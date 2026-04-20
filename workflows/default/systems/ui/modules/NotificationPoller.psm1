<#
.SYNOPSIS
Background poller that checks DotbotServer for external responses to needs-input tasks.

.DESCRIPTION
Periodically scans the needs-input directory for tasks with notification metadata,
polls DotbotServer for responses, and transitions answered tasks back to analysing
using the same logic as task-answer-question.

Uses first-write-wins: if a task has already been answered via the Web UI (moved out
of needs-input), the external response is silently ignored.
#>

$script:pollerPowerShell = $null
$script:pollerBotRoot = $null

function Initialize-NotificationPoller {
    <#
    .SYNOPSIS
    Starts the background notification polling timer.

    .PARAMETER BotRoot
    The .bot root directory path.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    $script:pollerBotRoot = $BotRoot

    # Import the notification client module
    $notifModule = Join-Path $BotRoot "systems\mcp\modules\NotificationClient.psm1"
    if (-not (Test-Path $notifModule)) {
        return
    }
    Import-Module $notifModule -Force

    $settings = Get-NotificationSettings -BotRoot $BotRoot
    if (-not $settings.enabled) {
        return
    }

    $intervalSeconds = $settings.poll_interval_seconds
    if ($intervalSeconds -lt 5) { $intervalSeconds = 5 }

    # Use a dedicated runspace with a sleep loop — avoids the System.Threading.Timer
    # runspace issue where the TimerCallback scriptblock has no PowerShell runspace.
    $pollerRunspace = [runspacefactory]::CreateRunspace()
    $pollerRunspace.Open()

    $script:pollerPowerShell = [powershell]::Create()
    $script:pollerPowerShell.Runspace = $pollerRunspace

    $pollerModule = $PSCommandPath
    $script:pollerPowerShell.AddScript(@"
        Import-Module '$($pollerModule -replace "'","''")' -Force
        Import-Module '$($notifModule -replace "'","''")' -Force
        `$script:pollerBotRoot = '$($BotRoot -replace "'","''")'
        `$global:DotbotProjectRoot = '$((Split-Path $BotRoot -Parent) -replace "'","''")'

        while (`$true) {
            Start-Sleep -Seconds $intervalSeconds
            try {
                Invoke-NotificationPollTick -BotRoot `$script:pollerBotRoot
            } catch {
                # Swallow per-tick errors to keep polling
            }
        }
"@)

    # BeginInvoke runs the loop asynchronously without blocking the main thread
    $null = $script:pollerPowerShell.BeginInvoke()
}

