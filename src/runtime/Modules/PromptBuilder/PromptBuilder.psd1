@{
    RootModule        = 'PromptBuilder.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'f6f33b17-2c00-42ea-a7c4-3b0af4e9ca01'
    Author            = 'dotbot contributors'
    Description       = 'Builds Claude prompts from templates with task-context variable substitution.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Build-TaskPrompt'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
