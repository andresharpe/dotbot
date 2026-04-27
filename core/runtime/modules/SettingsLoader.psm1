<#
.SYNOPSIS
Shared settings loader and deep-merge utilities for dotbot.

.DESCRIPTION
Centralizes the three-tier settings resolution used across the UI, MCP,
and runtime layers. Replaces the inline two-layer merges that each
reader previously implemented.

Precedence (low to high):
  Layer 1: $BotRoot/settings/settings.default.json   (tracked project baseline)
  Layer 2: $HOME/dotbot/user-settings.json           (user-level, machine-wide)
  Layer 3: $BotRoot/.control/settings.json           (gitignored per-project overrides)

Missing files are silently skipped. Malformed JSON logs a warning via
Write-BotLog when available and falls through to the remaining layers.
#>

function Merge-DeepSettings {
    <#
    .SYNOPSIS
    Deep-merge two settings objects. Nested objects are recursively merged
    only when both sides are objects; scalars and mismatched shapes use
    last-writer-wins. Arrays of objects replace entirely (ordered pipelines);
    arrays of scalars concat + dedup.
    #>
    param(
        [Parameter(Mandatory)] $Base,
        [Parameter(Mandatory)] $Override
    )

    function ConvertTo-OrderedHash ($obj) {
        if ($obj -is [System.Collections.IDictionary]) { return $obj }
        $h = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }

    $result = ConvertTo-OrderedHash $Base
    $over = ConvertTo-OrderedHash $Override

    foreach ($key in $over.Keys) {
        $overVal = $over[$key]
        if ($result.Contains($key)) {
            $baseVal = $result[$key]
            $baseIsObject = $baseVal -is [System.Collections.IDictionary] -or ($baseVal -is [PSCustomObject] -and $baseVal.PSObject.Properties.Count -gt 0)
            $overIsObject = $overVal -is [System.Collections.IDictionary] -or ($overVal -is [PSCustomObject] -and $overVal.PSObject.Properties.Count -gt 0)
            if ($baseIsObject -and $overIsObject) {
                $result[$key] = Merge-DeepSettings $baseVal $overVal
            } elseif ($baseVal -is [System.Collections.IList] -and $overVal -is [System.Collections.IList]) {
                $hasObjects = ($overVal | Where-Object { $_ -is [PSCustomObject] } | Select-Object -First 1)
                if ($hasObjects) {
                    $result[$key] = $overVal
                } else {
                    $merged = [System.Collections.ArrayList]::new(@($baseVal))
                    foreach ($item in $overVal) {
                        if ($merged -notcontains $item) { $merged.Add($item) | Out-Null }
                    }
                    $result[$key] = @($merged)
                }
            } else {
                $result[$key] = $overVal
            }
        } else {
            $result[$key] = $overVal
        }
    }
    return $result
}

function Get-MergedSettings {
    <#
    .SYNOPSIS
    Returns a deep-merged PSCustomObject combining the three settings layers.

    .PARAMETER BotRoot
    The .bot root directory for the current project.

    .OUTPUTS
    PSCustomObject with the deep-merged settings. Empty PSCustomObject when
    no layer is present or parseable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )

    $layerFiles = @(
        (Join-Path $BotRoot "settings\settings.default.json"),
        (Join-Path $HOME "dotbot" "user-settings.json"),
        (Join-Path $BotRoot ".control\settings.json")
    )

    $merged = $null

    foreach ($layerFile in $layerFiles) {
        if (-not (Test-Path $layerFile)) { continue }
        try {
            $layerContent = Get-Content $layerFile -Raw | ConvertFrom-Json
            if ($null -eq $merged) {
                $merged = $layerContent
            } else {
                $merged = Merge-DeepSettings $merged $layerContent
            }
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Warn -Message "Failed to parse settings layer: $layerFile" -Exception $_
            }
        }
    }

    if ($null -eq $merged) {
        return [pscustomobject]@{}
    }

    return ($merged | ConvertTo-Json -Depth 20 -Compress | ConvertFrom-Json)
}

Export-ModuleMember -Function 'Merge-DeepSettings','Get-MergedSettings'
