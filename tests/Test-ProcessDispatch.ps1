#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Validation tests for the launch-process.ps1 dispatcher.
.DESCRIPTION
    Tests that the dispatcher correctly routes to process type scripts,
    validates the file structure after the Phase 03 decomposition.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: Process Dispatch Tests" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally - run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Process Dispatch"
    exit 1
}

$runtimeDir = Join-Path $dotbotDir "core/runtime"
$modulesDir = Join-Path $runtimeDir "modules"
$processTypesDir = Join-Path $modulesDir "ProcessTypes"

# ===================================================================
# FILE STRUCTURE
# ===================================================================

Write-Host "  FILE STRUCTURE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Assert-True -Name "launch-process.ps1 exists" `
    -Condition (Test-Path (Join-Path $runtimeDir "launch-process.ps1")) `
    -Message "Dispatcher not found"

Assert-True -Name "ProcessRegistry.psm1 exists" `
    -Condition (Test-Path (Join-Path $modulesDir "ProcessRegistry.psm1")) `
    -Message "ProcessRegistry module not found"

Assert-True -Name "InterviewLoop.ps1 exists" `
    -Condition (Test-Path (Join-Path $modulesDir "InterviewLoop.ps1")) `
    -Message "InterviewLoop not found"

$processTypeFiles = @(
    "Invoke-PromptProcess.ps1",
    "Invoke-WorkflowProcess.ps1"
)
foreach ($ptFile in $processTypeFiles) {
    Assert-True -Name "ProcessTypes/$ptFile exists" `
        -Condition (Test-Path (Join-Path $processTypesDir $ptFile)) `
        -Message "$ptFile not found in ProcessTypes/"
}

# Regression guard: legacy engines must not be re-introduced.
$deletedEngines = @("Invoke-KickstartProcess.ps1", "Invoke-AnalysisProcess.ps1", "Invoke-ExecutionProcess.ps1")
foreach ($deleted in $deletedEngines) {
    Assert-True -Name "Legacy engine $deleted is deleted (PR-3)" `
        -Condition (-not (Test-Path (Join-Path $processTypesDir $deleted))) `
        -Message "$deleted should not exist after PR-3 engine deletion"
}

# ===================================================================
# DISPATCHER LINE COUNT
# ===================================================================

Write-Host "  DISPATCHER SIZE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$dispatcherLines = @(Get-Content (Join-Path $runtimeDir "launch-process.ps1")).Count
Assert-True -Name "launch-process.ps1 is under 500 lines (dispatcher-only)" `
    -Condition ($dispatcherLines -lt 500) `
    -Message "Got $dispatcherLines lines - expected under 500 after decomposition"

# ===================================================================
# DISPATCH REFERENCES
# ===================================================================

Write-Host "  DISPATCH REFERENCES" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$dispatcherContent = Get-Content (Join-Path $runtimeDir "launch-process.ps1") -Raw

Assert-True -Name "Dispatcher references Invoke-WorkflowProcess.ps1" `
    -Condition ($dispatcherContent -match 'Invoke-WorkflowProcess\.ps1') `
    -Message "No reference to workflow process type"

Assert-True -Name "Dispatcher references Invoke-PromptProcess.ps1" `
    -Condition ($dispatcherContent -match 'Invoke-PromptProcess\.ps1') `
    -Message "No reference to prompt process type"

# Regression guard: deleted engines must not be re-introduced.
Assert-True -Name "Dispatcher does NOT reference Invoke-KickstartProcess.ps1 (PR-3 deletion)" `
    -Condition (-not ($dispatcherContent -match 'Invoke-KickstartProcess\.ps1')) `
    -Message "Reference to deleted kickstart engine should not exist"
Assert-True -Name "Dispatcher does NOT reference Invoke-AnalysisProcess.ps1 (PR-3 deletion)" `
    -Condition (-not ($dispatcherContent -match 'Invoke-AnalysisProcess\.ps1')) `
    -Message "Reference to deleted analysis engine should not exist"
Assert-True -Name "Dispatcher does NOT reference Invoke-ExecutionProcess.ps1 (PR-3 deletion)" `
    -Condition (-not ($dispatcherContent -match 'Invoke-ExecutionProcess\.ps1')) `
    -Message "Reference to deleted execution engine should not exist"

Assert-True -Name "Dispatcher imports ProcessRegistry.psm1" `
    -Condition ($dispatcherContent -match 'ProcessRegistry\.psm1') `
    -Message "ProcessRegistry module not imported"

# ===================================================================
# VALID TYPE HANDLING
# ===================================================================

Write-Host "  TYPE HANDLING" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$validTypes = @('task-runner', 'planning', 'commit', 'task-creation')
foreach ($vt in $validTypes) {
    Assert-True -Name "Dispatcher handles type '$vt'" `
        -Condition ($dispatcherContent -match [regex]::Escape("'$vt'")) `
        -Message "Type '$vt' not found in dispatcher"
}

# Regression guard: deleted types must not appear in ValidateSet.
$deletedTypes = @('analysis', 'execution', 'kickstart', 'analyse')
foreach ($dt in $deletedTypes) {
    Assert-True -Name "Dispatcher ValidateSet does NOT include '$dt' (PR-3 deletion)" `
        -Condition (-not ($dispatcherContent -match "ValidateSet\([^)]*'$dt'")) `
        -Message "Deleted type '$dt' should not appear in ValidateSet"
}

# ===================================================================
# PROCESS TYPE SCRIPTS HAVE CONTEXT PARAMETER
# ===================================================================

Write-Host "  CONTEXT PARAMETER" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

foreach ($ptFile in $processTypeFiles) {
    $ptContent = Get-Content (Join-Path $processTypesDir $ptFile) -Raw
    Assert-True -Name "$ptFile accepts -Context parameter" `
        -Condition ($ptContent -match '\$Context') `
        -Message "$ptFile does not use `$Context parameter"
}

