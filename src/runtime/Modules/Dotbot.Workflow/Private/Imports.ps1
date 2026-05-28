$moduleRoot = Split-Path -Parent $PSScriptRoot
$runtimeModules = Split-Path -Parent $moduleRoot

Import-Module (Join-Path $runtimeModules 'Dotbot.Core' 'Dotbot.Core.psm1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'ContentResolver' 'ContentResolver.psm1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Task' 'Dotbot.Task.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.TaskFile' 'Dotbot.TaskFile.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Settings' 'Dotbot.Settings.psd1') -DisableNameChecking -Global
