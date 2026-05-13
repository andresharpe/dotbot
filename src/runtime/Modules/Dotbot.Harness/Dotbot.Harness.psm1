using namespace System.Management.Automation

<#
.SYNOPSIS
Dotbot.Harness — pluggable AI harness layer.

.DESCRIPTION
A "harness" is an AI coding tool that dotbot drives as a child process:
Claude Code (Anthropic), Codex (OpenAI), Gemini CLI (Google), and any future
adapter that conforms to the contract in Adapters/.

This module is composed by dot-sourcing in load order:

    Private/      — cross-cutting helpers used by every adapter
        ConsoleRender.ps1    : timestamps, markdown rendering, themed log lines
        ActivityLog.ps1      : Write-ActivityLog (oscilloscope UI feed)
        RateLimit.ps1        : rate-limit reset-time parser
        Failure.ps1          : exit-code → failure classifier
        HarnessConfig.ps1    : provider JSON loader, model resolution, CLI args
        AdapterRegistry.ps1  : Register-HarnessAdapter / Get-HarnessAdapter

    Adapters/    — one .ps1 per harness. Each registers itself via
                   Register-HarnessAdapter with scriptblocks implementing the
                   contract: Stream, Invoke, NewSession, RemoveSession,
                   GetLastRateLimit. See Private/AdapterRegistry.ps1 for the
                   contract specification.

The public API in this file is harness-agnostic; the active harness is
selected by the `provider` field in the merged settings chain and the
`adapter` field in the resolved provider JSON.

Dependencies: Dotbot.Core (paths, sanitization), Dotbot.Theme (console output),
Dotbot.Settings (provider selection). Logs through Dotbot.Logging when present.
#>

# Console theming — adapters share $script:theme for rendering
if (-not (Get-Module Dotbot.Theme)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Theme' 'Dotbot.Theme.psm1') -DisableNameChecking
}
$script:theme = Get-DotbotTheme

# PathSanitizer strips absolute paths from activity log messages.
# $PSScriptRoot is src/runtime/Modules/Dotbot.Harness/; three ups reaches src/.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "mcp/modules/PathSanitizer.psm1") -Force

# Dotbot.Core (paths, sanitization)
if (-not (Get-Module Dotbot.Core)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Core' 'Dotbot.Core.psm1') -DisableNameChecking
}

# Dotbot.Settings (active harness selection from merged settings)
if (-not (Get-Module Dotbot.Settings)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Settings' 'Dotbot.Settings.psm1') -DisableNameChecking -Global
}

# --- Load order matters ---
# 1. Helpers first (Activity log + console rendering used by adapters)
. (Join-Path $PSScriptRoot "Private/ActivityLog.ps1")
. (Join-Path $PSScriptRoot "Private/ConsoleRender.ps1")
. (Join-Path $PSScriptRoot "Private/RateLimit.ps1")
. (Join-Path $PSScriptRoot "Private/Failure.ps1")
. (Join-Path $PSScriptRoot "Private/HarnessConfig.ps1")
. (Join-Path $PSScriptRoot "Private/AdapterRegistry.ps1")

# 2. Adapters — each registers itself at the bottom of its file.
. (Join-Path $PSScriptRoot "Adapters/ClaudeCodeAdapter.ps1")
. (Join-Path $PSScriptRoot "Adapters/CodexAdapter.ps1")
. (Join-Path $PSScriptRoot "Adapters/GeminiAdapter.ps1")

# --- Public dispatch API ---

$script:LastHarnessRateLimitInfo = $null

