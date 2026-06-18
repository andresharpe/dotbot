<#
.SYNOPSIS
TaskInstance schema: closed shape, write-time validation, builder.

The TaskInstance shape is closed: a fixed set of core fields plus a namespaced
'extensions' object for everything else. Unknown top-level fields are rejected.

Depends on IdGen.psm1 (Test-TaskId, Test-WorkflowRunId) and Transitions.psm1
(Test-TaskStatus, Get-TaskStatuses). When loaded as a nested module from
Dotbot.Task.psd1 those siblings are already in the same session state, so we
don't Import-Module them here.
#>

$script:DotbotTaskInstanceSchemaVersion = 2

# Closed top-level field set. Anything outside this list raises a validation
# error on write — that's the whole point of having a closed schema.
$script:DotbotTaskInstanceFields = @(
    'schema_version',
    'id',
    'name',
    'description',
    'status',
    'provenance',
    'category',
    'priority',
    'effort',
    'type',
    'dependencies',
    'acceptance_criteria',
    'outputs',
    'created_at',
    'updated_at',
    'completed_at',
    'updated_by',
    'extensions'
)

# Required-on-write fields. 'completed_at' is required-but-nullable: it must be
# present so readers don't need to defensively check for it, but its value is
# null until the task enters a terminal status. 'extensions' is required-but-
# can-be-empty so the namespace channel is always available without a presence
# check at every read site.
$script:DotbotTaskInstanceRequired = @(
    'schema_version',
    'id',
    'name',
    'status',
    'provenance',
    'created_at',
    'updated_at',
    'completed_at',
    'updated_by',
    'extensions'
)

$script:DotbotProvenanceFields = @('workflow', 'run_id', 'definition_name', 'expanded_by')

$script:DotbotExpandedByValues = @('workflow-expansion')   # plus 'task:t_<id>' form, checked separately

$script:DotbotPriorityValues = @('low', 'normal', 'high', 'critical')

# RFC3339-Z timestamp (UTC, no offset, second precision). Matches what the
# rest of the codebase emits via .ToString("yyyy-MM-ddTHH:mm:ssZ").
$script:DotbotTimestampRegex = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'

# Extension namespace keys: dotted-or-flat identifier-like. Empty / whitespace
# / containing path separators or '..' / starting or ending with a dot are
# rejected. The PRD requires dotted names like 'workflow.<name>' but does not
# hard-code an allow-list, so this is shape-only.
$script:DotbotExtensionKeyRegex = '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_-]*)*$'

function Get-TaskInstanceSchemaVersion {
    return $script:DotbotTaskInstanceSchemaVersion
}

function Get-TaskInstanceFields {
    return ,@($script:DotbotTaskInstanceFields)
}

