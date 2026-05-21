#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Unit + integration tests for Dotbot.Worktree.
.DESCRIPTION
    Covers:
      - Pure path / branch / dir-name derivation (no git needed).
      - Lifecycle against a tmp git repo: create per-run worktree;
        complete with success (dir removed, branch present);
        complete with cancel after dirtying the worktree (wip commit
        present, dir removed).
      - Parallel runs: two isolated runs at the same time each get their
        own worktree path, branches are independent.
      - Prune-branches selection (pure function over a list of branches).
      - Git-ready refusal for non-git directories and empty git repos.

    Style: external-behaviour assertions. Tests drive the public surface
    (Resolve-RunWorktreeLayout / New-RunWorktree / Complete-RunWorktree /
    Get-PrunableBranches / Invoke-PruneBranches) and inspect the resulting
    on-disk + git state.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Worktree" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1") -Force -DisableNameChecking

# Helpers local to this test file --------------------------------------------

function New-TestRunRecord {
    param(
        [string]$WorkflowName = 'demo-workflow',
        [string]$RunId        = 'wr_AbCd1234',
        [string]$StartedAt    = '2026-05-19T10:00:00Z'
    )
    return [ordered]@{
        run_id        = $RunId
        workflow_name = $WorkflowName
        started_at    = $StartedAt
        isolated      = $true
    }
}

