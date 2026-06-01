function Invoke-TaskCreateBulk {
    param([hashtable]$Arguments)

    if (-not $Arguments.ContainsKey('tasks') -or -not $Arguments['tasks']) {
        throw "task_create_bulk requires a non-empty tasks array."
    }

    $actor = Get-McpActor
    $parentTask = Get-CurrentWorkflowTaskForBulkCreate
    $created = @()

    foreach ($rawTask in @($Arguments['tasks'])) {
        $task = ConvertTo-PlainHashtable -Value $rawTask
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
