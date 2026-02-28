# Import task index module
$indexModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskIndexCache.psm1"
if (-not (Get-Module TaskIndexCache)) {
    Import-Module $indexModule -Force
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
    
    # Default to preferring analysed tasks (can be overridden)
    if ($null -eq $preferAnalysed) {
        $preferAnalysed = $true
    }

    Write-Verbose "[task-get-next] Using cached task index (prefer_analysed: $preferAnalysed)"

    $index = Get-TaskIndex
    $nextTask = $null
    $taskStatus = 'todo'
    
    # Priority order:
    # 1. Analysed tasks (ready for implementation, already pre-processed)
    # 2. Todo tasks (need analysis first, or legacy mode)
    
    $blockedCount = 0

    if ($preferAnalysed) {
        # Check for analysed tasks first (dependency-aware)
        $analysedResult = Get-NextAnalysedTask
        if ($analysedResult.Task) {
            $nextTask = $analysedResult.Task
            $taskStatus = 'analysed'
            $blockedCount = $analysedResult.BlockedCount
            Write-Verbose "[task-get-next] Found analysed task: $($nextTask.id) ($blockedCount blocked by dependencies)"
        } elseif ($analysedResult.BlockedCount -gt 0) {
            Write-Verbose "[task-get-next] All $($analysedResult.BlockedCount) analysed task(s) blocked by unmet dependencies"
        }
    }

    # Fallback behavior:
    # - prefer_analysed = true  -> try analysed first, then todo
    # - prefer_analysed = false -> todo only (used by analysis phase)
    if (-not $nextTask) {
        $nextTask = Get-NextTask
        if ($nextTask) {
            $taskStatus = 'todo'
        }
    }

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

        Write-Verbose "[task-get-next] No eligible tasks found"
        return @{
            success = $true
            task = $null
            message = $statusMessage
            analysing_count = $analysingCount
            needs_input_count = $needsInputCount
            blocked_count = $blockedCount
        }
    }

    Write-Verbose "[task-get-next] Selected task: $($nextTask.id) - $($nextTask.name) (Priority: $($nextTask.priority), Status: $taskStatus)"

    # Return the highest priority task
    if ($verbose) {
        $taskObj = @{
            id = $nextTask.id
            name = $nextTask.name
            status = $taskStatus
            priority = $nextTask.priority
            effort = $nextTask.effort
            category = $nextTask.category
            description = $nextTask.description
            dependencies = $nextTask.dependencies
            acceptance_criteria = $nextTask.acceptance_criteria
            steps = $nextTask.steps
            applicable_agents = $nextTask.applicable_agents
            applicable_standards = $nextTask.applicable_standards
            file_path = $nextTask.file_path
            needs_interview = $nextTask.needs_interview
            questions_resolved = $nextTask.questions_resolved
        }
    } else {
        $taskObj = @{
            id = $nextTask.id
            name = $nextTask.name
            status = $taskStatus
            priority = $nextTask.priority
            effort = $nextTask.effort
            category = $nextTask.category
        }
    }

    $sourceLabel = if ($taskStatus -eq 'analysed') { 'analysed (ready)' } else { 'todo (needs analysis)' }
    
    return @{
        success = $true
        task = $taskObj
        message = "Next task to work on: $($nextTask.name) (Priority: $($nextTask.priority), Effort: $($nextTask.effort), Source: $sourceLabel)"
    }
}
