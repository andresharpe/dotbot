<#
.SYNOPSIS
Foundation helpers for the dotbot runtime: path resolution, workspace identity, and console-text sanitization.

.DESCRIPTION
This is the base module in the runtime DAG. It has no dependencies on any other
Dotbot.* module and is safe to import from anywhere. All other Dotbot.* modules
may depend on Dotbot.Core.

Contents:
  - Path helpers: Get-Dotbot*Path family (install/project/runtime/UI/logs).
  - Workspace identity: Get-OrCreateWorkspaceInstanceId reads or repairs the GUID
    stamped into settings.default.json.
  - Console sanitization: ConvertTo-SanitizedConsoleText strips ANSI escapes
    from text headed for persisted state.
  - Path sanitization: Remove-AbsolutePaths strips user-specific absolute paths
    from text headed for logs or activity streams.
#>

#region Path Helpers

function Get-DotbotInstallPath {
    $configuredHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
    if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        return (Join-Path $HOME 'dotbot')
    }

    $configuredHome = $configuredHome.Trim()
    if ($configuredHome -eq '~') {
        $configuredHome = $HOME
    } elseif ($configuredHome.StartsWith('~/') -or $configuredHome.StartsWith('~\')) {
        $configuredHome = Join-Path $HOME $configuredHome.Substring(2)
    }

    try {
        return [System.IO.Path]::GetFullPath($configuredHome)
    } catch {
        return $configuredHome
    }
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

#region Path Sanitization

function Remove-AbsolutePaths {
    <#
    .SYNOPSIS
    Removes absolute file-system paths from a text string.

    .PARAMETER Text
    The string to sanitize.

    .PARAMETER ProjectRoot
    Optional project root path. All occurrences (backslash, forward-slash,
    and JSON-escaped variants) are replaced with '.'.

    .OUTPUTS
    The sanitized string.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [string]$ProjectRoot
    )

    if (-not $Text) { return $Text }

    # Replace known project root with '.' before the broader user-home safety net.
    if ($ProjectRoot) {
        # JSON-escaped double-backslash variant (e.g. C:\\Users\\<user>\\repos\\project)
        $doubleEscaped = $ProjectRoot -replace '\\', '\\'
        if ($doubleEscaped -ne $ProjectRoot) {
            $Text = $Text -replace [regex]::Escape($doubleEscaped), '.'
        }

        # Native backslash variant (e.g. C:\Users\<user>\repos\project)
        $Text = $Text -replace [regex]::Escape($ProjectRoot), '.'

        # Forward-slash variant (e.g. /c/Users/<user>/repos/project or C:/Users/<user>/repos/project)
        $forwardSlash = $ProjectRoot -replace '\\', '/'
        if ($forwardSlash -ne $ProjectRoot) {
            $Text = $Text -replace [regex]::Escape($forwardSlash), '.'
        }

        # Git-bash style lowercase drive letter (e.g. /c/Users/... from C:\Users\...)
        if ($ProjectRoot -match '^([A-Za-z]):\\') {
            $driveLetter = $Matches[1].ToLowerInvariant()
            $gitBashPath = '/' + $driveLetter + ($ProjectRoot.Substring(2) -replace '\\', '/')
            $Text = $Text -replace [regex]::Escape($gitBashPath), '.'
        }
    }

    # Safety net: redact remaining user-home paths.
    $Text = $Text -replace '[A-Za-z]:[/\\]+Users[/\\]+\w+', '<REDACTED>'
    $Text = $Text -replace '/home/\w+', '<REDACTED>'
    $Text = $Text -replace '/Users/\w+', '<REDACTED>'

    return $Text
}

#endregion

#region Console Sequence Sanitization

# The second alternative intentionally strips orphaned CSI fragments after the
# ESC byte is lost, but requires CSI-like parameter content or the common
# parameterless "[m" reset fragment so plain bracketed words are preserved.
$script:ConsoleSequencePattern = "(\x1B\[[0-9;?]*[ -/]*[@-~])|(\[(?:[0-9?][0-9;?]*[ -/]*[A-Za-z]|m))"

function ConvertTo-SanitizedConsoleText {
    param(
        [AllowNull()]
        [object]$Text
    )

    if ($null -eq $Text) { return $null }

    $clean = [regex]::Replace([string]$Text, $script:ConsoleSequencePattern, "").Trim()
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
    'Get-DotbotProjectPath'
    'Get-DotbotProjectBotPath'
    'Get-DotbotProjectInstallPath'
    'Get-DotbotProjectRuntimePath'
    'Get-DotbotProjectUIPath'
    'Get-DotbotProjectLogsPath'
    'Get-OrCreateWorkspaceInstanceId'
    'Remove-AbsolutePaths'
    'ConvertTo-SanitizedConsoleText'
    'Update-ProcessHeartbeatFields'
)
