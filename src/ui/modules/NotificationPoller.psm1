<#
.SYNOPSIS
Background poller that checks DotbotServer for external responses to needs-input tasks.

.DESCRIPTION
Periodically scans the needs-input directory for tasks with notification metadata,
polls DotbotServer for responses, and delegates task state changes to the
runtime-owned task-input transition module.

Uses first-write-wins: if a task has already been answered via the Web UI (moved out
of needs-input), the external response is silently ignored.
#>

if (-not (Get-Module TaskFile)) {
    Import-Module (Join-Path $PSScriptRoot ".." ".." "mcp" "modules" "TaskFile.psm1") -DisableNameChecking -Global
}
Import-Module (Join-Path $PSScriptRoot ".." ".." "runtime" "Modules" "Dotbot.TaskInput" "Dotbot.TaskInput.psd1") -Force -DisableNameChecking

function Get-NotificationObjectProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-NotificationTaskRunner {
    param($TaskContent)
    $extensions = Get-NotificationObjectProp -Object $TaskContent -Name 'extensions'
    if (-not $extensions) { return $null }
    return Get-NotificationObjectProp -Object $extensions -Name 'runner'
}

function Get-NotificationTaskInputValue {
    param($TaskContent, [string]$Name)
    $runner = Get-NotificationTaskRunner -TaskContent $TaskContent
    $value = Get-NotificationObjectProp -Object $runner -Name $Name
    if ($null -ne $value) { return $value }
    return Get-NotificationObjectProp -Object $TaskContent -Name $Name
}

