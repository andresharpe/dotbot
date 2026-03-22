#!/usr/bin/env pwsh
# Commit any uncommitted .bot workspace state changes
# Run at start of autonomous tasks to establish clean baseline

$ErrorActionPreference = "SilentlyContinue"

# Check for uncommitted .bot files
$botChanges = git status --porcelain | Where-Object { $_ -match "\.bot/" }

# On task branches, filter out tasks/ changes (junction to shared state)
$branch = git symbolic-ref --short HEAD 2>$null
if ($branch -and $branch.StartsWith("task/")) {
    $botChanges = $botChanges | Where-Object { $_ -notmatch "\.bot/workspace/tasks/" }
}

if (-not $botChanges) {
    Write-Host "No uncommitted .bot state - baseline is clean"
    exit 0
}

Write-Host "Found uncommitted .bot state changes:"
$botChanges | ForEach-Object { Write-Host "  $_" }

# Stage and commit
if ($branch -and $branch.StartsWith("task/")) {
    # On a task branch — tasks/ is a junction to shared state, don't commit it
    git add .bot/ -- ':!.bot/workspace/tasks/'
} else {
    git add .bot/
}
$commitResult = git commit --quiet -m "chore: save autonomous task state

Automatic commit of task metadata and workspace state
to establish clean baseline for next task."

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ Task state committed"
} else {
    Write-Host "`n! Could not commit (may be nothing to commit)"
}

exit 0
