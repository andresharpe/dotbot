@{
    RootModule        = 'Dotbot.Core.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '929887a1-4e48-47aa-9099-4ee619b983d6'
    Author            = 'dotbot contributors'
    Description       = 'Foundation helpers for the dotbot runtime: path resolution, workspace identity, console-text sanitization. No Dotbot.* dependencies.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-DotbotEnvelopeAnswer'
        'Get-DotbotInstallPath'
        'Get-DotbotProjectLocalInstallPath'
        'Get-DotbotVendoredInstallPath'
        'Get-DotbotUserSettingsPath'
        'Get-DotbotUserContentPath'
        'Get-DotbotProjectPath'
        'Get-DotbotProjectBotPath'
        'Get-DotbotProjectInstallPath'
        'Get-DotbotProjectRuntimePath'
        'Get-DotbotProjectUIPath'
        'Get-DotbotProjectLogsPath'
        'Get-OrCreateWorkspaceInstanceId'
        'Remove-AbsolutePaths'
        'ConvertTo-SanitizedConsoleText'
        'Update-ProcessHeartbeatFields'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