# ===================================================================
# TASK-RUNNER DISPATCH: BARRIER TASK TYPE
# ===================================================================

Write-Host "  BARRIER TASK TYPE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$workflowProcessFile = Join-Path $processTypesDir "Invoke-WorkflowProcess.ps1"
$workflowProcessContent = Get-Content $workflowProcessFile -Raw

Assert-True -Name "Task-runner dispatch handles 'barrier' task type" `
    -Condition ($workflowProcessContent -match "'barrier'\s*\{") `
    -Message "No 'barrier' case in task type dispatch switch"

Assert-True -Name "Barrier task type sets typeSuccess to true" `
    -Condition ($workflowProcessContent -match '(?s)''barrier''\s*\{.*?\$typeSuccess\s*=\s*\$true') `
    -Message "Barrier case does not set `$typeSuccess = `$true"

# ===================================================================
# CLI: workflow-run.ps1 TYPE STRING
# ===================================================================

Write-Host "  CLI WORKFLOW-RUN TYPE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$wfRunScript = Join-Path $dotbotDir "scripts\workflow-run.ps1"
if (Test-Path $wfRunScript) {
    $wfRunContent = Get-Content $wfRunScript -Raw

    Assert-True -Name "workflow-run.ps1 passes -Type 'task-runner' (not 'workflow')" `
        -Condition ($wfRunContent -match '"-Type",\s*"task-runner"') `
        -Message "workflow-run.ps1 still uses wrong type string"

    Assert-True -Name "workflow-run.ps1 does not pass -Type 'workflow'" `
        -Condition (-not ($wfRunContent -match '"-Type",\s*"workflow"')) `
        -Message "workflow-run.ps1 still contains -Type 'workflow' (regression)"
} else {
    Write-TestResult -Name "workflow-run.ps1 exists" -Status Skip -Message "Script not found at $wfRunScript"
}

Write-Host ""

# ===================================================================
# SUMMARY
# ===================================================================

$allPassed = Write-TestSummary -LayerName "Layer 2: Process Dispatch"

if (-not $allPassed) {
    exit 1
}
