<#
.SYNOPSIS
Compatibility shim for runtime-owned notification helpers.

.DESCRIPTION
Notification client logic now lives in Dotbot.Notification. Existing MCP and
UI callers can keep importing this module — it forwards to Dotbot.Notification
via a global import so the same function names remain available.
#>

$notifModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime' 'Modules' 'Dotbot.Notification' 'Dotbot.Notification.psd1'
if (-not (Get-Module Dotbot.Notification)) {
    Import-Module $notifModule -DisableNameChecking -Global
}
