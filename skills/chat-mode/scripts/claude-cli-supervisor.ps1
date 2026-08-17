[CmdletBinding()]
param(
    [ValidateSet('Invoke', 'Status')]
    [string]$Action = 'Invoke',

    [string]$RequestPath = '',

    [string]$WorkingTree = '.',

    [switch]$Resume,

    [int]$TimeoutSeconds = 300,

    [int]$MaxResponseBytes = 50000,

    [int]$MaxAgentTurns = 12,

    [ValidateSet('medium', 'high')]
    [string]$ClaudeEffort = 'medium',

    [int]$IdleWarningSeconds = 90,

    [switch]$ShowConversationViewer,

    [int]$ViewerHoldSeconds = 0,

    [string]$ClaudeExe = 'claude',

    [string[]]$ClaudeArgsPrefix = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$minimumClaudeVersion = [version]'2.1.233'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function New-ProcessResult {
    param(
        [int]$ExitCode,
        [string]$Stdout,
        [string]$Stderr,
        [double]$ElapsedSeconds,
        [string]$StopReason,
        [int]$StreamEventCount = 0,
        [int]$LiveBytes = 0,
        [string]$LastEventAt = '',
        [string]$LastEventKind = 'starting',
        [int]$ReadToolUseCount = 0,
        [string]$ProvisionalClaudeSessionId = '',
        [bool]$MalformedLineSeen = $false
    )

    [pscustomobject]@{
        ExitCode = $ExitCode
        Stdout = $Stdout
        Stderr = $Stderr
        ElapsedSeconds = $ElapsedSeconds
        StopReason = $StopReason
        StreamEventCount = $StreamEventCount
        LiveBytes = $LiveBytes
        LastEventAt = $LastEventAt
        LastEventKind = $LastEventKind
        ReadToolUseCount = $ReadToolUseCount
        ProvisionalClaudeSessionId = $ProvisionalClaudeSessionId
        MalformedLineSeen = $MalformedLineSeen
    }
}

function Write-JsonAtomic {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Record
    )

    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Force -Path $parent)
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, (($Record | ConvertTo-Json -Depth 10) + "`n"), $utf8NoBom)
        [System.IO.File]::Move($temporary, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-ActivityStatus {
    param(
        [System.Collections.IDictionary]$State,
        [string]$StatusPath,
        [string]$SessionId,
        [string]$TurnId,
        [string]$RunState,
        [string]$Effort,
        [int]$TimeoutSeconds,
        [int]$IdleWarningSeconds,
        [double]$ElapsedSeconds,
        [string]$StopReason = ''
    )

    if ([string]::IsNullOrWhiteSpace($StatusPath)) { return }
    $record = [ordered]@{
        schemaVersion = 1
        sessionId = $SessionId
        turnId = $TurnId
        state = $RunState
        effort = $Effort
        timeoutSeconds = $TimeoutSeconds
        idleWarningSeconds = $IdleWarningSeconds
        elapsedSeconds = [math]::Round($ElapsedSeconds, 3)
        eventCount = $State.StreamEventCount
        lastEventAt = $State.LastEventAt
        lastEventKind = $State.LastEventKind
        readToolUseCount = $State.ReadToolUseCount
        hasProvisionalClaudeSessionId = -not [string]::IsNullOrWhiteSpace($State.ProvisionalClaudeSessionId)
        stopReason = $StopReason
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-JsonAtomic -Path $StatusPath -Record $record
}

function Add-StreamingLine {
    param(
        [System.Collections.IDictionary]$State,
        [string]$Line,
        [string]$LivePath,
        [int]$LiveByteLimit,
        [string]$StatusPath,
        [string]$SessionId,
        [string]$TurnId,
        [string]$Effort,
        [int]$TimeoutSeconds,
        [int]$IdleWarningSeconds,
        [System.Diagnostics.Stopwatch]$Timer
    )

    $State.StreamEventCount++

    try {
        $streamEvent = $Line | ConvertFrom-Json
    }
    catch {
        $State.MalformedLineSeen = $true
        return
    }

    $State.LastEventAt = [DateTimeOffset]::UtcNow.ToString('o')
    $State.LastEventKind = 'model-active'
    if ($streamEvent.PSObject.Properties.Name -contains 'session_id' -and
        -not [string]::IsNullOrWhiteSpace([string]$streamEvent.session_id)) {
        $State.ProvisionalClaudeSessionId = [string]$streamEvent.session_id
    }
    if ($streamEvent.type -eq 'result') {
        $State.ResultLine = $Line
        $State.LastEventKind = 'finalizing'
    }
    elseif ($streamEvent.type -eq 'stream_event') {
        $eventType = [string]$streamEvent.event.type
        if ($eventType -eq 'content_block_start' -and
            $streamEvent.event.content_block.type -eq 'tool_use') {
            $State.LastEventKind = 'tool-active'
            if ($streamEvent.event.content_block.name -eq 'Read') {
                $State.ReadToolUseCount++
            }
        }
        elseif ($eventType -eq 'content_block_delta' -and
            $streamEvent.event.delta.type -eq 'text_delta') {
            $State.LastEventKind = 'responding'
        }
    }

    Write-ActivityStatus `
        -State $State `
        -StatusPath $StatusPath `
        -SessionId $SessionId `
        -TurnId $TurnId `
        -RunState 'running' `
        -Effort $Effort `
        -TimeoutSeconds $TimeoutSeconds `
        -IdleWarningSeconds $IdleWarningSeconds `
        -ElapsedSeconds $Timer.Elapsed.TotalSeconds

    if ($streamEvent.type -ne 'stream_event' -or
        $streamEvent.event.type -ne 'content_block_delta' -or
        $streamEvent.event.delta.type -ne 'text_delta') {
        return
    }

    $delta = [string]$streamEvent.event.delta.text
    if ([string]::IsNullOrEmpty($delta) -or $State.LiveTruncated) {
        return
    }

    $deltaBytes = $utf8NoBom.GetByteCount($delta)
    if ($State.LiveBytes + $deltaBytes -gt $LiveByteLimit) {
        $notice = "`n`n[live output truncated; final response validation continues]`n"
        [System.IO.File]::AppendAllText($LivePath, $notice, $utf8NoBom)
        $State.LiveBytes += $utf8NoBom.GetByteCount($notice)
        $State.LiveTruncated = $true
        return
    }

    [System.IO.File]::AppendAllText($LivePath, $delta, $utf8NoBom)
    $State.LiveBytes += $deltaBytes
}

function Invoke-CapturedProcess {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [int]$DeadlineSeconds,
        [string]$StopFile = '',
        [switch]$StreamJson,
        [string]$LivePath = '',
        [int]$LiveByteLimit = 50000,
        [string]$StatusPath = '',
        [string]$SessionId = '',
        [string]$TurnId = '',
        [string]$Effort = 'medium',
        [int]$IdleWarningSeconds = 90
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    $startInfo.WorkingDirectory = $script:WorkingTreePath

    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $process.Start()) {
        throw "Failed to start process: $FileName"
    }

    $stdoutTask = $null
    $lineTask = $null
    $streamState = [ordered]@{
        ResultLine = ''
        MalformedLineSeen = $false
        StreamEventCount = 0
        LiveBytes = 0
        LiveTruncated = $false
        LastEventAt = ''
        LastEventKind = 'starting'
        ReadToolUseCount = 0
        ProvisionalClaudeSessionId = ''
    }
    if ($StreamJson) {
        $lineTask = $process.StandardOutput.ReadLineAsync()
    }
    else {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    }
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopReason = ''

    while (-not $process.HasExited) {
        if ($StreamJson -and $null -ne $lineTask -and $lineTask.IsCompleted) {
            $line = $lineTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $lineTask = $null
            }
            else {
                Add-StreamingLine -State $streamState -Line $line -LivePath $LivePath -LiveByteLimit $LiveByteLimit -StatusPath $StatusPath -SessionId $SessionId -TurnId $TurnId -Effort $Effort -TimeoutSeconds $DeadlineSeconds -IdleWarningSeconds $IdleWarningSeconds -Timer $timer
                $lineTask = $process.StandardOutput.ReadLineAsync()
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($StopFile) -and (Test-Path -LiteralPath $StopFile)) {
            $stopReason = 'user_stop'
            try { $process.Kill($true) } catch {}
            break
        }

        if ($timer.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
            $stopReason = 'timeout'
            try { $process.Kill($true) } catch {}
            break
        }

        Start-Sleep -Milliseconds 50
    }

    $process.WaitForExit()
    if ($StreamJson) {
        while ($null -ne $lineTask) {
            $line = $lineTask.GetAwaiter().GetResult()
            if ($null -eq $line) {
                $lineTask = $null
            }
            else {
                Add-StreamingLine -State $streamState -Line $line -LivePath $LivePath -LiveByteLimit $LiveByteLimit -StatusPath $StatusPath -SessionId $SessionId -TurnId $TurnId -Effort $Effort -TimeoutSeconds $DeadlineSeconds -IdleWarningSeconds $IdleWarningSeconds -Timer $timer
                $lineTask = $process.StandardOutput.ReadLineAsync()
            }
        }
    }
    $timer.Stop()
    $stdout = if ($StreamJson) { $streamState.ResultLine } else { $stdoutTask.GetAwaiter().GetResult() }
    if ($StreamJson -and $streamState.MalformedLineSeen -and [string]::IsNullOrWhiteSpace($stdout)) {
        $stdout = '__CHAT_MODE_MALFORMED_STREAM__'
    }
    $stderr = $stderrTask.GetAwaiter().GetResult()

    New-ProcessResult `
        -ExitCode $process.ExitCode `
        -Stdout $stdout `
        -Stderr $stderr `
        -ElapsedSeconds $timer.Elapsed.TotalSeconds `
        -StopReason $stopReason `
        -StreamEventCount $streamState.StreamEventCount `
        -LiveBytes $streamState.LiveBytes `
        -LastEventAt $streamState.LastEventAt `
        -LastEventKind $streamState.LastEventKind `
        -ReadToolUseCount $streamState.ReadToolUseCount `
        -ProvisionalClaudeSessionId $streamState.ProvisionalClaudeSessionId `
        -MalformedLineSeen $streamState.MalformedLineSeen
}

