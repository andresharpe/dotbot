Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force

function Invoke-TaskMarkTodo {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }

    # Clear completion timestamps and any leftover question state when
    # reverting to todo. Other transitions out of needs-input
    # (task-mark-analysed, task-answer-question) already clear
    # pending_question; without the same here, a singular question left
    # over from an escalation is migrated back into pending_questions[]
    # by task-mark-needs-input on the next failure (see
    # task-mark-needs-input/script.ps1: "Migrate legacy single
    # pending_question into pending_questions"), resurfacing a stale
    # question to the operator.
    $updates = @{
        completed_at      = $null
        started_at        = $null
        pending_question  = $null
        pending_questions = @()
    }

    $previousState = Find-TaskFileById -TaskId $taskId
    if (-not $previousState) {
        throw "Task with ID '$taskId' not found"
    }
    $result = Set-TaskState -TaskId $taskId `
        -FromStates @('todo', 'in-progress', 'done', 'skipped', 'needs-input') `
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


