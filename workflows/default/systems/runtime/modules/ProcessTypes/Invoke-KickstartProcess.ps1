<#
.SYNOPSIS
    Kickstart process type: manifest-driven multi-phase product setup pipeline.
.DESCRIPTION
    Runs a workflow.yaml-driven pipeline of phases (interview, llm, task-runner,
    script, barrier) with question detection, git checkpoints, and YAML front matter.
    Extracted from launch-process.ps1 as part of v4 Phase 03 (#92).
#>

param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

$Type = $Context.Type
$botRoot = $Context.BotRoot
$procId = $Context.ProcId
$processData = $Context.ProcessData
$claudeModelName = $Context.ModelName
$claudeSessionId = $Context.SessionId
$Prompt = $Context.Prompt
$Description = $Context.Description
$ShowDebug = $Context.ShowDebug
$ShowVerbose = $Context.ShowVerbose
$projectRoot = $Context.ProjectRoot
$controlDir = $Context.ControlDir
$settings = $Context.Settings
$Model = $Context.Model
$NeedsInterview = $Context.NeedsInterview
$FromPhase = $Context.FromPhase
$skipPhaseIds = $Context.SkipPhaseIds
$permissionMode = $Context.PermissionMode

if (-not $Description) { $Description = "Kickstart project setup" }

$processData.status = 'running'
$processData.workflow = "kickstart-pipeline"
$processData.description = $Description
$processData.heartbeat_status = $Description
Write-ProcessFile -Id $procId -Data $processData
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "$Description started"

$productDir = Join-Path $botRoot "workspace\product"

# Ensure repo has at least one commit (required for worktrees and phase commits)
$hasCommits = git -C $projectRoot rev-parse --verify HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Status "Creating initial commit..." -Type Process
    git -C $projectRoot add .bot/ 2>$null
    git -C $projectRoot commit -m "chore: initialize dotbot" --allow-empty 2>$null
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Created initial git commit (repo had no commits)"
}

