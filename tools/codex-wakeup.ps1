param(
    [ValidateSet('loop', 'chain')]
    [string]$Mode = 'loop',

    [int]$DelaySec = 90,

    [int]$RetryN = 1,

    [int]$MaxRetries = 4,

    [string]$RepoPath = '',

    [string]$StatePath = '',

    [string]$LogDir = '',

    [string]$PromptText = '',

    [ValidateSet('read-only', 'workspace-write', 'danger-full-access')]
    [string]$Sandbox = 'workspace-write'
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

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $RepoPath '.chat-mode\wakeup-logs'
}
elseif (-not [System.IO.Path]::IsPathRooted($LogDir)) {
    $LogDir = Join-Path $RepoPath $LogDir
}

$scriptPath = $MyInvocation.MyCommand.Path
$codexExe = (Get-Command codex -ErrorAction Stop).Source

function New-LogPrefix {
    param(
        [string]$Directory,
        [int]$Retry
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return Join-Path $Directory "retry${Retry}-${stamp}"
}

function Quote-Arg {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Get-ChainCommand {
    param(
        [string]$WakeScriptPath,
        [string]$RootPath,
        [string]$StateFile,
        [string]$Directory,
        [string]$SandboxMode,
        [int]$DelaySeconds,
        [int]$NextRetry,
        [int]$RetryLimit
    )

    $parts = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $WakeScriptPath
        '-Mode'
        'chain'
        '-DelaySec'
        $DelaySeconds
        '-RetryN'
        $NextRetry
        '-MaxRetries'
        $RetryLimit
        '-RepoPath'
        $RootPath
        '-StatePath'
        $StateFile
        '-LogDir'
        $Directory
        '-Sandbox'
        $SandboxMode
    ) | ForEach-Object { "'$_'" }

    return "Start-Process pwsh -WindowStyle Hidden -ArgumentList " + ($parts -join ',')
}

function Get-DefaultPrompt {
    param(
        [string]$CurrentMode,
        [int]$CurrentRetry,
        [int]$RetryLimit,
        [int]$DelaySeconds,
        [string]$RootPath,
        [string]$StateFile,
        [string]$WakeScriptPath,
        [string]$Directory,
        [string]$SandboxMode
    )

    $common = @(
        "[Retry $CurrentRetry/$RetryLimit, ${DelaySeconds}s]"
        "Read the shared state JSON at '$StateFile'."
        "Open the markdown file pointed to by the state's session_file field, resolving relative paths from '$RootPath'."
        "Do not read any handoff file."
        "If status is done or interrupted, stop without changing files."
        "If session_file is missing or unreadable, report the mismatch and stop."
        "If current_agent == codex, continue the chat-mode session from the session file, write the next Codex round, update state, schedule wakeup/polling according to the chat-mode skill, and close if the turn limit is reached."
    )

    if ($CurrentMode -eq 'chain') {
        $chainCommand = Get-ChainCommand -WakeScriptPath $WakeScriptPath -RootPath $RootPath -StateFile $StateFile -Directory $Directory -SandboxMode $SandboxMode -DelaySeconds $DelaySeconds -NextRetry ($CurrentRetry + 1) -RetryLimit $RetryLimit
        $modeLines = @(
            "If current_agent != codex and retry < max, run this PowerShell command in the background before you exit:"
            $chainCommand
            "If current_agent != codex and retry == max, set status=interrupted, stop_reason=codex_timeout, and current_agent=user."
        )
    }
    else {
        $modeLines = @(
            "If current_agent != codex and retry < max, do not change files; just exit so the parent wake script can sleep and retry."
            "If current_agent != codex and retry == max, set status=interrupted, stop_reason=codex_timeout, and current_agent=user."
        )
    }

    return (($common + $modeLines) -join ' ')
}

if (-not (Test-Path -LiteralPath $StatePath)) {
    throw "Missing state file: $StatePath"
}

if ($DelaySec -gt 0) {
    Start-Sleep -Seconds $DelaySec
}

for ($attempt = $RetryN; $attempt -le $MaxRetries; $attempt++) {
    $logPrefix = New-LogPrefix -Directory $LogDir -Retry $attempt
    $stdoutLog = "${logPrefix}-stdout.txt"
    $stderrLog = "${logPrefix}-stderr.txt"

    $prompt = if ([string]::IsNullOrWhiteSpace($PromptText)) {
        Get-DefaultPrompt -CurrentMode $Mode -CurrentRetry $attempt -RetryLimit $MaxRetries -DelaySeconds $DelaySec -RootPath $RepoPath -StateFile $StatePath -WakeScriptPath $scriptPath -Directory $LogDir -SandboxMode $Sandbox
    }
    else {
        $PromptText
    }

    $invokeArgs = @(
        'exec'
        '-C'
        $RepoPath
        '--sandbox'
        $Sandbox
        $prompt
    )

    $argumentLine = (($invokeArgs | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $process = Start-Process -FilePath $codexExe -ArgumentList $argumentLine -WorkingDirectory $RepoPath -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "codex exec failed with exit code $($process.ExitCode). See $stderrLog"
    }

    if (-not [string]::IsNullOrWhiteSpace($PromptText)) {
        break
    }

    $state = Get-Content -LiteralPath $StatePath -Encoding utf8 | ConvertFrom-Json
    if ($state.status -in @('done', 'interrupted')) {
        break
    }

    if ($Mode -eq 'chain') {
        break
    }

    if ($attempt -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySec
    }
}

if (-not [string]::IsNullOrWhiteSpace($PromptText)) {
    exit 0
}

$finalState = Get-Content -LiteralPath $StatePath -Encoding utf8 | ConvertFrom-Json
if ($finalState.status -notin @('done', 'interrupted')) {
    $finalState.status = 'interrupted'
    $finalState.stop_reason = 'codex_timeout'
    $finalState.current_agent = 'user'
    $finalState | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding utf8
}
