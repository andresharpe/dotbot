@{
    RootModule        = 'ManifestCondition.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'd95bd587-51d3-40a7-9666-b5f9f7a9771a'
    Author            = 'dotbot contributors'
    Description       = 'Evaluates "if" / "unless" conditions on workflow and stack manifests.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Test-ManifestCondition'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
