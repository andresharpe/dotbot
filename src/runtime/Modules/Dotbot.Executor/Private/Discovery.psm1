<#
.SYNOPSIS
Executor discovery: scan the executors directory, parse metadata.json, and
build a dispatcher-ready registry indexed by task_type.

Discovery is reproducible: same folder listing → same registry state. Each
subfolder either parses + validates cleanly and registers, or fails
registration with a clear error. We surface failures eagerly (at runtime
startup) so the operator finds out about a malformed executor at the same
moment they would find out about any other startup misconfiguration.

Metadata parsing uses PowerShell's built-in JSON support.
#>

$script:DotbotExecutorMetadataFields = @(
    'name'
    'task_type'
    'description'
    'required_fields'
    'optional_fields'
    'supports_worktree'
    'supports_analysis'
    'max_executor_duration'
)

$script:DotbotExecutorRequiredFields = @(
    'name'
    'task_type'
    'description'
    'max_executor_duration'
)

function Get-DotbotExecutorsDir {
    <#
    .SYNOPSIS
    Resolve the canonical executors directory for a given runtime tree.

    .DESCRIPTION
    Executors live under src/runtime/Plugins/Executors/ in the source tree and
    .bot/src/runtime/Plugins/Executors/ inside an installed project. Callers supply
    -RuntimeRoot (e.g. the directory containing Modules/ and Scripts/) so
    this helper stays agnostic about which tree it's looking at.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuntimeRoot
    )

    return (Join-Path $RuntimeRoot (Join-Path 'Plugins' 'Executors'))
}

function _Parse-ExecutorMetadataJson {
    <#
    .SYNOPSIS
    Parse a metadata.json file. Returns a hashtable or throws on parse failure.
    #>
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "metadata.json not found at '$Path'."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "metadata.json at '$Path' is empty."
    }

    try {
        return ($raw | ConvertFrom-Json -AsHashtable)
    } catch {
        throw "metadata.json at '$Path' is not valid JSON: $($_.Exception.Message)"
    }
}

function Test-ExecutorMetadata {
    <#
    .SYNOPSIS
    Validate an executor metadata hashtable; return the list of error strings.
    Empty array means valid.

    .DESCRIPTION
    Shape-only — required fields are present, types match, max_executor_duration
    is a positive number, the field-name lists are arrays of non-empty strings.
    Does not assert that required_fields/optional_fields are disjoint; both can
    name the same task field if an executor wants to consult it conditionally.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Metadata)

    $errors = [System.Collections.ArrayList]::new()

    if ($null -eq $Metadata) {
        [void]$errors.Add('metadata: is null')
        return ,@($errors.ToArray())
    }
    if ($Metadata -isnot [System.Collections.IDictionary]) {
        [void]$errors.Add('metadata: must be a hashtable')
        return ,@($errors.ToArray())
    }

    foreach ($k in @($Metadata.Keys)) {
        if ($script:DotbotExecutorMetadataFields -notcontains $k) {
            [void]$errors.Add("$k`: is not a known executor metadata field")
        }
    }
    foreach ($f in $script:DotbotExecutorRequiredFields) {
        if (-not $Metadata.Contains($f)) {
            [void]$errors.Add("$f`: is required")
        }
    }

    foreach ($s in 'name','task_type','description') {
        if ($Metadata.Contains($s)) {
            $v = $Metadata[$s]
            if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v)) {
                [void]$errors.Add("$s`: must be a non-empty string")
            }
        }
    }

    foreach ($listField in 'required_fields','optional_fields') {
        if (-not $Metadata.Contains($listField)) { continue }
        $val = $Metadata[$listField]
        if ($null -eq $val) { continue }
        if ($val -is [string]) {
            [void]$errors.Add("$listField`: must be an array of strings, not a single string")
            continue
        }
        $arr = @($val)
        $idx = 0
        foreach ($item in $arr) {
            if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) {
                [void]$errors.Add("$listField[$idx]: must be a non-empty string")
            }
            $idx++
        }
    }

    foreach ($boolField in 'supports_worktree','supports_analysis') {
        if (-not $Metadata.Contains($boolField)) { continue }
        $val = $Metadata[$boolField]
        if ($val -isnot [bool]) {
            [void]$errors.Add("$boolField`: must be a boolean (true/false)")
        }
    }

    if ($Metadata.Contains('max_executor_duration')) {
        $d = $Metadata['max_executor_duration']
        $isInt = ($d -is [int]) -or ($d -is [long]) -or ($d -is [double] -and [Math]::Floor($d) -eq $d)
        if (-not $isInt) {
            [void]$errors.Add("max_executor_duration: must be an integer (seconds)")
        } elseif ([int]$d -le 0) {
            [void]$errors.Add("max_executor_duration: must be > 0 (got '$d')")
        }
    }

    return ,@($errors.ToArray())
}