function Get-ClaudeArguments {
    param([string[]]$Arguments)
    @($script:EffectiveClaudeArgsPrefix) + @($Arguments)
}

function Get-ClaudeVersionInfo {
    $result = Invoke-CapturedProcess `
        -FileName $script:ClaudePath `
        -Arguments (Get-ClaudeArguments @('--version')) `
        -DeadlineSeconds 15

    if ($result.ExitCode -ne 0) {
        throw "claude --version failed: $($result.Stderr.Trim())"
    }

    if ($result.Stdout -notmatch '(?<version>\d+\.\d+\.\d+)') {
        throw "Could not parse Claude Code version: $($result.Stdout.Trim())"
    }

    $version = [version]$Matches.version
    [pscustomobject]@{
        Version = $version
        Raw = $result.Stdout.Trim()
        MeetsMinimum = $version -ge $minimumClaudeVersion
    }
}

function Get-ClaudeAuthInfo {
    if (-not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -or
        -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
        throw 'API credentials are present. Chat-mode CLI requires Claude subscription OAuth.'
    }

    $result = Invoke-CapturedProcess `
        -FileName $script:ClaudePath `
        -Arguments (Get-ClaudeArguments @('auth', 'status')) `
        -DeadlineSeconds 15

    if ($result.ExitCode -ne 0) {
        throw 'Claude subscription authentication is unavailable. Run claude auth login.'
    }

    try {
        $auth = $result.Stdout | ConvertFrom-Json
    }
    catch {
        throw "Could not parse claude auth status: $($result.Stdout.Trim())"
    }

    if (-not $auth.loggedIn -or $auth.authMethod -ne 'claude.ai') {
        throw 'Chat-mode CLI requires a logged-in claude.ai subscription, not API billing.'
    }

    $auth
}

