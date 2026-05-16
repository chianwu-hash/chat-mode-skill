param(
    [string]$RepoPath = '',

    [string]$ConfigPath = '',

    [string]$CodexExe = '',

    [string]$ClaudeExe = ''
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

function Resolve-ExecutablePath {
    param(
        [string]$Value,
        [string]$CommandName
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        if (Test-Path -LiteralPath $Value) {
            return [System.IO.Path]::GetFullPath($Value)
        }

        $explicitCommand = Get-Command $Value -ErrorAction SilentlyContinue
        if ($explicitCommand) {
            return $explicitCommand.Source
        }

        throw "Executable not found: $Value"
    }

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($CommandName -eq 'codex' -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $extensionRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
        if (Test-Path -LiteralPath $extensionRoot) {
            $candidate = Get-ChildItem -LiteralPath $extensionRoot -Directory -Filter 'openai.chatgpt-*' |
                Sort-Object LastWriteTime -Descending |
                ForEach-Object {
                    Join-Path $_.FullName 'bin\windows-x86_64\codex.exe'
                } |
                Where-Object { Test-Path -LiteralPath $_ } |
                Select-Object -First 1

            if ($candidate) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
        }
    }

    throw "Executable not found: $CommandName"
}

function Invoke-CheckedTool {
    param(
        [string]$ExePath,
        [string[]]$ToolArgs
    )

    $output = & $ExePath @ToolArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
}

function Assert-CodexAgentCli {
    param([string]$ExePath)

    $rootHelp = Invoke-CheckedTool -ExePath $ExePath -ToolArgs @('--help')
    if ($rootHelp.ExitCode -ne 0) {
        throw "Codex CLI validation failed with exit code $($rootHelp.ExitCode): $($rootHelp.Output)"
    }

    $help = Invoke-CheckedTool -ExePath $ExePath -ToolArgs @('exec', '--help')
    if ($help.ExitCode -ne 0) {
        throw "Codex CLI validation failed with exit code $($help.ExitCode): $($help.Output)"
    }

    foreach ($required in @('exec', '--ask-for-approval')) {
        if ($rootHelp.Output -notmatch [regex]::Escape($required)) {
            throw "Codex CLI validation failed. Missing expected text: $required"
        }
    }

    foreach ($required in @('Run Codex non-interactively', '--sandbox')) {
        if ($help.Output -notmatch [regex]::Escape($required)) {
            throw "Codex CLI validation failed. Missing expected text: $required"
        }
    }

    $version = Invoke-CheckedTool -ExePath $ExePath -ToolArgs @('--version')
    if ($version.ExitCode -ne 0) {
        return ''
    }

    return $version.Output.Trim()
}

function Assert-ClaudeCodeCli {
    param([string]$ExePath)

    $help = Invoke-CheckedTool -ExePath $ExePath -ToolArgs @('--help')
    if ($help.ExitCode -ne 0) {
        throw "Claude CLI validation failed with exit code $($help.ExitCode): $($help.Output)"
    }

    foreach ($required in @('--print', '--permission-mode')) {
        if ($help.Output -notmatch [regex]::Escape($required)) {
            throw "Claude CLI validation failed. Missing expected text: $required"
        }
    }

    $version = Invoke-CheckedTool -ExePath $ExePath -ToolArgs @('--version')
    if ($version.ExitCode -ne 0) {
        return ''
    }

    return $version.Output.Trim()
}

$resolvedCodex = Resolve-ExecutablePath -Value $CodexExe -CommandName 'codex'
$resolvedClaude = Resolve-ExecutablePath -Value $ClaudeExe -CommandName 'claude'

$codexVersion = Assert-CodexAgentCli -ExePath $resolvedCodex
$claudeVersion = Assert-ClaudeCodeCli -ExePath $resolvedClaude
$validatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

$config = [ordered]@{
    schema_version = 1
    codex_exe = $resolvedCodex
    claude_exe = $resolvedClaude
    codex_version = $codexVersion
    claude_version = $claudeVersion
    validated_at = $validatedAt
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConfigPath) | Out-Null
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding utf8

[pscustomobject]@{
    status = 'ok'
    config_path = $ConfigPath
    codex_exe = $resolvedCodex
    claude_exe = $resolvedClaude
    codex_version = $codexVersion
    claude_version = $claudeVersion
    validated_at = $validatedAt
} | ConvertTo-Json -Depth 4
