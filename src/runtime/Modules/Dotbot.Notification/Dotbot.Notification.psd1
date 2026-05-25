@{
    RootModule        = 'Dotbot.Notification.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '0bc6311f-9cce-4a8d-a5d5-8767969f4692'
    Author            = 'dotbot contributors'
    Description       = 'Runtime client for DotbotServer task notifications and responses.'
    PowerShellVersion = '7.0'

    ScriptsToProcess  = @(
        'Private/Imports.ps1'
    )

    FunctionsToExport = @(
        'Get-NotificationSettings'
        'Test-NotificationServer'
        'Send-TaskNotification'
        'Send-SplitProposalNotification'
        'Get-TaskNotificationResponse'
        'Resolve-NotificationAnswer'
        'Send-AttachmentUpload'
        'Remove-Attachment'
        'Invoke-AttachmentBatchUpload'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
