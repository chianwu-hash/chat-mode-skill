[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$supervisor = Join-Path $repoRoot 'skills\chat-mode\scripts\claude-cli-supervisor.ps1'
$viewer = Join-Path $repoRoot 'skills\chat-mode\scripts\chat-mode-viewer.ps1'
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('chat-mode-cli-smoke-' + [guid]::NewGuid().ToString('N'))

function Write-Request {
    param(
        [string]$Root,
        [string]$SessionId,
        [string]$TurnId,
        [string]$Marker,
        [string]$NetworkAuthority = 'none',
        [string]$PathSessionId = '',
        [string]$Mode = 'review',
        [string]$AuthorizedCommands = '[]'
    )

    $head = (& git -C $Root rev-parse HEAD).Trim()
    if ([string]::IsNullOrWhiteSpace($PathSessionId)) { $PathSessionId = $SessionId }
    $requestDirectory = Join-Path $Root ".chat-mode\exchange\$PathSessionId"
    [void](New-Item -ItemType Directory -Force -Path $requestDirectory)
    $requestPath = Join-Path $requestDirectory "turn-$TurnId.request.md"
    $content = @"
---
protocol: chat-mode/v2
session_id: $SessionId
turn_id: $TurnId
orchestrator: codex
worker: claude
transport: claude-cli
intent: smoke-test
mode: $Mode
permission: read-only
authority: delegated
approval_policy: cli-supervised
edit_mode: dont-ask
repo_root: $Root
repo_branch: main
repo_head: $head
write_scope: []
authorized_actions:
  - read-project
authorized_commands: $AuthorizedCommands
git_authority: read-only
network_authority: $NetworkAuthority
credential_authority: none
deployment_authority: none
external_paths: []
max_response_bytes: 50000
deadline: 2026-08-17T12:00:00Z
completion_marker: $Marker
---

Return a smoke-test response and the completion marker.
"@
    Set-Content -LiteralPath $requestPath -Value $content -Encoding utf8NoBOM
    $requestPath
}

try {
    [void](New-Item -ItemType Directory -Force -Path $fixture)
    Set-Content -LiteralPath (Join-Path $fixture '.gitignore') -Value ".chat-mode/`n" -Encoding ascii
    Set-Content -LiteralPath (Join-Path $fixture 'README.md') -Value "# fixture`n" -Encoding ascii

    & git -C $fixture init -b main | Out-Null
    & git -C $fixture config user.email 'chat-mode-smoke@example.invalid'
    & git -C $fixture config user.name 'Chat Mode Smoke'
    & git -C $fixture add .gitignore README.md
    & git -C $fixture commit -m 'fixture baseline' | Out-Null

    $fakeClaude = Join-Path $fixture '.chat-mode\fake-claude.ps1'
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakeClaude))
    $fakeContent = @'
param(
    [Parameter(Position = 0)][string]$CommandOrPrompt = '',
    [Parameter(Position = 1)][string]$Subcommand = '',
    [Alias('version')][switch]$ShowVersion,
    [Alias('p')][switch]$Print,
    [Alias('setting-sources')][string]$SettingSources,
    [Alias('strict-mcp-config')][switch]$StrictMcpConfig,
    [Alias('disable-slash-commands')][switch]$DisableSlashCommands,
    [Alias('no-chrome')][switch]$NoChrome,
    [Alias('permission-mode')][string]$PermissionMode,
    [string]$Tools,
    [Alias('allowedTools')][string]$AllowedToolList,
    [Alias('max-turns')][int]$MaxTurns,
    [string]$Effort,
    [Alias('output-format')][string]$OutputFormat,
    [Alias('include-partial-messages')][switch]$IncludePartialMessages,
    [string]$Resume
)

if ($ShowVersion) {
    '2.1.233 (Claude Code)'
    exit 0
}

if ($CommandOrPrompt -eq 'auth' -and $Subcommand -eq 'status') {
    [pscustomobject]@{
        loggedIn = $true
        authMethod = 'claude.ai'
        subscriptionType = 'pro'
    } | ConvertTo-Json -Compress
    exit 0
}

