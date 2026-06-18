@{
    RootModule        = 'Dotbot.SessionTracking.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'f1d9a7a1-8f53-4d24-b35f-91bd3c4fcb74'
    Author            = 'dotbot contributors'
    Description       = 'Runtime helpers for tracking Claude session IDs on task files.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Add-SessionToTask'
        'Close-SessionOnTask'
        'Get-SessionFromTask'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
