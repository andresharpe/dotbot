@{
    RootModule        = 'Dotbot.Theme.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '062b3e6d-6817-444f-b0ca-28d4578c9d4b'
    Author            = 'dotbot contributors'
    Description       = 'CRT/oscilloscope terminal output for dotbot: themed Write-* helpers, box-drawing primitives, banners, tables, cards.'
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

        # Animation / step / shimmer / themed-progress / grid
        'Format-Phosphor'
        'Get-DotbotSpinner'
        'Set-DotbotSpinner'
        'Get-DotbotBullet'
        'Set-DotbotBullet'
        'Write-Step'
        'Complete-Section'
        'Write-Shimmer'
        'Invoke-PhosphorJob'
        'Write-DotbotProgress'
        'Invoke-DotbotProgress'
        'Write-Grid'
        'Invoke-PhosphorScript'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
