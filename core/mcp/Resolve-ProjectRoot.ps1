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
#>

function Resolve-DotbotProjectRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StartPath
    )

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
