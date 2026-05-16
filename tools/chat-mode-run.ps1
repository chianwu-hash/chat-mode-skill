param(
    [string]$RepoPath = '',

    [string]$ConfigPath = '',

    [string]$StatePath = '',

    [string]$SessionDir = '',

    [string]$Topic = '',

    [string]$TaskSummary = '',

    [int]$MaxTurns = 4,

    [ValidateSet('codex', 'claude')]
    [string]$FirstMover = 'codex',

    [ValidateSet('codex', 'claude', 'runner')]
    [string]$OrchestratorAgent = 'runner',

    [ValidateSet('review', 'suggest')]
    [string]$PermissionProfile = 'review',

    [int]$TimeoutSeconds = 300,

    [string]$CodexExe = '',

    [string]$ClaudeExe = '',

    [switch]$NewSession
)

#requires -Version 7.6.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    $RepoPath = (Get-Location).Path
}
else {
    $RepoPath = [System.IO.Path]::GetFullPath($RepoPath)
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RepoPath '.chat-mode\config.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $RepoPath $ConfigPath
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

if ($MaxTurns -le 0) {
    throw 'MaxTurns must be greater than 0.'
}

if ($TimeoutSeconds -le 0) {
    throw 'TimeoutSeconds must be greater than 0.'
}

function Get-IsoNow {
    param([datetimeoffset]$Value)
    return $Value.ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Get-OtherAgent {
    param([string]$Agent)
    if ($Agent -eq 'codex') { return 'claude' }
    return 'codex'
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

function Resolve-RepoPath {
    param([string]$MaybeRelativePath)

    if ([System.IO.Path]::IsPathRooted($MaybeRelativePath)) {
        return $MaybeRelativePath
    }

    return Join-Path $RepoPath $MaybeRelativePath
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

    return Join-Path $Directory "$($When.ToString('yyyy-MM-dd'))-$slug.md"
}

function New-SessionDocument {
    param(
        [string]$TaskSummaryText,
        [int]$Turns,
        [string]$StarterAgent,
        [datetimeoffset]$When
    )

    return @"
# Session: $TaskSummaryText

Date: $($When.ToString('yyyy-MM-dd'))
Mode: orchestrated, $Turns turns
Orchestrator: $OrchestratorAgent
First mover: $StarterAgent

---

"@
}

function Read-ChatModeConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Missing chat-mode config: $ConfigPath. Run tools\chat-mode-setup.ps1 from Codex first."
    }

    return Get-Content -LiteralPath $ConfigPath -Encoding utf8 -Raw | ConvertFrom-Json
}

function Get-ConfiguredExe {
    param(
        [pscustomobject]$Config,
        [string]$ExplicitValue,
        [string]$ConfigProperty,
        [string]$CommandName
    )

    $candidate = $ExplicitValue
    if ([string]::IsNullOrWhiteSpace($candidate) -and $Config.PSObject.Properties.Name -contains $ConfigProperty) {
        $candidate = $Config.$ConfigProperty
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $command = Get-Command $CommandName -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
        throw "Missing executable for $CommandName. Run tools\chat-mode-setup.ps1 first or pass an explicit path."
    }
    if (Test-Path -LiteralPath $candidate) {
        return [System.IO.Path]::GetFullPath($candidate)
    }

    $resolved = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($resolved) {
        return $resolved.Source
    }

    throw "Configured executable not found: $candidate"
}

function Get-RecentSessionContext {
    param([string]$SessionText)

    $matches = [regex]::Matches($SessionText, '(?m)^## Round ')
    if ($matches.Count -le 2) {
        return $SessionText
    }

    $start = $matches[$matches.Count - 2].Index
    return $SessionText.Substring($start)
}

function New-WorkerPrompt {
    param(
        [string]$Agent,
        [int]$RoundNumber,
        [pscustomobject]$State,
        [string]$SessionText
    )

    $sessionRelative = $State.session_file
    $stateRelative = Get-RelativePath -RootPath $RepoPath -FullPath $StatePath
    $context = Get-RecentSessionContext -SessionText $SessionText
    $mutationPolicy = 'Do not edit files. Return analysis, findings, and recommendations as markdown only.'
    if ($PermissionProfile -eq 'suggest') {
        $mutationPolicy = 'Do not edit files. Suggest edits as text only.'
    }

    return @"
You are the $Agent worker for a chat-mode session.

Do not invoke claude, codex, or any other agent CLI.
Do not start a nested chat-mode loop.
Return control to the orchestrator by printing your response only.

Repo root:
$RepoPath

Session file:
$sessionRelative

State file:
$stateRelative

Current turn:
$RoundNumber of $($State.max_turns)

Task:
$($State.task)

Your role:
$Agent worker

Permission profile:
$PermissionProfile

File mutation policy:
$mutationPolicy

Read the state file and session file if you need more context. Continue only your assigned round.

Context:
$context

Required output:
- Markdown only.
- Start with the round conclusion.
- Include risks, blockers, and recommended next steps.
- Do not include tool logs unless they are necessary to explain a failure.
"@
}

function Get-ProcessInvocation {
    param(
        [string]$ExePath,
        [string[]]$ToolArgs
    )

    $extension = [System.IO.Path]::GetExtension($ExePath).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        return [pscustomobject]@{
            FileName = 'pwsh'
            Arguments = @('-NoProfile', '-File', $ExePath) + $ToolArgs
        }
    }

    if ($extension -in @('.cmd', '.bat')) {
        return [pscustomobject]@{
            FileName = 'cmd.exe'
            Arguments = @('/c', $ExePath) + $ToolArgs
        }
    }

    return [pscustomobject]@{
        FileName = $ExePath
        Arguments = $ToolArgs
    }
}

