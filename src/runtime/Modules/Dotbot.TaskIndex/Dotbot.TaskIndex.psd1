@{
    RootModule        = 'Dotbot.TaskIndex.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '05fb9cb9-1c2d-4f35-9738-23c9c224f7ad'
    Author            = 'dotbot contributors'
    Description       = 'Runtime task index and filesystem query helpers for task state directories.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Initialize-TaskIndex'
        'Update-TaskIndex'
        'Get-TaskIndex'
        'Get-TodoTasks'
        'Get-AnalysingTasks'
        'Get-NeedsInputTasks'
        'Get-AnalysedTasks'
        'Get-InProgressTasks'
        'Get-DoneTasks'
        'Get-SplitTasks'
        'Get-SkippedTasks'
        'Get-CancelledTasks'
        'Get-AllTasks'
        'Get-NextTask'
        'Get-NextAnalysedTask'
        'Get-DeadlockedTasks'
        'Test-TaskDone'
        'Get-TaskTerminalState'
        'Test-IsFrameworkErrorSkip'
        'Get-IntentionalSkipReasons'
        'Get-FrameworkSkipReasons'
        'Test-DependencyMet'
        'Test-AllDependenciesMet'
        'Get-TaskById'
        'Get-TaskStats'
        'Get-RemainingEffort'
        'Reset-TaskIndex'
        'Stop-TaskIndexWatcher'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
