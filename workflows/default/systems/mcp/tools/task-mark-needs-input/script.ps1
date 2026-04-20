# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

function Invoke-TaskMarkNeedsInput {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $question = $Arguments['question']
    $questionsArg = $Arguments['questions']
    $splitProposal = $Arguments['split_proposal']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $question -and -not $questionsArg -and -not $splitProposal) { throw "Either 'questions' array, 'question' object, or 'split_proposal' is required" }
    if (($question -or $questionsArg) -and $splitProposal) { throw "Cannot provide both questions and split_proposal - use one at a time" }

    # Pre-read the task to build question data before the transition
    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('analysing', 'in-progress', 'needs-input')
    if (-not $found) { throw "Task with ID '$taskId' not found in 'analysing', 'in-progress', or 'needs-input' status" }

    # Guard: refuse to add more questions if all questions are already answered
    if (($question -or $questionsArg) -and
        $found.Content.PSObject.Properties['all_questions_answered'] -and
        $found.Content.all_questions_answered -eq $true) {
        throw "all_questions_answered is true — all questions have been answered. Proceed to Step 4 (write summary, call task_mark_done). Do NOT call task_mark_needs_input again."
    }

    # Build updates
    $updates = @{}
    $newPendingQuestions = @()

    if ($questionsArg) {
        # Batch questions (preferred path) — store as pending_questions array
        $questionsResolved = @()
        if ($found.Content.PSObject.Properties['questions_resolved']) {
            $questionsResolved = @($found.Content.questions_resolved)
        }
        $existingPending = @()
        if ($found.Content.PSObject.Properties['pending_questions']) {
            $existingPending = @($found.Content.pending_questions)
        }

        # Migrate legacy single pending_question into pending_questions before clearing it
        if ($found.Content.PSObject.Properties['pending_question'] -and $found.Content.pending_question) {
            $legacyQ = $found.Content.pending_question
            $alreadyMigrated = $existingPending | Where-Object { $_.id -eq $legacyQ.id }
            if (-not $alreadyMigrated) {
                $existingPending = @($legacyQ) + $existingPending
            }
        }

        $askedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $baseCount = $questionsResolved.Count + $existingPending.Count
        $newPending = @()
        for ($i = 0; $i -lt @($questionsArg).Count; $i++) {
            $q = @($questionsArg)[$i]
            $newPending += @{
                id             = "q$($baseCount + $i + 1)"
                question       = $q.question
                context        = $q.context
                options        = $q.options
                recommendation = if ($q.recommendation) { $q.recommendation } else { "A" }
                asked_at       = $askedAt
            }
        }
        $updates['pending_questions'] = $existingPending + $newPending
        $newPendingQuestions = $newPending
        $updates['pending_question'] = $null
        $updates['split_proposal']   = $null
        $updates['notification']     = $null
        $updates['questions_resolved'] = $questionsResolved
    }
    elseif ($question) {
        $questionsResolved = @()
        if ($found.Content.PSObject.Properties['questions_resolved']) {
            $questionsResolved = @($found.Content.questions_resolved)
        }

        $questionId = "q$($questionsResolved.Count + 1)"
        $pendingQuestion = @{
            id             = $questionId
            question       = $question.question
            context        = $question.context
            options        = $question.options
            recommendation = if ($question.recommendation) { $question.recommendation } else { "A" }
            asked_at       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        $updates['pending_question'] = $pendingQuestion
        $updates['split_proposal'] = $null
        $updates['questions_resolved'] = $questionsResolved
    }
    elseif ($splitProposal) {
        $updates['split_proposal'] = @{
            reason      = $splitProposal.reason
            sub_tasks   = $splitProposal.sub_tasks
            proposed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        $updates['pending_question'] = $null
    }

    $result = Move-TaskState -TaskId $taskId `
        -FromStates @('analysing', 'in-progress', 'needs-input') `
        -ToState 'needs-input' `
        -Updates $updates

    $taskContent = $result.task_content

    # Close current Claude session on actual transition
    if (-not $result.already_in_state) {
        $claudeSessionId = $env:CLAUDE_SESSION_ID
        if ($claudeSessionId) {
            $sessionPhase = if ($found.Status -eq 'in-progress') { 'execution' } else { 'analysis' }
            Close-SessionOnTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase $sessionPhase
            $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
        }
    }

    # If already in needs-input, still apply the new question/proposal
    if ($result.already_in_state) {
        foreach ($key in $updates.Keys) {
            Set-OrAddProperty -Object $taskContent -Name $key -Value $updates[$key]
        }
        Set-OrAddProperty -Object $taskContent -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
    }

    # --- External notification (opt-in) ---
    try {
        $notifModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\NotificationClient.psm1"
        if (Test-Path $notifModule) {
            Import-Module $notifModule -Force
            $settings = Get-NotificationSettings
            if ($settings.enabled -and ($question -or $splitProposal)) {
                $sendResult = if ($question) {
                    Send-TaskNotification -TaskContent $taskContent -PendingQuestion $taskContent.pending_question -Settings $settings
                } else {
                    Send-SplitProposalNotification -TaskContent $taskContent -SplitProposal $taskContent.split_proposal -Settings $settings
                }
                if ($sendResult.success) {
                    $taskContent | Add-Member -NotePropertyName 'notification' -NotePropertyValue @{
                        question_id = $sendResult.question_id
                        instance_id = $sendResult.instance_id
                        channel     = $sendResult.channel
                        project_id  = $sendResult.project_id
                        sent_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    } -Force
                    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
                }
            } elseif ($settings.enabled -and $newPendingQuestions.Count -gt 0) {
                $sentAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                $notificationsMap = @{}
                if ($taskContent.PSObject.Properties['notifications']) {
                    foreach ($prop in $taskContent.notifications.PSObject.Properties) {
                        $notificationsMap[$prop.Name] = $prop.Value
                    }
                }
                foreach ($pq in $newPendingQuestions) {
                    $maxAttempts = 3
                    $sendResult  = $null
                    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                        $sendResult = Send-TaskNotification -TaskContent $taskContent -PendingQuestion $pq -Settings $settings
                        if ($sendResult.success) { break }
                        if ($attempt -lt $maxAttempts) { Start-Sleep -Milliseconds 500 }
                    }
                    if ($sendResult -and $sendResult.success) {
                        $notificationsMap[$pq.id] = @{
                            question_id = $sendResult.question_id
                            instance_id = $sendResult.instance_id
                            channel     = $sendResult.channel
                            project_id  = $sendResult.project_id
                            sent_at     = $sentAt
                        }
                    }
                }
                if ($notificationsMap.Count -gt 0) {
                    $taskContent | Add-Member -NotePropertyName 'notifications' -NotePropertyValue $notificationsMap -Force
                    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $result.file_path -Encoding UTF8
                }
            }
        }
    } catch {
        # Never block the core flow
    }

    # Build result
    $output = @{
        success    = $true
        message    = if ($questionsArg) { "Task paused for human input - $(@($questionsArg).Count) question(s) pending" } elseif ($question) { "Task paused for human input - question pending" } else { "Task paused for human input - split proposal pending" }
        task_id    = $taskId
        task_name  = $result.task_name
        old_status = $result.old_status
        new_status = 'needs-input'
        file_path  = $result.file_path
    }

    if ($questionsArg) { $output['pending_questions'] = $taskContent.pending_questions; $output['questions_count'] = @($taskContent.pending_questions).Count }
    elseif ($question) { $output['pending_question'] = $taskContent.pending_question }
    elseif ($splitProposal) { $output['split_proposal'] = $taskContent.split_proposal }

    return $output
}
