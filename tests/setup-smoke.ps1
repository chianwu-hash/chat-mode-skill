param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

#requires -Version 7.6.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$setup = Join-Path $RepoRoot 'tools\chat-mode-setup.ps1'
if (-not (Test-Path -LiteralPath $setup)) {
    throw "Missing setup script: $setup"
}

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('chat-mode-setup-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixture | Out-Null

try {
    $fakeCodex = Join-Path $fixture 'codex.ps1'
    $fakeClaude = Join-Path $fixture 'claude.ps1'

    Set-Content -LiteralPath $fakeCodex -Encoding utf8 -Value @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ToolArgs
)

if ($ToolArgs.Count -ge 1 -and $ToolArgs[0] -eq '--help') {
    'Codex CLI'
    'exec            Run Codex non-interactively'
    '--ask-for-approval <APPROVAL_POLICY>'
    exit 0
}

if ($ToolArgs.Count -ge 2 -and $ToolArgs[0] -eq 'exec' -and $ToolArgs[1] -eq '--help') {
    'Run Codex non-interactively'
    '--sandbox <SANDBOX_MODE>'
    exit 0
}

if ($ToolArgs.Count -ge 1 -and $ToolArgs[0] -eq '--version') {
    'codex-cli smoke'
    exit 0
}

exit 1
'@

    Set-Content -LiteralPath $fakeClaude -Encoding utf8 -Value @'
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ToolArgs
)

if ($ToolArgs.Count -ge 1 -and $ToolArgs[0] -eq '--help') {
    'Claude Code'
    '-p, --print'
    '--permission-mode <mode>'
    exit 0
}

if ($ToolArgs.Count -ge 1 -and $ToolArgs[0] -eq '--version') {
    '2.1.71 (Claude Code smoke)'
    exit 0
}

exit 1
'@

    $result = & $setup -RepoPath $fixture -CodexExe $fakeCodex -ClaudeExe $fakeClaude | ConvertFrom-Json
    $configPath = Join-Path $fixture '.chat-mode\config.json'

    if ($result.status -ne 'ok') {
        throw "Expected setup status ok, got $($result.status)."
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Config file was not created: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Encoding utf8 -Raw | ConvertFrom-Json
    if ($config.codex_exe -ne [System.IO.Path]::GetFullPath($fakeCodex)) {
        throw 'Config codex_exe does not match fake Codex path.'
    }

    if ($config.claude_exe -ne [System.IO.Path]::GetFullPath($fakeClaude)) {
        throw 'Config claude_exe does not match fake Claude path.'
    }

    if ($config.schema_version -ne 1) {
        throw "Expected schema_version 1, got $($config.schema_version)."
    }

    'SETUP_SMOKE_OK'
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
