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

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$CodexSandbox = 'workspace-write',

    [Nullable[bool]]$CodexBypassSandbox = $null,

    [int]$TimeoutSeconds = 300,

    [string]$CodexExe = '',

    [string]$ClaudeExe = '',

    [ValidateSet('', 'local', 'ssh')]
    [string]$CodexTransport = '',

    [ValidateSet('', 'local', 'ssh')]
    [string]$ClaudeTransport = '',

    [string]$CodexRemoteHost = '',

    [string]$CodexRemoteRepoPath = '',

    [string]$CodexRemoteExe = '',

    [string]$CodexRemoteTmpPath = '',

    [string]$ClaudeRemoteHost = '',

    [string]$ClaudeRemoteRepoPath = '',

    [string]$ClaudeRemoteExe = '',

    [string]$ClaudeRemoteTmpPath = '',

    [string]$SshExe = '',

    [int]$RemoteConnectTimeoutSeconds = 10,

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

if ($RemoteConnectTimeoutSeconds -le 0) {
    throw 'RemoteConnectTimeoutSeconds must be greater than 0.'
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

function ConvertTo-RemoteRelativePath {
    param([string]$MaybeRelativePath)
    return $MaybeRelativePath.Replace('\', '/')
}

function ConvertTo-PowerShellSingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-PosixShellSingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function New-RemotePwshCommand {
    param([string]$ScriptText)
    return 'pwsh -NoProfile -Command ' + (ConvertTo-PosixShellSingleQuoted -Value $ScriptText)
}

function Get-PropertyValue {
    param(
        [pscustomobject]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }

    return $DefaultValue
}

function Get-ConfiguredValue {
    param(
        [pscustomobject]$Config,
        [string]$ExplicitValue,
        [string]$ConfigProperty,
        [string]$DefaultValue = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
        return $ExplicitValue
    }

    $configured = Get-PropertyValue -Object $Config -Name $ConfigProperty -DefaultValue ''
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return $configured
    }

    return $DefaultValue
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
        [string]$SessionText,
        [string]$WorkerRepoPath = $RepoPath,
        [string]$WorkerSessionRelative = '',
        [string]$WorkerStateRelative = ''
    )

    $sessionRelative = if ([string]::IsNullOrWhiteSpace($WorkerSessionRelative)) { $State.session_file } else { $WorkerSessionRelative }
    $stateRelative = if ([string]::IsNullOrWhiteSpace($WorkerStateRelative)) { Get-RelativePath -RootPath $RepoPath -FullPath $StatePath } else { $WorkerStateRelative }
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
$WorkerRepoPath

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

function Invoke-CapturedProcess {
    param(
        [string]$ExePath,
        [string[]]$ToolArgs,
        [string]$WorkingDirectory,
        [string]$StdoutPath,
        [string]$StderrPath,
        [int]$TimeoutSecondsValue,
        [AllowNull()]
        [string]$StdinText = $null,
        [hashtable]$EnvironmentRemovals = @{}
    )

    $invocation = Get-ProcessInvocation -ExePath $ExePath -ToolArgs $ToolArgs
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $invocation.FileName
    foreach ($arg in $invocation.Arguments) {
        [void]$startInfo.ArgumentList.Add($arg)
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $null -ne $StdinText
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($null -ne $StdinText) {
        $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    }

    foreach ($name in $EnvironmentRemovals.Keys) {
        if ($startInfo.EnvironmentVariables.ContainsKey($name)) {
            $startInfo.EnvironmentVariables.Remove($name)
        }
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()

    if ($null -ne $StdinText) {
        $process.StandardInput.Write($StdinText)
        $process.StandardInput.Close()
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSecondsValue * 1000)
    if (-not $finished) {
        try {
            $process.Kill($true)
        }
        catch {
        }
        throw "Process timed out after $TimeoutSecondsValue seconds: $ExePath"
    }

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if (-not [string]::IsNullOrWhiteSpace($StdoutPath)) {
        Set-Content -LiteralPath $StdoutPath -Encoding utf8 -Value $stdout
    }
    if (-not [string]::IsNullOrWhiteSpace($StderrPath)) {
        Set-Content -LiteralPath $StderrPath -Encoding utf8 -Value $stderr
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Invoke-LocalWorker {
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
        if ($script:EffectiveCodexBypassSandbox) {
            $invocation = Get-ProcessInvocation -ExePath $script:CodexPath -ToolArgs @(
                '--dangerously-bypass-approvals-and-sandbox',
                'exec',
                '-C', $RepoPath,
                $Prompt
            )
        }
        else {
            $invocation = Get-ProcessInvocation -ExePath $script:CodexPath -ToolArgs @(
                '--ask-for-approval', 'never',
                'exec',
                '-C', $RepoPath,
                '--sandbox', $CodexSandbox,
                $Prompt
            )
        }
    }

    $envRemovals = @{}
    if ($Agent -eq 'claude') {
        $envRemovals.CLAUDECODE = $true
    }

    try {
        return Invoke-CapturedProcess `
            -ExePath $invocation.FileName `
            -ToolArgs $invocation.Arguments `
            -WorkingDirectory $RepoPath `
            -StdoutPath $StdoutPath `
            -StderrPath $StderrPath `
            -TimeoutSecondsValue $TimeoutSeconds `
            -EnvironmentRemovals $envRemovals
    }
    catch {
        if ($_.Exception.Message -like 'Process timed out*') {
            throw "$Agent worker timed out after $TimeoutSeconds seconds."
        }
        throw
    }
}

function Invoke-RemoteSshCommand {
    param(
        [pscustomobject]$RemoteConfig,
        [string]$Command,
        [AllowNull()]
        [string]$StdinText = $null,
        [int]$TimeoutSecondsValue = $TimeoutSeconds,
        [string]$StdoutPath = '',
        [string]$StderrPath = ''
    )

    $args = @(
        '-T',
        '-oBatchMode=yes',
        "-oConnectTimeout=$($RemoteConfig.ConnectTimeoutSeconds)",
        $RemoteConfig.Host,
        $Command
    )

    return Invoke-CapturedProcess `
        -ExePath $script:SshPath `
        -ToolArgs $args `
        -WorkingDirectory $RepoPath `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath `
        -TimeoutSecondsValue $TimeoutSecondsValue `
        -StdinText $StdinText
}

function Invoke-RemotePwsh {
    param(
        [pscustomobject]$RemoteConfig,
        [string]$ScriptText,
        [AllowNull()]
        [string]$StdinText = $null,
        [int]$TimeoutSecondsValue = $TimeoutSeconds,
        [string]$StdoutPath = '',
        [string]$StderrPath = ''
    )

    return Invoke-RemoteSshCommand `
        -RemoteConfig $RemoteConfig `
        -Command (New-RemotePwshCommand -ScriptText $ScriptText) `
        -StdinText $StdinText `
        -TimeoutSecondsValue $TimeoutSecondsValue `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath
}

function Get-RemotePathPrelude {
    return @'
function Resolve-ChatModeRemotePath {
    param([string]$Path)
    if ($Path -eq '~') {
        return $HOME
    }
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) {
        return Join-Path $HOME $Path.Substring(2)
    }
    return $Path
}
'@
}

function Join-RemotePath {
    param(
        [string]$Directory,
        [string]$Leaf
    )
    return ($Directory.TrimEnd('/', '\') + '/' + $Leaf)
}

function ConvertTo-Base64Utf8 {
    param([string]$Content)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Content))
}

function Invoke-RemoteStageFile {
    param(
        [pscustomobject]$RemoteConfig,
        [string]$RemotePath,
        [string]$Content
    )

    $script = (Get-RemotePathPrelude) + @"
`$target = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $RemotePath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent `$target) | Out-Null
`$base64 = ([Console]::In.ReadToEnd()).Trim().TrimStart([char]0xFEFF)
`$bytes = [Convert]::FromBase64String(`$base64)
[System.IO.File]::WriteAllBytes(`$target, `$bytes)
"@

    $result = Invoke-RemotePwsh -RemoteConfig $RemoteConfig -ScriptText $script -StdinText (ConvertTo-Base64Utf8 -Content $Content)
    if ($result.ExitCode -ne 0) {
        throw "Remote staging failed on $($RemoteConfig.Host): $($result.Stderr.Trim())"
    }
}

function Get-RemoteGitStatus {
    param([pscustomobject]$RemoteConfig)

    $script = (Get-RemotePathPrelude) + @"
`$repo = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $RemoteConfig.RepoPath)
& git -C `$repo status --porcelain
exit `$LASTEXITCODE
"@
    $result = Invoke-RemotePwsh -RemoteConfig $RemoteConfig -ScriptText $script -TimeoutSecondsValue $RemoteConnectTimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "Remote git status failed on $($RemoteConfig.Host): $($result.Stderr.Trim())"
    }
    return $result.Stdout.Trim()
}

function Test-LocalCleanForRemote {
    $status = Get-GitStatusShort
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "Remote SSH mode requires a clean local worktree before worker execution. Current status:`n$status"
    }
}

function Test-RemoteWorkerPreflight {
    param(
        [string]$Agent,
        [pscustomobject]$RemoteConfig
    )

    if ($script:RemotePreflightDone.ContainsKey($Agent)) {
        return
    }

    Test-LocalCleanForRemote

    $reachability = Invoke-RemoteSshCommand -RemoteConfig $RemoteConfig -Command 'exit' -TimeoutSecondsValue $RemoteConnectTimeoutSeconds
    if ($reachability.ExitCode -ne 0) {
        throw "SSH preflight failed for $Agent on $($RemoteConfig.Host): $($reachability.Stderr.Trim())"
    }

    $script = (Get-RemotePathPrelude) + @"
`$version = `$PSVersionTable.PSVersion
if (`$version -lt [version]'7.6.1') {
    Write-Error "Remote pwsh 7.6.1 or newer is required. Found `$version."
    exit 2
}

`$repo = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $RemoteConfig.RepoPath)
if (-not (Test-Path -LiteralPath `$repo)) {
    Write-Error "Remote repo path does not exist: `$repo"
    exit 3
}

