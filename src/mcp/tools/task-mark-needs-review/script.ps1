function Invoke-TaskMarkNeedsReview {
    param([hashtable]$Arguments)

    $taskId = $Arguments['task_id']
    if (-not $taskId) { throw "Task ID is required" }
    $reason = $Arguments['reason']

    # Read current task state
    $resp = Invoke-McpRuntimeRequest -Method GET -Path "/tasks/$taskId"
    if (-not $resp) { throw "Task '$taskId' not found" }

    # Idempotent: already parked for review
    if ([string]$resp.status -eq 'needs-review') {
        return @{
            success    = $true
            message    = "Task is already in needs-review status"
            task_id    = $taskId
            old_status = 'needs-review'
            new_status = 'needs-review'
        }
    }

    # Require in-progress source state
    if ([string]$resp.status -ne 'in-progress') {
        return @{ success = $false; error = "Task '$taskId' is in status '$($resp.status)', not in-progress; refusing to park for review" }
    }

    # Require extensions.review.required === true (the per-task opt-in flag)
    $reviewExt = $null
    if ($resp.extensions -and $resp.extensions.PSObject.Properties['review']) {
        $reviewExt = $resp.extensions.review
    }
    $required = $false
    if ($reviewExt -and $reviewExt.PSObject.Properties['required']) {
        $required = [bool]$reviewExt.required
    }
    if (-not $required) {
        return @{ success = $false; error = "Task '$taskId' does not have extensions.review.required=true; refusing to park for review" }
    }

    # Capture pending commit SHA so the reject path knows what to discard.
    # Worktree map lookup is best-effort in case the map was already cleaned.
    $pendingCommit = $null
    try {
        if (-not (Get-Module Dotbot.Worktree)) {
            $candidates = @(
                (Join-Path $global:DotbotProjectRoot ".bot/src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1"),
                (Join-Path $env:DOTBOT_HOME "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1")
            )
            foreach ($c in $candidates) {
                if ($c -and (Test-Path $c)) {
                    Import-Module $c -DisableNameChecking -Global -ErrorAction SilentlyContinue
                    break
                }
            }
        }
        if (Get-Command Get-TaskWorktreeInfo -ErrorAction SilentlyContinue) {
            $info = Get-TaskWorktreeInfo -TaskId $taskId -BotRoot $global:DotbotBotRoot
            if ($info -and $info.worktree_path -and (Test-Path $info.worktree_path)) {
                $sha = git -C $info.worktree_path rev-parse HEAD 2>$null
                if ($LASTEXITCODE -eq 0) { $pendingCommit = $sha.Trim() }
            }
        }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Could not capture review commit SHA for task $taskId" -Exception $_
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    # PATCH extensions.review with the review payload (deep-merged by the runtime)
    $reviewPatch = @{
        status       = 'pending'
        requested_at = $now
    }
    if ($pendingCommit) { $reviewPatch['pending_commit'] = $pendingCommit }
    if ($reason)        { $reviewPatch['request_reason'] = $reason }

    $null = Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body @{
        actor      = Get-McpActor
        extensions = @{ review = $reviewPatch }
    }

    # Transition status
    $statusBody = @{ to = 'needs-review'; actor = Get-McpActor }
    if ($reason) { $statusBody['reason'] = $reason }
    $null = Invoke-McpRuntimeRequest -Method POST -Path "/tasks/$taskId/status" -Body $statusBody

    # Notify reviewers that the task has entered needs-review. Best-effort and
    # server-mediated (Teams / Slack / Jira) via the existing notification path —
    # a no-op when notifications are disabled, the module is absent, or the server
    # is unreachable. A delivery failure here NEVER reverts the transition
    # (mirrors the merge-failure park's best-effort emission).
    $notified            = $false
    $notificationReason  = $null
    try {
        if (-not (Get-Module Dotbot.Notification)) {
            $notifCandidates = @(
                (Join-Path $global:DotbotProjectRoot ".bot/src/runtime/Modules/Dotbot.Notification/Dotbot.Notification.psd1"),
                (Join-Path $env:DOTBOT_HOME "src/runtime/Modules/Dotbot.Notification/Dotbot.Notification.psd1")
            )
            foreach ($c in $notifCandidates) {
                if ($c -and (Test-Path $c)) {
                    Import-Module $c -DisableNameChecking -Global -ErrorAction SilentlyContinue
                    break
                }
            }
        }

        if (Get-Command Send-ReviewNotification -ErrorAction SilentlyContinue) {
            $botRoot  = $global:DotbotBotRoot
            $settings = Get-NotificationSettings -BotRoot $botRoot
            if ($settings.enabled) {
                # Synthesize the task content for the card from values already in
                # scope — avoids a re-GET and keeps requested_at = $now so the
                # idempotency key is stable across retries of this same request.
                $reviewTask = [PSCustomObject]@{
                    id         = $taskId
                    name       = [string]$resp.name
                    extensions = [PSCustomObject]@{
                        review = [PSCustomObject]@{ requested_at = $now }
                    }
                }

                # Best-effort review link: the control-plane URL is the one endpoint
                # configured for out-of-process access. Omitted when unset. The card
                # is informational (no in-channel Approve / Reject) — the reviewer
                # acts in the dotbot dashboard, so this link is the call-to-action.
                $reviewLinks = @()
                try {
                    $merged = Get-MergedSettings -BotRoot $botRoot
                    $cpUrl = if ($merged.PSObject.Properties['control_plane'] -and
                                 $merged.control_plane -and
                                 $merged.control_plane.PSObject.Properties['url']) {
                        "$($merged.control_plane.url)"
                    } else { "" }
                    if ($cpUrl) { $reviewLinks = @(@{ title = "Open review dashboard"; url = $cpUrl }) }
                } catch { }

                $sendResult = Send-ReviewNotification -TaskContent $reviewTask -Settings $settings `
                    -Reason $reason -Actor (Get-McpActor) -ReviewLinks $reviewLinks `
                    -DeliverableSummary $reason
                if ($sendResult -and $sendResult.success) {
                    $notified = $true
                    # Record notification metadata on the review extension
                    # (deep-merged). Best-effort — a PATCH failure must not unwind
                    # the transition.
                    try {
                        $null = Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body @{
                            actor      = Get-McpActor
                            extensions = @{ review = @{ notification = @{
                                question_id = $sendResult.question_id
                                instance_id = $sendResult.instance_id
                                channel     = $sendResult.channel
                                project_id  = $sendResult.project_id
                                sent_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                            } } }
                        }
                    } catch {
                        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                            Write-BotLog -Level Debug -Message "Could not persist review notification metadata for task $taskId" -Exception $_
                        }
                    }
                } else {
                    $notificationReason = if ($sendResult -and $sendResult.reason) { $sendResult.reason } else { "Send-ReviewNotification failed" }
                }
            } else {
                $notificationReason = "Notifications disabled"
            }
        } else {
            $notificationReason = "Dotbot.Notification module not found"
        }
    } catch {
        $notificationReason = "Notification error: $($_.Exception.Message)"
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "needs-review notification failed for task $taskId" -Exception $_
        }
    }

    return @{
        success             = $true
        message             = "Task parked for human review"
        task_id             = $taskId
        task_name           = [string]$resp.name
        old_status          = 'in-progress'
        new_status          = 'needs-review'
        pending_commit      = $pendingCommit
        notified            = $notified
        notification_reason = $notificationReason
    }
}
