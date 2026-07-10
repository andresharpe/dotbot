# Dotbot.Decision depends on Dotbot.Core for path resolution
# (Get-DotbotProjectBotPath) and Dotbot.Settings for reading merged state.
# Imported -Global so the exported functions resolve them regardless of the
# load order at each caller site (MCP tool, poller, CLI, settings API).
$moduleRoot = Split-Path -Parent $PSScriptRoot
$runtimeModules = Split-Path -Parent $moduleRoot

Import-Module (Join-Path $runtimeModules 'Dotbot.Core' 'Dotbot.Core.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Settings' 'Dotbot.Settings.psd1') -DisableNameChecking -Global
