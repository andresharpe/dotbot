@{
    RootModule        = 'Dotbot.Process.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8282b470-dda8-4560-ae8a-eb328bf0a643'
    Author            = 'dotbot contributors'
    Description       = 'Dotbot process lifecycle: business-level process registry (tracking, locks, activity) and low-level pwsh child process spawning.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    FunctionsToExport = @(
        # Process registry
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
        'Get-NextWorkflowTask'
        'Test-DependencyDeadlock'
        'Test-WorkflowComplete'
        # Child process spawning
        'Start-DotbotChildProcess'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
