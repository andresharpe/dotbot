<#
.SYNOPSIS
Runtime endpoint discovery + connection-file I/O.

Discovery order (low → high precedence, first match wins, highest first):
  1. Env vars: DOTBOT_RUNTIME_URL + DOTBOT_RUNTIME_TOKEN  (both must be set)
  2. Merged settings (Get-MergedSettings -BotRoot): runtime.url + runtime.token
  3. Connection file: <BotRoot>/.control/runtime.json

Partial config falls through (you cannot have a URL from env and a token from
settings) — that ambiguity is rejected on purpose.

The connection file shape is exactly what the PRD names:
    { url, token, pid, started_at }
plus a schema_version so future shape changes are detectable.
File permissions are restricted at write time:
  POSIX  → mode 0600
  Windows → user-only ACL via System.Security.AccessControl
#>

$script:DotbotRuntimeConnectionFileVersion = 1

function Get-RuntimeConnectionFilePath {
    <#
    .SYNOPSIS
    Resolve <BotRoot>/.control/runtime.json. Does not check existence.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot
    )
    return Join-Path $BotRoot (Join-Path '.control' 'runtime.json')
}

function _Set-RuntimeConnectionFilePermissions {
    param([Parameter(Mandatory)] [string]$Path)

    if ($IsLinux -or $IsMacOS) {
        # PS 7.4+ exposes SetUnixFileMode on [System.IO.File]. Older 7.x had it
        # on FileInfo only. Try the static first, fall back to chmod.
        try {
            $mode = [System.IO.UnixFileMode]'UserRead, UserWrite'
            [System.IO.File]::SetUnixFileMode($Path, $mode)
            return
        } catch {
            # Fall through to chmod below.
        }
        try {
            $null = & chmod 600 $Path 2>$null
        } catch {
            # chmod isn't fatal — runtime.json may already be created with
            # restrictive umask. Swallow per CLAUDE.md output hygiene rules.
            $null = $_
        }
        return
    }

    if ($IsWindows -or [System.Environment]::OSVersion.Platform -eq 'Win32NT') {
        try {
            $acl = Get-Acl -LiteralPath $Path
            # Break inheritance and drop any inherited entries — only the owner ACE survives.
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @($acl.Access)) {
                [void]$acl.RemoveAccessRule($rule)
            }
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $user,
                [System.Security.AccessControl.FileSystemRights]'Read,Write,Delete',
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            [void]$acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl
        } catch {
            # ACL set is best-effort; we are still loopback-only and the file
            # otherwise inherits the user-profile defaults.
            $null = $_
        }
    }
}

function Write-RuntimeConnectionFile {
    <#
    .SYNOPSIS
    Write the runtime connection file at .bot/.control/runtime.json with
    restricted permissions.

    .DESCRIPTION
    Writes the file atomically (write tmp, rename) so a reader never sees a
    half-written file. Sets POSIX 0600 / Windows user-only ACL after rename.
    #>
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [int]$ProcessId,
        [Parameter(Mandatory)] [string]$StartedAt
    )

    $path = Get-RuntimeConnectionFilePath -BotRoot $BotRoot
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $payload = [ordered]@{
        schema_version = $script:DotbotRuntimeConnectionFileVersion
        url            = $Url
        token          = $Token
        pid            = $ProcessId
        started_at     = $StartedAt
    }

    $json = $payload | ConvertTo-Json -Depth 4
    $tmp  = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    # Move-Item -Force is atomic on POSIX and best-effort on NTFS; either way
    # the tmp file picked up no restricted perms yet, so apply on the dest.
    Move-Item -LiteralPath $tmp -Destination $path -Force
    _Set-RuntimeConnectionFilePermissions -Path $path

    return $path
}

function Read-RuntimeConnectionFile {
    <#
    .SYNOPSIS
    Read and parse .bot/.control/runtime.json. Returns $null when missing
    or unparseable (callers must distinguish "no file" from "bad file" if
    they care; we report both as $null to keep discovery cheap).
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)

    $path = Get-RuntimeConnectionFilePath -BotRoot $BotRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if (-not $raw) { return $null }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        return $obj
    } catch {
        # A malformed file is indistinguishable from "no file" for discovery
        # — the caller falls through to the next layer. Swallow rather than
        # emit raw Write-Verbose (CLAUDE.md output hygiene).
        $null = $_
        return $null
    }
}

