param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$starter = Join-Path $RepoRoot 'tools\chat-mode-start.ps1'
if (-not (Test-Path -LiteralPath $starter)) {
    throw "Missing starter script: $starter"
}

$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ('chat-mode-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixture | Out-Null

try {
    & $starter `
        -RepoPath $fixture `
        -Topic 'smoke test topic' `
        -MaxTurns 4 `
        -FirstMover codex `
        -TaskSummary 'smoke test topic' `
        -WritePromptFile | Out-Null

    $statePath = Join-Path $fixture '.chat-mode\agent-sync-state.json'
    $promptPath = Join-Path $fixture '.chat-mode\claude-start-prompt.txt'
    $sessionPath = Join-Path $fixture '.chat-mode\sessions\2026-04-19-smoke-test-topic.md'

    if (-not (Test-Path -LiteralPath $statePath)) {
        throw 'State file was not created.'
    }

    if (-not (Test-Path -LiteralPath $promptPath)) {
        throw 'Prompt file was not created.'
    }

    $state = Get-Content -LiteralPath $statePath -Encoding utf8 | ConvertFrom-Json
    $sessionFullPath = Join-Path $fixture $state.session_file

    if (-not (Test-Path -LiteralPath $sessionFullPath)) {
        throw "Session file was not created: $sessionFullPath"
    }

    if ($state.current_agent -ne 'codex') {
        throw "Expected current_agent codex, got $($state.current_agent)."
    }

    if ($state.current_turn -ne 0) {
        throw "Expected current_turn 0, got $($state.current_turn)."
    }

    if ($state.session_file -notmatch '^\.chat-mode') {
        throw "Expected session_file to use .chat-mode default, got $($state.session_file)."
    }

    $session = Get-Content -LiteralPath $sessionFullPath -Encoding utf8 -Raw
    if ($session -notmatch '# Session: smoke test topic') {
        throw 'Session file header is missing expected title.'
    }

    'SMOKE_OK'
}
finally {
    if (Test-Path -LiteralPath $fixture) {
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}
