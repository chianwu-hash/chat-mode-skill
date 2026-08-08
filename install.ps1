[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillSource = Join-Path $scriptDirectory 'skills\chat-mode'

if (-not (Test-Path -LiteralPath $skillSource -PathType Container)) {
    throw "Missing skill source: $skillSource"
}

$skillsRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE '.codex\skills'
}
else {
    Join-Path $env:CODEX_HOME 'skills'
}

$skillTarget = Join-Path $skillsRoot 'chat-mode'
New-Item -ItemType Directory -Force -Path $skillTarget | Out-Null

Get-ChildItem -LiteralPath $skillSource -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $skillTarget -Recurse -Force
}

Write-Host 'chat-mode skill installed successfully.'
Write-Host "Source: $skillSource"
Write-Host "Target: $skillTarget"
Write-Host 'Restart Codex to load the updated skill.'
