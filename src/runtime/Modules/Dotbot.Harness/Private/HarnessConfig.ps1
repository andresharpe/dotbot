<#
.SYNOPSIS
Harness configuration loader, model resolution, and CLI argument building.

.DESCRIPTION
Reads provider-config JSON files (settings/providers/{name}.json) and exposes a
typed view used by every adapter:

  Get-HarnessConfig          — loads JSON for the active or named harness
  Get-HarnessModels          — returns the canonical tier list for the UI
  Resolve-HarnessModelTier   — maps legacy aliases/ids → fast/balanced/best
  Resolve-HarnessModelId     — maps tier → concrete adapter CLI model id
  Resolve-PermissionArgs     — resolves CLI args for a permission mode
  Build-HarnessCliArgs       — generic CLI arg builder driven by config

The directory `content/settings/providers/` is retained as the on-disk config
location because the settings UI and `.bot/settings/providers/` deployment
surface use that name. The PowerShell module itself uses "harness" vocabulary
throughout.
#>

$script:HarnessModelTiers = @('fast', 'balanced', 'best')

function Get-HarnessModelTiers {
    [CmdletBinding()]
    param()
    return @($script:HarnessModelTiers)
}

function Get-HarnessObjectValue {
    param(
        $Object,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$key]
            }
        }
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-HarnessModelEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Tier,

        [Parameter(Mandatory)]
        $AdapterEntry,

        $ConfigEntry
    )

    $id = Get-HarnessObjectValue -Object $AdapterEntry -Name 'id'
    $displayName = Get-HarnessObjectValue -Object $ConfigEntry -Name 'display_name'
    if (-not $displayName) { $displayName = Get-HarnessObjectValue -Object $AdapterEntry -Name 'display_name' }
    if (-not $displayName) {
        $displayName = switch ($Tier) {
            'fast' { 'Fast' }
            'balanced' { 'Balanced' }
            'best' { 'Best' }
            default { $Tier }
        }
    }

    $description = Get-HarnessObjectValue -Object $ConfigEntry -Name 'description'
    if (-not $description) { $description = Get-HarnessObjectValue -Object $AdapterEntry -Name 'description' }

    $badge = Get-HarnessObjectValue -Object $ConfigEntry -Name 'badge'
    if (-not $badge) { $badge = Get-HarnessObjectValue -Object $AdapterEntry -Name 'badge' }

    $aliases = @(Get-HarnessObjectValue -Object $AdapterEntry -Name 'aliases') |
        Where-Object { $_ } |
        ForEach-Object { [string]$_ }

    return [PSCustomObject]@{
        id           = [string]$id
        display_name = [string]$displayName
        description  = if ($description) { [string]$description } else { '' }
        badge        = if ($badge) { [string]$badge } else { $null }
        aliases      = @($aliases)
    }
}

function Merge-HarnessAdapterModels {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    if (-not (Get-Command Get-HarnessAdapter -ErrorAction SilentlyContinue)) {
        return $Config
    }

    $adapter = Get-HarnessAdapter -Name $Config.adapter
    $adapterModels = $adapter['Models']
    if (-not $adapterModels) {
        throw "Harness adapter '$($Config.adapter)' did not register model tiers."
    }

    $configModels = if ($Config.PSObject.Properties['models']) { $Config.models } else { $null }
    $modelsObject = [PSCustomObject]@{}
    foreach ($tier in $script:HarnessModelTiers) {
        $adapterEntry = $adapterModels[$tier]
        $configEntry = Get-HarnessObjectValue -Object $configModels -Name $tier
        $modelsObject | Add-Member -NotePropertyName $tier -NotePropertyValue (ConvertTo-HarnessModelEntry -Tier $tier -AdapterEntry $adapterEntry -ConfigEntry $configEntry) -Force
    }

    $Config | Add-Member -NotePropertyName models -NotePropertyValue $modelsObject -Force

    if (-not $Config.PSObject.Properties['default_model'] -or -not $Config.default_model) {
        $default = if ($adapter.ContainsKey('DefaultModel') -and $adapter['DefaultModel']) { $adapter['DefaultModel'] } else { 'best' }
        $Config | Add-Member -NotePropertyName default_model -NotePropertyValue $default -Force
    }

    $Config.default_model = Resolve-HarnessModelTier -Model $Config.default_model -Config $Config
    return $Config
}

