<#
.SYNOPSIS
    Analysis process type: todo -> analysing -> analysed task loop.
.DESCRIPTION
    Runs a continuous loop picking up todo tasks, running analysis via Claude,
    and marking them as analysed/needs-input/skipped. No worktrees.
    Extracted from launch-process.ps1 as part of v4 Phase 03 (#92).
#>

param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

$botRoot = $Context.BotRoot
$procId = $Context.ProcId
$processData = $Context.ProcessData
$claudeModelName = $Context.ModelName
$claudeSessionId = $Context.SessionId
$ShowDebug = $Context.ShowDebug
$ShowVerbose = $Context.ShowVerbose
$projectRoot = $Context.ProjectRoot
$processesDir = $Context.ProcessesDir
$settings = $Context.Settings
$Model = $Context.Model
$sessionId = $Context.BatchSessionId
$instanceId = $Context.InstanceId
$Continue = $Context.Continue
$NoWait = $Context.NoWait
$MaxTasks = $Context.MaxTasks
$TaskId = $Context.TaskId
$permissionMode = $Context.PermissionMode

# Load prompt template
$templateFile = Join-Path $botRoot "recipes\prompts\98-analyse-task.md"
$promptTemplate = Get-Content $templateFile -Raw
$processData.workflow = "98-analyse-task.md"

# Task reset
. (Join-Path $botRoot "systems\runtime\modules\task-reset.ps1")
$tasksBaseDir = Join-Path $botRoot "workspace\tasks"
Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $processesDir | Out-Null

# Clean up orphan worktrees from previous runs
Remove-OrphanWorktrees -ProjectRoot $projectRoot -BotRoot $botRoot

# Initialize task index for analysis
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

$tasksProcessed = 0
$maxRetriesPerTask = 2
$consecutiveFailureThreshold = 3

# Update process status to running
$processData.status = 'running'
Write-ProcessFile -Id $procId -Data $processData

try {
    while ($true) {
        # Check max tasks
        if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
            Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
            break
        }

        # Check stop signal
        if (Test-ProcessStopSignal -Id $procId) {
            Write-Status "Stop signal received" -Type Error
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process stopped by user"
            break
        }

        # Get next task
        Write-Status "Fetching next task..." -Type Process
        Reset-TaskIndex

        # Wait for any active execution worktrees to merge first
        $waitingLogged = $false
        while ($true) {
            Initialize-WorktreeMap -BotRoot $botRoot
            $map = Read-WorktreeMap
            $hasActiveExecutionWt = $false

            if ($map.Count -gt 0) {
                $index = Get-TaskIndex
                foreach ($taskId in @($map.Keys)) {
                    if ($index.InProgress.ContainsKey($taskId) -or
                        $index.Done.ContainsKey($taskId)) {
                        $entry = $map[$taskId]
                        if ($entry.worktree_path -and (Test-Path $entry.worktree_path)) {
                            $hasActiveExecutionWt = $true
                            break
                        }
                    }
                }
            }

            if (-not $hasActiveExecutionWt) { break }

            if (-not $waitingLogged) {
                Write-Status "Waiting for execution merge before next analysis..." -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" `
                    -Message "Waiting for execution to merge before starting next analysis"
                $processData.heartbeat_status = "Waiting for execution merge"
                Write-ProcessFile -Id $procId -Data $processData
                $waitingLogged = $true
            }

            Start-Sleep -Seconds 5
            if (Test-ProcessStopSignal -Id $procId) { break }
        }

        # For analysis: check resumed tasks (answered questions) first, then todo
        $taskResult = Get-NextTodoTask -Verbose

        # Immediately claim task to prevent execution from picking it up
        if ($taskResult.task) {
            # Auto-promote non-prompt tasks that skip analysis
            $taskSkipAnalysis = $taskResult.task.skip_analysis
            $taskTypeVal = if ($taskResult.task.type) { $taskResult.task.type } else { 'prompt' }
            if ($taskSkipAnalysis -or $taskTypeVal -notin @('prompt', 'prompt_template')) {
                Write-Status "Auto-promoting task (type=$taskTypeVal, skip_analysis): $($taskResult.task.name)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-promoted $($taskResult.task.name) (type=$taskTypeVal)"
                Invoke-TaskMarkAnalysing -Arguments @{ task_id = $taskResult.task.id } | Out-Null
                Invoke-TaskMarkAnalysed -Arguments @{
                    task_id = $taskResult.task.id
                    analysis = @{
                        summary = "Auto-promoted: task type '$taskTypeVal' skips LLM analysis"
                        auto_promoted = $true
                    }
                } | Out-Null
                $tasksProcessed++
                continue
            }
            Invoke-TaskMarkAnalysing -Arguments @{ task_id = $taskResult.task.id } | Out-Null
        }

        if (-not $taskResult.success) {
            Write-Status "Error fetching task: $($taskResult.message)" -Type Error
            break
        }

        if (-not $taskResult.task) {
            if ($Continue -and -not $NoWait) {
                $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for new tasks..."

                $foundTask = $false
                while ($true) {
                    Start-Sleep -Seconds 5
                    if (Test-ProcessStopSignal -Id $procId) { break }
                    $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                    Reset-TaskIndex
                    $taskResult = Get-NextTodoTask -Verbose
                    if ($taskResult.task) { $foundTask = $true; break }
                    if (Test-DependencyDeadlock -ProcessId $procId) { break }
                }
                if (-not $foundTask) { break }
            } else {
                Write-Status "No tasks available" -Type Info
                break
            }
        }

        $task = $taskResult.task
        $processData.task_id = $task.id
        $processData.task_name = $task.name
        $processData.heartbeat_status = "Working on: $($task.name)"
        Write-ProcessFile -Id $procId -Data $processData

        $env:DOTBOT_CURRENT_TASK_ID = $task.id
        $taskTypeForHeader = if ($task.type) { $task.type } else { 'prompt' }
        Write-TaskHeader -TaskName $task.name -TaskType $taskTypeForHeader -Model $Model -ProcessId $procId
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Started task: $($task.name)"

        # Generate new provider session ID per task
        $claudeSessionId = New-ProviderSession
        $env:CLAUDE_SESSION_ID = $claudeSessionId
        $processData.claude_session_id = $claudeSessionId
        Write-ProcessFile -Id $procId -Data $processData

        # Build analysis prompt
        $prompt = $promptTemplate
        $prompt = $prompt -replace '\{\{SESSION_ID\}\}', $sessionId
        $prompt = $prompt -replace '\{\{TASK_ID\}\}', $task.id
        $prompt = $prompt -replace '\{\{TASK_NAME\}\}', $task.name
        $prompt = $prompt -replace '\{\{TASK_CATEGORY\}\}', $task.category
        $prompt = $prompt -replace '\{\{TASK_PRIORITY\}\}', $task.priority
        $prompt = $prompt -replace '\{\{TASK_EFFORT\}\}', $task.effort
        $prompt = $prompt -replace '\{\{TASK_DESCRIPTION\}\}', $task.description
        $niValue = if ("$($task.needs_interview)" -eq 'true') { 'true' } else { 'false' }
        Write-Status "needs_interview raw=$($task.needs_interview) resolved=$niValue" -Type Info
        $prompt = $prompt -replace '\{\{NEEDS_INTERVIEW\}\}', $niValue
        $acceptanceCriteria = if ($task.acceptance_criteria) { ($task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n" } else { "No specific acceptance criteria defined." }
        $prompt = $prompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria
        $steps = if ($task.steps) { ($task.steps | ForEach-Object { "- $_" }) -join "`n" } else { "No specific steps defined." }
        $prompt = $prompt -replace '\{\{TASK_STEPS\}\}', $steps
        $splitThreshold = if ($settings.analysis.split_threshold_effort) { $settings.analysis.split_threshold_effort } else { 'XL' }
        $prompt = $prompt -replace '\{\{SPLIT_THRESHOLD_EFFORT\}\}', $splitThreshold
        $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', "main"

        # Build resolved questions context for resumed tasks
        $isResumedTask = $task.status -eq 'analysing'
        $resolvedQuestionsContext = ""
        $taskQR = if ($task.PSObject.Properties['questions_resolved']) { $task.questions_resolved } else { $null }
        if ($isResumedTask -and $taskQR) {
            $resolvedQuestionsContext = "`n## Previously Resolved Questions`n`n"
            $resolvedQuestionsContext += "This task was previously paused for human input. The following questions have been answered:`n`n"
            foreach ($q in $taskQR) {
                $resolvedQuestionsContext += "**Q:** $($q.question)`n"
                $resolvedQuestionsContext += "**A:** $($q.answer)`n`n"
            }
            $resolvedQuestionsContext += "Use these answers to guide your analysis. The task is already in ``analysing`` status - do NOT call ``task_mark_analysing`` again.`n"
        }

        $fullPrompt = @"
$prompt
$resolvedQuestionsContext
## Process Context

- **Process ID:** $procId
- **Instance Type:** analysis

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Analyse task $($task.id) completely. When analysis is finished:
- If all context is gathered: Call task_mark_analysed with the full analysis object
- If you need human input: Call task_mark_needs_input with a question or split_proposal
- If blocked by issues: Call task_mark_skipped with a reason

Do NOT implement the task. Your job is research and preparation only.
"@

        # Invoke Claude with retries
        $attemptNumber = 0
        $taskSuccess = $false

        try {
        while ($attemptNumber -le $maxRetriesPerTask) {
            $attemptNumber++

            if ($attemptNumber -gt 1) {
                Write-Status "Retry attempt $attemptNumber of $maxRetriesPerTask" -Type Warn
            }

            if (Test-ProcessStopSignal -Id $procId) {
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                break
            }

            Write-Header "Claude Session"
            try {
                $streamArgs = @{
                    Prompt = $fullPrompt
                    Model = $claudeModelName
                    SessionId = $claudeSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }
                if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }

                Invoke-ProviderStream @streamArgs
                $exitCode = 0
            } catch {
                Write-Status "Error: $($_.Exception.Message)" -Type Error
                $exitCode = 1
            }

            # Update heartbeat
            $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData

            # Check rate limit
            $rateLimitMsg = Get-LastProviderRateLimitInfo
            if ($rateLimitMsg) {
                Write-Status "Rate limit detected!" -Type Warn
                $rateLimitInfo = Get-RateLimitResetTime -Message $rateLimitMsg
                if ($rateLimitInfo) {
                    $processData.heartbeat_status = "Rate limited - waiting..."
                    Write-ProcessFile -Id $procId -Data $processData
                    Write-ProcessActivity -Id $procId -ActivityType "rate_limit" -Message $rateLimitMsg

                    $waitSeconds = $rateLimitInfo.wait_seconds
                    if (-not $waitSeconds -or $waitSeconds -lt 30) { $waitSeconds = 60 }
                    for ($w = 0; $w -lt $waitSeconds; $w++) {
                        Start-Sleep -Seconds 1
                        if (Test-ProcessStopSignal -Id $procId) { break }
                    }

                    $attemptNumber--
                    continue
                }
            }

            # Check if task moved to analysed/needs-input/skipped
            $taskDirs = @('analysed', 'needs-input', 'skipped', 'in-progress', 'done')
            $taskFound = $false
            foreach ($dir in $taskDirs) {
                $checkDir = Join-Path $botRoot "workspace\tasks\$dir"
                if (Test-Path $checkDir) {
                    $files = Get-ChildItem -Path $checkDir -Filter "*.json" -File
                    foreach ($f in $files) {
                        try {
                            $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                            if ($content.id -eq $task.id) {
                                $taskFound = $true
                                $taskSuccess = $true
                                Write-Status "Analysis complete (status: $dir)" -Type Complete
                                break
                            }
                        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
                    }
                    if ($taskFound) { break }
                }
            }
            if ($taskSuccess) { break }

            if ($attemptNumber -ge $maxRetriesPerTask) {
                Write-Status "Max retries exhausted" -Type Error
                break
            }
        }
        } finally { }

        # Update process data
        $env:DOTBOT_CURRENT_TASK_ID = $null
        $env:CLAUDE_SESSION_ID = $null

        if ($taskSuccess) {
            $tasksProcessed++
            $processData.tasks_completed = $tasksProcessed
            $processData.heartbeat_status = "Completed: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed: $($task.name)"

            try { Remove-ProviderSession -SessionId $claudeSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }
        } else {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"
        }

        # Continue to next task?
        if (-not $Continue) { break }

        $TaskId = $null
        $processData.task_id = $null
        $processData.task_name = $null

        # Delay between tasks
        Write-Status "Waiting 3s before next task..." -Type Info
        for ($i = 0; $i -lt 3; $i++) {
            Start-Sleep -Seconds 1
            if (Test-ProcessStopSignal -Id $procId) { break }
        }

        if (Test-ProcessStopSignal -Id $procId) {
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            break
        }
    }
} finally {
    if ($processData.status -eq 'running') {
        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status))"
}
