#requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testToken = [Guid]::NewGuid().ToString('N')
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = [IO.Path]::GetFullPath(
    (Join-Path $tempRoot "chat-mode-direct-main-test-$testToken")
)
$tempPrefix = $tempRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

if (-not $testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test path: $testRoot"
}

$repoPath = Join-Path $testRoot 'repo'
$helperPath = Join-Path $PSScriptRoot '..\skills\chat-mode\scripts\chat-mode-direct-main.ps1'

New-Item -ItemType Directory -Force -Path $repoPath | Out-Null

try {
    git -C $repoPath init --initial-branch=main | Out-Null
    git -C $repoPath config user.name 'chat-mode-test'
    git -C $repoPath config user.email 'chat-mode-test@example.invalid'
    [IO.File]::WriteAllText(
        (Join-Path $repoPath '.gitignore'),
        ".chat-mode/`n",
        [Text.UTF8Encoding]::new($false)
    )
    git -C $repoPath add -- '.gitignore'
    git -C $repoPath commit -m 'baseline' | Out-Null

    $prepared = & $helperPath `
        -Action Prepare `
        -RepoRoot $repoPath `
        -SessionId 'direct001' `
        -WriteScope 'allowed/**'

    $allowedDirectory = Join-Path $repoPath 'allowed\nested'
    New-Item -ItemType Directory -Force -Path $allowedDirectory | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $allowedDirectory 'inside.txt'),
        "inside`n",
        [Text.UTF8Encoding]::new($false)
    )
    $outsidePath = Join-Path $repoPath 'outside.txt'
    [IO.File]::WriteAllText(
        $outsidePath,
        "outside`n",
        [Text.UTF8Encoding]::new($false)
    )

    $violatingInspection = & $helperPath -Action Inspect -RepoRoot $repoPath
    if ($violatingInspection.ScopePassed) {
        throw 'Direct Inspect failed to detect a write-scope violation.'
    }
    if ($violatingInspection.ScopeViolations -ne 'outside.txt') {
        throw "Unexpected direct scope violations: $($violatingInspection.ScopeViolations)"
    }

    Remove-Item -LiteralPath $outsidePath -Force
    $inspected = & $helperPath -Action Inspect -RepoRoot $repoPath

    if ($prepared.mode -ne 'direct-main-exclusive') {
        throw 'Unexpected mode from direct Prepare.'
    }
    if ($inspected.Mode -ne 'direct-main-exclusive') {
        throw 'Unexpected mode from direct Inspect.'
    }
    if ($prepared.repo_root -ne $repoPath) {
        throw 'Unexpected repo root from direct Prepare.'
    }
    if ($prepared.base_commit -ne $inspected.BaseCommit) {
        throw 'Direct base commit mismatch.'
    }
    if ($inspected.BranchChanged -or $inspected.HeadChanged) {
        throw 'Direct session changed branch or HEAD unexpectedly.'
    }
    if (-not $inspected.DiffCheckPassed) {
        throw 'Direct diff check failed.'
    }
    if (-not $inspected.ScopePassed) {
        throw "Valid direct write scope failed: $($inspected.ScopeViolations)"
    }
    if ($inspected.ChangedPaths -ne 'allowed/nested/inside.txt') {
        throw "Unexpected direct changed paths: $($inspected.ChangedPaths)"
    }

    $closed = & $helperPath `
        -Action Close `
        -RepoRoot $repoPath `
        -SessionId 'direct001'
    if (-not $closed.Closed) {
        throw 'Direct session did not close.'
    }
    if (-not (Test-Path -LiteralPath $closed.ArchivePath -PathType Leaf)) {
        throw 'Direct session archive is missing.'
    }
    if (Test-Path -LiteralPath (Join-Path $repoPath '.chat-mode\direct-main.active.json')) {
        throw 'Direct active metadata remains after Close.'
    }

    Write-Host 'PASS: direct main prepared, inspected, and closed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $verifiedRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $verifiedRoot.StartsWith(
                $tempPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Refusing cleanup outside temp: $verifiedRoot"
        }
        Remove-Item -LiteralPath $verifiedRoot -Recurse -Force
    }
}
