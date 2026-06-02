function Invoke-TaskCreateBulk {
    param([hashtable]$Arguments)

    if (-not $Arguments.ContainsKey('tasks') -or -not $Arguments['tasks']) {
        throw "task_create_bulk requires a non-empty tasks array."
    }

    $actor = Get-McpActor
    $parentTask = Get-CurrentWorkflowTaskForBulkCreate
    $rawTasks = @($Arguments['tasks'] | ForEach-Object { ConvertTo-PlainHashtable -Value $_ })
    Assert-BulkTaskDependenciesResolvable -Tasks $rawTasks

    $knownTasks = New-BulkTaskDependencyIndex
    $created = @()

    foreach ($task in $rawTasks) {
        if (-not $task.ContainsKey('name') -or [string]::IsNullOrWhiteSpace([string]$task['name'])) {
            throw "task_create_bulk task is missing required field 'name'."
        }

        $body = @{
            actor = $actor
        }

        foreach ($key in @(
            'name', 'description', 'category', 'priority', 'effort', 'type',
            'status', 'dependencies', 'acceptance_criteria', 'outputs',
            'needs_review'
        )) {
            if ($task.ContainsKey($key) -and $null -ne $task[$key]) {
                $body[$key] = $task[$key]
            }
        }

        if ($body.ContainsKey('dependencies')) {
            $body['dependencies'] = Resolve-BulkTaskDependencies -Dependencies $body['dependencies'] -KnownTasks $knownTasks
        }

        $extensions = if ($task.ContainsKey('extensions') -and $task['extensions']) {
            ConvertTo-PlainHashtable -Value $task['extensions']
        } else {
            @{}
        }

        $workflowExt = if ($extensions.ContainsKey('workflow') -and $extensions['workflow']) {
            ConvertTo-PlainHashtable -Value $extensions['workflow']
        } else {
            @{}
        }

        foreach ($key in @(
            'group_id', 'applicable_decisions', 'human_hours', 'ai_hours',
            'steps', 'applicable_standards', 'applicable_agents',
            'applicable_skills', 'needs_interview'
        )) {
            if ($task.ContainsKey($key) -and $null -ne $task[$key]) {
                $workflowExt[$key] = $task[$key]
            }
        }

        if ($workflowExt.Count -gt 0) {
            $extensions['workflow'] = $workflowExt
        }

        $runnerExt = if ($extensions.ContainsKey('runner') -and $extensions['runner']) {
            ConvertTo-PlainHashtable -Value $extensions['runner']
        } else {
            @{}
        }
        if ($parentTask -and $parentTask.id) {
            if (-not $runnerExt.ContainsKey('parent_task_id')) { $runnerExt['parent_task_id'] = [string]$parentTask.id }
            if (-not $runnerExt.ContainsKey('generated_by')) { $runnerExt['generated_by'] = [string]$parentTask.id }
        }
        if ($runnerExt.Count -gt 0) {
            $extensions['runner'] = $runnerExt
        }

        if ($extensions.Count -gt 0) {
            $body['extensions'] = $extensions
        }

        if ($task.ContainsKey('provenance') -and $task['provenance']) {
            $body['provenance'] = ConvertTo-PlainHashtable -Value $task['provenance']
        } else {
            $inferred = Get-InferredBulkTaskProvenance -ParentTask $parentTask -TaskName ([string]$task['name'])
            if ($inferred) { $body['provenance'] = $inferred }
        }

        $resp = Invoke-McpRuntimeRequest -Method POST -Path '/tasks' -Body $body
        $created += [pscustomobject]@{
            id   = $resp.task.id
            name = $resp.task.name
            path = $resp.path
            task = $resp.task
        }
        Add-BulkTaskDependencyAlias -KnownTasks $knownTasks -TaskId ([string]$resp.task.id) -TaskName ([string]$resp.task.name)
    }

    return @{
        success = $true
        count = $created.Count
        tasks = $created
        created_tasks = @($created | ForEach-Object {
            [pscustomobject]@{ id = $_.id; name = $_.name; path = $_.path }
        })
    }
}

function Assert-BulkTaskDependenciesResolvable {
    param([array]$Tasks)

    $seen = New-BulkTaskDependencyIndex

    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        $task = $Tasks[$i]
        $name = if ($task.ContainsKey('name')) { [string]$task['name'] } else { '' }
        if ($task.ContainsKey('dependencies') -and $task['dependencies']) {
            foreach ($dep in @($task['dependencies'])) {
                $depText = [string]$dep
                if ([string]::IsNullOrWhiteSpace($depText) -or (Test-CanonicalTaskId -Value $depText)) {
                    continue
                }
                if (Find-BulkTaskDependencyId -Dependency $depText -KnownTasks $seen) {
                    continue
                }

                Add-ExistingBulkTaskDependenciesIfNeeded -KnownTasks $seen
                if (Find-BulkTaskDependencyId -Dependency $depText -KnownTasks $seen) {
                    continue
                }

                throw "task_create_bulk dependency '$depText' for task '$name' cannot be resolved. Use an existing task id/name or the exact name of an earlier task in this same bulk call."
            }
        }
        if ($name) {
            Add-BulkTaskDependencyAlias -KnownTasks $seen -TaskId "__pending_$i" -TaskName $name
        }
    }
}

