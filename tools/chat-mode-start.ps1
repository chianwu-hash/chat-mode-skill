param(
    [Parameter(Mandatory = $true)]
    [string]$Topic,

    [ValidateSet('turn-based', 'timed', 'hybrid')]
    [string]$Mode = 'turn-based',

    [int]$MaxTurns = 4,

    [Nullable[int]]$LimitMinutes = $null,

    [Parameter(Mandatory = $true)]
    [ValidateSet('codex', 'claude')]
    [string]$FirstMover,

    [ValidateSet('codex', 'claude')]
    [string]$RunnerAgent = 'codex',

    [string]$TaskSummary = 'chat-mode session',

    [int]$PollIntervalSeconds = 90,

    [string]$RepoPath = '',

    [string]$StatePath = '',

    [string]$SessionDir = '',

    [string]$PromptPath = '',

    [switch]$WritePromptFile
)

#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    $RepoPath = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $RepoPath '.chat-mode\agent-sync-state.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($StatePath)) {
    $StatePath = Join-Path $RepoPath $StatePath
}

if ([string]::IsNullOrWhiteSpace($SessionDir)) {
    $SessionDir = Join-Path $RepoPath '.chat-mode\sessions'
}
elseif (-not [System.IO.Path]::IsPathRooted($SessionDir)) {
    $SessionDir = Join-Path $RepoPath $SessionDir
}

if ([string]::IsNullOrWhiteSpace($PromptPath)) {
    $PromptPath = Join-Path $RepoPath '.chat-mode\claude-start-prompt.txt'
}
elseif (-not [System.IO.Path]::IsPathRooted($PromptPath)) {
    $PromptPath = Join-Path $RepoPath $PromptPath
}

if ($Mode -eq 'turn-based' -and $MaxTurns -le 0) {
    throw 'MaxTurns must be greater than 0 for turn-based mode.'
}

if (($Mode -eq 'timed' -or $Mode -eq 'hybrid') -and ($null -eq $LimitMinutes -or $LimitMinutes -le 0)) {
    throw 'LimitMinutes must be provided and greater than 0 for timed or hybrid mode.'
}

if ($Mode -eq 'hybrid' -and $MaxTurns -le 0) {
    throw 'MaxTurns must be greater than 0 for hybrid mode.'
}

if ($TaskSummary.ToCharArray().Where({ [int][char]$_ -gt 127 }).Count -gt 0) {
    throw 'TaskSummary must contain ASCII only.'
}

function Get-IsoNow {
    param([datetimeoffset]$Value)
    return $Value.ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Get-AgentLabel {
    param([string]$Agent)
    switch ($Agent) {
        'codex' { return 'Codex' }
        'claude' { return 'Claude Code' }
        default { throw "Unknown agent: $Agent" }
    }
}

function Get-OtherAgent {
    param([string]$Agent)
    if ($Agent -eq 'codex') { return 'claude' }
    return 'codex'
}

function New-MirroredPrompt {
    param(
        [string]$TaskTopic,
        [int]$Turns,
        [string]$StarterAgent,
        [string]$StateFilePath,
        [string]$RootPath
    )

    $starterLabel = Get-AgentLabel -Agent $StarterAgent
    $relativeState = Get-RelativePath -RootPath $RootPath -FullPath $StateFilePath

    return @"
Chat-mode session started: '$TaskTopic' ($Turns turns). $starterLabel has written round 1.

To continue as the next agent:
1. Read the shared state file at: $relativeState
2. Read the session file pointed to by the state's ``session_file`` field (resolve relative paths from the repo root).
3. Write your round as the next section in the session file.
4. Update ``current_turn``, ``current_agent``, ``poll_interval_seconds``, ``next_check_at``, and ``updated_at`` in the state file. Set ``current_agent`` to the first mover's agent name so they know to act next.
5. Schedule a ScheduleWakeup (90 seconds) to poll for the other agent's next round.
6. Enter the polling retry loop: re-read state after each wait; if ``current_agent`` is you, respond; if not and retries remain, wait again; if retries exhausted, set status=interrupted.

Do not read any handoff file. The state file and session file are the only inputs.
"@
}

function Get-SessionSlug {
    param([string]$Summary)
    return ($Summary.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
}

function Get-RelativePath {
    param(
        [string]$RootPath,
        [string]$FullPath
    )

    $root = [System.IO.Path]::GetFullPath($RootPath)
    $full = [System.IO.Path]::GetFullPath($FullPath)
    $rootUri = [System.Uri]::new(($root.TrimEnd('\') + '\'))
    $fullUri = [System.Uri]::new($full)
    return [System.Uri]::UnescapeDataString($rootUri.MakeRelativeUri($fullUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function New-SessionFilePath {
    param(
        [string]$Directory,
        [string]$Summary,
        [datetimeoffset]$When
    )

    $slug = Get-SessionSlug -Summary $Summary
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'TaskSummary must contain at least one ASCII letter or digit.'
    }

    $dateStr = $When.ToString('yyyy-MM-dd')
    return Join-Path $Directory "$dateStr-$slug.md"
}

function New-SessionDocument {
    param(
        [string]$TaskSummaryText,
        [string]$SessionMode,
        [int]$Turns,
        [string]$StarterAgent,
        [datetimeoffset]$When
    )

    return @"
# Session: $TaskSummaryText

Date: $($When.ToString('yyyy-MM-dd'))
Mode: $SessionMode, $Turns turns
First mover: $StarterAgent

---

"@
}

$now = [datetimeoffset]::Now
$nextCheck = $now.AddSeconds($PollIntervalSeconds)
$starter = $FirstMover
$nextOwner = Get-OtherAgent -Agent $starter
$mirroredPrompt = New-MirroredPrompt -TaskTopic $Topic -Turns $MaxTurns -StarterAgent $starter -StateFilePath $StatePath -RootPath $RepoPath

$sessionFilePath = New-SessionFilePath -Directory $SessionDir -Summary $TaskSummary -When $now
$sessionFileRelative = Get-RelativePath -RootPath $RepoPath -FullPath $sessionFilePath

$state = [ordered]@{
    current_agent = $starter
    status = 'in_progress'
    task = $TaskSummary
    session_file = $sessionFileRelative
    conversation_mode = $Mode
    limit_minutes = $LimitMinutes
    max_turns = $MaxTurns
    current_turn = 0
    poll_interval_seconds = $PollIntervalSeconds
    next_check_at = Get-IsoNow -Value $nextCheck
    last_checked_at = Get-IsoNow -Value $now
    started_at = Get-IsoNow -Value $now
    stop_reason = $null
    updated_by = $RunnerAgent
    updated_at = Get-IsoNow -Value $now
}

$sessionContent = New-SessionDocument -TaskSummaryText $TaskSummary -SessionMode $Mode -Turns $MaxTurns -StarterAgent $starter -When $now

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StatePath) | Out-Null
New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null

$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding utf8
Set-Content -LiteralPath $sessionFilePath -Encoding utf8 -Value $sessionContent

if ($WritePromptFile) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PromptPath) | Out-Null
    Set-Content -LiteralPath $PromptPath -Encoding utf8 -Value $mirroredPrompt
}

[pscustomobject]@{
    mirrored_prompt = $mirroredPrompt
    task_summary = $TaskSummary
    state_path = $StatePath
    session_file = $sessionFileRelative
    prompt_path = $(if ($WritePromptFile) { $PromptPath } else { $null })
    current_agent = $starter
    next_owner = $nextOwner
    started_at = Get-IsoNow -Value $now
} | ConvertTo-Json -Depth 3
