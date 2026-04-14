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
    $defaultsFile = Join-Path $BotRoot "settings\settings.default.json"
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
        } catch { Write-BotLog -Level Debug -Message "Settings operation failed" -Exception $_ }
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
        } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
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
        $null = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Send-ServerNotification {
    <#
    .SYNOPSIS
    Shared plumbing for sending notifications to DotbotServer via the two-step
    API (POST /api/templates + POST /api/instances).

    .DESCRIPTION
    Private helper — not exported. Handles settings validation, project ID
    resolution, deterministic GUID generation, template publishing, and
    instance creation.  Callers supply the composite key (for idempotency)
    and a pre-built template body.

    .PARAMETER CompositeKey
    A string used to derive a deterministic UUIDv5-style question ID
    (e.g. "<task-id>-<question-id>" or "<task-id>-split").

    .PARAMETER Template
    Hashtable with the card-specific fields: title, context, options,
    responseSettings.  This function adds questionId, version, and project.

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from config.

    .OUTPUTS
    Hashtable: @{ success; question_id; instance_id; channel; project_id }
    Returns @{ success = $false; reason = "..." } on any failure.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CompositeKey,

        [Parameter(Mandatory)]
        [hashtable]$Template,

        [object]$Settings
    )

    # Shallow clone to avoid mutating the caller's hashtable (reference type).
    # Only top-level keys (questionId, version, project) are added below, so
    # shallow is sufficient — nested values (options, responseSettings) are not mutated.
    $Template = $Template.Clone()

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

    # Deterministic UUIDv5-style GUID from composite key for idempotent retries
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($CompositeKey)
    $sha1  = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($bytes)
    } finally {
        $sha1.Dispose()
    }
    $guidBytes = New-Object 'System.Byte[]' 16
    [Array]::Copy($hash, $guidBytes, 16)
    $guidBytes[6] = ($guidBytes[6] -band 0x0F) -bor 0x50   # version 5
    $guidBytes[8] = ($guidBytes[8] -band 0x3F) -bor 0x80   # RFC 4122 variant
    $questionId = ([System.Guid]::new([byte[]]$guidBytes)).ToString()

    # ── Step 1: Publish template ──────────────────────────────────────────
    $Template['questionId'] = $questionId
    $Template['version']    = 1
    $Template['project']    = @{
        projectId   = $projectId
        name        = $projectName
        description = $projectDesc
    }

    try {
        $templateJson = $Template | ConvertTo-Json -Depth 20
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
        $instanceJson = $instanceReq | ConvertTo-Json -Depth 20
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

function Send-TaskNotification {
    <#
    .SYNOPSIS
    Sends a task's pending_question to DotbotServer as an Adaptive Card.

    .PARAMETER TaskContent
    The task PSCustomObject containing id, name, pending_question, etc.

    .PARAMETER PendingQuestion
    The pending_question object from the task. Contains id, question, context,
    options (key/label/rationale), recommendation.

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from config.

    .OUTPUTS
    Hashtable. On success: @{ success = $true; question_id; instance_id; channel; project_id }.
    On failure: @{ success = $false; reason = "..." } (reason is supplied by Send-ServerNotification).
    #>
    param(
        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [object]$PendingQuestion,

        [object]$Settings
    )

    $compositeKey = "$($TaskContent.id)-$($PendingQuestion.id)"

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
        title            = $PendingQuestion.question
        context          = if ($PendingQuestion.context) { $PendingQuestion.context } else { $null }
        options          = $templateOptions
        responseSettings = @{ allowFreeText = $true }
    }

    return Send-ServerNotification -CompositeKey $compositeKey -Template $template -Settings $Settings
}

