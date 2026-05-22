@{
    RootModule        = 'Dotbot.Harness.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '2c5adb0a-f2fa-464d-969c-927a462bc14d'
    Author            = 'dotbot contributors'
    Description       = 'Pluggable AI harness layer for dotbot. Loads harness adapters from Adapters/ and dispatches stream/invoke/session calls to the active adapter selected by the merged settings.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    FunctionsToExport = @(
        # Dispatch API (harness-agnostic)
        'Invoke-HarnessStream'
        'Invoke-Harness'
        'New-HarnessSession'
        'Remove-HarnessSession'
        'Get-HarnessConfig'
        'Get-HarnessModels'
        'Resolve-HarnessModelId'
        'Build-HarnessCliArgs'
        # Adapter introspection
        'Get-RegisteredHarnessAdapters'
        # Cross-cutting utilities
        'Write-ActivityLog'
        'Get-FailureReason'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
