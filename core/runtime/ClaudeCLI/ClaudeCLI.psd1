@{
    RootModule = 'ClaudeCLI.psm1'
    ModuleVersion = '0.1.0'
    GUID = '8f3a1b2c-4d5e-6f7a-8b9c-0d1e2f3a4b5c'
    Author = 'Andre'
    Description = 'PowerShell wrapper for the Claude CLI with streaming support'
    PowerShellVersion = '7.0'
    
    FunctionsToExport = @(
        'Invoke-ClaudeStream'
        'Invoke-Claude'
        'Get-ClaudeModels'
        'New-ClaudeSession'
    )
    
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('ics', 'ic', 'gclm', 'ncs')
    
    PrivateData = @{
        PSData = @{
            Tags = @('Claude', 'AI', 'CLI', 'Assistant')
            ProjectUri = ''
            ReleaseNotes = 'Initial release with streaming support'
        }
    }
}
