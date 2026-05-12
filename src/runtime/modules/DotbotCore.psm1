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

function Get-DotbotProjectInstallPath {
    # Engine umbrella in a target project's .bot/. Contains runtime/, mcp/,
    # ui/, hooks/ — code that runs, as opposed to content/ which holds
    # agents/, skills/, prompts/, etc.
    $projectBotPath = Get-DotbotProjectBotPath

    return Join-Path $projectBotPath 'src'
}

function Get-DotbotProjectContentPath {
    # Content umbrella in a target project's .bot/. Contains agents/,
    # skills/, prompts/, recipes/, settings/, workspace-template/.
    $projectBotPath = Get-DotbotProjectBotPath

    return Join-Path $projectBotPath 'content'
}

function Get-DotbotProjectRuntimePath {
    $projectInstallPath = Get-DotbotProjectInstallPath

    return Join-Path $projectInstallPath 'runtime'
}

function Get-DotbotProjectUIPath {
    $projectInstallPath = Get-DotbotProjectInstallPath

    return Join-Path $projectInstallPath 'ui'
}

function Get-DotbotProjectLogsPath {
    $projectBotPath = Get-DotbotProjectBotPath
    $logsDir = Join-Path $projectBotPath '.control' 'logs'

    if (-not (Test-Path $logsDir)) {
        New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    }

    return $logsDir
}
