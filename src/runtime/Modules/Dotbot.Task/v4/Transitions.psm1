<#
.SYNOPSIS
v4 status enum + closed transition table for TaskInstance.

Canonical PRD: docs/prds/PRD-01-data-model.md.

The transition table is the authority. Anything not listed throws.
#>

$script:DotbotTaskStatuses = @(
    'todo',
    'analysing',
    'analysed',
    'in-progress',
    'done',
    'failed',
    'skipped',
    'cancelled',
    'needs-input'
)

# Closed transition map: { from -> @(allowed-to, ...) }.
# Mirrors the table in PRD-01 §Implementation Decisions verbatim.
$script:DotbotTaskTransitions = @{
    'todo'        = @('analysing', 'skipped', 'cancelled')
    'analysing'   = @('analysed', 'needs-input', 'failed', 'cancelled')
    'analysed'    = @('in-progress', 'needs-input', 'skipped', 'cancelled')
    'in-progress' = @('done', 'needs-input', 'failed', 'analysed', 'cancelled')
    'needs-input' = @('analysing', 'cancelled')
    'done'        = @('todo')
    'failed'      = @('todo')
    'skipped'     = @('todo')
    'cancelled'   = @()
}

function Get-TaskStatuses {
    <#
    .SYNOPSIS
    Return the canonical list of valid task statuses (v4).
    #>
    return ,@($script:DotbotTaskStatuses)
}

function Test-TaskStatus {
    <#
    .SYNOPSIS
    Returns $true iff $Status is one of the canonical v4 statuses.
    #>
    param([string]$Status)
    if (-not $Status) { return $false }
    return $script:DotbotTaskStatuses -contains $Status
}

function Get-AllowedTransitions {
    <#
    .SYNOPSIS
    Return the array of statuses reachable from $From in one transition.

    .DESCRIPTION
    Reading from the closed map. An unknown status throws (callers should
    validate the input first via Test-TaskStatus if they don't want to crash).
    Terminal 'cancelled' returns an empty array.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$From
    )

    if (-not (Test-TaskStatus -Status $From)) {
        throw "Get-AllowedTransitions: '$From' is not a valid task status. Known statuses: $($script:DotbotTaskStatuses -join ', ')."
    }
    return ,@($script:DotbotTaskTransitions[$From])
}

function Test-TaskTransition {
    <#
    .SYNOPSIS
    Returns $true iff transitioning from $From to $To is allowed by the v4 table.

    .DESCRIPTION
    Returns $false for both 'unknown status' and 'known but disallowed'. This is
    the predicate; throwers belong in Assert-TaskTransition. A self-transition
    ($From -eq $To) is not in the table and so returns $false; callers that want
    a no-op should check equality before calling.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string]$To
    )

    if (-not (Test-TaskStatus -Status $From)) { return $false }
    if (-not (Test-TaskStatus -Status $To))   { return $false }
    $allowed = $script:DotbotTaskTransitions[$From]
    return $allowed -contains $To
}

function Assert-TaskTransition {
    <#
    .SYNOPSIS
    Throw if transitioning from $From to $To is not allowed by the v4 table.

    .DESCRIPTION
    The thrower variant — call sites that own a state mutation should use this
    so that an illegal request fails loudly before any side effect fires
    (file move, hook dispatch, worktree change). The exception message names
    the from/to pair and lists the legal exits from $From so the caller can
    correct the request without consulting the PRD.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$From,

        [Parameter(Mandatory)]
        [string]$To
    )

    if (-not (Test-TaskStatus -Status $From)) {
        throw "Assert-TaskTransition: '$From' is not a valid task status."
    }
    if (-not (Test-TaskStatus -Status $To)) {
        throw "Assert-TaskTransition: '$To' is not a valid task status."
    }

    if (Test-TaskTransition -From $From -To $To) { return }

    $allowed = $script:DotbotTaskTransitions[$From]
    if ($allowed.Count -eq 0) {
        throw "Assert-TaskTransition: cannot leave terminal status '$From' (attempted '$From' → '$To')."
    }
    throw "Assert-TaskTransition: '$From' → '$To' is not a legal transition. Allowed exits from '$From': $($allowed -join ', ')."
}

Export-ModuleMember -Function @(
    'Get-TaskStatuses'
    'Test-TaskStatus'
    'Get-AllowedTransitions'
    'Test-TaskTransition'
    'Assert-TaskTransition'
)
