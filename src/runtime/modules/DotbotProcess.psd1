@{
    RootModule = 'DotbotProcess.psm1'
    ModuleVersion = '0.1.0'
    GUID = '2e26626d-c82a-47ea-9e4d-c022fc1ff184'
    Author = 'Andre'
    Description = 'Starts pwsh child processes with platform-specific stdout/stderr handling'
    PowerShellVersion = '7.0'

    NestedModules = @(
        'DotbotCore.psm1'
    )

    FunctionsToExport = @(
        'Start-DotbotProcess'
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
