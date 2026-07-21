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
    $projectRuntimeHome = Get-DotbotProjectLocalInstallPath
    if (-not [string]::IsNullOrWhiteSpace($projectRuntimeHome)) {
        return $projectRuntimeHome
    }

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

function Get-DotbotProjectLocalInstallPath {
    [CmdletBinding()]
    param(
        [string]$StartDir = $PWD.Path
    )

    if ([string]::IsNullOrWhiteSpace($StartDir)) { return $null }

    try {
        $dir = [System.IO.Path]::GetFullPath($StartDir)
    } catch {
        return $null
    }

    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $botDir = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $botDir) {
            $runtimeRoot = Join-Path $botDir 'runtime'
            $runtimeCli = Join-Path $runtimeRoot 'bin' 'dotbot.ps1'
            $runtimeContent = Join-Path $runtimeRoot 'content' 'workspace-template'
            if ((Test-Path -LiteralPath $runtimeCli -PathType Leaf) -and
                (Test-Path -LiteralPath $runtimeContent -PathType Container)) {
                return [System.IO.Path]::GetFullPath($runtimeRoot)
            }
            return $null
        }

        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $null }

        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

function Get-DotbotVendoredInstallPath {
    return Get-DotbotProjectLocalInstallPath
}

function Get-DotbotUserSettingsPath {
    <#
    .SYNOPSIS
    Returns the absolute path to the user-level dotbot settings file.

    .DESCRIPTION
    Resolves to %APPDATA%\dotbot\user-settings.json on Windows and
    $XDG_CONFIG_HOME/dotbot/user-settings.json (or ~/.config/dotbot/user-settings.json
    when XDG_CONFIG_HOME is unset) on Linux/macOS.

    The directory may not exist yet; callers that write the file must create it.
    The path is decoupled from DOTBOT_HOME so user-level preferences survive
    checkout swaps.
    #>
    [CmdletBinding()]
    param()

    if ($IsWindows) {
        $base = [Environment]::GetEnvironmentVariable('APPDATA')
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path $HOME 'AppData' 'Roaming'
        }
    } else {
        $base = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path $HOME '.config'
        }
    }

    $full = Join-Path $base 'dotbot' 'user-settings.json'
    try {
        return [System.IO.Path]::GetFullPath($full)
    } catch {
        return $full
    }
}

function Get-DotbotUserContentPath {
    <#
    .SYNOPSIS
    Returns the absolute path for global dotbot content installs.

    .DESCRIPTION
    Resolves to <DOTBOT_HOME>/content. Global content installs intentionally
    write into the selected dotbot home content tree so one DOTBOT_HOME fully
    defines the runtime, registries, and content it can resolve.

    The directory may not exist yet; callers that write content must create it.
    Project content still wins over this directory at runtime.
    #>
    [CmdletBinding()]
    param()

    $full = Join-Path (Get-DotbotInstallPath) 'content'
    try {
        return [System.IO.Path]::GetFullPath($full)
    } catch {
        return $full
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

        if (Test-Path (Join-Path $dir '.git')) { break }

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

    # Serialize the read-modify-write across concurrent runs. Without this,
    # two runs that both observe a missing instance_id each mint a fresh GUID
    # and the second write clobbers the first. The named mutex gives total
    # cross-process mutual exclusion (no timeout, no poll); the write is atomic
    # (temp-then-rename), so the mint is idempotent under any interleaving.
    return Invoke-WithNamedMutex -Name ("instance-id:" + [System.IO.Path]::GetFullPath($SettingsPath)) -Action {
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
                Write-SettingsJsonAtomic -Path $SettingsPath -Object $settings
            }
            return $normalized
        }

        $newInstanceId = [guid]::NewGuid().ToString()
        $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue $newInstanceId -Force
        Write-SettingsJsonAtomic -Path $SettingsPath -Object $settings
        return $newInstanceId
    }
}

# ── Cross-process mutual exclusion ───────────────────────────────────────────
# Run a script block under an OS-level named mutex. Acquisition blocks with NO
# timeout and NO poll loop; if the holding process dies, the kernel releases the
# mutex and the next waiter is granted ownership via AbandonedMutexException
# (caught below) — so there is no stale-lock state and no wall-clock timer on any
# correctness path. ReleaseMutex must run on the acquiring thread, which it does
# (acquire + release are in the same synchronous call here).
#
# NOTE: this primitive is intentionally duplicated in the few modules that need
# it (Dotbot.Core, Dotbot.Worktree, SettingsAPI) rather than shared via import,
# to avoid cross-module load-order coupling — matching the codebase's existing
# per-module lock-helper convention.
function Invoke-WithNamedMutex {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    # Internal locals are '$__nm'-prefixed so they cannot shadow any variable the
    # caller's $Action references via dynamic scope when invoked with '& $Action'.
    $__nmSha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $__nmHash = ([System.BitConverter]::ToString(
            $__nmSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Name))) -replace '-', '').Substring(0, 32)
    } finally {
        $__nmSha.Dispose()
    }
    $__nmMutex = [System.Threading.Mutex]::new($false, "Global\dotbot-$__nmHash")
    $__nmOwns = $false
    try {
        try {
            $__nmOwns = $__nmMutex.WaitOne()
        } catch [System.Threading.AbandonedMutexException] {
            # Prior holder crashed; kernel granted us the mutex. Safe to proceed —
            # the action re-reads shared state, so a partially-applied prior op is
            # observed and corrected, not assumed.
            $__nmOwns = $true
        }
        return (& $Action)
    } finally {
        if ($__nmOwns) { try { $__nmMutex.ReleaseMutex() } catch { $null = $_ } }
        $__nmMutex.Dispose()
    }
}

