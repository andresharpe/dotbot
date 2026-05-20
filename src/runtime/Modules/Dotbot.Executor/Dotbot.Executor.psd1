@{
    RootModule        = 'Dotbot.Executor.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b6f4e8a5-1c19-4f31-89aa-7d2c4e9a6b03'
    Author            = 'dotbot contributors'
    Description       = 'Plugin executor dispatcher (PRD-05). Discovers executor folders, validates metadata, and routes task execution by task.type. Each executor declares its contract via metadata.yaml and exports an Invoke-Executor function in script.ps1.'
    PowerShellVersion = '7.0'

    NestedModules     = @(
        'v4/Discovery.psm1',
        'v4/Dispatch.psm1'
    )

    FunctionsToExport = @(
        # Discovery
        'Get-DotbotExecutorsDir'
        'Read-ExecutorMetadata'
        'Test-ExecutorMetadata'
        'Assert-ExecutorMetadata'
        'Get-ExecutorRegistry'

        # Dispatch
        'Test-ExecutorRequiredFields'
        'Invoke-TaskExecutor'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