try {
    # ===== Kickstart task pipeline (manifest-driven) =====
    # Load manifest helpers
    . (Join-Path $botRoot "systems\runtime\modules\workflow-manifest.ps1")
    # Load post-script runner (shared with Invoke-WorkflowProcess)
    . (Join-Path $botRoot "systems\runtime\modules\post-script-runner.ps1")

    $kickstartPhases = @()
    $activeWorkflowDir = $null
    $manifest = Get-ActiveWorkflowManifest -BotRoot $botRoot
    if ($manifest -and $manifest.tasks -and $manifest.tasks.Count -gt 0) {
        Ensure-ManifestTaskIds -Tasks $manifest.tasks
        $kickstartPhases = @($manifest.tasks)
        # Capture the workflow install dir so script phases can resolve workflow-scoped templates
        $wfInstallRoot = Join-Path $botRoot "workflows"
        $firstWf = Get-ChildItem $wfInstallRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($firstWf) { $activeWorkflowDir = $firstWf.FullName }
    }

    # Fallback to settings.kickstart.phases for legacy installs
    if ($kickstartPhases.Count -eq 0 -and $settings.kickstart -and $settings.kickstart.phases) {
        $kickstartPhases = @($settings.kickstart.phases)
    }

    if (-not $kickstartPhases -or $kickstartPhases.Count -eq 0) {
        throw "No workflow tasks found — ensure a workflow.yaml exists or settings.kickstart.phases is configured"
    }

    # ===== Build phase tracking array from config =====
    $hasInterviewPhase = $kickstartPhases | Where-Object { $_.type -eq 'interview' }
    if ($NeedsInterview -and -not $hasInterviewPhase) {
        # Prepend a synthetic interview phase for tracking
        $processData.phases = @(@{
            id = "interview"; name = "Interview"; type = "interview"
            status = "pending"; started_at = $null; completed_at = $null; error = $null
        })
    } else {
        $processData.phases = @()
    }
    # Append all config-driven phases
    $processData.phases += @($kickstartPhases | ForEach-Object {
        @{
            id = $_.id; name = $_.name
            type = if ($_.type) { $_.type } else { "llm" }
            status = "pending"; started_at = $null; completed_at = $null; error = $null
        }
    })
    Write-ProcessFile -Id $procId -Data $processData

    # ===== Validate FromPhase =====
    $fromPhaseActive = $false
    if ($FromPhase) {
        $validPhaseIds = @($processData.phases | ForEach-Object { $_.id })
        if ($FromPhase -notin $validPhaseIds) {
            Write-Status "Unknown phase '$FromPhase' — running all phases" -Type Warn
            $FromPhase = $null
        } else {
            $fromPhaseActive = $true
        }
    }

    # ===== Phase 0: Interview (backward compat for profiles without interview-type phase) =====
    if ($NeedsInterview -and -not $hasInterviewPhase) {
        $interviewPhaseIdx = @($processData.phases | ForEach-Object { $_.id }).IndexOf('interview')

        if ($fromPhaseActive -and $FromPhase -ne 'interview') {
            $processData.phases[$interviewPhaseIdx].status = 'skipped'
            $processData.phases[$interviewPhaseIdx].completed_at = 'prior-run'
            Write-ProcessFile -Id $procId -Data $processData
        } else {
            if ($fromPhaseActive) { $fromPhaseActive = $false }
            $processData.phases[$interviewPhaseIdx].status = 'running'
            $processData.phases[$interviewPhaseIdx].started_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData

            $processData.heartbeat_status = "Phase 0: Interviewing for requirements"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase 0 — interviewing for requirements..."
            Write-Header "Phase 0: Interview"

            Invoke-InterviewLoop -ProcessId $procId -ProcessData $processData `
                -BotRoot $botRoot -ProductDir $productDir -UserPrompt $Prompt `
                -ShowDebugJson:$ShowDebug -ShowVerboseOutput:$ShowVerbose `
                -PermissionMode $permissionMode

            $processData.phases[$interviewPhaseIdx].status = 'completed'
            $processData.phases[$interviewPhaseIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
        }
    }

    # Build briefing context once (shared across LLM phases)
    $briefingDir = Join-Path $productDir "briefing"
    $fileRefs = ""
    if (Test-Path $briefingDir) {
        $briefingFiles = Get-ChildItem -Path $briefingDir -File
        if ($briefingFiles.Count -gt 0) {
            $fileRefs = "`n`nBriefing files have been saved to the briefing/ directory. Read and use these for context:`n"
            foreach ($bf in $briefingFiles) {
                $fileRefs += "- $($bf.FullName)`n"
            }
        }
    }

    # Build interview context once (shared across LLM phases)
    $interviewContext = ""
    $interviewSummaryPath = Join-Path $productDir "interview-summary.md"
    if (Test-Path $interviewSummaryPath) {
        $interviewContext = @"

## Interview Summary

An interview-summary.md file exists in .bot/workspace/product/ containing the user's clarified requirements with both verbatim answers and expanded interpretation. **Read this file** and use it to guide your decisions — it reflects the user's confirmed preferences for platform, architecture, technology, domain model, and other key directions.
"@
    }

    $phaseNum = 1
    foreach ($phase in $kickstartPhases) {
        $phaseName = $phase.name
        $trackIdx = @($processData.phases | ForEach-Object { $_.id }).IndexOf($phase.id)

        # --- FromPhase skip logic ---
        if ($fromPhaseActive -and $phase.id -ne $FromPhase) {
            if ($trackIdx -ge 0) {
                $processData.phases[$trackIdx].status = 'skipped'
                $processData.phases[$trackIdx].completed_at = 'prior-run'
                Write-ProcessFile -Id $procId -Data $processData
            }
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): before resume point"
            Write-Status "Skipping phase $phaseNum ($phaseName) — before resume point" -Type Info
            $phaseNum++; continue
        }
        if ($fromPhaseActive) { $fromPhaseActive = $false }

        # --- Condition check (gitignore-style path patterns) ---
        if ($phase.condition) {
            if (-not (Test-ManifestCondition -ProjectRoot $projectRoot -Condition $phase.condition)) {
                if ($trackIdx -ge 0) {
                    $processData.phases[$trackIdx].status = 'skipped'
                    $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                }
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): condition not met ($($phase.condition))"
                Write-Status "Skipping phase $phaseNum ($phaseName) — condition not met" -Type Info
                $phaseNum++; continue
            }
        }

        # --- User-requested skip ---
        if ($phase.id -in $skipPhaseIds) {
            if ($trackIdx -ge 0) {
                $processData.phases[$trackIdx].status = 'skipped'
                $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
            }
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping phase $phaseNum ($phaseName): user opted out"
            Write-Status "Skipping phase $phaseNum ($phaseName) — user opted out" -Type Info
            $phaseNum++; continue
        }

        # Determine phase type
        $phaseType = if ($phase.type) { $phase.type } else { "llm" }

        # Mark phase as running
        if ($trackIdx -ge 0) {
            $processData.phases[$trackIdx].status = 'running'
            $processData.phases[$trackIdx].started_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        $processData.heartbeat_status = "Phase ${phaseNum}: $phaseName"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "init" -Message "Phase $phaseNum — $($phaseName.ToLower())..."
        Write-Header "Phase ${phaseNum}: $phaseName"

        if ($phaseType -eq "barrier") {
            # --- Barrier phase: no-op, marks dependencies as resolved ---
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Barrier phase $phaseNum ($phaseName) complete"
            Write-Status "Barrier phase $phaseNum ($phaseName) — dependencies resolved" -Type Complete

        } elseif ($phaseType -eq "task-runner") {
            # --- Task Runner phase: launch concurrent worker slots ---
            $wfConcurrency = 1
            if ($settings.scoring -and $settings.scoring.max_concurrent_scores) {
                $wfConcurrency = [int]$settings.scoring.max_concurrent_scores
            } elseif ($settings.execution -and $settings.execution.max_concurrent) {
                $wfConcurrency = [int]$settings.execution.max_concurrent
            }
            if ($wfConcurrency -lt 1) { $wfConcurrency = 1 }

            $launchScript = Join-Path $botRoot "systems\runtime\launch-process.ps1"
            $wfFilter = if ($settings.profile) { $settings.profile } else { "" }

            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Launching $wfConcurrency workflow worker(s)$(if ($wfFilter) { " (workflow: $wfFilter)" })"
            Write-Status "Launching $wfConcurrency workflow worker(s) for phase $phaseNum ($phaseName)" -Type Process

            $slotLogDir = Join-Path $controlDir "slot-logs"
            if (-not (Test-Path $slotLogDir)) { New-Item -Path $slotLogDir -ItemType Directory -Force | Out-Null }

            $childProcs = @()
            for ($s = 0; $s -lt $wfConcurrency; $s++) {
                $slotArgs = @(
                    "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", "`"$launchScript`"",
                    "-Type", "task-runner",
                    "-Slot", "$s",
                    "-Continue",
                    "-NoWait",
                    "-Model", $Model
                )
                if ($wfFilter) { $slotArgs += @("-Workflow", $wfFilter) }

                $stdoutLog = Join-Path $slotLogDir "slot-$s-stdout.log"
                $stderrLog = Join-Path $slotLogDir "slot-$s-stderr.log"

                $childProc = Start-Process -FilePath "pwsh" `
                    -ArgumentList $slotArgs `
                    -WorkingDirectory $projectRoot `
                    -RedirectStandardOutput $stdoutLog `
                    -RedirectStandardError $stderrLog `
                    -PassThru

                $childProcs += $childProc
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Workflow worker slot $s started (PID: $($childProc.Id))"
                Write-Status "Slot $s started (PID: $($childProc.Id))" -Type Info
            }

            # Poll for completion, relaying heartbeats and checking stop signal
            while ($true) {
                if (Test-ProcessStopSignal -Id $procId) {
                    Write-Status "Stop signal — terminating workflow workers" -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Stop signal: killing $($childProcs.Count) worker(s)"
                    foreach ($cp in $childProcs) {
                        try { if (-not $cp.HasExited) { Stop-Process -Id $cp.Id -Force -ErrorAction SilentlyContinue } } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process" -Exception $_ }
                    }
                    throw "Process stopped by user during workflow phase"
                }

                $wfRunning = @($childProcs | Where-Object { -not $_.HasExited })
                if ($wfRunning.Count -eq 0) { break }

                $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                $processData.heartbeat_status = "Workflow: $($wfRunning.Count)/$wfConcurrency workers active"
                Write-ProcessFile -Id $procId -Data $processData
                Start-Sleep -Seconds 5
            }

            # Report results
            $wfSucceeded = @($childProcs | Where-Object { $_.ExitCode -eq 0 }).Count
            $wfFailed = $wfConcurrency - $wfSucceeded
            $wfMsg = "Workflow phase complete: $wfSucceeded/$wfConcurrency workers succeeded"
            if ($wfFailed -gt 0) { $wfMsg += " ($wfFailed failed)" }
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message $wfMsg
            Write-Status $wfMsg -Type $(if ($wfFailed -gt 0) { 'Warn' } else { 'Complete' })

        } elseif ($phaseType -eq "interview") {
            # --- Interview phase: run interview loop at this point in the pipeline ---
            if (-not $NeedsInterview) {
                if ($trackIdx -ge 0) {
                    $processData.phases[$trackIdx].status = 'skipped'
                    $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                }
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping interview phase $phaseNum ($phaseName): not requested"
                Write-Status "Skipping interview phase (not requested)" -Type Info
                $phaseNum++; continue
            }

            Invoke-InterviewLoop -ProcessId $procId -ProcessData $processData `
                -BotRoot $botRoot -ProductDir $productDir -UserPrompt $Prompt `
                -ShowDebugJson:$ShowDebug -ShowVerboseOutput:$ShowVerbose `
                -PermissionMode $permissionMode

        } elseif ($phase.script) {
            # --- Script-only phase (no LLM) ---
            # Resolve script path: if it starts with 'scripts/' resolve from $botRoot, otherwise from systems/runtime/
            $rawScript = $phase.script
            $scriptPath = if ($rawScript -match '^scripts[/\\]') {
                Join-Path $botRoot $rawScript
            } else {
                Join-Path $botRoot "systems\runtime\$rawScript"
            }
            $scriptInvokeArgs = @{ BotRoot = $botRoot; Model = $claudeModelName; ProcessId = $procId }
            if ($activeWorkflowDir) { $scriptInvokeArgs['WorkflowDir'] = $activeWorkflowDir }
            & $scriptPath @scriptInvokeArgs
        } else {
            # --- LLM phase ---

            # Pre-phase cleanup: remove leftover clarification files from previous phases
            $phaseQuestionsPath = Join-Path $productDir "clarification-questions.json"
            $phaseAnswersPath = Join-Path $productDir "clarification-answers.json"
            if (Test-Path $phaseQuestionsPath) { Remove-Item $phaseQuestionsPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path $phaseAnswersPath) { Remove-Item $phaseAnswersPath -Force -ErrorAction SilentlyContinue }

            $wfContent = ""
            $wfPath = Join-Path $botRoot "recipes\prompts\$($phase.workflow)"
            if (Test-Path $wfPath) { $wfContent = Get-Content $wfPath -Raw }

            $phasePrompt = @"
$wfContent

User's project description:
$Prompt
$fileRefs
$interviewContext

Instructions:
1. Read any briefing files listed above and any existing project files (README.md, etc.) for additional context
2. If an interview-summary.md file exists in .bot/workspace/product/, read it carefully — it contains clarified requirements from the user
3. Follow the workflow above to create the required outputs. Write files to .bot/workspace/product/
4. Do NOT create tasks or use task management tools unless the workflow explicitly instructs you to
5. Write comprehensive, well-structured content based on the user's description and any attached files
6. Make reasonable inferences where details are missing — the user can refine later

IMPORTANT: If creating mission.md, it MUST begin with ## Executive Summary as the first content after the title. This is required for the UI to detect that product planning is complete.
"@

            $claudeSessionId = New-ProviderSession
            $streamArgs = @{
                Prompt = $phasePrompt
                Model = $claudeModelName
                SessionId = $claudeSessionId
                PersistSession = $false
            }
            if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
            if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }
            if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }

            Invoke-ProviderStream @streamArgs

            # --- Post-phase question detection (Generate -> Ask -> Adjust) ---
            if (Test-Path $phaseQuestionsPath) {
                try {
                    $phaseQData = (Get-Content $phaseQuestionsPath -Raw) | ConvertFrom-Json
                } catch {
                    Write-Status "Failed to parse phase questions JSON: $($_.Exception.Message)" -Type Warn
                    $phaseQData = $null
                }

                if ($phaseQData -and $phaseQData.questions -and $phaseQData.questions.Count -gt 0) {
                    Write-Status "Phase $phaseNum ($phaseName): $($phaseQData.questions.Count) question(s) — waiting for user" -Type Info
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum has $($phaseQData.questions.Count) clarification question(s)"

                    # 1. ASK — Set process to needs-input, poll for answers
                    $processData.status = 'needs-input'
                    $processData.pending_questions = $phaseQData
                    $processData.heartbeat_status = "Waiting for answers (phase ${phaseNum}: $phaseName)"
                    Write-ProcessFile -Id $procId -Data $processData

                    # Send questions to external notification channel (Teams) if configured
                    $phaseNotifications = @{}
                    $phaseNotifSettings = $null
                    try {
                        $notifModule = Join-Path $botRoot "systems\mcp\modules\NotificationClient.psm1"
                        if (Test-Path $notifModule) {
                            Import-Module $notifModule -Force
                            $phaseNotifSettings = Get-NotificationSettings -BotRoot $botRoot
                            if ($phaseNotifSettings.enabled) {
                                foreach ($q in $phaseQData.questions) {
                                    $fakeTask = @{ id = "$procId-phase-$phaseNum"; name = "Phase $phaseNum - $phaseName" }
                                    $pendingQ = @{
                                        id = "$($q.id)-p$phaseNum"
                                        question = $q.question
                                        context = $q.context
                                        options = @($q.options | ForEach-Object { @{ key = $_.key; label = $_.label; rationale = $_.rationale } })
                                        recommendation = $q.recommendation
                                    }
                                    $sendResult = Send-TaskNotification -TaskContent $fakeTask -PendingQuestion $pendingQ -Settings $phaseNotifSettings
                                    if ($sendResult.success) {
                                        $phaseNotifications[$q.id] = @{
                                            question_id = $sendResult.question_id
                                            instance_id = $sendResult.instance_id
                                            project_id  = $sendResult.project_id
                                        }
                                    }
                                }
                                Write-Status "Sent $($phaseNotifications.Count) phase question(s) to Teams" -Type Info
                            }
                        }
                    } catch {
                        Write-Status "Phase notification send failed (non-fatal): $($_.Exception.Message)" -Type Warn
                    }

                    if (Test-Path $phaseAnswersPath) { Remove-Item $phaseAnswersPath -Force }
                    $phaseTeamsAnswers = @{}
                    $phaseLastPoll = [datetime]::MinValue

                    while (-not (Test-Path $phaseAnswersPath)) {
                        if (Test-ProcessStopSignal -Id $procId) {
                            Write-Status "Stop signal received waiting for phase answers" -Type Error
                            $processData.status = 'stopped'
                            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                            $processData.pending_questions = $null
                            Write-ProcessFile -Id $procId -Data $processData
                            throw "Process stopped by user during phase $phaseNum questions"
                        }

                        # Check for Teams responses
                        if ($phaseNotifications.Count -gt 0 -and ([datetime]::UtcNow - $phaseLastPoll).TotalSeconds -ge 10) {
                            $phaseLastPoll = [datetime]::UtcNow
                            foreach ($qId in @($phaseNotifications.Keys)) {
                                if ($phaseTeamsAnswers.ContainsKey($qId)) { continue }
                                try {
                                    $notif = $phaseNotifications[$qId]
                                    $resp = Get-TaskNotificationResponse -Notification $notif -Settings $phaseNotifSettings
                                    if ($resp) {
                                        $attachDir = Join-Path $productDir "attachments\$qId"
                                        $resolved = Resolve-NotificationAnswer -Response $resp -Settings $phaseNotifSettings -AttachDir $attachDir
                                        if ($resolved) {
                                            $phaseTeamsAnswers[$qId] = $resolved
                                            Write-Status "Received Teams answer for $qId : $($resolved.answer)" -Type Info
                                        }
                                    }
                                } catch { Write-BotLog -Level Warn -Message "Teams polling attempt failed" -Exception $_ }
                            }

                            if ($phaseTeamsAnswers.Count -ge $phaseQData.questions.Count) {
                                $answersObj = @{
                                    answers = @($phaseQData.questions | ForEach-Object {
                                        $r = $phaseTeamsAnswers[$_.id]
                                        $entry = @{ id = $_.id; question = $_.question; answer = $r.answer }
                                        if ($r.attachments -and $r.attachments.Count -gt 0) { $entry['attachments'] = $r.attachments }
                                        $entry
                                    })
                                    answered_via = "teams"
                                }
                                $answersObj | ConvertTo-Json -Depth 10 | Set-Content -Path $phaseAnswersPath -Encoding UTF8
                                Write-Status "All $($phaseQData.questions.Count) phase answers received via Teams" -Type Complete
                                break
                            }
                        }

                        Start-Sleep -Seconds 2
                    }

                    # Read answers
                    try {
                        $phaseAnswersData = (Get-Content $phaseAnswersPath -Raw) | ConvertFrom-Json
                    } catch {
                        Write-Status "Failed to parse phase answers JSON: $($_.Exception.Message)" -Type Warn
                        $phaseAnswersData = $null
                    }

                    # Check if user skipped
                    if ($phaseAnswersData -and $phaseAnswersData.skipped -eq $true) {
                        Write-Status "User skipped phase $phaseNum questions" -Type Info
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "User skipped phase $phaseNum questions"
                    } elseif ($phaseAnswersData) {
                        Write-Status "Answers received for phase $phaseNum" -Type Success
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Received answers for phase $phaseNum"

                        # 2. RECORD — Append Q&A to interview-summary.md
                        $summaryPath = Join-Path $productDir "interview-summary.md"
                        $timestamp = (Get-Date).ToUniversalTime().ToString("o")
                        $qaSection = "`n`n### Phase ${phaseNum}: $phaseName`n"
                        $qaSection += "| # | Question | Answer (verbatim) | Interpretation | Timestamp |`n"
                        $qaSection += "|---|----------|--------------------|----------------|-----------|`n"

                        $qIdx = 0
                        foreach ($ans in $phaseAnswersData.answers) {
                            $qIdx++
                            $qText = ($ans.question -replace '\|', '\|' -replace "`n", ' ')
                            $aText = ($ans.answer -replace '\|', '\|' -replace "`n", ' ')
                            $qaSection += "| q$qIdx | $qText | $aText | _pending_ | $timestamp |`n"
                        }

                        if (Test-Path $summaryPath) {
                            # Append to existing file
                            $existingContent = Get-Content $summaryPath -Raw
                            if ($existingContent -notmatch '## Clarification Log') {
                                $qaSection = "`n## Clarification Log`n" + $qaSection
                            }
                            Add-Content -Path $summaryPath -Value $qaSection -NoNewline
                        } else {
                            # Create new summary with clarification log
                            $newSummary = "# Interview Summary`n`n## Clarification Log`n" + $qaSection
                            Set-Content -Path $summaryPath -Value $newSummary -NoNewline
                        }

                        # 3. ADJUST — Run holistic artifact correction pass
                        $adjustPromptPath = Join-Path $botRoot "recipes\includes\adjust-after-answers.md"
                        if (Test-Path $adjustPromptPath) {
                            $adjustContent = Get-Content $adjustPromptPath -Raw

                            $adjustPrompt = @"
$adjustContent

## Context

- **Phase that generated questions**: Phase $phaseNum — $phaseName
- **User's project description**: $Prompt
$fileRefs
$interviewContext

Instructions:
1. Read .bot/workspace/product/interview-summary.md for the full Q&A history including the new answers
2. Read ALL existing product artifacts in .bot/workspace/product/
3. Assess the impact of the new information across all artifacts
4. Enrich/correct any affected artifacts
5. Fill in the Interpretation column for the new Q&A entries in interview-summary.md
"@

                            Write-Status "Running post-answer adjustment for phase $phaseNum..." -Type Process
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Adjusting artifacts based on phase $phaseNum answers"

                            $adjustSessionId = New-ProviderSession
                            $adjustArgs = @{
                                Prompt = $adjustPrompt
                                Model = $claudeModelName
                                SessionId = $adjustSessionId
                                PersistSession = $false
                            }
                            if ($ShowDebug) { $adjustArgs['ShowDebugJson'] = $true }
                            if ($ShowVerbose) { $adjustArgs['ShowVerbose'] = $true }
                            if ($permissionMode) { $adjustArgs['PermissionMode'] = $permissionMode }

                            Invoke-ProviderStream @adjustArgs

                            Write-Status "Post-answer adjustment complete for phase $phaseNum" -Type Complete
                        } else {
                            Write-Status "Adjust prompt not found at $adjustPromptPath — skipping adjustment" -Type Warn
                        }
                    }

                    # 4. CLEANUP — Remove JSON files, reset process status
                    Remove-Item $phaseQuestionsPath -Force -ErrorAction SilentlyContinue
                    Remove-Item $phaseAnswersPath -Force -ErrorAction SilentlyContinue
                    $processData.status = 'running'
                    $processData.pending_questions = $null
                    $processData.heartbeat_status = "Running phase $phaseNum"
                    Write-ProcessFile -Id $procId -Data $processData
                }
            }
        }

        # --- Validation (skip for barrier/interview phase types) ---
        if ($phaseType -notin @("barrier", "interview")) {
            # Support both manifest-style 'outputs' and legacy 'required_outputs'
            $validationOutputs = if ($phase.outputs) { $phase.outputs } else { $phase.required_outputs }
            $validationOutputsDir = if ($phase.outputs_dir) { $phase.outputs_dir } else { $phase.required_outputs_dir }
            if ($validationOutputs) {
                foreach ($f in $validationOutputs) {
                    if (-not (Test-Path (Join-Path $productDir $f))) {
                        throw "Phase $phaseNum ($phaseName) failed: $f was not created"
                    }
                }
            } elseif ($validationOutputsDir) {
                $dirPath = Join-Path $botRoot "workspace\$validationOutputsDir"
                $minCount = if ($phase.min_output_count) { [int]$phase.min_output_count } else { 1 }
                $fileCount = if (Test-Path $dirPath) {
                    @(Get-ChildItem $dirPath -File | Where-Object { $_.Name -notmatch '^[._]' }).Count
                } else { 0 }
                if ($fileCount -lt $minCount) {
                    throw "Phase $phaseNum ($phaseName) failed: expected at least $minCount file(s) in $validationOutputsDir, found $fileCount"
                }
            }
        }

        # --- Front matter ---
        if ($phase.front_matter_docs) {
            $phaseMeta = @{
                generated_at = (Get-Date).ToUniversalTime().ToString("o")
                model = $claudeModelName
                process_id = $procId
                phase = "phase-$phaseNum-$($phase.id)"
                generator = "dotbot-kickstart"
            }
            foreach ($docName in $phase.front_matter_docs) {
                $docPath = Join-Path $productDir $docName
                if (Test-Path $docPath) {
                    Add-YamlFrontMatter -FilePath $docPath -Metadata $phaseMeta
                }
            }
        }

        # --- Post-script ---
        # Delegated to shared helper; raises on non-zero exit so a failing
        # post-script now fails the phase instead of being silently ignored.
        if ($phase.post_script) {
            Invoke-PostScript -BotRoot $botRoot -ProductDir $productDir -Settings $settings `
                -Model $claudeModelName -ProcessId $procId -RawPostScript $phase.post_script
        }

        # --- Git checkpoint (supports manifest-style commit object and legacy commit_paths/commit_message) ---
        $commitPaths = if ($phase.commit -and $phase.commit.paths) { $phase.commit.paths } else { $phase.commit_paths }
        $commitMsg = if ($phase.commit -and $phase.commit.message) { $phase.commit.message }
                     elseif ($phase.commit_message) { $phase.commit_message }
                     else { "chore(kickstart): phase $phaseNum — $($phaseName.ToLower())" }
        if ($commitPaths) {
            Write-Status "Committing phase $phaseNum artifacts..." -Type Info
            foreach ($cp in $commitPaths) {
                git -C $projectRoot add ".bot/$cp" 2>$null
            }
            git -C $projectRoot commit --quiet -m $commitMsg 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum checkpoint committed"

                # Auto-push phase commits so verify hooks (02-git-pushed.ps1) pass on
                # task_mark_done. Default is ON because the verify hook expects an
                # up-to-date remote, but users can opt out via the
                # `auto_push_phase_commits: false` setting for environments without
                # an `origin` remote, with branch protections, or with other push
                # constraints. When a push fails we log the stderr explicitly so
                # users can diagnose rather than silently seeing the verify hook fail.
                $autoPushPhaseCommits = $true
                if ($null -ne $settings) {
                    $val = $null
                    if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('auto_push_phase_commits')) {
                        $val = $settings['auto_push_phase_commits']
                    } elseif ($settings.PSObject -and $settings.PSObject.Properties['auto_push_phase_commits']) {
                        $val = $settings.auto_push_phase_commits
                    }
                    if ($null -ne $val) { $autoPushPhaseCommits = [bool]$val }
                }

                if ($autoPushPhaseCommits) {
                    # Skip task branches (merged by framework later). Push everything
                    # else — including main/master — because kickstart runs in fresh
                    # repos where the user chose the starting branch, and the verify
                    # hook (02-git-pushed.ps1) will otherwise block task_mark_done on
                    # unpushed phase commits. Users with branch protection on the
                    # default branch can opt out via `auto_push_phase_commits: false`.
                    $currentBranch = git -C $projectRoot rev-parse --abbrev-ref HEAD 2>$null
                    $branchLookupExit = $LASTEXITCODE
                    if (-not $currentBranch -or $branchLookupExit -ne 0) {
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum push skipped: could not determine current branch (git rev-parse --abbrev-ref HEAD failed or returned empty)"
                    } elseif ($currentBranch -notmatch '^task/') {
                        $originUrl = git -C $projectRoot remote get-url origin 2>$null
                        if ($LASTEXITCODE -eq 0 -and $originUrl) {
                            $pushOutput = git -C $projectRoot push --quiet origin $currentBranch 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum pushed to origin/$currentBranch"
                            } else {
                                $pushMessage = if ($pushOutput) { ($pushOutput | Out-String).Trim() } else { "unknown git push failure" }
                                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum push to origin/$currentBranch failed: $pushMessage"
                            }
                        } else {
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum push skipped: git remote 'origin' is not configured"
                        }
                    } else {
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum push skipped: branch '$currentBranch' is task-scoped (framework will merge)"
                    }
                } else {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum push skipped: auto_push_phase_commits setting is disabled"
                }
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum checkpoint: nothing to commit"
            }
        }

        # Mark phase as completed
        if ($trackIdx -ge 0) {
            $processData.phases[$trackIdx].status = 'completed'
            $processData.phases[$trackIdx].completed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
        }

        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Phase $phaseNum complete — $($phaseName.ToLower())"
        $phaseNum++
    }

    # Done
    $processData.status = 'completed'
    $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
    $processData.heartbeat_status = "Completed: $Description"
} catch {
    # Mark the current phase as failed if we have a tracking index
    if ($trackIdx -ge 0 -and $processData.phases[$trackIdx].status -eq 'running') {
        $processData.phases[$trackIdx].status = 'failed'
        $processData.phases[$trackIdx].error = $_.Exception.Message
    }
    $processData.status = 'failed'
    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
    $processData.error = $_.Exception.Message
    $processData.heartbeat_status = "Failed: $($_.Exception.Message)"
    Write-Status "Process failed: $($_.Exception.Message)" -Type Error
    # C8: Log the error details to activity JSONL so failures aren't silent
    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Phase failure: $($_.Exception.Message)"
}

Write-ProcessFile -Id $procId -Data $processData
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status))"
