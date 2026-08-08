[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Prepare', 'Inspect', 'Close')]
    [string]$Action,

    [string]$RepoRoot = '.',

    [string]$SessionId = '',

    [string]$BaseRef = 'HEAD',

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
    $result = Invoke-Git -WorkingDirectory $resolved -Arguments @(
        'rev-parse', '--show-toplevel'
    )
    $root = (Resolve-Path -LiteralPath ($result.Output | Select-Object -First 1)).Path
    if (-not $resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "RepoRoot must be the Git top-level directory: $root"
    }

    return $root
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

function Get-ActiveMetadataPath {
    param([string]$Repo)

    return Join-Path $Repo '.chat-mode\direct-main.active.json'
}

function Get-ActiveMetadata {
    param([string]$Repo)

    $metadataPath = Get-ActiveMetadataPath -Repo $Repo
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Missing active direct-main metadata: $metadataPath"
    }

    $metadata = Get-Content -Raw -Encoding utf8 -LiteralPath $metadataPath |
        ConvertFrom-Json
    if ([string]$metadata.mode -ne 'direct-main-exclusive') {
        throw 'Active metadata is not a direct-main-exclusive session.'
    }

    return $metadata
}

function Get-UpstreamState {
    param([string]$Repo)

    $upstreamResult = Invoke-Git -WorkingDirectory $Repo -Arguments @(
        'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'
    ) -AllowFailure
    if ($upstreamResult.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Ref    = ''
            Commit = ''
        }
    }

    $upstreamRef = ($upstreamResult.Output | Select-Object -First 1).Trim()
    $commitResult = Invoke-Git -WorkingDirectory $Repo -Arguments @(
        'rev-parse', '--verify', "$upstreamRef^{commit}"
    )

    return [PSCustomObject]@{
        Ref    = $upstreamRef
        Commit = ($commitResult.Output | Select-Object -First 1).Trim()
    }
}

