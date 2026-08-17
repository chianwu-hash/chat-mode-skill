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
        [string]$StopReason
    )

    [pscustomobject]@{
        ExitCode = $ExitCode
        Stdout = $Stdout
        Stderr = $Stderr
        ElapsedSeconds = $ElapsedSeconds
        StopReason = $StopReason
    }
}

function Invoke-CapturedProcess {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [int]$DeadlineSeconds,
        [string]$StopFile = ''
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
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

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopReason = ''

    while (-not $process.HasExited) {
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

        Start-Sleep -Milliseconds 200
    }

    $process.WaitForExit()
    $timer.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    New-ProcessResult `
        -ExitCode $process.ExitCode `
        -Stdout $stdout `
        -Stderr $stderr `
        -ElapsedSeconds $timer.Elapsed.TotalSeconds `
        -StopReason $stopReason
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

if ($TimeoutSeconds -le 0 -or $MaxResponseBytes -le 0 -or $MaxAgentTurns -le 0) {
    throw 'TimeoutSeconds, MaxResponseBytes, and MaxAgentTurns must be positive.'
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
$transcriptPath = Join-Path $script:WorkingTreePath ".chat-mode\sessions\$sessionId.md"

$claudeSessionId = ''
if ($Resume) {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw 'Cannot resume: Claude CLI session state is missing.'
    }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
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
    '--output-format', 'json'
)
if ($Resume) {
    $claudeArguments += @('--resume', $claudeSessionId)
}
$claudeArguments += $prompt

$processResult = Invoke-CapturedProcess `
    -FileName $script:ClaudePath `
    -Arguments (Get-ClaudeArguments $claudeArguments) `
    -DeadlineSeconds $TimeoutSeconds `
    -StopFile $stopFile

if (-not [string]::IsNullOrWhiteSpace($processResult.StopReason)) {
    throw "$($processResult.StopReason): Claude CLI process stopped."
}

try {
    $claudeResult = $processResult.Stdout | ConvertFrom-Json
}
catch {
    throw "malformed_response: Claude output was not JSON. stderr=$($processResult.Stderr.Trim())"
}

if ($null -eq $claudeResult -or $claudeResult.PSObject.Properties.Name -notcontains 'result') {
    throw "malformed_response: Claude JSON result field is missing. stderr=$($processResult.Stderr.Trim())"
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
    updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
Write-Utf8File -Path $statePath -Content (($stateRecord | ConvertTo-Json -Depth 8) + "`n")
Write-Utf8File -Path $responsePath -Content ($response.TrimEnd() + "`n")

$runRecord = [ordered]@{
    schemaVersion = 1
    sessionId = $sessionId
    turnId = $turnId
    mode = $mode
    resumed = [bool]$Resume
    claudeSessionId = $returnedSessionId
    contractFingerprint = $fingerprint
    requestPath = $normalizedRequest
    responsePath = [System.IO.Path]::GetRelativePath($script:WorkingTreePath, $responsePath).Replace('\', '/')
    elapsedSeconds = [math]::Round($processResult.ElapsedSeconds, 3)
    responseBytes = $responseBytes
    exitCode = $processResult.ExitCode
    stopReason = 'completed'
    gitBefore = $gitBefore
    gitAfter = $gitAfter
    completedAt = [DateTimeOffset]::UtcNow.ToString('o')
}
Write-Utf8File -Path $runPath -Content (($runRecord | ConvertTo-Json -Depth 10) + "`n")

$transcriptEntry = @"

## Turn $turnId - Claude CLI

- mode: $mode
- resumed: $([bool]$Resume)
- claude_session_id: $returnedSessionId
- contract_fingerprint: $fingerprint
- elapsed_seconds: $([math]::Round($processResult.ElapsedSeconds, 3))
- response_bytes: $responseBytes
- stop_reason: completed

$($response.TrimEnd())
"@
Append-Utf8File -Path $transcriptPath -Content $transcriptEntry

$runRecord | ConvertTo-Json -Depth 10
