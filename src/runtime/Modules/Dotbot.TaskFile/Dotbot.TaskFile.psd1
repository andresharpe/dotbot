@{
    RootModule        = 'Dotbot.TaskFile.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7b4f973-87c5-4d5b-b5a8-26cfa8e8a6c1'
    Author            = 'dotbot contributors'
    Description       = 'Atomic, lock-protected task JSON file mutations for the dotbot runtime.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Write-TaskFileAtomic'
        'Write-TaskFileRawAtomic'
        'Move-TaskFileAtomic'
        'Remove-TaskFileAtomic'
        'Invoke-WithTaskLock'
        'Get-TaskSlug'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
