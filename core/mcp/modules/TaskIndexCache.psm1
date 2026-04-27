<#
.SYNOPSIS
Task index module - reads task files fresh on each access

.DESCRIPTION
Provides functions to query tasks from the filesystem.
No caching - always reads fresh data to avoid stale state issues.
#>

$script:TaskIndex = @{
    Todo = @{}          # id -> task metadata
    Analysing = @{}     # Tasks currently being analysed
    NeedsInput = @{}    # Tasks waiting for human input
    Analysed = @{}      # Tasks ready for implementation
    InProgress = @{}
    Done = @{}
    Split = @{}         # Tasks that were split into sub-tasks
    Skipped = @{}       # Tasks that were skipped
    Cancelled = @{}     # Tasks that were cancelled
    DoneIds = @()       # Quick lookup for dependency checking (by id)
    DoneNames = @()     # Quick lookup for dependency checking (by name)
    DoneSlugs = @()     # Quick lookup for dependency checking (by slug)
    IgnoreMap = @{}     # Effective ignore state for todo tasks
    BaseDir = $null
}

function Initialize-TaskIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TasksBaseDir,
        [array]$TodoTasks
    )

    # Ensure directory exists
    if (-not (Test-Path $TasksBaseDir)) {
        New-Item -Path $TasksBaseDir -ItemType Directory -Force | Out-Null
    }

    $script:TaskIndex.BaseDir = $TasksBaseDir
}

function Get-IgnoreTaskPriorityValue {
    param(
        [object]$Task
    )

    try {
        if ($null -ne $Task.priority -and "$($Task.priority)".Trim()) {
            return [int]$Task.priority
        }
    } catch {
        # Leave malformed priorities at the end of ordinal alias resolution.
    }

    return [int]::MaxValue
}

function Add-IgnoreReferenceAlias {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ReferenceMap,
        [Parameter(Mandatory)]
        [string]$TaskId,
        [object]$Alias
    )

    if ($null -eq $Alias) {
        return
    }

    $normalizedAlias = "$Alias".Trim().ToLowerInvariant()
    if (-not $normalizedAlias) {
        return
    }

    $ReferenceMap[$normalizedAlias] = $TaskId
}

