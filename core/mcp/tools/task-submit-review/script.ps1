Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/PathSanitizer.psm1") -Force

function Invoke-TaskSubmitReview {
    param(
        [hashtable]$Arguments
    )

    $taskId  = $Arguments['task_id']
    $approved = $Arguments['approved']
    $comment        = $Arguments['comment']
    $whatWasWrong   = $Arguments['what_was_wrong']

    if (-not $taskId) { throw "Task ID is required" }
    if ($null -eq $approved) { throw "approved flag is required (true or false)" }

    $projectRoot = $global:DotbotProjectRoot
    if (-not $projectRoot) { throw "Project root not available. MCP server may not have initialized correctly." }

    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('needs-review')
    if (-not $found) {
        throw "Task with ID '$taskId' not found in needs-review status"
    }

    $taskContent = $found.Content
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # ── REJECT PATH ──────────────────────────────────────────────────────────
    if (-not $approved) {
        # Build feedback entry
        $feedbackEntry = [ordered]@{
            comment       = if ($comment) { $comment } else { "" }
            what_was_wrong = if ($whatWasWrong) { $whatWasWrong } else { "" }
            timestamp     = $now
        }

        # Accumulate reviewer_feedback history (survives multiple rejection cycles)
        $existingFeedback = @()
        if ($taskContent.PSObject.Properties['reviewer_feedback'] -and $taskContent.reviewer_feedback) {
            $existingFeedback = @($taskContent.reviewer_feedback)
        }
        $newFeedback = $existingFeedback + @($feedbackEntry)

        # State move first (atomic), worktree cleanup after (best-effort)
        $updates = @{
            review_status     = 'rejected'
            reviewer_feedback = $newFeedback
            review_rejected_at = $now
            # Clear execution-phase fields so the next run starts fresh
            pending_review_commit = $null
            review_requested_at   = $null
            started_at            = $null
            completed_at          = $null
        }

        $result = Set-TaskState -TaskId $taskId `
            -FromStates @('needs-review') `
            -ToState 'todo' `
            -Updates $updates

        # Discard the worktree + branch so the next cycle starts clean
        $botRoot = Join-Path $projectRoot ".bot"
        try {
            Import-Module (Join-Path $botRoot "core/runtime/modules/WorktreeManager.psm1") -DisableNameChecking -Force
            $resetResult = Reset-TaskWorktree -TaskId $taskId -ProjectRoot $projectRoot -BotRoot $botRoot
            Write-BotLog -Level Info -Message "Reset-TaskWorktree for '$taskId': $($resetResult.message)"
        } catch {
            Write-BotLog -Level Warn -Message "Could not reset worktree for task $taskId" -Exception $_
        }

        return @{
            success          = $true
            message          = "Review rejected — task returned to todo for rework"
            task_id          = $taskId
            task_name        = $result.task_content.name
            old_status       = 'needs-review'
            new_status       = 'todo'
            approved         = $false
            feedback_count   = $newFeedback.Count
            file_path        = $result.file_path
        }
    }

    # ── APPROVE PATH ─────────────────────────────────────────────────────────
    # Run verification gates via shared TaskStore function (avoids dot-sourcing
    # task-mark-done which would re-run its -Force imports and corrupt module state)
    $verificationResults = Invoke-VerificationScripts -TaskId $taskId -Category $taskContent.category -ProjectRoot $projectRoot

    if (-not $verificationResults.AllPassed) {
        $failedScripts = @($verificationResults.Scripts | Where-Object { $_.success -eq $false -and -not $_.skipped })
        return @{
            success              = $false
            message              = "Review approved but verification failed — task stays in needs-review"
            task_id              = $taskId
            current_status       = 'needs-review'
            verification_passed  = $false
            verification_results = $verificationResults.Scripts
        }
    }

    # Extract commit information
    $commitUpdates = @{}
    try {
        $modulePath = Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/Extract-CommitInfo.ps1"
        if (Test-Path $modulePath) {
            . $modulePath
            $commits = Get-TaskCommitInfo -TaskId $taskId -ProjectRoot $projectRoot
            if ($commits -and $commits.Count -gt 0) {
                $mostRecent = $commits[0]
                $commitUpdates['commit_sha']     = $mostRecent.commit_sha
                $commitUpdates['commit_subject'] = $mostRecent.commit_subject
                $commitUpdates['files_created']  = $mostRecent.files_created
                $commitUpdates['files_deleted']  = $mostRecent.files_deleted
                $commitUpdates['files_modified'] = $mostRecent.files_modified
                $commitUpdates['commits']        = $commits
            }
        }
    } catch {
        Write-BotLog -Level Warn -Message "Failed to extract commit info for review approval" -Exception $_
    }

    # Capture execution activity log
    $activityFile = Join-Path $projectRoot ".bot\.control\activity.jsonl"
    $executionActivities = @()
    if (Test-Path $activityFile) {
        Get-Content $activityFile | ForEach-Object {
            try {
                $entry = $_ | ConvertFrom-Json
                if ($entry.task_id -eq $taskId -and (-not $entry.phase -or $entry.phase -eq 'execution')) {
                    $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $projectRoot
                    $sanitizedEntry = $entry | Select-Object -Property type, timestamp
                    $sanitizedEntry | Add-Member -NotePropertyName 'message' -NotePropertyValue $sanitizedMessage -Force
                    $executionActivities += $sanitizedEntry
                }
            } catch {}
        }
    }

    $updates = @{
        review_status    = 'approved'
        review_approved_at = $now
        completed_at     = if (-not $taskContent.completed_at) { $now } else { $taskContent.completed_at }
    }
    foreach ($key in $commitUpdates.Keys) { $updates[$key] = $commitUpdates[$key] }
    if ($executionActivities.Count -gt 0) { $updates['execution_activity_log'] = $executionActivities }

    $result = Set-TaskState -TaskId $taskId `
        -FromStates @('needs-review') `
        -ToState 'done' `
        -Updates $updates

    # Close current Claude session if applicable
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Close-SessionOnTask -TaskContent $result.task_content -SessionId $claudeSessionId -Phase 'execution'
        $result.task_content | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
    }

    return @{
        success              = $true
        message              = "Review approved — task marked as done"
        task_id              = $taskId
        task_name            = $result.task_content.name
        old_status           = 'needs-review'
        new_status           = 'done'
        approved             = $true
        verification_passed  = $true
        verification_results = $verificationResults.Scripts
        file_path            = $result.file_path
    }
}
