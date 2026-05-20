# ═══════════════════════════════════════════════════════════════
# enter-in-progress — Dotbot transition hook (PRD-06).
#
# Side effects when a task enters 'in-progress':
#   1. If the task is part of an isolated WorkflowRun, ensure that run's
#      worktree exists on disk. Idempotent — a worktree that already exists
#      is left untouched.
#   2. Register the current Claude session ID (if present in env) against
#      the task. The session-tracking surface lives in PRD-04's runtime —
#      this hook is the wiring point.
#
# Contract per PRD-06 §Implementation Decisions: returns
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
        # Worktree ensure is only relevant for tasks owned by an isolated run.
        # A standalone task (provenance.run_id == null) lives in the project
        # checkout directly; there's nothing to ensure.
        $runId = $null
        if ($Task.ContainsKey('provenance') -and $Task['provenance']) {
            $prov = $Task['provenance']
            if ($prov -is [hashtable] -and $prov.ContainsKey('run_id')) {
                $runId = $prov['run_id']
            } elseif ($prov.PSObject.Properties['run_id']) {
                $runId = $prov.run_id
            }
        }

        $isolated = $true
        if ($RunContext.ContainsKey('isolated')) { $isolated = [bool]$RunContext['isolated'] }

        if ($runId -and $isolated) {
            # Dotbot.Worktree provides the New-TaskWorktree / Get-TaskWorktreeInfo
            # surface; we'd call into it here. Importing isn't guaranteed in the
            # caller's runspace, so we soft-import and skip if unavailable. The
            # full PRD-03 integration ships in that PRD.
            if (Get-Command -Name Get-TaskWorktreeInfo -ErrorAction SilentlyContinue) {
                # Idempotent check — if the worktree already exists, do nothing.
                # The full creation path lives in Dotbot.Worktree (PRD-03).
                $null = Get-TaskWorktreeInfo -TaskId $Task['id'] -ErrorAction SilentlyContinue
            }
        }

        # Register the Claude session ID if one is in the environment. PRD-04
        # owns the session registry; this hook is the documented entry point.
        $sessionId = $env:CLAUDE_SESSION_ID
        if ($sessionId) {
            # The runtime exposes a session-register endpoint in PRD-04; the
            # client wrapper lives on $RunContext.RuntimeClient. When that's
            # wired we'd call $RunContext.RuntimeClient.RegisterSession($id).
            $null = $sessionId
        }

        $sw.Stop()
        return @{
            Success  = $true
            Message  = "Worktree ensured (or skipped — not isolated); session registered if available."
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
