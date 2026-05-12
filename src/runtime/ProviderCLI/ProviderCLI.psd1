@{
    RootModule        = 'ProviderCLI.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '2c5adb0a-f2fa-464d-969c-927a462bc14d'
    Author            = 'dotbot contributors'
    Description       = 'Provider-agnostic CLI dispatcher for Claude, Codex, and Gemini.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-ProviderConfig'
        'Get-ProviderModels'
        'Resolve-ProviderModelId'
        'Build-ProviderCliArgs'
        'Invoke-ProviderStream'
        'Invoke-Provider'
        'New-ProviderSession'
        'Get-LastProviderRateLimitInfo'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
