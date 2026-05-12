@{
    RootModule        = 'DotbotTheme.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '062b3e6d-6817-444f-b0ca-28d4578c9d4b'
    Author            = 'dotbot contributors'
    Description       = 'CRT/retro-futuristic console theming, formatting, and rendering helpers.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Get-DotbotTheme'
        'Update-DotbotTheme'
        'Get-DotbotVersion'
        'Write-Phosphor'
        'Write-Status'
        'Write-SubStatus'
        'Write-Label'
        'Write-Header'
        'Write-Led'
        'Write-Separator'
        'Write-Banner'
        'Get-VisualWidth'
        'Get-PaddedText'
        'Write-Card'
        'Write-CardRow'
        'Write-Table'
        'Write-ProgressCard'
        'Write-Panel'
        'Write-TaskHeader'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