function _Get-DotbotProp {
    # Internal helper: read a property from either a hashtable/IDictionary or
    # a PSCustomObject so the validator works against both 'just parsed JSON'
    # and 'just built in PowerShell'.
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

function _Get-DotbotKeys {
    param($Bag)
    if ($null -eq $Bag) { return @() }
    if ($Bag -is [System.Collections.IDictionary]) { return @($Bag.Keys) }
    return @($Bag.PSObject.Properties.Name)
}

function _Has-DotbotProp {
    param($Bag, [string]$Name)
    if ($null -eq $Bag) { return $false }
    if ($Bag -is [System.Collections.IDictionary]) { return $Bag.Contains($Name) }
    return $null -ne $Bag.PSObject.Properties[$Name]
}

function _Add-Err {
    param([System.Collections.ArrayList]$Errors, [string]$Path, [string]$Message)
    [void]$Errors.Add("$Path`: $Message")
}

function _Validate-Provenance {
    param($Provenance, [System.Collections.ArrayList]$Errors)

    if ($null -eq $Provenance) {
        _Add-Err $Errors 'provenance' 'is required (use { workflow:null, run_id:null, definition_name:null, expanded_by:null } for standalone tasks)'
        return
    }

    $keys = _Get-DotbotKeys $Provenance
    foreach ($k in $keys) {
        if ($script:DotbotProvenanceFields -notcontains $k) {
            _Add-Err $Errors "provenance.$k" 'is not a known provenance field'
        }
    }
    foreach ($f in $script:DotbotProvenanceFields) {
        if (-not (_Has-DotbotProp $Provenance $f)) {
            _Add-Err $Errors "provenance.$f" 'is required (set to null for standalone tasks)'
        }
    }

    $workflow       = _Get-DotbotProp $Provenance 'workflow'
    $runId          = _Get-DotbotProp $Provenance 'run_id'
    $definitionName = _Get-DotbotProp $Provenance 'definition_name'
    $expandedBy     = _Get-DotbotProp $Provenance 'expanded_by'

    # Provenance is all-or-nothing per the PRD: standalone tasks have *all four*
    # null (User Story 6: "null provenance, so that 'ad-hoc' is distinguishable
    # from 'spawned by a workflow'"). Mixing null/non-null is an invariant break.
    $nonNullCount = @($workflow, $runId, $definitionName, $expandedBy | Where-Object { $null -ne $_ -and $_ -ne '' }).Count
    if ($nonNullCount -ne 0 -and $nonNullCount -ne 4) {
        _Add-Err $Errors 'provenance' 'must be either fully null (standalone) or fully populated (workflow-spawned) — partial provenance is not allowed'
    }

    if ($null -ne $runId -and $runId -ne '') {
        if (-not (Test-WorkflowRunId -Id $runId)) {
            _Add-Err $Errors 'provenance.run_id' "must match 'wr_' + 8 chars [A-Za-z0-9] (got '$runId')"
        }
    }

    if ($null -ne $expandedBy -and $expandedBy -ne '') {
        $okPlain = $script:DotbotExpandedByValues -contains $expandedBy
        $okTaskRef = $expandedBy -cmatch '^task:t_[A-Za-z0-9]{8}$'
        if (-not ($okPlain -or $okTaskRef)) {
            _Add-Err $Errors 'provenance.expanded_by' "must be 'workflow-expansion' or 'task:t_<8 chars>' (got '$expandedBy')"
        }
    }
}

function _Validate-Extensions {
    param($Extensions, [System.Collections.ArrayList]$Errors)

    if ($null -eq $Extensions) {
        _Add-Err $Errors 'extensions' 'is required (use {} when empty)'
        return
    }
    if ($Extensions -isnot [System.Collections.IDictionary] -and $Extensions -isnot [PSCustomObject]) {
        _Add-Err $Errors 'extensions' 'must be an object'
        return
    }

    foreach ($k in (_Get-DotbotKeys $Extensions)) {
        if (-not ($k -is [string]) -or [string]::IsNullOrWhiteSpace($k)) {
            _Add-Err $Errors "extensions" "key '$k' must be a non-empty string"
            continue
        }
        if ($k -notmatch $script:DotbotExtensionKeyRegex) {
            _Add-Err $Errors "extensions.$k" "is not a valid namespace key (expected dotted identifier, e.g. 'workflow.my-workflow', 'ui', 'executor.prompt')"
        }
    }
}

function Test-TaskInstance {
    <#
    .SYNOPSIS
    Validate a TaskInstance shape and return the list of validation errors.

    .DESCRIPTION
    Returns an array of human-readable error strings — empty array means valid.
    Use Assert-TaskInstance when you want a throw-on-failure variant.

    Accepts either a hashtable / IDictionary (e.g. [ordered]@{}) or a
    PSCustomObject (e.g. from ConvertFrom-Json). Shape only — does not check
    semantic invariants (e.g. dependency IDs referring to real tasks).

    .PARAMETER Task
    The task record to validate.
    #>
    param(
        [Parameter(Mandatory)]
        $Task
    )

    $errors = [System.Collections.ArrayList]::new()

    if ($null -eq $Task) {
        [void]$errors.Add('task: is null')
        return ,@($errors.ToArray())
    }
    if ($Task -isnot [System.Collections.IDictionary] -and $Task -isnot [PSCustomObject]) {
        [void]$errors.Add('task: must be a hashtable or object')
        return ,@($errors.ToArray())
    }

    # Unknown top-level fields — the PRD explicitly says "Unknown top-level fields
    # raise a validation error." (User Story 3.)
    foreach ($k in (_Get-DotbotKeys $Task)) {
        if ($script:DotbotTaskInstanceFields -notcontains $k) {
            _Add-Err $errors $k "is not a known TaskInstance field — put custom data under extensions.<namespace>"
        }
    }

    # Required fields (presence; null is allowed for completed_at, see schema).
    foreach ($f in $script:DotbotTaskInstanceRequired) {
        if (-not (_Has-DotbotProp $Task $f)) {
            _Add-Err $errors $f 'is required'
        }
    }

    # schema_version
    $sv = _Get-DotbotProp $Task 'schema_version'
    if ($null -ne $sv -and $sv -ne $script:DotbotTaskInstanceSchemaVersion) {
        _Add-Err $errors 'schema_version' "must be $($script:DotbotTaskInstanceSchemaVersion) (got '$sv')"
    }

    # id
    $id = _Get-DotbotProp $Task 'id'
    if ($id -and -not (Test-TaskId -Id $id)) {
        _Add-Err $errors 'id' "must match 't_' + 8 chars [A-Za-z0-9] (got '$id')"
    }

    # name
    $name = _Get-DotbotProp $Task 'name'
    if ($null -ne $name -and ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name))) {
        _Add-Err $errors 'name' 'must be a non-empty string'
    }

    # status
    $status = _Get-DotbotProp $Task 'status'
    if ($null -ne $status -and -not (Test-TaskStatus -Status $status)) {
        _Add-Err $errors 'status' "must be one of: $((Get-TaskStatuses) -join ', ') (got '$status')"
    }

    # provenance
    if (_Has-DotbotProp $Task 'provenance') {
        _Validate-Provenance -Provenance (_Get-DotbotProp $Task 'provenance') -Errors $errors
    }

    # priority (optional; if present, must be one of the named values OR a 0-100 int).
    $priority = _Get-DotbotProp $Task 'priority'
    if ($null -ne $priority) {
        $isNamed = $priority -is [string] -and ($script:DotbotPriorityValues -contains $priority)
        $isInt   = ($priority -is [int]) -or ($priority -is [long]) -or ($priority -is [double] -and [Math]::Floor($priority) -eq $priority)
        if (-not ($isNamed -or $isInt)) {
            _Add-Err $errors 'priority' "must be one of $($script:DotbotPriorityValues -join '/'), or an integer (got '$priority')"
        }
    }

    # dependencies — array of task IDs.
    # PowerShell unwraps single-element arrays on function return AND on
    # if-expression results, so read via direct indexer with no wrapping.
    if (_Has-DotbotProp $Task 'dependencies') {
        if ($Task -is [System.Collections.IDictionary]) {
            $depsRaw = $Task['dependencies']
        } else {
            $depsRaw = $Task.dependencies
        }
        if ($null -ne $depsRaw) {
            if ($depsRaw -is [string]) {
                _Add-Err $errors 'dependencies' 'must be an array of task IDs, not a single string'
            } else {
                $i = 0
                foreach ($d in @($depsRaw)) {
                    if (-not (Test-TaskId -Id $d)) {
                        _Add-Err $errors "dependencies[$i]" "must be a canonical task ID (got '$d')"
                    }
                    $i++
                }
            }
        }
    }

    # acceptance_criteria / outputs — arrays of strings.
    foreach ($listField in 'acceptance_criteria','outputs') {
        if (-not (_Has-DotbotProp $Task $listField)) { continue }
        if ($Task -is [System.Collections.IDictionary]) {
            $valRaw = $Task[$listField]
        } else {
            $valRaw = $Task.$listField
        }
        if ($null -eq $valRaw) { continue }
        if ($valRaw -is [string]) {
            _Add-Err $errors $listField 'must be an array of strings, not a single string'
            continue
        }
        $i = 0
        foreach ($item in @($valRaw)) {
            if ($item -isnot [string]) {
                _Add-Err $errors "$listField[$i]" 'must be a string'
            }
            $i++
        }
    }

    # Timestamps. PowerShell 7's ConvertFrom-Json auto-converts ISO-shaped
    # strings into [datetime] objects (even with -AsHashtable, surprisingly),
    # so accept either an RFC3339-Z string or a [datetime] here. Writers must
    # still emit the string form on disk.
    foreach ($tsField in 'created_at','updated_at') {
        $val = _Get-DotbotProp $Task $tsField
        if ($null -ne $val) {
            $ok = ($val -is [datetime]) -or ($val -is [string] -and $val -match $script:DotbotTimestampRegex)
            if (-not $ok) {
                _Add-Err $errors $tsField "must be an RFC3339-Z timestamp (e.g. '2026-05-19T12:34:56Z'), got '$val'"
            }
        }
    }
    $completedAt = _Get-DotbotProp $Task 'completed_at'
    if ($null -ne $completedAt) {
        $ok = ($completedAt -is [datetime]) -or ($completedAt -is [string] -and $completedAt -match $script:DotbotTimestampRegex)
        if (-not $ok) {
            _Add-Err $errors 'completed_at' "must be null or an RFC3339-Z timestamp, got '$completedAt'"
        }
    }
    # If status is terminal-non-null-able-completed (done/failed/skipped/cancelled),
    # completed_at MUST be non-null. Otherwise the audit trail loses the "when did
    # this stop?" answer and the UI has to backfill from updated_at.
    $terminal = @('done','failed','skipped','cancelled')
    if ($status -and $terminal -contains $status -and $null -eq $completedAt) {
        _Add-Err $errors 'completed_at' "must be set when status is terminal ('$status')"
    }
    if ($status -and $terminal -notcontains $status -and $null -ne $completedAt) {
        _Add-Err $errors 'completed_at' "must be null when status is non-terminal ('$status')"
    }

    # updated_by
    $updatedBy = _Get-DotbotProp $Task 'updated_by'
    if ($null -ne $updatedBy -and ($updatedBy -isnot [string] -or [string]::IsNullOrWhiteSpace($updatedBy))) {
        _Add-Err $errors 'updated_by' 'must be a non-empty string (actor identifier)'
    }

    # extensions
    if (_Has-DotbotProp $Task 'extensions') {
        _Validate-Extensions -Extensions (_Get-DotbotProp $Task 'extensions') -Errors $errors
    }

    return ,@($errors.ToArray())
}

