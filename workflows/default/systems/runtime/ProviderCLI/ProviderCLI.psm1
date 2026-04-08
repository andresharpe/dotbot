using namespace System.Management.Automation

<#
.SYNOPSIS
Provider-agnostic CLI abstraction layer for dotbot.

.DESCRIPTION
Wraps provider-specific CLIs (Claude, Codex, Gemini) behind a unified interface.
Loads declarative provider config from workflows/default/settings/providers/{name}.json
and dispatches CLI invocations accordingly.
#>

# Import DotBotTheme for consistent colors
if (-not (Get-Module DotBotTheme)) {
    Import-Module "$PSScriptRoot\..\modules\DotBotTheme.psm1" -Force
}

# Import ClaudeCLI for reuse of its stream parser and helpers
if (-not (Get-Module ClaudeCLI)) {
    Import-Module "$PSScriptRoot\..\ClaudeCLI\ClaudeCLI.psm1" -Force
}

#region Provider Config

function Get-ProviderConfig {
    <#
    .SYNOPSIS
    Loads provider config JSON for the active (or specified) provider.

    .PARAMETER Name
    Provider name (claude, codex, gemini). If omitted, reads from settings.
    #>
    [CmdletBinding()]
    param(
        [string]$Name
    )

    if (-not $Name) {
        # Read from settings
        $botRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $settingsPath = Join-Path $botRoot "settings\settings.default.json"
        $settings = @{ provider = 'claude' }
        if (Test-Path $settingsPath) {
            try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { Write-BotLog -Level Debug -Message "Settings operation failed" -Exception $_ }
        }

        # Check user override
        $controlSettings = Join-Path $botRoot ".control\settings.json"
        if (Test-Path $controlSettings) {
            try {
                $override = Get-Content $controlSettings -Raw | ConvertFrom-Json
                if ($override.provider) { $settings = @{ provider = $override.provider } }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }

        $Name = if ($settings.provider) { $settings.provider } else { 'claude' }
    }

    # Look for provider config in .bot first (installed project), then profiles (dev)
    $botRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $configPath = Join-Path $botRoot "settings\providers\$Name.json"
    if (-not (Test-Path $configPath)) {
        # Fallback to workflows source
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))))
        $configPath = Join-Path $repoRoot "workflows\default\settings\providers\$Name.json"
    }

    if (-not (Test-Path $configPath)) {
        throw "Provider config not found for '$Name' at $configPath"
    }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    return $config
}

function Get-ProviderModels {
    <#
    .SYNOPSIS
    Returns the model list for the active provider.
    #>
    [CmdletBinding()]
    param(
        [string]$ProviderName
    )

    $config = Get-ProviderConfig -Name $ProviderName
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

function Resolve-ProviderModelId {
    <#
    .SYNOPSIS
    Maps a model alias (e.g. "Opus") to the provider's configured CLI model selector.
    If the input is already a configured model selector, returns it as-is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ModelAlias,

        [string]$ProviderName
    )

    $config = Get-ProviderConfig -Name $ProviderName

    # Check if it's an alias
    if ($config.models.PSObject.Properties.Name -contains $ModelAlias) {
        return $config.models.$ModelAlias.id
    }

    # Check if it's already a full model ID
    foreach ($key in $config.models.PSObject.Properties.Name) {
        if ($config.models.$key.id -eq $ModelAlias) {
            return $ModelAlias
        }
    }

    throw "Unknown model '$ModelAlias' for provider '$($config.name)'. Valid models: $($config.models.PSObject.Properties.Name -join ', ')"
}

#endregion

#region CLI Arg Building

