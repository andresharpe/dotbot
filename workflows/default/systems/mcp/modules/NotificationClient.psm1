<#
.SYNOPSIS
Client module for DotbotServer external notifications (Teams, Email, Jira).

.DESCRIPTION
Provides functions to send task questions to DotbotServer and poll for responses.
All functions are no-op when notifications are disabled or the server is unreachable.
Used by task-mark-needs-input to dispatch notifications and by NotificationPoller
to collect external responses.
#>

function Get-NotificationSettings {
    <#
    .SYNOPSIS
    Reads the notifications section from merged dotbot settings.

    .PARAMETER BotRoot
    The .bot root directory. Defaults to $global:DotbotProjectRoot/.bot.

    .OUTPUTS
    PSCustomObject with enabled, server_url, api_key, channel, recipients, project_name,
    project_description, poll_interval_seconds. Returns disabled defaults if not configured.
    #>
    param(
        [string]$BotRoot
    )

    if (-not $BotRoot) {
        $BotRoot = Join-Path $global:DotbotProjectRoot ".bot"
    }

    $defaults = @{
        enabled                = $false
        server_url             = ""
        api_key                = ""
        channel                = "teams"
        recipients             = @()
        project_name           = ""
        project_description    = ""
        poll_interval_seconds  = 30
        sync_tasks             = $true
        sync_questions         = $true
        instance_id            = ""
    }

    # Read settings.default.json
    $defaultsFile = Join-Path $BotRoot "defaults\settings.default.json"
    $overridesFile = Join-Path $BotRoot ".control\settings.json"

    $merged = @{}
    foreach ($key in $defaults.Keys) { $merged[$key] = $defaults[$key] }

    # Layer: checked-in defaults
    if (Test-Path $defaultsFile) {
        try {
            $settingsJson = Get-Content -Path $defaultsFile -Raw | ConvertFrom-Json
            if ($settingsJson.PSObject.Properties['instance_id'] -and $settingsJson.instance_id) {
                $merged.instance_id = "$($settingsJson.instance_id)"
            }
            # Read from 'mothership' key (with 'notifications' fallback for migration)
            $sectionKey = if ($settingsJson.PSObject.Properties['mothership']) { 'mothership' }
                          elseif ($settingsJson.PSObject.Properties['notifications']) { 'notifications' }
                          else { $null }
            if ($sectionKey) {
                $notif = $settingsJson.$sectionKey
                foreach ($prop in $notif.PSObject.Properties) {
                    if ($merged.ContainsKey($prop.Name)) {
                        $merged[$prop.Name] = $prop.Value
                    }
                }
            }
        } catch { Write-Verbose "Settings operation failed: $_" }
    }

    # Layer: user overrides (gitignored)
    if (Test-Path $overridesFile) {
        try {
            $overrides = Get-Content -Path $overridesFile -Raw | ConvertFrom-Json
            if ($overrides.PSObject.Properties['instance_id'] -and $overrides.instance_id) {
                $merged.instance_id = "$($overrides.instance_id)"
            }
            # Read from 'mothership' key (with 'notifications' fallback for migration)
            $sectionKey = if ($overrides.PSObject.Properties['mothership']) { 'mothership' }
                          elseif ($overrides.PSObject.Properties['notifications']) { 'notifications' }
                          else { $null }
            if ($sectionKey) {
                $notif = $overrides.$sectionKey
                foreach ($prop in $notif.PSObject.Properties) {
                    if ($merged.ContainsKey($prop.Name)) {
                        $merged[$prop.Name] = $prop.Value
                    }
                }
            }
        } catch { Write-Verbose "Non-critical operation failed: $_" }
    }

    return [PSCustomObject]$merged
}

