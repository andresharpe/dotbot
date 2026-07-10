#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deactivate a workflow in a dotbot project.

.DESCRIPTION
    Removes the active workflow entry from .bot/.control/settings.json and,
    if a project tier override directory exists at
    .bot/content/workflows/<name>/, deletes it. Framework workflow content
    under <DOTBOT_HOME> is never modified.

.PARAMETER Name
    Workflow name (e.g., "start-from-jira").
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

Import-Module (Join-Path $DotbotBase "src/cli/Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found."
    exit 1
}

if (-not $Name) {
    Write-DotbotWarning "Usage: dotbot workflow remove <name>"
    exit 1
}

Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

$resolved = Find-Workflow -BotRoot $BotDir -Name $Name
if (-not $resolved.ok) {
    Write-DotbotError "Workflow '$Name' is not installed."
    exit 1
}

Write-Status "Removing workflow '$Name'"

# Clear tasks belonging to this workflow before touching project state.
$tasksDir = Join-Path $BotDir "workspace" "tasks"
$removed = Clear-WorkflowTasks -TasksBaseDir $tasksDir -WorkflowName $Name
if ($removed -gt 0) {
    Write-DotbotCommand "Removed $removed task(s)"
}

# Drop the project tier override directory if present. The framework tier
# under DOTBOT_HOME is never touched.
$projectTier = Join-Path $BotDir "content" "workflows" $Name
if (Test-Path $projectTier) {
    Remove-Item $projectTier -Recurse -Force
    Write-DotbotCommand "Removed override: .bot/content/workflows/$Name/"
}

# Clear the workflow selection from .bot/.control/settings.json. Leave other
# keys (provider, stacks, mothership, etc.) intact.
$controlSettingsPath = Join-Path $BotDir '.control' 'settings.json'
if (Test-Path $controlSettingsPath) {
    try {
        $settings = Get-Content $controlSettingsPath -Raw | ConvertFrom-Json
    } catch {
        $settings = [pscustomobject]@{}
    }
    if ($settings.PSObject.Properties['workflow'] -and $settings.workflow -eq $Name) {
        $settings.PSObject.Properties.Remove('workflow')
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $controlSettingsPath -Encoding UTF8
    }
}

# Inbound decision funnel (issue #416): record workflow removal as a process
# decision. Best-effort -- a failure here must not fail the workflow remove.
try {
    Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Decision" "Dotbot.Decision.psd1") -DisableNameChecking -Global -ErrorAction Stop
    $wfNamespace = if ($Name -match '^([^:]+):(.+)$') { $Matches[1] } else { '' }
    $null = New-InboundDecision -Source registry -BotPath $BotDir -Payload @{
        action    = 'remove'
        namespace = $wfNamespace
        workflow  = $Name
        title     = "Remove workflow $Name"
    }
} catch {
    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        Write-BotLog -Level Warn -Message "Inbound decision funnel (registry remove) failed" -Exception $_
    }
}

Write-Success "Workflow '$Name' removed."