`$head = (& git -C `$repo rev-parse HEAD 2>&1 | ForEach-Object { `$_.ToString() }) -join [Environment]::NewLine
if (`$LASTEXITCODE -ne 0) {
    Write-Error `$head
    exit 4
}
if (`$head.Trim() -ne $(ConvertTo-PowerShellSingleQuoted -Value $script:LocalHead)) {
    Write-Error "Remote HEAD mismatch. Local=$script:LocalHead Remote=`$(`$head.Trim())"
    exit 5
}

`$status = (& git -C `$repo status --porcelain 2>&1 | ForEach-Object { `$_.ToString() }) -join [Environment]::NewLine
if (`$LASTEXITCODE -ne 0) {
    Write-Error `$status
    exit 6
}
if (-not [string]::IsNullOrWhiteSpace(`$status)) {
    Write-Error "Remote worktree is not clean:`n`$status"
    exit 7
}

`$exe = $(ConvertTo-PowerShellSingleQuoted -Value $RemoteConfig.Exe)
`$command = Get-Command `$exe -ErrorAction SilentlyContinue
if (-not `$command) {
    Write-Error "Remote worker executable not found: `$exe"
    exit 8
}

`$tmp = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $RemoteConfig.TmpPath)
New-Item -ItemType Directory -Force -Path `$tmp | Out-Null
`$probe = Join-Path `$tmp 'chat-mode-probe.txt'
Set-Content -LiteralPath `$probe -Encoding utf8 -Value 'ok'
Remove-Item -LiteralPath `$probe -Force
exit 0
"@

    $result = Invoke-RemotePwsh -RemoteConfig $RemoteConfig -ScriptText $script -TimeoutSecondsValue $RemoteConnectTimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "Remote preflight failed for $Agent on $($RemoteConfig.Host): $($result.Stderr.Trim())"
    }

    $script:RemotePreflightDone[$Agent] = $true
}

