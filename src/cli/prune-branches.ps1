#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot prune-branches — delete stale workflow/* and task/* branches.

.DESCRIPTION
    Lists candidate branches matching 'workflow/*' or 'task/*' older than
    -OlderThan, prompts for confirmation unless -DryRun, never deletes the
    currently checked-out branch on any worktree, and (by default) skips
    branches that have a remote-tracking counterpart (`origin/<name>`).

    Output uses the standard CLI theme helpers from Platform-Functions.psm1
    (CLAUDE.md output-hygiene rule).

    Exit codes:
      0  prune completed (or dry-run printed candidates)
      1  invariant violation (no .git, bad flags, module missing)
#>

[CmdletBinding()]
param(
    [string]$OlderThan = '30d',
    [ValidateSet('workflow','task','all')]
    [string]$Match = 'all',
    [switch]$DryRun,
    [switch]$IncludeRemote,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

Import-Module (Join-Path $PSScriptRoot 'Platform-Functions.psm1') -Force

function Find-ProjectRoot {
    # Walk up from cwd looking for .git so we can prune branches against the
    # right repo. This is the project's main checkout (not a worktree).
    $cur = (Get-Location).Path
    while ($cur) {
        if (Test-Path -LiteralPath (Join-Path $cur '.git')) { return $cur }
        $parent = Split-Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $null
}

$projectRoot = Find-ProjectRoot
if (-not $projectRoot) {
    Write-DotbotError "Could not find a .git directory in this or any parent path."
    exit 1
}

# Resolve the Dotbot.Worktree module — prefer the project's installed copy
# under .bot/src/runtime/ so we pick up the version that was installed for
# this project; fall back to the canonical install or the dev repo.
$candidates = @(
    (Join-Path $projectRoot (Join-Path '.bot' (Join-Path 'src' (Join-Path 'runtime' (Join-Path 'Modules' (Join-Path 'Dotbot.Worktree' 'Dotbot.Worktree.psd1'))))))
    (Join-Path $PSScriptRoot (Join-Path '..' (Join-Path 'runtime' (Join-Path 'Modules' (Join-Path 'Dotbot.Worktree' 'Dotbot.Worktree.psd1')))))
)
$worktreePsd1 = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { $worktreePsd1 = $c; break }
}
if (-not $worktreePsd1) {
    Write-DotbotError "Dotbot.Worktree module not found. Set `$env:DOTBOT_HOME to a dotbot checkout with src/runtime/Modules/Dotbot.Worktree/."
    exit 1
}
Import-Module $worktreePsd1 -DisableNameChecking -Force

# Dry run first so we can show the user what we'd delete, regardless of mode.
try {
    $preview = Invoke-PruneBranches `
        -ProjectRoot $projectRoot `
        -OlderThan   $OlderThan `
        -Match       $Match `
        -DryRun:$true `
        -IncludeRemote:$IncludeRemote
} catch {
    Write-DotbotError $_.Exception.Message
    exit 1
}

Write-DotbotSection "PRUNE BRANCHES"
Write-DotbotLabel "Project:   " $projectRoot
Write-DotbotLabel "Match:     " $Match
Write-DotbotLabel "Older than:" $OlderThan
Write-DotbotLabel "Cutoff UTC:" ([string]$preview.cutoff_utc)
Write-DotbotLabel "Remotes:   " $(if ($IncludeRemote) { "INCLUDED" } else { "skipped (use --IncludeRemote to override)" })
Write-BlankLine

$cands = @($preview.candidates)
if ($cands.Count -eq 0) {
    Write-Success "No branches match the prune criteria."
    Write-BlankLine
    exit 0
}

Write-DotbotSection "CANDIDATES"
foreach ($c in $cands) {
    $name = $c['name']
    $date = $c['last_commit_at']
    $remote = if ($c['has_remote_ref']) { ' [has remote]' } else { '' }
    Write-DotbotLabel ("  • " + $name) ("$date$remote")
}
Write-BlankLine

if ($DryRun) {
    Write-DotbotCommand "Dry run — no branches deleted. Re-run without --DryRun to delete the above."
    Write-BlankLine
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Delete $($cands.Count) branch(es)? [y/N]"
    if ($answer -notmatch '^(y|yes)$') {
        Write-DotbotCommand "Cancelled — no branches deleted."
        Write-BlankLine
        exit 0
    }
}

$result = Invoke-PruneBranches `
    -ProjectRoot $projectRoot `
    -OlderThan   $OlderThan `
    -Match       $Match `
    -DryRun:$false `
    -IncludeRemote:$IncludeRemote

Write-DotbotSection "RESULT"
Write-DotbotLabel "Deleted:" ([string]$result.deleted.Count) -ValueType Success
foreach ($d in @($result.deleted)) {
    Write-Success ("  ✓ " + $d)
}
if ($result.skipped.Count -gt 0) {
    Write-DotbotLabel "Skipped:" ([string]$result.skipped.Count) -ValueType Warning
    foreach ($s in @($result.skipped)) {
        Write-DotbotWarning ("  ⚠ {0} — {1}" -f $s['name'], $s['reason'])
    }
}
Write-BlankLine
exit 0
