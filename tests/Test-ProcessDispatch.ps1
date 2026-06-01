#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Validation tests for the Invoke-DotbotProcess.ps1 dispatcher.
.DESCRIPTION
    Tests that the dispatcher correctly routes to process type scripts,
    validates the file structure after the Phase 03 decomposition.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-RepoRoot

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: Process Dispatch Tests" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally - set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 2: Process Dispatch"
    exit 1
}

$runtimeDir = Join-Path $dotbotDir "src/runtime"
$scriptsDir = Join-Path $runtimeDir "Scripts"
$modulesDir = Join-Path $runtimeDir "Modules"

# ===================================================================
# FILE STRUCTURE
# ===================================================================

Write-Host "  FILE STRUCTURE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Assert-True -Name "Invoke-DotbotProcess.ps1 exists" `
    -Condition (Test-Path (Join-Path $scriptsDir "Invoke-DotbotProcess.ps1")) `
    -Message "Dispatcher not found"

Assert-True -Name "Dotbot.Process.psm1 exists" `
    -Condition (Test-Path (Join-Path $modulesDir "Dotbot.Process" "Dotbot.Process.psm1")) `
    -Message "Dotbot.Process module not found (provides ProcessRegistry functions)"
Assert-True -Name "Dotbot.Process.psd1 exists" `
    -Condition (Test-Path (Join-Path $modulesDir "Dotbot.Process" "Dotbot.Process.psd1")) `
    -Message "Dotbot.Process manifest not found"

Assert-True -Name "Dotbot.Task.psm1 exists" `
    -Condition (Test-Path (Join-Path $modulesDir "Dotbot.Task" "Dotbot.Task.psm1")) `
    -Message "Dotbot.Task module not found (provides Invoke-InterviewLoop)"

$processTypeFiles = @(
    "Invoke-PromptProcess.ps1",
    "Invoke-WorkflowProcess.ps1"
)
foreach ($ptFile in $processTypeFiles) {
    Assert-True -Name "Scripts/$ptFile exists" `
        -Condition (Test-Path (Join-Path $scriptsDir $ptFile)) `
        -Message "$ptFile not found in Scripts/"
}

# Regression guard: legacy engines must not be re-introduced.
$deletedEngines = @("Invoke-AnalysisProcess.ps1", "Invoke-ExecutionProcess.ps1")
foreach ($deleted in $deletedEngines) {
    Assert-True -Name "Legacy engine $deleted is deleted (PR-3)" `
        -Condition (-not (Test-Path (Join-Path $scriptsDir $deleted))) `
        -Message "$deleted should not exist after PR-3 engine deletion"
}

# ===================================================================
# DISPATCHER LINE COUNT
# ===================================================================

Write-Host "  DISPATCHER SIZE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$dispatcherLines = @(Get-Content (Join-Path $scriptsDir "Invoke-DotbotProcess.ps1")).Count
Assert-True -Name "Invoke-DotbotProcess.ps1 is under 500 lines (dispatcher-only)" `
    -Condition ($dispatcherLines -lt 500) `
    -Message "Got $dispatcherLines lines - expected under 500 after decomposition"

# ===================================================================
# DISPATCH REFERENCES
# ===================================================================

Write-Host "  DISPATCH REFERENCES" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$dispatcherContent = Get-Content (Join-Path $scriptsDir "Invoke-DotbotProcess.ps1") -Raw

Assert-True -Name "Dispatcher references Invoke-WorkflowProcess.ps1" `
    -Condition ($dispatcherContent -match 'Invoke-WorkflowProcess\.ps1') `
    -Message "No reference to workflow process type"

Assert-True -Name "Dispatcher references Invoke-PromptProcess.ps1" `
    -Condition ($dispatcherContent -match 'Invoke-PromptProcess\.ps1') `
    -Message "No reference to prompt process type"

# Regression guard: deleted engines must not be re-introduced.
Assert-True -Name "Dispatcher does NOT reference Invoke-AnalysisProcess.ps1 (PR-3 deletion)" `
    -Condition (-not ($dispatcherContent -match 'Invoke-AnalysisProcess\.ps1')) `
    -Message "Reference to deleted analysis engine should not exist"
Assert-True -Name "Dispatcher does NOT reference Invoke-ExecutionProcess.ps1 (PR-3 deletion)" `
    -Condition (-not ($dispatcherContent -match 'Invoke-ExecutionProcess\.ps1')) `
    -Message "Reference to deleted execution engine should not exist"

Assert-True -Name "Dispatcher imports Dotbot.Process.psd1" `
    -Condition ($dispatcherContent -match 'Dotbot\.Process\.psd1') `
    -Message "Dotbot.Process manifest not imported (provides New-ProcessId, Write-ProcessFile etc.)"

Assert-True -Name "Dispatcher persists run_id in process registry" `
    -Condition ($dispatcherContent -match 'run_id\s*=\s*if \(\$RunId\)') `
    -Message "Process registry files must carry run_id so CLI watch can monitor the exact workflow run"

Assert-True -Name "Dispatcher scopes task-runner launch locks by WorkflowRun ID" `
    -Condition ($dispatcherContent -match 'function\s+New-DotbotLaunchLockKey\b' -and
                $dispatcherContent -match 'task-runner-run-\$WorkflowRunId') `
    -Message "Same-workflow concurrent runs need distinct launch locks keyed by run_id"

Assert-True -Name "Dispatcher keeps unscoped pending-task runner singleton" `
    -Condition ($dispatcherContent -match 'else\s*\{\s*"task-runner"\s*\}') `
    -Message "Only unscoped pending-task runners should share the task-runner singleton lock"

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
$deletedTypes = @('analysis', 'execution', 'analyse')
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
    $ptContent = Get-Content (Join-Path $scriptsDir $ptFile) -Raw
    Assert-True -Name "$ptFile accepts -Context parameter" `
        -Condition ($ptContent -match '\$Context') `
        -Message "$ptFile does not use `$Context parameter"
}

