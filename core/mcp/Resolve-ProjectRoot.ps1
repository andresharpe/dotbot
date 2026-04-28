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

    # Walk-up fallback. Restrict to `.git` *directories* so a worktree's
    # gitfile (a regular file) does not re-introduce the worktree-as-root
    # bug this resolver was written to fix.
    $current = $StartPath
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current ".git") -PathType Container) {
            return $current
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $null
}
