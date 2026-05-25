function Invoke-TaskSubmitReview {
    param([hashtable]$Arguments)

    $taskId   = $Arguments['task_id']
    $approved = $Arguments['approved']
    $comment      = $Arguments['comment']
    $whatWasWrong = $Arguments['what_was_wrong']

    if (-not $taskId)        { throw "Task ID is required" }
    if ($null -eq $approved) { throw "approved flag is required (true or false)" }
    if ($approved -isnot [bool]) {
        return @{ success = $false; error = "'approved' must be a JSON boolean (true or false), not a string or other type" }
    }

    # Verify current state
    $task = Invoke-McpRuntimeRequest -Method GET -Path "/tasks/$taskId"
    if (-not $task)                              { throw "Task '$taskId' not found" }
    if ([string]$task.status -ne 'needs-review') {
        return @{ success = $false; error = "Task '$taskId' is in status '$($task.status)', not needs-review" }
    }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $projectRoot = $global:DotbotProjectRoot
    $botRoot     = $global:DotbotBotRoot

    # Ensure Dotbot.Worktree is loaded so we can call Reset-TaskWorktree /
    # Complete-TaskWorktree directly. Both .bot/-installed and DOTBOT_HOME
    # locations are tried; the MCP server has Dotbot.Core/Logging in scope
    # but Dotbot.Worktree is on-demand.
    if (-not (Get-Module Dotbot.Worktree)) {
        $candidates = @(
            (Join-Path $projectRoot ".bot/src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1"),
            (Join-Path $env:DOTBOT_HOME "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1")
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) {
                Import-Module $c -DisableNameChecking -Global -ErrorAction SilentlyContinue
                break
            }
        }
    }

    # ── REJECT PATH ──────────────────────────────────────────────────────────
    if (-not $approved) {
        if ([string]::IsNullOrWhiteSpace($comment)) {
            return @{ success = $false; error = "'comment' is required when rejecting — describe what needs to change so the implementor can act on the feedback" }
        }

        # Build feedback entry and append to existing extensions.review.feedback array
        $feedbackEntry = [ordered]@{
            comment        = "$comment"
            what_was_wrong = if ($whatWasWrong) { "$whatWasWrong" } else { "" }
            timestamp      = $now
        }
        $existingFeedback = @()
        if ($task.extensions -and $task.extensions.PSObject.Properties['review'] -and
            $task.extensions.review.PSObject.Properties['feedback'] -and $task.extensions.review.feedback) {
            $existingFeedback = @($task.extensions.review.feedback)
        }
        $newFeedback = @($existingFeedback) + @($feedbackEntry)

        # State move first (atomic), worktree cleanup after (best-effort).
        # The PATCH below replaces the review extension with the new shape:
        # status=rejected, rejected_at=now, feedback=[…], and clears the
        # execution-phase fields so the next attempt starts fresh.
        $reviewReplacement = @{
            required       = $true
            status         = 'rejected'
            rejected_at    = $now
            feedback       = $newFeedback
            pending_commit = $null
            requested_at   = $null
            request_reason = $null
        }
        $null = Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body @{
            actor      = Get-McpActor
            extensions = @{ review = $reviewReplacement }
        }
        $null = Invoke-McpRuntimeRequest -Method POST -Path "/tasks/$taskId/status" -Body @{
            to     = 'todo'
            actor  = Get-McpActor
            reason = "Review rejected: $comment"
        }

        # Discard the worktree + branch so the next cycle starts clean
        $resetMsg = $null
        try {
            if (Get-Command Reset-TaskWorktree -ErrorAction SilentlyContinue) {
                $resetResult = Reset-TaskWorktree -TaskId $taskId -ProjectRoot $projectRoot -BotRoot $botRoot
                $resetMsg = $resetResult.message
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                    Write-BotLog -Level Info -Message "Reset-TaskWorktree for '$taskId': $($resetResult.message)"
                }
            }
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Warn -Message "Could not reset worktree for task $taskId" -Exception $_
            }
        }

        return @{
            success        = $true
            message        = "Review rejected — task returned to todo for rework"
            task_id        = $taskId
            task_name      = [string]$task.name
            old_status     = 'needs-review'
            new_status     = 'todo'
            approved       = $false
            feedback_count = $newFeedback.Count
            worktree_reset = $resetMsg
        }
    }

    # ── APPROVE PATH ─────────────────────────────────────────────────────────
    # Order matches main: verify → merge → transition to done. We rely on
    # the enter-done transition hook to run the verify chain (abort_on_failure
    # reverts the transition on failure). The merge runs AFTER successful
    # transition, mirroring how Invoke-WorkflowProcess.ps1 sequences
    # task_set_status(done) → Complete-TaskWorktree.

    # 1. Attempt the transition. The enter-done hook fires verify; on failure
    #    the runtime returns 422 hook_aborted and the task stays in needs-review.
    $statusResp = $null
    $statusErr  = $null
    try {
        $statusResp = Invoke-McpRuntimeRequest -Method POST -Path "/tasks/$taskId/status" -Body @{
            to    = 'done'
            actor = Get-McpActor
        }
    } catch {
        $statusErr = $_.Exception.Message
    }
    if ($statusErr) {
        return @{
            success        = $false
            error          = "Approval blocked by verification: $statusErr"
            message        = "Approval blocked — verification failed. Task stays in needs-review. Fix the verify failures and click Approve again."
            task_id        = $taskId
            current_status = 'needs-review'
        }
    }

    # 2. Merge the worktree to main. If it fails the task is in done state
    #    but unmerged — operator can rerun submit_review (idempotent on done)
    #    or invoke Complete-TaskWorktree directly to retry.
    $mergeMsg = $null
    try {
        if (Get-Command Complete-TaskWorktree -ErrorAction SilentlyContinue) {
            $mergeResult = Complete-TaskWorktree -TaskId $taskId -ProjectRoot $projectRoot -BotRoot $botRoot
            $mergeMsg = $mergeResult.message
            if (-not $mergeResult.success) {
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                    Write-BotLog -Level Warn -Message "Review approval: merge failed for task $taskId — $($mergeResult.message)"
                }
            } else {
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                    Write-BotLog -Level Info -Message "Review approval: merged worktree for task $taskId — $($mergeResult.message)"
                }
            }
        }
    } catch {
        $mergeMsg = "merge failed: $($_.Exception.Message)"
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "Review approval: $mergeMsg for task $taskId" -Exception $_
        }
    }

    # 3. Stamp extensions.review.approved_at + status=approved
    $reviewPatch = @{
        status      = 'approved'
        approved_at = $now
    }
    $null = Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body @{
        actor      = Get-McpActor
        extensions = @{ review = $reviewPatch }
    }

    return @{
        success     = $true
        message     = "Review approved — task marked as done"
        task_id     = $taskId
        task_name   = [string]$task.name
        old_status  = 'needs-review'
        new_status  = 'done'
        approved    = $true
        merge_message = $mergeMsg
    }
}
