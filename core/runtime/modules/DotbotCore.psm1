<#
.SYNOPSIS
    Shared low-level helpers used across dotbot runtime modules.
#>

function Get-DotbotInstallPath {
    return (Join-Path $HOME 'dotbot')
}

function Get-DotbotConfigPath {
    return (Get-DotbotInstallPath)
}

function Get-DotbotLogsPath {
    return $null
}

function Get-DotbotProjectPath {
    $projectBotPath = Get-DotbotProjectBotPath

    return Split-Path -Parent $projectBotPath
}

function Get-DotbotProjectBotPath {
    $dir = $PWD.Path

    while ($dir) {
        if (Test-Path (Join-Path $dir '.bot')) {
            return (Join-Path $dir '.bot')
        }

        $parent = Split-Path -Parent $dir

        if ($parent -eq $dir) {
            break
        }

        $dir = $parent
    }

    return Join-Path ([System.IO.Path]::GetTempPath()) '.bot'
}

function Get-DotbotProjectLogsPath {
    $projectBotPath = Get-DotbotProjectBotPath
    $logsDir = Join-Path $projectBotPath '.control' 'logs'

    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    }

    return $logsDir
}
