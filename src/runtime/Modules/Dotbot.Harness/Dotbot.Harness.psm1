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
        Failure.ps1          : exit-code → failure classifier
        HarnessConfig.ps1    : provider JSON loader, model resolution, CLI args
        AdapterRegistry.ps1  : Register-HarnessAdapter / Get-HarnessAdapter

    Adapters/    — one .ps1 per harness. Each registers itself via
                   Register-HarnessAdapter with scriptblocks implementing the
                   contract (Stream, Invoke, NewSession, RemoveSession).
                   See Private/AdapterRegistry.ps1 for the contract spec.

The public API in this file is harness-agnostic; the active harness is
selected by the `provider` field in the merged settings chain and the
`adapter` field in the resolved provider JSON.

Dependencies: Dotbot.Core (paths, sanitization), Dotbot.Theme (console output),
Dotbot.Settings (provider selection). Logs through Dotbot.Logging when present.
#>

# Console theming — adapters share $script:theme for rendering
if (-not (Get-Module Dotbot.Theme)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Theme' 'Dotbot.Theme.psd1') -DisableNameChecking
}
$script:theme = Get-DotbotTheme

# Dotbot.Core (paths, sanitization)
if (-not (Get-Module Dotbot.Core)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Core' 'Dotbot.Core.psm1') -DisableNameChecking
}

# Dotbot.Settings (active harness selection from merged settings)
if (-not (Get-Module Dotbot.Settings)) {
    Import-Module (Join-Path $PSScriptRoot '..' 'Dotbot.Settings' 'Dotbot.Settings.psd1') -DisableNameChecking -Global
}

# Helpers first (Activity log + console rendering used by adapters), then
# the registry, then adapters which self-register.
. (Join-Path $PSScriptRoot "Private/ActivityLog.ps1")
. (Join-Path $PSScriptRoot "Private/ConsoleRender.ps1")
. (Join-Path $PSScriptRoot "Private/Failure.ps1")
. (Join-Path $PSScriptRoot "Private/HarnessConfig.ps1")
. (Join-Path $PSScriptRoot "Private/AdapterRegistry.ps1")
. (Join-Path $PSScriptRoot "Adapters/ClaudeCodeAdapter.ps1")
. (Join-Path $PSScriptRoot "Adapters/CodexAdapter.ps1")
. (Join-Path $PSScriptRoot "Adapters/GeminiAdapter.ps1")

# --- Public dispatch API ---

function Invoke-HarnessStream {
    <#
    .SYNOPSIS
    Streaming invocation of the active harness with detailed per-event logging.
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

    $config = Get-HarnessConfig -Name $HarnessName
    $adapter = Get-HarnessAdapter -Name $config.adapter

    $forwardArgs = @{ Prompt = $Prompt; Config = $config }
    if ($Model)            { $forwardArgs.Model = $Model }
    if ($SessionId)        { $forwardArgs.SessionId = $SessionId }
    if ($PersistSession)   { $forwardArgs.PersistSession = $true }
    if ($ShowDebugJson)    { $forwardArgs.ShowDebugJson = $true }
    if ($ShowVerbose)      { $forwardArgs.ShowVerbose = $true }
    if ($PermissionMode)   { $forwardArgs.PermissionMode = $PermissionMode }
    if ($WorkingDirectory) { $forwardArgs.WorkingDirectory = $WorkingDirectory }

    & $adapter.Stream @forwardArgs
}

function Invoke-Harness {
    <#
    .SYNOPSIS
    Simple (non-streaming) invocation of the active harness.
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

    $forwardArgs = @{ Prompt = $Prompt; Config = $config }
    if ($Model)          { $forwardArgs.Model = $Model }
    if ($PermissionMode) { $forwardArgs.PermissionMode = $PermissionMode }

    & $adapter.Invoke @forwardArgs
}

function New-HarnessSession {
    <#
    .SYNOPSIS
    Creates a new session id for the active harness. Returns a string id for
    harnesses that support sessions, or $null for those that don't.
    #>
    [CmdletBinding()]
    param([string]$HarnessName)

    $config = Get-HarnessConfig -Name $HarnessName
    $adapter = Get-HarnessAdapter -Name $config.adapter
    & $adapter.NewSession -Config $config
}

function Remove-HarnessSession {
    <#
    .SYNOPSIS
    Removes a harness session's local artifacts. Dispatches to the active
    adapter's RemoveSession scriptblock.
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
    & $adapter.RemoveSession -Config $config -SessionId $SessionId -ProjectRoot $ProjectRoot
}

Export-ModuleMember -Function @(
    'Invoke-HarnessStream'
    'Invoke-Harness'
    'New-HarnessSession'
    'Remove-HarnessSession'
    'Get-HarnessConfig'
    'Get-HarnessModels'
    'Resolve-HarnessModelId'
    'Build-HarnessCliArgs'
    'Get-RegisteredHarnessAdapters'
    'Write-ActivityLog'
    'Get-FailureReason'
)
