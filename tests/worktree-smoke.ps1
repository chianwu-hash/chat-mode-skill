#requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testToken = [Guid]::NewGuid().ToString('N')
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = [IO.Path]::GetFullPath(
    (Join-Path $tempRoot "chat-mode-worktree-test-$testToken")
)
$tempPrefix = $tempRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

if (-not $testRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe test path: $testRoot"
}

$repoPath = Join-Path $testRoot 'repo'
$workerPath = Join-Path $testRoot 'worker'
$helperPath = Join-Path $PSScriptRoot '..\skills\chat-mode\scripts\chat-mode-worktree.ps1'

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
        -SessionId 'test001' `
        -WorktreePath $workerPath `
        -WriteScope 'allowed/**'

    $allowedDirectory = Join-Path $workerPath 'allowed'
    New-Item -ItemType Directory -Force -Path $allowedDirectory | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $allowedDirectory 'inside.txt'),
        "inside`n",
        [Text.UTF8Encoding]::new($false)
    )
    $outsidePath = Join-Path $workerPath 'outside.txt'
    [IO.File]::WriteAllText(
        $outsidePath,
        "outside`n",
        [Text.UTF8Encoding]::new($false)
    )

    $violatingInspection = & $helperPath -Action Inspect -WorktreePath $workerPath
    if ($violatingInspection.ScopePassed) {
        throw 'Inspect failed to detect a write-scope violation.'
    }
    if ($violatingInspection.ScopeViolations -ne 'outside.txt') {
        throw "Unexpected scope violation list: $($violatingInspection.ScopeViolations)"
    }

    Remove-Item -LiteralPath $outsidePath -Force
    $inspected = & $helperPath -Action Inspect -WorktreePath $workerPath

    if ($prepared.branch -ne 'chat-mode/claude-test001') {
        throw 'Unexpected branch from Prepare.'
    }
    if ($inspected.Branch -ne 'chat-mode/claude-test001') {
        throw 'Unexpected branch from Inspect.'
    }
    if ($prepared.base_commit -ne $inspected.BaseCommit) {
        throw 'Base commit mismatch.'
    }
    if (-not $inspected.DiffCheckPassed) {
        throw 'Diff check failed.'
    }
    if (-not $inspected.ScopePassed) {
        throw "Valid write scope failed: $($inspected.ScopeViolations)"
    }
    if ($inspected.ChangedPaths -ne 'allowed/inside.txt') {
        throw "Unexpected changed paths: $($inspected.ChangedPaths)"
    }
    if (-not [string]::IsNullOrWhiteSpace($inspected.MainStatus)) {
        throw 'Main worktree changed.'
    }

    $metadataPath = Join-Path $workerPath '.chat-mode\session.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw 'Missing session metadata.'
    }

    Write-Host 'PASS: isolated worktree prepared and inspected.'
}
finally {
    if ((Test-Path -LiteralPath $repoPath) -and (Test-Path -LiteralPath $workerPath)) {
        git -C $repoPath worktree remove --force $workerPath 2>$null
    }
    if (Test-Path -LiteralPath $repoPath) {
        git -C $repoPath branch -D 'chat-mode/claude-test001' 2>$null | Out-Null
    }

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
