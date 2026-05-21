<#
.SYNOPSIS
Prompt executor — entry point for AI-spawning tasks.

.DESCRIPTION
Thin shim around the Claude harness launch logic in
src/runtime/Scripts/Invoke-WorkflowProcess.ps1. Currently records the
intent of spawning Claude and returns success; the full prompt-build /
worktree-ensure / harness-spawn sequence routes through Dotbot.Process.
#>

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    $taskId   = $Task['id']
    $taskName = $Task['name']

    # Compose the prompt content the harness would receive.
    $promptText = if ($Task.Contains('prompt') -and $Task['prompt']) {
        [string]$Task['prompt']
    } else {
        [string]$Task['description']
    }

    return @{
        Success        = $true
        Message        = "Prompt executor staged for task '$taskName' ($taskId); harness launch is wired separately."
        ExitCode       = 0
        prompt_length  = if ($promptText) { $promptText.Length } else { 0 }
        worktree_path  = $RunContext['worktree_path']
        run_id         = $RunContext['run_id']
    }
}

Export-ModuleMember -Function Invoke-Executor
