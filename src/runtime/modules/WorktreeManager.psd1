@{
    RootModule        = 'WorktreeManager.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fd93c4e5-efce-466c-a37d-2981ab77e495'
    Author            = 'dotbot contributors'
    Description       = 'Creates, tracks, and cleans up per-task git worktrees.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Initialize-WorktreeMap'
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
        'Get-TaskWorktreePath'
        'Get-TaskWorktreeInfo'
        'Get-GitignoredCopyPaths'
        'Copy-BuildArtifacts'
        'Remove-OrphanWorktrees'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
