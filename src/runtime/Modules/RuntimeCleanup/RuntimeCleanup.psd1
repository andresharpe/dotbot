@{
    RootModule        = 'RuntimeCleanup.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'edc3180a-44fd-41b5-a0a3-dca2db4687ad'
    Author            = 'dotbot contributors'
    Description       = 'Cleans up per-task provider session artifacts (Claude session files, etc).'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-ClaudeProjectDir'
        'Remove-ProviderSession'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
