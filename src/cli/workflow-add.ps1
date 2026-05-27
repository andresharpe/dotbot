#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Activate a workflow in an existing dotbot project.

.DESCRIPTION
    Records the workflow as active in .bot/.control/settings.json and
    materialises an effective project-tier workflow if the source declares
    override files, so the resulting workflow keeps a valid manifest while
    the override files replace its base assets.

.PARAMETER Name
    Workflow identifier (e.g., "iwg:iwg-bs-scoring" for a registry workflow
    or "start-from-jira" for a built-in workflow).

.PARAMETER Force
    Overwrite an existing override directory at .bot/content/workflows/<name>/.
#>
param(
    [Parameter(Position = 0)]
    [string]$Name,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src/cli/Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

if (-not $Name) {
    Write-DotbotWarning "Usage: dotbot workflow add <name>"
    Write-DotbotCommand "Example: dotbot workflow add start-from-jira"
    exit 1
}

# Resolve workflow source under DOTBOT_HOME.
$wfSourceDir = $null
if ($Name -match '^([^:]+):(.+)$') {
    $namespace = $Matches[1]
    $shortName = $Matches[2]
    $candidate = Join-Path $DotbotBase "registries" $namespace "workflows" $shortName
    if (Test-Path $candidate) { $wfSourceDir = $candidate }
    $displayName = $shortName
} else {
    $candidate = Join-Path $DotbotBase "content" "workflows" $Name
    if (Test-Path $candidate) { $wfSourceDir = $candidate }
    $displayName = $Name
}

if (-not $wfSourceDir) {
    Write-DotbotError "Workflow not found in DOTBOT_HOME: $Name"
    exit 1
}

# Workflow must have a usable workflow.json at the framework tier.
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking
if (-not (Test-ValidWorkflowDir -Dir $wfSourceDir)) {
    Write-DotbotError "Workflow source at '$wfSourceDir' has no usable workflow.json."
    exit 1
}

# Materialise a complete project-tier workflow when overrides are declared.
$overridesDir = Join-Path $wfSourceDir "overrides"
$projectTier  = Join-Path $BotDir "content" "workflows" $displayName

if ((Test-Path $overridesDir) -or ($Name -match ':')) {
    if ((Test-Path $projectTier) -and -not $Force) {
        Write-DotbotWarning "Project override directory already exists: $projectTier"
        Write-DotbotWarning "Re-run with --Force to overwrite."
        exit 1
    }
    if (Test-Path $projectTier) { Remove-Item $projectTier -Recurse -Force }
    New-Item -Path $projectTier -ItemType Directory -Force | Out-Null

    $sourceFull = [System.IO.Path]::GetFullPath($wfSourceDir)
    Get-ChildItem -Path $wfSourceDir -Recurse -File | Where-Object {
        $rel = [System.IO.Path]::GetRelativePath($sourceFull, [System.IO.Path]::GetFullPath($_.FullName))
        -not ($rel -eq 'overrides' -or $rel.StartsWith("overrides$([System.IO.Path]::DirectorySeparatorChar)"))
    } | ForEach-Object {
        $rel  = [System.IO.Path]::GetRelativePath($sourceFull, [System.IO.Path]::GetFullPath($_.FullName))
        $dest = Join-Path $projectTier $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
    if (Test-Path $overridesDir) {
        $overrideFull = [System.IO.Path]::GetFullPath($overridesDir)
        Get-ChildItem -Path $overridesDir -Recurse -File | ForEach-Object {
            $rel  = [System.IO.Path]::GetRelativePath($overrideFull, [System.IO.Path]::GetFullPath($_.FullName))
            $dest = Join-Path $projectTier $rel
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -Path $_.FullName -Destination $dest -Force
        }
    }
    Write-DotbotCommand "Materialised workflow → .bot/content/workflows/$displayName/"
}

# Record the active workflow in .bot/.control/settings.json (per-project, gitignored).
$controlDir = Join-Path $BotDir '.control'
if (-not (Test-Path $controlDir)) {
    New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
}
$controlSettingsPath = Join-Path $controlDir 'settings.json'
$existing = [pscustomobject]@{}
if (Test-Path $controlSettingsPath) {
    try { $existing = Get-Content $controlSettingsPath -Raw | ConvertFrom-Json } catch {
        $existing = [pscustomobject]@{}
    }
}
$existing | Add-Member -NotePropertyName 'workflow' -NotePropertyValue $displayName -Force
$existing | ConvertTo-Json -Depth 10 | Set-Content -Path $controlSettingsPath -Encoding UTF8

Write-Success "Active workflow: $displayName"
