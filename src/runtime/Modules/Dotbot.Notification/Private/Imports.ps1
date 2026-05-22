$moduleRoot = Split-Path -Parent $PSScriptRoot
$runtimeModules = Split-Path -Parent $moduleRoot

Import-Module (Join-Path $runtimeModules 'Dotbot.Core' 'Dotbot.Core.psd1') -DisableNameChecking -Global
Import-Module (Join-Path $runtimeModules 'Dotbot.Settings' 'Dotbot.Settings.psd1') -DisableNameChecking -Global
