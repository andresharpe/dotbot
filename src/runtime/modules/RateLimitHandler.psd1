@{
    RootModule        = 'RateLimitHandler.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '45aaecb5-4811-497a-851f-044b0020eeb9'
    Author            = 'dotbot contributors'
    Description       = 'Parses provider rate-limit messages into wait-until timestamps.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-RateLimitResetTime'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
