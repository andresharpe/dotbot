<#
.SYNOPSIS
Foundation helpers for the dotbot runtime: path resolution, workspace identity, and console-text sanitization.

.DESCRIPTION
This is the base module in the runtime DAG. It has no dependencies on any other
Dotbot.* module and is safe to import from anywhere. All other Dotbot.* modules
may depend on Dotbot.Core.

Contents:
  - Path helpers: Get-Dotbot*Path family (install/config/project/runtime/UI/logs).
  - Workspace identity: Get-OrCreateWorkspaceInstanceId reads or repairs the GUID
    stamped into settings.default.json.
  - Console sanitization: Remove-ConsoleSequences / ConvertTo-SanitizedConsoleText
    strip ANSI escapes from text headed for persisted state.
#>

#region Path Helpers

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
        if ($parent -eq $dir) { break }

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

#endregion

#region Workspace Instance ID

function Get-OrCreateWorkspaceInstanceId {
    <#
    .SYNOPSIS
    Returns a stable per-workspace GUID, reading or repairing settings.default.json as needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    if (-not (Test-Path $SettingsPath)) {
        return $null
    }

    try {
        $settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    $currentInstanceId = if ($settings.PSObject.Properties['instance_id']) {
        "$($settings.instance_id)"
    } else {
        ""
    }

    $parsedGuid = [guid]::Empty
    if ([guid]::TryParse($currentInstanceId, [ref]$parsedGuid)) {
        $normalized = $parsedGuid.ToString()
        if ($currentInstanceId -ne $normalized) {
            $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue $normalized -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath
        }
        return $normalized
    }

    $newInstanceId = [guid]::NewGuid().ToString()
    $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue $newInstanceId -Force
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath
    return $newInstanceId
}

#endregion

#region Console Sequence Sanitization

# The second alternative intentionally strips orphaned CSI fragments after the
# ESC byte is lost, but requires CSI-like parameter content or the common
# parameterless "[m" reset fragment so plain bracketed words are preserved.
$script:ConsoleSequencePattern = "(\x1B\[[0-9;?]*[ -/]*[@-~])|(\[(?:[0-9?][0-9;?]*[ -/]*[A-Za-z]|m))"

function Remove-ConsoleSequences {
    param(
        [AllowNull()]
        [object]$Text
    )

    if ($null -eq $Text) { return $null }

    $clean = [regex]::Replace([string]$Text, $script:ConsoleSequencePattern, "")
    return $clean.Trim()
}

function ConvertTo-SanitizedConsoleText {
    param(
        [AllowNull()]
        [object]$Text
    )

    $clean = Remove-ConsoleSequences $Text
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

    return $clean
}

function Update-ProcessHeartbeatFields {
    param(
        [Parameter(Mandatory)]
        [object]$Process
    )

    if ($Process.PSObject.Properties['heartbeat_status']) {
        $Process.heartbeat_status = ConvertTo-SanitizedConsoleText $Process.heartbeat_status
    }

    if ($Process.PSObject.Properties['heartbeat_next_action']) {
        $Process.heartbeat_next_action = ConvertTo-SanitizedConsoleText $Process.heartbeat_next_action
    }

    return $Process
}

#endregion

Export-ModuleMember -Function @(
    'Get-DotbotInstallPath'
    'Get-DotbotConfigPath'
    'Get-DotbotLogsPath'
    'Get-DotbotProjectPath'
    'Get-DotbotProjectBotPath'
    'Get-DotbotProjectInstallPath'
    'Get-DotbotProjectContentPath'
    'Get-DotbotProjectRuntimePath'
    'Get-DotbotProjectUIPath'
    'Get-DotbotProjectLogsPath'
    'Get-OrCreateWorkspaceInstanceId'
    'Remove-ConsoleSequences'
    'ConvertTo-SanitizedConsoleText'
    'Update-ProcessHeartbeatFields'
)
