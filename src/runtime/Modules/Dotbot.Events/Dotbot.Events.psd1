@{
    RootModule        = 'Dotbot.Events.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'c4e1f8a2-3b6d-4e9c-8a17-2f5b9d3c7e04'
    Author            = 'dotbot contributors'
    Description       = 'Event-bus sinks. Folder-discovered subscribers that react to bus events on the activity log. Discovery scans <runtime>/Plugins/Events/Sinks/*/metadata.json; Dispatch runs Invoke-Sink in a time-boxed child runspace, non-aborting and out-of-band; a background consumer tails activity.jsonl by persisted byte cursor.'
    PowerShellVersion = '7.0'

    # Concerns live as nested modules so each is findable in isolation.
    # Dispatch (child-runspace execution) and the background Consumer are added
    # in later steps.
    NestedModules     = @(
        'Private/Discovery.psm1'
    )

    FunctionsToExport = @(
        # Discovery
        'Get-DefaultSinksDirectory'
        'Read-SinkMetadata'
        'Get-SinkRegistry'
        'Get-SinksForEvent'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
