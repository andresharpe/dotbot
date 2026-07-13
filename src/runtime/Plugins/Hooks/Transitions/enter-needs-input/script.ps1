# ===============================================================
# enter-needs-input -- Dotbot transition hook.
#
# Side effect when a task enters 'needs-input':
#   - Dispatch its pending question(s) to mothership (Teams/email/etc.) via
#     Send-TaskNotification, then persist a notifications map keyed by question
#     id so the UI NotificationPoller can match answers back to the questions.
#
# This closes the outbound gap for the generic pause pattern
# (task_update(pending_questions) + task_set_status(needs-input)), which -- unlike
# the interview / review / split paths -- never dispatched to mothership before.
#
# Best-effort only: metadata sets abort_on_failure=false, so a delivery failure
# is logged and never reverts the transition. Sending is gated on
# mothership.enabled; sync_questions is intentionally NOT consulted (it is read
# nowhere else in the codebase).
# ===============================================================

function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$FromStatus,
        [Parameter(Mandatory)][string]$ToStatus
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $botRoot  = if ($RunContext.ContainsKey('BotRoot'))  { $RunContext['BotRoot'] }  else { $null }
        $taskPath = if ($RunContext.ContainsKey('TaskPath')) { $RunContext['TaskPath'] } else { $null }
        if (-not $botRoot -or -not $taskPath) {
            $sw.Stop()
            return @{ Success = $true; Message = "enter-needs-input: no BotRoot/TaskPath in RunContext; skipped."; Duration = $sw.Elapsed }
        }

        # Locate the pending question(s). The generic pause pattern writes them
        # under extensions.runner; the merge-failure single shape lives at the
        # task root. Prefer runner, fall back to root.
        $runner = $null
        if ($Task.ContainsKey('extensions') -and $Task['extensions'] -is [hashtable] -and
            $Task['extensions'].ContainsKey('runner') -and $Task['extensions']['runner'] -is [hashtable]) {
            $runner = $Task['extensions']['runner']
        }
        $batch = $null; $single = $null
        if ($runner) {
            if     ($runner.ContainsKey('pending_questions') -and $runner['pending_questions']) { $batch  = @($runner['pending_questions']) }
            elseif ($runner.ContainsKey('pending_question')  -and $runner['pending_question'])  { $single = $runner['pending_question'] }
        }
        if (-not $batch -and -not $single) {
            if     ($Task.ContainsKey('pending_questions') -and $Task['pending_questions']) { $batch  = @($Task['pending_questions']) }
            elseif ($Task.ContainsKey('pending_question')  -and $Task['pending_question'])  { $single = $Task['pending_question'] }
        }
        if (-not $batch -and -not $single) {
            $sw.Stop()
            return @{ Success = $true; Message = "enter-needs-input: no pending questions; nothing to dispatch."; Duration = $sw.Elapsed }
        }

        # This hook runs in an isolated child runspace, so import the runtime
        # modules it needs (each guarded, following the enter-done precedent).
        $frameworkRoot = if ($env:DOTBOT_HOME) {
            $env:DOTBOT_HOME
        } elseif (Get-Command Get-DotbotInstallPath -ErrorAction SilentlyContinue) {
            Get-DotbotInstallPath
        } else {
            $null
        }
        if (-not $frameworkRoot) {
            $sw.Stop()
            return @{ Success = $true; Message = "enter-needs-input: DOTBOT_HOME unresolved; skipped."; Duration = $sw.Elapsed }
        }
        $modulesBase = Join-Path $frameworkRoot 'src/runtime/Modules'
        if (-not (Get-Command Write-BotLog -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $modulesBase 'Dotbot.Logging/Dotbot.Logging.psd1') -DisableNameChecking -Global -ErrorAction SilentlyContinue
        }
        if (-not (Get-Command Send-TaskNotification -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-NotificationSettings -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $modulesBase 'Dotbot.Notification/Dotbot.Notification.psd1') -DisableNameChecking -Global -ErrorAction Stop
        }
        if (-not (Get-Command Write-TaskFileAtomic -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $modulesBase 'Dotbot.TaskFile/Dotbot.TaskFile.psd1') -DisableNameChecking -Global -ErrorAction Stop
        }

        $settings = Get-NotificationSettings -BotRoot $botRoot
        if (-not $settings.enabled) {
            $sw.Stop()
            return @{ Success = $true; Message = "enter-needs-input: mothership notifications disabled; skipped."; Duration = $sw.Elapsed }
        }

        $utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $sent = 0
        $total = 0

        if ($batch) {
            $total = @($batch).Count
            $notifications = @{}
            foreach ($pq in $batch) {
                $qid = "$($pq.id)"
                if (-not $qid) { continue }
                try {
                    $r = Send-TaskNotification -TaskContent $Task -PendingQuestion $pq -Settings $settings
                    if ($r -and $r.success) {
                        $notifications[$qid] = @{
                            question_id = $r.question_id
                            instance_id = $r.instance_id
                            project_id  = $r.project_id
                            channel     = $r.channel
                            sent_at     = $utc
                        }
                        $sent++
                    } elseif (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                        $why = if ($r -and $r.reason) { $r.reason } else { 'unknown' }
                        Write-BotLog -Level Warn -Message "enter-needs-input: send for question $qid failed: $why"
                    }
                } catch {
                    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                        Write-BotLog -Level Warn -Message "enter-needs-input: send threw for question $qid" -Exception $_
                    }
                }
            }
            if ($notifications.Count -gt 0) {
                # Re-read fresh (inside the task mutex) and merge the map into
                # extensions.runner.notifications -- co-located with
                # pending_questions, which is where the poller resolves it.
                $fresh = Get-Content -LiteralPath $taskPath -Raw | ConvertFrom-Json -AsHashtable
                if (-not $fresh.ContainsKey('extensions') -or $fresh['extensions'] -isnot [hashtable]) { $fresh['extensions'] = @{} }
                if (-not $fresh['extensions'].ContainsKey('runner') -or $fresh['extensions']['runner'] -isnot [hashtable]) { $fresh['extensions']['runner'] = @{} }
                $existing = if ($fresh['extensions']['runner'].ContainsKey('notifications') -and $fresh['extensions']['runner']['notifications'] -is [hashtable]) {
                    $fresh['extensions']['runner']['notifications']
                } else { @{} }
                foreach ($k in $notifications.Keys) { $existing[$k] = $notifications[$k] }
                $fresh['extensions']['runner']['notifications'] = $existing
                Write-TaskFileAtomic -Path $taskPath -Content $fresh -Depth 20 -TaskId "$($fresh['id'])" -BotRoot $botRoot
            }
        } elseif ($single) {
            $total = 1
            try {
                $r = Send-TaskNotification -TaskContent $Task -PendingQuestion $single -Settings $settings
                if ($r -and $r.success) {
                    $note = @{
                        question_id = $r.question_id
                        instance_id = $r.instance_id
                        channel     = $r.channel
                        project_id  = $r.project_id
                        sent_at     = $utc
                    }
                    $fresh = Get-Content -LiteralPath $taskPath -Raw | ConvertFrom-Json -AsHashtable
                    # Co-locate the note with its pending_question (root vs runner).
                    if ($fresh.ContainsKey('pending_question')) {
                        $fresh['notification'] = $note
                    } else {
                        if (-not $fresh.ContainsKey('extensions') -or $fresh['extensions'] -isnot [hashtable]) { $fresh['extensions'] = @{} }
                        if (-not $fresh['extensions'].ContainsKey('runner') -or $fresh['extensions']['runner'] -isnot [hashtable]) { $fresh['extensions']['runner'] = @{} }
                        $fresh['extensions']['runner']['notification'] = $note
                    }
                    Write-TaskFileAtomic -Path $taskPath -Content $fresh -Depth 20 -TaskId "$($fresh['id'])" -BotRoot $botRoot
                    $sent = 1
                } elseif (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                    $why = if ($r -and $r.reason) { $r.reason } else { 'unknown' }
                    Write-BotLog -Level Warn -Message "enter-needs-input: single-question send failed: $why"
                }
            } catch {
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                    Write-BotLog -Level Warn -Message "enter-needs-input: single-question send threw" -Exception $_
                }
            }
        }

        $sw.Stop()
        return @{ Success = $true; Message = "enter-needs-input: dispatched $sent/$total question(s) to mothership."; Duration = $sw.Elapsed }
    } catch {
        # abort_on_failure=false keeps this non-aborting even on an uncaught throw.
        $sw.Stop()
        return @{ Success = $false; Message = "enter-needs-input failed: $($_.Exception.Message)"; Duration = $sw.Elapsed }
    }
}

Export-ModuleMember -Function Invoke-Hook
