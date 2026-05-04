# Import task index module
$indexModule = Join-Path $PSScriptRoot "..\..\mcp\modules\TaskIndexCache.psm1"
if (-not (Get-Module TaskIndexCache)) {
    Import-Module $indexModule -Force
}

# Initialize index on first use
$tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

function Test-TaskCompletion {
    <#
    .SYNOPSIS
    Check if a task has been completed successfully

    .PARAMETER TaskId
    The ID of the task to check

    .PARAMETER ClaudeOutput
    The output from Claude to check for completion markers
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $false)]
        [string]$ClaudeOutput = ""
    )

    # Index always reads fresh from filesystem (no caching)

    # Primary method: look at the task's physical directory (issue #318). We
    # cannot rely on Test-TaskDone here — that helper consults DoneIds, which
    # also includes intentional skips and split parents (dependency satisfiers).
    # The completion check must distinguish "task ended in done/" from "task
    # ended in skipped/cancelled/split"; otherwise the runner squash-merges
    # an intentionally skipped task to main.
    $terminalState = Get-TaskTerminalState -TaskId $TaskId
    if ($terminalState -eq 'done') {
        $task = Get-TaskById -TaskId $TaskId
        return @{
            completed = $true
            method = "TaskStatusCheck"
            reason = "Task found in done directory"
            task_file = $task.file_path
        }
    }
    if ($terminalState) {
        # skipped/cancelled/split — terminal but not done. The runner uses
        # method=TerminalState to clean up the worktree without merging.
        $task = Get-TaskById -TaskId $TaskId
        return @{
            completed     = $true
            method        = "TerminalState"
            reason        = "Task is in terminal state: $terminalState"
            terminal_state = $terminalState
            task_file     = $task.file_path
        }
    }

    # Secondary method: Check for completion marker in Claude output
    # Format: TASK_{TASK_ID}_COMPLETE
    $completionMarker = "TASK_${TaskId}_COMPLETE"
    if ($ClaudeOutput -match [regex]::Escape($completionMarker)) {
        return @{
            completed = $true
            method = "OutputMarker"
            reason = "Completion marker found in Claude output"
            marker = $completionMarker
        }
    }

    # Tertiary method: Check if Claude called task_mark_done via MCP
    # This would be detected by the task being in done directory (covered by primary method)
    # But we can also check the Claude output for MCP tool calls
    if ($ClaudeOutput -match "task_mark_done.*$TaskId" -or
        $ClaudeOutput -match "marked.*complete.*$TaskId") {

        # Double-check if task is actually in done directory
        # (cache was already refreshed at start of function)
        if ((Get-TaskTerminalState -TaskId $TaskId) -eq 'done') {
            $task = Get-TaskById -TaskId $TaskId
            return @{
                completed = $true
                method = "MCPCall"
                reason = "MCP task_mark_done was called and task is in done directory"
                task_file = $task.file_path
            }
        }

        # MCP call detected but task not in done directory
        return @{
            completed = $false
            method = "MCPCallIncomplete"
            reason = "task_mark_done was called but task is not in done directory (verification may have failed)"
        }
    }

    # Task not completed
    return @{
        completed = $false
        method = "NotCompleted"
        reason = "Task not found in done directory and no completion markers detected"
    }
}
