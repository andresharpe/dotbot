# ═══════════════════════════════════════════════════════════════
# enter-skipped — Dotbot transition hook (PRD-06).
#
# Side effects: fire WorkflowRun status aggregation. The actual aggregator
# is PRD-12; this hook is the documented call site so the wiring is in
# place before that PRD lands.
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
        Message  = "Skipped — run aggregation is a PRD-12 follow-up."
        Duration = $sw.Elapsed
    }
}

Export-ModuleMember -Function Invoke-Hook
