@{
    RootModule        = 'ProcessRegistry.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8282b470-dda8-4560-ae8a-eb328bf0a643'
    Author            = 'dotbot contributors'
    Description       = 'Tracks long-running dotbot child processes, their locks, and workflow state.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Initialize-ProcessRegistry'
        'New-ProcessId'
        'Write-ProcessFile'
        'Write-ProcessActivity'
        'Test-ProcessStopSignal'
        'Request-ProcessLock'
        'Test-ProcessLock'
        'Set-ProcessLock'
        'Remove-ProcessLock'
        'Test-Preflight'
        'Add-YamlFrontMatter'
        'Get-NextTodoTask'
        'Get-NextWorkflowTask'
        'Test-DependencyDeadlock'
        'Test-WorkflowComplete'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
