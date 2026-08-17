[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$supervisor = Join-Path $repoRoot 'skills\chat-mode\scripts\claude-cli-supervisor.ps1'
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
    [Alias('output-format')][string]$OutputFormat,
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
    if ($marker -eq 'CLI_SMOKE_TIMEOUT_DONE') {
        Start-Sleep -Seconds 3
    }
    if ($marker -eq 'CLI_SMOKE_MALFORMED_DONE') {
        'not-json'
        exit 0
    }
    $sessionId = '11111111-1111-4111-8111-111111111111'
    if (-not [string]::IsNullOrWhiteSpace($Resume)) {
        $sessionId = $Resume
    }
    $isError = $marker -eq 'CLI_SMOKE_ERROR_DONE'
    $result = if ($marker -eq 'CLI_SMOKE_MISSING_MARKER_DONE') {
        'fake response without completion marker'
    }
    elseif ($isError) {
        'fake Claude failure'
    }
    else {
        "fake response`n$marker"
    }
    if ($marker -eq 'CLI_SMOKE_FLOW_LIST_DONE' -and $AllowedToolList.Split(',') -notcontains 'Bash(test-command)') {
        throw 'Inline authorized command was not exposed as an allowed Bash rule.'
    }
    [pscustomobject]@{
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
        -ClaudeExe $claudeExe `
        -ClaudeArgsPrefix $prefix
    $flowRun = ($flowRunText -join "`n") | ConvertFrom-Json
    if ($flowRun.stopReason -ne 'completed') {
        throw 'Flow-style authorized command was not parsed.'
    }

    $negativeCases = @(
        @{ Session = 'cli-smoke-malformed'; Marker = 'CLI_SMOKE_MALFORMED_DONE'; Error = 'malformed_response' },
        @{ Session = 'cli-smoke-missing-marker'; Marker = 'CLI_SMOKE_MISSING_MARKER_DONE'; Error = 'malformed_response' },
        @{ Session = 'cli-smoke-error'; Marker = 'CLI_SMOKE_ERROR_DONE'; Error = 'claude_error' }
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
                -ClaudeExe $claudeExe `
                -ClaudeArgsPrefix $prefix 2>&1 | Out-Null
        }
        catch {
            $rejected = $_.Exception.Message -match ('^' + [regex]::Escape($case.Error) + ':')
        }
        if (-not $rejected) {
            throw "Negative case was not rejected as $($case.Error): $($case.Marker)"
        }
    }

    $response1 = Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0001.response.md"
    $response2 = Join-Path $fixture ".chat-mode\sessions\$sessionId\turn-0002.response.md"
    if (-not (Test-Path -LiteralPath $response1) -or -not (Test-Path -LiteralPath $response2)) {
        throw 'Expected response artifacts were not written.'
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
        PathSessionMismatchRejected = $true
        FlowStyleListParsed = $true
        MalformedResponseRejected = $true
        MissingMarkerRejected = $true
        ClaudeErrorRejected = $true
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
