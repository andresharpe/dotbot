@{
    RootModule        = 'PostScriptRunner.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8c142f3f-a294-4caf-8680-7f3519ff8374'
    Author            = 'dotbot contributors'
    Description       = 'Executes workflow phase post-scripts with escalation on failure.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Invoke-PostScript'
        'Invoke-PostScriptFailureEscalation'
        'Invoke-TaskPostScriptIfPresent'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
