@{
    RootModule        = 'SettingsLoader.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '045320c7-332f-4682-bf3a-161299256874'
    Author            = 'dotbot contributors'
    Description       = 'Resolves dotbot settings via the layered default -> user -> control merge.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Merge-DeepSettings'
        'Get-MergedSettings'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