function Resolve-PermissionArgs {
    <#
    .SYNOPSIS
    Resolves the CLI permission arguments for a provider invocation.

    .PARAMETER Config
    Provider config object (from Get-ProviderConfig).

    .PARAMETER PermissionMode
    Requested permission mode key. If omitted or invalid, falls back to provider default.

    .PARAMETER DefaultArgs
    Fallback args array returned when no config-driven mode can be resolved.
    #>
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

function Build-ProviderCliArgs {
    <#
    .SYNOPSIS
    Builds the CLI argument array for a provider invocation.

    .PARAMETER Config
    Provider config object (from Get-ProviderConfig).

    .PARAMETER Prompt
    The prompt text.

    .PARAMETER ModelId
    Full model ID to use.

    .PARAMETER SessionId
    Optional session ID (only used if provider supports it).

    .PARAMETER PersistSession
    Whether to persist the session.

    .PARAMETER Streaming
    Whether to use streaming output format.
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

    # Exec subcommand (e.g. "exec" for Codex)
    if ($Config.exec_subcommand) {
        $args_ += $Config.exec_subcommand
    }

    # Model
    if ($Config.cli_args.model) {
        $args_ += $Config.cli_args.model, $ModelId
    }

    # Permission mode — resolve from permission_modes config, fall back to cli_args.permissions_bypass
    $permArgs = Resolve-PermissionArgs -Config $Config -PermissionMode $PermissionMode -DefaultArgs @()
    if ($permArgs) {
        $args_ += $permArgs
    }

    # Session ID (only if provider supports it)
    if ($SessionId -and $Config.capabilities.session_id -and $Config.cli_args.session_id) {
        $args_ = @($Config.cli_args.session_id, $SessionId) + $args_
    }

    # No session persistence (only if provider supports it and we don't want persistence)
    if (-not $PersistSession -and $Config.capabilities.persist_session -and $Config.cli_args.no_session_persistence) {
        $args_ += $Config.cli_args.no_session_persistence
    }

    # Streaming format
    if ($Streaming -and $Config.cli_args.stream_format) {
        $args_ += @($Config.cli_args.stream_format)
    }

    # Print flag
    if ($Config.cli_args.print) {
        $args_ += $Config.cli_args.print
    }

    # Verbose flag
    if ($Config.cli_args.verbose) {
        $args_ += $Config.cli_args.verbose
    }

    # Prompt is delivered via stdin by callers to avoid Windows command-line length limits (#167)
    # The $Prompt parameter is retained for signature compatibility but not added to args.

    return $args_
}

#endregion

#region Invocation

# Script-scoped variable to store rate limit info for caller to check
$script:LastProviderRateLimitInfo = $null

function Invoke-ProviderStream {
    <#
    .SYNOPSIS
    Invokes the active provider's CLI with streaming output and detailed logging.

    .DESCRIPTION
    Provider-agnostic replacement for Invoke-ClaudeStream. Builds CLI args from
    provider config, invokes the CLI, and dispatches output to the correct stream parser.

    .PARAMETER Prompt
    The prompt to send.

    .PARAMETER Model
    Full model ID to use (default: provider's default model).

    .PARAMETER SessionId
    Optional session ID for conversation continuity.

    .PARAMETER PersistSession
    Whether to persist the session.

    .PARAMETER ShowDebugJson
    Show raw JSON events.

    .PARAMETER ShowVerbose
    Show detailed tool results and metadata.

    .PARAMETER ProviderName
    Override provider name (default: from settings).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model,

        [string]$SessionId,
        [switch]$PersistSession,
        [switch]$ShowDebugJson,
        [switch]$ShowVerbose,
        [string]$ProviderName,
        [string]$PermissionMode
    )

    # Clear any previous rate limit info
    $script:LastProviderRateLimitInfo = $null

    # Load provider config
    $config = Get-ProviderConfig -Name $ProviderName

    # Resolve model
    if (-not $Model) {
        $Model = $config.models.($config.default_model).id
    }

    # For Claude provider, delegate to existing Invoke-ClaudeStream (proven, battle-tested)
    if ($config.name -eq 'claude') {
        # Resolve permission args for Claude path
        $permArgs = Resolve-PermissionArgs -Config $config -PermissionMode $PermissionMode

        $streamArgs = @{
            Prompt         = $Prompt
            Model          = $Model
            PermissionArgs = $permArgs
        }
        if ($SessionId)    { $streamArgs['SessionId'] = $SessionId }
        if ($PersistSession) { $streamArgs['PersistSession'] = $true }
        if ($ShowDebugJson) { $streamArgs['ShowDebugJson'] = $true }
        if ($ShowVerbose)  { $streamArgs['ShowVerbose'] = $true }

        Invoke-ClaudeStream @streamArgs

        # Propagate rate limit info
        $script:LastProviderRateLimitInfo = Get-LastRateLimitInfo
        return
    }

    # --- Non-Claude provider path ---

    # Refresh theme
    if (Update-DotBotTheme) {
        $script:theme = Get-DotBotTheme
    }
    $t = Get-DotBotTheme

    # Build CLI args
    $cliArgs = Build-ProviderCliArgs -Config $config -Prompt $Prompt -ModelId $Model `
        -SessionId $SessionId -PersistSession ([bool]$PersistSession) -Streaming $true `
        -PermissionMode $PermissionMode

    $executable = $config.executable

    # Load the appropriate stream parser
    $parserName = $config.stream_parser
    $parserScript = "$PSScriptRoot\parsers\Parse-$($parserName)Stream.ps1"

    if (-not (Test-Path $parserScript)) {
        throw "Stream parser not found: $parserScript"
    }

    # Initialize parser state
    $parserState = @{
        assistantText    = New-Object System.Text.StringBuilder
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheRead   = 0
        totalCacheCreate = 0
        pendingToolCalls = @()
        lastUnknown      = Get-Date
        theme            = $t
    }

    # Dot-source the parser to get Process-StreamLine function
    . $parserScript

    # Debug output
    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("$($t.Bezel)--- PROVIDER: $($config.display_name) ---$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)Executable: $executable$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)Args: $($cliArgs -join ' ')$($t.Reset)")
        [Console]::Error.Flush()
    }

    # Ensure UTF-8
    $prevOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $Prompt | & $executable @cliArgs 2>&1 | ForEach-Object -Process {
            $raw = $_.ToString()
            if (-not $raw) { return }

            $line = $raw.TrimStart()
            if ($line.Length -eq 0) { return }

            # Dispatch to parser
            $result = Process-StreamLine -Line $line -State $parserState -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose
            if ($result -eq 'rate_limit') {
                $script:LastProviderRateLimitInfo = $parserState.rateLimitMessage
            }
        }
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
    }
}

