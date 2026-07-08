$moduleRoot = Split-Path -Parent $PSScriptRoot
$runtimeModules = Split-Path -Parent $moduleRoot

Import-Module (Join-Path $runtimeModules 'Dotbot.Task' 'Dotbot.Task.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.TaskInput' 'Dotbot.TaskInput.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Workflow' 'Dotbot.Workflow.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Process' 'Dotbot.Process.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Hook' 'Dotbot.Hook.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Settings' 'Dotbot.Settings.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Handoff' 'Dotbot.Handoff.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Events' 'Dotbot.Events.psd1') -DisableNameChecking -Global
