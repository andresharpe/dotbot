@{
    RootModule        = 'Dotbot.Task.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'bf82739b-deae-4416-827e-169e9b10fbb4'
    Author            = 'dotbot contributors'
    Description       = 'Task lifecycle for the dotbot runtime: prompt building, completion detection, state recovery, post-script hooks, merge-failure escalation, interview loop, plus the canonical data model (IdGen, transition table, TaskInstance schema, on-disk layout).'
    PowerShellVersion = '7.0'

    # Local runtime dependencies load through the manifest so Dotbot.Task.psm1
    # can assume their commands are present without mid-module imports.
    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    # Each concern lives in a nested module so it's findable in isolation.
    NestedModules     = @(
        'Private/IdGen.psm1',
        'Private/Transitions.psm1',
        'Private/TaskInstance.psm1',
        'Private/Layout.psm1'
    )

    FunctionsToExport = @(
        # Task lifecycle helpers
        'Build-TaskPrompt'
        'Resolve-TaskReviewDecision'
        'Test-TaskCompletion'
        'Reset-InProgressTasks'
        'Reset-WorkflowTasksToTodo'
        'Get-WorkflowTransitiveDependents'
        'Reset-SkippedTasks'
        'Invoke-PostScript'
        'Invoke-PostScriptFailureEscalation'
        'Invoke-TaskPostScriptIfPresent'
        'Move-TaskToMergeFailureNeedsInput'
        'Invoke-MergeFailureEscalation'
        'New-MergeFailurePendingQuestion'
        'Invoke-InterviewLoop'

        # IdGen
        'New-DotbotNanoId'
        'New-TaskId'
        'New-WorkflowRunId'
        'Test-TaskId'
        'Test-WorkflowRunId'
        'Get-ShortId'

        # Transitions
        'Get-TaskStatuses'
        'Test-TaskStatus'
        'Get-AllowedTransitions'
        'Test-TaskTransition'
        'Assert-TaskTransition'

        # TaskInstance schema
        'Get-TaskInstanceSchemaVersion'
        'Get-TaskInstanceFields'
        'Test-TaskInstance'
        'Assert-TaskInstance'
        'New-TaskInstance'

        # Layout
        'ConvertTo-DotbotSlug'
        'Get-WorkflowRunLayout'
        'Get-RunTaskFilePath'
        'Get-StandaloneTaskLayout'
        'Get-TaskLayoutPath'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
