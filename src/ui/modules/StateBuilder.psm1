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

Import-Module (Join-Path $PSScriptRoot "../../runtime/Modules/Dotbot.Core/Dotbot.Core.psm1")
Import-Module (Join-Path $PSScriptRoot "../../mcp/modules/TaskMutation.psm1") -Force

function _Read-FlatTask {
    <#
    .SYNOPSIS
    Read a task JSON file and project it into a flat dictionary. Executor
    knobs from extensions.executor.* and workflow metadata from
    extensions.workflow.* are surfaced at the top level, as is
    provenance.workflow → top-level 'workflow'.
    #>
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    try {
        $c = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
    $exec = $null; $wfx = $null; $runner = $null; $analysis = $null
    if ($c.PSObject.Properties['extensions'] -and $c.extensions) {
        $e = $c.extensions
        if ($e.PSObject.Properties['executor']) { $exec = $e.executor }
        if ($e.PSObject.Properties['workflow']) { $wfx  = $e.workflow }
        if ($e.PSObject.Properties['runner'])   { $runner = $e.runner }
        if ($e.PSObject.Properties['analysis']) { $analysis = $e.analysis }
    }
    function _g { param($Bag, [string]$Key)
        if ($null -eq $Bag) { return $null }
        if ($Bag -is [System.Collections.IDictionary]) {
            if ($Bag.Contains($Key)) { return $Bag[$Key] }
            return $null
        }
        if ($Bag.PSObject.Properties[$Key]) { return $Bag.PSObject.Properties[$Key].Value }
        return $null
    }
    $workflowName = $null
    if ($c.PSObject.Properties['provenance'] -and $c.provenance) {
        $workflowName = [string]$c.provenance.workflow
    }
    return [pscustomobject]@{
        id                    = $c.id
        name                  = $c.name
        description           = $c.description
        category              = $c.category
        priority              = $c.priority
        effort                = $c.effort
        status                = $c.status
        type                  = $c.type
        dependencies          = $c.dependencies
        acceptance_criteria   = $c.acceptance_criteria
        outputs               = $c.outputs
        created_at            = $c.created_at
        updated_at            = $c.updated_at
        completed_at          = $c.completed_at
        ignore                = if ($c.PSObject.Properties['ignore']) { $c.ignore } else { $null }
        workflow              = $workflowName
        script_path           = _g $exec 'script_path'
        mcp_tool              = _g $exec 'mcp_tool'
        mcp_args              = _g $exec 'mcp_args'
        prompt                = _g $exec 'prompt'
        skip_analysis         = _g $exec 'skip_analysis'
        outputs_dir           = _g $wfx 'outputs_dir'
        min_output_count      = _g $wfx 'min_output_count'
        required_outputs      = _g $wfx 'required_outputs'
        required_outputs_dir  = _g $wfx 'required_outputs_dir'
        front_matter_docs     = _g $wfx 'front_matter_docs'
        condition             = _g $wfx 'condition'
        optional              = _g $wfx 'optional'
        steps                 = _g $wfx 'steps'
        applicable_agents     = _g $wfx 'applicable_agents'
        applicable_standards  = _g $wfx 'applicable_standards'
        applicable_decisions  = _g $wfx 'applicable_decisions'
        needs_interview       = _g $wfx 'needs_interview'
        questions_resolved    = _g $runner 'questions_resolved'
        pending_question      = _g $runner 'pending_question'
        claude_session_id     = _g $runner 'claude_session_id'
        started_at            = _g $runner 'started_at'
        analysis_started_at   = _g $runner 'analysis_started_at'
        analysis_completed_at = _g $runner 'analysis_completed_at'
        commit_sha            = _g $runner 'commit_sha'
        commit_subject        = _g $runner 'commit_subject'
        files_created         = _g $runner 'files_created'
        files_modified        = _g $runner 'files_modified'
        files_deleted         = _g $runner 'files_deleted'
        commits               = _g $runner 'commits'
        activity_log          = _g $runner 'activity_log'
        plan_path             = _g $runner 'plan_path'
        analysis              = $analysis
        analysed_by           = _g $analysis 'analysed_by'
        research_prompt       = _g $wfx 'research_prompt'
        _FullName             = $File.FullName
    }
}

function _Get-RunIdForDir {
    <#
    .SYNOPSIS
    Read the run_id from a workflow-run directory's run.json (cached per call).
    #>
    param([Parameter(Mandatory)][string]$RunDir, [Parameter(Mandatory)][hashtable]$Cache)
    if ($Cache.ContainsKey($RunDir)) { return $Cache[$RunDir] }
    $runId = $null
    $runJson = Join-Path $RunDir 'run.json'
    if (Test-Path -LiteralPath $runJson) {
        try {
            $rj = Get-Content -LiteralPath $runJson -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($rj.PSObject.Properties['run_id']) { $runId = [string]$rj.run_id }
        } catch { $runId = $null }
    }
    $Cache[$RunDir] = $runId
    return $runId
}

function _Get-TasksGrouped {
    <#
    .SYNOPSIS
    Walk workflow-runs/ + standalone/ and group flat tasks by status. Each task
    is tagged with the run_id of its containing run directory so concurrent runs
    can be told apart in the dashboard.
    #>
    param([Parameter(Mandatory)][string]$BotRoot)
    $grouped = @{}
    foreach ($s in @('todo','analysing','analysed','needs-input','in-progress','needs-review','done','failed','skipped','cancelled','split')) {
        $grouped[$s] = @()
    }
    $tasksRoot = Join-Path $BotRoot 'workspace/tasks'
    if (-not (Test-Path -LiteralPath $tasksRoot)) { return $grouped }

    $runIdCache = @{}
    $buckets = @(
        (Join-Path $tasksRoot 'workflow-runs'),
        (Join-Path $tasksRoot 'standalone')
    )
    foreach ($bucket in $buckets) {
        if (-not (Test-Path -LiteralPath $bucket)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $bucket -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq 'run.json') { continue }
            $flat = _Read-FlatTask -File $f
            if (-not $flat) { continue }
            $st = [string]$flat.status
            if (-not $st) { continue }
            # Tag the task with its run_id, derived from the run.json living in
            # the same directory (null for standalone tasks).
            $runId = _Get-RunIdForDir -RunDir $f.DirectoryName -Cache $runIdCache
            $flat | Add-Member -NotePropertyName 'run_id' -NotePropertyValue $runId -Force
            if ($grouped.ContainsKey($st)) { $grouped[$st] += $flat }
        }
    }
    return $grouped
}

