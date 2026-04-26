<#
.SYNOPSIS
Bot state builder module

.DESCRIPTION
Builds the comprehensive bot state object including task counts, session info,
control signals, instance status, and loop state. Uses FileWatcher for caching
and MCP session tools for live data.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    BotRoot = $null
    ControlDir = $null
    ProcessesDir = $null
}

Import-Module (Join-Path $PSScriptRoot "..\..\runtime\modules\ConsoleSequenceSanitizer.psm1")
Import-Module (Join-Path $PSScriptRoot "..\..\mcp\modules\TaskMutation.psm1") -Force

function Initialize-StateBuilder {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ControlDir,
        [Parameter(Mandatory)] [string]$ProcessesDir
    )
    $script:Config.BotRoot = $BotRoot
    $script:Config.ControlDir = $ControlDir
    $script:Config.ProcessesDir = $ProcessesDir
}

function Get-RoadmapTaskDependencies {
    param(
        [Parameter(Mandatory)]
        [object]$Task,
        [Parameter(Mandatory)]
        [hashtable]$DependencyMap
    )

    $explicitDependencies = @(@($Task.dependencies) | Where-Object { $null -ne $_ -and "$($_)".Trim() })
    if ($explicitDependencies.Count -gt 0) {
        return $explicitDependencies
    }

    $researchPrompt = "$($Task.research_prompt)".Trim().ToLowerInvariant()
    if ($researchPrompt -and $DependencyMap.ContainsKey($researchPrompt)) {
        return @($DependencyMap[$researchPrompt])
    }

    return @()
}

