<#
.SYNOPSIS
On-disk layout derivation for tasks and workflow runs.

Layout (under each project's .bot/ directory):
  - Committed:  workspace/tasks/workflow-runs/<YYYY-MM-DD>-<workflow-slug>-<4char>/{run.json, t_<id>.json...}
  - Committed:  workspace/tasks/standalone/<YYYY-MM-DD>-<task-slug>-<4char>.json
  - Gitignored: .control/workflow-runs/<wr_id>.json

These helpers are pure — they derive paths but never create directories.
The writer (runtime) is responsible for mkdir.

Depends on IdGen.psm1 for Test-TaskId / Test-WorkflowRunId / Get-ShortId. When
loaded as a nested module from Dotbot.Task.psd1 IdGen is already in the same
session state, so we don't Import-Module it here.
#>

$script:DotbotSlugMaxLength = 40

function _Get-DotbotDateComponent {
    # Accept a string ('2026-05-19' or RFC3339-Z), a [datetime], or $null
    # (defaults to "now" in UTC). Always returns YYYY-MM-DD.
    param($When)
    if ($null -eq $When -or $When -eq '') {
        return (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    }
    if ($When -is [datetime]) {
        return $When.ToUniversalTime().ToString('yyyy-MM-dd')
    }
    $s = [string]$When
    # Already date-only?
    if ($s -match '^\d{4}-\d{2}-\d{2}$') { return $s }
    # RFC3339-ish: take the first 10 chars.
    if ($s -match '^\d{4}-\d{2}-\d{2}T') { return $s.Substring(0, 10) }
    # Fallback: try to parse and reformat.
    try {
        return ([datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime().ToString('yyyy-MM-dd')
    } catch {
        throw "Get-TaskLayoutPath: can't interpret '$When' as a date."
    }
}

function ConvertTo-DotbotSlug {
    <#
    .SYNOPSIS
    Render a human string as a filesystem-friendly slug.

    .DESCRIPTION
    Lowercase, strip non-word characters except hyphens and whitespace,
    collapse whitespace to single hyphens, trim hyphens, cap at 40 chars.

    The cap is intentionally tight: after the 'YYYY-MM-DD-' prefix (11
    chars), '-AbCd' suffix (5 chars), and '.json' extension (5 chars) we
    still want headroom under common filesystem name limits and to keep
    the path readable.

    Empty inputs become 'untitled' so the slug is never an empty segment.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $slug = $Text
    $slug = $slug -replace '[^\p{L}\p{N}\s-]', ''
    $slug = $slug -replace '\s+', '-'
    $slug = $slug.Trim('-').ToLowerInvariant()
    if (-not $slug) { $slug = 'untitled' }
    if ($slug.Length -gt $script:DotbotSlugMaxLength) {
        $slug = $slug.Substring(0, $script:DotbotSlugMaxLength).TrimEnd('-')
    }
    return $slug
}

function Get-WorkflowRunLayout {
    <#
    .SYNOPSIS
    Compute the on-disk paths for a workflow run.

    .DESCRIPTION
    Given the project's .bot/ root, the workflow's slug source (its name), the
    run's started_at date and canonical run ID, return a hashtable with:
      - run_dir            : the committed run directory under workspace/tasks/workflow-runs/
      - run_record_path    : <run_dir>/run.json (committed immutable provenance)
      - tasks_dir          : <run_dir> (task files live alongside run.json)
      - live_status_path   : .control/workflow-runs/<wr_id>.json (gitignored)
      - dir_name           : the bare directory name (no parents) — useful for logs
      - short_id           : the 4-char derived ID

    The committed dir name format: <YYYY-MM-DD>-<workflow-slug>-<4char>.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [string]$WorkflowName,

        [Parameter(Mandatory)]
        [string]$RunId,

        $StartedAt
    )

    if (-not (Test-WorkflowRunId -Id $RunId)) {
        throw "Get-WorkflowRunLayout: '$RunId' is not a canonical workflow-run ID."
    }

    $date    = _Get-DotbotDateComponent -When $StartedAt
    $slug    = ConvertTo-DotbotSlug -Text $WorkflowName
    $shortId = Get-ShortId -Id $RunId
    $dirName = "$date-$slug-$shortId"

    $runDir          = Join-Path $BotRoot (Join-Path 'workspace' (Join-Path 'tasks' (Join-Path 'workflow-runs' $dirName)))
    $runRecordPath   = Join-Path $runDir 'run.json'
    $liveStatusPath  = Join-Path $BotRoot (Join-Path '.control' (Join-Path 'workflow-runs' "$RunId.json"))

    return [ordered]@{
        run_dir          = $runDir
        run_record_path  = $runRecordPath
        tasks_dir        = $runDir
        live_status_path = $liveStatusPath
        dir_name         = $dirName
        short_id         = $shortId
    }
}

function Get-RunTaskFilePath {
    <#
    .SYNOPSIS
    Return the path of a single task file inside its run directory.

    .DESCRIPTION
    Inside a run directory, task files use their canonical ID as the basename:
    't_AbCd1234.json'. Same-id collisions can't happen by construction (the
    run already disambiguates with its 4-char suffix on the parent dir).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RunDir,

        [Parameter(Mandatory)]
        [string]$TaskId
    )

    if (-not (Test-TaskId -Id $TaskId)) {
        throw "Get-RunTaskFilePath: '$TaskId' is not a canonical task ID."
    }
    return Join-Path $RunDir "$TaskId.json"
}

function Get-StandaloneTaskLayout {
    <#
    .SYNOPSIS
    Compute the on-disk path for a standalone (workflow-of-one) task.

    .DESCRIPTION
    Standalone tasks are single files, not directories — they're not a
    multi-task unit so the directory form would be misleading (User Story 9).
    Returns a hashtable with:
      - file_path  : workspace/tasks/standalone/<YYYY-MM-DD>-<task-slug>-<4char>.json
      - file_name  : the bare filename — useful for logs
      - short_id   : the 4-char derived ID
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        [string]$TaskName,

        $CreatedAt
    )

    if (-not (Test-TaskId -Id $TaskId)) {
        throw "Get-StandaloneTaskLayout: '$TaskId' is not a canonical task ID."
    }

    $date    = _Get-DotbotDateComponent -When $CreatedAt
    $slug    = ConvertTo-DotbotSlug -Text $TaskName
    $shortId = Get-ShortId -Id $TaskId
    $fileName = "$date-$slug-$shortId.json"
    $filePath = Join-Path $BotRoot (Join-Path 'workspace' (Join-Path 'tasks' (Join-Path 'standalone' $fileName)))

    return [ordered]@{
        file_path = $filePath
        file_name = $fileName
        short_id  = $shortId
    }
}

