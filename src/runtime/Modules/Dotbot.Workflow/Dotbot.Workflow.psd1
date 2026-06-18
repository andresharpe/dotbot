@{
    RootModule        = 'Dotbot.Workflow.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'ffc6b42e-5ee9-4dc7-bcfe-702e24d5c4f3'
    Author            = 'dotbot contributors'
    Description       = 'Workflow manifest handling and WorkflowRun + TaskDefinition schemas.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    NestedModules     = @(
        'Private/TaskDefinition.psm1',
        'Private/WorkflowRun.psm1'
    )

    FunctionsToExport = @(
    # legacy surface
        'Read-WorkflowManifest'
        'Test-ValidWorkflowDir'
        'Get-RecipeFolders'
        'Get-ActiveWorkflowManifest'
        'Get-WorkflowTierRoots'
        'Find-Workflow'
        'Discover-Workflows'
        'Get-ManifestEntryField'
        'Format-ManifestEntryForError'
        'Test-WorkflowFormFieldSchema'
        'Test-WorkflowManifestSchema'
        'Convert-ManifestRequiresToPreflightChecks'
        'Ensure-ManifestTaskIds'
        'Convert-ManifestTasksToPhases'
        'New-WorkflowTask'
        'Initialize-WorkflowRun'
        'Find-WorkflowRunDir'
        'Get-ActiveWorkflowRuns'
        'Merge-McpServers'
        'Remove-OrphanMcpServers'
        'New-EnvLocalScaffold'
        'Clear-WorkflowTasks'
        'Test-ManifestCondition'
        'Test-CanStartRun'
        'Test-GitReadyForWorktree'

        # TaskDefinition
        'Get-TaskDefinitionFields'
        'Get-TaskDefinitionRemovedFields'
        'Test-TaskDefinition'
        'Assert-TaskDefinition'

        # WorkflowRun
        'Get-WorkflowRunSchemaVersion'
        'Get-WorkflowRunRecordFields'
        'Get-WorkflowRunStatusFields'
        'Get-WorkflowRunStatuses'
        'Test-WorkflowRunRecord'
        'Assert-WorkflowRunRecord'
        'Test-WorkflowRunStatus'
        'Assert-WorkflowRunStatus'
        'New-WorkflowRunRecord'
        'New-WorkflowRunStatus'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
