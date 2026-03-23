#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List installed workflows in the current project.
#>
param()

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

# Import manifest utilities
. (Join-Path $BotDir "systems\runtime\modules\workflow-manifest.ps1")

Write-Host ""
Write-Host "  INSTALLED WORKFLOWS" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# Show active (base) workflow from workflow.yaml
$baseManifest = $null
$baseYaml = Join-Path $BotDir "workflow.yaml"
if (Test-Path $baseYaml) {
    $baseManifest = Read-WorkflowManifest -WorkflowDir $BotDir
    $name = if ($baseManifest.name) { $baseManifest.name } else { "default" }
    $desc = if ($baseManifest.description) { $baseManifest.description } else { "" }
    Write-Host "    $($name.PadRight(24))" -NoNewline -ForegroundColor Cyan
    Write-Host $desc -ForegroundColor White
    Write-Host "    $(' ' * 24)" -NoNewline
    Write-Host "(base workflow)" -ForegroundColor DarkGray
}

# Show addon workflows from .bot/workflows/
$workflowsDir = Join-Path $BotDir "workflows"
$addonCount = 0
if (Test-Path $workflowsDir) {
    $wfDirs = @(Get-ChildItem -Path $workflowsDir -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $wfDirs) {
        $manifest = Read-WorkflowManifest -WorkflowDir $d.FullName
        $name = if ($manifest.name) { $manifest.name } else { $d.Name }
        $desc = if ($manifest.description) { $manifest.description } else { "" }
        Write-Host "    $($name.PadRight(24))" -NoNewline -ForegroundColor Yellow
        Write-Host $desc -ForegroundColor White
        $addonCount++
    }
}

if (-not (Test-Path $baseYaml) -and $addonCount -eq 0) {
    Write-Host "    (none)" -ForegroundColor DarkGray
}

Write-Host ""
