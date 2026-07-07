<#
.SYNOPSIS
Discovery for event-bus sinks.

Sinks live one-folder-per-sink under a stable directory. Each folder must
contain metadata.json + script.ps1. Discovery scans the folder, parses each
metadata.json, and returns a list of sink records sorted alphabetically by
folder name — dispatch order is the declaration order in the directory listing.

A malformed metadata.json is reported as an error rather than silently
skipped, so a fixture directory with valid sinks + one malformed produces a
startup error (parity with the Dotbot.Hook engine).

Sinks differ from transition hooks in two ways enforced elsewhere (Dispatch):
dispatch is non-aborting and out-of-band. Consequently a sink's metadata has
no `abort_on_failure` field — every sink is non-aborting by contract.
#>

# ─── Configurable schema ────────────────────────────────────────────────────

$script:DotbotSinkMetadataRequiredFields = @(
    'name',
    'subscribed_events',
    'max_duration'
)

# ─── Default sinks directory resolution ─────────────────────────────────────

function Get-DefaultSinksDirectory {
    <#
    .SYNOPSIS
    Resolve the canonical "where do sinks live" path for a project.

    .DESCRIPTION
    Sinks live under runtime/Plugins/Events/Sinks/.
    After dotbot init, this is <BotRoot>/src/runtime/Plugins/Events/Sinks/.
    When running against an uninstalled source tree (dev tests), the sinks
    live next to this module in <repo>/src/runtime/Plugins/Events/Sinks/.

    Resolution order:
      1. <BotRoot>/src/runtime/Plugins/Events/Sinks/   ← per-project framework copy
      2. <module-source>/../../Plugins/Events/Sinks/   ← dev/repo fallback

    Returns $null if neither exists. Callers can pass an explicit -SinksDir
    to Get-SinkRegistry to override.
    #>
    [CmdletBinding()]
    param(
        [string]$BotRoot
    )

    if ($BotRoot) {
        $projectCopy = Join-Path $BotRoot (Join-Path 'src' (Join-Path 'runtime' (Join-Path 'Plugins' (Join-Path 'Events' 'Sinks'))))
        if (Test-Path -LiteralPath $projectCopy -PathType Container) {
            return $projectCopy
        }
    }

    # Dev fallback: this file lives at
    # <root>/src/runtime/Modules/Dotbot.Events/Private/Discovery.psm1,
    # so the sinks sit at <root>/src/runtime/Plugins/Events/Sinks/.
    $repoCopy = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) (Join-Path 'Plugins' (Join-Path 'Events' 'Sinks'))
    if (Test-Path -LiteralPath $repoCopy -PathType Container) {
        return $repoCopy
    }

    return $null
}

# ─── Metadata parsing ───────────────────────────────────────────────────────

function _Parse-SinkMetadataJson {
    <#
    .SYNOPSIS
    Parse a metadata.json string into a hashtable.
    #>
    param([Parameter(Mandatory)] [string]$Content)

    try {
        return ($Content | ConvertFrom-Json -AsHashtable)
    } catch {
        throw "Invalid metadata.json: $($_.Exception.Message)"
    }
}