function Get-FrontMatterLines {
    param([string]$Text)

    $lines = $Text -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        throw 'Request must begin with YAML frontmatter.'
    }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            $end = $i
            break
        }
    }

    if ($end -lt 2) {
        throw 'Request frontmatter is not terminated.'
    }

    @($lines[1..($end - 1)])
}

function Get-FrontMatterBlocks {
    param([string[]]$Lines)

    $blocks = [ordered]@{}
    $currentKey = ''
    foreach ($line in $Lines) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_-]*):(?:\s*(.*))?$') {
            $currentKey = $Matches[1]
            $blocks[$currentKey] = [System.Collections.Generic.List[string]]::new()
            $blocks[$currentKey].Add($line.TrimEnd())
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($currentKey) -and $line -match '^\s+') {
            $blocks[$currentKey].Add($line.TrimEnd())
        }
    }

    $blocks
}

function Get-FrontMatterScalar {
    param(
        [System.Collections.IDictionary]$Blocks,
        [string]$Name,
        [switch]$Required
    )

    if (-not $Blocks.Contains($Name)) {
        if ($Required) { throw "Missing request field: $Name" }
        return ''
    }

    $first = $Blocks[$Name][0]
    $value = ($first -replace '^[^:]+:\s*', '').Trim()
    $value = $value.Trim('"').Trim("'")
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Request field is empty: $Name"
    }
    $value
}

