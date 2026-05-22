$moduleRoot = Split-Path -Parent $PSScriptRoot
$runtimeModules = Split-Path -Parent $moduleRoot

Import-Module (Join-Path $runtimeModules 'Dotbot.Core' 'Dotbot.Core.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.TaskIndex' 'Dotbot.TaskIndex.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.TaskFile' 'Dotbot.TaskFile.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.SessionTracking' 'Dotbot.SessionTracking.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Notification' 'Dotbot.Notification.psd1') -DisableNameChecking -Global