function Assert-ExecutorMetadata {
    <#
    .SYNOPSIS
    Throw if executor metadata fails validation. Returns nothing on success.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Metadata)

    $errs = Test-ExecutorMetadata -Metadata $Metadata
    if ($errs -and $errs.Count -gt 0) {
        throw "Invalid executor metadata:`n  - $($errs -join "`n  - ")"
    }
}

function Read-ExecutorMetadata {
    <#
    .SYNOPSIS
    Read + validate the metadata.json for an executor folder.

    .OUTPUTS
    A hashtable of the parsed metadata. Defaults are filled in for the
    optional flags so callers don't have to defensively check:
      supports_worktree   -> $true
      supports_analysis   -> $false
      required_fields     -> @()
      optional_fields     -> @()
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Path)

    $parsed = _Parse-ExecutorMetadataJson -Path $Path
    Assert-ExecutorMetadata -Metadata $parsed

    # Fill defaults for absent optional flags.
    if (-not $parsed.Contains('supports_worktree')) { $parsed['supports_worktree'] = $true }
    if (-not $parsed.Contains('supports_analysis')) { $parsed['supports_analysis'] = $false }
    if (-not $parsed.Contains('required_fields'))   { $parsed['required_fields']   = @() }
    if (-not $parsed.Contains('optional_fields'))   { $parsed['optional_fields']   = @() }

    return $parsed
}

function Get-ExecutorRegistry {
    <#
    .SYNOPSIS
    Scan the executors directory, parse + validate every subfolder's
    metadata.json, and return a dispatcher-ready registry indexed by task_type.

    .DESCRIPTION
    Reproducible: same folder listing → same registry state. Malformed
    executors fail the scan with a clear startup error rather than being
    silently skipped, so an operator who drops a bad folder hears about it
    immediately.

    .OUTPUTS
    @{
        '<task_type>' = @{
            metadata    = <hashtable from Read-ExecutorMetadata>
            dir         = <path to the executor folder>
            script_path = <path to script.ps1>
        }
        ...
    }

    .PARAMETER ExecutorsDir
    The directory containing one folder per executor.

    .PARAMETER IgnoreMalformed
    Skip folders that fail validation instead of throwing. Off by default
    so malformed metadata produces a startup error. Tests use it to assert
    behaviour against fixture trees that intentionally include a broken
    executor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ExecutorsDir,
        [switch]$IgnoreMalformed
    )

    if (-not (Test-Path -LiteralPath $ExecutorsDir -PathType Container)) {
        throw "Executors directory not found: '$ExecutorsDir'."
    }

    $registry = @{}
    $folders = Get-ChildItem -LiteralPath $ExecutorsDir -Directory -ErrorAction Stop |
        Sort-Object Name

    foreach ($folder in $folders) {
        $metadataPath = Join-Path $folder.FullName 'metadata.json'
        $scriptPath   = Join-Path $folder.FullName 'script.ps1'

        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            if ($IgnoreMalformed) { continue }
            throw "Executor '$($folder.Name)' is missing metadata.json (expected '$metadataPath')."
        }
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            if ($IgnoreMalformed) { continue }
            throw "Executor '$($folder.Name)' is missing script.ps1 (expected '$scriptPath')."
        }

        try {
            $metadata = Read-ExecutorMetadata -Path $metadataPath
        } catch {
            if ($IgnoreMalformed) { continue }
            throw "Executor '$($folder.Name)' has invalid metadata.json: $($_.Exception.Message)"
        }

        $taskType = $metadata['task_type']
        if ($registry.ContainsKey($taskType)) {
            $existing = $registry[$taskType].dir
            if ($IgnoreMalformed) { continue }
            throw "Duplicate executor for task_type '$taskType': '$($folder.FullName)' conflicts with '$existing'."
        }

        $registry[$taskType] = @{
            metadata    = $metadata
            dir         = $folder.FullName
            script_path = $scriptPath
        }
    }

    return $registry
}

Export-ModuleMember -Function @(
    'Get-DotbotExecutorsDir'
    'Read-ExecutorMetadata'
    'Test-ExecutorMetadata'
    'Assert-ExecutorMetadata'
    'Get-ExecutorRegistry'
)