function Get-HarnessConfig {
    <#
    .SYNOPSIS
    Loads the JSON config for a harness adapter.

    .PARAMETER Name
    Harness name (claude, codex, antigravity). If omitted, reads the active value
    from the merged settings chain.
    #>
    [CmdletBinding()]
    param(
        [string]$Name
    )

    if (-not $Name) {
        $botRoot = Get-DotbotProjectBotPath
        $settings = if (Test-Path $botRoot) { Get-MergedSettings -BotRoot $botRoot } else { $null }

        if ($settings -and $settings.PSObject.Properties['provider'] -and $settings.provider) {
            $Name = $settings.provider
        } else {
            $Name = 'claude'
        }
    }

    # Legacy alias: pre-rename settings may carry provider:"gemini". Map to the
    # renamed Antigravity provider so existing users don't hit a hard throw on
    # first task after upgrade.
    if ($Name -eq 'gemini') {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "Provider 'gemini' is deprecated; using 'antigravity'. Update your settings to silence this warning."
        }
        $Name = 'antigravity'
    }

    # Project override at <BotRoot>/settings/providers/, framework default at
    # <DOTBOT_HOME>/content/settings/providers/. Using the explicit project +
    # framework roots avoids the fragile 5-ups-from-$PSScriptRoot trick (which
    # broke once the runtime stopped being copied into every .bot/ snapshot).
    $configPath = $null
    $botRootForConfig = Get-DotbotProjectBotPath
    if ($botRootForConfig -and (Test-Path $botRootForConfig)) {
        $projectConfig = Join-Path $botRootForConfig "settings" "providers" "$Name.json"
        if (Test-Path $projectConfig) { $configPath = $projectConfig }
    }
    if (-not $configPath) {
        $configPath = Join-Path (Get-DotbotInstallPath) "content" "settings" "providers" "$Name.json"
    }

    if (-not (Test-Path $configPath)) {
        throw "Harness config not found for '$Name'. Looked in project (<BotRoot>/settings/providers/) and framework (<DOTBOT_HOME>/content/settings/providers/)."
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not ($config.PSObject.Properties['adapter']) -or -not $config.adapter) {
        throw "Harness config '$Name' must declare an adapter field."
    }

    return (Merge-HarnessAdapterModels -Config $config)
}

function Get-HarnessModels {
    <#
    .SYNOPSIS
    Returns the canonical model tier list for the active or named harness.
    #>
    [CmdletBinding()]
    param(
        [string]$HarnessName
    )

    $config = Get-HarnessConfig -Name $HarnessName
    $models = @()
    $defaultTier = Resolve-HarnessModelTier -Model $config.default_model -Config $config
    foreach ($tier in $script:HarnessModelTiers) {
        $m = Get-HarnessObjectValue -Object $config.models -Name $tier
        if (-not $m) { continue }
        $models += [PSCustomObject]@{
            Tier        = $tier
            Id          = $tier
            Name        = if ($m.display_name) { $m.display_name } else { $tier }
            Description = if ($m.description) { $m.description } else { '' }
            Badge       = if ($m.badge) { $m.badge } else { $null }
            IsDefault   = ($tier -eq $defaultTier)
        }
    }
    return $models
}

