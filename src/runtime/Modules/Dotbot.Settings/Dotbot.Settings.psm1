<#
.SYNOPSIS
Shared settings loader and deep-merge utilities for dotbot.

.DESCRIPTION
Centralizes the four-tier settings resolution used across the UI, MCP,
and runtime layers. Replaces the inline two-layer merges that each
reader previously implemented.

Precedence (low to high):
  Layer 1: <DOTBOT_HOME>/content/settings/settings.default.json  (framework default)
  Layer 2: $BotRoot/content/settings/settings.default.json       (project override, tracked, optional)
  Layer 3: Get-DotbotUserSettingsPath                            (user-level, ~/.config/dotbot or %APPDATA%\dotbot)
  Layer 4: $BotRoot/.control/settings.json                       (gitignored per-project state)

Missing files are silently skipped. Malformed JSON logs a warning via
Write-BotLog when available and falls through to the remaining layers.

Required manifest dependencies: Dotbot.Core.
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

# Process-scope flag guarding Invoke-DotbotUserSettingsMigration so it runs
# at most once per PowerShell process. Reset via the -Force switch.
$script:UserSettingsMigrationDone = $false

function Invoke-DotbotUserSettingsMigration {
    <#
    .SYNOPSIS
    Idempotent one-time migration of user-settings.json from the legacy
    DOTBOT_HOME location to the platform-native config dir.

    .DESCRIPTION
    Source: (Get-DotbotInstallPath)/user-settings.json
    Target: Get-DotbotUserSettingsPath

    No-op when the source is absent, when the target already exists, or
    when source and target resolve to the same path. Safe to call
    repeatedly; a process-scope flag short-circuits subsequent invocations
    unless -Force is passed.
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if ($script:UserSettingsMigrationDone -and -not $Force) { return }
    $script:UserSettingsMigrationDone = $true

    try {
        $source = Join-Path (Get-DotbotInstallPath) 'user-settings.json'
        $target = Get-DotbotUserSettingsPath
        if ([string]::Equals($source, $target, [System.StringComparison]::OrdinalIgnoreCase)) { return }
        if (-not (Test-Path $source)) { return }
        if (Test-Path $target) { return }

        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Move-Item -Path $source -Destination $target -Force

        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Info -Message "Migrated user-settings.json from $source to $target"
        }
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "user-settings.json migration failed" -Exception $_
        }
    }
}

function Get-MergedSettings {
    <#
    .SYNOPSIS
    Returns a deep-merged PSCustomObject combining the settings layers.

    .DESCRIPTION
    Resolution order (low → high):
      1. <DOTBOT_HOME>/content/settings/settings.default.json  framework default
      2. <BotRoot>/content/settings/settings.default.json      project override (tracked, optional)
      3. Get-DotbotUserSettingsPath                            user prefs (machine-local)
      4. <BotRoot>/.control/settings.json                      per-project state (gitignored)

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

    Invoke-DotbotUserSettingsMigration

    $frameworkRoot = Get-DotbotInstallPath
    $layerFiles = @(
        (Join-Path $frameworkRoot 'content/settings/settings.default.json'),
        (Join-Path $BotRoot       'content/settings/settings.default.json'),
        (Get-DotbotUserSettingsPath),
        (Join-Path $BotRoot       '.control/settings.json')
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

Export-ModuleMember -Function 'Merge-DeepSettings','Get-MergedSettings','Invoke-DotbotUserSettingsMigration'
