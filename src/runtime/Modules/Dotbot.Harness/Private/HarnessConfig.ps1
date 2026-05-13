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
    Harness name (claude, codex, gemini). If omitted, reads the active value
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

    # $PSScriptRoot is src/runtime/Modules/Dotbot.Harness/Private; 5 ups reaches
    # the framework root (.bot/ in installed projects, repo root in dev).
    # Project override at <root>/settings/providers/, framework default at
    # <root>/content/settings/providers/.
    $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
    $configPath = Join-Path $root "settings" "providers" "$Name.json"
    if (-not (Test-Path $configPath)) {
        $configPath = Join-Path $root "content" "settings" "providers" "$Name.json"
    }

    if (-not (Test-Path $configPath)) {
        throw "Harness config not found for '$Name' at $configPath"
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    # Adapter selection: prefer the explicit `adapter` field; fall back to the
    # legacy `stream_parser` value for forward compatibility with configs that
    # have not yet been updated.
    if (-not ($config.PSObject.Properties['adapter']) -or -not $config.adapter) {
        if ($config.PSObject.Properties['stream_parser'] -and $config.stream_parser) {
            $config | Add-Member -NotePropertyName adapter -NotePropertyValue $config.stream_parser -Force
        }
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
    Requested permission mode key. If omitted or invalid, falls back to the
    config's default mode.

    .PARAMETER DefaultArgs
    Fallback args array returned when no config-driven mode can be resolved.
    #>
    [CmdletBinding()]
    param(
        $Config,
        [string]$PermissionMode,
        [string[]]$DefaultArgs = @("--dangerously-skip-permissions")
    )

    if ($PermissionMode -and $Config.permission_modes -and $Config.permission_modes.$PermissionMode) {
        return @($Config.permission_modes.$PermissionMode.cli_args)
    }
    if ($Config.default_permission_mode -and $Config.permission_modes -and $Config.permission_modes.$($Config.default_permission_mode)) {
        return @($Config.permission_modes.$($Config.default_permission_mode).cli_args)
    }
    if ($Config.cli_args.permissions_bypass) {
        return @($Config.cli_args.permissions_bypass)
    }
    return $DefaultArgs
}

function Build-HarnessCliArgs {
    <#
    .SYNOPSIS
    Generic CLI argument builder for harnesses that conform to the config-driven
    template (Codex, Gemini, future plugins). The Claude adapter uses its own
    arg-builder because of the richer streaming flag set.

    .PARAMETER Config
    Harness config object (from Get-HarnessConfig).

    .PARAMETER Prompt
    The prompt text (retained for signature compatibility; delivered via stdin
    by adapter callers to avoid Windows command-line length limits — #167).

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
        [string]$PermissionMode
    )

    $args_ = @()

    if ($Config.exec_subcommand) {
        $args_ += $Config.exec_subcommand
    }

    if ($Config.cli_args.model) {
        $args_ += $Config.cli_args.model, $ModelId
    }

    $permArgs = Resolve-PermissionArgs -Config $Config -PermissionMode $PermissionMode -DefaultArgs @()
    if ($permArgs) {
        $args_ += $permArgs
    }

    if ($SessionId -and $Config.capabilities.session_id -and $Config.cli_args.session_id) {
        $args_ = @($Config.cli_args.session_id, $SessionId) + $args_
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

    return $args_
}
