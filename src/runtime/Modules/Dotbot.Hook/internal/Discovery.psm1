<#
.SYNOPSIS
Discovery for plugin transition hooks.

Hooks live one-folder-per-hook under a stable directory. Each folder must
contain metadata.yaml + script.ps1. Discovery scans the folder, parses each
metadata.yaml, and returns a list of hook records sorted alphabetically by
folder name — hook order within a status is the declaration order in the
directory listing.

A malformed metadata.yaml is reported as an error rather than silently
skipped, so a fixture directory with three valid hooks + one malformed
produces a startup error.
#>

# ─── Configurable schema ────────────────────────────────────────────────────

$script:DotbotHookMetadataRequiredFields = @(
    'name',
    'target_statuses',
    'max_duration',
    'abort_on_failure'
)

# Statuses a hook can declare as a target. Mirrors Dotbot.Task's status
# enum. Kept in sync manually because Dotbot.Hook is otherwise independent
# of Dotbot.Task (and we want discovery to work even if Dotbot.Task isn't
# loaded — e.g. dev tests of discovery in isolation).
$script:DotbotHookValidTargetStatuses = @(
    'todo', 'analysing', 'analysed', 'in-progress',
    'done', 'failed', 'skipped', 'cancelled', 'needs-input'
)

# ─── Default hooks directory resolution ─────────────────────────────────────

function Get-DefaultHooksDirectory {
    <#
    .SYNOPSIS
    Resolve the canonical "where do hooks live" path for a project.

    .DESCRIPTION
    Hooks live under runtime/hooks/transitions/.
    After dotbot init, this is <BotRoot>/src/runtime/hooks/transitions/.
    When running against an uninstalled source tree (dev tests), the hooks
    live next to this module in <repo>/src/runtime/hooks/transitions/.

    Resolution order:
      1. <BotRoot>/src/runtime/hooks/transitions/   ← per-project framework copy
      2. <module-source>/../hooks/transitions/      ← dev/repo fallback

    Returns $null if neither exists. Callers can pass an explicit -HooksDir
    to Get-HookRegistry to override.
    #>
    [CmdletBinding()]
    param(
        [string]$BotRoot
    )

    if ($BotRoot) {
        $projectCopy = Join-Path $BotRoot (Join-Path 'src' (Join-Path 'runtime' (Join-Path 'hooks' 'transitions')))
        if (Test-Path -LiteralPath $projectCopy -PathType Container) {
            return $projectCopy
        }
    }

    # Dev fallback: this file lives at
    # <root>/src/runtime/Modules/Dotbot.Hook/internal/Discovery.psm1,
    # so the hooks sit at <root>/src/runtime/hooks/transitions/.
    $repoCopy = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) (Join-Path 'hooks' 'transitions')
    if (Test-Path -LiteralPath $repoCopy -PathType Container) {
        return $repoCopy
    }

    return $null
}

# ─── Metadata parsing ───────────────────────────────────────────────────────

function _Parse-HookMetadataYaml {
    <#
    .SYNOPSIS
    Parse a metadata.yaml string into a hashtable. Prefers powershell-yaml;
    falls back to a minimal flat-scalar parser for the metadata shape this
    module actually uses (4 top-level keys, target_statuses inline or block list).
    #>
    param([Parameter(Mandatory)] [string]$Content)

    $yamlMod = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
    if ($yamlMod) {
        try {
            return ($Content | ConvertFrom-Yaml)
        } catch {
            # Fall through to the simple parser. Letting a YAML lib bug
            # break discovery would be hostile; the metadata schema is
            # tightly constrained and a regex parser handles all real cases.
        }
    }

    # Minimal parser: scalars, booleans, ints, inline lists `[a, b]`, and
    # block lists `- item` under a key.
    $bag = @{}
    $lines = $Content -split "`r?`n"
    $currentList = $null
    $listKey = $null
    foreach ($raw in $lines) {
        $line = $raw -replace '\s*#.*$', ''                  # strip trailing comments
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*-\s+(.+)$' -and $listKey) {
            $val = $Matches[1].Trim().Trim('"').Trim("'")
            $currentList += ,$val
            continue
        }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            # New key — flush any in-flight block list first.
            if ($listKey -and $currentList -ne $null) {
                $bag[$listKey] = $currentList
                $currentList = $null
                $listKey = $null
            }
            $k = $Matches[1]
            $v = $Matches[2].Trim()
            if (-not $v) {
                # Block-style value to follow on next line.
                $listKey = $k
                $currentList = @()
                continue
            }
            # Inline list `[a, b, c]`
            if ($v -match '^\[(.*)\]$') {
                $inner = $Matches[1]
                $items = @()
                if ($inner.Trim()) {
                    $items = $inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
                }
                $bag[$k] = ,$items
                continue
            }
            # Boolean
            if ($v -in 'true','True','TRUE')   { $bag[$k] = $true;  continue }
            if ($v -in 'false','False','FALSE') { $bag[$k] = $false; continue }
            # Int
            $intOut = 0
            if ([int]::TryParse($v, [ref]$intOut)) { $bag[$k] = $intOut; continue }
            # String — strip surrounding quotes if present
            $bag[$k] = $v.Trim('"').Trim("'")
        }
    }
    if ($listKey -and $currentList -ne $null) {
        $bag[$listKey] = $currentList
    }
    return $bag
}

