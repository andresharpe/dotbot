@{
    RootModule        = 'FailureReason.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1b2c3d4-e5f6-4789-9abc-def012345601'
    Author            = 'dotbot contributors'
    Description       = 'Classifies Claude/provider failure reasons from exit codes and stderr.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-FailureReason'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