function Invoke-RemoteWorker {
    param(
        [string]$Agent,
        [string]$Prompt,
        [string]$SessionText,
        [pscustomobject]$State,
        [string]$StdoutPath,
        [string]$StderrPath,
        [pscustomobject]$RemoteConfig
    )

    Test-RemoteWorkerPreflight -Agent $Agent -RemoteConfig $RemoteConfig

    $sessionStem = [System.IO.Path]::GetFileNameWithoutExtension($State.session_file)
    $promptRemotePath = Join-RemotePath -Directory $RemoteConfig.TmpPath -Leaf "$sessionStem-$Agent-$($State.current_turn + 1)-prompt.md"
    $stateRemotePath = ConvertTo-RemoteRelativePath -MaybeRelativePath (Get-RelativePath -RootPath $RepoPath -FullPath $StatePath)
    $sessionRemotePath = ConvertTo-RemoteRelativePath -MaybeRelativePath $State.session_file
    $stateJson = $State | ConvertTo-Json -Depth 8

    Invoke-RemoteStageFile -RemoteConfig $RemoteConfig -RemotePath $promptRemotePath -Content $Prompt
    Invoke-RemoteStageFile -RemoteConfig $RemoteConfig -RemotePath (Join-RemotePath -Directory $RemoteConfig.RepoPath -Leaf $stateRemotePath) -Content $stateJson
    Invoke-RemoteStageFile -RemoteConfig $RemoteConfig -RemotePath (Join-RemotePath -Directory $RemoteConfig.RepoPath -Leaf $sessionRemotePath) -Content $SessionText
    $statusBeforeWorker = Get-RemoteGitStatus -RemoteConfig $RemoteConfig

    $toolArgsExpression = if ($Agent -eq 'claude') {
        "@('-p', '--tools', 'Read,Glob,Grep', '--allowedTools', 'Read,Glob,Grep', '--permission-mode', 'dontAsk', '--output-format', 'text', `$prompt)"
    }
    elseif ($script:EffectiveRemoteCodexBypassSandbox) {
        "@('--dangerously-bypass-approvals-and-sandbox', 'exec', '-C', `$repo, `$prompt)"
    }
    else {
        "@('--ask-for-approval', 'never', 'exec', '-C', `$repo, '--sandbox', $(ConvertTo-PowerShellSingleQuoted -Value $CodexSandbox), `$prompt)"
    }

    $script = (Get-RemotePathPrelude) + @"
`$repo = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $RemoteConfig.RepoPath)
`$promptPath = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $promptRemotePath)
`$prompt = [System.IO.File]::ReadAllText(`$promptPath, [System.Text.Encoding]::UTF8)
Set-Location -LiteralPath `$repo
`$exe = $(ConvertTo-PowerShellSingleQuoted -Value $RemoteConfig.Exe)
`$toolArgs = $toolArgsExpression
& `$exe @toolArgs
exit `$LASTEXITCODE
"@

    $cleanupScript = (Get-RemotePathPrelude) + @"
`$promptPath = Resolve-ChatModeRemotePath $(ConvertTo-PowerShellSingleQuoted -Value $promptRemotePath)
Remove-Item -LiteralPath `$promptPath -Force -ErrorAction SilentlyContinue
exit 0
"@

    try {
        $result = Invoke-RemotePwsh `
            -RemoteConfig $RemoteConfig `
            -ScriptText $script `
            -TimeoutSecondsValue $TimeoutSeconds `
            -StdoutPath $StdoutPath `
            -StderrPath $StderrPath

        $statusAfterWorker = Get-RemoteGitStatus -RemoteConfig $RemoteConfig
    }
    finally {
        try {
            [void](Invoke-RemotePwsh -RemoteConfig $RemoteConfig -ScriptText $cleanupScript -TimeoutSecondsValue $RemoteConnectTimeoutSeconds)
        }
        catch {
        }
    }

    if ($statusAfterWorker -ne $statusBeforeWorker) {
        $beforeText = if ([string]::IsNullOrWhiteSpace($statusBeforeWorker)) { '<clean>' } else { $statusBeforeWorker }
        $afterText = if ([string]::IsNullOrWhiteSpace($statusAfterWorker)) { '<clean>' } else { $statusAfterWorker }
        throw "$Agent remote worker changed remote workspace status on $($RemoteConfig.Host):`nBefore:`n$beforeText`nAfter:`n$afterText"
    }

    return $result
}