function Get-IgnoreDependencyTokens {
    param(
        [object]$Dependency
    )

    if ($null -eq $Dependency) {
        return @()
    }

    $rawDependency = "$Dependency".Trim()
    if (-not $rawDependency) {
        return @()
    }

    $tokens = [System.Collections.Generic.List[string]]::new()

    function Add-IgnoreDependencyToken {
        param(
            [string]$Value
        )

        if (-not $Value) {
            return
        }

        $normalizedValue = $Value.Trim().ToLowerInvariant()
        if ($normalizedValue -and -not $tokens.Contains($normalizedValue)) {
            $null = $tokens.Add($normalizedValue)
        }
    }

    Add-IgnoreDependencyToken -Value $rawDependency

    $ordinalMatch = [regex]::Match($rawDependency, '^tasks?\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($ordinalMatch.Success) {
        $ordinalExpression = $ordinalMatch.Groups[1].Value.Trim()
        Add-IgnoreDependencyToken -Value $ordinalExpression

        foreach ($part in ($ordinalExpression -split '\s*,\s*')) {
            $normalizedPart = [regex]::Replace($part, '^tasks?\s+', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
            if (-not $normalizedPart) {
                continue
            }

            Add-IgnoreDependencyToken -Value $normalizedPart
            Add-IgnoreDependencyToken -Value "task $normalizedPart"
        }

        return @($tokens)
    }

    foreach ($part in ($rawDependency -split '\s*,\s*')) {
        Add-IgnoreDependencyToken -Value $part
    }

    return @($tokens)
}

function Get-IgnoreRoadmapDependencyMap {
    param(
        [string]$TasksBaseDir
    )

    $workspaceDir = Split-Path -Parent $TasksBaseDir
    $overviewPath = Join-Path $workspaceDir "product\roadmap-overview.md"
    $dependencyMap = @{}
    if (-not (Test-Path $overviewPath)) {
        return $dependencyMap
    }

    foreach ($line in @(Get-Content -Path $overviewPath -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '^\|\s*\d+\s*\|') {
            continue
        }

        $cells = ($line.Trim().Trim('|') -split '\s*\|\s*')
        if ($cells.Count -lt 5) {
            continue
        }

        $methodologyMatch = [regex]::Match($cells[2], '`([^`]+)`')
        if (-not $methodologyMatch.Success) {
            continue
        }

        $methodologyKey = $methodologyMatch.Groups[1].Value.Trim().ToLowerInvariant()
        if (-not $methodologyKey) {
            continue
        }

        $dependencyText = $cells[3].Trim()
        if (-not $dependencyText -or $dependencyText -match '^(none|n/a)$') {
            $dependencyMap[$methodologyKey] = @()
            continue
        }

        $dependencyMap[$methodologyKey] = @($dependencyText)
    }

    return $dependencyMap
}

function Get-ResolvedIgnoreDependencies {
    param(
        [Parameter(Mandatory)]
        [object]$Task,
        [Parameter(Mandatory)]
        [hashtable]$RoadmapDependencyMap
    )

    $explicitDependencies = @(@($Task.dependencies) | Where-Object { $null -ne $_ -and "$($_)".Trim() })
    if ($explicitDependencies.Count -gt 0) {
        return $explicitDependencies
    }

    $researchPrompt = "$($Task.research_prompt)".Trim().ToLowerInvariant()
    if ($researchPrompt -and $RoadmapDependencyMap.ContainsKey($researchPrompt)) {
        return @($RoadmapDependencyMap[$researchPrompt])
    }

    return @()
}

function Get-TaskIgnoreLookup {
    param(
        [string]$TasksBaseDir,
        [array]$TodoTasks
    )

    $todoDir = Join-Path $TasksBaseDir 'todo'
    if (-not (Test-Path $todoDir)) {
        return @{}
    }

    $tasks = @{}
    $references = @{}
    $orderedTasks = [System.Collections.Generic.List[object]]::new()
    $roadmapDependencyMap = Get-IgnoreRoadmapDependencyMap -TasksBaseDir $TasksBaseDir

    if ($TodoTasks) {
        foreach ($task in @($TodoTasks)) {
            if (-not $task.id) {
                continue
            }

            $tasks[$task.id] = $task
            $null = $orderedTasks.Add($task)
        }
    } else {
        foreach ($file in @(Get-ChildItem -Path $todoDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $task = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if (-not $task.id) {
                    continue
                }

                $tasks[$task.id] = $task
                $null = $orderedTasks.Add($task)
            } catch {
                Write-BotLog -Level Warn -Message "[TaskIndex] Failed to read ignore state from '$($file.FullName)'" -Exception $_
            }
        }
    }

    $position = 0
    foreach ($task in @($orderedTasks) | Sort-Object @{ Expression = { Get-IgnoreTaskPriorityValue -Task $_ } }, @{ Expression = { $_.name } }, @{ Expression = { $_.id } }) {
        $position += 1
        Add-IgnoreReferenceAlias -ReferenceMap $references -TaskId $task.id -Alias $task.id
        Add-IgnoreReferenceAlias -ReferenceMap $references -TaskId $task.id -Alias $task.name
        $slug = (($task.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLowerInvariant())
        if ($slug) {
            Add-IgnoreReferenceAlias -ReferenceMap $references -TaskId $task.id -Alias $slug
        }
        Add-IgnoreReferenceAlias -ReferenceMap $references -TaskId $task.id -Alias $position
        Add-IgnoreReferenceAlias -ReferenceMap $references -TaskId $task.id -Alias "task $position"
    }

    $memo = @{}
    $resolving = @{}

    function Resolve-TaskIgnoreState {
        param(
            [string]$TaskId
        )

        if ($memo.ContainsKey($TaskId)) {
            return $memo[$TaskId]
        }

        if ($resolving.ContainsKey($TaskId)) {
            return [pscustomobject]@{
                task_id = $TaskId
                manual = $false
                effective = $false
                auto = $false
                blocking_task_ids = @()
                blocking_task_names = @()
                updated_at = $null
                updated_by = $null
            }
        }

        $resolving[$TaskId] = $true
        $task = $tasks[$TaskId]
        $manualIgnored = $false
        $updatedAt = $null
        $updatedBy = $null

        if ($task.PSObject.Properties['ignore']) {
            $manualIgnored = ($task.ignore.manual -eq $true)
            $updatedAt = $task.ignore.updated_at
            $updatedBy = $task.ignore.updated_by
        }

        $blockingIds = [System.Collections.Generic.List[string]]::new()
        $dependencies = Get-ResolvedIgnoreDependencies -Task $task -RoadmapDependencyMap $roadmapDependencyMap
        foreach ($dependency in $dependencies) {
            if (-not $dependency) {
                continue
            }

            $dependencyTaskIds = [System.Collections.Generic.List[string]]::new()
            foreach ($lookupKey in (Get-IgnoreDependencyTokens -Dependency $dependency)) {
                if (-not $references.ContainsKey($lookupKey)) {
                    continue
                }

                $resolvedDependencyTaskId = $references[$lookupKey]
                if (-not $tasks.ContainsKey($resolvedDependencyTaskId) -or $dependencyTaskIds.Contains($resolvedDependencyTaskId)) {
                    continue
                }

                $dependencyTaskIds.Add($resolvedDependencyTaskId)
            }

            foreach ($dependencyTaskId in $dependencyTaskIds) {
                $dependencyState = Resolve-TaskIgnoreState -TaskId $dependencyTaskId
                if (-not $dependencyState.effective) {
                    continue
                }

                if ($dependencyState.manual) {
                    if (-not $blockingIds.Contains($dependencyTaskId)) {
                        $blockingIds.Add($dependencyTaskId)
                    }
                    continue
                }

                if ($dependencyState.blocking_task_ids.Count -gt 0) {
                    foreach ($blockingTaskId in $dependencyState.blocking_task_ids) {
                        if (-not $blockingIds.Contains($blockingTaskId)) {
                            $blockingIds.Add($blockingTaskId)
                        }
                    }
                    continue
                }

                if (-not $blockingIds.Contains($dependencyTaskId)) {
                    $blockingIds.Add($dependencyTaskId)
                }
            }

        }
        $blockingNames = foreach ($blockingTaskId in $blockingIds) {
            if ($tasks.ContainsKey($blockingTaskId) -and $tasks[$blockingTaskId].name) {
                $tasks[$blockingTaskId].name
            } else {
                $blockingTaskId
            }
        }

        $state = [pscustomobject]@{
            task_id = $TaskId
            manual = $manualIgnored
            effective = ($manualIgnored -or $blockingIds.Count -gt 0)
            auto = (-not $manualIgnored -and $blockingIds.Count -gt 0)
            blocking_task_ids = @($blockingIds)
            blocking_task_names = @($blockingNames | Select-Object -Unique)
            updated_at = $updatedAt
            updated_by = $updatedBy
        }

        $memo[$TaskId] = $state
        $resolving.Remove($TaskId) | Out-Null
        return $state
    }

    $ignoreMap = @{}
    foreach ($taskId in @($tasks.Keys)) {
        $ignoreMap[$taskId] = Resolve-TaskIgnoreState -TaskId $taskId
    }

    return $ignoreMap
}

function Update-TaskIndex {
    $taskMutationModulePath = (Get-Module TaskMutation | Select-Object -ExpandProperty Path -First 1)
    $baseDir = $script:TaskIndex.BaseDir
    if (-not $baseDir) {
        Write-BotLog -Level Debug -Message "[TaskIndex] BaseDir not set, skipping update"
        return
    }

    $script:TaskIndex.Todo = @{}
    $script:TaskIndex.Analysing = @{}
    $script:TaskIndex.NeedsInput = @{}
    $script:TaskIndex.Analysed = @{}
    $script:TaskIndex.InProgress = @{}
    $script:TaskIndex.Done = @{}
    $script:TaskIndex.Split = @{}
    $script:TaskIndex.Skipped = @{}
    $script:TaskIndex.Cancelled = @{}
    $script:TaskIndex.DoneIds = @()
    $script:TaskIndex.DoneNames = @()
    $script:TaskIndex.DoneSlugs = @()
    $script:TaskIndex.IgnoreMap = @{}

    foreach ($status in @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'split', 'skipped', 'cancelled')) {
        $dir = Join-Path $baseDir $status
        if (-not (Test-Path $dir)) {
            continue
        }

        $files = Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            try {
                if (-not (Test-Path $file.FullName)) { continue }
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                $entry = [PSCustomObject]@{
                    id = $content.id
                    name = $content.name
                    description = $content.description
                    category = $content.category
                    priority = [int]$content.priority
                    effort = $content.effort
                    dependencies = $content.dependencies
                    acceptance_criteria = $content.acceptance_criteria
                    steps = $content.steps
                    applicable_agents = $content.applicable_agents
                    applicable_standards = $content.applicable_standards
                    file_path = $file.FullName
                    last_write = $file.LastWriteTimeUtc
                    started_at = $content.started_at
                    completed_at = $content.completed_at
                    needs_interview = $content.needs_interview
                    working_dir = $content.working_dir
                    external_repo = $content.external_repo
                    research_prompt = $content.research_prompt
                    ignore = $content.ignore
                    type = $content.type
                    script_path = $content.script_path
                    prompt = $content.prompt
                    mcp_tool = $content.mcp_tool
                    mcp_args = $content.mcp_args
                    skip_analysis = $content.skip_analysis
                    skip_worktree = $content.skip_worktree
                    workflow = $content.workflow
                    condition = $content.condition
                }

                switch ($status) {
                    'todo' { $script:TaskIndex.Todo[$content.id] = $entry }
                    'analysing' { $script:TaskIndex.Analysing[$content.id] = $entry }
                    'needs-input' { $script:TaskIndex.NeedsInput[$content.id] = $entry }
                    'analysed' { $script:TaskIndex.Analysed[$content.id] = $entry }
                    'in-progress' { $script:TaskIndex.InProgress[$content.id] = $entry }
                    'done' {
                        $script:TaskIndex.Done[$content.id] = $entry
                        $script:TaskIndex.DoneIds += $content.id
                        $script:TaskIndex.DoneNames += $content.name
                        # Also store slug version of name for dependency matching
                        $slug = ($content.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLowerInvariant()
                        $script:TaskIndex.DoneSlugs += $slug
                    }
                    'split' {
                        $script:TaskIndex.Split[$content.id] = $entry
                        # Split tasks satisfy dependencies — work delegated to sub-tasks
                        $script:TaskIndex.DoneIds += $content.id
                        $script:TaskIndex.DoneNames += $content.name
                        $slug = ($content.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLowerInvariant()
                        $script:TaskIndex.DoneSlugs += $slug
                    }
                    'skipped' { $script:TaskIndex.Skipped[$content.id] = $entry }
                    'cancelled' { $script:TaskIndex.Cancelled[$content.id] = $entry }
                }
            } catch {
                Write-BotLog -Level Warn -Message "[TaskIndex] Failed to read: $($file.FullName)" -Exception $_
            }
        }
    }

    # Dedup: if a task exists in multiple state directories (stale copies),
    # keep only the most advanced state to prevent double-pickup
    $seenIds = @{}
    foreach ($bucket in @(
        $script:TaskIndex.Done,
        $script:TaskIndex.Skipped,
        $script:TaskIndex.Cancelled,
        $script:TaskIndex.Split,
        $script:TaskIndex.InProgress,
        $script:TaskIndex.Analysed,
        $script:TaskIndex.NeedsInput,
        $script:TaskIndex.Analysing,
        $script:TaskIndex.Todo
    )) {
        foreach ($taskId in @($bucket.Keys)) {
            if ($seenIds.ContainsKey($taskId)) {
                $bucket.Remove($taskId)
            } else {
                $seenIds[$taskId] = $true
            }
        }
    }
    $script:TaskIndex.IgnoreMap = Get-TaskIgnoreLookup -TasksBaseDir $baseDir -TodoTasks @($script:TaskIndex.Todo.Values)
    foreach ($taskId in @($script:TaskIndex.Todo.Keys)) {
        if (-not $script:TaskIndex.IgnoreMap.ContainsKey($taskId)) {
            continue
        }

        if ($script:TaskIndex.Todo[$taskId].PSObject.Properties['ignore_state']) {
            $script:TaskIndex.Todo[$taskId].ignore_state = $script:TaskIndex.IgnoreMap[$taskId]
        } else {
            $script:TaskIndex.Todo[$taskId] | Add-Member -NotePropertyName 'ignore_state' -NotePropertyValue $script:TaskIndex.IgnoreMap[$taskId] -Force
        }
    }

    if ($taskMutationModulePath -and -not (Get-Module TaskMutation)) {
        Import-Module $taskMutationModulePath -Global -Force | Out-Null
    }
}

function Get-TaskIndex {
    # Always rebuild - no caching
    Update-TaskIndex
    return $script:TaskIndex
}

function Get-TodoTasks {
    param(
        [string]$Category,
        [string]$Effort,
        [int]$MinPriority,
        [int]$MaxPriority,
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @($index.Todo.Values)

    if ($Category) {
        $tasks = $tasks | Where-Object { $_.category -eq $Category }
    }

    if ($Effort) {
        $tasks = $tasks | Where-Object { $_.effort -eq $Effort }
    }

    if ($MinPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -ge $MinPriority }
    }

    if ($MaxPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -le $MaxPriority }
    }

    $tasks = $tasks | Sort-Object priority

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Get-InProgressTasks {
    $index = Get-TaskIndex
    return @($index.InProgress.Values)
}

function Get-AnalysingTasks {
    $index = Get-TaskIndex
    return @($index.Analysing.Values)
}

function Get-NeedsInputTasks {
    $index = Get-TaskIndex
    return @($index.NeedsInput.Values)
}

function Get-AnalysedTasks {
    param(
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @($index.Analysed.Values) | Sort-Object priority

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Get-SplitTasks {
    $index = Get-TaskIndex
    return @($index.Split.Values)
}

function Get-SkippedTasks {
    $index = Get-TaskIndex
    return @($index.Skipped.Values)
}

function Get-CancelledTasks {
    $index = Get-TaskIndex
    return @($index.Cancelled.Values)
}

function Get-DoneTasks {
    param(
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @($index.Done.Values) | Sort-Object { [DateTime]$_.completed_at } -Descending

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Get-AllTasks {
    param(
        [string]$Status,
        [string]$Category,
        [string]$Effort,
        [int]$MinPriority,
        [int]$MaxPriority,
        [int]$Limit = 0
    )

    $index = Get-TaskIndex
    $tasks = @()

    # Determine which collections to include
    if (-not $Status -or $Status -eq 'todo') {
        $tasks += @($index.Todo.Values)
    }
    if (-not $Status -or $Status -eq 'analysing') {
        $tasks += @($index.Analysing.Values)
    }
    if (-not $Status -or $Status -eq 'needs-input') {
        $tasks += @($index.NeedsInput.Values)
    }
    if (-not $Status -or $Status -eq 'analysed') {
        $tasks += @($index.Analysed.Values)
    }
    if (-not $Status -or $Status -eq 'in-progress') {
        $tasks += @($index.InProgress.Values)
    }
    if (-not $Status -or $Status -eq 'done') {
        $tasks += @($index.Done.Values)
    }
    if (-not $Status -or $Status -eq 'split') {
        $tasks += @($index.Split.Values)
    }
    if (-not $Status -or $Status -eq 'skipped') {
        $tasks += @($index.Skipped.Values)
    }
    if (-not $Status -or $Status -eq 'cancelled') {
        $tasks += @($index.Cancelled.Values)
    }

    # Apply filters
    if ($Category) {
        $tasks = $tasks | Where-Object { $_.category -eq $Category }
    }

    if ($Effort) {
        $tasks = $tasks | Where-Object { $_.effort -eq $Effort }
    }

    if ($MinPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -ge $MinPriority }
    }

    if ($MaxPriority -gt 0) {
        $tasks = $tasks | Where-Object { $_.priority -le $MaxPriority }
    }

    $tasks = $tasks | Sort-Object priority

    if ($Limit -gt 0) {
        $tasks = $tasks | Select-Object -First $Limit
    }

    return @($tasks)
}

function Test-DependencyMet {
    param(
        [string]$Dependency,
        [array]$DoneNames,
        [array]$DoneSlugs,
        [array]$DoneIds
    )
    
    $depLower = $Dependency.ToLowerInvariant()
    
    # Exact match on ID
    if ($Dependency -in $DoneIds) { return $true }
    
    # Exact match on name
    if ($Dependency -in $DoneNames) { return $true }
    
    # Exact match on slug
    if ($depLower -in $DoneSlugs) { return $true }
    
    # No fuzzy matching - dependencies must be exact
    # If a dependency doesn't exist, the task should not proceed
    return $false
}

function Test-AllDependenciesMet {
    param(
        [object]$Task,
        [array]$DoneNames,
        [array]$DoneSlugs,
        [array]$DoneIds
    )

    if (-not $Task.dependencies -or $Task.dependencies.Count -eq 0) {
        return $true
    }
    # Handle both string and array dependencies
    $deps = if ($Task.dependencies -is [array]) { $Task.dependencies } else { @($Task.dependencies) }
    $unmet = $deps | Where-Object {
        -not (Test-DependencyMet -Dependency $_ -DoneNames $DoneNames -DoneSlugs $DoneSlugs -DoneIds $DoneIds)
    }
    return $unmet.Count -eq 0
}

function Get-NextTask {
    param([string]$WorkflowFilter)
    $index = Get-TaskIndex
    $doneNames = $index.DoneNames
    $doneSlugs = $index.DoneSlugs
    $doneIds = $index.DoneIds

    # Filter tasks with unmet dependencies or effective ignore state
    $eligible = @($index.Todo.Values) | Where-Object {
        $ignoreState = if ($index.IgnoreMap.ContainsKey($_.id)) { $index.IgnoreMap[$_.id] } else { $null }
        (-not $ignoreState -or -not $ignoreState.effective) -and
        (Test-AllDependenciesMet -Task $_ -DoneNames $doneNames -DoneSlugs $doneSlugs -DoneIds $doneIds)
    }

    # Apply workflow filter if specified
    if ($WorkflowFilter) {
        $eligible = @($eligible | Where-Object { $_.workflow -eq $WorkflowFilter })
    }

    # Return highest priority (lowest number)
    return $eligible | Sort-Object priority | Select-Object -First 1
}

function Get-NextAnalysedTask {
    param([string]$WorkflowFilter)
    $index = Get-TaskIndex
    $doneNames = $index.DoneNames
    $doneSlugs = $index.DoneSlugs
    $doneIds = $index.DoneIds

    # Filter analysed tasks with unmet dependencies or effective ignore state
    $eligible = @($index.Analysed.Values) | Where-Object {
        $ignoreState = if ($index.IgnoreMap.ContainsKey($_.id)) { $index.IgnoreMap[$_.id] } else { $null }
        (-not $ignoreState -or -not $ignoreState.effective) -and
        (Test-AllDependenciesMet -Task $_ -DoneNames $doneNames -DoneSlugs $doneSlugs -DoneIds $doneIds)
    }

    # Apply workflow filter if specified
    if ($WorkflowFilter) {
        $eligible = @($eligible | Where-Object { $_.workflow -eq $WorkflowFilter })
    }

    $total = @($index.Analysed.Values).Count
    $blockedCount = $total - @($eligible).Count

    # Return highest priority (lowest number) + blocked count for reporting
    $next = $eligible | Sort-Object priority | Select-Object -First 1
    return @{
        Task = $next
        BlockedCount = $blockedCount
        TotalCount = $total
    }
}

function Get-DeadlockedTasks {
    <#
    .SYNOPSIS
    Returns info about todo tasks that are blocked by at least one skipped dependency.

    .DESCRIPTION
    Called when Get-NextTask returns null to distinguish a dependency deadlock from a
    genuine wait (e.g. analysis still running). Returns a PSCustomObject with BlockedCount
    (number of blocked todo tasks) and BlockerNames (skipped task names causing the block).
    #>

    $index = Get-TaskIndex
    if ($index.Todo.Count   -eq 0) { return [PSCustomObject]@{ BlockedCount = 0; BlockerNames = @() } }
    if ($index.Skipped.Count -eq 0) { return [PSCustomObject]@{ BlockedCount = 0; BlockerNames = @() } }

    # Build a case-insensitive lookup set covering id, name, and slug of every
    # skipped task so dependency strings can be matched in one Contains() call.
    $skippedLookup = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    # Map from any form (id/name/slug) back to the task name for reporting.
    $skippedNameMap = @{}
    foreach ($t in $index.Skipped.Values) {
        $skippedLookup.Add($t.id)   | Out-Null
        $skippedLookup.Add($t.name) | Out-Null
        $slug = ($t.name -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLowerInvariant()
        $skippedLookup.Add($slug)   | Out-Null
        $skippedNameMap[$t.id]   = $t.name
        $skippedNameMap[$t.name] = $t.name
        $skippedNameMap[$slug]   = $t.name
    }

    $count = 0
    $blockerNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($task in $index.Todo.Values) {
        $deps = if     ($task.dependencies -is [array]) { @($task.dependencies) }
                elseif ($task.dependencies)              { @($task.dependencies) }
                else                                     { @() }

        foreach ($dep in $deps) {
            if (-not $dep) { continue }

            # If the dependency is already satisfied by a done/split task, skip it.
            if (Test-DependencyMet -Dependency $dep `
                    -DoneNames $index.DoneNames `
                    -DoneSlugs $index.DoneSlugs `
                    -DoneIds   $index.DoneIds) { continue }

            # The dependency is unmet — is the blocker a skipped task?
            if ($skippedLookup.Contains($dep)) {
                $count++
                $blockerNames.Add($skippedNameMap[$dep]) | Out-Null
                break  # count each blocked task only once
            }
        }
    }

    return [PSCustomObject]@{ BlockedCount = $count; BlockerNames = @($blockerNames | Sort-Object) }
}

function Test-TaskDone {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )

    $index = Get-TaskIndex
    return $TaskId -in $index.DoneIds
}

function Get-TaskById {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId
    )

    $index = Get-TaskIndex

    if ($index.Todo.ContainsKey($TaskId)) {
        return $index.Todo[$TaskId]
    }
    if ($index.Analysing.ContainsKey($TaskId)) {
        return $index.Analysing[$TaskId]
    }
    if ($index.NeedsInput.ContainsKey($TaskId)) {
        return $index.NeedsInput[$TaskId]
    }
    if ($index.Analysed.ContainsKey($TaskId)) {
        return $index.Analysed[$TaskId]
    }
    if ($index.InProgress.ContainsKey($TaskId)) {
        return $index.InProgress[$TaskId]
    }
    if ($index.Done.ContainsKey($TaskId)) {
        return $index.Done[$TaskId]
    }
    if ($index.Split.ContainsKey($TaskId)) {
        return $index.Split[$TaskId]
    }
    if ($index.Skipped.ContainsKey($TaskId)) {
        return $index.Skipped[$TaskId]
    }
    if ($index.Cancelled.ContainsKey($TaskId)) {
        return $index.Cancelled[$TaskId]
    }

    return $null
}

function Get-TaskStats {
    $index = Get-TaskIndex

    $stats = @{
        total = $index.Todo.Count + $index.Analysing.Count + $index.NeedsInput.Count + $index.Analysed.Count + $index.InProgress.Count + $index.Done.Count + $index.Split.Count + $index.Skipped.Count + $index.Cancelled.Count
        todo = $index.Todo.Count
        analysing = $index.Analysing.Count
        needs_input = $index.NeedsInput.Count
        analysed = $index.Analysed.Count
        in_progress = $index.InProgress.Count
        done = $index.Done.Count
        split = $index.Split.Count
        skipped = $index.Skipped.Count
        cancelled = $index.Cancelled.Count
        by_category = @{}
        by_effort = @{}
        by_priority_range = @{
            high = 0      # 1-20
            medium = 0    # 21-50
            low = 0       # 51-100
        }
    }

    $allTasks = @($index.Todo.Values) + @($index.Analysing.Values) + @($index.NeedsInput.Values) + @($index.Analysed.Values) + @($index.InProgress.Values) + @($index.Done.Values) + @($index.Skipped.Values) + @($index.Cancelled.Values)

    foreach ($task in $allTasks) {
        # Count by category
        if ($task.category) {
            if (-not $stats.by_category[$task.category]) {
                $stats.by_category[$task.category] = 0
            }
            $stats.by_category[$task.category]++
        }

        # Count by effort
        if ($task.effort) {
            if (-not $stats.by_effort[$task.effort]) {
                $stats.by_effort[$task.effort] = 0
            }
            $stats.by_effort[$task.effort]++
        }

        # Count by priority range
        if ($task.priority) {
            $priority = [int]$task.priority
            if ($priority -le 20) {
                $stats.by_priority_range.high++
            } elseif ($priority -le 50) {
                $stats.by_priority_range.medium++
            } else {
                $stats.by_priority_range.low++
            }
        }
    }

    return $stats
}

function Get-RemainingEffort {
    $index = Get-TaskIndex

    $effort_mapping = @{
        'XS' = 1
        'S' = 2.5
        'M' = 5
        'L' = 10
        'XL' = 15
    }

    $days_remaining = 0
    # Include all tasks that still need work (not done or split)
    $allRemaining = @($index.Todo.Values) + @($index.Analysing.Values) + @($index.NeedsInput.Values) + @($index.Analysed.Values) + @($index.InProgress.Values)

    foreach ($task in $allRemaining) {
        if ($task.effort -and $effort_mapping[$task.effort]) {
            $days_remaining += $effort_mapping[$task.effort]
        } else {
            $days_remaining += 5  # Default to M if not specified
        }
    }

    return [Math]::Round($days_remaining, 1)
}

# Keep for backwards compatibility but now a no-op
function Reset-TaskIndex {
    # No-op - index is always fresh
}

# Keep for backwards compatibility but now a no-op
function Stop-TaskIndexWatcher {
    # No-op - no watcher to stop
}

Export-ModuleMember -Function @(
    'Initialize-TaskIndex',
    'Update-TaskIndex',
    'Get-TaskIndex',
    'Get-TodoTasks',
    'Get-AnalysingTasks',
    'Get-NeedsInputTasks',
    'Get-AnalysedTasks',
    'Get-InProgressTasks',
    'Get-DoneTasks',
    'Get-SplitTasks',
    'Get-SkippedTasks',
    'Get-CancelledTasks',
    'Get-AllTasks',
    'Get-NextTask',
    'Get-NextAnalysedTask',
    'Get-DeadlockedTasks',
    'Test-TaskDone',
    'Test-DependencyMet',
    'Test-AllDependenciesMet',
    'Get-TaskById',
    'Get-TaskStats',
    'Get-RemainingEffort',
    'Reset-TaskIndex',
    'Stop-TaskIndexWatcher'
)





