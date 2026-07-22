@{
    RootModule        = 'Dotbot.LegacyYaml.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8f2c6a1d-4b7e-4c93-9d15-3e8a5f0b6c24'
    Author            = 'dotbot contributors'
    Description       = 'Legacy v3.5 YAML manifest detection and one-time migration to the v4 JSON layout for workflows and registries.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    FunctionsToExport = @(
        'Import-DotbotYamlSupport'
        'Convert-DotbotYamlFileToJson'
        'Update-DotbotManifestFromYaml'
        'Get-DotbotLegacyYamlFile'
        'Test-DotbotLegacyYamlPresent'
        'Invoke-DotbotWorkflowYamlMigration'
        'Invoke-DotbotSingleRegistryYamlMigration'
        'Invoke-DotbotRegistryYamlMigration'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
