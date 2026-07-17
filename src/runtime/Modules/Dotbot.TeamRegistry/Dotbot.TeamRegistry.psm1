<#
.SYNOPSIS
Dotbot team registry — sole writer of .bot/team-registry.json.

Registry shape (schema_version = 1):
    {
      "schema_version": 1,
      "members": [
        { "id": "tm_XXXXXXXX", "name": "...", "email": "...",
          "role": "developer|lead|reviewer|qa",
          "created_at": "RFC3339-Z", "created_by": "cli|api|..." }
      ]
    }

Writers hold a named-mutex lock around the full read-modify-write cycle so
concurrent `dotbot team add` invocations can't lose each other's writes.
Atomic temp-file rename on top prevents readers from seeing a torn file.

`id` generation contract: `tm_` + 8 characters uniform-drawn from the
62-char alphabet [0-9a-zA-Z] via System.Security.Cryptography.RandomNumberGenerator
with rejection sampling. Collision domain is 62**8 ≈ 2.18e14 — safe for any
plausible team size. See _New-TeamMemberId + the collision retry in
Add-DotbotTeamMember for the belt-and-suspenders check.

All CLI + future MCP surfaces should go through this module rather than
touching the JSON directly.
#>

$script:SCHEMA_VERSION = 1
$script:NAME_REGEX     = '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$'
$script:EMAIL_REGEX    = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
$script:VALID_ROLES    = @('developer', 'lead', 'reviewer', 'qa')
$script:ID_ALPHABET    = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
$script:ID_LENGTH      = 8
$script:ID_PREFIX      = 'tm_'
$script:LOCK_TIMEOUT_MS = 5000

function Get-DotbotTeamRegistryPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BotRoot)
    return (Join-Path $BotRoot 'team-registry.json')
}

function _New-TeamMemberId {
    # CSRNG rejection sampling over a 62-char alphabet for uniform distribution.
    # Threshold = floor(256 / 62) * 62 = 248. Bytes >= 248 are discarded.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $sb  = [System.Text.StringBuilder]::new($script:ID_LENGTH)
        $buf = [byte[]]::new(1)
        while ($sb.Length -lt $script:ID_LENGTH) {
            $rng.GetBytes($buf)
            if ($buf[0] -lt 248) {
                [void]$sb.Append($script:ID_ALPHABET[$buf[0] % $script:ID_ALPHABET.Length])
            }
        }
        return "$($script:ID_PREFIX)$($sb.ToString())"
    } finally {
        $rng.Dispose()
    }
}

function _Write-TeamRegistryJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding utf8NoBOM
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function _New-EmptyRegistry {
    return [ordered]@{
        schema_version = $script:SCHEMA_VERSION
        members        = @()
    }
}

function _Acquire-TeamRegistryLock {
    <#
    .SYNOPSIS
    Acquire a cross-process lock keyed on the registry file's absolute path.

    .DESCRIPTION
    Uses a named System.Threading.Mutex so two concurrent dotbot processes on
    the same machine serialize their read-modify-write cycles. Returns the
    mutex; caller must release with _Release-TeamRegistryLock.
    #>
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [int]$TimeoutMs = $script:LOCK_TIMEOUT_MS
    )
    $path = Get-DotbotTeamRegistryPath -BotRoot $BotRoot
    try {
        $abs = [System.IO.Path]::GetFullPath($path)
    } catch {
        $abs = $path
    }
    # Hash the path so the mutex name is stable, safe (no path chars),
    # and short enough for Global\ namespace.
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($abs.ToLowerInvariant()))
        $hashHex   = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    } finally {
        $hasher.Dispose()
    }
    $mutexName = "Global\dotbot-team-registry-$($hashHex.Substring(0, 16))"

    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    try {
        if (-not $mutex.WaitOne($TimeoutMs)) {
            $mutex.Dispose()
            throw "Timed out waiting for team registry lock ($TimeoutMs ms). Another dotbot process may be adding a member."
        }
    } catch [System.Threading.AbandonedMutexException] {
        # Prior owner crashed without releasing. WaitOne throws but we now
        # hold the mutex — safe to proceed since we're about to overwrite
        # the file atomically anyway.
        $null = $_
    }
    return $mutex
}

function _Release-TeamRegistryLock {
    param([Parameter(Mandatory)]$Lock)
    try { $Lock.ReleaseMutex() } catch { $null = $_ }
    try { $Lock.Dispose() }      catch { $null = $_ }
}

function Read-DotbotTeamRegistry {
    <#
    .SYNOPSIS
    Read the team registry. Returns an empty envelope if the file is missing.

    .PARAMETER BotRoot
    Path to the project's .bot directory.

    .OUTPUTS
    Hashtable: @{ schema_version = <int>; members = <array of hashtables> }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BotRoot)

    $path = Get-DotbotTeamRegistryPath -BotRoot $BotRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return _New-EmptyRegistry
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    } catch {
        throw "Team registry at '$path' could not be read: $($_.Exception.Message)"
    }

    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        throw "Team registry at '$path' is not valid JSON: $($_.Exception.Message)"
    }

    if ($null -eq $parsed) { return _New-EmptyRegistry }

    if (-not $parsed.Contains('schema_version')) {
        throw "Team registry at '$path' is missing schema_version."
    }
    if ($parsed.schema_version -ne $script:SCHEMA_VERSION) {
        throw "Team registry at '$path' has schema_version=$($parsed.schema_version); this build understands only version $($script:SCHEMA_VERSION)."
    }
    if (-not $parsed.Contains('members') -or $null -eq $parsed.members) {
        $parsed.members = @()
    }

    return $parsed
}

