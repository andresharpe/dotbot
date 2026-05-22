<#
.SYNOPSIS
Compatibility shim for runtime-owned task file mutation helpers.

.DESCRIPTION
Atomic task JSON file mutation now lives in Dotbot.TaskFile so runtime modules
do not depend on MCP modules for task persistence primitives. Existing MCP
callers can keep importing this module — it forwards to Dotbot.TaskFile via a
global import so the same function names remain available.
#>

$taskFileModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime' 'Modules' 'Dotbot.TaskFile' 'Dotbot.TaskFile.psd1'
if (-not (Get-Module Dotbot.TaskFile)) {
    Import-Module $taskFileModule -DisableNameChecking -Global
}
