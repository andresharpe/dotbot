@{
    RootModule        = 'Dotbot.Logging.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '594900fe-7b72-4427-a7af-10e748a7e458'
    Author            = 'dotbot contributors'
    Description       = 'Structured file + console logger for the dotbot runtime. Writes JSONL to .control/logs/, mirrors Info+ events to activity.jsonl, themed console output when Dotbot.Theme is loaded.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Initialize-DotbotLog'
        'Write-BotLog'
        'Rotate-DotbotLog'
        'Write-Diag'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
