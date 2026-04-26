Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

function Invoke-TaskMarkTodo {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    # Clear completion timestamps when reverting to todo
    $updates = @{
        completed_at = $null
        started_at   = $null
    }

    $previousState = Find-TaskFileById -TaskId $taskId
    if (-not $previousState) {
        throw "Task with ID '$taskId' not found"
    }
    $result = Move-TaskState -TaskId $taskId `
        -FromStates @('todo', 'in-progress', 'done', 'skipped') `
        -ToState 'todo' `
        -Updates $updates

    if ($result.already_in_state) {
        return @{
            success = $true
            message = "Task is already marked as todo"
            task_id = $taskId
            status  = 'todo'
        }
    }

    return @{
        success    = $true
        message    = "Task marked as todo"
        task_id    = $taskId
        old_status = $result.old_status
        new_status = 'todo'
        old_path   = $previousState.File.FullName
        new_path   = $result.file_path
    }
}