function Get-BranchExists {
    param([string]$ProjectRoot, [string]$Branch)
    & git -C $ProjectRoot rev-parse --verify "refs/heads/$Branch" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-BranchLog {
    param([string]$ProjectRoot, [string]$Branch)
    $log = & git -C $ProjectRoot log --pretty=format:'%s' "$Branch" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return @($log | ForEach-Object { "$_" })
}

# ═══════════════════════════════════════════════════════════════════
# Pure path / branch / dir-name derivation
# ═══════════════════════════════════════════════════════════════════

Write-Host "  Pure path/branch derivation" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-Equal -Name "ConvertTo-WorktreeSlug — lowercase + hyphenates" `
    -Expected 'add-feature-x' `
    -Actual (ConvertTo-WorktreeSlug -Text 'Add Feature X')

Assert-Equal -Name "ConvertTo-WorktreeSlug — strips punctuation" `
    -Expected 'fix-the-bug' `
    -Actual (ConvertTo-WorktreeSlug -Text "Fix the bug!?,")

Assert-Equal -Name "ConvertTo-WorktreeSlug — empty becomes 'untitled'" `
    -Expected 'untitled' `
    -Actual (ConvertTo-WorktreeSlug -Text '')

$longName = ('x' * 80)
Assert-True -Name "ConvertTo-WorktreeSlug — caps at 40 chars" `
    -Condition ((ConvertTo-WorktreeSlug -Text $longName).Length -le 40)

Assert-Equal -Name "Get-WorktreeBranchName — workflow run prefix" `
    -Expected 'workflow/add-feature-x-AbCd' `
    -Actual (Get-WorktreeBranchName -Slug 'add-feature-x' -ShortId 'AbCd')

Assert-Equal -Name "Get-WorktreeBranchName — standalone prefix" `
    -Expected 'task/quick-fix-EfGh' `
    -Actual (Get-WorktreeBranchName -Slug 'quick-fix' -ShortId 'EfGh' -Standalone)

Assert-Equal -Name "Get-WorktreeDirName — date-slug-shortid" `
    -Expected '2026-05-19-add-feature-x-AbCd' `
    -Actual (Get-WorktreeDirName -Date '2026-05-19' -Slug 'add-feature-x' -ShortId 'AbCd')

$tmpRoot = if ($IsWindows) { 'C:\repos\proj' } else { '/tmp/repos/proj' }
$base    = Get-WorktreeBasePath -ProjectRoot $tmpRoot
$expectedBase = if ($IsWindows) { 'C:\repos\worktrees\proj' } else { '/tmp/repos/worktrees/proj' }
Assert-Equal -Name "Get-WorktreeBasePath — sibling 'worktrees' tree" `
    -Expected $expectedBase `
    -Actual $base

$layout = Resolve-RunWorktreeLayout -ProjectRoot $tmpRoot -RunRecord (New-TestRunRecord -WorkflowName 'My Feature' -RunId 'wr_ZzYy1234' -StartedAt '2026-05-19T12:00:00Z')
Assert-Equal -Name "Resolve-RunWorktreeLayout — short_id is first 4 of body" `
    -Expected 'ZzYy' -Actual $layout.short_id
Assert-Equal -Name "Resolve-RunWorktreeLayout — slug from workflow_name" `
    -Expected 'my-feature' -Actual $layout.slug
Assert-Equal -Name "Resolve-RunWorktreeLayout — dir_name format" `
    -Expected '2026-05-19-my-feature-ZzYy' -Actual $layout.dir_name
Assert-Equal -Name "Resolve-RunWorktreeLayout — branch_name (workflow)" `
    -Expected 'workflow/my-feature-ZzYy' -Actual $layout.branch_name

$layoutStandalone = Resolve-RunWorktreeLayout -ProjectRoot $tmpRoot -RunRecord (New-TestRunRecord -WorkflowName 'tiny task' -RunId 'wr_QqWwEeRr') -Standalone
Assert-Equal -Name "Resolve-RunWorktreeLayout — branch_name (standalone)" `
    -Expected 'task/tiny-task-QqWw' -Actual $layoutStandalone.branch_name

# Missing fields raise.
$threw = $false
try { Resolve-RunWorktreeLayout -ProjectRoot $tmpRoot -RunRecord @{ workflow_name = 'x' } } catch { $threw = $true }
Assert-True -Name "Resolve-RunWorktreeLayout — throws when run_id missing" -Condition $threw

$threw = $false
try { Resolve-RunWorktreeLayout -ProjectRoot $tmpRoot -RunRecord @{ run_id = 'wr_AbCd1234' } } catch { $threw = $true }
Assert-True -Name "Resolve-RunWorktreeLayout — throws when workflow_name missing" -Condition $threw

$threw = $false
try { Resolve-RunWorktreeLayout -ProjectRoot $tmpRoot -RunRecord @{ run_id = 'banana'; workflow_name = 'x' } } catch { $threw = $true }
Assert-True -Name "Resolve-RunWorktreeLayout — throws on malformed run_id" -Condition $threw

# ═══════════════════════════════════════════════════════════════════
# Lifecycle — create, success-complete, cancel-complete
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Lifecycle (create / success / cancel)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$lifecycleProject = New-TestProject -Prefix 'dotbot-test-wt-lifecycle'
try {
    # Force the canonical 'main' branch — New-TestProject's `git init` may
    # land on whatever init.defaultBranch is on this machine.
    & git -C $lifecycleProject branch -M main 2>$null | Out-Null

    $run = New-TestRunRecord -WorkflowName 'Lifecycle Demo' -RunId 'wr_LfCy0001'
    $createResult = New-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run

    Assert-True -Name "New-RunWorktree — success on clean repo" -Condition ([bool]$createResult.success) `
        -Message ($createResult | ConvertTo-Json -Compress -Depth 5)
    Assert-Equal -Name "New-RunWorktree — branch_name set" -Expected 'workflow/lifecycle-demo-LfCy' -Actual $createResult.branch_name
    Assert-PathExists -Name "New-RunWorktree — worktree dir exists" -Path $createResult.worktree_path
    Assert-PathExists -Name "New-RunWorktree — .git marker present" -Path (Join-Path $createResult.worktree_path '.git')

    # No junctions / symlinks. Check a few candidate paths that the legacy
    # implementation would have created links at — they must NOT exist.
    $legacyLinks = @('.bot/.control', '.bot/workspace/tasks', '.bot/workspace/product', '.bot/hooks', '.bot/recipes', '.bot/settings', '.bot/systems')
    $anyJunction = $false
    foreach ($lp in $legacyLinks) {
        $candidate = Join-Path $createResult.worktree_path $lp
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            if ($item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $item.LinkType)) {
                $anyJunction = $true
                break
            }
        }
    }
    Assert-True -Name "New-RunWorktree — no junction/symlink leftovers" -Condition (-not $anyJunction)

    Assert-True -Name "New-RunWorktree — branch exists in main repo" `
        -Condition (Get-BranchExists -ProjectRoot $lifecycleProject -Branch $createResult.branch_name)

    # Idempotency: calling create again returns the same path / branch.
    $createAgain = New-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run
    Assert-True -Name "New-RunWorktree — idempotent on second call" -Condition ([bool]$createAgain.success)
    Assert-Equal -Name "New-RunWorktree — same worktree_path on repeat" `
        -Expected $createResult.worktree_path -Actual $createAgain.worktree_path

    # --- Success completion: dir removed, branch preserved -------------------
    $okResult = Complete-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run -Outcome success
    Assert-True -Name "Complete-RunWorktree(success) — success=true" -Condition ([bool]$okResult.success)
    Assert-PathNotExists -Name "Complete-RunWorktree(success) — worktree dir removed" -Path $createResult.worktree_path
    Assert-True -Name "Complete-RunWorktree(success) — branch preserved" `
        -Condition (Get-BranchExists -ProjectRoot $lifecycleProject -Branch $createResult.branch_name)
    Assert-True -Name "Complete-RunWorktree(success) — no wip commit created" `
        -Condition ([string]::IsNullOrEmpty($okResult.wip_commit))

    # --- Cancel completion with dirty worktree -------------------------------
    $run2 = New-TestRunRecord -WorkflowName 'Cancel Demo' -RunId 'wr_CnCl0002'
    $create2 = New-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run2
    Assert-True -Name "Cancel scenario — create succeeded" -Condition ([bool]$create2.success)

    # Dirty the worktree (untracked file + modification to a tracked file).
    "agent-leftover" | Set-Content -Path (Join-Path $create2.worktree_path 'AGENT_NOTES.md')
    "more text" | Add-Content -Path (Join-Path $create2.worktree_path 'README.md')

    $logBefore = Get-BranchLog -ProjectRoot $lifecycleProject -Branch $create2.branch_name
    $cancelResult = Complete-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run2 -Outcome cancel -Reason 'user-cancel'

    Assert-True -Name "Complete-RunWorktree(cancel) — success=true" -Condition ([bool]$cancelResult.success) `
        -Message ($cancelResult | ConvertTo-Json -Compress -Depth 5)
    Assert-PathNotExists -Name "Complete-RunWorktree(cancel) — worktree dir removed" -Path $create2.worktree_path
    Assert-True -Name "Complete-RunWorktree(cancel) — wip_commit captured" `
        -Condition (-not [string]::IsNullOrWhiteSpace($cancelResult.wip_commit))

    $logAfter = Get-BranchLog -ProjectRoot $lifecycleProject -Branch $create2.branch_name
    Assert-True -Name "Complete-RunWorktree(cancel) — added a new commit on branch" `
        -Condition (@($logAfter).Count -gt @($logBefore).Count)
    $wipFound = $false
    foreach ($l in @($logAfter)) {
        if ($l -match '^wip: user-cancel at \d{4}-\d{2}-\d{2}T') { $wipFound = $true; break }
    }
    Assert-True -Name "Complete-RunWorktree(cancel) — wip commit message format" -Condition $wipFound

    # Idempotent cancel: directory already gone, call should still succeed.
    $cancelAgain = Complete-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run2 -Outcome cancel
    Assert-True -Name "Complete-RunWorktree(cancel) — idempotent on missing dir" -Condition ([bool]$cancelAgain.success)

    # --- Fail outcome behaves like cancel but tags message accordingly -------
    $run3 = New-TestRunRecord -WorkflowName 'Fail Demo' -RunId 'wr_FaIl0003'
    $create3 = New-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run3
    "trash" | Set-Content -Path (Join-Path $create3.worktree_path 'FAILED.txt')
    $failResult = Complete-RunWorktree -ProjectRoot $lifecycleProject -RunRecord $run3 -Outcome fail -Reason 'tests-broken'
    Assert-True -Name "Complete-RunWorktree(fail) — success=true" -Condition ([bool]$failResult.success)
    Assert-True -Name "Complete-RunWorktree(fail) — branch preserved for forensics" `
        -Condition (Get-BranchExists -ProjectRoot $lifecycleProject -Branch $create3.branch_name)
    $log3 = Get-BranchLog -ProjectRoot $lifecycleProject -Branch $create3.branch_name
    $failWipFound = $false
    foreach ($l in @($log3)) {
        if ($l -match '^wip: failed \(tests-broken\) at \d{4}-\d{2}-\d{2}T') { $failWipFound = $true; break }
    }
    Assert-True -Name "Complete-RunWorktree(fail) — wip-failed commit message" -Condition $failWipFound

} finally {
    Remove-TestProject -Path $lifecycleProject
    # Also clean any worktree dirs the test left behind in the sibling tree.
    $repoParent = Split-Path $lifecycleProject -Parent
    $wtSibling = Join-Path $repoParent 'worktrees'
    if (Test-Path $wtSibling) {
        Remove-Item -Path $wtSibling -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════
# Parallel runs — independent worktrees + branches
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Parallel runs" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$parallelProject = New-TestProject -Prefix 'dotbot-test-wt-parallel'
try {
    & git -C $parallelProject branch -M main 2>$null | Out-Null

    $runA = New-TestRunRecord -WorkflowName 'Track Alpha' -RunId 'wr_AaAa1111'
    $runB = New-TestRunRecord -WorkflowName 'Track Beta'  -RunId 'wr_BbBb2222'

    $createA = New-RunWorktree -ProjectRoot $parallelProject -RunRecord $runA
    $createB = New-RunWorktree -ProjectRoot $parallelProject -RunRecord $runB

    Assert-True -Name "Parallel — both creates succeed" -Condition ([bool]$createA.success -and [bool]$createB.success)
    Assert-True -Name "Parallel — different worktree paths" -Condition ($createA.worktree_path -ne $createB.worktree_path)
    Assert-True -Name "Parallel — different branch names" -Condition ($createA.branch_name -ne $createB.branch_name)
    Assert-PathExists -Name "Parallel — worktree A on disk" -Path $createA.worktree_path
    Assert-PathExists -Name "Parallel — worktree B on disk" -Path $createB.worktree_path
    Assert-True -Name "Parallel — branch A exists" -Condition (Get-BranchExists -ProjectRoot $parallelProject -Branch $createA.branch_name)
    Assert-True -Name "Parallel — branch B exists" -Condition (Get-BranchExists -ProjectRoot $parallelProject -Branch $createB.branch_name)

    # Tear down A; B must still exist (independence).
    Complete-RunWorktree -ProjectRoot $parallelProject -RunRecord $runA -Outcome success | Out-Null
    Assert-PathNotExists -Name "Parallel — A removed after teardown" -Path $createA.worktree_path
    Assert-PathExists -Name "Parallel — B still present after A teardown" -Path $createB.worktree_path
    Assert-True -Name "Parallel — A branch still preserved" -Condition (Get-BranchExists -ProjectRoot $parallelProject -Branch $createA.branch_name)
    Assert-True -Name "Parallel — B branch still preserved" -Condition (Get-BranchExists -ProjectRoot $parallelProject -Branch $createB.branch_name)
} finally {
    Remove-TestProject -Path $parallelProject
    $repoParent = Split-Path $parallelProject -Parent
    $wtSibling = Join-Path $repoParent 'worktrees'
    if (Test-Path $wtSibling) {
        Remove-Item -Path $wtSibling -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════
# Prune-branches selection (pure)
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Prune selection (pure function)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$nowUtc = (Get-Date).ToUniversalTime()
$cutoff = $nowUtc.AddDays(-30)
$branches = @(
    @{ name = 'main';                      last_commit_at = $nowUtc.AddDays(-90);  is_current = $true;  has_remote_ref = $true  }
    @{ name = 'workflow/old-feature-AbCd'; last_commit_at = $nowUtc.AddDays(-60);  is_current = $false; has_remote_ref = $false }
    @{ name = 'workflow/recent-EfGh';      last_commit_at = $nowUtc.AddDays(-5);   is_current = $false; has_remote_ref = $false }
    @{ name = 'task/old-fix-IjKl';         last_commit_at = $nowUtc.AddDays(-45);  is_current = $false; has_remote_ref = $false }
    @{ name = 'task/old-pushed-MnOp';      last_commit_at = $nowUtc.AddDays(-45);  is_current = $false; has_remote_ref = $true  }
    @{ name = 'workflow/active-checkout';  last_commit_at = $nowUtc.AddDays(-60);  is_current = $true;  has_remote_ref = $false }
    @{ name = 'random/other';              last_commit_at = $nowUtc.AddDays(-90);  is_current = $false; has_remote_ref = $false }
)

$prunable = Get-PrunableBranches -Branches $branches -CutoffUtc $cutoff -Match all
$names = @($prunable | ForEach-Object { $_['name'] })

Assert-True -Name "Prune — includes workflow/old-feature-AbCd"           -Condition ($names -contains 'workflow/old-feature-AbCd')
Assert-True -Name "Prune — includes task/old-fix-IjKl"                   -Condition ($names -contains 'task/old-fix-IjKl')
Assert-True -Name "Prune — excludes recent workflow"                     -Condition (-not ($names -contains 'workflow/recent-EfGh'))
Assert-True -Name "Prune — excludes branch with remote ref by default"   -Condition (-not ($names -contains 'task/old-pushed-MnOp'))
Assert-True -Name "Prune — excludes currently checked out branch"        -Condition (-not ($names -contains 'workflow/active-checkout'))
Assert-True -Name "Prune — excludes non-workflow/task branches"          -Condition (-not ($names -contains 'main'))
Assert-True -Name "Prune — excludes other-prefixed branches"             -Condition (-not ($names -contains 'random/other'))

$prunableWorkflow = Get-PrunableBranches -Branches $branches -CutoffUtc $cutoff -Match workflow
$wfNames = @($prunableWorkflow | ForEach-Object { $_['name'] })
Assert-True -Name "Prune — -Match workflow only returns workflow/*"      -Condition (($wfNames -contains 'workflow/old-feature-AbCd') -and (-not ($wfNames -contains 'task/old-fix-IjKl')))

$prunableTask = Get-PrunableBranches -Branches $branches -CutoffUtc $cutoff -Match task
$tkNames = @($prunableTask | ForEach-Object { $_['name'] })
Assert-True -Name "Prune — -Match task only returns task/*"              -Condition (($tkNames -contains 'task/old-fix-IjKl') -and (-not ($tkNames -contains 'workflow/old-feature-AbCd')))

$prunableWithRemote = Get-PrunableBranches -Branches $branches -CutoffUtc $cutoff -Match all -IncludeRemote
$irNames = @($prunableWithRemote | ForEach-Object { $_['name'] })
Assert-True -Name "Prune — -IncludeRemote pulls in remote-tracked"       -Condition ($irNames -contains 'task/old-pushed-MnOp')

# ═══════════════════════════════════════════════════════════════════
# Prune-branches integration (real git repo)
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Prune integration (live git repo)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$pruneProject = New-TestProject -Prefix 'dotbot-test-wt-prune'
try {
    & git -C $pruneProject branch -M main 2>$null | Out-Null

    # Create three branches at HEAD so we have known shapes to filter on.
    foreach ($b in @('workflow/aged-AaBb', 'workflow/young-CcDd', 'task/aged-EeFf')) {
        & git -C $pruneProject branch $b 2>$null | Out-Null
    }

    # `Get-PrunableBranches` uses committerdate to filter. The just-created
    # branches all share the initial commit's mtime, which is "now", so a
    # 30d cutoff won't include any of them. Use a 0d cutoff so the moving
    # "now" passes any commit timestamp that is in the past.
    $result = Invoke-PruneBranches -ProjectRoot $pruneProject -OlderThan '0d' -DryRun
    Assert-True -Name "Prune integration — DryRun returns candidates list" -Condition ($null -ne $result.candidates)
    Assert-True -Name "Prune integration — DryRun does NOT delete any branch" -Condition ($result.deleted.Count -eq 0)
    foreach ($b in @('workflow/aged-AaBb', 'workflow/young-CcDd', 'task/aged-EeFf')) {
        Assert-True -Name "Prune integration — DryRun keeps '$b'" -Condition (Get-BranchExists -ProjectRoot $pruneProject -Branch $b)
    }

    # Same query without DryRun should actually delete them. None are currently
    # checked out (main is HEAD); none have remote refs (no remote configured).
    $resultLive = Invoke-PruneBranches -ProjectRoot $pruneProject -OlderThan '0d'
    $deletedNames = @($resultLive.deleted)
    Assert-True -Name "Prune integration — live run deletes workflow/aged-AaBb" -Condition ($deletedNames -contains 'workflow/aged-AaBb')
    Assert-True -Name "Prune integration — live run deletes task/aged-EeFf"   -Condition ($deletedNames -contains 'task/aged-EeFf')
    Assert-True -Name "Prune integration — main branch survives"              -Condition (Get-BranchExists -ProjectRoot $pruneProject -Branch 'main')

    # -Match workflow narrows the filter.
    foreach ($b in @('workflow/keep-A', 'task/keep-B')) {
        & git -C $pruneProject branch $b 2>$null | Out-Null
    }
    $resultMatch = Invoke-PruneBranches -ProjectRoot $pruneProject -OlderThan '0d' -Match workflow
    $matchDeleted = @($resultMatch.deleted)
    Assert-True -Name "Prune integration — -Match workflow deletes workflow/*" -Condition ($matchDeleted -contains 'workflow/keep-A')
    Assert-True -Name "Prune integration — -Match workflow spares task/*"     -Condition (Get-BranchExists -ProjectRoot $pruneProject -Branch 'task/keep-B')

    # Bad duration throws.
    $threw = $false
    try { Invoke-PruneBranches -ProjectRoot $pruneProject -OlderThan 'forever' -DryRun } catch { $threw = $true }
    Assert-True -Name "Prune integration — bad duration throws" -Condition $threw
} finally {
    Remove-TestProject -Path $pruneProject
}

# ═══════════════════════════════════════════════════════════════════
# Git-ready refusal
# ═══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Git-ready refusal (precondition)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Case A: no .git at all.
$noGitDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-nogit-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $noGitDir -Force | Out-Null
try {
    $run = New-TestRunRecord -WorkflowName 'No Git' -RunId 'wr_NoGt0001'
    $result = New-RunWorktree -ProjectRoot $noGitDir -RunRecord $run
    Assert-True -Name "New-RunWorktree — refuses non-git dir" -Condition (-not [bool]$result.success)
    Assert-Equal -Name "New-RunWorktree — refusal reason no_git" -Expected 'no_git' -Actual $result.reason
    Assert-True -Name "New-RunWorktree — refusal message mentions isolated workflows" `
        -Condition ($result.message -match 'Isolated workflows require a git repo')
} finally {
    Remove-Item -Path $noGitDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Case B: git repo with zero commits.
$emptyRepo = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-emptyrepo-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $emptyRepo -Force | Out-Null
try {
    & git -C $emptyRepo init --quiet 2>$null | Out-Null
    $run = New-TestRunRecord -WorkflowName 'No Commits' -RunId 'wr_NoCt0002'
    $result = New-RunWorktree -ProjectRoot $emptyRepo -RunRecord $run
    Assert-True -Name "New-RunWorktree — refuses git repo with no commits" -Condition (-not [bool]$result.success)
    Assert-Equal -Name "New-RunWorktree — refusal reason no_commits" -Expected 'no_commits' -Actual $result.reason
} finally {
    Remove-Item -Path $emptyRepo -Recurse -Force -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════

if (-not (Write-TestSummary -LayerName "Worktree")) {
    exit 1
}
exit 0
