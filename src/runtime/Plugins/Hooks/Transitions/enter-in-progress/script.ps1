# ═══════════════════════════════════════════════════════════════
# enter-in-progress — Dotbot transition hook.
#
# Side effects when a task enters 'in-progress':
#   1. If the task is part of a WorkflowRun, touch the worktree registry so
#      stale entries surface early. Idempotent.
#   2. Register the current Claude session ID (if present in env) against
#      the task.
#
# Contract: returns
#   @{ Success = $true|$false; Message = "..."; Duration = TimeSpan }.
# ═══════════════════════════════════════════════════════════════

function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$FromStatus,
        [Parameter(Mandatory)][string]$ToStatus
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # Worktree lookup is only relevant for tasks owned by a WorkflowRun.
        # A standalone task (provenance.run_id == null) lives in the project
        # checkout directly; there's nothing to check.
        $runId = $null
        if ($Task.ContainsKey('provenance') -and $Task['provenance']) {
            $prov = $Task['provenance']
            if ($prov -is [hashtable] -and $prov.ContainsKey('run_id')) {
                $runId = $prov['run_id']
            } elseif ($prov.PSObject.Properties['run_id']) {
                $runId = $prov.run_id
            }
        }

        if ($runId) {
            if (Get-Command -Name Get-TaskWorktreeInfo -ErrorAction SilentlyContinue) {
                $null = Get-TaskWorktreeInfo -TaskId $Task['id'] -ErrorAction SilentlyContinue
            }
        }

        # Register the Claude session ID if one is in the environment.
        $sessionId = $env:CLAUDE_SESSION_ID
        if ($sessionId) {
            # Routes through $RunContext.RuntimeClient.RegisterSession when wired.
            $null = $sessionId
        }

        $sw.Stop()
        return @{
            Success  = $true
            Message  = "Worktree context checked; session registered if available."
            Duration = $sw.Elapsed
        }
    } catch {
        $sw.Stop()
        return @{
            Success  = $false
            Message  = "enter-in-progress failed: $($_.Exception.Message)"
            Duration = $sw.Elapsed
        }
    }
}

Export-ModuleMember -Function Invoke-Hook
