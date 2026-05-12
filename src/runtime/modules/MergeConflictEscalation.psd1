@{
    RootModule        = 'MergeConflictEscalation.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '4edd9362-9668-4e85-83dd-8f1ef830208d'
    Author            = 'dotbot contributors'
    Description       = 'Detects unresolved merge conflicts and routes affected tasks to needs-input.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Move-TaskToMergeConflictNeedsInput'
        'Invoke-MergeConflictEscalation'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