function Invoke-Provider {
    <#
    .SYNOPSIS
    Simple non-streaming provider invocation.

    .PARAMETER Prompt
    The prompt to send.

    .PARAMETER Model
    Full model ID (default: provider's default).

    .PARAMETER ProviderName
    Override provider name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model,

        [string]$ProviderName,
        [string]$PermissionMode
    )

    $config = Get-ProviderConfig -Name $ProviderName

    if (-not $Model) {
        $Model = $config.models.($config.default_model).id
    }

    # For Claude, delegate to Invoke-Claude
    if ($config.name -eq 'claude') {
        $permArgs = Resolve-PermissionArgs -Config $config -PermissionMode $PermissionMode
        return Invoke-Claude -Prompt $Prompt -Model $Model -PermissionArgs $permArgs
    }

    # Non-Claude: build args without streaming
    $cliArgs = Build-ProviderCliArgs -Config $config -Prompt $Prompt -ModelId $Model -Streaming $false -PermissionMode $PermissionMode

    $executable = $config.executable
    $previousOutputEncoding = $OutputEncoding
    $previousConsoleInputEncoding = [Console]::InputEncoding
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    $utf8Encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        $OutputEncoding = $utf8Encoding
        [Console]::InputEncoding = $utf8Encoding
        [Console]::OutputEncoding = $utf8Encoding

        $Prompt | & $executable @cliArgs
    }
    finally {
        $OutputEncoding = $previousOutputEncoding
        [Console]::InputEncoding = $previousConsoleInputEncoding
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
    }
}

function New-ProviderSession {
    <#
    .SYNOPSIS
    Creates a new session ID. Returns GUID for Claude, $null for providers without session support.
    #>
    [CmdletBinding()]
    param(
        [string]$ProviderName
    )

    $config = Get-ProviderConfig -Name $ProviderName

    if ($config.capabilities.session_id) {
        return [Guid]::NewGuid().ToString()
    }

    return $null
}

function Get-LastProviderRateLimitInfo {
    <#
    .SYNOPSIS
    Gets the last rate limit message from the most recent provider stream invocation.
    #>
    [CmdletBinding()]
    param()

    return $script:LastProviderRateLimitInfo
}

#endregion

Export-ModuleMember -Function @(
    'Get-ProviderConfig'
    'Get-ProviderModels'
    'Resolve-ProviderModelId'
    'Build-ProviderCliArgs'
    'Invoke-ProviderStream'
    'Invoke-Provider'
    'New-ProviderSession'
    'Get-LastProviderRateLimitInfo'
)