function _Get-WorkflowRunsSummary {
    <#
    .SYNOPSIS
    Build a per-run summary so the dashboard can show all concurrent runs side
    by side instead of one flattened task board. Joins the committed run.json
    records with the live status files under .control/workflow-runs/ and folds
    in per-run task counts from the already-grouped, run_id-tagged tasks.
    #>
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][hashtable]$Grouped
    )
    $runsRoot = Join-Path $BotRoot 'workspace/tasks/workflow-runs'
    $liveRoot = Join-Path $BotRoot '.control/workflow-runs'

    # Per-run task counts and a lightweight per-run task list, both derived from
    # the run_id-tagged grouped tasks. The task list lets the dashboard group
    # tasks under their run; it is capped per run to keep the state payload small.
    $maxTasksPerRun = 300
    $countsByRun = @{}
    $tasksByRun = @{}
    foreach ($status in $Grouped.Keys) {
        foreach ($t in $Grouped[$status]) {
            $rid = if ($t.PSObject.Properties['run_id']) { [string]$t.run_id } else { $null }
            if (-not $rid) { continue }
            if (-not $countsByRun.ContainsKey($rid)) { $countsByRun[$rid] = @{ total = 0 } }
            if (-not $countsByRun[$rid].ContainsKey($status)) { $countsByRun[$rid][$status] = 0 }
            $countsByRun[$rid][$status]++
            $countsByRun[$rid]['total']++

            if (-not $tasksByRun.ContainsKey($rid)) { $tasksByRun[$rid] = [System.Collections.Generic.List[object]]::new() }
            $tasksByRun[$rid].Add([ordered]@{
                id       = [string]$t.id
                name     = [string]$t.name
                status   = $status
                priority = if ($null -ne $t.priority) { [int]$t.priority } else { 99 }
            })
        }
    }

    # Live status records keyed by run_id.
    $liveByRun = @{}
    if (Test-Path -LiteralPath $liveRoot) {
        foreach ($lf in (Get-ChildItem -LiteralPath $liveRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $live = Get-Content -LiteralPath $lf.FullName -Raw | ConvertFrom-Json
                if ($live.PSObject.Properties['run_id']) { $liveByRun[[string]$live.run_id] = $live }
            } catch { continue }
        }
    }

    $runs = @()
    if (Test-Path -LiteralPath $runsRoot) {
        foreach ($dir in (Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue)) {
            $runJson = Join-Path $dir.FullName 'run.json'
            if (-not (Test-Path -LiteralPath $runJson)) { continue }
            try { $rj = Get-Content -LiteralPath $runJson -Raw | ConvertFrom-Json } catch { continue }
            $rid = [string]$rj.run_id
            if (-not $rid) { continue }
            $live = $liveByRun[$rid]
            $runTasks = if ($tasksByRun.ContainsKey($rid)) { $tasksByRun[$rid] } else { @() }
            $runTaskTotal = @($runTasks).Count
            # Sort lowest-priority-number (highest priority) first, then cap.
            $runTasksOut = @($runTasks | Sort-Object -Property { $_.priority }, { $_.name } | Select-Object -First $maxTasksPerRun)
            $runs += [ordered]@{
                run_id          = $rid
                workflow_name   = [string]$rj.workflow_name
                dir_name        = $dir.Name
                isolated        = [bool]$rj.isolated
                started_at      = [string]$rj.started_at
                status          = if ($live -and $live.PSObject.Properties['status']) { [string]$live.status } else { 'unknown' }
                current_task_id = if ($live -and $live.PSObject.Properties['current_task_id']) { [string]$live.current_task_id } else { $null }
                last_heartbeat  = if ($live -and $live.PSObject.Properties['last_heartbeat']) { [string]$live.last_heartbeat } else { $null }
                task_counts     = if ($countsByRun.ContainsKey($rid)) { $countsByRun[$rid] } else { @{ total = 0 } }
                tasks           = $runTasksOut
                tasks_total     = $runTaskTotal
            }
        }
    }
    # Most recent first (ISO-8601 timestamps sort lexically).
    return @($runs | Sort-Object { if ($_.started_at) { $_.started_at } else { '' } } -Descending)
}

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
    . (Join-Path $PSScriptRoot ".." ".." "mcp" "tools" "session-get-state" "script.ps1")
    . (Join-Path $PSScriptRoot ".." ".." "mcp" "tools" "session-get-stats" "script.ps1")

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

    $tasksDir = Join-Path $botRoot "workspace/tasks"
    $roadmapDependencyMap = Get-RoadmapOverviewDependencyMap -TasksBaseDir $tasksDir

    $grouped = _Get-TasksGrouped -BotRoot $botRoot
    $todoTasks       = @($grouped['todo'])
    $analysingTasks  = @($grouped['analysing'])
    $needsInputTasks = @($grouped['needs-input'])
    $analysedTasks   = @($grouped['analysed'])
    $splitTasks      = @($grouped['split'])
    $inProgressTasks = @($grouped['in-progress'])
    $needsReviewTasks = @($grouped['needs-review'])
    $doneTasks       = @($grouped['done'])
    $skippedTasks    = @($grouped['skipped'])
    $cancelledTasks  = @($grouped['cancelled'])

    # Get current task details
    $currentTask = $null
    if ($inProgressTasks.Count -gt 0) {
        $taskContent = $inProgressTasks[0]
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
        $taskContent = $analysingTasks[0]
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
                    $taskContent = $_
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
                    $taskContent = $_
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
                    $taskContent = $_
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
                    $taskContent = $_
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
                    $taskContent = $_
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

    # Get in-progress tasks list. The legacy `current` field keeps the first
    # active task for compact widgets, but dashboard columns need the full set
    # when multiple workflow runners are executing concurrently.
    $inProgressTasksList = @()
    if ($inProgressTasks.Count -gt 0) {
        $inProgressTasksList = $inProgressTasks |
            ForEach-Object {
                try {
                    $taskContent = $_
                    [PSCustomObject]@{
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
                        run_id = $taskContent.run_id
                        type = $taskContent.type
                        priority_num = if ($null -ne $taskContent.priority) { [int]$taskContent.priority } else { 99 }
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
                    acceptance_criteria = @($_.acceptance_criteria)
                    steps = @($_.steps)
                    dependencies = @($_.dependencies)
                    applicable_agents = @($_.applicable_agents)
                    applicable_standards = @($_.applicable_standards)
                    applicable_decisions = @($_.applicable_decisions | Where-Object { $_ })
                    plan_path = $_.plan_path
                    created_at = $_.created_at
                    updated_at = $_.updated_at
                    started_at = $_.started_at
                    analysis = $_.analysis
                    questions_resolved = $_.questions_resolved
                    analysis_started_at = $_.analysis_started_at
                    analysis_completed_at = $_.analysis_completed_at
                    analysed_by = $_.analysed_by
                    workflow = $_.workflow
                    run_id = $_.run_id
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
                    $taskContent = $_
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

    # Per-workflow task counts.
    foreach ($statusKey in @('todo','analysing','needs-input','analysed','in-progress','needs-review','done','skipped')) {
        foreach ($tc in @($grouped[$statusKey])) {
            $wfName = $tc.workflow
            if (-not $wfName) { continue }
            if (-not $workflowCounts.ContainsKey($wfName)) {
                $workflowCounts[$wfName] = @{ todo = 0; analysing = 0; needs_input = 0; analysed = 0; in_progress = 0; needs_review = 0; done = 0; skipped = 0; total = 0 }
            }
            $wc = $workflowCounts[$wfName]
            $wc['total']++
            switch ($statusKey) {
                'todo'         { $wc['todo']++ }
                'analysing'    { $wc['analysing']++ }
                'needs-input'  { $wc['needs_input']++ }
                'analysed'     { $wc['analysed']++ }
                'in-progress'  { $wc['in_progress']++ }
                'needs-review' { $wc['needs_review']++ }
                'done'         { $wc['done']++ }
                'skipped'      { $wc['skipped']++ }
            }
        }
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
                            $entry = @{ timestamp = $deadNow; type = "text"; message = "Process terminated unexpectedly (PID $($proc.pid) no longer alive)" } | ConvertTo-Json -Compress
                            Add-Content -Path $actFile -Value $entry -ErrorAction SilentlyContinue
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


    # Instance identity is machine-local workspace state, not inherited settings.
    $workspaceInstanceId = $null
    $settingsPath = Join-Path $botRoot ".control/settings.json"
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
    $decisionsBaseDir = Join-Path $botRoot "workspace/decisions"
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
            in_progress_list = @($inProgressTasksList)
            recent_completed = @($recentCompleted)
            completed_total = if ($doneTasks.Count) { $doneTasks.Count } else { 0 }
            skipped_list = @($skippedTasksList)
            action_required = $needsInputTasks.Count + $processNeedsInputCount + $needsReviewTasks.Count
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
        product_docs = @(Get-ChildItem -Path (Join-Path $botRoot "workspace/product") -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue).Count
        workflows = $workflowCounts
        workflow_runs = @(_Get-WorkflowRunsSummary -BotRoot $botRoot -Grouped $grouped)
    }

    # Cache the result
    Set-CachedState -State $state

    return $state
}

Export-ModuleMember -Function @('Initialize-StateBuilder', 'Get-BotState')
