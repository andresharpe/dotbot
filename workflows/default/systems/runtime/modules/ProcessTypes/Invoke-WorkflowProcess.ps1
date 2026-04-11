<#
.SYNOPSIS
    Workflow (task-runner) process type: unified analyse-then-execute per task.
.DESCRIPTION
    Runs a continuous loop that analyses and then executes each task in sequence.
    Supports concurrent slots, slot stagger/claim guards, and non-prompt task dispatch.
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
$controlDir = $Context.ControlDir
$settings = $Context.Settings
$Model = $Context.Model
$instanceId = $Context.InstanceId
$Continue = $Context.Continue
$NoWait = $Context.NoWait
$MaxTasks = $Context.MaxTasks
$TaskId = $Context.TaskId
$Slot = $Context.Slot
$Workflow = $Context.Workflow
$permissionMode = $Context.PermissionMode

# Initialize session for execution phase tracking
$sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if ($sessionResult.success) {
    $sessionId = $sessionResult.session.session_id
}
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Workflow child started (session: $sessionId, PID: $PID)"

# Load both prompt templates
$analysisTemplateFile = Join-Path $botRoot "recipes\prompts\98-analyse-task.md"
$executionTemplateFile = Join-Path $botRoot "recipes\prompts\99-autonomous-task.md"
$analysisPromptTemplate = Get-Content $analysisTemplateFile -Raw
$executionPromptTemplate = Get-Content $executionTemplateFile -Raw

$processData.workflow = "workflow (analyse + execute)"

# Standards and product context (for execution phase)
$standardsList = ""
$productMission = ""
$entityModel = ""
$standardsDir = Join-Path $botRoot "recipes\standards\global"
if (Test-Path $standardsDir) {
    $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
        ForEach-Object { ".bot/recipes/standards/global/$($_.Name)" }
    $standardsList = if ($standardsFiles) { "- " + ($standardsFiles -join "`n- ") } else { "No standards files found." }
}
$productDir = Join-Path $botRoot "workspace\product"
$productMission = if (Test-Path (Join-Path $productDir "mission.md")) { "Read the product mission and context from: .bot/workspace/product/mission.md" } else { "No product mission file found." }
$entityModel = if (Test-Path (Join-Path $productDir "entity-model.md")) { "Read the entity model design from: .bot/workspace/product/entity-model.md" } else { "No entity model file found." }

# Task reset
. (Join-Path $botRoot "systems\runtime\modules\task-reset.ps1")
$tasksBaseDir = Join-Path $botRoot "workspace\tasks"

# Recover orphaned tasks
Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $processesDir | Out-Null
Reset-InProgressTasks -TasksBaseDir $tasksBaseDir | Out-Null
Reset-SkippedTasks -TasksBaseDir $tasksBaseDir | Out-Null

# Clean up orphan worktrees
Remove-OrphanWorktrees -ProjectRoot $projectRoot -BotRoot $botRoot

# Initialize task index
Initialize-TaskIndex -TasksBaseDir $tasksBaseDir

# Log task index state for diagnostics
$initIndex = Get-TaskIndex
$todoCount = if ($initIndex.Todo) { $initIndex.Todo.Count } else { 0 }
$analysedCount = if ($initIndex.Analysed) { $initIndex.Analysed.Count } else { 0 }
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task index loaded: $todoCount todo, $analysedCount analysed"

# Pre-flight: warn if main repo has uncommitted non-.bot/ files.
# These don't block execution (verification runs in the worktree) but can
# complicate the squash-merge stash/pop if left unresolved.
try {
    $mainDirtyStatus = git -C $projectRoot status --porcelain 2>$null
    $mainDirtyFiles  = @($mainDirtyStatus | Where-Object { $_ -notmatch '\.bot/' })
    if ($mainDirtyFiles.Count -gt 0) {
        $fileList = ($mainDirtyFiles | ForEach-Object { $_.Substring(3).Trim() }) -join ', '
        Write-Status "Pre-flight: Main repo has $($mainDirtyFiles.Count) uncommitted non-.bot/ file(s). Commit them to avoid squash-merge complications: $fileList" -Type Warn
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pre-flight warning: Main repo has $($mainDirtyFiles.Count) uncommitted file(s) outside .bot/ ($fileList). Consider committing before workflow."
    }
} catch { Write-BotLog -Level Debug -Message "Git operation failed" -Exception $_ }

$tasksProcessed = 0
$maxRetriesPerTask = 2
$consecutiveFailureThreshold = 3

# Ensure repo has at least one commit (required for worktrees)
$hasCommits = git -C $projectRoot rev-parse --verify HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Status "Creating initial commit (required for worktrees)..." -Type Process
    git -C $projectRoot add .bot/ 2>$null
    git -C $projectRoot commit -m "chore: initialize dotbot" --allow-empty 2>$null
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Created initial git commit (repo had no commits)"
}

