@{
    RootModule        = 'ClaudeCLI.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '8f3a1b2c-4d5e-6f7a-8b9c-0d1e2f3a4b5c'
    Author            = 'dotbot contributors'
    Description       = 'PowerShell wrapper for the Claude CLI with streaming support, activity logging, and shared formatting primitives.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Invoke-ClaudeStream'
        'Invoke-Claude'
        'Get-ClaudeModels'
        'New-ClaudeSession'
        'Get-LastRateLimitInfo'
        'Write-ActivityLog'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('ics', 'ic', 'gclm', 'ncs')
}
