#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Launch a workflow-agnostic task runner that drains pending todo tasks.

.DESCRIPTION
    Spawns the task-runner with no -Workflow filter, so it picks up any
    eligible todo task regardless of `task.workflow`. Closes the gap left
    by PR #274 for orphan/untagged tasks (see #324, #301).
#>
param()

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "workflows\default\systems\runtime\modules\DotBotTheme.psm1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

$lpPath = Join-Path $BotDir "systems\runtime\launch-process.ps1"
if (-not (Test-Path $lpPath)) {
    Write-DotbotError "launch-process.ps1 not found at $lpPath"
    exit 1
}

Write-DotbotBanner -Title "D O T B O T" -Subtitle "Pending tasks runner"
Write-Status "Launching workflow-agnostic task runner..."

$wfArgs = @(
    "-NoProfile", "-File", $lpPath,
    "-Type", "task-runner",
    "-Continue",
    "-Description", "Pending tasks (unfiltered)"
)

Start-Process pwsh -ArgumentList $wfArgs -WorkingDirectory $ProjectDir

Write-BlankLine
Write-Success "Pending-tasks runner started. Use .bot/go.ps1 to monitor progress."
Write-BlankLine
