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

$DotbotBase = Join-Path $HOME "dotbot"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "workflows\default\systems\runtime\modules\DotBotTheme.psm1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

# Import manifest utilities
. (Join-Path $BotDir "systems\runtime\modules\workflow-manifest.ps1")

$wfDir = Join-Path $BotDir "workflows\$WorkflowName"
# Default workflow lives at .bot/ root; installed workflows at .bot/workflows/{name}/
if (-not (Test-Path $wfDir)) {
    # Check if this is the default workflow (manifest at .bot/workflow.yaml)
    $defaultYaml = Join-Path $BotDir "workflow.yaml"
    if ((Test-Path $defaultYaml)) {
        $defaultManifest = Read-WorkflowManifest -WorkflowDir $BotDir
        $defaultName = if ($defaultManifest -and $defaultManifest.name) { $defaultManifest.name } else { 'default' }
        if ($WorkflowName -eq $defaultName -or $WorkflowName -eq 'default') {
            $wfDir = $BotDir
            $WorkflowName = $defaultName
        }
    }
}
if (-not (Test-Path (Join-Path $wfDir "workflow.yaml"))) {
    Write-DotbotError "Workflow '$WorkflowName' is not installed."
    Write-DotbotWarning "Installed workflows:"
    $wfBaseDir = Join-Path $BotDir "workflows"
    if (Test-Path $wfBaseDir) {
        Get-ChildItem $wfBaseDir -Directory | ForEach-Object {
            Write-Status "- $($_.Name)"
        }
    }
    exit 1
}

# Parse manifest
$manifest = Read-WorkflowManifest -WorkflowDir $wfDir

Write-DotbotBanner -Title "D O T B O T   v3.5" -Subtitle "Run Workflow: $WorkflowName"

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

# --- Handle rerun ---
$tasksDir = Join-Path $BotDir "workspace\tasks"
$rerunMode = if ($manifest.rerun) { $manifest.rerun } else { "fresh" }

# Check for existing tasks
$existingCount = 0
foreach ($status in @('todo', 'analysing', 'analysed', 'in-progress', 'done', 'skipped')) {
    $dir = Join-Path $tasksDir $status
    if (Test-Path $dir) {
        Get-ChildItem $dir -Filter "*.json" -File | ForEach-Object {
            try {
                $content = Get-Content $_.FullName -Raw | ConvertFrom-Json
                if ($content.workflow -eq $WorkflowName) { $existingCount++ }
            } catch { Write-DotbotCommand "Parse skipped: $_" }
        }
    }
}

if ($existingCount -gt 0) {
    if ($rerunMode -eq "fresh") {
        Write-Status "Clearing $existingCount existing tasks (rerun: fresh)"
        Clear-WorkflowTasks -TasksBaseDir $tasksDir -WorkflowName $WorkflowName | Out-Null
    } else {
        Write-Status "Keeping $existingCount existing tasks (rerun: append)"
    }
}

# --- Create tasks from manifest ---
$tasks = @()
if ($manifest.tasks) { $tasks = @($manifest.tasks) }

if ($tasks.Count -eq 0) {
    Write-DotbotWarning "No tasks defined in workflow.yaml"
    exit 0
}

Write-Status "Creating $($tasks.Count) task(s) from manifest..."

foreach ($taskDef in $tasks) {
    # Convert PSCustomObject to hashtable if needed
    $td = @{}
    if ($taskDef -is [PSCustomObject]) {
        foreach ($p in $taskDef.PSObject.Properties) { $td[$p.Name] = $p.Value }
    } elseif ($taskDef -is [System.Collections.IDictionary]) {
        $td = $taskDef
    }

    $result = New-WorkflowTask -ProjectBotDir $BotDir -WorkflowName $WorkflowName -TaskDef $td
    Write-DotbotCommand "+ $($result.name)"
}

Write-Success "Created $($tasks.Count) task(s) for $WorkflowName"

# --- Spawn workflow process ---
$lpPath = Join-Path $BotDir "systems\runtime\launch-process.ps1"
Write-Status "Launching workflow process..."

$wfArgs = @(
    "-NoProfile", "-File", $lpPath,
    "-Type", "task-runner",
    "-Continue",
    "-Workflow", $WorkflowName,
    "-Description", "Run: $WorkflowName"
)

Start-Process pwsh -ArgumentList $wfArgs -WorkingDirectory $ProjectDir

Write-BlankLine
Write-Success "Workflow '$WorkflowName' started. Use .bot/go.ps1 to monitor progress."
Write-BlankLine
