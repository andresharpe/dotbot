<#
.SYNOPSIS
Harness configuration loader, model resolution, and CLI argument building.

.DESCRIPTION
Reads provider-config JSON files (settings/providers/{name}.json) and exposes a
typed view used by every adapter:

  Get-HarnessConfig          — loads JSON for the active or named harness
  Get-HarnessModels          — returns the model list with alias + id + badge
  Resolve-HarnessModelId     — maps alias → CLI model id (with passthrough)
  Resolve-PermissionArgs     — resolves CLI args for a permission mode
  Build-HarnessCliArgs       — generic CLI arg builder driven by config

The directory `content/settings/providers/` is retained as the on-disk config
location because the settings UI and `.bot/settings/providers/` deployment
surface use that name. The PowerShell module itself uses "harness" vocabulary
throughout.
#>

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

    return $config
}

function Get-HarnessModels {
    <#
    .SYNOPSIS
    Returns the model list for the active or named harness.
    #>
    [CmdletBinding()]
    param(
        [string]$HarnessName
    )

    $config = Get-HarnessConfig -Name $HarnessName
    $models = @()
    foreach ($key in ($config.models.PSObject.Properties.Name)) {
        $m = $config.models.$key
        $models += [PSCustomObject]@{
            Alias       = $key
            Id          = $m.id
            Description = $m.description
            Badge       = if ($m.badge) { $m.badge } else { $null }
            IsDefault   = ($key -eq $config.default_model)
        }
    }
    return $models
}

function Resolve-HarnessModelId {
    <#
    .SYNOPSIS
    Maps a model alias (e.g. "Opus") to the configured CLI model id.
    If the input is already a model id, returns it as-is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModelAlias,

        [string]$HarnessName
    )

    $config = Get-HarnessConfig -Name $HarnessName

    if ($config.models.PSObject.Properties.Name -contains $ModelAlias) {
        return $config.models.$ModelAlias.id
    }

    foreach ($key in $config.models.PSObject.Properties.Name) {
        if ($config.models.$key.id -eq $ModelAlias) {
            return $ModelAlias
        }
    }

    throw "Unknown model '$ModelAlias' for harness '$($config.name)'. Valid models: $($config.models.PSObject.Properties.Name -join ', ')"
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
