@{
    RootModule        = 'Dotbot.Worktree.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fd93c4e5-efce-466c-a37d-2981ab77e495'
    Author            = 'dotbot contributors'
    Description       = 'Git worktree lifecycle: per-run create / complete / prune, plus a per-task worktree manager (junctions, patch-replay, worktree-map).'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    NestedModules     = @(
        'Private/Worktree.psm1'
    )

    FunctionsToExport = @(
        # Per-task worktree manager
        'Read-WorktreeMap'
        'Write-WorktreeMap'
        'Invoke-WorktreeMapLocked'
        'Resolve-DotbotBaseBranch'
        'Resolve-MainBranch'
        'Assert-OnBaseBranch'
        'Stop-WorktreeProcesses'
        'Invoke-Git'
        'Remove-Junctions'
        'New-TaskWorktree'
        'Complete-TaskWorktree'
        'Reset-TaskWorktree'
        'Get-TaskWorktreeInfo'
        'Get-GitignoredCopyPaths'
        'Remove-OrphanWorktrees'

        # Per-WorkflowRun worktree
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
