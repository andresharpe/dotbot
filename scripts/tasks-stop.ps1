#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Signal stop to the workflow-agnostic task runner.

.DESCRIPTION
    Writes a `<id>.stop` file for every running task-runner process whose
    description starts with "Pending tasks". Mirrors the per-workflow stop
    pattern in core/ui/server.ps1.
#>
param()

$ErrorActionPreference = "Stop"


Import-Module (Join-Path $PSScriptRoot ".." "core" "runtime" "modules" "DotbotCore.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force
Import-Module (Join-Path (Get-DotbotInstallPath) "core" "runtime" "modules" "DotBotTheme.psm1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

$processesDir = Join-Path $BotDir ".control\processes"
if (-not (Test-Path $processesDir)) {
    Write-DotbotWarning "No process directory at $processesDir — nothing to stop."
    exit 0
}

$stopped = 0
Get-ChildItem $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $proc = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if ($proc.status -in @('running', 'starting') -and $proc.type -eq 'task-runner' -and "$($proc.description)" -like 'Pending tasks*') {
            $stopFile = Join-Path $processesDir "$($proc.id).stop"
            "stop" | Set-Content $stopFile -Encoding UTF8
            $stopped++
            Write-Status "Stop signal sent to $($proc.id)"
        }
    } catch {
        # Skip unreadable process files silently
    }
}

if ($stopped -eq 0) {
    Write-DotbotWarning "No running pending-tasks runner found."
} else {
    Write-Success "Sent stop signal to $stopped pending-tasks runner(s)."
}
