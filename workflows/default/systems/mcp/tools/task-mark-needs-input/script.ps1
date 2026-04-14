# Import modules
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskStore.psm1") -Force

function Invoke-TaskMarkNeedsInput {
    param(
        [hashtable]$Arguments
    )

    $taskId = $Arguments['task_id']
    $question = $Arguments['question']
    $splitProposal = $Arguments['split_proposal']

    if (-not $taskId) { throw "Task ID is required" }
    if (-not $question -and -not $splitProposal) { throw "Either a question or split_proposal is required" }
    if ($question -and $splitProposal) { throw "Cannot provide both question and split_proposal - use one at a time" }

    # Pre-read the task to build question data before the transition
    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses @('analysing', 'needs-input')
    if (-not $found) { throw "Task with ID '$taskId' not found in 'analysing' or 'needs-input' status" }

    # Build updates
    $updates = @{}

    if ($question) {
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
        -FromStates @('analysing', 'needs-input') `
        -ToState 'needs-input' `
        -Updates $updates

    $taskContent = $result.task_content

    # Close current Claude session on actual transition
    if (-not $result.already_in_state) {
        $claudeSessionId = $env:CLAUDE_SESSION_ID
        if ($claudeSessionId) {
            Close-SessionOnTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase 'analysis'
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
            }
        }
    } catch {
        # Never block the core flow
    }

    # Build result
    $output = @{
        success    = $true
        message    = if ($question) { "Task paused for human input - question pending" } else { "Task paused for human input - split proposal pending" }
        task_id    = $taskId
        task_name  = $result.task_name
        old_status = $result.old_status
        new_status = 'needs-input'
        file_path  = $result.file_path
    }

    if ($question) { $output['pending_question'] = $taskContent.pending_question }
    elseif ($splitProposal) { $output['split_proposal'] = $taskContent.split_proposal }

    return $output
}