function Invoke-Worker {
    param(
        [string]$Agent,
        [string]$Prompt,
        [string]$SessionText,
        [pscustomobject]$State,
        [string]$StdoutPath,
        [string]$StderrPath
    )

    $transport = if ($Agent -eq 'codex') { $script:CodexTransport } else { $script:ClaudeTransport }
    if ($transport -eq 'ssh') {
        $remoteConfig = if ($Agent -eq 'codex') { $script:CodexRemoteConfig } else { $script:ClaudeRemoteConfig }
        return Invoke-RemoteWorker `
            -Agent $Agent `
            -Prompt $Prompt `
            -SessionText $SessionText `
            -State $State `
            -StdoutPath $StdoutPath `
            -StderrPath $StderrPath `
            -RemoteConfig $remoteConfig
    }

    return Invoke-LocalWorker -Agent $Agent -Prompt $Prompt -StdoutPath $StdoutPath -StderrPath $StderrPath
}

function Get-WorkerStopReason {
    param(
        [string]$Agent,
        [string]$Message
    )

    if ($Message -like '*timed out*') {
        return "${Agent}_timeout"
    }

    if ($Message -like 'SSH preflight failed*' -or $Message -like 'Remote preflight failed*') {
        return "${Agent}_remote_preflight_error"
    }

    if ($Message -like 'Remote staging failed*') {
        return "${Agent}_remote_staging_error"
    }

    if ($Message -like '*changed remote workspace status*') {
        return "${Agent}_remote_mutation"
    }

    return "${Agent}_error"
}

function Get-GitDiffStat {
    $output = & git -C $RepoPath diff --stat 2>&1
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

function Get-GitStatusShort {
    $output = & git -C $RepoPath status --short 2>&1
    return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

function Get-GitHead {
    $output = & git -C $RepoPath rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read local git HEAD: $((($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim())"
    }
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
        codex_sandbox = $CodexSandbox
        codex_bypass_sandbox = $script:EffectiveCodexBypassSandbox
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

function New-RemoteWorkerConfig {
    param(
        [string]$Agent,
        [string]$RemoteHost,
        [string]$RemoteRepoPath,
        [string]$RemoteExe,
        [string]$RemoteTmpPath,
        [string]$DefaultExe
    )

    if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
        throw "$Agent SSH transport requires a remote host."
    }

    if ([string]::IsNullOrWhiteSpace($RemoteRepoPath)) {
        throw "$Agent SSH transport requires a remote repo path."
    }

    if ([string]::IsNullOrWhiteSpace($RemoteExe)) {
        $RemoteExe = $DefaultExe
    }

    if ([string]::IsNullOrWhiteSpace($RemoteTmpPath)) {
        $RemoteTmpPath = '~/.chat-mode-tmp'
    }

    return [pscustomobject]@{
        Agent = $Agent
        Host = $RemoteHost
        RepoPath = $RemoteRepoPath
        Exe = $RemoteExe
        TmpPath = $RemoteTmpPath
        ConnectTimeoutSeconds = $RemoteConnectTimeoutSeconds
    }
}

function Get-WorkerTransport {
    param([string]$Agent)
    if ($Agent -eq 'codex') {
        return $script:CodexTransport
    }
    return $script:ClaudeTransport
}

function Get-WorkerRemoteConfig {
    param([string]$Agent)
    if ($Agent -eq 'codex') {
        return $script:CodexRemoteConfig
    }
    return $script:ClaudeRemoteConfig
}

$config = Read-ChatModeConfig
$script:CodexTransport = Get-ConfiguredValue -Config $config -ExplicitValue $CodexTransport -ConfigProperty 'codex_transport' -DefaultValue 'local'
$script:ClaudeTransport = Get-ConfiguredValue -Config $config -ExplicitValue $ClaudeTransport -ConfigProperty 'claude_transport' -DefaultValue 'local'
if ($script:CodexTransport -notin @('local', 'ssh')) {
    throw "Invalid codex transport: $script:CodexTransport"
}
if ($script:ClaudeTransport -notin @('local', 'ssh')) {
    throw "Invalid claude transport: $script:ClaudeTransport"
}
$script:UseSshTransport = $script:CodexTransport -eq 'ssh' -or $script:ClaudeTransport -eq 'ssh'

if ($script:CodexTransport -eq 'local') {
    $script:CodexPath = Get-ConfiguredExe -Config $config -ExplicitValue $CodexExe -ConfigProperty 'codex_exe' -CommandName 'codex'
}
else {
    $script:CodexPath = $null
}

if ($script:ClaudeTransport -eq 'local') {
    $script:ClaudePath = Get-ConfiguredExe -Config $config -ExplicitValue $ClaudeExe -ConfigProperty 'claude_exe' -CommandName 'claude'
}
else {
    $script:ClaudePath = $null
}

if ($script:UseSshTransport) {
    $script:SshPath = Get-ConfiguredExe -Config $config -ExplicitValue $SshExe -ConfigProperty 'ssh_exe' -CommandName 'ssh'
}
else {
    $script:SshPath = $null
}
$isWindowsPlatform = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $IsWindows } else { $true }
$script:EffectiveCodexBypassSandbox = if ($null -eq $CodexBypassSandbox) { $isWindowsPlatform } else { [bool]$CodexBypassSandbox }
$script:EffectiveRemoteCodexBypassSandbox = if ($null -eq $CodexBypassSandbox) { $false } else { [bool]$CodexBypassSandbox }
$script:LocalHead = if ($script:UseSshTransport) { Get-GitHead } else { '' }
$script:RemotePreflightDone = @{}

$script:CodexRemoteConfig = $null
if ($script:CodexTransport -eq 'ssh') {
    $script:CodexRemoteConfig = New-RemoteWorkerConfig `
        -Agent 'codex' `
        -RemoteHost (Get-ConfiguredValue -Config $config -ExplicitValue $CodexRemoteHost -ConfigProperty 'codex_remote_host') `
        -RemoteRepoPath (Get-ConfiguredValue -Config $config -ExplicitValue $CodexRemoteRepoPath -ConfigProperty 'codex_remote_repo_path') `
        -RemoteExe (Get-ConfiguredValue -Config $config -ExplicitValue $CodexRemoteExe -ConfigProperty 'codex_remote_exe') `
        -RemoteTmpPath (Get-ConfiguredValue -Config $config -ExplicitValue $CodexRemoteTmpPath -ConfigProperty 'codex_remote_tmp_path') `
        -DefaultExe 'codex'
}

$script:ClaudeRemoteConfig = $null
if ($script:ClaudeTransport -eq 'ssh') {
    $script:ClaudeRemoteConfig = New-RemoteWorkerConfig `
        -Agent 'claude' `
        -RemoteHost (Get-ConfiguredValue -Config $config -ExplicitValue $ClaudeRemoteHost -ConfigProperty 'claude_remote_host') `
        -RemoteRepoPath (Get-ConfiguredValue -Config $config -ExplicitValue $ClaudeRemoteRepoPath -ConfigProperty 'claude_remote_repo_path') `
        -RemoteExe (Get-ConfiguredValue -Config $config -ExplicitValue $ClaudeRemoteExe -ConfigProperty 'claude_remote_exe') `
        -RemoteTmpPath (Get-ConfiguredValue -Config $config -ExplicitValue $ClaudeRemoteTmpPath -ConfigProperty 'claude_remote_tmp_path') `
        -DefaultExe 'claude'
}

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
    $transport = Get-WorkerTransport -Agent $agent
    $remoteConfig = if ($transport -eq 'ssh') { Get-WorkerRemoteConfig -Agent $agent } else { $null }
    $workerRepoPath = if ($transport -eq 'ssh') { $remoteConfig.RepoPath } else { $RepoPath }
    $workerSessionRelative = if ($transport -eq 'ssh') { ConvertTo-RemoteRelativePath -MaybeRelativePath $state.session_file } else { '' }
    $workerStateRelative = if ($transport -eq 'ssh') { ConvertTo-RemoteRelativePath -MaybeRelativePath (Get-RelativePath -RootPath $RepoPath -FullPath $StatePath) } else { '' }
    $prompt = New-WorkerPrompt `
        -Agent $agent `
        -RoundNumber $roundNumber `
        -State $state `
        -SessionText $sessionText `
        -WorkerRepoPath $workerRepoPath `
        -WorkerSessionRelative $workerSessionRelative `
        -WorkerStateRelative $workerStateRelative
    $stdoutPath = Join-Path $tmpDir "$roundNumber-$agent-stdout.txt"
    $stderrPath = Join-Path $tmpDir "$roundNumber-$agent-stderr.txt"
    $diffBefore = Get-GitDiffStat
    $statusBefore = Get-GitStatusShort

    try {
        $result = Invoke-Worker -Agent $agent -Prompt $prompt -SessionText $sessionText -State $state -StdoutPath $stdoutPath -StderrPath $stderrPath
    }
    catch {
        $state.status = 'interrupted'
        $state.current_agent = 'user'
        $state.stop_reason = Get-WorkerStopReason -Agent $agent -Message $_.Exception.Message
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
    $codexSandboxSummary = 'n/a'
    if ($agent -eq 'codex') {
        $codexBypassForLog = if ($transport -eq 'ssh') { $script:EffectiveRemoteCodexBypassSandbox } else { $script:EffectiveCodexBypassSandbox }
        $codexSandboxSummary = if ($codexBypassForLog) { 'bypass' } else { $CodexSandbox }
    }
    $roundText = @"
## Round $roundNumber - $($agent.Substring(0,1).ToUpperInvariant() + $agent.Substring(1))

Invocation:
- mode: orchestrated
- orchestrator: $OrchestratorAgent
- worker: $agent
- transport: $transport
- remote_host: $(if ($transport -eq 'ssh') { $remoteConfig.Host } else { 'n/a' })
- permission_profile: $PermissionProfile
- timeout_seconds: $TimeoutSeconds
- codex_sandbox: $codexSandboxSummary
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