function Test-NotificationServer {
    <#
    .SYNOPSIS
    Returns $true if the DotbotServer is reachable.

    .PARAMETER Settings
    Notification settings from Get-NotificationSettings. If not provided, reads from config.
    #>
    param(
        [object]$Settings
    )

    if (-not $Settings) {
        $Settings = Get-NotificationSettings
    }

    if (-not $Settings.server_url) { return $false }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $healthUrl = "$baseUrl/api/health"

    try {
        $response = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Send-TaskNotification {
    <#
    .SYNOPSIS
    Sends a task's pending_question to DotbotServer via the two-step API
    (POST /api/templates + POST /api/instances).

    .PARAMETER TaskContent
    The task PSCustomObject containing id, name, pending_question, etc.

    .PARAMETER PendingQuestion
    The pending_question object from the task. Contains id, question, context,
    options (key/label/rationale), recommendation.

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from config.

    .OUTPUTS
    Hashtable: @{ success; question_id; instance_id; channel }
    Returns @{ success = $false } on any failure.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [object]$PendingQuestion,

        [object]$Settings
    )

    if (-not $Settings) {
        $Settings = Get-NotificationSettings
    }

    if (-not $Settings.enabled -or -not $Settings.server_url -or -not $Settings.api_key) {
        return @{ success = $false; reason = "Notifications not configured" }
    }

    $recipients = @($Settings.recipients)
    if ($recipients.Count -eq 0) {
        return @{ success = $false; reason = "No recipients configured" }
    }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $headers = @{ "X-Api-Key" = $Settings.api_key }

    # Prefer stable workspace GUID as project ID; fallback to legacy slug
    $projectName = if ($Settings.project_name) { $Settings.project_name } else { "dotbot" }
    $projectDesc = if ($Settings.project_description) { $Settings.project_description } else { "" }
    $projectId = $null
    if ($Settings.PSObject.Properties['instance_id'] -and $Settings.instance_id) {
        $parsedProjectGuid = [guid]::Empty
        if ([guid]::TryParse("$($Settings.instance_id)", [ref]$parsedProjectGuid)) {
            $projectId = $parsedProjectGuid.ToString()
        }
    }
    if (-not $projectId) {
        $projectId = ($projectName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    }

    # Use stable question ID derived as a deterministic GUID from task-id + question-id
    # This behaves like a UUIDv5-style name-based GUID, ensuring stability across retries.
    $compositeQuestionKey = "$($TaskContent.id)-$($PendingQuestion.id)"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($compositeQuestionKey)
    $sha1  = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($bytes)
    } finally {
        $sha1.Dispose()
    }
    $guidBytes = New-Object 'System.Byte[]' 16
    [Array]::Copy($hash, $guidBytes, 16)
    # Set version 5 (0101) in the high 4 bits of byte 6
    $guidBytes[6] = ($guidBytes[6] -band 0x0F) -bor 0x50
    # Set RFC 4122 variant (10xx) in the high bits of byte 8
    $guidBytes[8] = ($guidBytes[8] -band 0x3F) -bor 0x80
    $questionId = ([System.Guid]::new([byte[]]$guidBytes)).ToString()

    # ── Step 1: Publish template ──────────────────────────────────────────
    $templateOptions = @(foreach ($opt in $PendingQuestion.options) {
        @{
            optionId      = [guid]::NewGuid().ToString()
            key           = "$($opt.key)"
            title         = "$($opt.label)"
            summary       = if ($opt.rationale) { "$($opt.rationale)" } else { $null }
            isRecommended = ("$($opt.key)" -eq $PendingQuestion.recommendation)
        }
    })

    $template = @{
        questionId       = $questionId
        version          = 1
        title            = $PendingQuestion.question
        context          = if ($PendingQuestion.context) { $PendingQuestion.context } else { $null }
        options          = $templateOptions
        responseSettings = @{ allowFreeText = $true }
        project          = @{
            projectId   = $projectId
            name        = $projectName
            description = $projectDesc
        }
    }

    try {
        $templateJson = $template | ConvertTo-Json -Depth 5
        $null = Invoke-RestMethod -Uri "$baseUrl/api/templates" -Method Post `
            -Body $templateJson -ContentType 'application/json' -Headers $headers -TimeoutSec 15
    } catch {
        return @{ success = $false; reason = "Template publish failed: $($_.Exception.Message)" }
    }

    # ── Step 2: Create instance ───────────────────────────────────────────
    $instanceId = [guid]::NewGuid().ToString()
    $channel = if ($Settings.channel) { $Settings.channel } else { "teams" }

    $recipientEmails = @($recipients | Where-Object { $_ -match '@' })
    $recipientIds = @($recipients | Where-Object { $_ -notmatch '@' })

    $instanceReq = @{
        instanceId      = $instanceId
        projectId       = $projectId
        questionId      = $questionId
        questionVersion = 1
        channel         = $channel
        recipients      = @{}
    }

    if ($recipientEmails.Count -gt 0) {
        $instanceReq.recipients.emails = $recipientEmails
    }
    if ($recipientIds.Count -gt 0) {
        if ($channel -eq "slack") {
            $instanceReq.recipients.slackUserIds = $recipientIds
        } else {
            $instanceReq.recipients.userObjectIds = $recipientIds
        }
    }

    try {
        $instanceJson = $instanceReq | ConvertTo-Json -Depth 5
        $null = Invoke-RestMethod -Uri "$baseUrl/api/instances" -Method Post `
            -Body $instanceJson -ContentType 'application/json' -Headers $headers -TimeoutSec 15
    } catch {
        return @{ success = $false; reason = "Instance creation failed: $($_.Exception.Message)" }
    }

    return @{
        success     = $true
        question_id = $questionId
        instance_id = $instanceId
        channel     = $channel
        project_id  = $projectId
    }
}

function Get-TaskNotificationResponse {
    <#
    .SYNOPSIS
    Polls DotbotServer for a response to a previously sent notification.

    .PARAMETER Notification
    The notification metadata stored on the task (question_id, instance_id, etc.)

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from config.

    .OUTPUTS
    Response object with selectedKey, freeText, etc. or $null if no response yet.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Notification,

        [object]$Settings
    )

    if (-not $Settings) {
        $Settings = Get-NotificationSettings
    }

    if (-not $Settings.enabled -or -not $Settings.server_url -or -not $Settings.api_key) {
        return $null
    }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $headers = @{ "X-Api-Key" = $Settings.api_key }

    $projectId = $Notification.project_id
    if (-not $projectId) {
        # Prefer settings.instance_id for backward-compatible polling fallback
        if ($Settings.PSObject.Properties['instance_id'] -and $Settings.instance_id) {
            $parsedProjectGuid = [guid]::Empty
            if ([guid]::TryParse("$($Settings.instance_id)", [ref]$parsedProjectGuid)) {
                $projectId = $parsedProjectGuid.ToString()
            }
        }
        if (-not $projectId) {
            $projectName = if ($Settings.project_name) { $Settings.project_name } else { "dotbot" }
            $projectId = ($projectName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        }
    }

    $questionId = $Notification.question_id
    $instanceId = $Notification.instance_id

    $responsesUrl = "$baseUrl/api/instances/$projectId/$questionId/$instanceId/responses"

    try {
        $responses = Invoke-RestMethod -Uri $responsesUrl -Method Get -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        if ($responses -and @($responses).Count -gt 0) {
            return @($responses)[0]
        }
    } catch {
        # 404 means no responses yet; other errors are transient
    }

    return $null
}

Export-ModuleMember -Function @(
    'Get-NotificationSettings'
    'Test-NotificationServer'
    'Send-TaskNotification'
    'Get-TaskNotificationResponse'
)