# Atomic JSON write: serialize to a sibling temp file then rename over the
# target so a concurrent reader never observes a half-written file.
function Write-SettingsJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force
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

#region External Command Resolution

# On Windows, Machine PATH and User PATH are merged into the process PATH at
# login, but a spawned process can inherit a PATH missing one scope (e.g. Git
# installed system-wide -> Machine PATH, a provider CLI installed per-user ->
# User PATH). Get-Command only searches the process PATH, so tools that are
# installed and registered on the machine get reported as missing. These
# helpers resolve commands across all three scopes and can repair the session
# PATH so downstream Get-Command calls and process spawns succeed.

$script:ExternalCommandProbeExtensions = @('exe', 'cmd', 'bat', 'ps1')

function Get-DotbotRegistryPathDirectories {
    # Windows-only: PATH directories registered in a registry scope.
    param([Parameter(Mandatory)][ValidateSet('Machine', 'User')][string]$Scope)

    if (-not $IsWindows) { return @() }
    $raw = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw -split [IO.Path]::PathSeparator | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Find-DotbotCommandInDirectory {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Directory
    )

    $probes = if ([IO.Path]::GetExtension($Name)) {
        @($Name)
    } else {
        @($script:ExternalCommandProbeExtensions | ForEach-Object { "$Name.$_" })
    }
    foreach ($probe in $probes) {
        try {
            $candidate = Join-Path $Directory $probe
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        } catch {
            # Malformed PATH entries throw on Join-Path/Test-Path; skip them.
        }
    }
    return $null
}

function Resolve-DotbotExternalCommand {
    <#
    .SYNOPSIS
    Resolves an external command via the process PATH, falling back to the
    registry Machine and User PATH scopes on Windows.

    .DESCRIPTION
    Returns a hashtable: @{ Found; Name; Source; Directory; Scope; Repaired }
    where Scope is 'Process', 'Machine', or 'User'. With -RepairSessionPath,
    a registry-scope hit appends the containing directory to the process
    $env:PATH so later Get-Command calls and spawns in this process succeed.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$RepairSessionPath
    )

    $cmd = Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) {
        $source = if ($cmd.PSObject.Properties['Source'] -and $cmd.Source) { $cmd.Source } else { $cmd.Path }
        return @{
            Found     = $true
            Name      = $Name
            Source    = $source
            Directory = (Split-Path $source -Parent)
            Scope     = 'Process'
            Repaired  = $false
        }
    }

    if (-not $IsWindows) {
        return @{ Found = $false; Name = $Name }
    }

    foreach ($scope in @('Machine', 'User')) {
        foreach ($dir in (Get-DotbotRegistryPathDirectories -Scope $scope)) {
            $hit = Find-DotbotCommandInDirectory -Name $Name -Directory $dir
            if (-not $hit) { continue }

            $repaired = $false
            if ($RepairSessionPath) {
                $normalized = $dir.TrimEnd('\', '/')
                $present = @($env:PATH -split [IO.Path]::PathSeparator) |
                    Where-Object { $_ -and ($_.TrimEnd('\', '/') -ieq $normalized) }
                if (-not $present) {
                    $env:PATH = $env:PATH + [IO.Path]::PathSeparator + $dir
                }
                $repaired = $true
            }

            return @{
                Found     = $true
                Name      = $Name
                Source    = $hit
                Directory = $dir
                Scope     = $scope
                Repaired  = $repaired
            }
        }
    }

    return @{ Found = $false; Name = $Name }
}

function Repair-DotbotProcessPath {
    <#
    .SYNOPSIS
    Merges registry Machine/User PATH directories missing from the process
    PATH into $env:PATH (Windows split-PATH repair).

    .DESCRIPTION
    Returns the list of appended directories. No-op on non-Windows platforms
    and when DOTBOT_SKIP_PATH_REPAIR is set. Runs once per module load unless
    -Force is passed; the merge is append-only, so repeats are harmless.
    #>
    param([switch]$Force)

    if (-not $IsWindows) { return @() }
    if ($env:DOTBOT_SKIP_PATH_REPAIR) { return @() }
    if ($script:DotbotProcessPathRepaired -and -not $Force) { return @() }
    $script:DotbotProcessPathRepaired = $true

    $processDirs = @($env:PATH -split [IO.Path]::PathSeparator |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') })
    $appended = @()
    foreach ($scope in @('Machine', 'User')) {
        foreach ($dir in (Get-DotbotRegistryPathDirectories -Scope $scope)) {
            $normalized = $dir.TrimEnd('\', '/')
            $known = @($processDirs) | Where-Object { $_ -ieq $normalized }
            if ($known) { continue }
            $env:PATH = $env:PATH + [IO.Path]::PathSeparator + $dir
            $processDirs += $normalized
            $appended += $dir
        }
    }
    return $appended
}

#endregion

Export-ModuleMember -Function @(
    'Get-DotbotInstallPath'
    'Get-DotbotProjectLocalInstallPath'
    'Get-DotbotVendoredInstallPath'
    'Get-DotbotUserSettingsPath'
    'Get-DotbotUserContentPath'
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
    'Resolve-DotbotExternalCommand'
    'Repair-DotbotProcessPath'
)
