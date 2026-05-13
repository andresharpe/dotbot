@{
    RootModule        = 'ConsoleSequenceSanitizer.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8e8d6969-1e3a-4d32-b33b-65402c9dd993'
    Author            = 'dotbot contributors'
    Description       = 'Strips ANSI escape sequences and other control characters from captured console output.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'ConvertTo-SanitizedConsoleText'
        'Update-ProcessHeartbeatFields'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
