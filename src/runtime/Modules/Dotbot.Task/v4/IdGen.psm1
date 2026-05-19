<#
.SYNOPSIS
v4 ID generator: nanoid-style 8-char IDs over [A-Za-z0-9], with prefixes
'_t' / '_wr', and a 4-char derived short form.

Canonical PRD: docs/prds/PRD-01-data-model.md.
#>

$script:DotbotIdAlphabet      = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$script:DotbotIdBodyLength    = 8
$script:DotbotIdShortLength   = 4
$script:DotbotTaskPrefix      = 't_'
$script:DotbotWorkflowPrefix  = 'wr_'

function _Get-DotbotIdAlphabet      { $script:DotbotIdAlphabet }
function _Get-DotbotIdBodyLength    { $script:DotbotIdBodyLength }
function _Get-DotbotIdShortLength   { $script:DotbotIdShortLength }

function New-DotbotNanoId {
    <#
    .SYNOPSIS
    Generate an 8-character random ID over the alphabet [A-Za-z0-9].

    .DESCRIPTION
    Uniform-distribution draw from a CSRNG. Used by New-TaskId and
    New-WorkflowRunId. Exposed for tests and tooling that need a raw body
    (e.g. fixture builders); production code should call the typed helpers.
    #>
    param(
        [int]$Length = $script:DotbotIdBodyLength
    )

    if ($Length -lt 1) { throw "Length must be >= 1" }

    $alphabet = $script:DotbotIdAlphabet
    $alphaLen = $alphabet.Length
    # Rejection-sample so the distribution stays uniform across the 62-char
    # alphabet (256 mod 62 != 0). Threshold = floor(256 / 62) * 62 = 248.
    $threshold = [Math]::Floor(256 / $alphaLen) * $alphaLen

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $sb = [System.Text.StringBuilder]::new($Length)
        $buf = [byte[]]::new(1)
        while ($sb.Length -lt $Length) {
            $rng.GetBytes($buf)
            if ($buf[0] -lt $threshold) {
                [void]$sb.Append($alphabet[$buf[0] % $alphaLen])
            }
        }
        return $sb.ToString()
    } finally {
        $rng.Dispose()
    }
}

function New-TaskId {
    <#
    .SYNOPSIS
    Generate a canonical task ID of the form 't_AbCd1234'.
    #>
    return "$script:DotbotTaskPrefix$(New-DotbotNanoId)"
}

function New-WorkflowRunId {
    <#
    .SYNOPSIS
    Generate a canonical workflow-run ID of the form 'wr_AbCd1234'.
    #>
    return "$script:DotbotWorkflowPrefix$(New-DotbotNanoId)"
}

function Test-TaskId {
    <#
    .SYNOPSIS
    Returns $true iff the input matches the canonical task-ID shape.
    #>
    param([string]$Id)
    if (-not $Id) { return $false }
    return $Id -cmatch '^t_[A-Za-z0-9]{8}$'
}

function Test-WorkflowRunId {
    <#
    .SYNOPSIS
    Returns $true iff the input matches the canonical workflow-run-ID shape.
    #>
    param([string]$Id)
    if (-not $Id) { return $false }
    return $Id -cmatch '^wr_[A-Za-z0-9]{8}$'
}

function Get-ShortId {
    <#
    .SYNOPSIS
    Return the 4-char short form derived from a canonical task or workflow-run ID.

    .DESCRIPTION
    The short form is the first 4 chars of the body (i.e. after the prefix).
    The PRD requires the short form to be *derived*, never separately allocated,
    so directory/filename collisions stay solvable by changing the canonical ID.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    if (Test-TaskId -Id $Id) {
        return $Id.Substring(2, $script:DotbotIdShortLength)
    }
    if (Test-WorkflowRunId -Id $Id) {
        return $Id.Substring(3, $script:DotbotIdShortLength)
    }
    throw "Get-ShortId: '$Id' is not a canonical task or workflow-run ID."
}

Export-ModuleMember -Function @(
    'New-DotbotNanoId'
    'New-TaskId'
    'New-WorkflowRunId'
    'Test-TaskId'
    'Test-WorkflowRunId'
    'Get-ShortId'
    '_Get-DotbotIdAlphabet'
    '_Get-DotbotIdBodyLength'
    '_Get-DotbotIdShortLength'
)
