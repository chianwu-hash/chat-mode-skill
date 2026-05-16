param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

#requires -Version 7.6.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runner = Join-Path $RepoRoot 'tools\chat-mode-run.ps1'
if (-not (Test-Path -LiteralPath $runner)) {
    throw "Missing runner script: $runner"
}

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('chat-mode-remote-smoke-' + [guid]::NewGuid().ToString('N'))
$toolDir = Join-Path $fixture 'tools'
$repo = Join-Path $fixture 'repo'
New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
New-Item -ItemType Directory -Force -Path $repo | Out-Null

try {
    & git -C $repo init | Out-Null
    Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Encoding utf8 -Value ".chat-mode/`n"
    Set-Content -LiteralPath (Join-Path $repo 'README.md') -Encoding utf8 -Value '# fixture'
    & git -C $repo add .gitignore README.md | Out-Null
    & git -C $repo -c user.email='smoke@example.test' -c user.name='Smoke Test' commit -m 'init' | Out-Null

    $fakeCodex = Join-Path $toolDir 'codex.ps1'
    $fakeClaude = Join-Path $toolDir 'claude.ps1'
    $fakeSsh = Join-Path $toolDir 'ssh.ps1'

    Set-Content -LiteralPath $fakeCodex -Encoding utf8 -Value @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ToolArgs
)

"Remote Codex worker smoke response. Args: $($ToolArgs -join ' ')"
exit 0
'@

    Set-Content -LiteralPath $fakeClaude -Encoding utf8 -Value @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ToolArgs
)

"Remote Claude worker smoke response. Args: $($ToolArgs.Count)"
exit 0
'@

    Set-Content -LiteralPath $fakeSsh -Encoding utf8 -Value @'
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$T,
    [string]$oBatchMode,
    [string]$oConnectTimeout,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SshArgs
)

# This fake validates runner plumbing and encoded command construction; it does
# not replace a real OpenSSH/POSIX-shell integration test.
function Decode-PosixSingleQuotedCommand {
    param([string]$Command)

    $prefix = "pwsh -NoProfile -Command '"
    if (-not $Command.StartsWith($prefix) -or -not $Command.EndsWith("'")) {
        if ($Command -eq 'exit') {
            return ''
        }
        throw "Unsupported fake ssh command: $Command"
    }

    $inner = $Command.Substring($prefix.Length, $Command.Length - $prefix.Length - 1)
    return $inner.Replace("'\''", "'")
}

$command = $SshArgs[-1]
$script = Decode-PosixSingleQuotedCommand -Command $command
if ([string]::IsNullOrEmpty($script)) {
    exit 0
}

$stdinText = [Console]::In.ReadToEnd()
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = 'pwsh'
$startInfo.ArgumentList.Add('-NoProfile')
$startInfo.ArgumentList.Add('-Command')
$startInfo.ArgumentList.Add($script)
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
$startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void]$process.Start()
$process.StandardInput.Write($stdinText)
$process.StandardInput.Close()
$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
$process.WaitForExit()
[Console]::Out.Write($stdout)
[Console]::Error.Write($stderr)
exit $process.ExitCode
'@

    $configDir = Join-Path $repo '.chat-mode'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    [ordered]@{
        schema_version = 1
        codex_version = 'codex remote smoke'
        claude_version = 'claude remote smoke'
        validated_at = '2026-05-16T00:00:00+08:00'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding utf8

    $result = & $runner `
        -RepoPath $repo `
        -Topic 'remote runner smoke test' `
        -TaskSummary 'remote runner smoke test' `
        -MaxTurns 2 `
        -FirstMover codex `
        -CodexTransport ssh `
        -ClaudeTransport ssh `
        -CodexRemoteHost fake-host `
        -ClaudeRemoteHost fake-host `
        -CodexRemoteRepoPath $repo `
        -ClaudeRemoteRepoPath $repo `
        -CodexRemoteExe $fakeCodex `
        -ClaudeRemoteExe $fakeClaude `
        -CodexRemoteTmpPath (Join-Path $fixture 'remote-tmp') `
        -ClaudeRemoteTmpPath (Join-Path $fixture 'remote-tmp') `
        -SshExe $fakeSsh `
        -NewSession | ConvertFrom-Json

    if ($result.status -ne 'done') {
        throw "Expected done status, got $($result.status)."
    }

    if ($result.current_turn -ne 2) {
        throw "Expected current_turn 2, got $($result.current_turn)."
    }

    $state = Get-Content -LiteralPath (Join-Path $repo '.chat-mode\agent-sync-state.json') -Encoding utf8 -Raw | ConvertFrom-Json
    $sessionPath = Join-Path $repo $state.session_file
    $session = Get-Content -LiteralPath $sessionPath -Encoding utf8 -Raw

    if ($session -notmatch 'Remote Codex worker smoke response') {
        throw 'Missing remote Codex worker output.'
    }

    if ($session -notmatch 'Remote Claude worker smoke response') {
        throw 'Missing remote Claude worker output.'
    }

    if ($session -notmatch 'transport: ssh') {
        throw 'Missing ssh transport metadata.'
    }

    if ($session -match '--dangerously-bypass-approvals-and-sandbox') {
        throw 'Remote Codex should not bypass sandbox unless explicitly requested.'
    }

    if ($session -notmatch '--ask-for-approval never exec') {
        throw 'Remote Codex default invocation should use the non-bypass exec path.'
    }

    'REMOTE_RUN_SMOKE_OK'
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