function New-BulkTaskDependencyIndex {
    @{
        by_id = @{}
        by_name = @{}
        by_slug = @{}
        existing_loaded = $false
    }
}

function Add-BulkTaskDependencyAlias {
    param(
        [Parameter(Mandatory)][hashtable]$KnownTasks,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$TaskName
    )

    if ([string]::IsNullOrWhiteSpace($TaskId) -or [string]::IsNullOrWhiteSpace($TaskName)) { return }

    $KnownTasks['by_id'][$TaskId] = $TaskId
    $KnownTasks['by_name'][$TaskName] = $TaskId
    $slug = ConvertTo-BulkTaskSlug -Value $TaskName
    if ($slug) { $KnownTasks['by_slug'][$slug] = $TaskId }
}

function Resolve-BulkTaskDependencies {
    param(
        $Dependencies,
        [Parameter(Mandatory)][hashtable]$KnownTasks
    )

    $resolved = @()
    foreach ($dep in @($Dependencies)) {
        $depText = [string]$dep
        if ([string]::IsNullOrWhiteSpace($depText)) { continue }
        if (Test-CanonicalTaskId -Value $depText) {
            $resolved += $depText
            continue
        }

        $resolvedId = Find-BulkTaskDependencyId -Dependency $depText -KnownTasks $KnownTasks
        if (-not $resolvedId) {
            Add-ExistingBulkTaskDependenciesIfNeeded -KnownTasks $KnownTasks
            $resolvedId = Find-BulkTaskDependencyId -Dependency $depText -KnownTasks $KnownTasks
        }
        if (-not $resolvedId) {
            throw "task_create_bulk dependency '$depText' cannot be resolved to a task ID."
        }
        $resolved += $resolvedId
    }
    return ,$resolved
}

function Find-BulkTaskDependencyId {
    param(
        [Parameter(Mandatory)][string]$Dependency,
        [Parameter(Mandatory)][hashtable]$KnownTasks
    )

    if ($KnownTasks['by_id'].ContainsKey($Dependency)) { return $KnownTasks['by_id'][$Dependency] }
    if ($KnownTasks['by_name'].ContainsKey($Dependency)) { return $KnownTasks['by_name'][$Dependency] }

    $slug = ConvertTo-BulkTaskSlug -Value $Dependency
    if ($slug -and $KnownTasks['by_slug'].ContainsKey($slug)) { return $KnownTasks['by_slug'][$slug] }

    if ($slug) {
        foreach ($knownSlug in @($KnownTasks['by_slug'].Keys)) {
            if ($knownSlug.Contains($slug) -or $slug.Contains($knownSlug)) {
                return $KnownTasks['by_slug'][$knownSlug]
            }
        }
    }

    return $null
}

function Add-ExistingBulkTaskDependenciesIfNeeded {
    param([Parameter(Mandatory)][hashtable]$KnownTasks)

    if ($KnownTasks['existing_loaded']) { return }
    $KnownTasks['existing_loaded'] = $true

    try {
        $resp = Invoke-McpRuntimeRequest -Method GET -Path '/tasks'
        foreach ($task in @($resp.tasks)) {
            if ($task -and $task.id -and $task.name) {
                Add-BulkTaskDependencyAlias -KnownTasks $KnownTasks -TaskId ([string]$task.id) -TaskName ([string]$task.name)
            }
        }
    } catch {
        # Existing-task lookup is best-effort. Canonical IDs and earlier tasks in
        # the same bulk call still work without a task-list round trip.
    }
}

function ConvertTo-BulkTaskSlug {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').Trim('-').ToLowerInvariant())
}

function Test-CanonicalTaskId {
    param([string]$Value)
    return ($Value -cmatch '^t_[A-Za-z0-9]{8}$')
}

function ConvertTo-PlainHashtable {
    param($Value)

    if ($null -eq $Value) { return @{} }
    if ($Value -is [hashtable]) { return $Value.Clone() }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $Value.Keys) { $out[[string]$key] = $Value[$key] }
        return $out
    }
    if ($Value -is [pscustomobject]) {
        $out = @{}
        foreach ($prop in $Value.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
        return $out
    }
    throw "Expected object/hashtable, got $($Value.GetType().FullName)."
}

function Get-CurrentWorkflowTaskForBulkCreate {
    $taskId = [Environment]::GetEnvironmentVariable('DOTBOT_CURRENT_TASK_ID')
    if ([string]::IsNullOrWhiteSpace($taskId) -or $taskId -notmatch '^t_[A-Za-z0-9]{8}$') {
        return $null
    }

    try {
        $ctx = Invoke-McpRuntimeRequest -Method GET -Path "/tasks/$taskId/context"
        if ($ctx -and $ctx.task) { return $ctx.task }
    } catch {
        return $null
    }
    return $null
}

function Get-InferredBulkTaskProvenance {
    param(
        $ParentTask,
        [Parameter(Mandatory)][string]$TaskName
    )

    if (-not $ParentTask -or -not $ParentTask.provenance) { return $null }
    $parentProvenance = $ParentTask.provenance
    if (-not $parentProvenance.run_id -or -not $parentProvenance.workflow -or -not $ParentTask.id) {
        return $null
    }

    return @{
        workflow = [string]$parentProvenance.workflow
        run_id = [string]$parentProvenance.run_id
        definition_name = $TaskName
        expanded_by = "task:$($ParentTask.id)"
    }
}
