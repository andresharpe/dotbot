<#
.SYNOPSIS
    Framework integrity checks for dotbot target projects.

.DESCRIPTION
    Shared helper used by the verify hook (04-framework-integrity.ps1) and the
    task-state MCP tools (task-mark-analysing, task-mark-in-progress) to detect
    accidental or unauthorised modifications to framework-owned files under
    .bot/ in a target project.

    The integrity model assumes .bot/ is committed to git in the target project.
    That is how dotbot init bootstraps the framework and is a load-bearing
    assumption of worktree-based task isolation.

    If .bot/ is gitignored (repo .gitignore, core.excludesFile, info/exclude, or
    a deep rule), every git-based check returns empty and silently passes.
    Callers MUST consult Test-FrameworkTracked first and surface the remedia-
    tion message rather than treating an empty git status as "clean".
#>

# Paths inside the target project's .bot/ that are framework-owned. Any change
# to these paths outside of `dotbot init --force` indicates tampering.
$script:ProtectedPaths = @(
    '.bot/systems',
    '.bot/hooks',
    '.bot/recipes',
    '.bot/settings/providers',
    '.bot/settings/settings.default.json',
    '.bot/settings/theme.default.json',
    '.bot/go.ps1',
    '.bot/init.ps1',
    '.bot/workflow.yaml',
    '.bot/.gitignore',
    '.bot/.manifest.json',
    '.bot/README.md'
)

# Canonical sentinel file used to probe whether .bot/ is effectively gitignored
# (via any ignore mechanism git recognises).
$script:SentinelPath = '.bot/systems/mcp/dotbot-mcp.ps1'

function Get-FrameworkProtectedPaths {
    <#
    .SYNOPSIS
        Returns the list of .bot/-relative paths considered framework-owned.
    #>
    return , $script:ProtectedPaths
}

function Test-FrameworkTracked {
    <#
    .SYNOPSIS
        Returns $true iff .bot/ is tracked in git (not ignored by any rule).

    .DESCRIPTION
        Uses `git check-ignore` against a canonical sentinel file under .bot/.
        If git reports the sentinel as ignored (exit code 0), integrity checks
        are impossible — the caller should refuse to proceed and surface the
        remediation message.
    #>
    [CmdletBinding()]
    param()

    $null = & git check-ignore -q -- $script:SentinelPath 2>$null
    # exit 0 = path IS ignored; exit 1 = not ignored; 128 = not a git repo
    return ($LASTEXITCODE -ne 0)
}

function Get-FrameworkIgnoreSource {
    <#
    .SYNOPSIS
        Returns the gitignore source (file:line:pattern) responsible for
        ignoring the sentinel, or the empty string if not ignored.
    #>
    [CmdletBinding()]
    param()

    $source = & git check-ignore -v -- $script:SentinelPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $source) {
        return ($source | Select-Object -First 1).ToString()
    }
    return ''
}

