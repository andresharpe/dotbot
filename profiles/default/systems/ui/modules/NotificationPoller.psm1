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

$script:pollerTimer = $null
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

    $intervalMs = ($settings.poll_interval_seconds) * 1000
    if ($intervalMs -lt 5000) { $intervalMs = 5000 }

    # Use System.Threading.Timer for non-blocking background polling
    $callback = [System.Threading.TimerCallback]{
        try {
            Invoke-NotificationPollTick
        } catch {
            # Swallow errors to keep the timer alive
        }
    }

    $script:pollerTimer = New-Object System.Threading.Timer($callback, $null, $intervalMs, $intervalMs)
}

function Invoke-NotificationPollTick {
    <#
    .SYNOPSIS
    Single poll cycle: scans needs-input tasks for notification metadata,
    checks for external responses, and transitions answered tasks.
    #>

    $botRoot = $script:pollerBotRoot
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

            # Skip tasks without notification metadata
            if (-not $taskContent.PSObject.Properties['notification'] -or -not $taskContent.notification) {
                continue
            }

            # Skip tasks without a pending question (already answered)
            if (-not $taskContent.pending_question) {
                continue
            }

            $notification = $taskContent.notification
            $response = Get-TaskNotificationResponse -Notification $notification -Settings $settings

            if ($response) {
                # Resolve the answer from the external response
                $answer = $null
                if ($response.selectedKey) {
                    $answer = $response.selectedKey
                } elseif ($response.freeText) {
                    $answer = $response.freeText
                }

                if ($answer) {
                    # Re-check that the task is still in needs-input (first-write-wins)
                    if (Test-Path $taskFile.FullName) {
                        Invoke-TaskTransitionFromNotification -TaskFile $taskFile -TaskContent $taskContent -Answer $answer -BotRoot $botRoot
                    }
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
        [string]$Answer,

        [Parameter(Mandatory)]
        [string]$BotRoot
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

Export-ModuleMember -Function @(
    'Initialize-NotificationPoller'
    'Invoke-NotificationPollTick'
)
