@{
    RootModule        = 'Dotbot.Settings.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '045320c7-332f-4682-bf3a-161299256874'
    Author            = 'dotbot contributors'
    Description       = 'Deep-merge settings resolver for dotbot. Layered default -> user -> control merge with PSCustomObject output.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    FunctionsToExport = @(
        'Merge-DeepSettings'
        'Get-MergedSettings'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
