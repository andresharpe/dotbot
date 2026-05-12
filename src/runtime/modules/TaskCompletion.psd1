@{
    RootModule        = 'TaskCompletion.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'bf82739b-deae-4416-827e-169e9b10fbb4'
    Author            = 'dotbot contributors'
    Description       = 'Determines whether a task reached a terminal state from filesystem + agent output.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Test-TaskCompletion'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