function Read-HookMetadata {
    <#
    .SYNOPSIS
    Parse and validate a single hook's metadata.yaml.

    .OUTPUTS
    Hashtable record:
        @{
            name             = 'enter-done'
            description      = '...'
            target_statuses  = @('done')
            max_duration     = 60
            abort_on_failure = $true
            metadata_path    = '/path/to/metadata.yaml'
            script_path      = '/path/to/script.ps1'
            dir              = '/path/to/enter-done'
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$HookDir
    )

    if (-not (Test-Path -LiteralPath $HookDir -PathType Container)) {
        throw "Read-HookMetadata: hook directory not found: $HookDir"
    }

    $metaPath   = Join-Path $HookDir 'metadata.yaml'
    $scriptPath = Join-Path $HookDir 'script.ps1'

    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw "Read-HookMetadata: '$HookDir' is missing metadata.yaml."
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Read-HookMetadata: '$HookDir' is missing script.ps1."
    }

    $raw = Get-Content -LiteralPath $metaPath -Raw
    $parsed = _Parse-HookMetadataYaml -Content $raw
    if (-not $parsed -or $parsed.Count -eq 0) {
        throw "Read-HookMetadata: '$metaPath' did not parse to any fields."
    }

    foreach ($req in $script:DotbotHookMetadataRequiredFields) {
        if (-not $parsed.ContainsKey($req)) {
            throw "Read-HookMetadata: '$metaPath' is missing required field '$req'."
        }
    }

    # Normalise target_statuses → string[]
    $targets = @($parsed['target_statuses'])
    if ($targets.Count -eq 0) {
        throw "Read-HookMetadata: '$metaPath' has empty target_statuses (must list at least one status)."
    }
    foreach ($s in $targets) {
        if ($script:DotbotHookValidTargetStatuses -notcontains $s) {
            throw "Read-HookMetadata: '$metaPath' lists unknown target status '$s'. Known: $($script:DotbotHookValidTargetStatuses -join ', ')."
        }
    }

    # Normalise max_duration → int seconds
    $maxDur = [int]$parsed['max_duration']
    if ($maxDur -le 0) {
        throw "Read-HookMetadata: '$metaPath' has non-positive max_duration ($($parsed['max_duration']))."
    }

    $abort = [bool]$parsed['abort_on_failure']

    $description = if ($parsed.ContainsKey('description')) { [string]$parsed['description'] } else { '' }

    return [ordered]@{
        name             = [string]$parsed['name']
        description      = $description
        target_statuses  = [string[]]$targets
        max_duration     = $maxDur
        abort_on_failure = $abort
        metadata_path    = $metaPath
        script_path      = $scriptPath
        dir              = $HookDir
    }
}

# ─── Registry assembly ──────────────────────────────────────────────────────

function Get-HookRegistry {
    <#
    .SYNOPSIS
    Scan the hooks directory, parse each hook's metadata, return a sorted
    list of hook records.

    .DESCRIPTION
    Discovery is deterministic and reproducible. Order is alphabetical
    by directory name. A malformed hook (bad/missing metadata, missing
    script.ps1) throws — discovery is "either all parse correctly or fail
    loudly" so a typo at startup is impossible to miss.

    .PARAMETER HooksDir
    Override the hooks root. When omitted, Get-DefaultHooksDirectory chooses.

    .PARAMETER BotRoot
    Project bot root, used by Get-DefaultHooksDirectory to find the
    per-project framework copy.

    .OUTPUTS
    @(<hookRecord>, ...). Empty array if no hooks dir exists.
    #>
    [CmdletBinding()]
    param(
        [string]$HooksDir,
        [string]$BotRoot
    )

    if (-not $HooksDir) {
        $HooksDir = Get-DefaultHooksDirectory -BotRoot $BotRoot
    }
    if (-not $HooksDir) { return @() }
    if (-not (Test-Path -LiteralPath $HooksDir -PathType Container)) { return @() }

    $registry = @()
    Get-ChildItem -LiteralPath $HooksDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property Name |
        ForEach-Object {
            # Read-HookMetadata throws on malformed entries; let it propagate.
            $registry += ,(Read-HookMetadata -HookDir $_.FullName)
        }
    return ,$registry
}

function Get-HooksForStatus {
    <#
    .SYNOPSIS
    Filter a hook registry down to hooks whose target_statuses contains $ToStatus.

    .PARAMETER Registry
    The output of Get-HookRegistry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] [string]$ToStatus
    )
    $out = @()
    foreach ($h in $Registry) {
        if ($h.target_statuses -contains $ToStatus) { $out += ,$h }
    }
    return ,$out
}

Export-ModuleMember -Function @(
    'Get-DefaultHooksDirectory'
    'Read-HookMetadata'
    'Get-HookRegistry'
    'Get-HooksForStatus'
)
