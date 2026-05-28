<#
.SYNOPSIS
Worktree lifecycle for WorkflowRuns.

A worktree exists for every WorkflowRun. The runtime owns the lifecycle; this
module just creates / tears down / prunes.

No junctions, no patch-replay, no worktree-map. The worktree is a pure git
checkout; the path is recorded on the WorkflowRun record and the branch is
preserved on completion so the user merges via standard git.

Layout:
  Worktree dir : <repo-parent>/worktrees/<repo-leaf>/<YYYY-MM-DD>-<slug>-<4char>/
  Branch       : workflow/<slug>-<4char>      (workflow runs)
                 task/<slug>-<4char>          (standalone tasks)

Public surface:
  Get-WorktreeBasePath        — <repo-parent>/worktrees/<repo-leaf>
  Get-WorktreeBranchName      — pure branch-name derivation
  Get-WorktreeDirName         — pure dir-leaf derivation
  Resolve-WorkflowMainBranch  — find 'main' or 'master' in a repo
  Resolve-RunWorktreeLayout   — derive {worktree_path, branch_name, dir_name} from a run record
  New-RunWorktree             — create branch + worktree from a run record
  Complete-RunWorktree        — success: remove dir; cancel/fail: wip-commit then remove dir
  Get-PrunableBranches        — pure selection over `git for-each-ref` output
  Invoke-PruneBranches        — find + (dry-run|delete) workflow/* or task/* branches
#>

$script:DotbotV4WorktreeSlugMax = 40

function ConvertTo-WorktreeSlug {
    # Self-contained slug helper so this nested module doesn't depend on
    # Dotbot.Task being imported into the same session state. Mirrors the
    # rules in Dotbot.Task's ConvertTo-DotbotSlug: lowercase, strip non-word,
    # collapse whitespace to hyphens, trim, cap at 40 chars.
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
    if ($slug.Length -gt $script:DotbotV4WorktreeSlugMax) {
        $slug = $slug.Substring(0, $script:DotbotV4WorktreeSlugMax).TrimEnd('-')
    }
    return $slug
}

function _Get-RunField {
    param($Record, [string]$Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $prop = $Record.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function _Get-DateComponent {
    param($When)
    if ($null -eq $When -or $When -eq '') {
        return (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    }
    if ($When -is [datetime]) {
        return $When.ToUniversalTime().ToString('yyyy-MM-dd')
    }
    $s = [string]$When
    if ($s -match '^\d{4}-\d{2}-\d{2}$') { return $s }
    if ($s -match '^\d{4}-\d{2}-\d{2}T') { return $s.Substring(0, 10) }
    try {
        return ([datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture)).ToUniversalTime().ToString('yyyy-MM-dd')
    } catch {
        throw "worktree: cannot interpret '$When' as a date."
    }
}

function _Get-RunShortId {
    param([string]$RunId)
    if (-not $RunId) { throw "worktree: run_id is required." }
    if ($RunId -cmatch '^wr_([A-Za-z0-9]{8})$') {
        return $Matches[1].Substring(0, 4)
    }
    throw "worktree: '$RunId' is not a canonical workflow-run ID."
}

function Get-WorktreeBasePath {
    <#
    .SYNOPSIS
    Return <repo-parent>/worktrees/<repo-leaf>/ for a project root.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $repoParent = Split-Path $ProjectRoot -Parent
    $repoLeaf   = Split-Path $ProjectRoot -Leaf
    return (Join-Path $repoParent (Join-Path 'worktrees' $repoLeaf))
}

function Get-WorktreeBranchName {
    <#
    .SYNOPSIS
    Pure: derive the branch name for a run.

    Format: 'workflow/<slug>-<4char>' for workflow runs, 'task/<slug>-<4char>'
    for standalone tasks (workflows-of-one).
    #>
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$ShortId,
        [switch]$Standalone
    )
    $prefix = if ($Standalone) { 'task' } else { 'workflow' }
    return "$prefix/$Slug-$ShortId"
}

function Get-WorktreeDirName {
    <#
    .SYNOPSIS
    Pure: derive the worktree directory leaf name. Mirrors the on-disk run
    directory layout under workspace/tasks/workflow-runs/.
    #>
    param(
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$ShortId
    )
    return "$Date-$Slug-$ShortId"
}

function Resolve-WorkflowMainBranch {
    <#
    .SYNOPSIS
    Find the canonical integration branch (main or master) by explicit lookup.
    Returns the branch name, or $null if neither exists.

    Never reads symbolic HEAD: callers may invoke this when the repo has been
    checked out on a feature branch and a HEAD read would lie.
    #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    foreach ($candidate in @('main', 'master')) {
        & git -C $ProjectRoot rev-parse --verify $candidate 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    return $null
}

function _Test-GitReadyForWorktree {
    # Local copy of Test-GitReadyForWorktree's check so this module doesn't
    # have to drag in Dotbot.Workflow.
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $refusal = @(
        "Workflow runs require a git repo with at least one commit on the base branch."
        "Initialise git and commit first, then retry."
    ) -join "`n"

    $gitDir = Join-Path $ProjectRoot '.git'
    if (-not (Test-Path -LiteralPath $gitDir)) {
        return @{ ok = $false; reason = 'no_git'; message = $refusal }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; reason = 'git_unavailable'; message = "git CLI is not available on PATH; cannot verify the worktree precondition.`n$refusal" }
    }

    $count = $null
    try {
        $stdout = & git -C $ProjectRoot rev-list --count HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $stdout) {
            $count = [int]($stdout.ToString().Trim())
        }
    } catch { $count = $null }

    if (-not $count -or $count -le 0) {
        return @{ ok = $false; reason = 'no_commits'; message = $refusal }
    }
    return @{ ok = $true }
}

function Resolve-RunWorktreeLayout {
    <#
    .SYNOPSIS
    Pure: derive the full worktree path + branch name for a WorkflowRun record.

    .DESCRIPTION
    Reads run_id, workflow_name, started_at from $RunRecord. Returns:
      @{
        worktree_path = <abs path>
        branch_name   = 'workflow/<slug>-<4char>' or 'task/<slug>-<4char>'
        dir_name      = '<YYYY-MM-DD>-<slug>-<4char>'
        short_id      = '<4char>'
        slug          = <slug>
        base_path     = <repo-parent>/worktrees/<repo-leaf>
      }

    The caller decides whether the run is standalone (workflow-of-one) by
    passing -Standalone; otherwise the branch prefix is 'workflow/'.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object]$RunRecord,
        [switch]$Standalone
    )

    $runId        = _Get-RunField $RunRecord 'run_id'
    $workflowName = _Get-RunField $RunRecord 'workflow_name'
    $startedAt    = _Get-RunField $RunRecord 'started_at'

    if (-not $runId)        { throw "Resolve-RunWorktreeLayout: run_record.run_id is required." }
    if (-not $workflowName) { throw "Resolve-RunWorktreeLayout: run_record.workflow_name is required." }

    $shortId  = _Get-RunShortId -RunId $runId
    $date     = _Get-DateComponent -When $startedAt
    $slug     = ConvertTo-WorktreeSlug -Text $workflowName
    $dirName  = Get-WorktreeDirName -Date $date -Slug $slug -ShortId $shortId
    $basePath = Get-WorktreeBasePath -ProjectRoot $ProjectRoot
    $wtPath   = Join-Path $basePath $dirName
    $branch   = Get-WorktreeBranchName -Slug $slug -ShortId $shortId -Standalone:$Standalone

    return [ordered]@{
        worktree_path = $wtPath
        branch_name   = $branch
        dir_name      = $dirName
        short_id      = $shortId
        slug          = $slug
        base_path     = $basePath
    }
}

function New-RunWorktree {
    <#
    .SYNOPSIS
    Create a per-WorkflowRun worktree + branch.

    .DESCRIPTION
    Idempotent: if the worktree already exists at the derived path with a valid
    .git marker, returns success without recreating it. Otherwise creates the
    worktree from the project's main/master branch.

    Enforces the git-ready precondition. Returns the standard refusal
    message on failure rather than throwing.

    .OUTPUTS
    Hashtable: @{ success; worktree_path; branch_name; base_branch; message }
    On refusal: @{ success = $false; reason = 'no_git'|'no_commits'|...; message = <refusal text> }
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object]$RunRecord,
        [switch]$Standalone
    )

    $gitReady = _Test-GitReadyForWorktree -ProjectRoot $ProjectRoot
    if (-not $gitReady.ok) {
        return @{
            success       = $false
            reason        = $gitReady.reason
            message       = $gitReady.message
            worktree_path = $null
            branch_name   = $null
            base_branch   = $null
        }
    }

    $layout = Resolve-RunWorktreeLayout -ProjectRoot $ProjectRoot -RunRecord $RunRecord -Standalone:$Standalone
    $wtPath = $layout.worktree_path
    $branch = $layout.branch_name

    $baseBranch = Resolve-WorkflowMainBranch -ProjectRoot $ProjectRoot
    if (-not $baseBranch) {
        return @{
            success       = $false
            reason        = 'no_main_branch'
            message       = "Cannot create worktree: no 'main' or 'master' branch found in $ProjectRoot."
            worktree_path = $null
            branch_name   = $branch
            base_branch   = $null
        }
    }

    if (-not (Test-Path -LiteralPath $layout.base_path)) {
        New-Item -Path $layout.base_path -ItemType Directory -Force | Out-Null
    }

    # Idempotency: if the worktree directory + .git marker exist, treat it as
    # already-created. The git-worktree subsystem ensures the .git file points
    # at the right gitdir; we don't second-guess.
    if (Test-Path -LiteralPath $wtPath) {
        if (Test-Path -LiteralPath (Join-Path $wtPath '.git')) {
            return @{
                success       = $true
                worktree_path = $wtPath
                branch_name   = $branch
                base_branch   = $baseBranch
                message       = "Worktree already exists at $wtPath"
            }
        }
        # Leftover empty directory — remove so `git worktree add` doesn't refuse.
        Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
        & git -C $ProjectRoot worktree prune 2>$null | Out-Null
    }

    # Create the worktree on a new branch from $baseBranch. If the branch
    # already exists (interrupted previous run), attach without -b.
    $output = & git -C $ProjectRoot worktree add -b $branch $wtPath $baseBranch 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output = & git -C $ProjectRoot worktree add $wtPath $branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{
                success       = $false
                reason        = 'git_worktree_add_failed'
                message       = "git worktree add failed: $(($output | ForEach-Object { "$_" }) -join ' ')"
                worktree_path = $null
                branch_name   = $branch
                base_branch   = $baseBranch
            }
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $wtPath '.git'))) {
        return @{
            success       = $false
            reason        = 'git_marker_missing'
            message       = "git worktree add succeeded but .git marker not found at $wtPath"
            worktree_path = $null
            branch_name   = $branch
            base_branch   = $baseBranch
        }
    }

    return @{
        success       = $true
        worktree_path = $wtPath
        branch_name   = $branch
        base_branch   = $baseBranch
        message       = "Worktree created at $wtPath"
    }
}

function Complete-RunWorktree {
    <#
    .SYNOPSIS
    Tear down a per-run worktree. Branch is always preserved.

    .DESCRIPTION
    -Outcome success : `git worktree remove` (no force). Refuses if the worktree
                       has uncommitted changes — that's a bug in the caller, who
                       should have committed before declaring success.
    -Outcome cancel  : `git add -A`; if there are changes, commit them as
                       `wip: <reason> at <iso-timestamp>` on the run's branch;
                       then `git worktree remove --force`.
    -Outcome fail    : Same as cancel but the commit message is `wip: failed (<reason>) ...`.
                       Per PRD: failed runs keep the branch for forensics; we
                       still remove the worktree directory to match cancellation.

    .OUTPUTS
    Hashtable: @{ success; worktree_path; branch_name; wip_commit; message; outcome }
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][object]$RunRecord,
        [Parameter(Mandatory)][ValidateSet('success','cancel','fail')][string]$Outcome,
        [string]$Reason = '',
        [switch]$Standalone
    )

    $layout = Resolve-RunWorktreeLayout -ProjectRoot $ProjectRoot -RunRecord $RunRecord -Standalone:$Standalone
    $wtPath = _Get-RunField $RunRecord 'worktree_path'
    if (-not $wtPath) { $wtPath = $layout.worktree_path }
    $branch = _Get-RunField $RunRecord 'branch_name'
    if (-not $branch) { $branch = $layout.branch_name }

    $result = [ordered]@{
        success       = $true
        outcome       = $Outcome
        worktree_path = $wtPath
        branch_name   = $branch
        wip_commit    = $null
        message       = ''
    }

    if (-not (Test-Path -LiteralPath $wtPath)) {
        # Already gone — nothing to do. Still report success: the caller's
        # invariant (no worktree on disk) holds.
        $result.message = "Worktree directory $wtPath does not exist; nothing to remove."
        return $result
    }

    if ($Outcome -ne 'success') {
        # Stage everything and capture as a wip commit if there's something to
        # commit. PRD §Cancellation flow steps 3.
        & git -C $wtPath add -A 2>$null
        $staged = & git -C $wtPath diff --cached --name-only 2>$null
        if ($staged) {
            $iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            $reasonText = if ($Reason) { $Reason } else { $Outcome }
            $commitMsg = if ($Outcome -eq 'fail') {
                "wip: failed ($reasonText) at $iso"
            } else {
                "wip: $reasonText at $iso"
            }
            $commitOut = & git -C $wtPath -c "user.name=dotbot" -c "user.email=dotbot@localhost" commit --quiet -m $commitMsg 2>&1
            if ($LASTEXITCODE -eq 0) {
                $result.wip_commit = (& git -C $wtPath rev-parse HEAD 2>$null) -as [string]
                $result.wip_commit = if ($result.wip_commit) { $result.wip_commit.Trim() } else { $null }
            } else {
                $result.success = $false
                $result.message = "wip commit failed: $(($commitOut | ForEach-Object { "$_" }) -join ' ')"
                # Fall through to removal; preserving the wip-failure status.
            }
        }
    }

    # Remove the directory. Force on non-success because we may have just
    # committed and want git-worktree-remove to succeed regardless of stray
    # untracked files; on success there's nothing dirty so force is harmless.
    $removeArgs = @('worktree', 'remove', $wtPath, '--force')
    $removeOut = & git -C $ProjectRoot @removeArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Fallback: drop the registration and remove the directory by hand.
        & git -C $ProjectRoot worktree prune 2>$null | Out-Null
        Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $wtPath) {
            $result.success = $false
            $result.message = "Worktree removal failed: $(($removeOut | ForEach-Object { "$_" }) -join ' ')"
            return $result
        }
    }

    if (-not $result.message) {
        $result.message = switch ($Outcome) {
            'success' { "Worktree removed; branch '$branch' preserved." }
            'cancel'  { "Worktree cancelled, wip-committed (if dirty), and removed; branch '$branch' preserved." }
            'fail'    { "Worktree failed, wip-committed (if dirty), and removed; branch '$branch' preserved." }
        }
    }
    return $result
}

function Get-PrunableBranches {
    <#
    .SYNOPSIS
    Pure selection: given a list of branch records, return those eligible for prune.

    .DESCRIPTION
    Input is an array of records with fields:
      - name           (string)          required
      - last_commit_at (datetime/string) required
      - is_current     (bool)            optional, default $false
      - has_remote_ref (bool)            optional, default $false
      - is_merged      (bool)            optional, default $false

    Filters:
      - Name must start with 'workflow/' or 'task/' (or match -Match if set
        to 'workflow' or 'task' specifically).
      - last_commit_at older than -CutoffUtc.
      - is_current = $false (the currently checked-out branch on any worktree
        is never proposed).
      - has_remote_ref = $false unless -IncludeRemote.

    Returns a new array of the same records, filtered. Sort order is preserved.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Branches,
        [Parameter(Mandatory)][datetime]$CutoffUtc,
        [ValidateSet('workflow','task','all')][string]$Match = 'all',
        [switch]$IncludeRemote
    )

    $out = @()
    foreach ($b in @($Branches)) {
        if ($null -eq $b) { continue }
        $name        = _Get-RunField $b 'name'
        $lastCommit  = _Get-RunField $b 'last_commit_at'
        $isCurrent   = [bool](_Get-RunField $b 'is_current')
        $hasRemote   = [bool](_Get-RunField $b 'has_remote_ref')

        if (-not $name) { continue }

        $kind = if ($name.StartsWith('workflow/')) { 'workflow' }
                elseif ($name.StartsWith('task/')) { 'task' }
                else { $null }
        if (-not $kind) { continue }
        if ($Match -ne 'all' -and $Match -ne $kind) { continue }

        if ($isCurrent) { continue }
        if ($hasRemote -and -not $IncludeRemote) { continue }

        $dt = if ($lastCommit -is [datetime]) { $lastCommit.ToUniversalTime() }
              elseif ($lastCommit) {
                  try { [datetime]::Parse([string]$lastCommit, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
                  catch { $null }
              } else { $null }
        if ($null -eq $dt) { continue }
        if ($dt -ge $CutoffUtc) { continue }

        $out += $b
    }
    return ,$out
}

function _Get-RepoBranchRecords {
    # Build the input shape for Get-PrunableBranches from `git for-each-ref`.
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $currentSet = @{}
    $wtList = & git -C $ProjectRoot worktree list --porcelain 2>$null
    if ($LASTEXITCODE -eq 0 -and $wtList) {
        foreach ($line in @($wtList)) {
            if ($line -match '^branch refs/heads/(.+)$') {
                $currentSet[$Matches[1]] = $true
            }
        }
    }

    $records = @()
    # Use '|' as the separator: branch names, ISO timestamps and upstream
    # short-names can't contain pipes (git refuses '|' in refnames; dates and
    # upstreams use ASCII separators only).
    $fmt = '%(refname:short)|%(committerdate:iso-strict)|%(upstream:short)'
    $lines = & git -C $ProjectRoot for-each-ref --format=$fmt 'refs/heads/' 2>$null
    if ($LASTEXITCODE -ne 0) { return ,@() }

    foreach ($line in @($lines)) {
        $parts = ($line -as [string]) -split '\|'
        if ($parts.Count -lt 2) { continue }
        $name      = $parts[0]
        $dateStr   = $parts[1]
        $upstream  = if ($parts.Count -ge 3) { $parts[2] } else { '' }

        $dt = $null
        try { $dt = [datetime]::Parse($dateStr, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() } catch { $dt = $null }
        if ($null -eq $dt) { continue }

        $records += [ordered]@{
            name           = $name
            last_commit_at = $dt
            is_current     = [bool]$currentSet[$name]
            has_remote_ref = -not [string]::IsNullOrWhiteSpace($upstream)
            is_merged      = $false  # populated on demand by callers that care
        }
    }
    return ,@($records)
}

function Invoke-PruneBranches {
    <#
    .SYNOPSIS
    List + (optionally delete) workflow/* / task/* branches older than a threshold.

    .DESCRIPTION
    -OlderThan accepts a duration string like '30d', '14d', '6h'.
    -Match selects which kinds participate: 'workflow', 'task', or 'all' (default).
    -DryRun returns the candidate list without deleting.
    -IncludeRemote opts in to deleting branches that have an upstream ref.
    Branches currently checked out on any worktree are never deleted.

    .OUTPUTS
    Hashtable: @{
      candidates = @( @{ name; last_commit_at; has_remote_ref; is_current } )
      deleted    = @( <name> )    # empty when -DryRun
      skipped    = @( @{ name; reason } )
      cutoff_utc = <datetime>
    }
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$OlderThan = '30d',
        [ValidateSet('workflow','task','all')][string]$Match = 'all',
        [switch]$DryRun,
        [switch]$IncludeRemote
    )

    $cutoff = _ConvertFrom-DurationToCutoffUtc -Duration $OlderThan
    $branches = _Get-RepoBranchRecords -ProjectRoot $ProjectRoot
    $candidates = Get-PrunableBranches -Branches $branches -CutoffUtc $cutoff -Match $Match -IncludeRemote:$IncludeRemote

    $deleted = @()
    $skipped = @()

    if (-not $DryRun) {
        foreach ($c in @($candidates)) {
            $name = _Get-RunField $c 'name'
            $delOut = & git -C $ProjectRoot branch -D $name 2>&1
            if ($LASTEXITCODE -eq 0) {
                $deleted += $name
            } else {
                $skipped += @{ name = $name; reason = (($delOut | ForEach-Object { "$_" }) -join ' ') }
            }
        }
    }

    return @{
        candidates = @($candidates)
        deleted    = @($deleted)
        skipped    = @($skipped)
        cutoff_utc = $cutoff
    }
}

function _ConvertFrom-DurationToCutoffUtc {
    # '30d' -> now - 30 days; '6h' -> now - 6 hours; '14m' -> 14 minutes.
    param([Parameter(Mandatory)][string]$Duration)
    if ($Duration -notmatch '^\s*(\d+)\s*([dhmw])\s*$') {
        throw "Invoke-PruneBranches: bad duration '$Duration' (expected forms like '30d', '14d', '6h', '2w')."
    }
    $n = [int]$Matches[1]
    $unit = $Matches[2]
    $span = switch ($unit) {
        'd' { [TimeSpan]::FromDays($n) }
        'h' { [TimeSpan]::FromHours($n) }
        'm' { [TimeSpan]::FromMinutes($n) }
        'w' { [TimeSpan]::FromDays($n * 7) }
    }
    return ((Get-Date).ToUniversalTime() - $span)
}

Export-ModuleMember -Function @(
    'ConvertTo-WorktreeSlug'
    'Get-WorktreeBasePath'
    'Get-WorktreeBranchName'
    'Get-WorktreeDirName'
    'Resolve-WorkflowMainBranch'
    'Resolve-RunWorktreeLayout'
    'New-RunWorktree'
    'Complete-RunWorktree'
    'Get-PrunableBranches'
    'Invoke-PruneBranches'
)
