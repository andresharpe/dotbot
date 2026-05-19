<#
.SYNOPSIS
v4 WorkflowRun schema validation + builder.

Canonical PRD: docs/prds/PRD-01-data-model.md §Implementation Decisions.

WorkflowRun is split into two records on disk:

  - Committed (immutable provenance) — workspace/tasks/workflow-runs/<dir>/run.json
      run_id, workflow_name, started_at, isolated, branch_name, worktree_path,
      task_ids, task_definitions, started_by, schema_version

  - Gitignored (live, churning state) — .control/workflow-runs/<wr_id>.json
      status, completed_at, last_heartbeat, current_task_id, error

This module validates each shape independently. They share a run_id so the
runtime can reconcile them at lookup time.

Depends on Dotbot.Task's v4 IdGen (Test-TaskId, Test-WorkflowRunId,
New-WorkflowRunId). Callers should Import-Module Dotbot.Task before this
module; the manifest does this implicitly because consumers always go through
the Dotbot.Workflow manifest which is documented to require Dotbot.Task.
#>

$script:DotbotWorkflowRunSchemaVersion = 1

$script:DotbotRunRecordFields = @(
    'schema_version',
    'run_id',
    'workflow_name',
    'started_at',
    'isolated',
    'branch_name',
    'worktree_path',
    'task_ids',
    'task_definitions',
    'started_by'
)

$script:DotbotRunRecordRequired = @(
    'schema_version',
    'run_id',
    'workflow_name',
    'started_at',
    'isolated',
    'task_ids',
    'started_by'
)

# Live-status record shape
$script:DotbotRunStatusFields = @(
    'schema_version',
    'run_id',
    'status',
    'completed_at',
    'last_heartbeat',
    'current_task_id',
    'error'
)

$script:DotbotRunStatusRequired = @(
    'schema_version',
    'run_id',
    'status'
)

$script:DotbotRunStatusValues = @('running', 'completed', 'failed', 'cancelled')

$script:DotbotTimestampRegex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'

function _Get-Prop {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $null }
    if ($Bag -is [System.Collections.IDictionary]) {
        if ($Bag.Contains($Name)) { return $Bag[$Name] }
        return $null
    }
    $prop = $Bag.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function _Has-Prop {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $false }
    if ($Bag -is [System.Collections.IDictionary]) { return $Bag.Contains($Name) }
    return $null -ne $Bag.PSObject.Properties[$Name]
}

function _Get-Keys {
    param($Bag)
    if ($null -eq $Bag) { return @() }
    if ($Bag -is [System.Collections.IDictionary]) { return @($Bag.Keys) }
    return @($Bag.PSObject.Properties.Name)
}

function Get-WorkflowRunSchemaVersion {
    return $script:DotbotWorkflowRunSchemaVersion
}

function Get-WorkflowRunRecordFields {
    return ,@($script:DotbotRunRecordFields)
}

function Get-WorkflowRunStatusFields {
    return ,@($script:DotbotRunStatusFields)
}

function Get-WorkflowRunStatuses {
    return ,@($script:DotbotRunStatusValues)
}

