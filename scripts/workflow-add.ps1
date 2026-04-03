#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add a workflow to an existing dotbot project.

.PARAMETER Name
    Workflow identifier (e.g., "iwg:iwg-bs-scoring" for registry or "my-workflow" for built-in).

.PARAMETER Force
    Overwrite if already installed.
#>
param(
    [Parameter(Position = 0)]
    [string]$Name,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

if (-not $Name) {
    Write-Host "  Usage: dotbot workflow add <name>" -ForegroundColor Yellow
    Write-Host "  Example: dotbot workflow add iwg:iwg-bs-scoring" -ForegroundColor DarkGray
    exit 1
}

# Import manifest utilities
. (Join-Path $BotDir "systems\runtime\modules\workflow-manifest.ps1")

$workflowsDir = Join-Path $BotDir "workflows"
if (-not (Test-Path $workflowsDir)) {
    New-Item -Path $workflowsDir -ItemType Directory -Force | Out-Null
}

# Resolve source directory
$wfSourceDir = $null
if ($Name -match '^([^:]+):(.+)$') {
    $namespace = $Matches[1]
    $wfShortName = $Matches[2]
    $candidate = Join-Path $DotbotBase "registries\$namespace\workflows\$wfShortName"
    if (Test-Path $candidate) { $wfSourceDir = $candidate }
    $displayName = $wfShortName
} else {
    $candidate = Join-Path $DotbotBase "workflows\$Name"
    if (Test-Path $candidate) { $wfSourceDir = $candidate }
    $displayName = $Name
}

if (-not $wfSourceDir) {
    Write-DotbotError "Workflow not found: $Name"
    exit 1
}

$wfTargetDir = Join-Path $workflowsDir $displayName
if ((Test-Path $wfTargetDir) -and -not $Force) {
    Write-DotbotWarning "Workflow '$displayName' already installed. Use --Force to overwrite."
    exit 1
}
if ((Test-Path $wfTargetDir) -and $Force) {
    Remove-Item $wfTargetDir -Recurse -Force
}

Write-Status "Installing workflow: $displayName"

# Copy files
New-Item -Path $wfTargetDir -ItemType Directory -Force | Out-Null
$wfSourceDirFull = [System.IO.Path]::GetFullPath($wfSourceDir)
Get-ChildItem -Path $wfSourceDir -Recurse -File | ForEach-Object {
    $relativePath = [System.IO.Path]::GetRelativePath($wfSourceDirFull, $_.FullName)
    $relativePathKey = $relativePath -replace '\\', '/'
    if ($relativePathKey -eq "on-install.ps1") { return }
    if ($relativePathKey -eq "manifest.yaml") { return }
    if ($relativePathKey -match '^systems/mcp/tools/(.+)$') { $relativePath = "tools/$($Matches[1])" }
    if ($relativePathKey -eq "settings/settings.default.json") { $relativePath = "settings.json" }

    $destPath = Join-Path $wfTargetDir $relativePath
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -Path $_.FullName -Destination $destPath -Force
}

# Copy workflow.yaml
$wfYamlSource = Join-Path $wfSourceDir "workflow.yaml"
$wfYamlTarget = Join-Path $wfTargetDir "workflow.yaml"
if (Test-Path $wfYamlSource) {
    Copy-Item $wfYamlSource $wfYamlTarget -Force
} elseif (-not (Test-Path $wfYamlTarget)) {
    $manifestYaml = Join-Path $wfSourceDir "manifest.yaml"
    if (Test-Path $manifestYaml) { Copy-Item $manifestYaml $wfYamlTarget -Force }
}

# Parse manifest
$manifest = Read-WorkflowManifest -WorkflowDir $wfTargetDir

# Scaffold .env.local
$envVars = @()
if ($manifest.requires -and $manifest.requires.env_vars) { $envVars = @($manifest.requires.env_vars) }
elseif ($manifest.requires -and $manifest.requires['env_vars']) { $envVars = @($manifest.requires['env_vars']) }
if ($envVars.Count -gt 0) {
    New-EnvLocalScaffold -EnvLocalPath (Join-Path $ProjectDir ".env.local") -EnvVars $envVars
}

# Merge MCP servers
if ($manifest.mcp_servers) {
    $added = Merge-McpServers -McpJsonPath (Join-Path $ProjectDir ".mcp.json") -WorkflowServers $manifest.mcp_servers
    if ($added -gt 0) { Write-Host "  Merged $added MCP server(s) into .mcp.json" -ForegroundColor Gray }
}

# Update installed_workflows list + merge domain.task_categories from manifest
$settingsPath = Join-Path $BotDir "settings\settings.default.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $existing = @()
    if ($settings.PSObject.Properties['installed_workflows']) { $existing = @($settings.installed_workflows) }
    if ($displayName -notin $existing) { $existing += $displayName }
    $settings | Add-Member -NotePropertyName "installed_workflows" -NotePropertyValue $existing -Force

    # Merge custom task_categories from workflow manifest domain section
    if ($manifest.domain -and $manifest.domain['task_categories']) {
        $wfCategories = @($manifest.domain['task_categories'])
        $currentCategories = @()
        if ($settings.PSObject.Properties['task_categories']) { $currentCategories = @($settings.task_categories) }
        $merged = @($currentCategories + $wfCategories | Select-Object -Unique)
        $settings | Add-Member -NotePropertyName "task_categories" -NotePropertyValue $merged -Force
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
}

Write-Success "Workflow '$displayName' installed to .bot/workflows/$displayName/"
