# This is the default template for pattern-pipeline-cmdlet.
# Replace this file with a real example from the dotbot codebase when one is
# higher-quality than the template. Today the codebase has only two functions
# that declare ValueFromPipeline (Invoke-ClaudeStream and Invoke-Claude in
# core/runtime/ClaudeCLI/ClaudeCLI.psm1), and both are too large to be
# canonical examples - they would teach the wrong shape.
#
# What to look for in a good canonical example:
#   - [CmdletBinding()] attribute
#   - [OutputType()] attribute that matches actual return
#   - At least one parameter with ValueFromPipeline
#   - process block that handles each input item
#   - Comment-based help with synopsis, description, parameter, example
#   - Proper terminating-error discipline
#   - No I/O if it should be pure, I/O cleanly separated if not

function Get-Example {
    <#
    .SYNOPSIS
        One-line description of what this function does.

    .DESCRIPTION
        A paragraph explaining the function. Why it exists, what it returns,
        what it does not do (boundary).

    .PARAMETER InputObject
        The thing being processed. Documents type, valid values, mandatory-ness.

    .PARAMETER Filter
        Optional filter applied to the input.

    .EXAMPLE
        Get-Example -InputObject $foo

        Description of what this example demonstrates.

    .EXAMPLE
        $items | Get-Example -Filter 'active'

        Description of what this example demonstrates.

    .OUTPUTS
        [pscustomobject] with Name, Value, Status properties.

    .NOTES
        Any caveats. Author, date, related functions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(
            Mandatory,
            Position = 0,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName
        )]
        [ValidateNotNull()]
        [object]$InputObject,

        [Parameter()]
        [ValidateSet('active', 'inactive', 'all')]
        [string]$Filter = 'all'
    )

    begin {
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'

        $count = 0
    }

    process {
        $count++

        if ($Filter -ne 'all') {
            $statusProp = $InputObject.Status
            if ($statusProp -ne $Filter) {
                return  # skip this item, do not emit
            }
        }

        [pscustomobject]@{
            Name   = $InputObject.Name
            Value  = $InputObject.Value
            Status = $InputObject.Status ?? 'unknown'
        }
    }

    end {
        Write-BotLog -Level Debug -Message "Get-Example processed $count item(s)."
    }
}