function Get-Inspection {
    param(
        [string]$Repo,
        [object]$Metadata
    )

    if (-not $Repo.Equals(
            [string]$Metadata.repo_root,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Repository path does not match direct-main metadata.'
    }

    $head = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'rev-parse', 'HEAD'
        )).Output | Select-Object -First 1
    $branch = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'branch', '--show-current'
        )).Output | Select-Object -First 1
    $status = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'status', '--short', '--untracked-files=all'
        )).Output
    $trackedPaths = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'diff', '--name-only', '--no-renames', [string]$Metadata.base_commit, '--'
        )).Output
    $untrackedPaths = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'ls-files', '--others', '--exclude-standard'
        )).Output
    $changedPaths = @($trackedPaths + $untrackedPaths) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Replace('\', '/') } |
        Sort-Object -Unique
    $scope = @($Metadata.write_scope | ForEach-Object { [string]$_ })
    $scopeViolations = @($changedPaths | Where-Object {
            -not (Test-WriteScope -Path $_ -Scope $scope)
        })
    $diffStat = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'diff', '--stat', [string]$Metadata.base_commit, '--'
        )).Output
    $diffCheck = Invoke-Git -WorkingDirectory $Repo -Arguments @(
        'diff', '--check', [string]$Metadata.base_commit, '--'
    ) -AllowFailure
    $commits = (Invoke-Git -WorkingDirectory $Repo -Arguments @(
            'log', '--oneline', "$($Metadata.base_commit)..HEAD"
        )).Output
    $upstream = Get-UpstreamState -Repo $Repo

    [PSCustomObject]@{
        SessionId            = [string]$Metadata.session_id
        Mode                 = [string]$Metadata.mode
        RepoRoot             = $Repo
        Branch               = $branch
        BaselineBranch       = [string]$Metadata.branch
        BranchChanged        = $branch -ne [string]$Metadata.branch
        BaseCommit           = [string]$Metadata.base_commit
        Head                 = $head
        HeadChanged          = $head -ne [string]$Metadata.base_commit
        WorktreeStatus       = $status -join [Environment]::NewLine
        ChangedPaths         = $changedPaths -join [Environment]::NewLine
        WriteScope           = $scope -join [Environment]::NewLine
        ScopePassed          = $scopeViolations.Count -eq 0
        ScopeViolations      = $scopeViolations -join [Environment]::NewLine
        DiffStat             = $diffStat -join [Environment]::NewLine
        DiffCheckPassed      = $diffCheck.ExitCode -eq 0
        Commits              = $commits -join [Environment]::NewLine
        BaselineUpstreamRef  = [string]$Metadata.upstream_ref
        BaselineUpstreamHead = [string]$Metadata.upstream_commit
        CurrentUpstreamRef   = $upstream.Ref
        CurrentUpstreamHead  = $upstream.Commit
        UpstreamChanged      = (
            $upstream.Ref -ne [string]$Metadata.upstream_ref -or
            $upstream.Commit -ne [string]$Metadata.upstream_commit
        )
    }
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
            throw "The main worktree must be clean before direct handoff.`n$($status.Output -join [Environment]::NewLine)"
        }

        $ignoreCheck = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'check-ignore', '--quiet', '--no-index', '.chat-mode/direct-main.active.json'
        ) -AllowFailure
        if ($ignoreCheck.ExitCode -ne 0) {
            throw 'The repository must ignore .chat-mode/ before direct handoff.'
        }

        $metadataPath = Get-ActiveMetadataPath -Repo $repo
        if (Test-Path -LiteralPath $metadataPath) {
            throw "An active direct-main session already exists: $metadataPath"
        }

        $baseResult = Invoke-Git -WorkingDirectory $repo -Arguments @(
            'rev-parse', '--verify', "$BaseRef^{commit}"
        )
        $baseCommit = ($baseResult.Output | Select-Object -First 1).Trim()
        $branch = (Invoke-Git -WorkingDirectory $repo -Arguments @(
                'branch', '--show-current'
            )).Output | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($branch)) {
            throw 'Direct-main mode requires a named branch, not detached HEAD.'
        }

        $upstream = Get-UpstreamState -Repo $repo
        $exchangePath = Join-Path $repo ".chat-mode\exchange\$SessionId"
        New-Item -ItemType Directory -Force -Path $exchangePath | Out-Null

        $metadata = [ordered]@{
            protocol        = 'chat-mode/direct-main-v1'
            mode            = 'direct-main-exclusive'
            session_id      = $SessionId
            repo_root       = $repo
            worktree_path   = $repo
            branch          = $branch
            base_commit     = $baseCommit
            write_scope     = $safeWriteScope
            exclusive_writer = 'claude'
            upstream_ref    = $upstream.Ref
            upstream_commit = $upstream.Commit
            created_at      = [DateTimeOffset]::UtcNow.ToString('o')
        }
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
        $repo = Resolve-GitRoot -Path $RepoRoot
        $metadata = Get-ActiveMetadata -Repo $repo
        Get-Inspection -Repo $repo -Metadata $metadata
        break
    }

    'Close' {
        $repo = Resolve-GitRoot -Path $RepoRoot
        $metadataPath = Get-ActiveMetadataPath -Repo $repo
        $metadata = Get-ActiveMetadata -Repo $repo
        if (
            -not [string]::IsNullOrWhiteSpace($SessionId) -and
            $SessionId -ne [string]$metadata.session_id
        ) {
            throw 'SessionId does not match the active direct-main session.'
        }

        $inspection = Get-Inspection -Repo $repo -Metadata $metadata
        $archiveDirectory = Join-Path $repo '.chat-mode\sessions'
        New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
        $archivePath = Join-Path $archiveDirectory "$($metadata.session_id).direct-main.json"
        if (Test-Path -LiteralPath $archivePath) {
            throw "Direct-main archive already exists: $archivePath"
        }

        $archive = [ordered]@{
            metadata   = $metadata
            inspection = $inspection
            closed_at  = [DateTimeOffset]::UtcNow.ToString('o')
        }
        [IO.File]::WriteAllText(
            $archivePath,
            ($archive | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        Remove-Item -LiteralPath $metadataPath -Force

        [PSCustomObject]@{
            SessionId   = [string]$metadata.session_id
            ArchivePath = $archivePath
            Closed      = $true
        }
        break
    }
}