function Invoke-NotificationPollTick {
    <#
    .SYNOPSIS
    Single poll cycle: scans needs-input tasks for notification metadata,
    checks for external responses, and transitions answered tasks.
    #>
    param(
        [string]$BotRoot
    )

    $botRoot = if ($BotRoot) { $BotRoot } else { $script:pollerBotRoot }
    if (-not $botRoot) { return }

    $needsInputDir = Join-Path $botRoot "workspace\tasks\needs-input"
    if (-not (Test-Path $needsInputDir)) { return }

    # Ensure notification client is loaded
    $notifModule = Join-Path $botRoot "systems\mcp\modules\NotificationClient.psm1"
    if (-not (Test-Path $notifModule)) { return }
    Import-Module $notifModule -Force

    $settings = Get-NotificationSettings -BotRoot $botRoot
    if (-not $settings.enabled) { return }

    $taskFiles = Get-ChildItem -Path $needsInputDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    if (-not $taskFiles) { return }

    foreach ($taskFile in $taskFiles) {
        try {
            $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
            $taskId = $taskContent.id

            # ── Single-question path (pending_question + notification) ──────
            $hasSingleNotif = $taskContent.PSObject.Properties['notification'] -and $taskContent.notification
            $hasSingleQ     = $taskContent.PSObject.Properties['pending_question'] -and $taskContent.pending_question

            # Determine notification type: question or split proposal
            $isQuestion  = [bool]$taskContent.pending_question
            $isSplit     = [bool]$taskContent.split_proposal
            $isBatchQs   = $taskContent.PSObject.Properties['pending_questions'] -and
                           $taskContent.pending_questions -and
                           @($taskContent.pending_questions).Count -gt 0

            # Skip tasks that have nothing actionable
            if (-not $isQuestion -and -not $isSplit -and -not $isBatchQs) {
                continue
            }

            $notification = $taskContent.notification
            $response = $null
            if ($notification) {
                $response = Get-TaskNotificationResponse -Notification $notification -Settings $settings
            }

            if ($response) {
                # Re-check that the task is still in needs-input (first-write-wins)
                if (-not (Test-Path $taskFile.FullName)) { continue }

                if ($isSplit) {
                    # Split proposal response: "approve" or "reject" key
                    $answerKey = if ($response.selectedKey) { $response.selectedKey } else { $null }
                    if ($answerKey) {
                        Invoke-SplitTransitionFromNotification -TaskFile $taskFile -TaskContent $taskContent `
                            -AnswerKey $answerKey -BotRoot $botRoot
                    } else {
                        # Unsupported response (e.g. free-text reply). The template
                        # disables free-text, but if a response without selectedKey
                        # still reaches us we must consume it — otherwise the same
                        # response is re-fetched on every poll tick indefinitely.
                        $taskContent.notification = $null
                        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $taskFile.FullName -Encoding UTF8
                    }
                } else {
                    # Question response: resolve answer and transition
                    $taskId    = $taskContent.id
                    $questionId = $taskContent.pending_question.id
                    $attachDir = Join-Path $botRoot "workspace\attachments\$taskId\$questionId"
                    $resolved  = Resolve-NotificationAnswer -Response $response -Settings $settings -AttachDir $attachDir

                    if ($resolved) {
                        Invoke-TaskTransitionFromNotification -TaskFile $taskFile -TaskContent $taskContent `
                            -Answer $resolved.answer -Attachments $resolved.attachments -BotRoot $botRoot
                    }
                }
                continue
            }

            # ── Batch path (pending_questions + notifications map) ──────────
            $hasBatchNotifs = $taskContent.PSObject.Properties['notifications'] -and $taskContent.notifications
            $hasBatchQs     = $taskContent.PSObject.Properties['pending_questions'] -and $taskContent.pending_questions

            if (-not $hasBatchNotifs -or -not $hasBatchQs) { continue }

            $pendingQs = @($taskContent.pending_questions)
            if ($pendingQs.Count -eq 0) { continue }

            foreach ($pq in $pendingQs) {
                $notifEntry = $null
                if ($taskContent.notifications.PSObject.Properties[$pq.id]) {
                    $notifEntry = $taskContent.notifications.($pq.id)
                }
                if (-not $notifEntry) { continue }

                $response = Get-TaskNotificationResponse -Notification $notifEntry -Settings $settings
                if (-not $response) { continue }

                $attachDir = Join-Path $botRoot "workspace\attachments\$taskId\$($pq.id)"
                $resolved  = Resolve-NotificationAnswer -Response $response -Settings $settings -AttachDir $attachDir
                if (-not $resolved) { continue }

                # Re-read task file before mutating (first-write-wins)
                if (-not (Test-Path $taskFile.FullName)) { break }
                $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json

                Invoke-BatchQuestionTransitionFromNotification -TaskFile $taskFile -TaskContent $taskContent `
                    -Question $pq -Answer $resolved.answer -Attachments $resolved.attachments -BotRoot $botRoot

                # Re-read after mutation to pick up updated pending_questions for next iteration
                if (Test-Path $taskFile.FullName) {
                    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
                } else {
                    break  # task moved out of needs-input — stop processing this file
                }
            }
        } catch {
            # Per-task errors are non-fatal; continue polling other tasks
        }
    }
}

function Invoke-TaskTransitionFromNotification {
    <#
    .SYNOPSIS
    Transitions a needs-input task back to analysing after receiving an external response.
    Mirrors the logic in task-answer-question/script.ps1.
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$TaskFile,

        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Answer,

        [Parameter(Mandatory)]
        [string]$BotRoot,

        [array]$Attachments = @()
    )

    $tasksBaseDir = Join-Path $BotRoot "workspace\tasks"
    $analysingDir = Join-Path $tasksBaseDir "analysing"
    $pendingQuestion = $TaskContent.pending_question

    # Resolve the answer (same logic as task-answer-question)
    $resolvedAnswer = $Answer
    $answerType = "custom"

    $validKeys = @("A", "B", "C", "D", "E")
    if ($Answer.ToUpper() -in $validKeys) {
        $answerKey = $Answer.ToUpper()
        $answerType = "option"
        $matchingOption = $pendingQuestion.options | Where-Object { $_.key -eq $answerKey } | Select-Object -First 1
        if ($matchingOption) {
            $resolvedAnswer = "$answerKey - $($matchingOption.label)"
        } else {
            $resolvedAnswer = $answerKey
        }
    }

    # Create resolved question entry
    $resolvedEntry = @{
        id          = $pendingQuestion.id
        question    = $pendingQuestion.question
        answer      = $resolvedAnswer
        answer_type = $answerType
        asked_at    = $pendingQuestion.asked_at
        answered_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        answered_via = "notification"
    }

    if ($Attachments -and $Attachments.Count -gt 0) {
        $resolvedEntry['attachments'] = $Attachments
    }

    # Add to questions_resolved
    if (-not $TaskContent.PSObject.Properties['questions_resolved']) {
        $TaskContent | Add-Member -NotePropertyName 'questions_resolved' -NotePropertyValue @() -Force
    }
    $existingResolved = @($TaskContent.questions_resolved)
    $existingResolved += $resolvedEntry
    $TaskContent.questions_resolved = $existingResolved

    # Clear pending question
    $TaskContent.pending_question = $null
    $TaskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Check if the answer indicates skip
    $isSkipAnswer = $resolvedAnswer -match '(?i)skip\s*task|skip\s*-|already\s*exist'

    if ($isSkipAnswer) {
        $TaskContent.status = 'skipped'
        if (-not $TaskContent.PSObject.Properties['skip_history']) {
            $TaskContent | Add-Member -NotePropertyName 'skip_history' -NotePropertyValue @() -Force
        }
        $existingSkips = @($TaskContent.skip_history)
        $existingSkips += @{
            skipped_at = $TaskContent.updated_at
            reason     = "Skipped via external notification answer: $resolvedAnswer"
        }
        $TaskContent.skip_history = $existingSkips

        $skippedDir = Join-Path $tasksBaseDir "skipped"
        if (-not (Test-Path $skippedDir)) {
            New-Item -ItemType Directory -Force -Path $skippedDir | Out-Null
        }
        $newFilePath = Join-Path $skippedDir $TaskFile.Name
    } else {
        $TaskContent.status = 'analysing'
        if (-not (Test-Path $analysingDir)) {
            New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null
        }
        $newFilePath = Join-Path $analysingDir $TaskFile.Name
    }

    # Save updated task to new location and remove from needs-input
    $TaskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
    Remove-Item -Path $TaskFile.FullName -Force
}

function Invoke-SplitTransitionFromNotification {
    <#
    .SYNOPSIS
    Transitions a needs-input task based on a split-proposal response from Teams.
    Maps "approve"/"reject" answer keys to the corresponding task-approve-split logic.
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$TaskFile,

        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [string]$AnswerKey,

        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    # Validate answer key — only "approve" and "reject" are expected
    $validKeys = @('approve', 'reject')
    if ($AnswerKey -notin $validKeys) {
        Write-BotLog -Level Warn -Message "Unexpected split proposal answer key '$AnswerKey' for task $($TaskContent.id) — ignoring"
        # Clear notification metadata so the same invalid response is not
        # re-fetched and re-logged on every subsequent poll tick.
        if (Test-Path $TaskFile.FullName) {
            $TaskContent.notification = $null
            $TaskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $TaskFile.FullName -Encoding UTF8
        }
        return
    }

    $approved = $AnswerKey -eq 'approve'

    if (-not $approved) {
        # ── Reject path: mark rejected, move back to analysing ────────────
        $tasksBaseDir = Join-Path $BotRoot "workspace" "tasks"
        $analysingDir = Join-Path $tasksBaseDir "analysing"

        $TaskContent.status = 'analysing'
        $TaskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

        $TaskContent.split_proposal | Add-Member -NotePropertyName 'rejected_at' `
            -NotePropertyValue (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") -Force
        $TaskContent.split_proposal | Add-Member -NotePropertyName 'status' -NotePropertyValue 'rejected' -Force
        $TaskContent.split_proposal | Add-Member -NotePropertyName 'answered_via' -NotePropertyValue 'notification' -Force

        # Clear stale notification metadata so it doesn't carry over if the task
        # cycles back to needs-input with a new question or proposal
        $TaskContent.notification = $null

        if (-not (Test-Path $analysingDir)) {
            New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null
        }

        $newFilePath = Join-Path $analysingDir $TaskFile.Name
        $TaskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
        Remove-Item -Path $TaskFile.FullName -Force
    } else {
        # ── Approve path: delegate to Invoke-TaskApproveSplit ─────────────
        # $global:DotbotProjectRoot is set in the runspace init block
        # (Initialize-NotificationPoller) so it's available here.
        $approveScript = Join-Path $BotRoot "systems" "mcp" "tools" "task-approve-split" "script.ps1"
        if (-not (Get-Command Invoke-TaskApproveSplit -ErrorAction SilentlyContinue)) {
            . $approveScript
        }

        try {
            $approveResult = Invoke-TaskApproveSplit -Arguments @{
                task_id  = $TaskContent.id
                approved = $true
            }

            # Record that the approval came via Teams notification (for audit trail)
            if ($approveResult.file_path -and (Test-Path $approveResult.file_path)) {
                $approvedTask = Get-Content -Path $approveResult.file_path -Raw | ConvertFrom-Json
                $approvedTask.split_proposal | Add-Member -NotePropertyName 'answered_via' -NotePropertyValue 'notification' -Force
                $approvedTask.notification = $null
                $approvedTask | ConvertTo-Json -Depth 20 | Set-Content -Path $approveResult.file_path -Encoding UTF8
            }
        } catch {
            # Clear notification metadata to prevent infinite retry loops on
            # persistent failures (e.g., task already moved, sub-task creation broken)
            Write-BotLog -Level Warn -Message "Split approval failed for task $($TaskContent.id): $($_.Exception.Message)" -Exception $_
            if (Test-Path $TaskFile.FullName) {
                $TaskContent.notification = $null
                $TaskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                $TaskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $TaskFile.FullName -Encoding UTF8
            }
        }
    }
}

function Invoke-BatchQuestionTransitionFromNotification {
    <#
    .SYNOPSIS
    Handles a single answered question in a batch (pending_questions) flow.
    Moves the question to questions_resolved, removes its notification entry,
    and transitions the task to 'analysing' only when all questions are answered.
    #>
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$TaskFile,

        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [object]$Question,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Answer,

        [Parameter(Mandatory)]
        [string]$BotRoot,

        [array]$Attachments = @()
    )

    $tasksBaseDir = Join-Path $BotRoot "workspace\tasks"
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")

    # Resolve option key to label (same logic as Invoke-TaskTransitionFromNotification)
    $resolvedAnswer = $Answer
    $answerType     = "custom"
    $validKeys      = @("A", "B", "C", "D", "E")
    if ($Answer.ToUpper() -in $validKeys) {
        $answerKey = $Answer.ToUpper()
        $answerType = "option"
        $matchingOption = $Question.options | Where-Object { $_.key -eq $answerKey } | Select-Object -First 1
        $resolvedAnswer = if ($matchingOption) { "$answerKey - $($matchingOption.label)" } else { $answerKey }
    }

    # Build resolved entry
    $resolvedEntry = @{
        id           = $Question.id
        question     = $Question.question
        answer       = $resolvedAnswer
        answer_type  = $answerType
        asked_at     = $Question.asked_at
        answered_at  = $now
        answered_via = "notification"
    }
    if ($Attachments -and $Attachments.Count -gt 0) {
        $resolvedEntry['attachments'] = $Attachments
    }

    # Append to questions_resolved
    if (-not $TaskContent.PSObject.Properties['questions_resolved']) {
        $TaskContent | Add-Member -NotePropertyName 'questions_resolved' -NotePropertyValue @() -Force
    }
    $TaskContent.questions_resolved = @($TaskContent.questions_resolved) + $resolvedEntry

    # Remove from pending_questions
    $TaskContent.pending_questions = @($TaskContent.pending_questions | Where-Object { $_.id -ne $Question.id })

    # Remove notification entry for this question
    if ($TaskContent.PSObject.Properties['notifications'] -and $TaskContent.notifications.PSObject.Properties[$Question.id]) {
        $TaskContent.notifications.PSObject.Properties.Remove($Question.id)
    }

    $TaskContent.updated_at = $now

    $remainingCount = @($TaskContent.pending_questions).Count

    if ($remainingCount -gt 0) {
        # More questions pending — stay in needs-input, just update the file in place
        $TaskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $TaskFile.FullName -Encoding UTF8
    } else {
        # All answered — transition to analysing (or skipped)
        $isSkipAnswer = $resolvedAnswer -match '(?i)skip\s*task|skip\s*-|already\s*exist'

        if ($isSkipAnswer) {
            $TaskContent.status = 'skipped'
            if (-not $TaskContent.PSObject.Properties['skip_history']) {
                $TaskContent | Add-Member -NotePropertyName 'skip_history' -NotePropertyValue @() -Force
            }
            $TaskContent.skip_history = @($TaskContent.skip_history) + @{
                skipped_at = $now
                reason     = "Skipped via external notification answer: $resolvedAnswer"
            }
            $destDir = Join-Path $tasksBaseDir "skipped"
        } else {
            $TaskContent.status = 'analysing'
            $destDir = Join-Path $tasksBaseDir "analysing"
        }

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }
        $newFilePath = Join-Path $destDir $TaskFile.Name
        $TaskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
        Remove-Item -Path $TaskFile.FullName -Force
    }
}

Export-ModuleMember -Function @(
    'Initialize-NotificationPoller'
    'Invoke-NotificationPollTick'
    'Invoke-SplitTransitionFromNotification'
    'Invoke-BatchQuestionTransitionFromNotification'
    'Invoke-TaskTransitionFromNotification'
)
