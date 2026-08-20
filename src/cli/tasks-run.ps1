#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Launch a workflow-agnostic task runner that drains pending todo tasks.

.DESCRIPTION
    Spawns the task-runner with no -Workflow filter, so it picks up any
    eligible todo task regardless of `task.workflow`. Closes the gap left
    by PR #274 for orphan/untagged tasks (see #324, #301).
#>
[CmdletBinding()]
param(
    [switch]$NoAutoRuntime
)

$ErrorActionPreference = "Stop"


Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src/cli/Platform-Functions.psm1") -Force
Import-Module (Join-Path (Get-DotbotInstallPath) "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1") -Force -DisableNameChecking

$lpPath = Join-Path $DotbotBase "src/runtime/Scripts/Invoke-DotbotProcess.ps1"
if (-not (Test-Path $lpPath)) {
    Write-DotbotError "Invoke-DotbotProcess.ps1 not found at $lpPath"
    exit 1
}

Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1") -Force -DisableNameChecking

Write-DotbotBanner -Title "D O T B O T" -Subtitle "Pending tasks runner"
Write-Status "Launching workflow-agnostic task runner..."

$runtimeAlive = (Test-RuntimeAlive -BotRoot $BotDir) -and (Test-RuntimeServing -BotRoot $BotDir)
if (-not $runtimeAlive -and $NoAutoRuntime) {
    Write-DotbotError "The dotbot runtime is not running."
    Write-DotbotCommand "Run 'dotbot serve' in another shell, or omit --no-auto-runtime."
    exit 1
}

if (-not $runtimeAlive) {
    Write-Status "Starting headless runtime..."
    try {
        $runtimeStart = Start-DotbotRuntimeDetached -BotRoot $BotDir
    } catch {
        Write-DotbotError $_.Exception.Message
        Write-DotbotCommand "Start it manually with 'dotbot serve' in another shell."
        exit 1
    }
    Write-Success ("Runtime ready at {0}" -f $runtimeStart.url)
} else {
    Write-DotbotCommand "Using existing headless runtime."
}

$wfArgs = @(
    "-Type", "task-runner",
    "-Continue",
    "-Description", "Pending tasks (unfiltered)"
)

$null = Start-DotbotChildProcess -File $lpPath -FileArguments $wfArgs -WorkingDirectory $ProjectDir

Write-BlankLine
Write-Success "Pending-tasks runner started. Use 'dotbot runtime-status' to monitor progress."
Write-BlankLine
