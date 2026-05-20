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


Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src\cli\Platform-Functions.psm1") -Force
Import-Module (Join-Path (Get-DotbotInstallPath) "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psm1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found."
    exit 1
}

if (-not $Name) {
    Write-DotbotWarning "Usage: dotbot workflow remove <name>"
    exit 1
}

# Import manifest utilities
Import-Module (Join-Path (Get-DotbotProjectRuntimePath) "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psm1") -Force -DisableNameChecking

# PRD-13: resolve through the two-tier registry. When both tiers contain
# the same name, the project tier wins — which is the override the user
# likely wants to drop. The framework copy is preserved (it gets restored
# on the next 'dotbot init').
$resolved = Find-Workflow -BotRoot $BotDir -Name $Name
if (-not $resolved.ok) {
    Write-DotbotError "Workflow '$Name' is not installed."
    exit 1
}
$wfDir = $resolved.path
$wfSource = $resolved.source

Write-Status "Removing workflow '$Name' ($wfSource tier)..."

# Clear tasks belonging to this workflow
$tasksDir = Join-Path $BotDir "workspace\tasks"
$removed = Clear-WorkflowTasks -TasksBaseDir $tasksDir -WorkflowName $Name
if ($removed -gt 0) {
    Write-DotbotCommand "Removed $removed task(s)"
}

# Remove workflow directory
Remove-Item $wfDir -Recurse -Force
Write-DotbotCommand "Removed $wfDir"

# Clean orphaned MCP servers — only scan the framework tier here. The
# project tier holds overrides whose MCP server set must match the
# corresponding framework workflow; cleaning project entries would risk
# stripping servers that a framework workflow still needs.
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
$workflowsDir = Join-Path $BotDir "content" "workflows"
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
