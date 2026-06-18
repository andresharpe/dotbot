#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Show the dotbot installation status for the current shell + project.

.DESCRIPTION
    Reports the values a dev needs to know which dotbot checkout the
    shell is bound to and which project tier is layered on top:
      - DOTBOT_HOME (resolved)
      - Framework checkout: version, git SHA, dirty flag, current branch
      - User-settings path
      - Project .bot/ status (initialized or not)
      - Active workflow + provider (merged settings)

.PARAMETER Json
    Emit the report as a single JSON object on stdout instead of the
    formatted banner. Stable shape for scripting.
#>

[CmdletBinding()]
param(
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

# Locate DOTBOT_HOME via the same resolver init uses, so this command's
# answer matches what every other dotbot command will see.
Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$dotbotHome = Get-DotbotInstallPath

function Get-FrameworkGitInfo {
    param([string]$Root)
    $info = [ordered]@{
        is_git_repo = $false
        sha         = $null
        sha_short   = $null
        branch      = $null
        dirty       = $false
    }
    if (-not (Test-Path (Join-Path $Root '.git'))) { return $info }
    Push-Location $Root
    try {
        $sha = (& git rev-parse HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $sha) {
            $info.is_git_repo = $true
            $info.sha = $sha.Trim()
            $info.sha_short = $info.sha.Substring(0, [Math]::Min(8, $info.sha.Length))
        }
        $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $branch) {
            $info.branch = $branch.Trim()
        }
        $porcelain = & git status --porcelain 2>$null
        $info.dirty = [bool]$porcelain
    } finally {
        Pop-Location
    }
    return $info
}

function Get-DotbotVersion {
    param([string]$Root)
    $vfile = Join-Path $Root 'version.json'
    if (-not (Test-Path $vfile)) { return 'unknown' }
    try {
        $v = Get-Content $vfile -Raw | ConvertFrom-Json
        if ($v.PSObject.Properties['version']) { return [string]$v.version }
    } catch { }
    return 'unknown'
}

function Get-ProjectStatus {
    param([string]$BotDir)
    $status = [ordered]@{
        initialized      = $false
        bot_dir          = $BotDir
        workflow         = $null
        provider         = $null
        stacks           = @()
    }
    if (-not (Test-Path $BotDir)) { return $status }
    $status.initialized = $true

    try {
        $settingsModule = Join-Path $PSScriptRoot '..' 'runtime' 'Modules' 'Dotbot.Settings' 'Dotbot.Settings.psd1'
        if (-not (Get-Module Dotbot.Settings)) {
            Import-Module $settingsModule -DisableNameChecking -Global
        }
        $merged = Get-MergedSettings -BotRoot $BotDir
        if ($merged.PSObject.Properties['workflow']) { $status.workflow = $merged.workflow }
        if ($merged.PSObject.Properties['provider']) { $status.provider = $merged.provider }
        if ($merged.PSObject.Properties['stacks'])   { $status.stacks   = @($merged.stacks) }
    } catch {
        # Project may have an empty / unreadable .control/settings.json; treat
        # as "no settings recorded" rather than failing the whole report.
    }
    return $status
}

function Find-DotbotProjectBotDir {
    param([string]$StartDir)

    $dir = [System.IO.Path]::GetFullPath($StartDir)
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $candidate = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { break }

        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

# ---------------------------------------------------------------------------
# Assemble the report
# ---------------------------------------------------------------------------
$frameworkGit = Get-FrameworkGitInfo -Root $dotbotHome
$version      = Get-DotbotVersion   -Root $dotbotHome
$userSettings = Get-DotbotUserSettingsPath
$envSet       = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('DOTBOT_HOME'))
$projectDir   = (Get-Location).Path
$resolvedBotDir = Find-DotbotProjectBotDir -StartDir $projectDir
$botDir       = if ($resolvedBotDir) { $resolvedBotDir } else { Join-Path $projectDir '.bot' }
$project      = Get-ProjectStatus -BotDir $botDir

$report = [ordered]@{
    dotbot_home          = $dotbotHome
    dotbot_home_env_set  = $envSet
    version              = $version
    framework            = $frameworkGit
    user_settings_path   = $userSettings
    user_settings_exists = [bool](Test-Path $userSettings)
    project              = $project
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($Json) {
    $report | ConvertTo-Json -Depth 6
    return
}

# Theme helpers come from DOTBOT_HOME so the formatted output is consistent
# regardless of which directory the user invoked from.
Import-Module (Join-Path $dotbotHome 'src/cli/Platform-Functions.psm1') -Force
Import-Module (Join-Path $dotbotHome 'src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1') -Force -DisableNameChecking

Write-DotbotBanner -Title "D O T B O T   v$version" -Subtitle "Status"

Write-DotbotSection "FRAMEWORK"
Write-DotbotLabel "    DOTBOT_HOME    " "$dotbotHome"
if (-not $envSet) {
    Write-DotbotLabel "    Source         " "fallback (`$env:DOTBOT_HOME unset)" -ValueType Warning
} else {
    Write-DotbotLabel "    Source         " "`$env:DOTBOT_HOME"
}
Write-DotbotLabel "    Version        " "$version"
if ($frameworkGit.is_git_repo) {
    $shaLine = $frameworkGit.sha_short
    if ($frameworkGit.dirty) { $shaLine += ' (dirty)' }
    $shaType = if ($frameworkGit.dirty) { 'Warning' } else { 'Default' }
    Write-DotbotLabel "    Git SHA        " $shaLine -ValueType $shaType
    $branchType = if ($frameworkGit.branch -eq 'main' -or $frameworkGit.branch -eq 'master') { 'Default' } else { 'Warning' }
    Write-DotbotLabel "    Branch         " "$($frameworkGit.branch)" -ValueType $branchType
} else {
    Write-DotbotLabel "    Git            " "not a git repository" -ValueType Warning
}
Write-BlankLine

Write-DotbotSection "USER SETTINGS"
$userSettingsStatus = if ($report.user_settings_exists) { 'present' } else { 'not present' }
Write-DotbotLabel "    Path           " "$userSettings"
Write-DotbotLabel "    File           " "$userSettingsStatus"
Write-BlankLine

Write-DotbotSection "PROJECT"
if ($project.initialized) {
    Write-DotbotLabel "    Status         " "✓ Initialized" -ValueType Success
    Write-DotbotLabel "    .bot/          " "$botDir"
    if ($project.workflow) {
        Write-DotbotLabel "    Workflow       " "$($project.workflow)"
    } else {
        Write-DotbotLabel "    Workflow       " "(none recorded)" -ValueType Warning
    }
    if ($project.provider) {
        Write-DotbotLabel "    Provider       " "$($project.provider)"
    }
    if ($project.stacks -and $project.stacks.Count -gt 0) {
        Write-DotbotLabel "    Stacks         " ($project.stacks -join ', ')
    }
} else {
    Write-DotbotLabel "    Status         " "✗ Not initialized" -ValueType Error
    Write-DotbotCommand "Run 'dotbot init' to add dotbot to this project"
}
Write-BlankLine
