<#
.SYNOPSIS
Prompt executor — entry point for AI-spawning tasks.

PRD-05 names this executor as the thin shim around the existing Claude
harness launch logic in src/runtime/Scripts/Invoke-WorkflowProcess.ps1.
The full extraction of that orchestration is mechanical follow-up work —
this file establishes the contract surface so the dispatcher (and tests)
have a real target.

For now, this executor records the intent of spawning Claude and returns
success without actually launching the harness. The follow-up patch will
import the prompt-build / worktree-ensure / harness-spawn sequence here
and call into Dotbot.Process for tracking.
#>

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    $taskId   = $Task['id']
    $taskName = $Task['name']

    # Compose the prompt content the harness would receive. Real harness
    # invocation arrives in the follow-up patch (PRD-05 Further Notes).
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