function Get-FrontMatterList {
    param(
        [System.Collections.IDictionary]$Blocks,
        [string]$Name
    )

    if (-not $Blocks.Contains($Name)) { return @() }
    $values = [System.Collections.Generic.List[string]]::new()
    $first = $Blocks[$Name][0]
    $inline = ($first -replace '^[^:]+:\s*', '').Trim()
    if (-not [string]::IsNullOrWhiteSpace($inline)) {
        if ($inline -notmatch '^\[(.*)\]$') {
            throw "Request list field $Name must use YAML block-list or flow-list syntax."
        }

        $body = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($body)) { return @() }

        $item = [System.Text.StringBuilder]::new()
        $quote = [char]0
        $escaped = $false
        foreach ($character in $body.ToCharArray()) {
            if ($escaped) {
                [void]$item.Append($character)
                $escaped = $false
                continue
            }
            if ($quote -eq '"' -and $character -eq '\') {
                [void]$item.Append($character)
                $escaped = $true
                continue
            }
            if ($quote -ne [char]0) {
                [void]$item.Append($character)
                if ($character -eq $quote) { $quote = [char]0 }
                continue
            }
            if ($character -eq '"' -or $character -eq "'") {
                $quote = $character
                [void]$item.Append($character)
                continue
            }
            if ($character -eq ',') {
                $value = $item.ToString().Trim().Trim('"').Trim("'")
                if ([string]::IsNullOrWhiteSpace($value)) {
                    throw "Request list field $Name contains an empty item."
                }
                $values.Add($value)
                [void]$item.Clear()
                continue
            }
            if ($character -in @('[', ']', '{', '}')) {
                throw "Request list field $Name contains unsupported nested YAML."
            }
            [void]$item.Append($character)
        }
        if ($quote -ne [char]0 -or $escaped) {
            throw "Request list field $Name contains an unterminated quoted item."
        }
        $value = $item.ToString().Trim().Trim('"').Trim("'")
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Request list field $Name contains an empty item."
        }
        $values.Add($value)
        return @($values)
    }

    foreach ($line in $Blocks[$Name]) {
        if ($line -match '^\s*-\s*(.+?)\s*$') {
            $value = $Matches[1].Trim().Trim('"').Trim("'")
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $values.Add($value)
            }
        }
    }
    @($values)
}

function Get-ContractFingerprint {
    param([System.Collections.IDictionary]$Blocks)

    $contractKeys = @(
        'protocol', 'session_id', 'orchestrator', 'worker', 'transport', 'mode', 'permission',
        'authority', 'approval_policy', 'edit_mode', 'repo_root', 'main_repo',
        'worktree_path', 'worktree_branch', 'repo_branch', 'repo_head', 'base_commit',
        'repo_upstream', 'repo_upstream_head', 'baseline_status',
        'write_scope', 'setup_scope', 'authorized_actions', 'authorized_commands',
        'allowed_config_paths', 'git_authority', 'network_authority',
        'credential_authority', 'deployment_authority', 'external_paths',
        'restart_authority'
    )

    $canonical = [System.Collections.Generic.List[string]]::new()
    foreach ($key in ($contractKeys | Sort-Object)) {
        if ($Blocks.Contains($key)) {
            $canonical.Add(($Blocks[$key] -join "`n"))
        }
    }

    $bytes = $utf8NoBom.GetBytes(($canonical -join "`n"))
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    [Convert]::ToHexString($hash).ToLowerInvariant()
}

function Get-GitSnapshot {
    param([string]$Root)

    $inside = & git -C $Root rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inside.Trim() -ne 'true') {
        throw "Not a Git working tree: $Root"
    }

    $branch = (& git -C $Root branch --show-current).Trim()
    $head = (& git -C $Root rev-parse HEAD).Trim()
    $status = (& git -C $Root status --porcelain=v1 --untracked-files=all) -join "`n"
    $upstream = (& git -C $Root rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null)
    $upstreamHead = ''
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($upstream -join ''))) {
        $upstream = ($upstream -join '').Trim()
        $upstreamHead = (& git -C $Root rev-parse '@{upstream}').Trim()
    }
    else {
        $upstream = ''
    }

    [pscustomobject]@{
        Branch = $branch
        Head = $head
        Status = $status
        Upstream = $upstream
        UpstreamHead = $upstreamHead
    }
}

function Test-SnapshotEqual {
    param($Before, $After)
    $Before.Branch -eq $After.Branch -and
        $Before.Head -eq $After.Head -and
        $Before.Status -eq $After.Status -and
        $Before.Upstream -eq $After.Upstream -and
        $Before.UpstreamHead -eq $After.UpstreamHead
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Force -Path $parent)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Append-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    [void](New-Item -ItemType Directory -Force -Path $parent)
    [System.IO.File]::AppendAllText($Path, $Content, $utf8NoBom)
}