function Assert-DotbotTeamMember {
    <#
    .SYNOPSIS
    Validate a member instance. Throws with an actionable message on failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Member)

    foreach ($required in @('id', 'name', 'email', 'created_at', 'created_by')) {
        if (-not $Member.Contains($required) -or [string]::IsNullOrWhiteSpace([string]$Member[$required])) {
            throw "Team member is missing required field '$required'."
        }
    }

    if ([string]$Member.name -notmatch $script:NAME_REGEX) {
        throw "Team member name '$($Member.name)' is invalid. Names must match: $($script:NAME_REGEX) (start with alphanumeric; 1-64 chars; letters, digits, dot, dash, underscore)."
    }

    if ([string]$Member.email -notmatch $script:EMAIL_REGEX) {
        throw "Team member email '$($Member.email)' is invalid. Expected a basic 'user@domain.tld' shape."
    }

    if ($Member.Contains('role') -and $null -ne $Member.role -and -not [string]::IsNullOrWhiteSpace([string]$Member.role)) {
        if ([string]$Member.role -notin $script:VALID_ROLES) {
            throw "Invalid role '$($Member.role)'. Must be one of: $($script:VALID_ROLES -join ', ')."
        }
    }
}

function _Find-TeamMemberIndex {
    param(
        [Parameter(Mandatory)]$Registry,
        [Parameter(Mandatory)][string]$Name
    )
    $needle = $Name.ToLowerInvariant()
    for ($i = 0; $i -lt $Registry.members.Count; $i++) {
        $m = $Registry.members[$i]
        if ([string]$m.name -and ([string]$m.name).ToLowerInvariant() -eq $needle) {
            return $i
        }
    }
    return -1
}

function Add-DotbotTeamMember {
    <#
    .SYNOPSIS
    Persist a new team member to the workspace registry.

    .DESCRIPTION
    Read-modify-write is serialized under a named mutex keyed to the registry
    path so concurrent `dotbot team add` calls can't clobber each other. The
    write itself is a temp-file rename so readers never see a torn file.

    Rejects duplicate names (case-insensitive) and invalid role / email
    values. Returns the newly created member on success.

    .PARAMETER BotRoot
    Path to the project's .bot directory.

    .PARAMETER Name
    Case-preserving unique identifier for the member.

    .PARAMETER Email
    Contact address for downstream Q&A routing (#632/#600/#609). Required.

    .PARAMETER Role
    Optional role — must be one of: developer, lead, reviewer, qa.

    .PARAMETER CreatedBy
    Origin of the request. Defaults to 'cli'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Email,
        [string]$Role,
        [string]$CreatedBy = 'cli'
    )

    if ($Name -notmatch $script:NAME_REGEX) {
        throw "Invalid name '$Name'. Names must match: $($script:NAME_REGEX) (start with alphanumeric; 1-64 chars; letters, digits, dot, dash, underscore)."
    }
    if ($Email -notmatch $script:EMAIL_REGEX) {
        throw "Invalid email '$Email'. Expected 'user@domain.tld' shape."
    }
    if (-not [string]::IsNullOrWhiteSpace($Role) -and $Role -notin $script:VALID_ROLES) {
        throw "Invalid role '$Role'. Must be one of: $($script:VALID_ROLES -join ', ')."
    }

    $lock = _Acquire-TeamRegistryLock -BotRoot $BotRoot
    try {
        $registry = Read-DotbotTeamRegistry -BotRoot $BotRoot
        $existingIdx = _Find-TeamMemberIndex -Registry $registry -Name $Name
        if ($existingIdx -ge 0) {
            $existing = $registry.members[$existingIdx]
            throw "Team member '$Name' already exists (id: $($existing.id)). Names are case-insensitive; a follow-up ticket will add 'dotbot team update'."
        }

        # Belt-and-suspenders: re-draw id on the astronomically unlikely
        # collision with an existing member. Collision domain is 62^8 ≈ 2e14.
        $existingIds = @{}
        foreach ($m in $registry.members) { if ($m.id) { $existingIds[$m.id] = $true } }
        do { $newId = _New-TeamMemberId } while ($existingIds.Contains($newId))

        $member = [ordered]@{
            id         = $newId
            name       = $Name
            email      = $Email
            role       = if ([string]::IsNullOrWhiteSpace($Role)) { $null } else { $Role }
            created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            created_by = $CreatedBy
        }

        Assert-DotbotTeamMember -Member $member

        $registry.members = @($registry.members) + @($member)

        $path = Get-DotbotTeamRegistryPath -BotRoot $BotRoot
        _Write-TeamRegistryJsonAtomic -Path $path -Object $registry

        return $member
    } finally {
        _Release-TeamRegistryLock -Lock $lock
    }
}

function Get-DotbotTeamMembers {
    <#
    .SYNOPSIS
    Return all team members as an array (possibly empty).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BotRoot)

    $registry = Read-DotbotTeamRegistry -BotRoot $BotRoot
    return @($registry.members)
}

function Get-DotbotTeamMember {
    <#
    .SYNOPSIS
    Return a single team member by name (case-insensitive) or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$Name
    )

    $registry = Read-DotbotTeamRegistry -BotRoot $BotRoot
    $idx = _Find-TeamMemberIndex -Registry $registry -Name $Name
    if ($idx -lt 0) { return $null }
    return $registry.members[$idx]
}

Export-ModuleMember -Function @(
    'Get-DotbotTeamRegistryPath'
    'Read-DotbotTeamRegistry'
    'Assert-DotbotTeamMember'
    'Add-DotbotTeamMember'
    'Get-DotbotTeamMembers'
    'Get-DotbotTeamMember'
)
