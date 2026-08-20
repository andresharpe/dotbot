<#
.SYNOPSIS
Compatibility shim for runtime-owned notification/mothership helpers.

.DESCRIPTION
Mothership client logic lives in Dotbot.Notification. Existing MCP and UI
callers can import this module — it forwards to Dotbot.Notification via a
global import so the same function names remain available.
#>

$notifModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime' 'Modules' 'Dotbot.Notification' 'Dotbot.Notification.psd1'
if (-not (Get-Module Dotbot.Notification)) {
    Import-Module $notifModule -DisableNameChecking -Global
}