function Test-WorkflowRunRecord {
    <#
    .SYNOPSIS
    Validate the committed-immutable run.json shape. Returns array of errors.
    #>
    param(
        [Parameter(Mandatory)]
        $Record
    )

    $errors = [System.Collections.ArrayList]::new()

    if ($null -eq $Record) {
        [void]$errors.Add('run_record: is null')
        return ,@($errors.ToArray())
    }
    if ($Record -isnot [System.Collections.IDictionary] -and $Record -isnot [PSCustomObject]) {
        [void]$errors.Add('run_record: must be a hashtable or object')
        return ,@($errors.ToArray())
    }

    foreach ($k in (_Get-Keys $Record)) {
        if ($script:DotbotRunRecordFields -notcontains $k) {
            [void]$errors.Add("$k`: is not a known WorkflowRun record field")
        }
    }

    foreach ($f in $script:DotbotRunRecordRequired) {
        if (-not (_Has-Prop $Record $f)) {
            [void]$errors.Add("$f`: is required")
        }
    }

    $sv = _Get-Prop $Record 'schema_version'
    if ($null -ne $sv -and $sv -ne $script:DotbotWorkflowRunSchemaVersion) {
        [void]$errors.Add("schema_version: must be $($script:DotbotWorkflowRunSchemaVersion) (got '$sv')")
    }

    $runId = _Get-Prop $Record 'run_id'
    if ($runId -and -not (Test-WorkflowRunId -Id $runId)) {
        [void]$errors.Add("run_id: must match 'wr_' + 8 chars [A-Za-z0-9] (got '$runId')")
    }

    $workflowName = _Get-Prop $Record 'workflow_name'
    if ($null -ne $workflowName -and ($workflowName -isnot [string] -or [string]::IsNullOrWhiteSpace($workflowName))) {
        [void]$errors.Add('workflow_name: must be a non-empty string')
    }

    $startedAt = _Get-Prop $Record 'started_at'
    if ($null -ne $startedAt) {
        # ConvertFrom-Json auto-converts ISO-shaped strings to [datetime] in
        # PS 7 even with -AsHashtable; accept both forms.
        $ok = ($startedAt -is [datetime]) -or ($startedAt -is [string] -and $startedAt -match $script:DotbotTimestampRegex)
        if (-not $ok) {
            [void]$errors.Add("started_at: must be an RFC3339-Z timestamp, got '$startedAt'")
        }
    }

    $isolated = _Get-Prop $Record 'isolated'
    if ($null -ne $isolated -and $isolated -isnot [bool]) {
        [void]$errors.Add('isolated: must be a boolean')
    }

    foreach ($strField in 'branch_name','worktree_path','started_by') {
        $v = _Get-Prop $Record $strField
        if ($null -ne $v -and $v -isnot [string]) {
            [void]$errors.Add("$strField`: must be a string")
        }
    }

    # task_ids — required, array of canonical task IDs.
    # PowerShell unwraps single-element arrays through both function returns AND
    # if-expressions, so we read via direct indexer with no if-expression wrapper.
    if (_Has-Prop $Record 'task_ids') {
        if ($Record -is [System.Collections.IDictionary]) {
            $taskIdsRaw = $Record['task_ids']
        } else {
            $taskIdsRaw = $Record.task_ids
        }
        if ($null -eq $taskIdsRaw) {
            [void]$errors.Add('task_ids: must be an array of task IDs (got null)')
        } elseif ($taskIdsRaw -is [string]) {
            [void]$errors.Add('task_ids: must be an array of task IDs, not a single string')
        } else {
            $taskIds = @($taskIdsRaw)
            $i = 0
            foreach ($tid in $taskIds) {
                if (-not (Test-TaskId -Id $tid)) {
                    [void]$errors.Add("task_ids[$i]: must be a canonical task ID (got '$tid')")
                }
                $i++
            }
        }
    }

    # task_definitions — optional but if present must be an array.
    if (_Has-Prop $Record 'task_definitions') {
        if ($Record -is [System.Collections.IDictionary]) {
            $taskDefsRaw = $Record['task_definitions']
        } else {
            $taskDefsRaw = $Record.task_definitions
        }
        if ($null -ne $taskDefsRaw -and $taskDefsRaw -is [string]) {
            [void]$errors.Add('task_definitions: must be an array of TaskDefinition records')
        }
        # Per-element validation is handled by TaskDefinition.psm1 when callers
        # want it; the run record's job is to capture the array verbatim.
    }

    return ,@($errors.ToArray())
}

function Assert-WorkflowRunRecord {
    <#
    .SYNOPSIS
    Throw if the committed-immutable run.json shape is invalid.
    #>
    param([Parameter(Mandatory)] $Record)
    $errs = Test-WorkflowRunRecord -Record $Record
    if ($errs -and $errs.Count -gt 0) {
        throw "Invalid WorkflowRun record:`n  - $($errs -join "`n  - ")"
    }
}

function Test-WorkflowRunStatus {
    <#
    .SYNOPSIS
    Validate the gitignored live-status record shape. Returns array of errors.
    #>
    param(
        [Parameter(Mandatory)]
        $Status
    )

    $errors = [System.Collections.ArrayList]::new()

    if ($null -eq $Status) {
        [void]$errors.Add('run_status: is null')
        return ,@($errors.ToArray())
    }
    if ($Status -isnot [System.Collections.IDictionary] -and $Status -isnot [PSCustomObject]) {
        [void]$errors.Add('run_status: must be a hashtable or object')
        return ,@($errors.ToArray())
    }

    foreach ($k in (_Get-Keys $Status)) {
        if ($script:DotbotRunStatusFields -notcontains $k) {
            [void]$errors.Add("$k`: is not a known WorkflowRun status field")
        }
    }

    foreach ($f in $script:DotbotRunStatusRequired) {
        if (-not (_Has-Prop $Status $f)) {
            [void]$errors.Add("$f`: is required")
        }
    }

    $sv = _Get-Prop $Status 'schema_version'
    if ($null -ne $sv -and $sv -ne $script:DotbotWorkflowRunSchemaVersion) {
        [void]$errors.Add("schema_version: must be $($script:DotbotWorkflowRunSchemaVersion) (got '$sv')")
    }

    $runId = _Get-Prop $Status 'run_id'
    if ($runId -and -not (Test-WorkflowRunId -Id $runId)) {
        [void]$errors.Add("run_id: must match 'wr_' + 8 chars [A-Za-z0-9] (got '$runId')")
    }

    $statusValue = _Get-Prop $Status 'status'
    if ($null -ne $statusValue -and $script:DotbotRunStatusValues -notcontains $statusValue) {
        [void]$errors.Add("status: must be one of: $($script:DotbotRunStatusValues -join ', ') (got '$statusValue')")
    }

    $completedAt = _Get-Prop $Status 'completed_at'
    if ($null -ne $completedAt) {
        $ok = ($completedAt -is [datetime]) -or ($completedAt -is [string] -and $completedAt -match $script:DotbotTimestampRegex)
        if (-not $ok) {
            [void]$errors.Add("completed_at: must be null or an RFC3339-Z timestamp, got '$completedAt'")
        }
    }
    $heartbeat = _Get-Prop $Status 'last_heartbeat'
    if ($null -ne $heartbeat) {
        $ok = ($heartbeat -is [datetime]) -or ($heartbeat -is [string] -and $heartbeat -match $script:DotbotTimestampRegex)
        if (-not $ok) {
            [void]$errors.Add("last_heartbeat: must be null or an RFC3339-Z timestamp, got '$heartbeat'")
        }
    }

    $currentTask = _Get-Prop $Status 'current_task_id'
    if ($null -ne $currentTask -and $currentTask -ne '' -and -not (Test-TaskId -Id $currentTask)) {
        [void]$errors.Add("current_task_id: must be null or a canonical task ID (got '$currentTask')")
    }

    # terminal status requires completed_at
    $terminal = @('completed','failed','cancelled')
    if ($statusValue -and $terminal -contains $statusValue -and $null -eq $completedAt) {
        [void]$errors.Add("completed_at: must be set when status is terminal ('$statusValue')")
    }

    return ,@($errors.ToArray())
}

