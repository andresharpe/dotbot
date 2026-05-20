@{
    RootModule        = 'Dotbot.Worktree.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fd93c4e5-efce-466c-a37d-2981ab77e495'
    Author            = 'dotbot contributors'
    Description       = 'Per-run git worktree lifecycle (PRD-03): create / complete / prune. v3 per-task surface (junctions, patch-replay) retained until PRD-06 swaps the runtime over.'
    PowerShellVersion = '7.0'

    # v4 surface (PRD-03) lives in v4/Worktree.psm1. The legacy v3 surface
    # (junctions, patch-replay, worktree-map) stays in the root .psm1 until
    # PRD-06 hooks repoint the runtime at the new functions.
    NestedModules     = @(
        'v4/Worktree.psm1'
    )

    FunctionsToExport = @(
        # v3 surface — legacy per-task worktree manager
        'Read-WorktreeMap'
        'Write-WorktreeMap'
        'Invoke-WorktreeMapLocked'
        'Resolve-MainBranch'
        'Assert-OnBaseBranch'
        'Stop-WorktreeProcesses'
        'Invoke-Git'
        'Remove-Junctions'
        'New-TaskWorktree'
        'Complete-TaskWorktree'
        'Get-TaskWorktreeInfo'
        'Get-GitignoredCopyPaths'
        'Remove-OrphanWorktrees'

        # v4 surface — per-WorkflowRun worktree (PRD-03)
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

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
