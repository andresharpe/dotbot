<#
.SYNOPSIS
    Execution process type: analysed -> in-progress -> done task loop.
.DESCRIPTION
    Runs a continuous loop picking up analysed tasks, executing them via Claude
    in isolated git worktrees, verifying results, and squash-merging to main.
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
$instanceId = $Context.InstanceId
$Continue = $Context.Continue
$NoWait = $Context.NoWait
$MaxTasks = $Context.MaxTasks
$TaskId = $Context.TaskId
$permissionMode = $Context.PermissionMode

# Initialize session
$sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
$sessionId = if ($sessionResult.success) { $sessionResult.session.session_id } else { $Context.BatchSessionId }

# Load prompt template
$templateFile = Join-Path $botRoot "recipes\prompts\99-autonomous-task.md"
$promptTemplate = Get-Content $templateFile -Raw
$processData.workflow = "99-autonomous-task.md"

# Standards and product context
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
Reset-AnalysingTasks -TasksBaseDir $tasksBaseDir -ProcessesDir $processesDir | Out-Null
Reset-InProgressTasks -TasksBaseDir $tasksBaseDir | Out-Null
Reset-SkippedTasks -TasksBaseDir $tasksBaseDir | Out-Null

# Clean up orphan worktrees from previous runs
Remove-OrphanWorktrees -ProjectRoot $projectRoot -BotRoot $botRoot

$tasksProcessed = 0
$maxRetriesPerTask = 2
$consecutiveFailureThreshold = 3

# Update process status to running
$processData.status = 'running'
Write-ProcessFile -Id $procId -Data $processData

try {
    while ($true) {
        if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
            Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
            break
        }

        if (Test-ProcessStopSignal -Id $procId) {
            Write-Status "Stop signal received" -Type Error
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process stopped by user"
            break
        }

        Write-Status "Fetching next task..." -Type Process
        $taskResult = Invoke-TaskGetNext -Arguments @{ verbose = $true }

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
                    $taskResult = Invoke-TaskGetNext -Arguments @{ verbose = $true }
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

        # Mark execution task immediately
        Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
        Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

        # --- Task type dispatch (script / mcp / task_gen bypass Claude) ---
        $taskTypeExec = if ($task.type) { $task.type } else { 'prompt' }
        if ($taskTypeExec -notin @('prompt', 'prompt_template')) {
            $typeSuccess = $false
            $typeError = $null
            try {
                switch ($taskTypeExec) {
                    'script' {
                        $resolvedScript = Join-Path $botRoot $task.script_path
                        Write-Status "Running script: $($task.script_path)" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing script task: $($task.name)"
                        & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                        $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                    }
                    'mcp' {
                        $toolFuncParts = $task.mcp_tool -split '_'
                        $capitalParts = foreach ($p in $toolFuncParts) { $p.Substring(0,1).ToUpperInvariant() + $p.Substring(1) }
                        $toolFunc = 'Invoke-' + ($capitalParts -join '')
                        $toolArgs = if ($task.mcp_args) { $task.mcp_args } else { @{} }
                        Write-Status "Calling MCP tool: $($task.mcp_tool)" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Executing MCP task: $($task.name)"
                        $mcpResult = & $toolFunc -Arguments $toolArgs
                        $typeSuccess = $true
                    }
                    'task_gen' {
                        $resolvedScript = Join-Path $botRoot $task.script_path
                        Write-Status "Running task generator: $($task.script_path)" -Type Process
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Generating tasks: $($task.name)"
                        & $resolvedScript -BotRoot $botRoot -ProcessId $procId -Settings $settings
                        $typeSuccess = ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE)
                        Reset-TaskIndex
                    }
                }
            } catch {
                $typeError = $_.Exception.Message
                Write-Status "Task type execution failed: $typeError" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
            }

            if ($typeSuccess) {
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
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completed $taskTypeExec task: $($task.name)"
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $tasksProcessed++
            } else {
                Write-Status "Task failed: $($task.name)" -Type Error
                try {
                    Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = "$taskTypeExec execution failed: $typeError" } | Out-Null
                } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }
            }
            continue
        }

        # --- Worktree setup ---
        $worktreePath = $null
        $branchName = $null
        $wtInfo = Get-TaskWorktreeInfo -TaskId $task.id -BotRoot $botRoot
        if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
            $worktreePath = $wtInfo.worktree_path
            $branchName = $wtInfo.branch_name
            Write-Status "Using worktree: $worktreePath" -Type Info
        } else {
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

        # Generate new provider session ID per task
        $claudeSessionId = New-ProviderSession
        $env:CLAUDE_SESSION_ID = $claudeSessionId
        $processData.claude_session_id = $claudeSessionId
        Write-ProcessFile -Id $procId -Data $processData

        # Build execution prompt
        $prompt = Build-TaskPrompt `
            -PromptTemplate $promptTemplate `
            -Task $task `
            -SessionId $sessionId `
            -ProductMission $productMission `
            -EntityModel $entityModel `
            -StandardsList $standardsList `
            -InstanceId $instanceId

        $branchForPrompt = if ($branchName) { $branchName } else { "main" }
        $prompt = $prompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

        $fullPrompt = @"
$prompt

## Process Context

- **Process ID:** $procId
- **Instance Type:** execution

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call task_mark_done via MCP.
"@

        # Invoke Claude with retries
        $attemptNumber = 0
        $taskSuccess = $false

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

            # Kill any background processes Claude may have spawned in the worktree
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

            # Check completion
            $completionCheck = Test-TaskCompletion -TaskId $task.id
            if ($completionCheck.completed) {
                Write-Status "Task completed!" -Type Complete
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $taskSuccess = $true
                break
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
            if ($worktreePath) {
                Stop-WorktreeProcesses -WorktreePath $worktreePath | Out-Null
                Pop-Location
            }
        }

        # Update process data
        $env:DOTBOT_CURRENT_TASK_ID = $null
        $env:CLAUDE_SESSION_ID = $null

        if ($taskSuccess) {
            # Post-completion: squash-merge task branch to main
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

                    # Resolve via $PSScriptRoot so the lookup is immune to a null
                    # $global:DotbotProjectRoot and to Join-Path's backslash quirk on Linux.
                    $escalationModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'MergeConflictEscalation.psm1'
                    if (Test-Path $escalationModule) {
                        Import-Module $escalationModule -Force
                        Invoke-MergeConflictEscalation -Task $task -TasksBaseDir $tasksBaseDir -MergeResult $mergeResult -WorktreePath $worktreePath -ProcId $procId -BotRoot $botRoot | Out-Null
                    } else {
                        Write-Status "Merge-conflict escalation helper not found at $escalationModule" -Type Error
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Escalation helper missing for $($task.name); task left in done/"
                    }
                }
            }

            $tasksProcessed++
            $processData.tasks_completed = $tasksProcessed
            $processData.heartbeat_status = "Completed: $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed: $($task.name)"

            try { Remove-ProviderSession -SessionId $claudeSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }
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
                    Initialize-WorktreeMap -BotRoot $botRoot
                    Invoke-WorktreeMapLocked -Action {
                        $cleanupMap = Read-WorktreeMap
                        $cleanupMap.Remove($task.id)
                        Write-WorktreeMap -Map $cleanupMap
                    }
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

                if ($newFailures -ge $consecutiveFailureThreshold) {
                    Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                    break
                }
            } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
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

    try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
}