function Start-ConversationViewer {
    param(
        [string]$Request,
        [string]$Live,
        [string]$Run,
        [string]$Status,
        [int]$HoldSeconds
    )

    $terminal = Get-Command wt.exe -ErrorAction Stop
    $powerShell = (Get-Command pwsh -ErrorAction Stop).Source
    $viewer = Join-Path $PSScriptRoot 'chat-mode-viewer.ps1'
    if (-not (Test-Path -LiteralPath $viewer -PathType Leaf)) {
        throw "Conversation viewer not found: $viewer"
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $terminal.Source
    $startInfo.UseShellExecute = $true
    foreach ($argument in @(
        '-w', '-1',
        'new-tab',
        '--title', 'Chat Mode - Codex and Claude',
        '--suppressApplicationTitle',
        $powerShell,
        '-NoProfile',
        '-File', $viewer,
        '-RequestPath', $Request,
        '-LivePath', $Live,
        '-RunPath', $Run,
        '-StatusPath', $Status,
        '-ParentProcessId', $PID.ToString(),
        '-HoldSeconds', $HoldSeconds.ToString()
    )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    [void][System.Diagnostics.Process]::Start($startInfo)
}

$script:WorkingTreePath = [System.IO.Path]::GetFullPath($WorkingTree)
$script:EffectiveClaudeArgsPrefix = @($ClaudeArgsPrefix)
$command = Get-Command $ClaudeExe -ErrorAction Stop
$script:ClaudePath = $command.Source
if ([string]::IsNullOrWhiteSpace($script:ClaudePath)) {
    $script:ClaudePath = $command.Path
}
if ([System.IO.Path]::GetExtension($script:ClaudePath) -ieq '.ps1') {
    $claudeScriptPath = $script:ClaudePath
    $script:ClaudePath = (Get-Command pwsh -ErrorAction Stop).Source
    $script:EffectiveClaudeArgsPrefix = @('-NoProfile', '-File', $claudeScriptPath) + @($ClaudeArgsPrefix)
}

$versionInfo = Get-ClaudeVersionInfo
if (-not $versionInfo.MeetsMinimum) {
    throw "Claude Code $($versionInfo.Version) is too old. Require $minimumClaudeVersion or newer."
}
$authInfo = Get-ClaudeAuthInfo

if ($Action -eq 'Status') {
    [pscustomobject]@{
        Status = 'ready'
        ClaudeVersion = $versionInfo.Raw
        AuthMethod = $authInfo.authMethod
        SubscriptionType = $authInfo.subscriptionType
        MinimumVersion = $minimumClaudeVersion.ToString()
    } | ConvertTo-Json -Depth 4
    exit 0
}

if ($TimeoutSeconds -le 0 -or $MaxResponseBytes -le 0 -or $MaxAgentTurns -le 0 -or $IdleWarningSeconds -le 0) {
    throw 'TimeoutSeconds, MaxResponseBytes, MaxAgentTurns, and IdleWarningSeconds must be positive.'
}
if ($ViewerHoldSeconds -lt 0) {
    throw 'ViewerHoldSeconds must not be negative.'
}
if ([string]::IsNullOrWhiteSpace($RequestPath)) {
    throw 'RequestPath is required for Invoke.'
}

$requestFullPath = [System.IO.Path]::GetFullPath($RequestPath)
if (-not (Test-Path -LiteralPath $requestFullPath -PathType Leaf)) {
    throw "Request file not found: $requestFullPath"
}

$relativeRequest = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $requestFullPath)
$normalizedRequest = $relativeRequest.Replace('\', '/')
if ($normalizedRequest -eq '..' -or $normalizedRequest.StartsWith('../') -or [System.IO.Path]::IsPathRooted($relativeRequest)) {
    throw 'RequestPath must be inside WorkingTree.'
}
if ($normalizedRequest -notmatch '^\.chat-mode/exchange/(?<pathSession>[^/]+)/turn-[0-9A-Za-z_-]+\.request\.md$') {
    throw 'RequestPath must use .chat-mode/exchange/<session>/turn-<id>.request.md.'
}
$pathSessionId = $Matches.pathSession

$stopFile = Join-Path $script:WorkingTreePath '.chat-mode\STOP'
if (Test-Path -LiteralPath $stopFile) {
    throw 'user_stop: .chat-mode/STOP exists.'
}

$requestText = [System.IO.File]::ReadAllText($requestFullPath, $utf8NoBom)
$frontMatterLines = Get-FrontMatterLines -Text $requestText
$blocks = Get-FrontMatterBlocks -Lines $frontMatterLines
$sessionId = Get-FrontMatterScalar -Blocks $blocks -Name 'session_id' -Required
$turnId = Get-FrontMatterScalar -Blocks $blocks -Name 'turn_id' -Required
$mode = Get-FrontMatterScalar -Blocks $blocks -Name 'mode' -Required
$marker = Get-FrontMatterScalar -Blocks $blocks -Name 'completion_marker' -Required

if ($sessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$' -or $turnId -notmatch '^[A-Za-z0-9_-]{1,32}$') {
    throw 'session_id or turn_id is unsafe for an artifact path.'
}
if (-not $pathSessionId.Equals($sessionId, [System.StringComparison]::Ordinal)) {
    throw 'Request path session segment must exactly match frontmatter session_id.'
}
if ($mode -notin @('review', 'isolated-implementer')) {
    throw "Mode $mode is not supported by CLI transport. Use Claude Desktop."
}

$fingerprint = Get-ContractFingerprint -Blocks $blocks
$sessionDirectory = Join-Path $script:WorkingTreePath ".chat-mode\sessions\$sessionId"
$statePath = Join-Path $sessionDirectory 'claude-cli-state.json'
$runPath = Join-Path $sessionDirectory "turn-$turnId.run.json"
$responsePath = Join-Path $sessionDirectory "turn-$turnId.response.md"
$livePath = Join-Path $sessionDirectory "turn-$turnId.live.md"
$statusPath = Join-Path $sessionDirectory "turn-$turnId.status.json"
$transcriptPath = Join-Path $script:WorkingTreePath ".chat-mode\sessions\$sessionId.md"

$claudeSessionId = ''
if ($Resume) {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Cannot resume: Claude CLI session state is missing.'
    }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.PSObject.Properties.Name -contains 'resumable' -and -not [bool]$state.resumable) {
        throw 'Cannot resume: a prior turn did not complete; choose a new session_id.'
    }
    if ($state.contractFingerprint -ne $fingerprint) {
        throw 'Cannot resume: request authority contract changed.'
    }
    $claudeSessionId = [string]$state.claudeSessionId
    if ([string]::IsNullOrWhiteSpace($claudeSessionId)) {
        throw 'Cannot resume: Claude session id is missing.'
    }
}
elseif (Test-Path -LiteralPath $statePath) {
    throw 'Session state already exists. Use -Resume or choose a new session_id.'
}

