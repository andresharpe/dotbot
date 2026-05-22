#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Run (or rerun) an installed workflow.

.DESCRIPTION
    Reads the workflow.yaml tasks section, creates task JSONs in the shared queue
    with the workflow field set, runs preflight checks, and spawns a workflow
    process filtered to this workflow's tasks.

.PARAMETER WorkflowName
    Name of the installed workflow (e.g., "iwg-bs-scoring").
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$WorkflowName
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$ProjectDir = Get-DotbotProjectPath
$BotDir = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src\cli\Platform-Functions.psm1") -Force
Import-Module (Join-Path (Get-DotbotInstallPath) "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

Import-Module (Join-Path (Get-DotbotProjectRuntimePath) "Modules" "Dotbot.Process" "Dotbot.Process.psd1") -Force -DisableNameChecking

# Import manifest utilities
Import-Module (Join-Path (Get-DotbotProjectRuntimePath) "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psd1") -Force -DisableNameChecking

# resolve through the two-tier registry — project tier (.bot/workflows/)
# takes precedence over the framework tier (.bot/content/workflows/).
$resolved = Find-Workflow -BotRoot $BotDir -Name $WorkflowName
if (-not $resolved.ok) {
    Write-DotbotError "Workflow '$WorkflowName' is not installed."
    Write-DotbotWarning "Installed workflows:"
    foreach ($wf in (Discover-Workflows -BotRoot $BotDir)) {
        Write-Status "- $($wf.name) ($($wf.source))"
    }
    exit 1
}
$wfDir = $resolved.path
$wfSource = $resolved.source
Write-DotbotCommand "Resolved '$WorkflowName' from $wfSource tier ($wfDir)"

# Parse manifest
$manifest = Read-WorkflowManifest -WorkflowDir $wfDir

Write-DotbotBanner -Title "D O T B O T" -Subtitle "Run Workflow: $WorkflowName"

# --- Preflight checks ---
$envLocalPath = Join-Path $ProjectDir ".env.local"
if ($manifest.requires -and $manifest.requires.env_vars) {
    # Load .env.local
    $envValues = @{}
    if (Test-Path $envLocalPath) {
        Get-Content $envLocalPath | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.+)$') {
                $envValues[$matches[1].Trim()] = $matches[2].Trim()
            }
        }
    }

    $missing = @()
    foreach ($ev in $manifest.requires.env_vars) {
        $varName = if ($ev.var) { $ev.var } elseif ($ev['var']) { $ev['var'] } else { continue }
        if (-not $envValues[$varName]) { $missing += $varName }
    }

    if ($missing.Count -gt 0) {
        Write-DotbotError "Missing required environment variables: $($missing -join ', ')"
        Write-DotbotWarning "Set them in .env.local"
        exit 1
    }
    Write-Success "Preflight: all required env vars present"
}

# --- Mint a fresh WorkflowRun ---
$tasks = @()
if ($manifest.tasks) { $tasks = @($manifest.tasks) }
if ($tasks.Count -eq 0) {
    Write-DotbotWarning "No tasks defined in workflow.yaml"
    exit 0
}

Write-Status "Minting WorkflowRun for '$WorkflowName'..."
$run = Initialize-WorkflowRun `
    -BotRoot         $BotDir `
    -WorkflowName    $WorkflowName `
    -StartedBy       'cli:workflow-run' `
    -WorkflowPath    $wfDir `
    -WorkflowSource  $wfSource
Write-DotbotCommand "Run: $($run.run_id) → $($run.dir_name)"

Write-Status "Creating $($tasks.Count) task(s) under the run..."

foreach ($taskDef in $tasks) {
    $td = @{}
    if ($taskDef -is [PSCustomObject]) {
        foreach ($p in $taskDef.PSObject.Properties) { $td[$p.Name] = $p.Value }
    } elseif ($taskDef -is [System.Collections.IDictionary]) {
        $td = $taskDef
    }

    $result = New-WorkflowTask -Run $run -TaskDef $td
    Write-DotbotCommand "+ $($result.name) [$($result.id)]"
}

Write-Success "Created $($tasks.Count) task(s) for $WorkflowName"

# --- Spawn workflow process ---
$lpPath = Join-Path (Get-DotbotProjectRuntimePath) "Scripts" "Invoke-DotbotProcess.ps1"
Write-Status "Launching workflow process..."

$wfArgs = @(
    "-Type", "task-runner",
    "-Continue",
    "-Workflow", $WorkflowName,
    "-RunId", $run.run_id,
    "-Description", "Run: $WorkflowName"
)

$null = Start-DotbotChildProcess -File $lpPath -FileArguments $wfArgs -WorkingDirectory $ProjectDir

Write-BlankLine
Write-Success "Workflow '$WorkflowName' started. Use .bot/go.ps1 to monitor progress."
Write-BlankLine