function Remove-RuntimeConnectionFile {
    <#
    .SYNOPSIS
    Remove .bot/.control/runtime.json. No-op when missing.
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)

    $path = Get-RuntimeConnectionFilePath -BotRoot $BotRoot
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function _Get-SettingsRuntimeEndpoint {
    param([Parameter(Mandatory)] [string]$BotRoot)

    # Dotbot.Runtime.psd1 loads Dotbot.Settings through ScriptsToProcess.
    # Keep this defensive null-return so private-file or broken-manifest
    # callers degrade to the connection file rather than hard-failing.
    if (-not (Get-Command Get-MergedSettings -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $merged = Get-MergedSettings -BotRoot $BotRoot
    } catch {
        return $null
    }

    if (-not $merged) { return $null }
    $runtimeNode = $null
    if ($merged.PSObject.Properties['runtime']) {
        $runtimeNode = $merged.runtime
    } elseif ($merged -is [System.Collections.IDictionary] -and $merged.Contains('runtime')) {
        $runtimeNode = $merged['runtime']
    }
    if (-not $runtimeNode) { return $null }

    $url   = $null
    $token = $null
    if ($runtimeNode -is [System.Collections.IDictionary]) {
        if ($runtimeNode.Contains('url'))   { $url   = $runtimeNode['url'] }
        if ($runtimeNode.Contains('token')) { $token = $runtimeNode['token'] }
    } else {
        if ($runtimeNode.PSObject.Properties['url'])   { $url   = $runtimeNode.url }
        if ($runtimeNode.PSObject.Properties['token']) { $token = $runtimeNode.token }
    }

    if (-not $url -or -not $token) { return $null }
    return [ordered]@{ url = [string]$url; token = [string]$token; source = 'settings' }
}

function Resolve-RuntimeEndpoint {
    <#
    .SYNOPSIS
    Resolve the runtime's URL + bearer token for the active project.

    .DESCRIPTION
    Looks up the endpoint following the runtime's discovery order. Used by
    both the MCP tools and the UI proxy so they never hard-code the
    runtime URL.

    Resolution order (first complete match wins):
      1. Env vars   : DOTBOT_RUNTIME_URL + DOTBOT_RUNTIME_TOKEN (both required)
      2. Settings   : runtime.url + runtime.token from Get-MergedSettings
      3. Conn. file : <BotRoot>/.control/runtime.json { url, token, pid, started_at }

    On success returns @{ url; token; source; pid?; started_at? } where source
    is one of 'env' / 'settings' / 'file'. pid + started_at are only set when
    the source is 'file' (env/settings don't carry them).

    Throws "Dotbot runtime endpoint not available" when no layer carries
    both a URL and a token. This is the failure the PRD names as
    "runtime not running" in the lifecycle section.

    .PARAMETER BotRoot
    The project's .bot/ root. Required so the file layer can find
    .control/runtime.json.

    .PARAMETER NoThrow
    Return $null instead of throwing when no endpoint is found.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [switch]$NoThrow
    )

    # 1. Env vars — both must be present to count as "set".
    $envUrl   = [Environment]::GetEnvironmentVariable('DOTBOT_RUNTIME_URL')
    $envToken = [Environment]::GetEnvironmentVariable('DOTBOT_RUNTIME_TOKEN')
    if ($envUrl -and $envToken) {
        return [ordered]@{
            url    = $envUrl
            token  = $envToken
            source = 'env'
        }
    }

    # 2. Settings layer.
    $settingsEndpoint = _Get-SettingsRuntimeEndpoint -BotRoot $BotRoot
    if ($settingsEndpoint) { return $settingsEndpoint }

    # 3. Connection file.
    $file = Read-RuntimeConnectionFile -BotRoot $BotRoot
    if ($file -and $file.url -and $file.token) {
        $result = [ordered]@{
            url    = [string]$file.url
            token  = [string]$file.token
            source = 'file'
        }
        if ($file.PSObject.Properties['pid'])        { $result['pid']        = $file.pid }
        if ($file.PSObject.Properties['started_at']) { $result['started_at'] = $file.started_at }
        return $result
    }

    if ($NoThrow) { return $null }
    throw "Dotbot runtime endpoint not available. Start the runtime with 'dotbot go' or set DOTBOT_RUNTIME_URL + DOTBOT_RUNTIME_TOKEN."
}

Export-ModuleMember -Function @(
    'Resolve-RuntimeEndpoint'
    'Get-RuntimeConnectionFilePath'
    'Read-RuntimeConnectionFile'
    'Write-RuntimeConnectionFile'
    'Remove-RuntimeConnectionFile'
)