function Invoke-HarnessStream {
    <#
    .SYNOPSIS
    Streaming invocation of the active harness with detailed per-event logging.

    .DESCRIPTION
    Loads the harness config, looks up the registered adapter, and invokes its
    Stream scriptblock. Captures the adapter's rate-limit message for
    Get-LastHarnessRateLimitInfo to retrieve afterwards.

    .PARAMETER Prompt
    The prompt to send.

    .PARAMETER Model
    Full model id (default: harness default model).

    .PARAMETER SessionId
    Optional session id for conversation continuity (harnesses that support it).

    .PARAMETER PersistSession
    Whether to persist the session locally.

    .PARAMETER ShowDebugJson
    Show raw JSON events on stderr.

    .PARAMETER ShowVerbose
    Show detailed tool results and metadata.

    .PARAMETER HarnessName
    Override active harness name (default: from settings).

    .PARAMETER PermissionMode
    Permission mode key from the harness config (e.g. "bypassPermissions").

    .PARAMETER WorkingDirectory
    Optional cwd for the spawned harness process. Honored by adapters that
    explicitly support it (Claude pins it via ProcessStartInfo). Used by task
    execution to direct file edits at a per-task git worktree (#314).
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
        [string]$HarnessName,
        [string]$PermissionMode,
        [string]$WorkingDirectory
    )

    $script:LastHarnessRateLimitInfo = $null

    $config = Get-HarnessConfig -Name $HarnessName
    $adapter = Get-HarnessAdapter -Name $config.adapter

    $forwardArgs = @{
        Prompt   = $Prompt
        Config   = $config
    }
    if ($Model)             { $forwardArgs['Model'] = $Model }
    if ($SessionId)         { $forwardArgs['SessionId'] = $SessionId }
    if ($PersistSession)    { $forwardArgs['PersistSession'] = $true }
    if ($ShowDebugJson)     { $forwardArgs['ShowDebugJson'] = $true }
    if ($ShowVerbose)       { $forwardArgs['ShowVerbose'] = $true }
    if ($PermissionMode)    { $forwardArgs['PermissionMode'] = $PermissionMode }
    if ($WorkingDirectory)  { $forwardArgs['WorkingDirectory'] = $WorkingDirectory }

    try {
        & $adapter.Stream @forwardArgs
    } finally {
        $script:LastHarnessRateLimitInfo = & $adapter.GetLastRateLimit
    }
}

function Invoke-Harness {
    <#
    .SYNOPSIS
    Simple (non-streaming) invocation of the active harness.

    .PARAMETER Prompt
    The prompt to send.

    .PARAMETER Model
    Full model id (default: harness default).

    .PARAMETER HarnessName
    Override active harness name (default: from settings).

    .PARAMETER PermissionMode
    Permission mode key from the harness config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model,

        [string]$HarnessName,
        [string]$PermissionMode
    )

    $config = Get-HarnessConfig -Name $HarnessName
    $adapter = Get-HarnessAdapter -Name $config.adapter

    $forwardArgs = @{
        Prompt = $Prompt
        Config = $config
    }
    if ($Model)          { $forwardArgs['Model'] = $Model }
    if ($PermissionMode) { $forwardArgs['PermissionMode'] = $PermissionMode }

    & $adapter.Invoke @forwardArgs
}

function New-HarnessSession {
    <#
    .SYNOPSIS
    Creates a new session id for the active harness. Returns a string id for
    harnesses that support sessions, or $null for those that don't.
    #>
    [CmdletBinding()]
    param(
        [string]$HarnessName
    )

    $config = Get-HarnessConfig -Name $HarnessName
    $adapter = Get-HarnessAdapter -Name $config.adapter
    return & $adapter.NewSession -Config $config
}

function Remove-HarnessSession {
    <#
    .SYNOPSIS
    Removes a harness session's local artifacts. Dispatches to the active
    adapter's RemoveSession scriptblock.

    .PARAMETER SessionId
    Session id to remove.

    .PARAMETER ProjectRoot
    Path to the project root directory.

    .PARAMETER HarnessName
    Override active harness name (default: from settings).
    #>
    [CmdletBinding()]
    param(
        [string]$SessionId,

        [Parameter(Mandatory)]
        [string]$ProjectRoot,

        [string]$HarnessName
    )

    if (-not $SessionId) { return $false }

    $config = Get-HarnessConfig -Name $HarnessName
    $adapter = Get-HarnessAdapter -Name $config.adapter
    return & $adapter.RemoveSession -Config $config -SessionId $SessionId -ProjectRoot $ProjectRoot
}

function Get-LastHarnessRateLimitInfo {
    <#
    .SYNOPSIS
    Returns the most recent rate-limit message captured by the last harness
    stream invocation. $null if no rate limit was hit.
    #>
    [CmdletBinding()]
    param()
    return $script:LastHarnessRateLimitInfo
}

Export-ModuleMember -Function @(
    # Dispatch API
    'Invoke-HarnessStream'
    'Invoke-Harness'
    'New-HarnessSession'
    'Remove-HarnessSession'
    'Get-HarnessConfig'
    'Get-HarnessModels'
    'Resolve-HarnessModelId'
    'Build-HarnessCliArgs'
    'Get-LastHarnessRateLimitInfo'
    # Adapter introspection
    'Get-RegisteredHarnessAdapters'
    # Cross-cutting utilities
    'Write-ActivityLog'
    'Get-RateLimitResetTime'
    'Get-FailureReason'
)