function ConvertTo-NotificationArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Remove-NotificationTaskInputValue {
    param($TaskContent, [string]$Name)
    $runner = Get-NotificationTaskRunner -TaskContent $TaskContent
    foreach ($bag in @($runner, $TaskContent)) {
        if ($null -eq $bag) { continue }
        if ($bag -is [System.Collections.IDictionary]) {
            if ($bag.Contains($Name)) { $bag.Remove($Name) }
        } elseif ($bag.PSObject.Properties[$Name]) {
            $bag.PSObject.Properties.Remove($Name)
        }
    }
}

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
    $notifModule = Join-Path $PSScriptRoot ".." ".." "mcp" "modules" "NotificationClient.psm1"
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

    $tasksBaseDir = Join-Path $botRoot "workspace\tasks"
    if (-not (Test-Path $tasksBaseDir)) { return }

    # Ensure notification client is loaded
    $notifModule = Join-Path $PSScriptRoot ".." ".." "mcp" "modules" "NotificationClient.psm1"
    if (-not (Test-Path $notifModule)) { return }
    Import-Module $notifModule -Force

    $settings = Get-NotificationSettings -BotRoot $botRoot
    if (-not $settings.enabled) { return }

    $taskFiles = @()
    foreach ($bucket in @((Join-Path $tasksBaseDir 'workflow-runs'),
                           (Join-Path $tasksBaseDir 'standalone'))) {
        if (-not (Test-Path -LiteralPath $bucket)) { continue }
        $taskFiles += @(Get-ChildItem -LiteralPath $bucket -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
                        Where-Object {
                            if ($_.Name -eq 'run.json') { return $false }
                            try {
                                $c = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                                return ([string]$c.status -eq 'needs-input')
                            } catch { return $false }
                        })
    }
    if (-not $taskFiles) { return }

    foreach ($taskFile in $taskFiles) {
        try {
            $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json
            $taskId = $taskContent.id

            $pendingQuestion = Get-NotificationTaskInputValue -TaskContent $taskContent -Name 'pending_question'
            $splitProposal = Get-NotificationTaskInputValue -TaskContent $taskContent -Name 'split_proposal'
            $pendingQuestions = ConvertTo-NotificationArray (Get-NotificationTaskInputValue -TaskContent $taskContent -Name 'pending_questions')

            $isQuestion  = [bool]$pendingQuestion
            $isSplit     = [bool]$splitProposal
            $isBatchQs   = $pendingQuestions.Count -gt 0

            # Skip tasks that have nothing actionable
            if (-not $isQuestion -and -not $isSplit -and -not $isBatchQs) {
                continue
            }

            $notification = Get-NotificationTaskInputValue -TaskContent $taskContent -Name 'notification'
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
                        Remove-NotificationTaskInputValue -TaskContent $taskContent -Name 'notification'
                        Write-TaskFileAtomic -Path $taskFile.FullName -Content $taskContent -Depth 20 -TaskId $taskContent.id
                    }
                } else {
                    # Question response: resolve answer and transition
                    $taskId    = $taskContent.id
                    $questionId = $pendingQuestion.id
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
            $notifications = Get-NotificationTaskInputValue -TaskContent $taskContent -Name 'notifications'
            $pendingQuestions = ConvertTo-NotificationArray (Get-NotificationTaskInputValue -TaskContent $taskContent -Name 'pending_questions')
            $hasBatchNotifs = [bool]$notifications
            $hasBatchQs     = $pendingQuestions.Count -gt 0

            if (-not $hasBatchNotifs -or -not $hasBatchQs) { continue }

            $pendingQs = @($pendingQuestions)
            if ($pendingQs.Count -eq 0) { continue }

            foreach ($pq in $pendingQs) {
                $notifEntry = $null
                $notifEntry = Get-NotificationObjectProp -Object $notifications -Name $pq.id
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
    Transitions a needs-input task after receiving a single external answer.
    #>
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] [object]$TaskContent,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Answer,
        [Parameter(Mandatory)] [string]$BotRoot,
        [array]$Attachments = @()
    )

    Invoke-TaskQuestionAnswerTransition -TaskFile $TaskFile `
        -TaskContent $TaskContent `
        -Answer $Answer `
        -BotRoot $BotRoot `
        -Attachments $Attachments `
        -AnsweredVia 'notification'
}

function Invoke-SplitTransitionFromNotification {
    <#
    .SYNOPSIS
    Transitions a needs-input task after receiving a split approval response.
    #>
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] [object]$TaskContent,
        [Parameter(Mandatory)] [string]$AnswerKey,
        [Parameter(Mandatory)] [string]$BotRoot
    )

    $validKeys = @('approve', 'reject')
    if ($AnswerKey -notin $validKeys) {
        Write-BotLog -Level Warn -Message "Unexpected split proposal answer key '$AnswerKey' for task $($TaskContent.id) — ignoring"
        if (Test-Path $TaskFile.FullName) {
            Remove-NotificationTaskInputValue -TaskContent $TaskContent -Name 'notification'
            Write-TaskFileAtomic -Path $TaskFile.FullName -Content $TaskContent -Depth 20 -TaskId $TaskContent.id -BotRoot $BotRoot
        }
        return
    }

    try {
        Invoke-TaskSplitDecisionTransition -TaskFile $TaskFile `
            -TaskContent $TaskContent `
            -Approved ($AnswerKey -eq 'approve') `
            -BotRoot $BotRoot `
            -AnsweredVia 'notification'
    } catch {
        Write-BotLog -Level Warn -Message "Split decision failed for task $($TaskContent.id): $($_.Exception.Message)" -Exception $_
        if (Test-Path $TaskFile.FullName) {
            Remove-NotificationTaskInputValue -TaskContent $TaskContent -Name 'notification'
            $TaskContent.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            Write-TaskFileAtomic -Path $TaskFile.FullName -Content $TaskContent -Depth 20 -TaskId $TaskContent.id -BotRoot $BotRoot
        }
    }
}

function Invoke-BatchQuestionTransitionFromNotification {
    <#
    .SYNOPSIS
    Handles one answered question from a batch notification flow.
    #>
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$TaskFile,
        [Parameter(Mandatory)] [object]$TaskContent,
        [Parameter(Mandatory)] [object]$Question,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Answer,
        [Parameter(Mandatory)] [string]$BotRoot,
        [array]$Attachments = @()
    )

    Invoke-TaskQuestionAnswerTransition -TaskFile $TaskFile `
        -TaskContent $TaskContent `
        -Answer $Answer `
        -BotRoot $BotRoot `
        -QuestionId $Question.id `
        -Attachments $Attachments `
        -AnsweredVia 'notification'
}

Export-ModuleMember -Function @(
    'Initialize-NotificationPoller'
    'Invoke-NotificationPollTick'
    'Invoke-SplitTransitionFromNotification'
    'Invoke-BatchQuestionTransitionFromNotification'
    'Invoke-TaskTransitionFromNotification'
)