function Invoke-Worker {
    param(
        [string]$Agent,
        [string]$Prompt,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    if ($Agent -eq 'claude') {
        $invocation = Get-ProcessInvocation -ExePath $script:ClaudePath -ToolArgs @(
            '-p',
            '--tools', 'Read,Glob,Grep',
            '--allowedTools', 'Read,Glob,Grep',
            '--permission-mode', 'dontAsk',
            '--output-format', 'text',
            $Prompt
        )
    }
    else {
        $invocation = Get-ProcessInvocation -ExePath $script:CodexPath -ToolArgs @(
            '--ask-for-approval', 'never',
            'exec',
            '-C', $RepoPath,
            '--sandbox', 'read-only',
            $Prompt
        )
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $invocation.FileName
    foreach ($arg in $invocation.Arguments) {
        [void]$startInfo.ArgumentList.Add($arg)
    }
    $startInfo.WorkingDirectory = $RepoPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try {
            $process.Kill($true)
        }
        catch {
        }
        throw "$Agent worker timed out after $TimeoutSeconds seconds."
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Set-Content -LiteralPath $StdoutPath -Encoding utf8 -Value $stdout
    Set-Content -LiteralPath $StderrPath -Encoding utf8 -Value $stderr

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Get-GitDiffStat {
    $output = & git -C $RepoPath diff --stat 2>&1
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

function Get-GitStatusShort {
    $output = & git -C $RepoPath status --short 2>&1
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

function Update-StateFile {
    param([pscustomobject]$State)
    $State.updated_at = Get-IsoNow -Value ([datetimeoffset]::Now)
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding utf8
}

function Add-StateProperty {
    param(
        [pscustomobject]$State,
        [string]$Name,
        [object]$Value
    )
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function New-OrchestratedState {
    $summary = if ([string]::IsNullOrWhiteSpace($TaskSummary)) { $Topic } else { $TaskSummary }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        throw 'Topic or TaskSummary is required when creating a new session.'
    }
    if ($summary.ToCharArray().Where({ [int][char]$_ -gt 127 }).Count -gt 0) {
        throw 'TaskSummary must contain ASCII only.'
    }

    $now = [datetimeoffset]::Now
    $sessionPath = New-SessionFilePath -Directory $SessionDir -Summary $summary -When $now
    $sessionRelative = Get-RelativePath -RootPath $RepoPath -FullPath $sessionPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StatePath) | Out-Null
    New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null

    $state = [pscustomobject][ordered]@{
        current_agent = $FirstMover
        status = 'in_progress'
        task = $summary
        session_file = $sessionRelative
        conversation_mode = 'orchestrated'
        limit_minutes = $null
        max_turns = $MaxTurns
        current_turn = 0
        poll_interval_seconds = 0
        next_check_at = $null
        last_checked_at = Get-IsoNow -Value $now
        started_at = Get-IsoNow -Value $now
        stop_reason = $null
        updated_by = 'runner'
        updated_at = Get-IsoNow -Value $now
        orchestration_mode = 'orchestrated'
        orchestrator_agent = $OrchestratorAgent
        worker_agent = 'both'
        permission_profile = $PermissionProfile
        timeout_seconds = $TimeoutSeconds
    }

    New-SessionDocument -TaskSummaryText $summary -Turns $MaxTurns -StarterAgent $FirstMover -When $now |
        Set-Content -LiteralPath $sessionPath -Encoding utf8
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding utf8
    return $state
}

function Get-ActiveState {
    if ($NewSession -or -not (Test-Path -LiteralPath $StatePath)) {
        return New-OrchestratedState
    }

    $state = Get-Content -LiteralPath $StatePath -Encoding utf8 -Raw | ConvertFrom-Json
    if ($state.status -in @('done', 'interrupted')) {
        if ([string]::IsNullOrWhiteSpace($Topic) -and [string]::IsNullOrWhiteSpace($TaskSummary)) {
            throw "Existing session is $($state.status). Pass -NewSession with -Topic to start a new run."
        }
        return New-OrchestratedState
    }

    return $state
}

$config = Read-ChatModeConfig
$script:CodexPath = Get-ConfiguredExe -Config $config -ExplicitValue $CodexExe -ConfigProperty 'codex_exe' -CommandName 'codex'
$script:ClaudePath = Get-ConfiguredExe -Config $config -ExplicitValue $ClaudeExe -ConfigProperty 'claude_exe' -CommandName 'claude'

$tmpDir = Join-Path $RepoPath '.chat-mode\tmp'
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$state = Get-ActiveState

while ($state.status -eq 'in_progress' -and $state.current_turn -lt $state.max_turns) {
    $agent = $state.current_agent
    if ($agent -notin @('codex', 'claude')) {
        throw "Cannot run worker for current_agent=$agent."
    }

    $sessionPath = Resolve-RepoPath -MaybeRelativePath $state.session_file
    if (-not (Test-Path -LiteralPath $sessionPath)) {
        throw "Missing session file: $sessionPath"
    }

    $roundNumber = [int]$state.current_turn + 1
    $sessionText = Get-Content -LiteralPath $sessionPath -Encoding utf8 -Raw
    $prompt = New-WorkerPrompt -Agent $agent -RoundNumber $roundNumber -State $state -SessionText $sessionText
    $stdoutPath = Join-Path $tmpDir "$roundNumber-$agent-stdout.txt"
    $stderrPath = Join-Path $tmpDir "$roundNumber-$agent-stderr.txt"
    $diffBefore = Get-GitDiffStat
    $statusBefore = Get-GitStatusShort

    try {
        $result = Invoke-Worker -Agent $agent -Prompt $prompt -StdoutPath $stdoutPath -StderrPath $stderrPath
    }
    catch {
        $state.status = 'interrupted'
        $state.current_agent = 'user'
        $state.stop_reason = "${agent}_timeout"
        Add-StateProperty -State $state -Name "${agent}_last_error" -Value $_.Exception.Message
        Update-StateFile -State $state
        throw
    }

    $diffAfter = Get-GitDiffStat
    $statusAfter = Get-GitStatusShort
    $stdoutTrimmed = $result.Stdout.Trim()
    if ($result.ExitCode -ne 0) {
        $state.status = 'interrupted'
        $state.current_agent = 'user'
        $state.stop_reason = "${agent}_exit_$($result.ExitCode)"
        Add-StateProperty -State $state -Name "${agent}_last_exit_code" -Value $result.ExitCode
        Add-StateProperty -State $state -Name "${agent}_last_error" -Value $result.Stderr.Trim()
        Update-StateFile -State $state
        throw "$agent worker exited with code $($result.ExitCode). See $stderrPath"
    }

    if ([string]::IsNullOrWhiteSpace($stdoutTrimmed)) {
        $state.status = 'interrupted'
        $state.current_agent = 'user'
        $state.stop_reason = "${agent}_empty_output"
        Add-StateProperty -State $state -Name "${agent}_last_exit_code" -Value $result.ExitCode
        Add-StateProperty -State $state -Name "${agent}_last_error" -Value 'empty output'
        Update-StateFile -State $state
        throw "$agent worker returned empty output."
    }

    if ($diffAfter -ne $diffBefore -or $statusAfter -ne $statusBefore) {
        $state.status = 'interrupted'
        $state.current_agent = 'user'
        $state.stop_reason = "${agent}_workspace_modified"
        Add-StateProperty -State $state -Name "${agent}_last_exit_code" -Value $result.ExitCode
        Add-StateProperty -State $state -Name "${agent}_last_error" -Value 'workspace diff changed during read-only worker call'
        Update-StateFile -State $state
        throw "$agent worker changed tracked workspace diff in $PermissionProfile mode."
    }

    $diffSummary = if ([string]::IsNullOrWhiteSpace($diffAfter)) { 'clean' } else { $diffAfter }
    $roundText = @"
## Round $roundNumber - $($agent.Substring(0,1).ToUpperInvariant() + $agent.Substring(1))

Invocation:
- mode: orchestrated
- orchestrator: $OrchestratorAgent
- worker: $agent
- permission_profile: $PermissionProfile
- timeout_seconds: $TimeoutSeconds
- stdout_temp_file: $(Get-RelativePath -RootPath $RepoPath -FullPath $stdoutPath)
- stderr_temp_file: $(Get-RelativePath -RootPath $RepoPath -FullPath $stderrPath)
- exit_code: $($result.ExitCode)
- diff_stat_after: $diffSummary

Response:
$stdoutTrimmed

"@

    Add-Content -LiteralPath $sessionPath -Encoding utf8 -Value $roundText

    $state.current_turn = $roundNumber
    Add-StateProperty -State $state -Name "${agent}_last_exit_code" -Value $result.ExitCode
    Add-StateProperty -State $state -Name "${agent}_last_error" -Value $null
    $state.last_checked_at = Get-IsoNow -Value ([datetimeoffset]::Now)
    if ($state.current_turn -ge $state.max_turns) {
        $state.status = 'done'
        $state.current_agent = 'user'
        $state.stop_reason = 'turn_limit_reached'
        $state.next_check_at = $null
    }
    else {
        $state.current_agent = Get-OtherAgent -Agent $agent
        $state.next_check_at = $null
    }
    $state.updated_by = 'runner'
    Update-StateFile -State $state
}

[pscustomobject]@{
    status = $state.status
    current_turn = $state.current_turn
    max_turns = $state.max_turns
    current_agent = $state.current_agent
    stop_reason = $state.stop_reason
    session_file = $state.session_file
    state_path = $StatePath
} | ConvertTo-Json -Depth 4
