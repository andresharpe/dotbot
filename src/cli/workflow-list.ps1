#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List installed workflows in the current project.
#>
param()

$ErrorActionPreference = "Stop"


Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src\cli\Platform-Functions.psm1") -Force

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

# Import manifest utilities
Import-Module (Join-Path (Get-DotbotProjectRuntimePath) "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psm1") -Force -DisableNameChecking

Write-BlankLine
Write-DotbotSection -Title "INSTALLED WORKFLOWS"

# Show active (base) workflow from workflow.yaml
$baseManifest = $null
$hasBase = Test-ValidWorkflowDir -Dir $BotDir
if ($hasBase) {
    $baseManifest = Read-WorkflowManifest -WorkflowDir $BotDir
    $name = if ($baseManifest.name) { $baseManifest.name } else { "default" }
    $desc = if ($baseManifest.description) { $baseManifest.description } else { "" }
    Write-DotbotLabel -Label "$($name.PadRight(24))" -Value "$desc"
    Write-DotbotCommand "$(' ' * 24)(base workflow)"
}

# Show addon workflows from .bot/content/workflows/
$workflowsDir = Join-Path $BotDir "content" "workflows"
$addonCount = 0
if (Test-Path $workflowsDir) {
    $wfDirs = @(Get-ChildItem -Path $workflowsDir -Directory -ErrorAction SilentlyContinue)
    foreach ($d in $wfDirs) {
        if (-not (Test-ValidWorkflowDir -Dir $d.FullName)) {
            continue
        }
        $manifest = Read-WorkflowManifest -WorkflowDir $d.FullName
        $name = if ($manifest.name) { $manifest.name } else { $d.Name }
        $desc = if ($manifest.description) { $manifest.description } else { "" }
        Write-DotbotLabel -Label "$($name.PadRight(24))" -Value "$desc" -ValueType Warning
        $addonCount++
    }
}

if (-not $hasBase -and $addonCount -eq 0) {
    Write-DotbotCommand "(none)"
}

Write-BlankLine