function Resolve-HarnessModelTier {
    <#
    .SYNOPSIS
    Maps a model tier, legacy display alias, or concrete provider id to the
    canonical tier name: fast, balanced, or best.
    #>
    [CmdletBinding()]
    param(
        [string]$Model,

        [string]$HarnessName,

        $Config
    )

    $config = if ($Config) { $Config } else { Get-HarnessConfig -Name $HarnessName }
    if (-not $Model) { $Model = $config.default_model }
    $candidate = ([string]$Model).Trim()
    if (-not $candidate) { $candidate = 'best' }

    foreach ($tier in $script:HarnessModelTiers) {
        if ([string]::Equals($candidate, $tier, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $tier
        }
    }

    foreach ($tier in $script:HarnessModelTiers) {
        $entry = Get-HarnessObjectValue -Object $config.models -Name $tier
        if (-not $entry) { continue }

        $aliases = @()
        $aliases += Get-HarnessObjectValue -Object $entry -Name 'display_name'
        $aliases += @(Get-HarnessObjectValue -Object $entry -Name 'aliases')
        $aliases += Get-HarnessObjectValue -Object $entry -Name 'id'

        foreach ($alias in @($aliases | Where-Object { $_ })) {
            if ([string]::Equals($candidate, [string]$alias, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $tier
            }
        }
    }

    throw "Unknown model tier '$Model' for harness '$($config.name)'. Valid tiers: $($script:HarnessModelTiers -join ', ')"
}

function Resolve-HarnessModelId {
    <#
    .SYNOPSIS
    Maps a canonical model tier to the concrete CLI model id registered by the
    active harness adapter.
    #>
    [CmdletBinding()]
    param(
        [string]$ModelAlias,

        [string]$HarnessName,

        $Config
    )

    $config = if ($Config) { $Config } else { Get-HarnessConfig -Name $HarnessName }
    $tier = Resolve-HarnessModelTier -Model $ModelAlias -Config $config
    $entry = Get-HarnessObjectValue -Object $config.models -Name $tier
    $modelId = Get-HarnessObjectValue -Object $entry -Name 'id'
    if (-not $modelId) {
        throw "Harness '$($config.name)' tier '$tier' does not have a registered provider model id."
    }

    return [string]$modelId
}

function Resolve-PermissionArgs {
    <#
    .SYNOPSIS
    Resolves the CLI permission arguments for a harness invocation.

    .PARAMETER Config
    Harness config object (from Get-HarnessConfig).

    .PARAMETER PermissionMode
    Requested permission mode key. If omitted, resolves the config's default
    mode. Invalid modes are rejected.
    #>
    [CmdletBinding()]
    param(
        $Config,
        [string]$PermissionMode
    )

    $permissionModes = $Config.PSObject.Properties['permission_modes'].Value
    $modeNames = @()
    if ($permissionModes) {
        $modeNames = @($permissionModes.PSObject.Properties.Name)
    }

    if (-not $permissionModes -or $modeNames.Count -eq 0) {
        throw "Harness '$($Config.name)' must declare permission_modes."
    }

    if ($PermissionMode) {
        $mode = $permissionModes.PSObject.Properties[$PermissionMode]
        if (-not $mode) {
            throw "Unknown permission mode '$PermissionMode' for harness '$($Config.name)'. Valid modes: $($modeNames -join ', ')"
        }
        return @($mode.Value.cli_args)
    }

    if (-not $Config.default_permission_mode) {
        throw "Harness '$($Config.name)' must declare default_permission_mode."
    }

    $defaultMode = $permissionModes.PSObject.Properties[$Config.default_permission_mode]
    if (-not $defaultMode) {
        throw "Harness '$($Config.name)' default_permission_mode '$($Config.default_permission_mode)' is not in permission_modes. Valid modes: $($modeNames -join ', ')"
    }

    return @($defaultMode.Value.cli_args)
}

function Test-HarnessModelTierExcluded {
    <#
    .SYNOPSIS
    Returns true when a permission mode excludes a canonical model tier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [string]$ModelTier,

        [string]$PermissionMode
    )

    if (-not $PermissionMode -or -not $Config.permission_modes) { return $false }

    $modeConfig = Get-HarnessObjectValue -Object $Config.permission_modes -Name $PermissionMode
    if (-not $modeConfig) { return $false }

    $restrictions = Get-HarnessObjectValue -Object $modeConfig -Name 'restrictions'
    if (-not $restrictions) { return $false }

    $excludedTiers = @(Get-HarnessObjectValue -Object $restrictions -Name 'excluded_model_tiers') |
        Where-Object { $_ } |
        ForEach-Object { [string]$_ }

    # Legacy project overrides may still use excluded_models with aliases.
    $legacyExcluded = @(Get-HarnessObjectValue -Object $restrictions -Name 'excluded_models') | Where-Object { $_ }
    foreach ($legacy in $legacyExcluded) {
        try {
            $excludedTiers += Resolve-HarnessModelTier -Model ([string]$legacy) -Config $Config
        } catch {
            if ([string]::Equals([string]$legacy, $ModelTier, [System.StringComparison]::OrdinalIgnoreCase)) {
                $excludedTiers += $ModelTier
            }
        }
    }

    foreach ($tier in $excludedTiers) {
        if ([string]::Equals($tier, $ModelTier, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Build-HarnessCliArgs {
    <#
    .SYNOPSIS
    Generic CLI argument builder for harnesses that conform to the config-driven
    template (Codex, Antigravity, future plugins). The Claude adapter uses its own
    arg-builder because of the richer streaming flag set.

    .PARAMETER Config
    Harness config object (from Get-HarnessConfig).

    .PARAMETER Prompt
    The prompt text. Harnesses with a configured prompt_flag receive it as a
    native CLI argument; other harnesses read it from stdin in their adapter.

    .PARAMETER ModelId
    Full model id to use.

    .PARAMETER SessionId
    Optional session id (only used if the harness supports it).

    .PARAMETER PersistSession
    Whether to persist the session.

    .PARAMETER Streaming
    Whether to use streaming output format.

    .PARAMETER PermissionMode
    Requested permission mode key.

    .PARAMETER WorkingDirectory
    Optional project/worktree directory for harnesses that expose a cwd flag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$ModelId,

        [string]$SessionId,
        [bool]$PersistSession = $false,
        [bool]$Streaming = $true,
        [string]$PermissionMode,
        [string]$WorkingDirectory
    )

    $args_ = @()

    if ($Config.exec_subcommand) {
        $args_ += $Config.exec_subcommand
    }

    if ($Config.cli_args.model) {
        $args_ += $Config.cli_args.model, $ModelId
    }

    $permArgs = Resolve-PermissionArgs -Config $Config -PermissionMode $PermissionMode
    if ($permArgs) {
        $args_ += $permArgs
    }

    if ($SessionId -and $Config.capabilities.session_id -and $Config.cli_args.session_id) {
        $args_ = @($Config.cli_args.session_id, $SessionId) + $args_
    }

    if ($WorkingDirectory -and $Config.cli_args.working_directory) {
        $args_ += $Config.cli_args.working_directory, $WorkingDirectory
    }

    if (-not $PersistSession -and $Config.capabilities.persist_session -and $Config.cli_args.no_session_persistence) {
        $args_ += $Config.cli_args.no_session_persistence
    }

    if ($Streaming -and $Config.cli_args.stream_format) {
        $args_ += @($Config.cli_args.stream_format)
    }

    if ($Config.cli_args.print) {
        $args_ += $Config.cli_args.print
    }

    if ($Config.cli_args.verbose) {
        $args_ += $Config.cli_args.verbose
    }

    if ($Config.prompt_flag) {
        $args_ += $Config.prompt_flag, $Prompt
    }

    return $args_
}