function Read-SinkMetadata {
    <#
    .SYNOPSIS
    Parse and validate a single sink's metadata.json.

    .OUTPUTS
    Hashtable record:
        @{
            name              = 'webhooks'
            description       = '...'
            subscribed_events = @('task.*', 'workflow.*')
            max_duration      = 10
            metadata_path     = '/path/to/metadata.json'
            script_path       = '/path/to/script.ps1'
            dir               = '/path/to/webhooks'
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SinkDir
    )

    if (-not (Test-Path -LiteralPath $SinkDir -PathType Container)) {
        throw "Read-SinkMetadata: sink directory not found: $SinkDir"
    }

    $metaPath   = Join-Path $SinkDir 'metadata.json'
    $scriptPath = Join-Path $SinkDir 'script.ps1'

    if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
        throw "Read-SinkMetadata: '$SinkDir' is missing metadata.json."
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Read-SinkMetadata: '$SinkDir' is missing script.ps1."
    }

    $raw = Get-Content -LiteralPath $metaPath -Raw
    $parsed = _Parse-SinkMetadataJson -Content $raw
    if (-not $parsed -or $parsed.Count -eq 0) {
        throw "Read-SinkMetadata: '$metaPath' did not parse to any fields."
    }

    foreach ($req in $script:DotbotSinkMetadataRequiredFields) {
        if (-not $parsed.ContainsKey($req)) {
            throw "Read-SinkMetadata: '$metaPath' is missing required field '$req'."
        }
    }

    # Normalise subscribed_events → string[]. Entries are glob patterns matched
    # against a concrete dotted event type (e.g. 'task.*' matches 'task.created').
    # No closed vocabulary: the bus is extensible, so any non-empty pattern is
    # legal here — an unknown family just never matches until it is published.
    $events = @($parsed['subscribed_events'])
    if ($events.Count -eq 0) {
        throw "Read-SinkMetadata: '$metaPath' has empty subscribed_events (must list at least one glob pattern)."
    }
    foreach ($e in $events) {
        if ([string]::IsNullOrWhiteSpace([string]$e)) {
            throw "Read-SinkMetadata: '$metaPath' has a blank entry in subscribed_events."
        }
    }

    # Normalise max_duration → int seconds
    $maxDur = [int]$parsed['max_duration']
    if ($maxDur -le 0) {
        throw "Read-SinkMetadata: '$metaPath' has non-positive max_duration ($($parsed['max_duration']))."
    }

    $description = if ($parsed.ContainsKey('description')) { [string]$parsed['description'] } else { '' }

    return [ordered]@{
        name              = [string]$parsed['name']
        description       = $description
        subscribed_events = [string[]]$events
        max_duration      = $maxDur
        metadata_path     = $metaPath
        script_path       = $scriptPath
        dir               = $SinkDir
    }
}

# ─── Registry assembly ──────────────────────────────────────────────────────

function Get-SinkRegistry {
    <#
    .SYNOPSIS
    Scan the sinks directory, parse each sink's metadata, return a sorted
    list of sink records.

    .DESCRIPTION
    Discovery is deterministic and reproducible. Order is alphabetical by
    directory name. A malformed sink (bad/missing metadata, missing script.ps1)
    throws — discovery is "either all parse correctly or fail loudly" so a typo
    at startup is impossible to miss.

    .PARAMETER SinksDir
    Override the sinks root. When omitted, Get-DefaultSinksDirectory chooses.

    .PARAMETER BotRoot
    Project bot root, used by Get-DefaultSinksDirectory to find the per-project
    framework copy.

    .OUTPUTS
    @(<sinkRecord>, ...). Empty array if no sinks dir exists.
    #>
    [CmdletBinding()]
    param(
        [string]$SinksDir,
        [string]$BotRoot
    )

    if (-not $SinksDir) {
        $SinksDir = Get-DefaultSinksDirectory -BotRoot $BotRoot
    }
    if (-not $SinksDir) { return @() }
    if (-not (Test-Path -LiteralPath $SinksDir -PathType Container)) { return @() }

    # Collect with a foreach statement (not ForEach-Object) so accumulation
    # stays in this scope, and emit the elements normally — callers wrap the
    # result in @() so 0/1/many sinks all read back as an array.
    $registry = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $SinksDir -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
        # Read-SinkMetadata throws on malformed entries; let it propagate.
        $registry += (Read-SinkMetadata -SinkDir $dir.FullName)
    }
    return $registry
}

function Get-SinksForEvent {
    <#
    .SYNOPSIS
    Filter a sink registry down to sinks subscribed to a concrete event type.

    .DESCRIPTION
    A sink matches when any of its subscribed_events glob patterns matches the
    given event type (PowerShell -like), so a sink subscribed to 'task.*'
    matches 'task.created', and one subscribed to the exact 'workflow.run_completed'
    matches only that type.

    .PARAMETER Registry
    The output of Get-SinkRegistry.

    .PARAMETER EventType
    The concrete dotted event type of a published event (e.g. 'task.created').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Registry,
        [Parameter(Mandatory)] [string]$EventType
    )
    $out = @()
    foreach ($s in $Registry) {
        foreach ($pattern in $s.subscribed_events) {
            if ($EventType -like $pattern) { $out += $s; break }
        }
    }
    return $out
}

Export-ModuleMember -Function @(
    'Get-DefaultSinksDirectory'
    'Read-SinkMetadata'
    'Get-SinkRegistry'
    'Get-SinksForEvent'
)
