@{
    RootModule        = 'InstanceId.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'cee50da4-60f1-4fb5-bb18-a7c8a231b926'
    Author            = 'dotbot contributors'
    Description       = 'Per-workspace stable instance ID generation and persistence.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-OrCreateWorkspaceInstanceId'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
