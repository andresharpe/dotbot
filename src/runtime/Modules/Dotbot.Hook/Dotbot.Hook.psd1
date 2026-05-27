@{
    RootModule        = 'Dotbot.Hook.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0b9f3e74-7c41-4dba-b35a-26a3d5d2b9e1'
    Author            = 'dotbot contributors'
    Description       = 'Plugin transition hooks. Folder-discovered side effects that fire on status entry. Discovery scans <runtime>/Plugins/Hooks/Transitions/*/metadata.json; Dispatch runs Invoke-Hook in a child runspace with max_duration enforced; abort_on_failure: true causes Set-TaskStatus to revert.'
    PowerShellVersion = '7.0'

    NestedModules     = @(
        'Private/Discovery.psm1',
        'Private/Dispatch.psm1'
    )

    FunctionsToExport = @(
        # Discovery
        'Get-DefaultHooksDirectory'
        'Read-HookMetadata'
        'Get-HookRegistry'
        'Get-HooksForStatus'

        # Dispatch
        'Invoke-TransitionHooks'
        'Invoke-SingleTransitionHook'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
