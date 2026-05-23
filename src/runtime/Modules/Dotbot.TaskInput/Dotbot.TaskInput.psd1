@{
    RootModule        = 'Dotbot.TaskInput.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0f0a7f17-dc1a-4f3e-927d-1a8bbf72f1cd'
    Author            = 'dotbot contributors'
    Description       = 'Runtime-owned task human-input transitions for questions and split decisions.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Ensure-TaskInputPendingQuestionIds'
        'Invoke-TaskQuestionAnswerTransition'
        'Invoke-TaskSplitDecisionTransition'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