function Get-TaskLayoutPath {
    <#
    .SYNOPSIS
    Top-level layout dispatcher: workflow-spawned vs standalone.

    .DESCRIPTION
    For workflow-spawned tasks, you must supply -RunId, -WorkflowName and
    optionally -StartedAt; this returns the path *inside* that run's directory.
    For standalone tasks, omit -RunId; -TaskName and optionally -CreatedAt are used.

    A standalone task may also be passed -RunId $null explicitly; either form
    routes to Get-StandaloneTaskLayout.

    Returns the same hashtable shape as Get-RunTaskFilePath (single 'file_path'
    key) so callers can treat both cases uniformly.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [string]$TaskId,

        [string]$TaskName,

        [string]$RunId,

        [string]$WorkflowName,

        $StartedAt,

        $CreatedAt
    )

    if ($RunId) {
        $layout = Get-WorkflowRunLayout -BotRoot $BotRoot `
                                        -WorkflowName $WorkflowName `
                                        -RunId $RunId `
                                        -StartedAt $StartedAt
        return [ordered]@{
            file_path = Get-RunTaskFilePath -RunDir $layout.run_dir -TaskId $TaskId
            run_dir   = $layout.run_dir
            dir_name  = $layout.dir_name
            short_id  = Get-ShortId -Id $TaskId
        }
    }

    if (-not $TaskName) {
        throw "Get-TaskLayoutPath: -TaskName is required for standalone tasks."
    }
    return Get-StandaloneTaskLayout -BotRoot $BotRoot `
                                    -TaskId $TaskId `
                                    -TaskName $TaskName `
                                    -CreatedAt $CreatedAt
}

Export-ModuleMember -Function @(
    'ConvertTo-DotbotSlug'
    'Get-WorkflowRunLayout'
    'Get-RunTaskFilePath'
    'Get-StandaloneTaskLayout'
    'Get-TaskLayoutPath'
)
