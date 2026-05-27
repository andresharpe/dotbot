<#
.SYNOPSIS
Adapter registry — the plugin point for harness implementations.

.DESCRIPTION
Each adapter under Adapters/ calls Register-HarnessAdapter at load time with
a hashtable of scriptblocks implementing the adapter contract. The top-level
Dotbot.Harness dispatcher looks up the adapter for the active harness config
and invokes the matching scriptblock.

Adapter contract (every adapter MUST provide these fields):

    Models         — hashtable keyed by the canonical model tiers:
                     fast, balanced, best. Each tier maps to the provider's
                     concrete CLI model id and optional UI metadata.
                     Required.

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
    3. Register fast/balanced/best model tiers in the adapter spec.
    4. Call Register-HarnessAdapter -Name '<Name>' -Spec @{ ... } at the bottom
       of the file.
    5. Add a settings/providers/<harness>.json config with `"adapter": "<Name>"`.

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

    if (-not $Spec.ContainsKey('Models') -or $null -eq $Spec['Models']) {
        throw "Adapter '$Name' is missing required model tier registration. Required tiers: fast, balanced, best."
    }
    if ($Spec['Models'] -isnot [hashtable]) {
        throw "Adapter '$Name' field 'Models' must be a [hashtable]."
    }

    foreach ($tier in @('fast', 'balanced', 'best')) {
        if (-not $Spec['Models'].ContainsKey($tier) -or $null -eq $Spec['Models'][$tier]) {
            throw "Adapter '$Name' must register model tier '$tier'. Required tiers: fast, balanced, best."
        }

        $entry = $Spec['Models'][$tier]
        $id = if ($entry -is [hashtable]) { $entry['id'] } else { $entry.id }
        if (-not $id) {
            throw "Adapter '$Name' model tier '$tier' must declare a concrete provider model id."
        }
    }

    if ($Spec.ContainsKey('DefaultModel') -and $Spec['DefaultModel'] -and $Spec['DefaultModel'] -notin @('fast', 'balanced', 'best')) {
        throw "Adapter '$Name' DefaultModel must be one of: fast, balanced, best."
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
