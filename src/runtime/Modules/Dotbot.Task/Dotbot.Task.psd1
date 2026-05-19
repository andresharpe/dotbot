@{
    RootModule        = 'Dotbot.Task.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'bf82739b-deae-4416-827e-169e9b10fbb4'
    Author            = 'dotbot contributors'
    Description       = 'Task lifecycle for the dotbot runtime. v3 surface (prompt building, completion detection, state recovery, post-script hooks, merge-failure escalation, interview loop) plus the v4 canonical data model (PRD-01): IdGen, transition table, TaskInstance schema, on-disk layout.'
    PowerShellVersion = '7.0'

    # v4 surface lives in nested module files so each concern (id generation,
    # transitions, schema, layout) is findable in isolation. v3 surface stays
    # in the root .psm1 until downstream PRDs migrate consumers.
    NestedModules     = @(
        'v4/IdGen.psm1',
        'v4/Transitions.psm1',
        'v4/TaskInstance.psm1',
        'v4/Layout.psm1'
    )

    FunctionsToExport = @(
        # v3 surface
        'Build-TaskPrompt'
        'Test-TaskCompletion'
        'Reset-InProgressTasks'
        'Reset-SkippedTasks'
        'Reset-AnalysingTasks'
        'Invoke-PostScript'
        'Invoke-PostScriptFailureEscalation'
        'Invoke-TaskPostScriptIfPresent'
        'Move-TaskToMergeFailureNeedsInput'
        'Invoke-MergeFailureEscalation'
        'New-MergeFailurePendingQuestion'
        'Invoke-InterviewLoop'

        # v4 — IdGen
        'New-DotbotNanoId'
        'New-TaskId'
        'New-WorkflowRunId'
        'Test-TaskId'
        'Test-WorkflowRunId'
        'Get-ShortId'

        # v4 — Transitions
        'Get-TaskStatuses'
        'Test-TaskStatus'
        'Get-AllowedTransitions'
        'Test-TaskTransition'
        'Assert-TaskTransition'

        # v4 — TaskInstance schema
        'Get-TaskInstanceSchemaVersion'
        'Get-TaskInstanceFields'
        'Test-TaskInstance'
        'Assert-TaskInstance'
        'New-TaskInstance'

        # v4 — Layout
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
