param(
    [string]$ToolsTarget = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillSource = Join-Path $ScriptDir 'skills\chat-mode'
$ToolsSource = Join-Path $ScriptDir 'tools'
$MinimumPwshVersion = [version]'7.6.1'

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-WithWinget {
    param(
        [string]$CommandName,
        [string]$PackageId
    )

    if (Test-Command $CommandName) {
        $path = (Get-Command $CommandName -ErrorAction Stop).Source
        Write-Host "[ok] $CommandName found: $path"
        return
    }

    if (-not (Test-Command winget)) {
        throw "winget is required to auto-install $CommandName. Install it manually, then rerun install.ps1."
    }

    Write-Host "[install] $CommandName is missing; installing $PackageId with winget"
    winget install --id $PackageId --exact --accept-package-agreements --accept-source-agreements

    if (-not (Test-Command $CommandName)) {
        Write-Warning "$CommandName was installed but is not available in this shell yet. Open a new terminal if needed."
    }
}

function Update-PathFromRegistry {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Get-PwshVersion {
    if (-not (Test-Command 'pwsh')) {
        return $null
    }

    $rawVersion = & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    return [version]($rawVersion | Select-Object -First 1)
}

function Install-OrUpgrade-Pwsh {
    if (-not (Test-Command winget)) {
        throw "winget is required to install or upgrade pwsh. Install PowerShell $MinimumPwshVersion or newer manually, then rerun install.ps1."
    }

    $currentVersion = Get-PwshVersion
    if ($null -eq $currentVersion) {
        Write-Host "[install] pwsh is missing; installing Microsoft.PowerShell with winget"
        winget install --id Microsoft.PowerShell --exact --accept-package-agreements --accept-source-agreements
    }
    elseif ($currentVersion -lt $MinimumPwshVersion) {
        Write-Host "[upgrade] pwsh $currentVersion found; upgrading to $MinimumPwshVersion or newer with winget"
        winget upgrade --id Microsoft.PowerShell --exact --accept-package-agreements --accept-source-agreements
    }
    else {
        $path = (Get-Command pwsh -ErrorAction Stop).Source
        Write-Host "[ok] pwsh $currentVersion found: $path"
        return
    }

    Update-PathFromRegistry
    $installedVersion = Get-PwshVersion
    if ($null -eq $installedVersion -or $installedVersion -lt $MinimumPwshVersion) {
        throw "PowerShell $MinimumPwshVersion or newer is required, but installed version is $installedVersion."
    }

    $installedPath = (Get-Command pwsh -ErrorAction Stop).Source
    Write-Host "[ok] pwsh $installedVersion found: $installedPath"
}

function Test-OptionalCli {
    param(
        [string]$Name,
        [string]$Url
    )

    if (Test-Command $Name) {
        $path = (Get-Command $Name -ErrorAction Stop).Source
        Write-Host "[ok] $Name found: $path"
    }
    else {
        Write-Warning "$Name not found. Install and authenticate it when you want full two-agent automation: $Url"
    }
}

function Copy-DirectoryReplace {
    param(
        [string]$Source,
        [string]$Target
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Missing source directory: $Source"
    }

    $parent = Split-Path -Parent $Target
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }

    Copy-Item -LiteralPath $Source -Destination $Target -Recurse
}

$isWindowsPlatform = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) { $IsWindows } else { $true }
if (-not $isWindowsPlatform) {
    Write-Warning 'install.ps1 is intended for Windows. On macOS/Linux, use ./install.sh.'
}

if (-not (Test-Path -LiteralPath $SkillSource)) {
    throw "Missing skill source: $SkillSource"
}

Install-WithWinget -CommandName 'git' -PackageId 'Git.Git'
Install-OrUpgrade-Pwsh
Test-OptionalCli -Name 'codex' -Url 'https://github.com/openai/codex'
Test-OptionalCli -Name 'claude' -Url 'https://docs.anthropic.com/en/docs/claude-code'

if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    $skillsRoot = Join-Path $env:CODEX_HOME 'skills'
}
else {
    $skillsRoot = Join-Path $env:USERPROFILE '.codex\skills'
}

$skillTarget = Join-Path $skillsRoot 'chat-mode'
Write-Host "[install] copying skill to $skillTarget"
Copy-DirectoryReplace -Source $SkillSource -Target $skillTarget

if (-not [string]::IsNullOrWhiteSpace($ToolsTarget)) {
    if (-not (Test-Path -LiteralPath $ToolsSource)) {
        throw "Missing tools source: $ToolsSource"
    }
    New-Item -ItemType Directory -Force -Path $ToolsTarget | Out-Null
    Write-Host "[install] copying tools to $ToolsTarget"
    Get-ChildItem -LiteralPath $ToolsSource | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $ToolsTarget -Recurse -Force
    }
}

Write-Host ''
Write-Host 'chat-mode-skill installed successfully.'
Write-Host "Skill: $skillTarget"
if (-not [string]::IsNullOrWhiteSpace($ToolsTarget)) {
    Write-Host "Tools: $ToolsTarget"
}
else {
    Write-Host 'Tools: not copied. Pass -ToolsTarget <dir> to copy helper scripts into a host project.'
}
