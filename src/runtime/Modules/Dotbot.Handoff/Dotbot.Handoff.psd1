@{
    RootModule        = 'Dotbot.Handoff.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '2af05e6a-4895-4aa8-9b17-44c9f99502ef'
    Author            = 'dotbot contributors'
    Description       = 'Task-scoped human-input handoff files and same-task resume context.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'New-DotbotTaskHandoff'
        'Complete-DotbotTaskHandoffForAnswer'
        'Get-DotbotTaskResumeContext'
        'Start-DotbotTaskSessionAttempt'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