$gitBefore = Get-GitSnapshot -Root $script:WorkingTreePath
$authorizedCommands = Get-FrontMatterList -Blocks $blocks -Name 'authorized_commands'

$tools = @('Read', 'Glob', 'Grep')
$allowedTools = @('Read', 'Glob', 'Grep')
$permissionMode = 'dontAsk'
if ($mode -eq 'isolated-implementer') {
    $tools += @('Edit', 'Write')
    $allowedTools += @('Edit', 'Write')
    $permissionMode = 'acceptEdits'
    $realCommands = @($authorizedCommands | Where-Object { $_ -notin @('none', '<none>') })
    if ($realCommands.Count -gt 0) {
        $tools += 'Bash'
        foreach ($authorizedCommand in $realCommands) {
            $allowedTools += "Bash($authorizedCommand)"
        }
    }
}

$prompt = "Read $normalizedRequest, follow its authority contract, respond only with the requested result, and end with $marker. Do not invoke Claude, Codex, or another agent."
$claudeArguments = @(
    '-p',
    '--setting-sources', 'user',
    '--strict-mcp-config',
    '--disable-slash-commands',
    '--no-chrome',
    '--permission-mode', $permissionMode,
    '--tools', ($tools -join ','),
    '--allowedTools', ($allowedTools -join ','),
    '--max-turns', $MaxAgentTurns.ToString(),
    '--effort', $ClaudeEffort,
    '--output-format', 'stream-json',
    '--verbose',
    '--include-partial-messages'
)
if ($Resume) {
    $claudeArguments += @('--resume', $claudeSessionId)
}
$claudeArguments += $prompt

Write-Utf8File -Path $livePath -Content ''
$processResult = $null
try {
$initialActivity = [ordered]@{
    StreamEventCount = 0
    LastEventAt = ''
    LastEventKind = 'starting'
    ReadToolUseCount = 0
    ProvisionalClaudeSessionId = ''
}
Write-ActivityStatus `
    -State $initialActivity `
    -StatusPath $statusPath `
    -SessionId $sessionId `
    -TurnId $turnId `
    -RunState 'running' `
    -Effort $ClaudeEffort `
    -TimeoutSeconds $TimeoutSeconds `
    -IdleWarningSeconds $IdleWarningSeconds `
    -ElapsedSeconds 0
if ($ShowConversationViewer) {
    Start-ConversationViewer `
        -Request $requestFullPath `
        -Live $livePath `
        -Run $runPath `
        -Status $statusPath `
        -HoldSeconds $ViewerHoldSeconds
}

$processResult = Invoke-CapturedProcess `
    -FileName $script:ClaudePath `
    -Arguments (Get-ClaudeArguments $claudeArguments) `
    -DeadlineSeconds $TimeoutSeconds `
    -StopFile $stopFile `
    -StreamJson `
    -LivePath $livePath `
    -LiveByteLimit $MaxResponseBytes `
    -StatusPath $statusPath `
    -SessionId $sessionId `
    -TurnId $turnId `
    -Effort $ClaudeEffort `
    -IdleWarningSeconds $IdleWarningSeconds

if (-not [string]::IsNullOrWhiteSpace($processResult.StopReason)) {
    throw "$($processResult.StopReason): Claude CLI process stopped."
}
if ($processResult.MalformedLineSeen) {
    throw "malformed_response: Claude stream contained invalid JSON. stderr=$($processResult.Stderr.Trim())"
}

$claudeResult = $null
foreach ($streamLine in ($processResult.Stdout -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($streamLine)) { continue }
    try {
        $streamObject = $streamLine | ConvertFrom-Json
    }
    catch {
        throw "malformed_response: Claude stream contained invalid JSON. stderr=$($processResult.Stderr.Trim())"
    }
    if ($streamObject.type -eq 'result') {
        $claudeResult = $streamObject
    }
}

