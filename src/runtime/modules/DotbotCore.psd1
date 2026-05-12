@{
    RootModule        = 'DotbotCore.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '929887a1-4e48-47aa-9099-4ee619b983d6'
    Author            = 'dotbot contributors'
    Description       = 'Shared low-level path helpers used across dotbot runtime modules.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-DotbotInstallPath'
        'Get-DotbotConfigPath'
        'Get-DotbotLogsPath'
        'Get-DotbotProjectPath'
        'Get-DotbotProjectBotPath'
        'Get-DotbotProjectInstallPath'
        'Get-DotbotProjectContentPath'
        'Get-DotbotProjectRuntimePath'
        'Get-DotbotProjectUIPath'
        'Get-DotbotProjectLogsPath'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
