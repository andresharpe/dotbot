@{
    RootModule        = 'Dotbot.Workflow.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'ffc6b42e-5ee9-4dc7-bcfe-702e24d5c4f3'
    Author            = 'dotbot contributors'
    Description       = 'Workflow manifest handling: parse workflow.yaml, validate schemas, generate tasks, evaluate path conditions, merge MCP server definitions.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
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
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
