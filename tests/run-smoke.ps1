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

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('chat-mode-run-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixture | Out-Null

try {
    & git -C $fixture init | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'README.md') -Encoding utf8 -Value '# fixture'
    & git -C $fixture add README.md | Out-Null
    & git -C $fixture -c user.email='smoke@example.test' -c user.name='Smoke Test' commit -m 'init' | Out-Null

    $fakeCodex = Join-Path $fixture 'codex.ps1'
    $fakeClaude = Join-Path $fixture 'claude.ps1'

    Set-Content -LiteralPath $fakeCodex -Encoding utf8 -Value @'
"Codex worker smoke response. Args: $($args.Count)"
exit 0
'@

    Set-Content -LiteralPath $fakeClaude -Encoding utf8 -Value @'
"Claude worker smoke response. Args: $($args.Count)"
exit 0
'@

    $configDir = Join-Path $fixture '.chat-mode'
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    [ordered]@{
        schema_version = 1
        codex_exe = $fakeCodex
        claude_exe = $fakeClaude
        codex_version = 'codex smoke'
        claude_version = 'claude smoke'
        validated_at = '2026-05-16T00:00:00+08:00'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $configDir 'config.json') -Encoding utf8

    $result = & $runner `
        -RepoPath $fixture `
        -Topic 'runner smoke test' `
        -TaskSummary 'runner smoke test' `
        -MaxTurns 4 `
        -FirstMover claude `
        -NewSession | ConvertFrom-Json

    if ($result.status -ne 'done') {
        throw "Expected done status, got $($result.status)."
    }

    if ($result.current_turn -ne 4) {
        throw "Expected current_turn 4, got $($result.current_turn)."
    }

    $statePath = Join-Path $fixture '.chat-mode\agent-sync-state.json'
    $state = Get-Content -LiteralPath $statePath -Encoding utf8 -Raw | ConvertFrom-Json
    if ($state.current_agent -ne 'user') {
        throw "Expected current_agent user, got $($state.current_agent)."
    }

    $sessionPath = Join-Path $fixture $state.session_file
    $session = Get-Content -LiteralPath $sessionPath -Encoding utf8 -Raw
    foreach ($expected in @('Round 1 - Claude', 'Round 2 - Codex', 'Round 3 - Claude', 'Round 4 - Codex')) {
        if ($session -notmatch [regex]::Escape($expected)) {
            throw "Missing session round: $expected"
        }
    }

    if ($session -notmatch 'Claude worker smoke response') {
        throw 'Missing Claude worker output.'
    }

    if ($session -notmatch 'Codex worker smoke response') {
        throw 'Missing Codex worker output.'
    }

    'RUN_SMOKE_OK'
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
