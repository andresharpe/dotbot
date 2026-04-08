<#
.SYNOPSIS
    Reusable interview loop for kickstart Phase 0 and interview-type phases.
.DESCRIPTION
    Extracted from launch-process.ps1 as part of v4 Phase 03 (#92).
    Runs a multi-round Q&A loop with Claude, collecting user answers
    via local files or external Teams notifications.
#>

function Invoke-InterviewLoop {
    param(
        [string]$ProcessId,
        [hashtable]$ProcessData,
        [string]$BotRoot,
        [string]$ProductDir,
        [string]$UserPrompt,
        [switch]$ShowDebugJson,
        [switch]$ShowVerboseOutput,
        [string]$PermissionMode
    )

    $processData = $ProcessData

    # Load interview prompt template
    $interviewWorkflowPath = Join-Path $BotRoot "recipes\prompts\00-kickstart-interview.md"
    $interviewWorkflow = ""
    if (Test-Path $interviewWorkflowPath) {
        $interviewWorkflow = Get-Content $interviewWorkflowPath -Raw
    }

    # Check for briefing files
    $briefingDir = Join-Path $ProductDir "briefing"
    $interviewFileRefs = ""
    if (Test-Path $briefingDir) {
        $briefingFiles = Get-ChildItem -Path $briefingDir -File
        if ($briefingFiles.Count -gt 0) {
            $interviewFileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
            foreach ($bf in $briefingFiles) {
                $interviewFileRefs += "- $($bf.FullName)`n"
            }
        }
    }

    $interviewRound = 0
    $allQandA = @()
    $questionsPath = Join-Path $ProductDir "clarification-questions.json"
    $answersPath   = Join-Path $ProductDir "clarification-answers.json"
    $summaryPath   = Join-Path $ProductDir "interview-summary.md"

    # Use Opus for interview quality
    $interviewModel = Resolve-ProviderModelId -ModelAlias 'Opus'

    do {
        $interviewRound++

        # Build previous Q&A context
        $previousContext = ""
        if ($allQandA.Count -gt 0) {
            $previousContext = "`n`n## Previous Interview Rounds`n"
            foreach ($round in $allQandA) {
                $previousContext += "`n### Round $($round.round)`n"
                foreach ($qa in $round.pairs) {
                    $previousContext += "**Q:** $($qa.question)`n**A:** $($qa.answer)`n`n"
                }
            }
        }

        $interviewPrompt = @"
$interviewWorkflow

## User's Project Description

$UserPrompt
$interviewFileRefs
$previousContext

## Instructions

Review all context above. Decide whether to write clarification-questions.json (more questions needed) or interview-summary.md (all clear). Write exactly one file to .bot/workspace/product/.
"@

        Write-Status "Interview round $interviewRound..." -Type Process
        Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound"

        $interviewSessionId = New-ProviderSession
        $streamArgs = @{
            Prompt = $interviewPrompt
            Model = $interviewModel
            SessionId = $interviewSessionId
            PersistSession = $false
        }
        if ($ShowDebugJson) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerboseOutput) { $streamArgs['ShowVerbose'] = $true }
        if ($PermissionMode) { $streamArgs['PermissionMode'] = $PermissionMode }

        Invoke-ProviderStream @streamArgs

        # Check what Opus wrote
        if (Test-Path $summaryPath) {
            Write-Status "Interview complete — summary written" -Type Complete
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview complete after $interviewRound round(s)"

            # Add YAML front matter to interview summary
            $meta = @{
                generated_at = (Get-Date).ToUniversalTime().ToString("o")
                model = $interviewModel
                process_id = $ProcessId
                phase = "interview"
                generator = "dotbot-kickstart"
            }
            Add-YamlFrontMatter -FilePath $summaryPath -Metadata $meta

            # Clean up any leftover question/answer files now that the interview is fully analysed
            Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
            Remove-Item $answersPath -Force -ErrorAction SilentlyContinue

            break
        }

        if (Test-Path $questionsPath) {
            try {
                $questionsRaw = Get-Content $questionsPath -Raw
                $questionsData = $questionsRaw | ConvertFrom-Json
                $questions = $questionsData.questions
            } catch {
                Write-Status "Failed to parse questions JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            Write-Status "Round ${interviewRound}: $($questions.Count) question(s) — waiting for user" -Type Info

            # Set process to needs-input
            $processData.status = 'needs-input'
            $processData.pending_questions = $questionsData
            $processData.interview_round = $interviewRound
            $processData.heartbeat_status = "Waiting for interview answers (round $interviewRound)"
            Write-ProcessFile -Id $ProcessId -Data $processData
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Waiting for user answers (round $interviewRound, $($questions.Count) questions)"

            # Send questions to external notification channel (Teams) if configured
            $interviewNotifications = @{}
            $interviewNotifSettings = $null
            try {
                $notifModule = Join-Path $BotRoot "systems\mcp\modules\NotificationClient.psm1"
                if (Test-Path $notifModule) {
                    Import-Module $notifModule -Force
                    $interviewNotifSettings = Get-NotificationSettings -BotRoot $BotRoot
                    if ($interviewNotifSettings.enabled) {
                        foreach ($q in $questions) {
                            $fakeTask = @{ id = "$ProcessId-interview"; name = "Kickstart Interview Round $interviewRound" }
                            $pendingQ = @{
                                id = "$($q.id)-r$interviewRound"
                                question = $q.question
                                context = $q.context
                                options = @($q.options | ForEach-Object { @{ key = $_.key; label = $_.label; rationale = $_.rationale } })
                                recommendation = $q.recommendation
                            }
                            $sendResult = Send-TaskNotification -TaskContent $fakeTask -PendingQuestion $pendingQ -Settings $interviewNotifSettings
                            if ($sendResult.success) {
                                $interviewNotifications[$q.id] = @{
                                    question_id = $sendResult.question_id
                                    instance_id = $sendResult.instance_id
                                    project_id  = $sendResult.project_id
                                }
                            }
                        }
                        Write-Status "Sent $($interviewNotifications.Count) question(s) to Teams" -Type Info
                    }
                }
            } catch {
                Write-Status "Notification send failed (non-fatal): $($_.Exception.Message)" -Type Warn
            }

            # Poll for answers file OR external Teams responses
            $answersPath = Join-Path $ProductDir "clarification-answers.json"
            if (Test-Path $answersPath) { Remove-Item $answersPath -Force }
            $teamsAnswers = @{}
            $lastTeamsPoll = [datetime]::MinValue
            $teamsPollInterval = 10  # seconds between server polls

            while (-not (Test-Path $answersPath)) {
                if (Test-ProcessStopSignal -Id $ProcessId) {
                    Write-Status "Stop signal received during interview" -Type Error
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    $processData.pending_questions = $null
                    Write-ProcessFile -Id $ProcessId -Data $processData
                    throw "Process stopped by user during interview"
                }

                # Check for Teams responses if notifications were sent
                if ($interviewNotifications.Count -gt 0 -and ([datetime]::UtcNow - $lastTeamsPoll).TotalSeconds -ge $teamsPollInterval) {
                    $lastTeamsPoll = [datetime]::UtcNow
                    foreach ($qId in @($interviewNotifications.Keys)) {
                        if ($teamsAnswers.ContainsKey($qId)) { continue }
                        try {
                            $notif = $interviewNotifications[$qId]
                            $resp = Get-TaskNotificationResponse -Notification $notif -Settings $interviewNotifSettings
                            if ($resp) {
                                $attachDir = Join-Path $ProductDir "attachments\$qId"
                                $resolved = Resolve-NotificationAnswer -Response $resp -Settings $interviewNotifSettings -AttachDir $attachDir
                                if ($resolved) {
                                    $teamsAnswers[$qId] = $resolved
                                    Write-Status "Received Teams answer for $qId : $($resolved.answer)" -Type Info
                                }
                            }
                        } catch { Write-BotLog -Level Warn -Message "Teams polling attempt failed" -Exception $_ }
                    }

                    # If all questions answered via Teams, write the answers file
                    if ($teamsAnswers.Count -ge $questions.Count) {
                        $answersObj = @{
                            answers = @($questions | ForEach-Object {
                                $r = $teamsAnswers[$_.id]
                                $entry = @{ id = $_.id; question = $_.question; answer = $r.answer }
                                if ($r.attachments -and $r.attachments.Count -gt 0) { $entry['attachments'] = $r.attachments }
                                $entry
                            })
                            answered_via = "teams"
                        }
                        $answersObj | ConvertTo-Json -Depth 10 | Set-Content -Path $answersPath -Encoding UTF8
                        Write-Status "All $($questions.Count) answers received via Teams" -Type Complete
                        break
                    }
                }

                Start-Sleep -Seconds 2
            }

            # Read answers
            try {
                $answersRaw = Get-Content $answersPath -Raw
                $answersData = $answersRaw | ConvertFrom-Json
            } catch {
                Write-Status "Failed to parse answers JSON: $($_.Exception.Message)" -Type Warn
                break
            }

            # Check if user skipped
            if ($answersData.skipped -eq $true) {
                Write-Status "User skipped interview" -Type Info
                Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "User skipped interview at round $interviewRound"
                # Clean up
                Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
                Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
                break
            }

            # Accumulate Q&A for next round
            $allQandA += @{
                round = $interviewRound
                pairs = @($answersData.answers)
            }

            Write-Status "Answers received for round $interviewRound" -Type Success
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Received answers for round $interviewRound"

            # Keep clarification-questions.json and clarification-answers.json intact so
            # Claude can read them in the next round when it processes the answers.
            # They will be overwritten (questions) or pre-cleared (answers, line below)
            # naturally when the next round begins.

            # Reset process status
            $processData.status = 'running'
            $processData.pending_questions = $null
            $processData.interview_round = $null
            $processData.heartbeat_status = "Processing interview answers"
            Write-ProcessFile -Id $ProcessId -Data $processData
        } else {
            # Neither file written — something went wrong, proceed without
            Write-Status "Interview round produced no output — proceeding" -Type Warn
            Write-ProcessActivity -Id $ProcessId -ActivityType "text" -Message "Interview round $interviewRound produced no output — skipping"
            break
        }
    } while ($true)

    # Ensure status is running after interview
    $processData.status = 'running'
    $processData.pending_questions = $null
    $processData.interview_round = $null
    Write-ProcessFile -Id $ProcessId -Data $processData
}
