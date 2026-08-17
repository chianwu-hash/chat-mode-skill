[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [string]$LivePath,

    [Parameter(Mandatory = $true)]
    [string]$RunPath,

    [int]$ParentProcessId = 0,

    [int]$HoldSeconds = 0,

    [int]$PollMilliseconds = 100,

    [switch]$NoClear
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$Host.UI.RawUI.WindowTitle = 'Chat Mode - Codex and Claude'

function Write-RoleHeading {
    param(
        [string]$Text,
        [ConsoleColor]$Color
    )

    Write-Host ''
    Write-Host $Text -ForegroundColor $Color
    Write-Host ('-' * 72) -ForegroundColor DarkGray
}

function Get-RequestBody {
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
    $lines = $text -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') {
        return $text.Trim()
    }

    $end = -1
    for ($index = 1; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq '---') {
            $end = $index
            break
        }
    }
    if ($end -lt 0 -or $end + 1 -ge $lines.Count) {
        return $text.Trim()
    }

    (($lines[($end + 1)..($lines.Count - 1)]) -join "`n").Trim()
}

function Test-ParentAlive {
    if ($ParentProcessId -le 0) { return $true }
    $null -ne (Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue)
}

function Wait-BeforeClose {
    if ($HoldSeconds -gt 0) {
        Write-Host "Closing in $HoldSeconds seconds..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $HoldSeconds
        return
    }

    Write-Host 'Press Enter to close this window.' -ForegroundColor DarkGray
    [void](Read-Host)
}

if (-not $NoClear) { Clear-Host }
Write-Host 'CHAT MODE' -ForegroundColor White
Write-Host 'Live conversation mirror' -ForegroundColor DarkGray

Write-RoleHeading -Text 'CODEX -> CLAUDE' -Color Cyan
Write-Host (Get-RequestBody -Path $RequestPath)

Write-RoleHeading -Text 'CLAUDE -> CODEX' -Color Magenta

$reader = $null
try {
    while (-not (Test-Path -LiteralPath $LivePath -PathType Leaf)) {
        if (-not (Test-ParentAlive)) { return }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    $stream = [System.IO.FileStream]::new(
        $LivePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    $reader = [System.IO.StreamReader]::new($stream, $utf8NoBom, $false)

    while ($true) {
        $chunk = $reader.ReadToEnd()
        if (-not [string]::IsNullOrEmpty($chunk)) {
            [Console]::Write($chunk)
        }

        if (Test-Path -LiteralPath $RunPath -PathType Leaf) {
            $run = [System.IO.File]::ReadAllText($RunPath, $utf8NoBom) | ConvertFrom-Json
            Write-Host ''
            Write-RoleHeading -Text "TURN $($run.turnId) COMPLETE" -Color Green
            Wait-BeforeClose
            break
        }

        if (-not (Test-ParentAlive)) {
            Write-Host ''
            Write-RoleHeading -Text 'TURN ENDED WITHOUT A COMPLETION RECORD' -Color Yellow
            Wait-BeforeClose
            break
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
finally {
    if ($null -ne $reader) { $reader.Dispose() }
}
