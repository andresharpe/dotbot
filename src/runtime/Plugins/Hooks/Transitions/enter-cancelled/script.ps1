# ═══════════════════════════════════════════════════════════════
# enter-cancelled — Dotbot transition hook.
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
        Message  = "Cancelled."
        Duration = $sw.Elapsed
    }
}

Export-ModuleMember -Function Invoke-Hook
