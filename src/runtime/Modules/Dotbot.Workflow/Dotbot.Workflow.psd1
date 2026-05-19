@{
    RootModule        = 'Dotbot.Workflow.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'ffc6b42e-5ee9-4dc7-bcfe-702e24d5c4f3'
    Author            = 'dotbot contributors'
    Description       = 'Workflow manifest handling and v4 WorkflowRun + TaskDefinition schemas (PRD-01).'
    PowerShellVersion = '7.0'

    NestedModules     = @(
        'v4/TaskDefinition.psm1',
        'v4/WorkflowRun.psm1'
    )

    FunctionsToExport = @(
        # v3 surface
        'Read-WorkflowManifest'
        'Test-ValidWorkflowDir'
        'Get-RecipeFolders'
        'Get-ActiveWorkflowManifest'
        'Get-ManifestEntryField'
        'Format-ManifestEntryForError'
        'Test-WorkflowManifestSchema'
        'Convert-ManifestRequiresToPreflightChecks'
        'Ensure-ManifestTaskIds'
        'Convert-ManifestTasksToPhases'
        'New-WorkflowTask'
        'Merge-McpServers'
        'Remove-OrphanMcpServers'
        'New-EnvLocalScaffold'
        'Clear-WorkflowTasks'
        'Test-ManifestCondition'
        'Test-CanStartRun'
        'Test-GitReadyForIsolation'

        # v4 — TaskDefinition
        'Get-TaskDefinitionFields'
        'Get-TaskDefinitionRemovedFields'
        'Test-TaskDefinitionV4'
        'Assert-TaskDefinitionV4'

        # v4 — WorkflowRun
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
