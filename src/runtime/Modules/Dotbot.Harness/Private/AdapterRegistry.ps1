<#
.SYNOPSIS
Adapter registry — the plugin point for harness implementations.

.DESCRIPTION
Each adapter under Adapters/ calls Register-HarnessAdapter at load time with
a hashtable of scriptblocks implementing the adapter contract. The top-level
Dotbot.Harness dispatcher looks up the adapter for the active harness config
and invokes the matching scriptblock.

Adapter contract (every adapter MUST provide these scriptblocks):

    Stream         — streaming invocation; mirrors Invoke-HarnessStream params.
                     Required.
    Invoke         — simple (non-streaming) invocation; mirrors Invoke-Harness
                     params. Required.
    NewSession     — returns a new session id (string) or $null if the harness
                     does not support sessions. Required.
    RemoveSession  — cleans up a session by id; returns $true if anything was
                     removed. Required (return $false for harnesses without
                     local session artifacts).

Add a new harness:
    1. Drop ./Adapters/<Name>Adapter.ps1 into the module.
    2. Implement the four scriptblocks listed above.
    3. Call Register-HarnessAdapter -Name '<Name>' -Spec @{ ... } at the bottom
       of the file.
    4. Add a settings/providers/<harness>.json config with `"adapter": "<Name>"`.

No other changes are required — the dispatcher loads adapters from disk and
resolves them by name from the config.
#>

$script:Adapters = @{}

function Register-HarnessAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Spec
    )

    $required = @('Stream', 'Invoke', 'NewSession', 'RemoveSession')
    foreach ($key in $required) {
        if (-not $Spec.ContainsKey($key) -or $null -eq $Spec[$key]) {
            throw "Adapter '$Name' is missing required scriptblock '$key'. Required: $($required -join ', ')."
        }
        if ($Spec[$key] -isnot [scriptblock]) {
            throw "Adapter '$Name' field '$key' must be a [scriptblock]."
        }
    }

    $script:Adapters[$Name] = $Spec
}

function Get-HarnessAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $script:Adapters.ContainsKey($Name)) {
        $available = ($script:Adapters.Keys | Sort-Object) -join ', '
        throw "No harness adapter registered for '$Name'. Available: $available"
    }
    return $script:Adapters[$Name]
}

function Get-RegisteredHarnessAdapters {
    [CmdletBinding()]
    param()
    return @($script:Adapters.Keys | Sort-Object)
}
