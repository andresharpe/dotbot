# ═══════════════════════════════════════════════════════════════
# enter-done — Dotbot transition hook (PRD-06).
#
# Side effects when a task enters 'done':
#   1. Run the framework verification chain — every script under
#      <BotRoot>/hooks/verify/ (alphabetical order). Any failure aborts.
#   2. Extract commit info into the task record (commits since the task's
#      branch diverged from main). Hand-off into the runtime via the
#      RuntimeClient PATCH on $RunContext.
#   3. Close the Claude session, if one was registered.
#   4. Fire WorkflowRun status aggregation (PRD-12).
#
# Aborts on any verification failure (PRD-06 §Implementation Decisions
# bullet: "Aborts on any verification failure"). With abort_on_failure: true
# in metadata, the runtime reverts the transition.
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
        $botRoot = $null
        if ($RunContext.ContainsKey('BotRoot')) { $botRoot = $RunContext['BotRoot'] }
        if (-not $botRoot) {
            $sw.Stop()
            return @{
                Success  = $false
                Message  = "enter-done: RunContext.BotRoot is required to locate the verify chain."
                Duration = $sw.Elapsed
            }
        }

        # ─── 1. Run the verification chain ─────────────────────────────────
        # The chain lives under <BotRoot>/hooks/verify/ (PRD-06 names the
        # path explicitly: "existing .bot/hooks/verify/ chain"). Each script
        # is independent and emits a JSON object with `success: bool`. The
        # first failing script aborts.
        $verifyDir = Join-Path $botRoot (Join-Path 'hooks' 'verify')
        $failedScript = $null
        if (Test-Path -LiteralPath $verifyDir -PathType Container) {
            $scripts = Get-ChildItem -LiteralPath $verifyDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name
            foreach ($s in $scripts) {
                try {
                    $raw = & pwsh -NoProfile -File $s.FullName -TaskId $Task['id'] -Category ([string]$Task['category']) 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        $failedScript = @{ name = $s.Name; reason = "exit code $LASTEXITCODE" }
                        break
                    }
                    if ($raw) {
                        $parsed = $null
                        try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
                        if ($parsed -and ($parsed.PSObject.Properties['success']) -and (-not [bool]$parsed.success)) {
                            $msg = if ($parsed.PSObject.Properties['message']) { [string]$parsed.message } else { 'unknown' }
                            $failedScript = @{ name = $s.Name; reason = $msg }
                            break
                        }
                    }
                } catch {
                    $failedScript = @{ name = $s.Name; reason = $_.Exception.Message }
                    break
                }
            }
        }
        if ($failedScript) {
            $sw.Stop()
            return @{
                Success  = $false
                Message  = "Verify '$($failedScript.name)' failed: $($failedScript.reason)"
                Duration = $sw.Elapsed
            }
        }

        # ─── 2. Commit-info extraction ─────────────────────────────────────
        # The v3 helper extracted commits between the task branch and main;
        # the rewrite re-homes that under PRD-03 (Dotbot.Worktree). When that
        # helper exists, the call site is here. No-op for now — the task
        # transition still completes; commit info is decorative.

        # ─── 3. Close the Claude session ───────────────────────────────────
        # Symmetric with enter-in-progress: when PRD-04's session registry
        # lands, this is the point that closes whatever was opened on entry
        # to in-progress.

        # ─── 4. WorkflowRun status aggregation (PRD-12) ────────────────────
        # When PRD-12 lands, this is the call site for the run-status
        # aggregator: a 'done' task contributes a 'completed' tick to its
        # parent run; the aggregator decides if the run as a whole is done,
        # blocked, or still running.

        $sw.Stop()
        return @{
            Success  = $true
            Message  = "Verification passed; commit-info / session-close / run-aggregation are PRD-03/04/12 follow-ups."
            Duration = $sw.Elapsed
        }
    } catch {
        $sw.Stop()
        return @{
            Success  = $false
            Message  = "enter-done failed: $($_.Exception.Message)"
            Duration = $sw.Elapsed
        }
    }
}

Export-ModuleMember -Function Invoke-Hook