function Assert-WorkflowRunStatus {
    param([Parameter(Mandatory)] $Status)
    $errs = Test-WorkflowRunStatus -Status $Status
    if ($errs -and $errs.Count -gt 0) {
        throw "Invalid WorkflowRun status record:`n  - $($errs -join "`n  - ")"
    }
}

function New-WorkflowRunRecord {
    <#
    .SYNOPSIS
    Build a v4 WorkflowRun committed record (run.json) with defaults, then validate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkflowName,

        [Parameter(Mandatory)]
        [string]$StartedBy,

        [bool]$Isolated = $true,

        $BranchName = $null,

        $WorktreePath = $null,

        [string[]]$TaskIds = @(),

        $TaskDefinitions = $null,

        [string]$RunId,

        [string]$StartedAt
    )

    if (-not $RunId) { $RunId = New-WorkflowRunId }
    if (-not $StartedAt) {
        $StartedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    }

    foreach ($tid in $TaskIds) {
        if (-not (Test-TaskId -Id $tid)) {
            throw "New-WorkflowRunRecord: '$tid' is not a canonical task ID."
        }
    }

    $record = [ordered]@{
        schema_version   = $script:DotbotWorkflowRunSchemaVersion
        run_id           = $RunId
        workflow_name    = $WorkflowName
        started_at       = $StartedAt
        isolated         = [bool]$Isolated
        branch_name      = $BranchName
        worktree_path    = $WorktreePath
        task_ids         = @($TaskIds)
        task_definitions = if ($null -ne $TaskDefinitions) { @($TaskDefinitions) } else { @() }
        started_by       = $StartedBy
    }

    Assert-WorkflowRunRecord -Record $record
    return $record
}

function New-WorkflowRunStatus {
    <#
    .SYNOPSIS
    Build a v4 WorkflowRun live-status record (.control/.../wr_<id>.json) with defaults.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunId,

        [string]$Status = 'running',

        # Untyped so unbound parameters stay $null instead of degrading to ''.
        # The validator differentiates "absent" from "empty string" and would
        # otherwise reject defaulted empty timestamps.
        $CurrentTaskId = $null,

        $CompletedAt = $null,

        $LastHeartbeat = $null,

        $Error = $null
    )

    if (-not (Test-WorkflowRunId -Id $RunId)) {
        throw "New-WorkflowRunStatus: '$RunId' is not a canonical workflow-run ID."
    }

    $rec = [ordered]@{
        schema_version  = $script:DotbotWorkflowRunSchemaVersion
        run_id          = $RunId
        status          = $Status
        completed_at    = $CompletedAt
        last_heartbeat  = $LastHeartbeat
        current_task_id = $CurrentTaskId
        error           = $Error
    }

    Assert-WorkflowRunStatus -Status $rec
    return $rec
}

Export-ModuleMember -Function @(
    'Get-WorkflowRunSchemaVersion'
    'Get-WorkflowRunRecordFields'
    'Get-WorkflowRunStatusFields'
    'Get-WorkflowRunStatuses'
    'Test-WorkflowRunRecord'
    'Assert-WorkflowRunRecord'
    'Test-WorkflowRunStatus'
    'Assert-WorkflowRunStatus'
    'New-WorkflowRunRecord'
    'New-WorkflowRunStatus'
)
