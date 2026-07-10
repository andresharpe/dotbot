@{
    RootModule        = 'Dotbot.Decision.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '4039f9a3-ef84-4ead-9df8-d41afb9aba07'
    Author            = 'dotbot contributors'
    Description       = 'Single point for managing decision records: the write primitive (New-DecisionRecord) and the inbound decision funnel (New-InboundDecision) that promotes mothership answers, workflow registry changes, and material settings changes to first-class decision records.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    FunctionsToExport = @(
        'New-DecisionRecord'
        'New-InboundDecision'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
