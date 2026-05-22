<#
.SYNOPSIS
Compatibility shim for runtime-owned session-tracking helpers.

.DESCRIPTION
Session tracking now lives in Dotbot.SessionTracking. Existing MCP callers can
keep importing this module — it forwards to Dotbot.SessionTracking via a
global import so the same function names remain available.
#>

$sessionModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime' 'Modules' 'Dotbot.SessionTracking' 'Dotbot.SessionTracking.psd1'
if (-not (Get-Module Dotbot.SessionTracking)) {
    Import-Module $sessionModule -DisableNameChecking -Global
}