# ===================================================================
# TASK-RUNNER DISPATCH: EXECUTOR DELEGATION
# ===================================================================

Write-Host "  EXECUTOR DELEGATION" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$workflowProcessFile = Join-Path $scriptsDir "Invoke-WorkflowProcess.ps1"
$workflowProcessContent = Get-Content $workflowProcessFile -Raw

Assert-True -Name "Task-runner imports Dotbot.Executor" `
    -Condition ($workflowProcessContent -match 'Dotbot\.Executor\.psd1') `
    -Message "Invoke-WorkflowProcess does not import Dotbot.Executor"

Assert-True -Name "Task-runner delegates non-prompt tasks to Invoke-TaskExecutor" `
    -Condition ($workflowProcessContent -match 'Invoke-TaskExecutor') `
    -Message "Invoke-WorkflowProcess does not delegate to Invoke-TaskExecutor"

Assert-True -Name "Task-runner finalizes WorkflowRun live status" `
    -Condition ($workflowProcessContent -match 'Set-WorkflowRunLiveStatus' -and $workflowProcessContent -match 'New-WorkflowRunStatus') `
    -Message "Workflow runner should update .control/workflow-runs/<run>.json when it exits"

Assert-True -Name "Task-runner uses legal executor status transitions" `
    -Condition ($workflowProcessContent -match 'Set-TaskInProgressForExecutorDispatch' -and $workflowProcessContent -match 'Set-TaskTerminalFailureForExecutorDispatch') `
    -Message "Executor tasks must move through in-progress before terminal states"

Assert-True -Name "Task-runner no longer carries a bespoke barrier switch case" `
    -Condition ($workflowProcessContent -notmatch "'barrier'\s*\{") `
    -Message "Barrier should be handled by the shipped barrier executor"

