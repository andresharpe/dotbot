@{
    RootModule        = 'Dotbot.Provider.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '2c5adb0a-f2fa-464d-969c-927a462bc14d'
    Author            = 'dotbot contributors'
    Description       = 'Unified AI provider integration for dotbot: provider-agnostic CLI dispatch (Claude / Codex / Gemini), Claude streaming engine, activity logging, rate-limit parsing, failure classification, provider-session cleanup.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        # Claude streaming engine
        'Invoke-ClaudeStream'
        'Invoke-Claude'
        'Get-ClaudeModels'
        'New-ClaudeSession'
        'Get-LastRateLimitInfo'
        'Write-ActivityLog'
        # Provider-agnostic dispatch
        'Get-ProviderConfig'
        'Get-ProviderModels'
        'Resolve-ProviderModelId'
        'Build-ProviderCliArgs'
        'Invoke-ProviderStream'
        'Invoke-Provider'
        'New-ProviderSession'
        'Get-LastProviderRateLimitInfo'
        # Rate-limit parsing
        'Get-RateLimitResetTime'
        # Failure classification
        'Get-FailureReason'
        # Provider session cleanup
        'Get-ClaudeProjectDir'
        'Remove-ProviderSession'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('ics', 'ic', 'gclm', 'ncs')
}
