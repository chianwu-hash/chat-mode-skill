[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Inspect')]
    [string]$Action,

    [string]$RepoRoot = '.',

    [string]$SessionId = '',

    [string]$BaseRef = 'HEAD',

    [string]$WorktreePath = '',

    [string]$BranchName = '',

    [string[]]$WriteScope = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [string]$WorkingDirectory,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Resolve-GitRoot {
    param([string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $result = Invoke-Git -WorkingDirectory $resolved -Arguments @('rev-parse', '--show-toplevel')
    $root = (Resolve-Path -LiteralPath ($result.Output | Select-Object -First 1)).Path
    if (-not $resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "RepoRoot must be the Git top-level directory: $root"
    }

    return $root
}

function ConvertTo-AbsolutePath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    $candidate = if ([IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path $BasePath $Path
    }

    return [IO.Path]::GetFullPath($candidate)
}

function Assert-SafeSessionId {
    param([string]$Value)

    if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'SessionId must contain 1-64 ASCII letters, digits, dots, underscores, or hyphens.'
    }
}

function ConvertTo-SafeWriteScope {
    param([string[]]$Scope)

    if ($Scope.Count -eq 0) {
        throw 'Prepare requires at least one -WriteScope pattern.'
    }

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $Scope) {
        $normalized = $item.Trim().Replace('\', '/')
        if (
            [string]::IsNullOrWhiteSpace($normalized) -or
            [IO.Path]::IsPathRooted($normalized) -or
            $normalized.StartsWith('/') -or
            $normalized -match '(^|/)\.\.(/|$)'
        ) {
            throw "Unsafe WriteScope pattern: $item"
        }
        $result.Add($normalized)
    }

    return $result.ToArray()
}

function Test-WriteScope {
    param(
        [string]$Path,
        [string[]]$Scope
    )

    $normalizedPath = $Path.Replace('\', '/')
    foreach ($item in $Scope) {
        $pattern = [Management.Automation.WildcardPattern]::new(
            $item,
            [Management.Automation.WildcardOptions]::IgnoreCase
        )
        if ($pattern.IsMatch($normalizedPath)) {
            return $true
        }
    }

    return $false
}

function Get-SessionMetadata {
    param([string]$Path)

    $metadataPath = Join-Path $Path '.chat-mode\session.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Missing chat-mode worktree metadata: $metadataPath"
    }

    return Get-Content -Raw -Encoding utf8 -LiteralPath $metadataPath | ConvertFrom-Json
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required.'
}

switch ($Action) {
    'Prepare' {
        Assert-SafeSessionId -Value $SessionId
        $safeWriteScope = @(ConvertTo-SafeWriteScope -Scope $WriteScope)
        $repo = Resolve-GitRoot -Path $RepoRoot

        $status = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'status', '--porcelain=v1', '--untracked-files=all'
        )
        if ($status.Output.Count -gt 0) {
            throw "The main worktree must be clean before creating an isolated Claude worktree.`n$($status.Output -join [Environment]::NewLine)"
        }

        $ignoreCheck = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'check-ignore', '--quiet', '--no-index', '.chat-mode/session.json'
        ) -AllowFailure
        if ($ignoreCheck.ExitCode -ne 0) {
            throw 'The repository must ignore .chat-mode/ before creating an isolated worktree.'
        }

        $baseResult = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'rev-parse', '--verify', "$BaseRef^{commit}"
        )
        $baseCommit = ($baseResult.Output | Select-Object -First 1).Trim()

        if ([string]::IsNullOrWhiteSpace($BranchName)) {
            $BranchName = "chat-mode/claude-$SessionId"
        }

        $branchCheck = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'check-ref-format', '--branch', $BranchName
        ) -AllowFailure
        if ($branchCheck.ExitCode -ne 0) {
            throw "Invalid branch name: $BranchName"
        }

        $existingBranch = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'show-ref', '--verify', '--quiet', "refs/heads/$BranchName"
        ) -AllowFailure
        if ($existingBranch.ExitCode -eq 0) {
            throw "Branch already exists: $BranchName"
        }
        if ($existingBranch.ExitCode -notin @(0, 1)) {
            throw "Could not check branch: $BranchName"
        }

        if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
            $repoName = Split-Path -Leaf $repo
            $worktreeParent = Join-Path (Split-Path -Parent $repo) '.chat-mode-worktrees'
            $WorktreePath = Join-Path $worktreeParent "$repoName-$SessionId"
        }

        $target = ConvertTo-AbsolutePath -Path $WorktreePath -BasePath $repo
        $repoPrefix = $repo.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (
            $target.Equals($repo, [StringComparison]::OrdinalIgnoreCase) -or
            $target.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)
        ) {
            throw 'The isolated worktree must be outside the main repository directory.'
        }
        if (Test-Path -LiteralPath $target) {
            throw "Worktree path already exists: $target"
        }

        $targetParent = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $targetParent | Out-Null

        Invoke-Git -WorkingDirectory $repo -Arguments @(
            'worktree', 'add', '-b', $BranchName, $target, $baseCommit
        ) | Out-Null

        $exchangePath = Join-Path $target ".chat-mode\exchange\$SessionId"
        New-Item -ItemType Directory -Force -Path $exchangePath | Out-Null

        $metadata = [ordered]@{
            protocol      = 'chat-mode/worktree-v1'
            session_id    = $SessionId
            main_repo     = $repo
            worktree_path = $target
            branch        = $BranchName
            base_commit   = $baseCommit
            write_scope   = $safeWriteScope
            created_at    = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $metadataPath = Join-Path $target '.chat-mode\session.json'
        $json = $metadata | ConvertTo-Json
        [IO.File]::WriteAllText(
            $metadataPath,
            $json + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )

        [PSCustomObject]$metadata
        break
    }

    'Inspect' {
        if ([string]::IsNullOrWhiteSpace($WorktreePath)) {
            throw '-WorktreePath is required for Inspect.'
        }

        $target = (Resolve-Path -LiteralPath $WorktreePath).Path
        $targetRoot = Resolve-GitRoot -Path $target
        $metadata = Get-SessionMetadata -Path $targetRoot

        if (-not $targetRoot.Equals(
                [string]$metadata.worktree_path,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw 'Worktree path does not match chat-mode metadata.'
        }

        $head = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'rev-parse', 'HEAD'
            )).Output | Select-Object -First 1
        $branch = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'branch', '--show-current'
            )).Output | Select-Object -First 1
        $status = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'status', '--short', '--untracked-files=all'
            )).Output
        $trackedPaths = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'diff', '--name-only', '--no-renames', [string]$metadata.base_commit, '--'
            )).Output
        $untrackedPaths = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'ls-files', '--others', '--exclude-standard'
            )).Output
        $changedPaths = @($trackedPaths + $untrackedPaths) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Replace('\', '/') } |
            Sort-Object -Unique
        $scope = @($metadata.write_scope | ForEach-Object { [string]$_ })
        $scopeViolations = @($changedPaths | Where-Object {
                -not (Test-WriteScope -Path $_ -Scope $scope)
            })
        $diffStat = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'diff', '--stat', [string]$metadata.base_commit, '--'
            )).Output
        $diffCheck = Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
            'diff', '--check', [string]$metadata.base_commit, '--'
        ) -AllowFailure
        $commits = (Invoke-Git -WorkingDirectory $targetRoot -Arguments @(
                'log', '--oneline', "$($metadata.base_commit)..HEAD"
            )).Output
        $mainStatus = (Invoke-Git -WorkingDirectory ([string]$metadata.main_repo) -Arguments @(
                'status', '--short', '--untracked-files=all'
            )).Output

        [PSCustomObject]@{
            SessionId       = [string]$metadata.session_id
            WorktreePath    = $targetRoot
            Branch          = $branch
            BaseCommit      = [string]$metadata.base_commit
            Head            = $head
            WorktreeStatus  = $status -join [Environment]::NewLine
            ChangedPaths    = $changedPaths -join [Environment]::NewLine
            WriteScope      = $scope -join [Environment]::NewLine
            ScopePassed     = $scopeViolations.Count -eq 0
            ScopeViolations = $scopeViolations -join [Environment]::NewLine
            DiffStat        = $diffStat -join [Environment]::NewLine
            DiffCheckPassed = $diffCheck.ExitCode -eq 0
            Commits         = $commits -join [Environment]::NewLine
            MainStatus      = $mainStatus -join [Environment]::NewLine
        }
        break
    }
}
