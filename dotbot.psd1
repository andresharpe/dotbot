@{
    RootModule = 'dotbot.psm1'
    ModuleVersion = '3.5.2'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Andre Sharpe'
    CompanyName = 'Andre Sharpe'
    Copyright = '(c) 2026 Andre Sharpe. All rights reserved.'
    Description = 'Structured AI-assisted development framework with two-phase execution, per-task git worktree isolation, and web dashboard.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @('Invoke-Dotbot')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('dotbot')

    PrivateData = @{
        PSData = @{
            Tags = @('dotbot', 'AI', 'Claude', 'development-framework', 'automation', 'MCP', 'PowerShell')
            LicenseUri = 'https://github.com/andresharpe/dotbot/blob/main/LICENSE'
            ProjectUri = 'https://github.com/andresharpe/dotbot'
            ReleaseNotes = 'Initial release — install via Install-Module dotbot -Scope CurrentUser'
        }
    }
}
