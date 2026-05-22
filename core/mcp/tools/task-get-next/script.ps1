

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

# Import task index module
$indexModule = Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskIndexCache.psm1"
if (-not (Get-Module TaskIndexCache)) {
    Import-Module $indexModule -Force
}

# Import task store (for Set-TaskState when skipping condition-unmet tasks)
$taskStoreModule = Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1"
if (-not (Get-Module TaskStore)) {
    Import-Module $taskStoreModule -Force
}

# Import ManifestCondition module for Test-ManifestCondition
$manifestConditionModule = Join-Path $global:DotbotProjectRoot ".bot/core/runtime/modules/ManifestCondition.psm1"
if (-not (Get-Module ManifestCondition)) {
    Import-Module $manifestConditionModule -Force
}

# Fail loud if still missing — silent fallback would resurrect #226. Stderr (not Write-BotLog)
# because tool discovery may run before DotBotLog is initialized.
if (-not (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("WARN: [task-get-next] Test-ManifestCondition unavailable - runtime condition checks DISABLED. Re-run 'pwsh install.ps1' or 'dotbot init'.")
}

# Initialize index on first use
$tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

function Invoke-TaskGetNext {
    param(
        [hashtable]$Arguments
    )

    $verbose = $Arguments['verbose'] -eq $true
    $preferAnalysed = $Arguments['prefer_analysed']
    $workflowFilter = $Arguments['workflow_filter']
    
    # Default to preferring analysed tasks (can be overridden)
    if ($null -eq $preferAnalysed) {
        $preferAnalysed = $true
    }

    Write-BotLog -Level Debug -Message "[task-get-next] Using cached task index (prefer_analysed: $preferAnalysed)"

    $nextTask = $null
    $taskStatus = 'todo'
    $blockedCount = 0
    $conditionSkipCount = 0
    $moveFailures = @()

    # Re-evaluate `condition` per candidate (issue #226). Loop so we can skip
    # condition-unmet tasks and pick the next eligible one. Priority: analysed → todo.
    # Bound = current candidate pool size (+ small buffer) so we can't return
    # "no task" while eligible candidates remain behind skipped ones.
    $initialIndex = Get-TaskIndex
    $candidatePoolSize = $initialIndex.Todo.Count + $initialIndex.Analysed.Count
    $maxIterations = [Math]::Max(50, $candidatePoolSize + 10)

    # Track IDs we've already considered in this invocation. Acts as a safety net
    # against re-picking a task whose Set-TaskState failed (so the index still
    # lists it as todo/analysed on subsequent Update-TaskIndex calls).
    $seenIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $iter = 0
    for (; $iter -lt $maxIterations; $iter++) {
        $candidate = $null
        $candidateStatus = 'todo'

        if ($preferAnalysed) {
            $analysedResult = Get-NextAnalysedTask -WorkflowFilter $workflowFilter
            # Track max so the "no tasks available" message stays accurate after skips.
            if ($analysedResult.BlockedCount -gt $blockedCount) {
                $blockedCount = $analysedResult.BlockedCount
            }
            if ($analysedResult.Task -and -not $seenIds.Contains($analysedResult.Task.id)) {
                $candidate = $analysedResult.Task
                $candidateStatus = 'analysed'
                Write-BotLog -Level Debug -Message "[task-get-next] Found analysed task: $($candidate.id) ($($analysedResult.BlockedCount) blocked by dependencies)"
            } elseif ($analysedResult.BlockedCount -gt 0) {
                Write-BotLog -Level Debug -Message "[task-get-next] All $($analysedResult.BlockedCount) analysed task(s) blocked by unmet dependencies"
            }
        }

        # Fallback to todo (or todo-only when prefer_analysed=false, used by analysis phase)
        if (-not $candidate) {
            $todoCandidate = Get-NextTask -WorkflowFilter $workflowFilter
            if ($todoCandidate -and -not $seenIds.Contains($todoCandidate.id)) {
                $candidate = $todoCandidate
                $candidateStatus = 'todo'
            }
        }

        if (-not $candidate) { break }

        [void]$seenIds.Add($candidate.id)

        # If Test-ManifestCondition is missing here we deliberately let PS raise (see load-time check).
        $candidateCondition = if ($candidate.PSObject.Properties['condition']) { $candidate.condition } else { $null }
        if ($candidateCondition) {
            $conditionMet = Test-ManifestCondition -ProjectRoot $global:DotbotProjectRoot -Condition $candidateCondition
            if (-not $conditionMet) {
                $conditionText = if ($candidateCondition -is [array]) { ($candidateCondition -join ', ') } else { "$($candidateCondition)" }
                Write-BotLog -Level Info -Message "[task-get-next] Skipped task '$($candidate.name)' ($($candidate.id)): condition not met ($conditionText)"
                try {
                    Set-TaskState -TaskId $candidate.id `
                        -FromStates @($candidateStatus) `
                        -ToState 'skipped' `
                        -Updates @{
                            skip_reason = 'condition-not-met'
                            skip_detail = "Condition not met at runtime: $conditionText"
                        } | Out-Null
                    $conditionSkipCount++
                    # TODO: incrementalise — full rescan per skip is O(N·skips).
                    Update-TaskIndex
                } catch {
                    # Surface the failure but keep looking — one bad task shouldn't stall
                    # the whole pipeline. $seenIds prevents re-picking this candidate.
                    Write-BotLog -Level Warn -Message "[task-get-next] Failed to move task $($candidate.id) to skipped; continuing with other candidates" -Exception $_
                    $moveFailures += "$($candidate.id) ($($candidate.name))"
                }
                continue
            }
        }

        $nextTask = $candidate
        $taskStatus = $candidateStatus
        break
    }

    if ($iter -ge $maxIterations) {
        Write-BotLog -Level Warn -Message "[task-get-next] Hit maxIterations cap ($maxIterations) — possible stuck task; inspect .bot/workspace/tasks/ for orphans."
    }

    $index = Get-TaskIndex

    if (-not $nextTask) {
        # Check if there are tasks in other states that might explain why nothing is available
        $analysingCount = $index.Analysing.Count
        $needsInputCount = $index.NeedsInput.Count

        $statusMessage = "No pending tasks available."
        if ($blockedCount -gt 0) {
            $statusMessage += " $blockedCount analysed task(s) blocked by unmet dependencies."
        }
        if ($analysingCount -gt 0) {
            $statusMessage += " $analysingCount task(s) being analysed."
        }
        if ($needsInputCount -gt 0) {
            $statusMessage += " $needsInputCount task(s) waiting for input."
        }
        if ($conditionSkipCount -gt 0) {
            $statusMessage += " $conditionSkipCount task(s) skipped (condition not met)."
        }
        if ($moveFailures.Count -gt 0) {
            $statusMessage += " WARNING: $($moveFailures.Count) task(s) stuck (Set-TaskState failed): $($moveFailures -join ', '). Inspect logs and .bot/workspace/tasks/."
        }

        Write-BotLog -Level Debug -Message "[task-get-next] No eligible tasks found"
        return @{
            success = $true
            task = $null
            message = $statusMessage
            analysing_count = $analysingCount
            needs_input_count = $needsInputCount
            blocked_count = $blockedCount
            condition_skip_count = $conditionSkipCount
            move_failures = $moveFailures
        }
    }

    Write-BotLog -Level Debug -Message "[task-get-next] Selected task: $($nextTask.id) - $($nextTask.name) (Priority: $($nextTask.priority), Status: $taskStatus)"

    # Project the PSCustomObject into a hashtable keyed by property name so we
    # can access optional fields without tripping Set-StrictMode -Version 3.0
    # on missing properties (task records vary by workflow).
    $nt = @{}
    foreach ($p in $nextTask.PSObject.Properties) { $nt[$p.Name] = $p.Value }

    # Return the highest priority task
    if ($verbose) {
        $taskObj = @{
            id = $nt['id']
            name = $nt['name']
            status = $taskStatus
            priority = $nt['priority']
            effort = $nt['effort']
            category = $nt['category']
            description = $nt['description']
            dependencies = $nt['dependencies']
            acceptance_criteria = $nt['acceptance_criteria']
            steps = $nt['steps']
            applicable_agents = $nt['applicable_agents']
            applicable_standards = $nt['applicable_standards']
            file_path = $nt['file_path']
            needs_interview = $nt['needs_interview']
            needs_review = $nt['needs_review']
            needs_review_reason = $nt['needs_review_reason']
            reviewer_feedback = $nt['reviewer_feedback']
            review_status = $nt['review_status']
            questions_resolved = $nt['questions_resolved']
            working_dir = $nt['working_dir']
            external_repo = $nt['external_repo']
            research_prompt = $nt['research_prompt']
            type = $nt['type']
            script_path = $nt['script_path']
            prompt = $nt['prompt']
            mcp_tool = $nt['mcp_tool']
            mcp_args = $nt['mcp_args']
            skip_analysis = $nt['skip_analysis']
            skip_worktree = $nt['skip_worktree']
            workflow = $nt['workflow']
            model = $nt['model']
            optional = $nt['optional']
        }
    } else {
        $taskObj = @{
            id = $nt['id']
            name = $nt['name']
            status = $taskStatus
            priority = $nt['priority']
            effort = $nt['effort']
            category = $nt['category']
            type = $nt['type']
            script_path = $nt['script_path']
            prompt = $nt['prompt']
            mcp_tool = $nt['mcp_tool']
            mcp_args = $nt['mcp_args']
            workflow = $nt['workflow']
            model = $nt['model']
            optional = $nt['optional']
        }
    }

    $sourceLabel = if ($taskStatus -eq 'analysed') { 'analysed (ready)' } else { 'todo (needs analysis)' }
    
    return @{
        success = $true
        task = $taskObj
        message = "Next task to work on: $($nextTask.name) (Priority: $($nextTask.priority), Effort: $($nextTask.effort), Source: $sourceLabel)"
    }
}


