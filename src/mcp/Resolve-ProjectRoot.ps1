# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
<#
.SYNOPSIS
    Resolves the dotbot project root from a starting path.

.DESCRIPTION
    The MCP server (and its dot-sourced tools) read $global:DotbotProjectRoot
    to locate .bot/workspace/tasks/ and other project-relative state. The walk-
    up `Test-Path .git` strategy stops at the first `.git` it finds — which in
    a linked git worktree is a *gitfile* at the worktree's root, not the main
    repo. That made every agent-driven task-state transition write to the
    worktree, where Complete-TaskWorktree later discarded it.

    Resolve-DotbotProjectRoot prefers `git rev-parse --git-common-dir`, which
    returns the path to the main repo's `.git/` regardless of whether the
    caller is inside the main checkout or a linked worktree. The walk-up is
    kept as a fallback for the no-git case (test fixtures, etc.).

    DOTBOT_STATE_ROOT vs DOTBOT_PROJECT_ROOT (issue #515): during task
    execution the agent's working directory is a linked worktree, but dotbot's
    runtime/task state lives in the *main* repository. Overloading
    DOTBOT_PROJECT_ROOT for both meanings forced state resolution onto the
    worktree, whose `.bot/.control` junction can be stale during retry/teardown
    windows — the MCP server then resolves runtime.json to a dead link and
    exits. DOTBOT_STATE_ROOT carries the stable main root explicitly and takes
    precedence here, so state resolution never depends on a worktree junction.
    When unset, the resolver falls back to DOTBOT_PROJECT_ROOT (backward
    compatible) and then to git detection.
#>

function Resolve-DotbotProjectRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartPath
    )

    # Normalise an env-var path: expand ~, make absolute, and require it to be
    # an existing directory. Returns $null when the value cannot be used.
    $resolveEnvRoot = {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $Value = $Value.Trim()
        if ($Value -eq '~') {
            $Value = $HOME
        } elseif ($Value.StartsWith('~/') -or $Value.StartsWith('~\')) {
            $Value = Join-Path $HOME $Value.Substring(2)
        }
        try {
            $Value = [System.IO.Path]::GetFullPath($Value)
        } catch {
            return $null
        }
        if (Test-Path -LiteralPath $Value -PathType Container) { return $Value }
        return $null
    }

    # DOTBOT_STATE_ROOT wins when it points at a real directory. It is the
    # stable main root, immune to worktree junction staleness (#515). A set-but-
    # invalid value falls through rather than failing, so a misconfigured state
    # root degrades to the previous DOTBOT_PROJECT_ROOT/git behaviour.
    $stateRoot = & $resolveEnvRoot ([Environment]::GetEnvironmentVariable('DOTBOT_STATE_ROOT'))
    if ($stateRoot) { return $stateRoot }

    $envProjectRoot = [Environment]::GetEnvironmentVariable('DOTBOT_PROJECT_ROOT')
    if (-not [string]::IsNullOrWhiteSpace($envProjectRoot)) {
        $resolvedProjectRoot = & $resolveEnvRoot $envProjectRoot
        if ($resolvedProjectRoot) { return $resolvedProjectRoot }
        return $null
    }

    if (-not (Test-Path -LiteralPath $StartPath)) {
        return $null
    }

    # Guard the git invocation so PowerShell's terminating
    # CommandNotFoundException does not bypass the walk-up fallback when git
    # is not on PATH (e.g. minimal CI containers).
    $gitCommonDir = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $gitCommonDir = & git -C $StartPath rev-parse --git-common-dir 2>$null
    }
    if ($LASTEXITCODE -eq 0 -and $gitCommonDir) {
        $candidate = if ([System.IO.Path]::IsPathRooted($gitCommonDir)) {
            $gitCommonDir
        } else {
            Join-Path $StartPath $gitCommonDir
        }
        $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($resolved) {
            return Split-Path $resolved.Path -Parent
        }
    }

    # Walk-up fallback. Prefer `.git` directories. If the entry is a
    # gitfile (a worktree's `.git` is a file containing `gitdir: <path>`),
    # follow it to the per-worktree gitdir and read its `commondir` to
    # resolve back to the main repository's shared `.git/`. Without this
    # branch, a missing `git` on PATH would make the resolver return $null
    # from inside any linked worktree.
    $current = $StartPath
    while ($current) {
        $gitPath = Join-Path $current ".git"
        if (Test-Path -LiteralPath $gitPath -PathType Container) {
            return $current
        }
        if (Test-Path -LiteralPath $gitPath -PathType Leaf) {
            $gitFileLine = Get-Content -LiteralPath $gitPath -TotalCount 1 -ErrorAction SilentlyContinue
            if ($gitFileLine -match '^\s*gitdir:\s*(.+?)\s*$') {
                $gitDir = $Matches[1]
                $gitDirCandidate = if ([System.IO.Path]::IsPathRooted($gitDir)) {
                    $gitDir
                } else {
                    Join-Path $current $gitDir
                }
                $resolvedGitDir = Resolve-Path -LiteralPath $gitDirCandidate -ErrorAction SilentlyContinue
                if ($resolvedGitDir) {
                    $commonDirPath = Join-Path $resolvedGitDir.Path "commondir"
                    if (Test-Path -LiteralPath $commonDirPath -PathType Leaf) {
                        $commonDir = Get-Content -LiteralPath $commonDirPath -TotalCount 1 -ErrorAction SilentlyContinue
                        if ($commonDir) {
                            $commonDirCandidate = if ([System.IO.Path]::IsPathRooted($commonDir)) {
                                $commonDir
                            } else {
                                Join-Path $resolvedGitDir.Path $commonDir
                            }
                            $resolvedCommonDir = Resolve-Path -LiteralPath $commonDirCandidate -ErrorAction SilentlyContinue
                            if ($resolvedCommonDir) {
                                return Split-Path $resolvedCommonDir.Path -Parent
                            }
                        }
                    }
                    return Split-Path $resolvedGitDir.Path -Parent
                }
            }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $null
}