if ($Print) {
    $prompt = $CommandOrPrompt
    if ($prompt -notmatch 'end with ([A-Za-z0-9_-]+)\.') {
        throw 'Marker missing from fake prompt.'
    }
    $marker = $Matches[1]
    if ($Effort -notin @('medium', 'high')) {
        throw "Unexpected effort: $Effort"
    }
    $sessionId = '11111111-1111-4111-8111-111111111111'
    if (-not [string]::IsNullOrWhiteSpace($Resume)) {
        $sessionId = $Resume
    }
    if ($marker -in @('CLI_SMOKE_TIMEOUT_DONE', 'CLI_SMOKE_STOP_DONE', 'CLI_SMOKE_IDLE_WARNING_DONE')) {
        [pscustomobject]@{
            type = 'stream_event'
            event = @{ type = 'message_start' }
            session_id = $sessionId
        } | ConvertTo-Json -Compress -Depth 8
    }
    if ($marker -eq 'CLI_SMOKE_TIMEOUT_DONE') {
        Start-Sleep -Seconds 3
    }
    if ($marker -eq 'CLI_SMOKE_STOP_DONE') {
        [System.IO.File]::WriteAllText((Join-Path (Get-Location) '.chat-mode\STOP'), 'stop')
        Start-Sleep -Seconds 3
    }
    if ($marker -eq 'CLI_SMOKE_IDLE_WARNING_DONE') {
        Start-Sleep -Seconds 2
    }
    if ($marker -eq 'CLI_SMOKE_MALFORMED_DONE') {
        'not-json'
        exit 0
    }
    $isError = $marker -eq 'CLI_SMOKE_ERROR_DONE'
    $result = if ($marker -eq 'CLI_SMOKE_MISSING_MARKER_DONE') {
        'fake response without completion marker'
    }
    elseif ($isError) {
        'fake Claude failure'
    }
    elseif ($marker -eq 'CLI_SMOKE_TOO_LARGE_DONE') {
        ('x' * 256) + "`n$marker"
    }
    else {
        "fake response`n$marker"
    }
    if ($marker -eq 'CLI_SMOKE_FLOW_LIST_DONE' -and $AllowedToolList.Split(',') -notcontains 'Bash(test-command)') {
        throw 'Inline authorized command was not exposed as an allowed Bash rule.'
    }
    [pscustomobject]@{
        type = 'stream_event'
        event = @{
            type = 'content_block_start'
            content_block = @{ type = 'tool_use'; name = 'Read'; id = 'fake-read' }
        }
        session_id = $sessionId
    } | ConvertTo-Json -Compress -Depth 8
    [pscustomobject]@{
        type = 'stream_event'
        event = @{
            type = 'content_block_delta'
            delta = @{ type = 'text_delta'; text = $result }
        }
        session_id = $sessionId
    } | ConvertTo-Json -Compress -Depth 8
    [pscustomobject]@{
        type = 'result'
        subtype = if ($isError) { 'error' } else { 'success' }
        is_error = $isError
        result = $result
        session_id = $sessionId
        usage = @{ input_tokens = 1; output_tokens = 1 }
    } | ConvertTo-Json -Compress
    exit 0
}

