# ═══════════════════════════════════════════════════════════════
# enter-cancelled — Dotbot transition hook (PRD-06).
#
# Side effects: fire WorkflowRun status aggregation, mainly relevant when a
# single task is cancelled directly outside a run cascade. The cascade
# itself (PRD-12) is responsible for the bulk path.
# ═══════════════════════════════════════════════════════════════

function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$FromStatus,
        [Parameter(Mandatory)][string]$ToStatus
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sw.Stop()
    return @{
        Success  = $true
        Message  = "Cancelled — run aggregation is a PRD-12 follow-up."
        Duration = $sw.Elapsed
    }
}

Export-ModuleMember -Function Invoke-Hook
