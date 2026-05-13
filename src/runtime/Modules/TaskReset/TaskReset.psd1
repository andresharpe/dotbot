@{
    RootModule        = 'TaskReset.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '844bfbfc-fbf2-48bb-b5b2-6b617c2212c1'
    Author            = 'dotbot contributors'
    Description       = 'Recovers stuck or interrupted tasks back to todo for retry.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Reset-InProgressTasks'
        'Reset-SkippedTasks'
        'Reset-AnalysingTasks'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
