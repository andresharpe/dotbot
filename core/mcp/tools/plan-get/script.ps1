Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force

function Invoke-PlanGet {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }

    # Resolve task across every valid status. Find-TaskFileById defaults to
    # TaskStore's $script:ValidStatuses so additions to the lifecycle do not
    # silently skip plan_get.
    $found = Find-TaskFileById -TaskId $taskId
    if (-not $found) {
        throw "Task not found with ID: $taskId"
    }

    $task = $found.Content

    # Check if task has plan_path field
    if (-not $task.plan_path) {
        return @{
            success = $true
            has_plan = $false
            task_id = $taskId
            task_name = $task.name
            message = "No plan found for this task"
        }
    }

    # Resolve plan path (relative to project root)
    $botRoot = $global:DotbotProjectRoot
    $planFullPath = Join-Path $botRoot $task.plan_path

    if (-not (Test-Path $planFullPath)) {
        return @{
            success = $true
            has_plan = $false
            task_id = $taskId
            task_name = $task.name
            plan_path = $task.plan_path
            message = "Plan file not found at: $($task.plan_path)"
        }
    }

    # Read and return plan content
    $planContent = Get-Content $planFullPath -Raw

    return @{
        success = $true
        has_plan = $true
        task_id = $taskId
        task_name = $task.name
        plan_path = $task.plan_path
        content = $planContent
        message = "Plan retrieved for task '$($task.name)'"
    }
}
