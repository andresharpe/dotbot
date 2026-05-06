<#
.SYNOPSIS
    Shared low-level helpers used across dotbot runtime modules.
#>

function Get-InstallPath {
    return (Join-Path $HOME 'dotbot')
}

function Get-ConfigPath {
    return (Get-InstallPath)
}

function Get-ProjectBotPath {
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

    return Join-Path ([System.IO.Path]::GetTempPath()) 'dotbot'
}

function Get-ProjectPath {
    $botPath = Get-ProjectBotPath

    if (-not $botPath) {
        return $null
    }

    return Split-Path -Parent $botPath
}

function Get-LogDirectory {
    $botDir = Get-ProjectBotPath
    $logsDir = Join-Path $botDir '.control' 'logs'

    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    }

    return $logsDir
}
