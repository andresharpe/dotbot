<#
.SYNOPSIS
    Shared low-level helpers used across dotbot runtime modules.
#>

function Get-BotDirectory {
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

function Get-LogDirectory {
    $botDir = Get-BotDirectory
    $logsDir = Join-Path $botDir '.control' 'logs'

    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    }

    return $logsDir
}