$enterDoneHook = Join-Path $runtimeDir "Plugins/Hooks/Transitions/enter-done/script.ps1"
$enterDoneContent = Get-Content $enterDoneHook -Raw
Assert-True -Name "enter-done hook imports ContentResolver from DOTBOT_HOME" `
    -Condition ($enterDoneContent -match 'DOTBOT_HOME' -and $enterDoneContent -match 'ContentResolver\.psm1') `
    -Message "enter-done runs as a dynamic module where PSScriptRoot is not reliable"

$smokeWorkflowDir = Join-Path $dotbotDir "content/workflows/smoke-test"
Assert-True -Name "smoke-test workflow exists" `
    -Condition ((Test-Path (Join-Path $smokeWorkflowDir "workflow.json")) -and (Test-Path (Join-Path $smokeWorkflowDir "scripts/smoke.ps1"))) `
    -Message "Expected a built-in headless smoke workflow for CLI watch testing"

# ===================================================================
# CLI: workflow-run.ps1 TYPE STRING
# ===================================================================

Write-Host "  CLI WORKFLOW-RUN TYPE" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$wfRunScript = Join-Path $dotbotDir "src\cli\workflow-run.ps1"
if (Test-Path $wfRunScript) {
    $wfRunContent = Get-Content $wfRunScript -Raw

    Assert-True -Name "workflow-run.ps1 passes -Type 'task-runner' (not 'workflow')" `
        -Condition ($wfRunContent -match '"-Type",\s*"task-runner"') `
        -Message "workflow-run.ps1 still uses wrong type string"

    Assert-True -Name "workflow-run.ps1 does not pass -Type 'workflow'" `
        -Condition (-not ($wfRunContent -match '"-Type",\s*"workflow"')) `
        -Message "workflow-run.ps1 still contains -Type 'workflow' (regression)"

    Assert-True -Name "workflow-run.ps1 exposes watch mode" `
        -Condition ($wfRunContent -match '\[switch\]\$Watch' -and $wfRunContent -match 'Watch-DotbotWorkflowRun') `
        -Message "workflow-run.ps1 should support --watch monitoring without the UI"

    Assert-True -Name "workflow-run.ps1 auto-starts headless runtime for watch mode" `
        -Condition ($wfRunContent -match 'Start-DotbotRuntime' -and $wfRunContent -match 'Test-RuntimeAlive') `
        -Message "watch mode must start or attach to Dotbot.Runtime instead of requiring the UI"
} else {
    Write-TestResult -Name "workflow-run.ps1 exists" -Status Skip -Message "Script not found at $wfRunScript"
}

$dispatcherScript = Join-Path $dotbotDir "bin\dotbot.ps1"
if (Test-Path $dispatcherScript) {
    $dispatcherCliContent = Get-Content $dispatcherScript -Raw
    Assert-True -Name "dotbot.ps1 supports workflow run subcommand" `
        -Condition ($dispatcherCliContent -match "wfSubCmd -eq 'run'" -and $dispatcherCliContent -match 'Get-WorkflowRunInvocation') `
        -Message "Expected dotbot workflow run <name> to dispatch to workflow-run.ps1"

    Assert-True -Name "dotbot.ps1 propagates workflow-run exit codes" `
        -Condition ($dispatcherCliContent -match 'LASTEXITCODE\s*=\s*0' -and $dispatcherCliContent -match 'exit \$LASTEXITCODE') `
        -Message "dotbot run should return workflow-run.ps1 failures to shell callers"
} else {
    Write-TestResult -Name "dotbot.ps1 workflow run dispatch" -Status Skip -Message "Script not found at $dispatcherScript"
}

Write-Host ""

# ===================================================================
# SUMMARY
# ===================================================================

$allPassed = Write-TestSummary -LayerName "Layer 2: Process Dispatch"

if (-not $allPassed) {
    exit 1
}
