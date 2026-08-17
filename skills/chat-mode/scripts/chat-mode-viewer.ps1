[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequestPath,

    [Parameter(Mandatory = $true)]
    [string]$LivePath,

    [Parameter(Mandatory = $true)]
    [string]$RunPath,

    [string]$StatusPath = '',

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

function Get-StatusSnapshot {
    if ([string]::IsNullOrWhiteSpace($StatusPath) -or
        -not (Test-Path -LiteralPath $StatusPath -PathType Leaf)) {
        return $null
    }

    try {
        [System.IO.File]::ReadAllText($StatusPath, $utf8NoBom) | ConvertFrom-Json
    }
    catch {
        $null
    }
}

if (-not $NoClear) { Clear-Host }
Write-Host 'CHAT MODE' -ForegroundColor White
Write-Host 'Live conversation mirror' -ForegroundColor DarkGray

Write-RoleHeading -Text 'CODEX -> CLAUDE' -Color Cyan
Write-Host (Get-RequestBody -Path $RequestPath)

Write-RoleHeading -Text 'CLAUDE -> CODEX' -Color Magenta

$reader = $null
$viewerTimer = [System.Diagnostics.Stopwatch]::StartNew()
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

        $status = Get-StatusSnapshot
        $viewerState = 'running'
        $eventCount = 0
        $lastEventKind = 'starting'
        $idleSeconds = [math]::Floor($viewerTimer.Elapsed.TotalSeconds)
        if ($null -ne $status) {
            $viewerState = [string]$status.state
            $eventCount = [int]$status.eventCount
            $lastEventKind = [string]$status.lastEventKind
            if (-not [string]::IsNullOrWhiteSpace([string]$status.lastEventAt)) {
                $lastEvent = [DateTimeOffset]::Parse([string]$status.lastEventAt)
                $idleSeconds = [math]::Max(0, [math]::Floor(([DateTimeOffset]::UtcNow - $lastEvent).TotalSeconds))
            }
            if ($viewerState -eq 'running' -and $idleSeconds -ge [int]$status.idleWarningSeconds) {
                $viewerState = 'idle-warning'
            }
        }
        Write-Progress `
            -Id 1 `
            -Activity "Claude status: $viewerState" `
            -Status "elapsed $([math]::Floor($viewerTimer.Elapsed.TotalSeconds))s | idle ${idleSeconds}s | events $eventCount | $lastEventKind"

        if (Test-Path -LiteralPath $RunPath -PathType Leaf) {
            $run = [System.IO.File]::ReadAllText($RunPath, $utf8NoBom) | ConvertFrom-Json
            Write-Progress -Id 1 -Activity 'Claude status' -Completed
            Write-Host ''
            if ($run.status -eq 'completed' -or $run.stopReason -eq 'completed') {
                Write-RoleHeading -Text "TURN $($run.turnId) COMPLETE" -Color Green
            }
            else {
                Write-RoleHeading -Text "TURN $($run.turnId) STOPPED: $(([string]$run.stopReason).ToUpperInvariant())" -Color Yellow
            }
            Wait-BeforeClose
            break
        }

        if (-not (Test-ParentAlive)) {
            Write-Host ''
            Write-Progress -Id 1 -Activity 'Claude status' -Completed
            Write-RoleHeading -Text 'TURN ENDED WITHOUT A COMPLETION RECORD' -Color Yellow
            Wait-BeforeClose
            break
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
finally {
    $viewerTimer.Stop()
    Write-Progress -Id 1 -Activity 'Claude status' -Completed
    if ($null -ne $reader) { $reader.Dispose() }
}
