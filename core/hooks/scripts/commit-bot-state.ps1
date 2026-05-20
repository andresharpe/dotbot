#!/usr/bin/env pwsh
# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
# Commit any uncommitted .bot workspace state changes
# Run at start of autonomous tasks to establish clean baseline

$ErrorActionPreference = "SilentlyContinue"

# Framework files under .bot/ (core/, hooks/, recipes/, settings/, top-level
# .ps1, README.md, .manifest.json, .gitignore) are managed by `dotbot init` and
# project-gitignored — they must NEVER appear in autonomous-task commits.
# Runtime state (.control/, profile/, .chrome-dev/) is similarly gitignored.
# This script only commits deliberate workspace content under .bot/workspace/:
#   decisions/, plans/, product/, sessions/ (and tasks/ on non-task branches).

# Only consider changes under .bot/workspace/ — everything else under .bot/
# is either gitignored (framework + runtime) or shared via worktree junction
# and not appropriate to commit on a feature branch. We scope `git status`
# with a pathspec (rather than running it unfiltered and matching in PS) so
# autonomous-task startup stays fast on large consumer repos.
$botChanges = git status --porcelain -- .bot/workspace/

# On task branches, filter out tasks/ changes (junction to shared state)
$branch = git symbolic-ref --short HEAD 2>$null
if ($branch -and $branch.StartsWith("task/")) {
    $botChanges = $botChanges | Where-Object { $_ -notmatch "\.bot/workspace/tasks/" }
}

if (-not $botChanges) {
    Write-Host "No uncommitted .bot/workspace state - baseline is clean"
    exit 0
}

Write-Host "Found uncommitted .bot/workspace state changes:"
$botChanges | ForEach-Object { Write-Host "  $_" }

# Stage and commit — workspace only, never framework / runtime
if ($branch -and $branch.StartsWith("task/")) {
    # On a task branch — tasks/ is a junction to shared state, don't commit it
    git add .bot/workspace/ -- ':!.bot/workspace/tasks/'
} else {
    git add .bot/workspace/
}
git commit --quiet -m "chore: save autonomous task state

Automatic commit of workspace state (decisions, plans, product docs,
sessions). Framework files and runtime state are gitignored and never
enter this commit."

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ Task state committed"
} else {
    Write-Host "`n! Could not commit (may be nothing to commit)"
}

exit 0