function Send-SplitProposalNotification {
    <#
    .SYNOPSIS
    Sends a task's split_proposal to DotbotServer as an Adaptive Card with
    Approve / Reject options and sub-task details.

    .PARAMETER TaskContent
    The task PSCustomObject containing id, name, split_proposal, etc.

    .PARAMETER SplitProposal
    The split_proposal object from the task. Contains reason, sub_tasks
    (each with name, description, effort), proposed_at.

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from config.

    .OUTPUTS
    Hashtable. On success: @{ success = $true; question_id; instance_id; channel; project_id }.
    On failure: @{ success = $false; reason = "..." }.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [object]$SplitProposal,

        [object]$Settings
    )

    if (-not $SplitProposal.proposed_at) {
        return @{ success = $false; reason = "Split proposal missing proposed_at" }
    }

    # Use proposed_at in the composite key: it's stable for the lifetime of a
    # proposal (set once at creation, reused on notification retries), and new
    # proposals after rejection get a fresh timestamp — producing a new GUID.
    $compositeKey = "$($TaskContent.id)-split-$($SplitProposal.proposed_at)"

    if (-not $SplitProposal.sub_tasks -or @($SplitProposal.sub_tasks).Count -eq 0) {
        return @{ success = $false; reason = "Split proposal has no sub-tasks" }
    }

    # Build context body: reason + numbered sub-task list
    $subTaskLines = @()
    $index = 1
    foreach ($st in $SplitProposal.sub_tasks) {
        $effort = if ($st.effort) { " [$($st.effort)]" } else { "" }
        $desc   = if ($st.description) { " — $($st.description)" } else { "" }
        $subTaskLines += "$index. $($st.name)$effort$desc"
        $index++
    }
    $contextBody = "Reason: $($SplitProposal.reason)`n`nProposed sub-tasks:`n$($subTaskLines -join "`n")"

    $template = @{
        title            = "Split proposal for task: $($TaskContent.name)"
        context          = $contextBody
        options          = @(
            @{
                optionId      = [guid]::NewGuid().ToString()
                key           = "approve"
                title         = "Approve"
                summary       = "Accept the split and create the proposed sub-tasks"
                isRecommended = $true
            },
            @{
                optionId      = [guid]::NewGuid().ToString()
                key           = "reject"
                title         = "Reject"
                summary       = "Reject the split and return the task to analysis"
                isRecommended = $false
            }
        )
        # Split proposal is an explicit Approve/Reject binary choice — free-text
        # replies have no mapping in the poller and would leave the task stuck
        # in needs-input with the poller repeatedly re-fetching the same response.
        responseSettings = @{ allowFreeText = $false }
    }

    return Send-ServerNotification -CompositeKey $compositeKey -Template $template -Settings $Settings
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

function Resolve-NotificationAnswer {
    <#
    .SYNOPSIS
    Extracts the answer text from a Teams response and downloads any attached files.

    .PARAMETER Response
    The response object returned by Get-TaskNotificationResponse.

    .PARAMETER Settings
    Notification settings (needs server_url, api_key).

    .PARAMETER AttachDir
    Local directory to save attachment files into (created if needed).

    .OUTPUTS
    Hashtable with keys:
      answer      - resolved answer string (with paths appended if attachments present)
      attachments - array of @{ name, size, path } metadata (empty array if none)
    Returns $null if no valid answer found in the response.
    #>
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string]$AttachDir
    )

    $answer = if ($Response.selectedKey) { $Response.selectedKey }
              elseif ($Response.freeText)  { $Response.freeText }
              else                         { $null }

    $hasAttachments = $Response.attachments -and @($Response.attachments).Count -gt 0
    if (-not $answer -and -not $hasAttachments) { return $null }
    if (-not $answer) { $answer = '' }  # attachments-only — paths will be appended below

    $attachmentMeta = @()

    if ($Response.attachments -and @($Response.attachments).Count -gt 0) {
        if (-not (Test-Path $AttachDir)) {
            New-Item -ItemType Directory -Force -Path $AttachDir | Out-Null
        }

        foreach ($att in @($Response.attachments)) {
            try {
                # URL-encode the blob path to handle spaces and special chars in filenames
                $encodedPath = [System.Uri]::EscapeUriString("$($Settings.server_url.TrimEnd('/'))/api/attachments/$($att.blobPath)")
                $headers = @{ 'X-Api-Key' = $Settings.api_key }
                $localPath = Join-Path $AttachDir $att.name
                Invoke-RestMethod -Uri $encodedPath -Method Get -Headers $headers `
                    -OutFile $localPath -TimeoutSec 30 -ErrorAction Stop

                # Build a relative path using the last two directory segments for portability
                $relPath = ($localPath -replace '\\', '/') -replace '^.*?/workspace/', '.bot/workspace/'
                $attachmentMeta += @{ name = $att.name; size = $att.sizeBytes; path = $relPath }
            } catch {
                Write-BotLog -Level Warn -Message "Attachment download failed: $($att.name)" -Exception $_
            }
        }

        if ($attachmentMeta.Count -gt 0) {
            $pathList = ($attachmentMeta | ForEach-Object { $_.path }) -join ', '
            $answer = if ($answer) { "$answer`nAttached: $pathList" } else { "Attached: $pathList" }
        } elseif (-not $answer) {
            # Attachments were present but all downloads failed — still acknowledge them
            $answer = "(attachment provided but could not be downloaded)"
        }
    }

    return @{
        answer      = $answer
        attachments = $attachmentMeta
    }
}

Export-ModuleMember -Function @(
    'Get-NotificationSettings'
    'Test-NotificationServer'
    'Send-TaskNotification'
    'Send-SplitProposalNotification'
    'Get-TaskNotificationResponse'
    'Resolve-NotificationAnswer'
)