if ($null -eq $claudeResult -or $claudeResult.PSObject.Properties.Name -notcontains 'result') {
    throw "malformed_response: Claude stream result event is missing. stderr=$($processResult.Stderr.Trim())"
}

if ($processResult.ExitCode -ne 0 -or $claudeResult.is_error) {
    $message = [string]$claudeResult.result
    if ($message -match 'authenticate|OAuth|login') {
        throw "auth_required: $message"
    }
    throw "claude_error: $message"
}

$response = [string]$claudeResult.result
if ([string]::IsNullOrWhiteSpace($response)) {
    throw 'malformed_response: Claude returned an empty result.'
}
$responseBytes = $utf8NoBom.GetByteCount($response)
if ($responseBytes -gt $MaxResponseBytes) {
    throw "response_too_large: $responseBytes bytes exceeds $MaxResponseBytes."
}
if (-not $response.TrimEnd().EndsWith($marker, [System.StringComparison]::Ordinal)) {
    throw 'malformed_response: completion marker is missing from the response end.'
}

$gitAfter = Get-GitSnapshot -Root $script:WorkingTreePath
if ($mode -eq 'review' -and -not (Test-SnapshotEqual -Before $gitBefore -After $gitAfter)) {
    throw 'unexpected_mutation: review mode changed Git state.'
}

$returnedSessionId = [string]$claudeResult.session_id
if ([string]::IsNullOrWhiteSpace($returnedSessionId)) {
    throw 'malformed_response: Claude session id is missing.'
}
if ($Resume -and $returnedSessionId -ne $claudeSessionId) {
    throw 'malformed_response: resumed Claude session id changed.'
}

