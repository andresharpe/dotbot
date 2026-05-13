@{
    RootModule        = 'Dotbot.Task.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'bf82739b-deae-4416-827e-169e9b10fbb4'
    Author            = 'dotbot contributors'
    Description       = 'Task lifecycle for the dotbot runtime: prompt building, completion detection, state recovery, post-script hooks, merge-conflict escalation, interview loop.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Build-TaskPrompt'
        'Test-TaskCompletion'
        'Reset-InProgressTasks'
        'Reset-SkippedTasks'
        'Reset-AnalysingTasks'
        'Invoke-PostScript'
        'Invoke-PostScriptFailureEscalation'
        'Invoke-TaskPostScriptIfPresent'
        'Move-TaskToMergeConflictNeedsInput'
        'Invoke-MergeConflictEscalation'
        'Invoke-InterviewLoop'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
