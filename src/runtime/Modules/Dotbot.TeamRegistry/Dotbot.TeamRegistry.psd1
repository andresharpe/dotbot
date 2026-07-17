@{
    RootModule        = 'Dotbot.TeamRegistry.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7c9e4a2f-3d5b-4e8c-b1a6-9f2d8e0a7b12'
    Author            = 'dotbot contributors'
    Description       = 'Sole writer of the workspace team registry (.bot/workspace/team-registry.json). Provides read/add/get + schema validation for team members.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-DotbotTeamRegistryPath'
        'Read-DotbotTeamRegistry'
        'Assert-DotbotTeamMember'
        'Add-DotbotTeamMember'
        'Get-DotbotTeamMembers'
        'Get-DotbotTeamMember'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