function Get-BotState {
    param(
        [DateTime]$IfModifiedSince = [DateTime]::MinValue
    )

    $botRoot = $script:Config.BotRoot
    $controlDir = $script:Config.ControlDir
    $processesDir = $script:Config.ProcessesDir

    # Dot-source MCP session tools (must be in calling scope, not init scope)
    . "$botRoot\systems\mcp\tools\session-get-state\script.ps1"
    . "$botRoot\systems\mcp\tools\session-get-stats\script.ps1"

    # Check if we have a valid cache and no changes since last build
    $cacheMaxAge = 2  # seconds
    $now = [DateTime]::UtcNow
    $cachedState = Get-CachedState
    $cacheTime = Get-StateCacheTime

    if ($cachedState -and
        ($now - $cacheTime).TotalSeconds -lt $cacheMaxAge -and
        -not (Test-StateChanged -Since $cacheTime)) {

        # Return 304-equivalent marker if client already has this state
        if ($IfModifiedSince -ge $cacheTime) {
            return @{ NotModified = $true; CacheTime = $cacheTime }
        }
        return $cachedState
    }

    # Build fresh state
    $tasksDir = Join-Path $botRoot "workspace\tasks"
    $roadmapDependencyMap = Get-RoadmapOverviewDependencyMap -TasksBaseDir $tasksDir

    # Count tasks (including new analysis statuses)
    $todoTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "todo") -Filter "*.json" -ErrorAction SilentlyContinue)
    $analysingTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "analysing") -Filter "*.json" -ErrorAction SilentlyContinue)
    $needsInputTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "needs-input") -Filter "*.json" -ErrorAction SilentlyContinue)
    $analysedTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "analysed") -Filter "*.json" -ErrorAction SilentlyContinue)
    $splitTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "split") -Filter "*.json" -ErrorAction SilentlyContinue)
    $inProgressTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "in-progress") -Filter "*.json" -ErrorAction SilentlyContinue)
    $doneTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "done") -Filter "*.json" -ErrorAction SilentlyContinue)
    $skippedTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "skipped") -Filter "*.json" -ErrorAction SilentlyContinue)
    $cancelledTasks = @(Get-ChildItem -Path (Join-Path $tasksDir "cancelled") -Filter "*.json" -ErrorAction SilentlyContinue)

    # Get current task details
    $currentTask = $null
    if ($inProgressTasks.Count -gt 0) {
        $taskContent = Get-Content $inProgressTasks[0].FullName -Raw | ConvertFrom-Json
        $currentTask = @{
            id = $taskContent.id
            name = $taskContent.name
            description = $taskContent.description
            category = $taskContent.category
            priority = $taskContent.priority
            effort = $taskContent.effort
            status = $taskContent.status
            acceptance_criteria = @($taskContent.acceptance_criteria)
            steps = @($taskContent.steps)
            dependencies = @($taskContent.dependencies)
            applicable_agents = @($taskContent.applicable_agents)
            applicable_standards = @($taskContent.applicable_standards)
            applicable_decisions = @($taskContent.applicable_decisions | Where-Object { $_ })
            plan_path = $taskContent.plan_path
            created_at = $taskContent.created_at
            updated_at = $taskContent.updated_at
            started_at = $taskContent.started_at
            analysis = $taskContent.analysis
            questions_resolved = $taskContent.questions_resolved
            analysis_started_at = $taskContent.analysis_started_at
            analysis_completed_at = $taskContent.analysis_completed_at
            analysed_by = $taskContent.analysed_by
            workflow = $taskContent.workflow
            type = $taskContent.type
        }
    } elseif ($analysingTasks.Count -gt 0) {
        $taskContent = Get-Content $analysingTasks[0].FullName -Raw | ConvertFrom-Json
        $currentTask = @{
            id = $taskContent.id
            name = $taskContent.name
            description = $taskContent.description
            category = $taskContent.category
            priority = $taskContent.priority
            effort = $taskContent.effort
            status = 'analysing'
            acceptance_criteria = @($taskContent.acceptance_criteria)
            steps = @($taskContent.steps)
            dependencies = @($taskContent.dependencies)
            applicable_agents = @($taskContent.applicable_agents)
            applicable_standards = @($taskContent.applicable_standards)
            applicable_decisions = @($taskContent.applicable_decisions | Where-Object { $_ })
            plan_path = $taskContent.plan_path
            created_at = $taskContent.created_at
            updated_at = $taskContent.updated_at
            started_at = $taskContent.started_at
            analysis = $taskContent.analysis
            questions_resolved = $taskContent.questions_resolved
            analysis_started_at = $taskContent.analysis_started_at
            analysis_completed_at = $taskContent.analysis_completed_at
            analysed_by = $taskContent.analysed_by
            workflow = $taskContent.workflow
            type = $taskContent.type
        }
    }

    # Per-workflow task counts accumulator
    $workflowCounts = @{}

    # Get recent completed tasks (last 100 for infinite scroll)
    $recentCompleted = @()
    if ($doneTasks.Count -gt 0) {
        $recentCompleted = $doneTasks |
            ForEach-Object {
                try {
                    $taskContent = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                    @{
                        id = $taskContent.id
                        name = $taskContent.name
                        description = $taskContent.description
                        category = $taskContent.category
                        priority = $taskContent.priority
                        effort = $taskContent.effort
                        status = $taskContent.status
                        acceptance_criteria = @($taskContent.acceptance_criteria)
                        steps = @($taskContent.steps)
                        dependencies = @($taskContent.dependencies)
                        applicable_agents = @($taskContent.applicable_agents)
                        applicable_standards = @($taskContent.applicable_standards)
                        applicable_decisions = @($taskContent.applicable_decisions | Where-Object { $_ })
                        plan_path = $taskContent.plan_path
                        created_at = $taskContent.created_at
                        updated_at = $taskContent.updated_at
                        ignore = $taskContent.ignore
                        started_at = $taskContent.started_at
                        completed_at = $taskContent.completed_at
                        commit_sha = $taskContent.commit_sha
                        commit_subject = $taskContent.commit_subject
                        files_created = $taskContent.files_created
                        files_modified = $taskContent.files_modified
                        files_deleted = $taskContent.files_deleted
                        commits = $taskContent.commits
                        activity_log = $taskContent.activity_log
                        execution_activity_log = $taskContent.execution_activity_log
                        analysis = $taskContent.analysis
                        analysis_started_at = $taskContent.analysis_started_at
                        analysis_completed_at = $taskContent.analysis_completed_at
                        analysed_by = $taskContent.analysed_by
                        workflow = $taskContent.workflow
                        type = $taskContent.type
                    }
                } catch {
                    $null
                }
            } | Where-Object { $_ -ne $null } |
            Sort-Object { if ($_.completed_at) { [DateTime]$_.completed_at } else { [DateTime]::MinValue } } -Descending |
            Select-Object -First 100
    }

    # Get skipped tasks list
    $skippedTasksList = @()
    if ($skippedTasks.Count -gt 0) {
        $skippedTasksList = $skippedTasks |
            ForEach-Object {
                try {
                    $taskContent = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                    @{
                        id = $taskContent.id
                        name = $taskContent.name
                        description = $taskContent.description
                        category = $taskContent.category
                        priority = $taskContent.priority
                        effort = $taskContent.effort
                        status = $taskContent.status
                        acceptance_criteria = @($taskContent.acceptance_criteria)
                        steps = @($taskContent.steps)
                        dependencies = @($taskContent.dependencies)
                        applicable_agents = @($taskContent.applicable_agents)
                        applicable_standards = @($taskContent.applicable_standards)
                        applicable_decisions = @($taskContent.applicable_decisions | Where-Object { $_ })
                        analysis = $taskContent.analysis
                        questions_resolved = $taskContent.questions_resolved
                        analysis_started_at = $taskContent.analysis_started_at
                        analysis_completed_at = $taskContent.analysis_completed_at
                        analysed_by = $taskContent.analysed_by
                        skip_history = $taskContent.skip_history
                        created_at = $taskContent.created_at
                        updated_at = $taskContent.updated_at
                        workflow = $taskContent.workflow
                        type = $taskContent.type
                    }
                } catch {
                    $null
                }
            } | Where-Object { $_ -ne $null }
    }

    # Get analysing tasks list
    $analysingTasksList = @()
    if ($analysingTasks.Count -gt 0) {
        $analysingTasksList = $analysingTasks |
            ForEach-Object {
                try {
                    $taskContent = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                    @{
                        id = $taskContent.id
                        name = $taskContent.name
                        description = $taskContent.description
                        category = $taskContent.category
                        priority = $taskContent.priority
                        effort = $taskContent.effort
                        status = $taskContent.status
                        workflow = $taskContent.workflow
                        type = $taskContent.type
                    }
                } catch { $null }
            } | Where-Object { $_ -ne $null }
    }

    # Get needs-input tasks list
    $needsInputTasksList = @()
    if ($needsInputTasks.Count -gt 0) {
        $needsInputTasksList = $needsInputTasks |
            ForEach-Object {
                try {
                    $taskContent = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                    @{
                        id = $taskContent.id
                        name = $taskContent.name
                        description = $taskContent.description
                        category = $taskContent.category
                        priority = $taskContent.priority
                        effort = $taskContent.effort
                        status = $taskContent.status
                        pending_question = $taskContent.pending_question
                        questions_resolved = $taskContent.questions_resolved
                        workflow = $taskContent.workflow
                        type = $taskContent.type
                    }
                } catch { $null }
            } | Where-Object { $_ -ne $null }
    }

    # Get analysed tasks list
    $analysedTasksList = @()
    if ($analysedTasks.Count -gt 0) {
        $analysedTasksList = $analysedTasks |
            ForEach-Object {
                try {
                    $taskContent = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                    [PSCustomObject]@{
                        id = $taskContent.id
                        name = $taskContent.name
                        description = $taskContent.description
                        category = $taskContent.category
                        priority = $taskContent.priority
                        effort = $taskContent.effort
                        status = $taskContent.status
                        workflow = $taskContent.workflow
                        type = $taskContent.type
                        priority_num = [int]$taskContent.priority
                    }
                } catch { $null }
            } | Where-Object { $_ -ne $null } |
            Sort-Object priority_num, name, id |
            ForEach-Object {
                @{
                    id = $_.id
                    name = $_.name
                    description = $_.description
                    category = $_.category
                    priority = $_.priority
                    effort = $_.effort
                    status = $_.status
                    workflow = $_.workflow
                    type = $_.type
                }
            }
    }

    # Get upcoming tasks (up to 100 in priority order for infinite scroll)
    $upcomingTasks = @()
    if ($todoTasks.Count -gt 0) {
        $upcomingTasks = $todoTasks |
            ForEach-Object {
                try {
                    $taskContent = Get-Content $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                    [PSCustomObject]@{
                        id = $taskContent.id
                        name = $taskContent.name
                        description = $taskContent.description
                        category = $taskContent.category
                        priority = $taskContent.priority
                        effort = $taskContent.effort
                        status = $taskContent.status
                        acceptance_criteria = $taskContent.acceptance_criteria
                        steps = $taskContent.steps
                        dependencies = $taskContent.dependencies
                        research_prompt = $taskContent.research_prompt
                        roadmap_dependencies = Get-RoadmapTaskDependencies -Task $taskContent -DependencyMap $roadmapDependencyMap
                        applicable_agents = $taskContent.applicable_agents
                        applicable_standards = $taskContent.applicable_standards
                        applicable_decisions = @($taskContent.applicable_decisions | Where-Object { $_ })
                        plan_path = $taskContent.plan_path
                        created_at = $taskContent.created_at
                        updated_at = $taskContent.updated_at
                        ignore = $taskContent.ignore
                        workflow = $taskContent.workflow
                        type = $taskContent.type
                        priority_num = [int]$taskContent.priority
                    }
                } catch {
                    $null
                }
            } |
            Where-Object { $_ -ne $null } |
            Sort-Object priority_num, name, id |
            Select-Object -First 100 |
            ForEach-Object {
                @{
                    id = $_.id
                    name = $_.name
                    description = $_.description
                    category = $_.category
                    priority = $_.priority
                    effort = $_.effort
                    status = $_.status
                    acceptance_criteria = $_.acceptance_criteria
                    steps = $_.steps
                    dependencies = $_.dependencies
                    research_prompt = $_.research_prompt
                    roadmap_dependencies = $_.roadmap_dependencies
                    applicable_agents = $_.applicable_agents
                    applicable_standards = $_.applicable_standards
                    applicable_decisions = @($_.applicable_decisions | Where-Object { $_ })
                    plan_path = $_.plan_path
                    created_at = $_.created_at
                    updated_at = $_.updated_at
                    ignore = $_.ignore
                    workflow = $_.workflow
                    type = $_.type
                }
            }
    }

    # When in-progress/ is empty, currentTask may fall back to a task from analysing/.
    # Exclude that task from the analysing list to prevent duplicate cards in the UI.
    if ($currentTask -and $inProgressTasks.Count -eq 0) {
        $analysingTasksList = @($analysingTasksList | Where-Object { $_.id -ne $currentTask.id })
    }

    # Build per-workflow task counts from all task lists
    $allTaskFiles = @()
    foreach ($statusDir in @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped')) {
        $dir = Join-Path $tasksDir $statusDir
        if (Test-Path $dir) {
            $allTaskFiles += @(Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        }
    }
    foreach ($tf in $allTaskFiles) {
        try {
            $tc = Get-Content $tf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
            $wfName = $tc.workflow
            if (-not $wfName) { continue }
            if (-not $workflowCounts.ContainsKey($wfName)) {
                $workflowCounts[$wfName] = @{ todo = 0; analysing = 0; needs_input = 0; analysed = 0; in_progress = 0; done = 0; skipped = 0; total = 0 }
            }
            $wc = $workflowCounts[$wfName]
            $wc['total']++
            switch ($tc.status) {
                'todo'        { $wc['todo']++ }
                'analysing'   { $wc['analysing']++ }
                'needs-input' { $wc['needs_input']++ }
                'analysed'    { $wc['analysed']++ }
                'in-progress' { $wc['in_progress']++ }
                'done'        { $wc['done']++ }
                'skipped'     { $wc['skipped']++ }
            }
        } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
    }

    # Get session info from MCP tools
    $sessionInfo = $null

    $stateResult = Invoke-SessionGetState -Arguments @{}
    if ($stateResult.success) {
        $statsResult = Invoke-SessionGetStats -Arguments @{}

        if ($statsResult.success) {
            $sessionInfo = @{
                session_id = $statsResult.session_id
                session_type = $statsResult.session_type
                status = $statsResult.status
                started_at = $stateResult.state.start_time
                start_time_raw = $stateResult.state.start_time
                tasks_completed = $statsResult.tasks_completed
                tasks_failed = $statsResult.tasks_failed
                tasks_skipped = $statsResult.tasks_skipped
                total_processed = $statsResult.total_processed
                consecutive_failures = $stateResult.state.consecutive_failures
                runtime_hours = $statsResult.runtime_hours
                runtime_minutes = $statsResult.runtime_minutes
                completion_rate = $statsResult.completion_rate
                failure_rate = $statsResult.failure_rate
                skip_rate = $statsResult.skip_rate
                avg_minutes_per_task = $statsResult.avg_minutes_per_task
                auth_method = $statsResult.auth_method
                current_task_id = $statsResult.current_task_id
            }
        } else {
            $sessionInfo = @{
                session_id = $stateResult.state.session_id
                session_type = $stateResult.state.session_type
                status = $stateResult.state.status
                started_at = $stateResult.state.start_time
                start_time_raw = $stateResult.state.start_time
                tasks_completed = $stateResult.state.tasks_completed
                tasks_failed = $stateResult.state.tasks_failed
                tasks_skipped = $stateResult.state.tasks_skipped
                consecutive_failures = $stateResult.state.consecutive_failures
                current_task_id = $stateResult.state.current_task_id
            }
        }
    }

    # Read instance info from process registry only
    $instances = @{
        analysis = $null
        execution = $null
    }
    $isAnalysisRunning = $false
    $isActuallyRunning = $false

    # Check process registry for running processes
    $runningProcesses = @()
    $processNeedsInputCount = 0
    if (Test-Path $processesDir) {
        $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($pf in $procFiles) {
            try {
                $proc = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                $proc = Update-ProcessHeartbeatFields -Process $proc

                # Count processes waiting for interview answers
                if ($proc.status -eq 'needs-input' -and $proc.pending_questions) {
                    # Verify PID is still alive
                    $needsInputAlive = $true
                    if ($proc.pid) {
                        try { $needsInputAlive = $null -ne (Get-Process -Id $proc.pid -ErrorAction SilentlyContinue) }
                        catch { $needsInputAlive = $true }
                    }
                    if ($needsInputAlive) {
                        $processNeedsInputCount++
                    }
                }

                if ($proc.status -in @('running', 'starting')) {

                    $isAlive = $true
                    if ($proc.pid) {
                        try { $isAlive = $null -ne (Get-Process -Id $proc.pid -ErrorAction SilentlyContinue) }
                        catch { $isAlive = $true }
                    }

                    # Mark dead PIDs as stopped and persist the change
                    if (-not $isAlive) {
                        $proc.status = 'stopped'
                        $deadNow = [DateTime]::UtcNow.ToString("o")
                        if (-not $proc.failed_at) {
                            $proc | Add-Member -NotePropertyName 'failed_at' -NotePropertyValue $deadNow -Force
                        }
                        $proc | Add-Member -NotePropertyName 'error' -NotePropertyValue "Process terminated unexpectedly" -Force
                        try {
                            $proc | ConvertTo-Json -Depth 10 | Set-Content -Path $pf.FullName -Force -Encoding utf8NoBOM
                            $actFile = Join-Path $processesDir "$($proc.id).activity.jsonl"
                            $event = @{ timestamp = $deadNow; type = "text"; message = "Process terminated unexpectedly (PID $($proc.pid) no longer alive)" } | ConvertTo-Json -Compress
                            Add-Content -Path $actFile -Value $event -ErrorAction SilentlyContinue
                        } catch { Write-BotLog -Level Warn -Message "Failed to write file" -Exception $_ }
                        continue  # Skip adding to instances — it's dead
                    }

                    $runningProcesses += $proc

                    if ($proc.type -eq 'analysis' -and -not $instances.analysis) {
                        $instances.analysis = @{
                            instance_id = $proc.id
                            pid = $proc.pid
                            started_at = $proc.started_at
                            last_heartbeat = $proc.last_heartbeat
                            status = $proc.heartbeat_status
                            next_action = $proc.heartbeat_next_action
                            alive = $isAlive
                        }
                        $isAnalysisRunning = $true
                    }
                    if ($proc.type -eq 'execution' -and -not $instances.execution) {
                        $instances.execution = @{
                            instance_id = $proc.id
                            pid = $proc.pid
                            started_at = $proc.started_at
                            last_heartbeat = $proc.last_heartbeat
                            status = $proc.heartbeat_status
                            next_action = $proc.heartbeat_next_action
                            alive = $isAlive
                        }
                        $isActuallyRunning = $true
                    }
                    if ($proc.type -eq 'task-runner' -and -not $instances.workflow) {
                        $instances.workflow = @{
                            instance_id = $proc.id
                            pid = $proc.pid
                            started_at = $proc.started_at
                            last_heartbeat = $proc.last_heartbeat
                            status = $proc.heartbeat_status
                            next_action = $proc.heartbeat_next_action
                            alive = $isAlive
                        }
                        $isActuallyRunning = $true
                    }
                }
            } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        }
    }

    # Track combined loop state
    $analysisAlive = ($null -ne $instances.analysis) -and ($instances.analysis.alive -eq $true)
    $executionAlive = ($null -ne $instances.execution) -and ($instances.execution.alive -eq $true)
    $workflowAlive = ($null -ne $instances.workflow) -and ($instances.workflow.alive -eq $true)
    $anyLoopRunning = $runningProcesses.Count -gt 0
    $anyLoopAlive = $analysisAlive -or $executionAlive -or $workflowAlive

    # Mark per-workflow process_alive so UI can enable Stop buttons per workflow
    $activeWorkflowNames = @{}
    foreach ($proc in $runningProcesses) {
        if ($proc.workflow_name) {
            $activeWorkflowNames[$proc.workflow_name] = $true
        }
    }
    foreach ($key in @($workflowCounts.Keys)) {
        if ($activeWorkflowNames.ContainsKey($key)) {
            $workflowCounts[$key]['process_alive'] = $true
        } elseif ($activeWorkflowNames.Count -eq 0 -and ($workflowAlive -or $analysisAlive -or $executionAlive)) {
            # Fallback: if no processes have workflow_name set, mark all as alive (legacy compat)
            $workflowCounts[$key]['process_alive'] = $true
        }
    }

    # Check control signals — derive stop from per-process .stop files
    $anyStopPending = $false
    if (Test-Path $processesDir) {
        $anyStopPending = @(Get-ChildItem -Path $processesDir -Filter "*.stop" -File -ErrorAction SilentlyContinue).Count -gt 0
    }
    $controlSignals = @{
        pause = Test-Path (Join-Path $controlDir "pause.signal")
        stop = $anyStopPending
        resume = $false
        running = $isActuallyRunning
    }

    # Override session status if no loops are running but session state says running
    if ($sessionInfo -and -not $anyLoopRunning) {
        if ($sessionInfo.status -eq 'running') {
            $sessionInfo.status = 'stopped'
        }
    }


    # Read workspace instance ID from settings.default.json
    $workspaceInstanceId = $null
    $settingsPath = Join-Path $botRoot "settings\settings.default.json"
    if (Test-Path $settingsPath) {
        try {
            $settingsJson = Get-Content $settingsPath -Raw | ConvertFrom-Json
            if ($settingsJson.PSObject.Properties['instance_id'] -and $settingsJson.instance_id) {
                $workspaceInstanceId = "$($settingsJson.instance_id)"
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }
    # Get steering status (for operator whisper channel) - legacy support
    $steeringStatus = $null
    $steeringStatusFile = Join-Path $controlDir "steering-status.json"
    if (Test-Path $steeringStatusFile) {
        try {
            $steeringStatus = Get-Content $steeringStatusFile -Raw | ConvertFrom-Json
        } catch {
            # Ignore read errors
        }
    }

    # Count decisions by status
    $decisionsBaseDir = Join-Path $botRoot "workspace\decisions"
    $decisionCounts = @{ proposed = 0; accepted = 0; deprecated = 0; superseded = 0; total = 0 }
    foreach ($decStatus in @('proposed', 'accepted', 'deprecated', 'superseded')) {
        $decDir = Join-Path $decisionsBaseDir $decStatus
        $decCount = if (Test-Path $decDir) { @(Get-ChildItem -Path $decDir -Filter "dec-*.json" -File -ErrorAction SilentlyContinue).Count } else { 0 }
        $decisionCounts[$decStatus] = $decCount
        $decisionCounts['total'] += $decCount
    }

    $state = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        instance_id = $workspaceInstanceId
        decisions = $decisionCounts
        tasks = @{
            todo = $todoTasks.Count
            analysing = $analysingTasks.Count
            needs_input = $needsInputTasks.Count
            analysed = $analysedTasks.Count
            split = $splitTasks.Count
            in_progress = $inProgressTasks.Count
            done = $doneTasks.Count
            skipped = $skippedTasks.Count
            cancelled = $cancelledTasks.Count
            current = $currentTask
            upcoming = @($upcomingTasks)
            upcoming_total = if ($todoTasks.Count) { $todoTasks.Count } else { 0 }
            analysing_list = @($analysingTasksList)
            needs_input_list = @($needsInputTasksList)
            analysed_list = @($analysedTasksList)
            recent_completed = @($recentCompleted)
            completed_total = if ($doneTasks.Count) { $doneTasks.Count } else { 0 }
            skipped_list = @($skippedTasksList)
            action_required = $needsInputTasks.Count + $processNeedsInputCount
        }
        session = $sessionInfo
        control = $controlSignals
        analysis = @{
            running = $isAnalysisRunning
        }
        loops = @{
            any_running = $anyLoopRunning
            all_stopped = -not $anyLoopRunning
            analysis_alive = $analysisAlive
            execution_alive = $executionAlive
            workflow_alive = $workflowAlive
            any_alive = $anyLoopAlive
        }
        instances = $instances
        steering = $steeringStatus
        product_docs = @(Get-ChildItem -Path (Join-Path $botRoot "workspace\product") -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue).Count
        workflows = $workflowCounts
    }

    # Cache the result
    Set-CachedState -State $state

    return $state
}

Export-ModuleMember -Function @('Initialize-StateBuilder', 'Get-BotState')