function Test-FrameworkIntegrity {
    <#
    .SYNOPSIS
        Checks whether framework-owned files under .bot/ have been modified,
        combining a SHA256 manifest check (catches `--no-verify` commits) with
        a `git status --porcelain` check (catches uncommitted edits).

    .OUTPUTS
        Hashtable with keys:
          success   — $true if no tampering detected (or nothing to protect)
          reason    — short machine-readable code ('clean', 'gitignored',
                      'pre-first-commit', 'tampered', 'not-a-repo',
                      'missing-manifest', 'manifest-error', 'git-error')
          message   — human-readable summary
          files     — array of file references (relative paths for manifest
                      results, porcelain lines for git status results)
          remediation — optional follow-up instruction for the caller

    .NOTES
        Returns success=$true when the protected paths have no git history
        yet (fresh target project, pre-first-commit) — there is nothing to
        protect. The init flow is responsible for making the initial commit
        and generating the manifest.
    #>
    [CmdletBinding()]
    param()

    # 0) Must be inside a git work tree.
    $null = & git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @{
            success     = $true
            reason      = 'not-a-repo'
            message     = 'Not a git repository — framework integrity check skipped'
            files       = @()
            remediation = ''
        }
    }

    # 1) If .bot/ is effectively gitignored, every subsequent check is a silent
    #    pass. Refuse to proceed.
    if (-not (Test-FrameworkTracked)) {
        $source = Get-FrameworkIgnoreSource
        $remediation = "Remove the rule that ignores .bot/ from your .gitignore " +
                       "(or core.excludesFile / .git/info/exclude). " +
                       "Source: $source"
        return @{
            success     = $false
            reason      = 'gitignored'
            message     = '.bot/ is gitignored — framework integrity cannot be verified'
            files       = @()
            remediation = $remediation
        }
    }

    # 2) Pre-first-commit short-circuit: if no protected path has git history
    #    yet, there is nothing to verify against.
    $hasHistory = & git log --oneline -1 -- $script:SentinelPath 2>$null
    if ([string]::IsNullOrWhiteSpace($hasHistory)) {
        return @{
            success     = $true
            reason      = 'pre-first-commit'
            message     = 'No framework history yet — nothing to protect'
            files       = @()
            remediation = ''
        }
    }

    # 3) Manifest check — catches tampering that was committed (including via
    #    `git commit --no-verify`). The manifest lives at .bot/.manifest.json
    #    in the target project's .bot/ (same project root we're running from).
    $projectRoot = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectRoot)) {
        $projectRoot = (Get-Location).Path
    }
    # git rev-parse returns forward slashes on Windows; normalise to OS-native
    # form so downstream path comparisons in Manifest.psm1 are stable.
    $projectRoot = [System.IO.Path]::GetFullPath($projectRoot)

    $manifestResult = $null
    # Manifest.psm1 is a pure utility sibling with no back-dependency on this
    # module. It ships alongside FrameworkIntegrity.psm1 in both the dotbot
    # source repo (workflows/default/systems/mcp/modules/) and in target
    # projects (.bot/systems/mcp/modules/ after `dotbot init`), so the sibling
    # import is reliable in every real-world context.
    $manifestModule = Join-Path $PSScriptRoot "Manifest.psm1"
    if (Test-Path -LiteralPath $manifestModule) {
        try {
            Import-Module $manifestModule -Force -ErrorAction Stop
            $manifestResult = Test-DotbotManifest -ProjectRoot $projectRoot -ProtectedPaths $script:ProtectedPaths
        } catch {
            $manifestResult = @{
                success     = $false
                reason      = 'manifest-error'
                message     = "Framework manifest validation failed: $($_.Exception.Message)"
                files       = @()
                remediation = 'Restore framework files from a trusted copy or re-run: dotbot init --force'
            }
        }
    }

    if ($null -ne $manifestResult -and $manifestResult.reason -in @('missing-manifest', 'manifest-error')) {
        return @{
            success     = $false
            reason      = $manifestResult.reason
            message     = $manifestResult.message
            files       = @()
            remediation = $manifestResult.remediation
        }
    }

    # 4) Scan protected paths for uncommitted modifications.
    $paths = $script:ProtectedPaths
    $dirty = & git status --porcelain -- @paths 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @{
            success     = $false
            reason      = 'git-error'
            message     = 'git status failed while checking framework files'
            files       = @()
            remediation = 'Inspect the working tree manually: git status .bot/'
        }
    }

    # Porcelain format is "XY path"; strip the 3-char status prefix to get a
    # plain relative path, so downstream consumers (verify hook, task gates)
    # see a uniform list regardless of whether the tamper came from git-status
    # or the manifest.
    $dirtyPaths = @(
        $dirty |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { if ($_.Length -gt 3) { $_.Substring(3) } else { $_ } }
    )

    # 5) Union the manifest findings with the git-status findings. Manifest
    #    detects committed tampering; git status detects uncommitted edits.
    $manifestTampered = @()
    if ($null -ne $manifestResult -and -not $manifestResult.success -and $manifestResult.reason -eq 'tampered') {
        $manifestTampered = @($manifestResult.files)
    }

    # Deduplicate — the same file may be flagged by both stages (e.g., edited,
    # committed with --no-verify, then edited again).
    $allFiles = @($manifestTampered + $dirtyPaths | Sort-Object -Unique)

    if ($allFiles.Count -eq 0) {
        return @{
            success     = $true
            reason      = 'clean'
            message     = 'Framework files unchanged'
            files       = @()
            remediation = ''
        }
    }

    return @{
        success     = $false
        reason      = 'tampered'
        message     = "Framework files modified ($($allFiles.Count) file(s))"
        files       = $allFiles
        remediation = "To update framework files, run: dotbot init --force. " +
                      "To discard the changes: git checkout -- <file>"
    }
}

function Invoke-FrameworkIntegrityGate {
    <#
    .SYNOPSIS
        Convenience wrapper for MCP tools that need to block on integrity failure.

    .DESCRIPTION
        Runs Test-FrameworkIntegrity in the given project root and returns a
        structured error hashtable if the check fails, or $null on success.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [string]$TaskId
    )

    Push-Location $ProjectRoot
    try {
        $integrity = Test-FrameworkIntegrity
    } finally {
        Pop-Location
    }

    if (-not $integrity.success) {
        return @{
            success     = $false
            error       = $integrity.message
            reason      = $integrity.reason
            files       = $integrity.files
            remediation = $integrity.remediation
            task_id     = $TaskId
        }
    }
    return $null
}

Export-ModuleMember -Function @(
    'Get-FrameworkProtectedPaths',
    'Test-FrameworkTracked',
    'Get-FrameworkIgnoreSource',
    'Test-FrameworkIntegrity',
    'Invoke-FrameworkIntegrityGate'
)