function Assert-TaskInstance {
    <#
    .SYNOPSIS
    Throw if a TaskInstance shape is invalid. Returns nothing on success.
    #>
    param(
        [Parameter(Mandatory)]
        $Task
    )
    $errs = Test-TaskInstance -Task $Task
    if ($errs -and $errs.Count -gt 0) {
        throw "Invalid TaskInstance:`n  - $($errs -join "`n  - ")"
    }
}

function New-TaskInstance {
    <#
    .SYNOPSIS
    Build a TaskInstance with sensible defaults, then validate it.

    .DESCRIPTION
    Convenience builder for tests and callers that don't want to assemble the
    full closed shape by hand. Generates an id if absent, fills timestamps with
    "now" in UTC, defaults status to 'todo', and stamps schema_version. Pass
    -Provenance @{...} to mark the task as workflow-spawned; omit it for a
    standalone task (all four provenance fields go to null).

    The result is validated through Assert-TaskInstance before being returned,
    so callers get either a valid record or an exception.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Description = '',

        [string]$Status = 'todo',

        [string]$Type = 'prompt',

        [hashtable]$Provenance,

        [string]$Category,

        $Priority,

        [string]$Effort,

        [string[]]$Dependencies = @(),

        [string[]]$AcceptanceCriteria = @(),

        [string[]]$Outputs = @(),

        [hashtable]$Extensions,

        [string]$UpdatedBy = 'system',

        [string]$Id
    )

    if (-not $Id) { $Id = New-TaskId }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $prov = if ($Provenance) {
        $bag = [ordered]@{}
        foreach ($f in $script:DotbotProvenanceFields) {
            $bag[$f] = if ($Provenance.Contains($f)) { $Provenance[$f] } else { $null }
        }
        $bag
    } else {
        [ordered]@{
            workflow        = $null
            run_id          = $null
            definition_name = $null
            expanded_by     = $null
        }
    }

    $ext = if ($Extensions) { $Extensions } else { @{} }

    $terminal = @('done','failed','skipped','cancelled')
    $completedAt = if ($terminal -contains $Status) { $now } else { $null }

    $task = [ordered]@{
        schema_version      = $script:DotbotTaskInstanceSchemaVersion
        id                  = $Id
        name                = $Name
        description         = $Description
        status              = $Status
        provenance          = $prov
        category            = $Category
        priority            = $Priority
        effort              = $Effort
        type                = $Type
        dependencies        = @($Dependencies)
        acceptance_criteria = @($AcceptanceCriteria)
        outputs             = @($Outputs)
        created_at          = $now
        updated_at          = $now
        completed_at        = $completedAt
        updated_by          = $UpdatedBy
        extensions          = $ext
    }

    Assert-TaskInstance -Task $task
    return $task
}

Export-ModuleMember -Function @(
    'Get-TaskInstanceSchemaVersion'
    'Get-TaskInstanceFields'
    'Test-TaskInstance'
    'Assert-TaskInstance'
    'New-TaskInstance'
)