$stateRecord = [ordered]@{
    schemaVersion = 1
    sessionId = $sessionId
    claudeSessionId = $returnedSessionId
    contractFingerprint = $fingerprint
    mode = $mode
    workingTree = $script:WorkingTreePath
    claudeVersion = $versionInfo.Version.ToString()
    authMethod = $authInfo.authMethod
    subscriptionType = $authInfo.subscriptionType
    resumable = $true
    updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
Write-Utf8File -Path $statePath -Content (($stateRecord | ConvertTo-Json -Depth 8) + "`n")
Write-Utf8File -Path $responsePath -Content ($response.TrimEnd() + "`n")

$runRecord = [ordered]@{
    schemaVersion = 1
    status = 'completed'
    sessionId = $sessionId
    turnId = $turnId
    mode = $mode
    resumed = [bool]$Resume
    claudeSessionId = $returnedSessionId
    contractFingerprint = $fingerprint
    requestPath = $normalizedRequest
    responsePath = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $responsePath).Replace('\', '/')
    livePath = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $livePath).Replace('\', '/')
    statusPath = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $statusPath).Replace('\', '/')
    elapsedSeconds = [math]::Round($processResult.ElapsedSeconds, 3)
    responseBytes = $responseBytes
    liveBytes = $processResult.LiveBytes
    streamEventCount = $processResult.StreamEventCount
    lastEventAt = $processResult.LastEventAt
    lastEventKind = $processResult.LastEventKind
    readToolUseCount = $processResult.ReadToolUseCount
    effort = $ClaudeEffort
    timeoutSeconds = $TimeoutSeconds
    idleWarningSeconds = $IdleWarningSeconds
    conversationViewer = [bool]$ShowConversationViewer
    viewerHoldSeconds = $ViewerHoldSeconds
    exitCode = $processResult.ExitCode
    stopReason = 'completed'
    gitBefore = $gitBefore
    gitAfter = $gitAfter
    completedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
Write-Utf8File -Path $runPath -Content (($runRecord | ConvertTo-Json -Depth 10) + "`n")
Write-ActivityStatus `
    -State ([ordered]@{
        StreamEventCount = $processResult.StreamEventCount
        LastEventAt = $processResult.LastEventAt
        LastEventKind = $processResult.LastEventKind
        ReadToolUseCount = $processResult.ReadToolUseCount
        ProvisionalClaudeSessionId = $returnedSessionId
    }) `
    -StatusPath $statusPath `
    -SessionId $sessionId `
    -TurnId $turnId `
    -RunState 'completed' `
    -Effort $ClaudeEffort `
    -TimeoutSeconds $TimeoutSeconds `
    -IdleWarningSeconds $IdleWarningSeconds `
    -ElapsedSeconds $processResult.ElapsedSeconds `
    -StopReason 'completed'

$transcriptEntry = @"

## Turn $turnId - Claude CLI

- mode: $mode
- resumed: $([bool]$Resume)
- claude_session_id: $returnedSessionId
- contract_fingerprint: $fingerprint
- elapsed_seconds: $([math]::Round($processResult.ElapsedSeconds, 3))
- response_bytes: $responseBytes
- effort: $ClaudeEffort
- stop_reason: completed

$($response.TrimEnd())
"@
Append-Utf8File -Path $transcriptPath -Content $transcriptEntry

$runRecord | ConvertTo-Json -Depth 10
}
catch {
    $failureMessage = $_.Exception.Message
    $failureReason = 'supervisor_error'
    if ($failureMessage -match '^(?<reason>[a-z][a-z0-9_]*):') {
        $failureReason = $Matches.reason
    }

    $failureGitAfter = $null
    try { $failureGitAfter = Get-GitSnapshot -Root $script:WorkingTreePath } catch {}
    if ($mode -eq 'review' -and $null -ne $failureGitAfter -and
        -not (Test-SnapshotEqual -Before $gitBefore -After $failureGitAfter)) {
        $failureReason = 'unexpected_mutation'
        $failureMessage = 'unexpected_mutation: review mode changed Git state.'
    }

    if ($failureMessage.Length -gt 4000) {
        $failureMessage = $failureMessage.Substring(0, 4000) + '...'
    }
    $elapsed = if ($null -ne $processResult) { $processResult.ElapsedSeconds } else { 0 }
    $eventCount = if ($null -ne $processResult) { $processResult.StreamEventCount } else { 0 }
    $liveBytes = if ($null -ne $processResult) { $processResult.LiveBytes } else { 0 }
    $lastEventAt = if ($null -ne $processResult) { $processResult.LastEventAt } else { '' }
    $lastEventKind = if ($null -ne $processResult) { $processResult.LastEventKind } else { 'starting' }
    $readToolUseCount = if ($null -ne $processResult) { $processResult.ReadToolUseCount } else { 0 }
    $provisionalSessionId = if ($null -ne $processResult) { $processResult.ProvisionalClaudeSessionId } else { $claudeSessionId }
    $exitCode = if ($null -ne $processResult) { $processResult.ExitCode } else { -1 }

    $invalidState = [ordered]@{
        schemaVersion = 1
        sessionId = $sessionId
        claudeSessionId = $provisionalSessionId
        claudeSessionIdValidated = $false
        contractFingerprint = $fingerprint
        mode = $mode
        workingTree = $script:WorkingTreePath
        resumable = $false
        invalidatedBy = $failureReason
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-Utf8File -Path $statePath -Content (($invalidState | ConvertTo-Json -Depth 8) + "`n")

    $failureRecord = [ordered]@{
        schemaVersion = 1
        status = 'failed'
        sessionId = $sessionId
        turnId = $turnId
        mode = $mode
        resumed = [bool]$Resume
        claudeSessionId = $provisionalSessionId
        claudeSessionIdValidated = $false
        contractFingerprint = $fingerprint
        requestPath = $normalizedRequest
        responsePath = $null
        livePath = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $livePath).Replace('\', '/')
        statusPath = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $statusPath).Replace('\', '/')
        elapsedSeconds = [math]::Round($elapsed, 3)
        responseBytes = 0
        liveBytes = $liveBytes
        streamEventCount = $eventCount
        lastEventAt = $lastEventAt
        lastEventKind = $lastEventKind
        readToolUseCount = $readToolUseCount
        effort = $ClaudeEffort
        timeoutSeconds = $TimeoutSeconds
        idleWarningSeconds = $IdleWarningSeconds
        conversationViewer = [bool]$ShowConversationViewer
        viewerHoldSeconds = $ViewerHoldSeconds
        exitCode = $exitCode
        stopReason = $failureReason
        errorMessage = $failureMessage
        gitBefore = $gitBefore
        gitAfter = $failureGitAfter
        stoppedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-Utf8File -Path $runPath -Content (($failureRecord | ConvertTo-Json -Depth 10) + "`n")

    $viewerState = if ($failureReason -eq 'timeout') { 'stopped-timeout' } elseif ($failureReason -eq 'user_stop') { 'stopped-user' } else { 'failed' }
    Write-ActivityStatus `
        -State ([ordered]@{
            StreamEventCount = $eventCount
            LastEventAt = $lastEventAt
            LastEventKind = $lastEventKind
            ReadToolUseCount = $readToolUseCount
            ProvisionalClaudeSessionId = $provisionalSessionId
        }) `
        -StatusPath $statusPath `
        -SessionId $sessionId `
        -TurnId $turnId `
        -RunState $viewerState `
        -Effort $ClaudeEffort `
        -TimeoutSeconds $TimeoutSeconds `
        -IdleWarningSeconds $IdleWarningSeconds `
        -ElapsedSeconds $elapsed `
        -StopReason $failureReason

    $failureTranscript = @"

## Turn $turnId - Claude CLI failure

- mode: $mode
- resumed: $([bool]$Resume)
- effort: $ClaudeEffort
- elapsed_seconds: $([math]::Round($elapsed, 3))
- event_count: $eventCount
- stop_reason: $failureReason
- resumable: false
"@
    Append-Utf8File -Path $transcriptPath -Content $failureTranscript
    throw
}
