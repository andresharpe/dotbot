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
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking

Write-BlankLine
Write-DotbotSection -Title "INSTALLED WORKFLOWS"

# two-tier registry. Discover-Workflows returns one entry per name
# from both <BotDir>/workflows/ (project) and <BotDir>/content/workflows/
# (framework); a project entry with the same name shadows the framework
# entry and is reported with `source = 'project (overrides framework)'`.
$discovered = Discover-Workflows -BotRoot $BotDir

if ($discovered.Count -eq 0) {
    Write-DotbotCommand "(none)"
} else {
    foreach ($wf in $discovered) {
        $name = $wf.name
        $desc = if ($wf.description) { $wf.description } else { "" }
        # Colour the value by tier so overrides pop out at a glance.
        $valueType = switch -Regex ($wf.source) {
            '^project \(overrides framework\)$' { 'Warning' }
            '^project$'                         { 'Success' }
            default                             { 'Info' }
        }
        Write-DotbotLabel -Label "$($name.PadRight(24))" -Value "$desc" -ValueType $valueType
        Write-DotbotCommand "$(' ' * 24)source: $($wf.source)"
    }
}

Write-BlankLine
