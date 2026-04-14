#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remove an installed workflow from a dotbot project.

.PARAMETER Name
    Workflow name (e.g., "iwg-bs-scoring").
#>
param(
    [Parameter(Position = 0)]
    [string]$Name
)

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "workflows\default\systems\runtime\modules\DotBotTheme.psm1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found."
    exit 1
}

if (-not $Name) {
    Write-DotbotWarning "Usage: dotbot workflow remove <name>"
    exit 1
}

# Import manifest utilities
. (Join-Path $BotDir "systems\runtime\modules\workflow-manifest.ps1")

$wfDir = Join-Path $BotDir "workflows\$Name"
if (-not (Test-Path $wfDir)) {
    Write-DotbotError "Workflow '$Name' is not installed."
    exit 1
}

Write-Status "Removing workflow: $Name"

# Clear tasks belonging to this workflow
$tasksDir = Join-Path $BotDir "workspace\tasks"
$removed = Clear-WorkflowTasks -TasksBaseDir $tasksDir -WorkflowName $Name
if ($removed -gt 0) {
    Write-DotbotCommand "Removed $removed task(s)"
}

# Remove workflow directory
Remove-Item $wfDir -Recurse -Force
Write-DotbotCommand "Removed .bot/workflows/$Name/"

# Clean orphaned MCP servers
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
$workflowsDir = Join-Path $BotDir "workflows"
$orphansRemoved = Remove-OrphanMcpServers -McpJsonPath $mcpJsonPath -WorkflowsDir $workflowsDir
if ($orphansRemoved -gt 0) {
    Write-DotbotCommand "Removed $orphansRemoved orphaned MCP server(s) from .mcp.json"
}

# Update installed_workflows list
$settingsPath = Join-Path $BotDir "settings\settings.default.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    if ($settings.PSObject.Properties['installed_workflows']) {
        $settings.installed_workflows = @($settings.installed_workflows | Where-Object { $_ -ne $Name })
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    }
}

Write-Success "Workflow '$Name' removed."