# Update process status to running
$processData.status = 'running'
Write-ProcessFile -Id $procId -Data $processData

$loopIteration = 0
try {
    while ($true) {
        $loopIteration++
        Write-Diag "--- Loop iteration $loopIteration ---"

        # Check max tasks
        Write-Diag "MaxTasks check: tasksProcessed=$tasksProcessed, MaxTasks=$MaxTasks"
        if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
            Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
            Write-Diag "EXIT: MaxTasks reached"
            break
        }

        # Check stop signal
        if (Test-ProcessStopSignal -Id $procId) {
            Write-Status "Stop signal received" -Type Error
            Write-Diag "EXIT: Stop signal received"
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process stopped by user"
            break
        }

        # ===== Pick next task =====
        # Stagger task pulls: each slot waits a random prime-number of seconds.
        # Primes (5,7,11,13) minimize collision probability between slots.
        if ($Slot -gt 0) {
            $staggerOptions = @(5, 7, 11, 13)
            $staggerSec = $staggerOptions | Get-Random
            Write-Status "Slot ${Slot}: stagger wait ${staggerSec}s..." -Type Info
            for ($sw = 0; $sw -lt $staggerSec; $sw++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
        }

        Write-Status "Fetching next task..." -Type Process
        Reset-TaskIndex

        # Check resumed tasks, analysed tasks, then todo
        $taskResult = Get-NextWorkflowTask -Verbose -WorkflowFilter $Workflow

        Write-Diag "TaskPickup: success=$($taskResult.success) hasTask=$($null -ne $taskResult.task) msg=$($taskResult.message)"

        if (-not $taskResult.success) {
            Write-Status "Error fetching task: $($taskResult.message)" -Type Error
            Write-Diag "EXIT: Error fetching task: $($taskResult.message)"
            break
        }

        if (-not $taskResult.task) {
            if ($Continue -and -not $NoWait) {
                $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                Write-Diag "Entering wait loop (Continue=$Continue, NoWait=$NoWait): $waitReason"
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for new tasks..."

                $foundTask = $false
                while ($true) {
                    Start-Sleep -Seconds 5
                    if (Test-ProcessStopSignal -Id $procId) { break }
                    $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                    Reset-TaskIndex
                    $taskResult = Get-NextWorkflowTask -Verbose -WorkflowFilter $Workflow
                    if ($taskResult.task) { $foundTask = $true; break }

                    if (Test-DependencyDeadlock -ProcessId $procId) { break }
                }
                if (-not $foundTask) {
                    Write-Diag "EXIT: No task found after wait loop (foundTask=$foundTask)"
                    break
                }
            } else {
                Write-Status "No tasks available" -Type Info
                Write-Diag "EXIT: No tasks and Continue not set"
                break
            }
        }

        $task = $taskResult.task

        # --- Non-prompt task slot guard (before claim) ---
        # Script/mcp/task_gen tasks must only run on slot 0.
        # Check BEFORE claiming to avoid orphaning tasks in in-progress.
        $taskTypeCheck = if ($task.type) { $task.type } else { 'prompt' }
        if ($taskTypeCheck -eq 'prompt_template') { $taskTypeCheck = 'prompt' }
        if ($Slot -gt 0 -and $taskTypeCheck -notin @('prompt')) {
            Write-Status "Slot ${Slot}: skipping $taskTypeCheck task '$($task.name)' (slot 0 only)" -Type Info
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Slot ${Slot}: waiting for prompt tasks (skipping $taskTypeCheck task)"
            Start-Sleep -Seconds 5
            continue
        }

        # --- Multi-slot claim guard ---
        # When running with -Slot (concurrent workflow processes), another slot may
        # have claimed this task between our Get-NextWorkflowTask and this point.
        # Only needed for prompt tasks — non-prompt tasks are guarded by the slot 0 check above.
        if ($Slot -ge 0 -and $taskTypeCheck -eq 'prompt') {
            $claimOk = $false
            for ($claimAttempt = 0; $claimAttempt -lt 5; $claimAttempt++) {
                try {
                    $claimStatus = if ($task.status -eq 'analysed') { 'in-progress' } else { 'analysing' }
                    $claimResult = $null
                    if ($claimStatus -eq 'in-progress' -and $task.status -ne 'in-progress') {
                        $claimResult = Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id }
                    } elseif ($claimStatus -eq 'analysing' -and $task.status -notin @('analysing', 'analysed')) {
                        $claimResult = Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id }
                    }
                    # Detect if another slot already claimed this task
                    if ($claimResult -and $claimResult.already_completed) {
                        throw "Task already completed"
                    }
                    if ($claimResult -and -not $claimResult.old_status) {
                        # No old_status means task was already in the target state (claimed by another slot)
                        throw "Task already claimed"
                    }
                    $claimOk = $true
                    break
                } catch {
                    Write-Diag "Slot ${Slot}: task $($task.id) claimed by another slot, retrying..."
                    Start-Sleep -Milliseconds 200
                    Reset-TaskIndex
                    $taskResult = Get-NextWorkflowTask -Verbose -WorkflowFilter $Workflow
                    if (-not $taskResult.task) { break }
                    $task = $taskResult.task
                }
            }
            if (-not $claimOk) {
                Write-Status "Slot ${Slot}: could not claim a task after $($claimAttempt + 1) attempts" -Type Warn
                if ($Continue) { continue } else { break }
            }
        }

        $processData.task_id = $task.id
        $processData.task_name = $task.name
        $env:DOTBOT_CURRENT_TASK_ID = $task.id
        $taskTypeForHeader = if ($task.type) { $task.type } else { 'prompt' }
        Write-TaskHeader -TaskName $task.name -TaskType $taskTypeForHeader -Model $Model -ProcessId $procId
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Processing task: $($task.name) (id: $($task.id), status: $($task.status))"
        Write-Diag "Selected task: id=$($task.id) name=$($task.name) status=$($task.status)"

        # Skip analysis for already-analysed tasks — jump straight to execution
        if ($task.status -eq 'analysed') {
            Write-Status "Task already analysed — skipping to execution phase" -Type Info
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task already analysed, proceeding to execution: $($task.name)"
            # Jump to Phase 2 (execution) below — the analysis block is wrapped in a conditional
        }

        try {   # Per-task try/catch — catches failures in BOTH analysis and execution phases

        # --- Task type dispatch (script / mcp / task_gen bypass Claude entirely) ---
        $taskTypeVal = if ($task.type) { $task.type } else { 'prompt' }
        # prompt_template uses Claude but with a workflow-specific prompt file
        # — falls through to the normal analysis+execution path below
        if ($taskTypeVal -eq 'prompt_template' -and $task.prompt) {
            # Resolve prompt template from workflow dir or .bot/
            $promptBase = $botRoot
            if ($task.workflow) {
                $wfPromptBase = Join-Path $botRoot "workflows\$($task.workflow)"
                if (Test-Path $wfPromptBase) { $promptBase = $wfPromptBase }
            }
            $templatePath = Join-Path $promptBase $task.prompt
            if (Test-Path $templatePath) {
                # Override the execution prompt template for this task
                $executionPromptTemplate = Get-Content $templatePath -Raw
                Write-Status "Using workflow prompt: $($task.prompt)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Prompt template: $($task.prompt)"
            }
            # Fall through to normal analysis+execution below (treated as 'prompt')
            $taskTypeVal = 'prompt'
        }
        if ($taskTypeVal -notin @('prompt')) {
            Write-Status "Auto-dispatching $taskTypeVal task: $($task.name)" -Type Process
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-dispatch $taskTypeVal task: $($task.name)"

            # Mark in-progress
            if ($task.status -ne 'in-progress') {
                Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
            }

            $typeSuccess = $false
            $typeError = $null
            # Resolve script base: workflow dir or .bot/
            $scriptBase = $botRoot
            if ($task.workflow) {
                $wfScriptBase = Join-Path $botRoot "workflows\$($task.workflow)"
                if (Test-Path $wfScriptBase) { $scriptBase = $wfScriptBase }
            }

            # Pre-flight: verify script exists before attempting execution
            if ($taskTypeVal -in @('script', 'task_gen') -and $task.script_path) {
                $resolvedScript = Join-Path $scriptBase $task.script_path
                if (-not (Test-Path $resolvedScript)) {
                    $typeError = "Script not found: $($task.script_path) (base: $scriptBase)"
                    Write-Status $typeError -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
                    try {
                        Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = $typeError } | Out-Null
                    } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
                    $TaskId = $null; $processData.task_id = $null; $processData.task_name = $null
                    Start-Sleep -Seconds 3
                    continue
                }
            }

            try {
                switch ($taskTypeVal) {
                    'script' {
                        $resolvedScript = Join-Path $scriptBase $task.script_path
                        Write-Status "Running script: $($task.script_path)" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing script: $($task.script_path)"
                        & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                        $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                    }
                    'mcp' {
                        $toolFuncParts = $task.mcp_tool -split '_'
                        $capitalParts = foreach ($p in $toolFuncParts) { $p.Substring(0,1).ToUpper() + $p.Substring(1) }
                        $toolFunc = 'Invoke-' + ($capitalParts -join '')
                        $toolArgs = if ($task.mcp_args) { $task.mcp_args } else { @{} }
                        Write-Status "Calling MCP tool: $($task.mcp_tool)" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing MCP tool: $($task.mcp_tool)"
                        $mcpResult = & $toolFunc -Arguments $toolArgs
                        $typeSuccess = $true
                    }
                    'task_gen' {
                        $resolvedScript = Join-Path $scriptBase $task.script_path
                        Write-Status "Running task generator: $($task.script_path)" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Generating tasks: $($task.script_path)"
                        & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                        $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                        # Reset task index so newly created tasks are discovered
                        Reset-TaskIndex
                    }
                    'barrier' {
                        Write-Status "Barrier: $($task.name) — synchronization point" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Barrier reached: $($task.name)"
                        $typeSuccess = $true
                    }
                }
            } catch {
                $typeError = $_.Exception.Message
                Write-Status "Task type execution failed: $typeError" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
            }

            if ($typeSuccess) {
                # Move task file directly to done/ (skip verification hooks —
                # they are for Claude-executed code tasks, not script/mcp/task_gen)
                try {
                    $doneDir = Join-Path $botRoot "workspace\tasks\done"
                    if (-not (Test-Path $doneDir)) { New-Item -Path $doneDir -ItemType Directory -Force | Out-Null }
                    $taskFile = Get-ChildItem (Join-Path $botRoot "workspace\tasks\in-progress") -Filter "*.json" -File |
                        Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $task.id } |
                        Select-Object -First 1
                    if ($taskFile) {
                        $content = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                        $content.status = 'done'
                        $content.completed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                        $content.updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                        $content | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $doneDir $taskFile.Name) -Encoding UTF8
                        Remove-Item $taskFile.FullName -Force
                    }
                } catch {
                    Write-Status "Failed to mark done: $($_.Exception.Message)" -Type Warn
                }
                Write-Status "Task completed: $($task.name)" -Type Complete
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completed $taskTypeVal task: $($task.name)"
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $tasksProcessed++
            } else {
                Write-Status "Task failed: $($task.name)" -Type Error
                try {
                    Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "$taskTypeVal execution failed: $typeError" } | Out-Null
                } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }
            }

            # Continue to next task (skip analysis + execution phases)
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
            continue
        }

        # ===== PHASE 1: Analysis (skipped if task already analysed) =====
        if ($task.status -ne 'analysed') {

        # Auto-promote prompt tasks that skip analysis (e.g. scoring tasks)
        # Mirrors the standalone analysis process behavior (line ~910)
        if ($task.skip_analysis -eq $true) {
            Write-Status "Auto-promoting task (skip_analysis): $($task.name)" -Type Info
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-promoted $($task.name) (skip_analysis=true)"
            if ($task.status -ne 'analysing') {
                Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id } | Out-Null
            }
            Invoke-TaskMarkAnalysed -Arguments @{
                task_id = $task.id
                analysis = @{
                    summary = "Auto-promoted: task has skip_analysis=true"
                    auto_promoted = $true
                }
            } | Out-Null
            # Fall through to execution phase
        } else {

        Write-Diag "Entering analysis phase for task $($task.id)"
        $env:DOTBOT_CURRENT_PHASE = 'analysis'
        $processData.heartbeat_status = "Analysing: $($task.name)"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analysis phase started: $($task.name)"

        # Claim task for analysis (unless already analysing from resumed question)
        if ($task.status -ne 'analysing') {
            Invoke-TaskMarkAnalysing -Arguments @{ task_id = $task.id } | Out-Null
        }

        # Build analysis prompt
        $analysisPrompt = $analysisPromptTemplate
        $analysisPrompt = $analysisPrompt -replace '\{\{SESSION_ID\}\}', $sessionId
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_ID\}\}', $task.id
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_NAME\}\}', $task.name
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_CATEGORY\}\}', $task.category
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_PRIORITY\}\}', $task.priority
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_EFFORT\}\}', $task.effort
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_DESCRIPTION\}\}', $task.description
        $niValue = if ("$($task.needs_interview)" -eq 'true') { 'true' } else { 'false' }
        $analysisPrompt = $analysisPrompt -replace '\{\{NEEDS_INTERVIEW\}\}', $niValue
        $acceptanceCriteria = if ($task.acceptance_criteria) { ($task.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n" } else { "No specific acceptance criteria defined." }
        $analysisPrompt = $analysisPrompt -replace '\{\{ACCEPTANCE_CRITERIA\}\}', $acceptanceCriteria
        $steps = if ($task.steps) { ($task.steps | ForEach-Object { "- $_" }) -join "`n" } else { "No specific steps defined." }
        $analysisPrompt = $analysisPrompt -replace '\{\{TASK_STEPS\}\}', $steps
        $splitThreshold = if ($settings.analysis.split_threshold_effort) { $settings.analysis.split_threshold_effort } else { 'XL' }
        $analysisPrompt = $analysisPrompt -replace '\{\{SPLIT_THRESHOLD_EFFORT\}\}', $splitThreshold
        $analysisPrompt = $analysisPrompt -replace '\{\{BRANCH_NAME\}\}', 'main'

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

        # Use task-level model override
        $analysisModel = if ($task.model) { $task.model }
            elseif ($settings.analysis?.model) { $settings.analysis.model }
            else { 'Opus' }
        $analysisModelName = Resolve-ProviderModelId -ModelAlias $analysisModel

        $fullAnalysisPrompt = @"
$analysisPrompt
$resolvedQuestionsContext
## Process Context

- **Process ID:** $procId
- **Instance Type:** workflow (analysis phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Analyse task $($task.id) completely. When analysis is finished:
- If all context is gathered: Call task_mark_analysed with the full analysis object
- If you need human input: Call task_mark_needs_input with a question or split_proposal
- If blocked by issues: Call task_mark_skipped with a reason

Do NOT implement the task. Your job is research and preparation only.
"@

        # Invoke provider for analysis
        $analysisSessionId = New-ProviderSession
        $env:CLAUDE_SESSION_ID = $analysisSessionId
        $processData.claude_session_id = $analysisSessionId
        Write-ProcessFile -Id $procId -Data $processData

        $analysisSuccess = $false
        $analysisAttempt = 0

        while ($analysisAttempt -le $maxRetriesPerTask) {
            $analysisAttempt++
            if (Test-ProcessStopSignal -Id $procId) { break }

            Write-Header "Analysis Phase"
            try {
                $streamArgs = @{
                    Prompt = $fullAnalysisPrompt
                    Model = $analysisModelName
                    SessionId = $analysisSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }
                Invoke-ProviderStream @streamArgs
                $exitCode = 0
            } catch {
                Write-Status "Analysis error: $($_.Exception.Message)" -Type Error
                $exitCode = 1
            }

            # Update heartbeat
            $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData

            # Handle rate limit
            $rateLimitMsg = Get-LastProviderRateLimitInfo
            if ($rateLimitMsg) {
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
                    $analysisAttempt--
                    continue
                }
            }

            # Check if analysis completed (task moved to analysed/needs-input/skipped)
            $taskDirs = @('analysed', 'needs-input', 'skipped', 'in-progress', 'done')
            $taskFound = $false
            $analysisOutcome = $null
            foreach ($dir in $taskDirs) {
                $checkDir = Join-Path $botRoot "workspace\tasks\$dir"
                if (Test-Path $checkDir) {
                    $files = Get-ChildItem -Path $checkDir -Filter "*.json" -File
                    foreach ($f in $files) {
                        try {
                            $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                            if ($content.id -eq $task.id) {
                                $taskFound = $true
                                $analysisSuccess = $true
                                $analysisOutcome = $dir
                                Write-Status "Analysis complete (status: $dir)" -Type Complete
                                break
                            }
                        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
                    }
                    if ($taskFound) { break }
                }
            }
            if ($analysisSuccess) { break }

            if ($analysisAttempt -ge $maxRetriesPerTask) {
                Write-Status "Analysis max retries exhausted" -Type Error
                break
            }
        }

        # Clean up analysis session
        try { Remove-ProviderSession -SessionId $analysisSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }

        Write-Diag "Analysis outcome: success=$analysisSuccess outcome=$analysisOutcome"

        if (-not $analysisSuccess) {
            Write-Diag "Analysis FAILED for task $($task.id)"
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analysis failed: $($task.name)"
            # Skip to next task
            if (-not $Continue) { break }
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
            continue
        }

        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Analysis complete: $($task.name) -> $analysisOutcome"

        # If analysis resulted in needs-input or skipped, don't proceed to execution
        # Note: 'done' and 'in-progress' are valid outcomes (task completed during analysis)
        if ($analysisOutcome -notin @('analysed', 'done', 'in-progress')) {
            Write-Diag "Task not ready for execution: outcome=$analysisOutcome"
            Write-Status "Task not ready for execution (status: $analysisOutcome) - moving to next task" -Type Info
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) needs input or was skipped - moving on"
            if (-not $Continue) { break }
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
            continue
        }

        # If task already completed during analysis (e.g. scoring tasks that called
        # task_mark_done from the analysis phase), skip execution and count as done
        if ($analysisOutcome -in @('done', 'in-progress')) {
            Write-Diag "Task completed during analysis (outcome=$analysisOutcome) — skipping execution"
            Write-Status "Task completed during analysis" -Type Complete
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) completed during analysis (status: $analysisOutcome)"
            Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
            $tasksProcessed++
            $processData.tasks_completed = $tasksProcessed
            $processData.heartbeat_status = "Completed: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            try { Remove-ProviderSession -SessionId $analysisSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
            continue
        }
        } # end: else (full LLM analysis)
        } # end: if ($task.status -ne 'analysed') — analysis phase

        # ===== PHASE 2: Execution =====
        Write-Diag "Entering execution phase for task $($task.id)"
        $env:DOTBOT_CURRENT_PHASE = 'execution'
        $processData.heartbeat_status = "Executing: $($task.name)"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution phase started: $($task.name)"

        try {

        # Re-read task data (analysis may have enriched it)
        Reset-TaskIndex
        $freshTask = Invoke-TaskGetNext -Arguments @{ prefer_analysed = $true; verbose = $true }
        Write-Diag "Execution TaskGetNext: hasTask=$($null -ne $freshTask.task) matchesId=$($freshTask.task.id -eq $task.id)"
        if ($freshTask.task -and $freshTask.task.id -eq $task.id) {
            $task = $freshTask.task
        }

        # Mark in-progress
        Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
        Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

        # Worktree setup — skip for research tasks, tasks with external repos, and tasks with skip_worktree flag
        $skipWorktree = ($task.category -eq 'research') -or $task.working_dir -or $task.external_repo -or ($task.skip_worktree -eq $true)
        Write-Diag "Worktree: skip=$skipWorktree category=$($task.category) skip_worktree=$($task.skip_worktree)"
        $worktreePath = $null
        $branchName = $null

        if ($skipWorktree) {
            Write-Status "Skipping worktree (category: $($task.category))" -Type Info
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Skipping worktree for task: $($task.name) (research/external repo task)"
        } else {
            $wtInfo = Get-TaskWorktreeInfo -TaskId $task.id -BotRoot $botRoot
            if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
                $worktreePath = $wtInfo.worktree_path
                $branchName = $wtInfo.branch_name
                Write-Status "Using worktree: $worktreePath" -Type Info
            } else {
                # Guard: ensure main repo is on base branch before creating a new worktree (Fix: wrong-branch merge)
                try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch {
                    Write-Status "Branch guard warning: $($_.Exception.Message)" -Type Warn
                }
                $wtResult = New-TaskWorktree -TaskId $task.id -TaskName $task.name `
                    -ProjectRoot $projectRoot -BotRoot $botRoot
                if ($wtResult.success) {
                    $worktreePath = $wtResult.worktree_path
                    $branchName = $wtResult.branch_name
                    Write-Status "Worktree: $worktreePath" -Type Info
                } else {
                    Write-Status "Worktree failed: $($wtResult.message)" -Type Warn
                }
            }
        }

        # Use task-level model override > execution model from settings > default
        $executionModel = if ($task.model) { $task.model }
            elseif ($settings.execution?.model) { $settings.execution.model }
            else { 'Opus' }
        $executionModelName = Resolve-ProviderModelId -ModelAlias $executionModel

        # Build execution prompt
        $executionPrompt = Build-TaskPrompt `
            -PromptTemplate $executionPromptTemplate `
            -Task $task `
            -SessionId $sessionId `
            -ProductMission $productMission `
            -EntityModel $entityModel `
            -StandardsList $standardsList `
            -InstanceId $instanceId

        $branchForPrompt = if ($branchName) { $branchName } else { "main" }
        $executionPrompt = $executionPrompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

        $fullExecutionPrompt = @"
$executionPrompt

## Process Context

- **Process ID:** $procId
- **Instance Type:** workflow (execution phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call task_mark_done via MCP.
"@

        # Invoke provider for execution
        $executionSessionId = New-ProviderSession
        $env:CLAUDE_SESSION_ID = $executionSessionId
        $processData.claude_session_id = $executionSessionId
        Write-ProcessFile -Id $procId -Data $processData

        $taskSuccess = $false
        $attemptNumber = 0

        if ($worktreePath) { Push-Location $worktreePath }
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

            Write-Header "Execution Phase"
            try {
                $streamArgs = @{
                    Prompt = $fullExecutionPrompt
                    Model = $executionModelName
                    SessionId = $executionSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }
                Invoke-ProviderStream @streamArgs
                $exitCode = 0
            } catch {
                Write-Status "Execution error: $($_.Exception.Message)" -Type Error
                $exitCode = 1
            }

            # Kill any background processes Claude may have spawned in the worktree
            # (e.g., dev servers started with pnpm dev &, npx next start &)
            if ($worktreePath) {
                $cleanedUp = Stop-WorktreeProcesses -WorktreePath $worktreePath
                if ($cleanedUp -gt 0) {
                    Write-Diag "Cleaned up $cleanedUp orphan process(es) after execution attempt"
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Cleaned up $cleanedUp background process(es) from worktree"
                }
            }

            # Update heartbeat
            $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData

            # Handle rate limit
            $rateLimitMsg = Get-LastProviderRateLimitInfo
            if ($rateLimitMsg) {
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

            # Check completion
            $completionCheck = Test-TaskCompletion -TaskId $task.id
            Write-Diag "Completion check: completed=$($completionCheck.completed)"
            if ($completionCheck.completed) {
                Write-Status "Task completed!" -Type Complete
                Write-Information "task_state_change: $($task.id) -> done [execution]" -Tags @('dotbot', 'task', 'state')
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $taskSuccess = $true
                break
            }

            # Task not completed - log diagnostic to help distinguish failure modes:
            # (a) task_mark_done was called but verification blocked it  → task still in in-progress/
            # (b) task_mark_done was never called (agent forgot)          → task not in any terminal dir
            $inProgressDir = Join-Path $tasksBaseDir "in-progress"
            $stillInProgress = $false
            try {
                $stillInProgress = $null -ne (
                    Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                    Where-Object {
                        try { (Get-Content $_.FullName -Raw | ConvertFrom-Json).id -eq $task.id } catch { $false }
                    } | Select-Object -First 1
                )
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }

            if ($stillInProgress) {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' still in in-progress/. Check activity log: if a 'task_mark_done blocked' entry exists, verification failed; otherwise task_mark_done was likely never called."
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' not found in in-progress/ or done/ (unexpected state)."
            }

            # Task not completed - handle failure
            $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout "" -Stderr "" -TimedOut $false
            if (-not $failureReason.recoverable) {
                Write-Status "Non-recoverable failure - skipping" -Type Error
                try {
                    Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "non-recoverable" } | Out-Null
                } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                break
            }

            if ($attemptNumber -ge $maxRetriesPerTask) {
                Write-Status "Max retries exhausted" -Type Error
                try {
                    Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "max-retries" } | Out-Null
                } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                break
            }
        }
        } finally {
            # Final safety-net cleanup: kill any remaining worktree processes
            if ($worktreePath) {
                Stop-WorktreeProcesses -WorktreePath $worktreePath | Out-Null
                Pop-Location
            }
        }

        # Clean up execution session
        try { Remove-ProviderSession -SessionId $executionSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process" -Exception $_ }

        } catch {
            # Execution phase setup/run failed — log and recover the task
            Write-Diag "Execution EXCEPTION: $($_.Exception.Message)"
            Write-Status "Execution failed: $($_.Exception.Message)" -Type Error
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution failed for $($task.name): $($_.Exception.Message)"
            try {
                $inProgressDir = Join-Path $tasksBaseDir "in-progress"
                $todoDir = Join-Path $tasksBaseDir "todo"
                $taskFile = Get-ChildItem -Path $inProgressDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match $task.id.Substring(0,8) } | Select-Object -First 1
                if ($taskFile) {
                    $taskData = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                    $taskData.status = 'todo'
                    $taskData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $todoDir $taskFile.Name) -Encoding UTF8
                    Remove-Item $taskFile.FullName -Force
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Recovered task $($task.name) back to todo"
                }
            } catch { Write-BotLog -Level Warn -Message "Failed to recover task" -Exception $_ }
            $taskSuccess = $false
        }

        # Update process data
        $env:DOTBOT_CURRENT_TASK_ID = $null
        $env:CLAUDE_SESSION_ID = $null

        Write-Diag "Task result: success=$taskSuccess"

        if ($taskSuccess) {
            # Squash-merge task branch to main
            if ($worktreePath) {
                Write-Status "Merging task branch to main..." -Type Process
                $mergeResult = Complete-TaskWorktree -TaskId $task.id -ProjectRoot $projectRoot -BotRoot $botRoot
                if ($mergeResult.success) {
                    Write-Status "Merged: $($mergeResult.message)" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Squash-merged to main: $($task.name)"
                    if ($mergeResult.push_result.attempted) {
                        if ($mergeResult.push_result.success) {
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pushed to remote: $($task.name)"
                        } else {
                            Write-Status "Push failed: $($mergeResult.push_result.error)" -Type Warn
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Push failed after merge: $($mergeResult.push_result.error)"
                        }
                    }
                } else {
                    Write-Status "Merge failed: $($mergeResult.message)" -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Merge failed for $($task.name): $($mergeResult.message)"

                    # Escalate: move task from done/ to needs-input/ with conflict info
                    $doneDir = Join-Path $tasksBaseDir "done"
                    $needsInputDir = Join-Path $tasksBaseDir "needs-input"
                    $taskFile = Get-ChildItem -Path $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Where-Object {
                        try {
                            $c = Get-Content $_.FullName -Raw | ConvertFrom-Json
                            $c.id -eq $task.id
                        } catch { $false }
                    } | Select-Object -First 1

                    if ($taskFile) {
                        $taskContent = Get-Content $taskFile.FullName -Raw | ConvertFrom-Json
                        $taskContent.status = 'needs-input'
                        $taskContent.updated_at = (Get-Date).ToUniversalTime().ToString("o")

                        if (-not $taskContent.PSObject.Properties['pending_question']) {
                            $taskContent | Add-Member -NotePropertyName 'pending_question' -NotePropertyValue $null -Force
                        }
                        $taskContent.pending_question = @{
                            id             = "merge-conflict"
                            question       = "Merge conflict during squash-merge to main"
                            context        = "Conflict details: $($mergeResult.conflict_files -join '; '). Worktree preserved at: $worktreePath"
                            options        = @(
                                @{ key = "A"; label = "Resolve manually and retry (recommended)"; rationale = "Inspect the worktree, resolve conflicts, then retry merge" }
                                @{ key = "B"; label = "Discard task changes"; rationale = "Remove worktree and abandon this task's changes" }
                                @{ key = "C"; label = "Retry with fresh rebase"; rationale = "Reset and attempt rebase again" }
                            )
                            recommendation = "A"
                            asked_at       = (Get-Date).ToUniversalTime().ToString("o")
                        }

                        if (-not (Test-Path $needsInputDir)) {
                            New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
                        }
                        $newPath = Join-Path $needsInputDir $taskFile.Name
                        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newPath -Encoding UTF8
                        Remove-Item -Path $taskFile.FullName -Force -ErrorAction SilentlyContinue

                        Write-Status "Task moved to needs-input for manual conflict resolution" -Type Warn
                    }
                }
            }

            $tasksProcessed++
            Write-Diag "Tasks processed: $tasksProcessed"
            $processData.tasks_completed = $tasksProcessed
            $processData.heartbeat_status = "Completed: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed (analyse+execute): $($task.name)"
        } else {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"

            # Clean up worktree for failed/skipped tasks
            if ($worktreePath) {
                Write-Status "Cleaning up worktree for failed task..." -Type Info
                try {
                    Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                    git -C $projectRoot worktree remove $worktreePath --force 2>$null
                    git -C $projectRoot branch -D $branchName 2>$null
                } finally {
                    # Map removal always runs even if junction/worktree cleanup throws (Fix: inconsistent registry)
                    Initialize-WorktreeMap -BotRoot $botRoot
                    Invoke-WorktreeMapLocked -Action {
                        $cleanupMap = Read-WorktreeMap
                        $cleanupMap.Remove($task.id)
                        Write-WorktreeMap -Map $cleanupMap
                    }
                    # Re-assert base branch after failed-task cleanup (Fix: wrong-branch merge)
                    try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                }
            }

            # Update session failure counters
            try {
                $state = Invoke-SessionGetState -Arguments @{}
                $newFailures = $state.state.consecutive_failures + 1
                Invoke-SessionUpdate -Arguments @{
                    consecutive_failures = $newFailures
                    tasks_skipped = $state.state.tasks_skipped + 1
                } | Out-Null

                Write-Diag "Consecutive failures: $newFailures (threshold=$consecutiveFailureThreshold)"
                if ($newFailures -ge $consecutiveFailureThreshold) {
                    Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                    Write-Diag "EXIT: Consecutive failure threshold reached"
                    break
                }
            } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        }

        } catch {
            # Per-task error recovery — catches anything that escapes the inner try/catches
            Write-Diag "Per-task EXCEPTION: $($_.Exception.Message)"
            Write-Status "Task failed unexpectedly: $($_.Exception.Message)" -Type Error
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) failed: $($_.Exception.Message)"

            # Recover task: move from whatever state back to todo
            try {
                foreach ($searchDir in @('analysing', 'in-progress')) {
                    $dir = Join-Path $tasksBaseDir $searchDir
                    $found = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match $task.id.Substring(0,8) } | Select-Object -First 1
                    if ($found) {
                        $taskData = Get-Content $found.FullName -Raw | ConvertFrom-Json
                        $taskData.status = 'todo'
                        $todoDir = Join-Path $tasksBaseDir "todo"
                        $taskData | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $todoDir $found.Name) -Encoding UTF8
                        Remove-Item $found.FullName -Force
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Recovered task $($task.name) back to todo"
                        break
                    }
                }
            } catch { Write-BotLog -Level Warn -Message "Failed to recover task" -Exception $_ }
        }

        # Continue to next task?
        Write-Diag "Continue check: Continue=$Continue"
        if (-not $Continue) {
            Write-Diag "EXIT: Continue not set"
            break
        }

        # Clear task ID for next iteration
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
            Write-Diag "EXIT: Stop signal after task completion"
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            break
        }
    }
} catch {
    # Process-level error handler — catches anything that escapes the per-task try/catch
    Write-Diag "PROCESS-LEVEL EXCEPTION: $($_.Exception.Message)"
    $processData.status = 'failed'
    $processData.error = $_.Exception.Message
    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
    Write-Information "process_failed: id=$procId error=$($_.Exception.Message)" -Tags @('dotbot', 'process', 'lifecycle')
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process failed: $($_.Exception.Message)"
    try { Write-Status "Process failed: $($_.Exception.Message)" -Type Error } catch { Write-BotLog -Level Error -Message "Process failed: $($_.Exception.Message)" }
} finally {
    # Final cleanup
    if ($processData.status -eq 'running') {
        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status), tasks_completed: $tasksProcessed)"
    Write-Information "process_end: id=$procId status=$($processData.status) tasks_completed=$tasksProcessed" -Tags @('dotbot', 'process', 'lifecycle')
    Write-Diag "=== Process ending: status=$($processData.status) tasksProcessed=$tasksProcessed ==="

    try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
}