throw 'Unexpected fake Claude arguments.'
'@
    Set-Content -LiteralPath $fakeClaude -Value $fakeContent -Encoding utf8NoBOM

    $claudeExe = (Get-Command pwsh).Source
    $prefix = @('-NoProfile', '-File', $fakeClaude)
    $sessionId = 'cli-smoke-session'

    $request1 = Write-Request -Root $fixture -SessionId $sessionId -TurnId '0001' -Marker 'CLI_SMOKE_TURN_1_DONE'
    $run1Text = & $supervisor `
        -Action Invoke `
        -WorkingTree $fixture `
        -RequestPath $request1 `
        -ClaudeExe $claudeExe `
        -ClaudeArgsPrefix $prefix
    $run1 = ($run1Text -join "`n") | ConvertFrom-Json
    if ($run1.stopReason -ne 'completed' -or $run1.resumed) {
        throw 'Initial CLI supervisor run did not complete as a new session.'
    }
    if ($run1.status -ne 'completed' -or $run1.effort -ne 'medium' -or $run1.readToolUseCount -ne 1) {
        throw 'Initial run did not record status, effort, or sanitized tool activity.'
    }

    $request2 = Write-Request -Root $fixture -SessionId $sessionId -TurnId '0002' -Marker 'CLI_SMOKE_TURN_2_DONE'
    $run2Text = & $supervisor `
        -Action Invoke `
        -WorkingTree $fixture `
        -RequestPath $request2 `
        -Resume `
        -ClaudeExe $claudeExe `
        -ClaudeArgsPrefix $prefix
    $run2 = ($run2Text -join "`n") | ConvertFrom-Json
    if ($run2.stopReason -ne 'completed' -or -not $run2.resumed) {
        throw 'Resumed CLI supervisor run did not complete.'
    }
    if ($run2.claudeSessionId -ne $run1.claudeSessionId) {
        throw 'Claude session id was not preserved across resume.'
    }

    $request3 = Write-Request `
        -Root $fixture `
        -SessionId $sessionId `
        -TurnId '0003' `
        -Marker 'CLI_SMOKE_TURN_3_DONE' `
        -NetworkAuthority 'example.com'
    $contractRejected = $false
    try {
        & $supervisor `
            -Action Invoke `
            -WorkingTree $fixture `
            -RequestPath $request3 `
            -Resume `
            -ClaudeExe $claudeExe `
            -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
    }
    catch {
        $contractRejected = $_.Exception.Message -match 'authority contract changed'
    }
    if (-not $contractRejected) {
        throw 'Changed authority contract was not rejected on resume.'
    }

    $timeoutRequest = Write-Request `
        -Root $fixture `
        -SessionId 'cli-smoke-timeout' `
        -TurnId '0001' `
        -Marker 'CLI_SMOKE_TIMEOUT_DONE'
    $timeoutRejected = $false
    try {
        & $supervisor `
            -Action Invoke `
            -WorkingTree $fixture `
            -RequestPath $timeoutRequest `
            -TimeoutSeconds 1 `
            -ClaudeExe $claudeExe `
            -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
    }
    catch {
        $timeoutRejected = $_.Exception.Message -match '^timeout:'
    }
    if (-not $timeoutRejected) {
        throw 'Timed-out worker process was not rejected.'
    }
    $timeoutDirectory = Join-Path $fixture '.chat-mode\sessions\cli-smoke-timeout'
    $timeoutRun = Get-Content -LiteralPath (Join-Path $timeoutDirectory 'turn-0001.run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $timeoutStatus = Get-Content -LiteralPath (Join-Path $timeoutDirectory 'turn-0001.status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $timeoutState = Get-Content -LiteralPath (Join-Path $timeoutDirectory 'claude-cli-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($timeoutRun.status -ne 'failed' -or $timeoutRun.stopReason -ne 'timeout' -or
        $timeoutStatus.state -ne 'stopped-timeout' -or [bool]$timeoutState.resumable -or
        [string]::IsNullOrWhiteSpace([string]$timeoutRun.claudeSessionId) -or [bool]$timeoutRun.claudeSessionIdValidated) {
        throw 'Timeout failure artifacts were incomplete or resumable.'
    }
    $timeoutResumeRequest = Write-Request `
        -Root $fixture `
        -SessionId 'cli-smoke-timeout' `
        -TurnId '0002' `
        -Marker 'CLI_SMOKE_TIMEOUT_RESUME_DONE'
    $timeoutResumeRejected = $false
    try {
        & $supervisor `
            -Action Invoke `
            -WorkingTree $fixture `
            -RequestPath $timeoutResumeRequest `
            -Resume `
            -ClaudeExe $claudeExe `
            -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
    }
    catch {
        $timeoutResumeRejected = $_.Exception.Message -match 'prior turn did not complete'
    }
    if (-not $timeoutResumeRejected) {
        throw 'Timed-out session was not blocked from resume.'
    }

    $stopRequest = Write-Request `
        -Root $fixture `
        -SessionId 'cli-smoke-stop' `
        -TurnId '0001' `
        -Marker 'CLI_SMOKE_STOP_DONE'
    $stopRejected = $false
    try {
        & $supervisor `
            -Action Invoke `
            -WorkingTree $fixture `
            -RequestPath $stopRequest `
            -TimeoutSeconds 5 `
            -ClaudeExe $claudeExe `
            -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
    }
    catch {
        $stopRejected = $_.Exception.Message -match '^user_stop:'
    }
    Remove-Item -LiteralPath (Join-Path $fixture '.chat-mode\STOP') -Force -ErrorAction SilentlyContinue
    $stopRun = Get-Content -LiteralPath (Join-Path $fixture '.chat-mode\sessions\cli-smoke-stop\turn-0001.run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $stopRejected -or $stopRun.stopReason -ne 'user_stop') {
        throw 'STOP did not produce a durable user_stop failure.'
    }

    $idleRequest = Write-Request `
        -Root $fixture `
        -SessionId 'cli-smoke-idle-warning' `
        -TurnId '0001' `
        -Marker 'CLI_SMOKE_IDLE_WARNING_DONE'
    $idleRunText = & $supervisor `
        -Action Invoke `
        -WorkingTree $fixture `
        -RequestPath $idleRequest `
        -TimeoutSeconds 5 `
        -IdleWarningSeconds 1 `
        -ClaudeExe $claudeExe `
        -ClaudeArgsPrefix $prefix
    $idleRun = ($idleRunText -join "`n") | ConvertFrom-Json
    if ($idleRun.status -ne 'completed' -or $idleRun.idleWarningSeconds -ne 1) {
        throw 'Idle warning incorrectly terminated an otherwise successful turn.'
    }

    $mismatchRequest = Write-Request `
        -Root $fixture `
        -SessionId 'declared-session' `
        -PathSessionId 'path-session' `
        -TurnId '0001' `
        -Marker 'CLI_SMOKE_PATH_MISMATCH_DONE'
    $pathMismatchRejected = $false
    try {
        & $supervisor `
            -Action Invoke `
            -WorkingTree $fixture `
            -RequestPath $mismatchRequest `
            -ClaudeExe $claudeExe `
            -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
    }
    catch {
        $pathMismatchRejected = $_.Exception.Message -match 'must exactly match frontmatter session_id'
    }
    if (-not $pathMismatchRejected) {
        throw 'Mismatched request-path and frontmatter sessions were not rejected.'
    }

    $flowRequest = Write-Request `
        -Root $fixture `
        -SessionId 'cli-smoke-flow-list' `
        -TurnId '0001' `
        -Marker 'CLI_SMOKE_FLOW_LIST_DONE' `
        -Mode 'isolated-implementer' `
        -AuthorizedCommands '[test-command]'
    $flowRunText = & $supervisor `
        -Action Invoke `
        -WorkingTree $fixture `
        -RequestPath $flowRequest `
        -ClaudeEffort high `
        -ClaudeExe $claudeExe `
        -ClaudeArgsPrefix $prefix
    $flowRun = ($flowRunText -join "`n") | ConvertFrom-Json
    if ($flowRun.stopReason -ne 'completed' -or $flowRun.effort -ne 'high') {
        throw 'Flow-style authorized command or explicit high effort was not applied.'
    }

    $negativeCases = @(
        @{ Session = 'cli-smoke-malformed'; Marker = 'CLI_SMOKE_MALFORMED_DONE'; Error = 'malformed_response'; MaxBytes = 50000 },
        @{ Session = 'cli-smoke-missing-marker'; Marker = 'CLI_SMOKE_MISSING_MARKER_DONE'; Error = 'malformed_response'; MaxBytes = 50000 },
        @{ Session = 'cli-smoke-error'; Marker = 'CLI_SMOKE_ERROR_DONE'; Error = 'claude_error'; MaxBytes = 50000 },
        @{ Session = 'cli-smoke-too-large'; Marker = 'CLI_SMOKE_TOO_LARGE_DONE'; Error = 'response_too_large'; MaxBytes = 64 }
    )
    foreach ($case in $negativeCases) {
        $negativeRequest = Write-Request `
            -Root $fixture `
            -SessionId $case.Session `
            -TurnId '0001' `
            -Marker $case.Marker
        $rejected = $false
        try {
            & $supervisor `
                -Action Invoke `
                -WorkingTree $fixture `
                -RequestPath $negativeRequest `
                -MaxResponseBytes $case.MaxBytes `
                -ClaudeExe $claudeExe `
                -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
        }
        catch {
            $rejected = $_.Exception.Message -match ('^' + [regex]::Escape($case.Error) + ':')
        }
        if (-not $rejected) {
            throw "Negative case was not rejected as $($case.Error): $($case.Marker)"
        }
        $negativeRunPath = Join-Path $fixture ".chat-mode\sessions\$($case.Session)\turn-0001.run.json"
        $negativeRun = Get-Content -LiteralPath $negativeRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($negativeRun.status -ne 'failed' -or $negativeRun.stopReason -ne $case.Error) {
            throw "Negative case did not write a durable $($case.Error) run record."
        }
    }

    $response1 = Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0001.response.md"
    $response2 = Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0002.response.md"
    $live1 = Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0001.live.md"
    if (-not (Test-Path -LiteralPath $response1) -or
        -not (Test-Path -LiteralPath $response2) -or
        -not (Test-Path -LiteralPath $live1)) {
        throw 'Expected response artifacts were not written.'
    }
    $liveText = Get-Content -LiteralPath $live1 -Raw -Encoding UTF8
    if ($liveText -notmatch 'fake response' -or $liveText -notmatch 'CLI_SMOKE_TURN_1_DONE') {
        throw 'Live response artifact did not contain streamed text deltas.'
    }
    $viewerText = (& $viewer `
        -RequestPath $request1 `
        -LivePath $live1 `
        -RunPath (Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0001.run.json") `
        -StatusPath (Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0001.status.json") `
        -ParentProcessId 0 `
        -HoldSeconds 1 `
        -NoClear 6>&1) -join "`n"
    if ($viewerText -notmatch 'CODEX -> CLAUDE' -or $viewerText -notmatch 'TURN 0001 COMPLETE') {
        throw 'Viewer did not render the request-first completed state.'
    }
    $timeoutViewerText = (& $viewer `
        -RequestPath $timeoutRequest `
        -LivePath (Join-Path $timeoutDirectory 'turn-0001.live.md') `
        -RunPath (Join-Path $timeoutDirectory 'turn-0001.run.json') `
        -StatusPath (Join-Path $timeoutDirectory 'turn-0001.status.json') `
        -ParentProcessId 0 `
        -HoldSeconds 1 `
        -NoClear 6>&1) -join "`n"
    if ($timeoutViewerText -notmatch 'TURN 0001 STOPPED: TIMEOUT') {
        throw 'Viewer did not render the sanitized timeout state.'
    }

    $status = (& git -C $fixture status --porcelain=v1 --untracked-files=all) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "Fixture Git status changed: $status"
    }

    [pscustomobject]@{
        Passed = $true
        InitialCompleted = $true
        ResumeCompleted = $true
        SameClaudeSession = $true
        ContractChangeRejected = $true
        TimeoutRejected = $true
        TimeoutArtifactsWritten = $true
        TimeoutResumeRejected = $true
        StopArtifactsWritten = $true
        IdleWarningDidNotKill = $true
        PathSessionMismatchRejected = $true
        FlowStyleListParsed = $true
        MalformedResponseRejected = $true
        MissingMarkerRejected = $true
        ClaudeErrorRejected = $true
        ResponseTooLargeRejected = $true
        LiveArtifactWritten = $true
        ViewerStatesRendered = $true
        GitStatusClean = $true
    } | ConvertTo-Json -Depth 4
}
finally {
    $resolvedFixture = [System.IO.Path]::GetFullPath($fixture)
    $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedFixture.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
