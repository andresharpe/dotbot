@{
    RootModule        = 'InterviewLoop.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0e953824-a3d6-4fbe-aa44-7572bf4ddaba'
    Author            = 'dotbot contributors'
    Description       = 'Runs a multi-round Q&A loop with the agent, collecting answers via local files or external channels.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Invoke-InterviewLoop'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
