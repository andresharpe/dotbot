@{
    RootModule        = 'Dotbot.Worktree.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fd93c4e5-efce-466c-a37d-2981ab77e495'
    Author            = 'dotbot contributors'
    Description       = 'Per-task git worktree lifecycle: branch + worktree creation, shared-infra junctions, squash-merge completion, orphan cleanup.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
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
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
