<#
.SYNOPSIS
Client module for DotbotServer external notifications (Teams, Email, Jira).

.DESCRIPTION
Provides functions to send task questions to DotbotServer and poll for responses.
All functions are no-op when notifications are disabled or the server is unreachable.
Used by task-mark-needs-input to dispatch notifications and by NotificationPoller
to collect external responses.

Required manifest dependencies: Dotbot.Core, Dotbot.Settings.
#>

# SPEC-029 envelope helpers (build + read) live in a dedicated script:
# New-NotificationEnvelope (build), ConvertFrom-NotificationEnvelope (split into
# sections), Get-NotificationEnvelopeAnswer (answer projection). The UI poller
# consumes the read helpers via this module.
. (Join-Path $PSScriptRoot 'Private/Envelope.ps1')

function Get-NotificationSettings {
    <#
    .SYNOPSIS
    Reads the notifications section from merged dotbot settings.

    .PARAMETER BotRoot
    The .bot root directory. Defaults to $global:DotbotProjectRoot/.bot.

    .OUTPUTS
    PSCustomObject with enabled, server_url, api_key, channel, recipients, project_name,
    project_description, poll_interval_seconds, and the workspace instance_id.
    #>
    param(
        [string]$BotRoot
    )

    if (-not $BotRoot) {
        $BotRoot = Get-DotbotProjectBotPath
    }

    $result = @{
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
        jira_issue_key         = ""
    }

    $merged = Get-MergedSettings -BotRoot $BotRoot

    if ($merged.PSObject.Properties['instance_id'] -and $merged.instance_id) {
        $result.instance_id = "$($merged.instance_id)"
    }

    $sectionKey = if ($merged.PSObject.Properties['mothership']) { 'mothership' }
                  elseif ($merged.PSObject.Properties['notifications']) { 'notifications' }
                  else { $null }
    if ($sectionKey) {
        $notif = $merged.$sectionKey
        foreach ($prop in $notif.PSObject.Properties) {
            if ($result.ContainsKey($prop.Name)) {
                $result[$prop.Name] = $prop.Value
            }
        }
    }

    return [PSCustomObject]$result
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

        [object]$Settings,

        # Originating outpost task short id - carried on the envelope (SPEC-029).
        [string]$TaskId
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
        $projectId = ($projectName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
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
        # SPEC-029: template publish body is { envelope, question }. The question block
        # is the QuestionTemplate JSON itself (stored verbatim by the server).
        $templateEnvelope = New-NotificationEnvelope -Settings $Settings -ProjectId $projectId -TaskId $TaskId
        $templateBody = @{ envelope = $templateEnvelope; question = $Template }
        $templateJson = $templateBody | ConvertTo-Json -Depth 20
        $null = Invoke-RestMethod -Uri "$baseUrl/api/templates" -Method Post `
            -Body $templateJson -ContentType 'application/json' -Headers $headers -TimeoutSec 15
    } catch {
        return @{ success = $false; reason = "Template publish failed: $($_.Exception.Message)" }
    }

    # ── Step 2: Create instance ───────────────────────────────────────────
    $InstanceId = [guid]::NewGuid().ToString()
    $channel = if ($Settings.channel) { $Settings.channel } else { "teams" }

    $recipientEmails = @($recipients | Where-Object { $_ -match '@' })
    $recipientIds = @($recipients | Where-Object { $_ -notmatch '@' })

    # SPEC-029: recipients is an array of { email|aadObjectId|slackUserId, channel }.
    $recipientsArray = @()
    foreach ($email in $recipientEmails) {
        $recipientsArray += @{ email = "$email"; channel = $channel }
    }
    foreach ($id in $recipientIds) {
        if ($channel -eq "slack") {
            $recipientsArray += @{ slackUserId = "$id"; channel = $channel }
        } else {
            $recipientsArray += @{ aadObjectId = "$id"; channel = $channel }
        }
    }

    # Instance body is { envelope, question: { questionId, version }, recipients }.
    # jiraIssueKey (when delivering on the jira channel) rides on the envelope as
    # routing metadata.
    $jiraKey = if ($channel -eq "jira" -and $Settings.jira_issue_key) { "$($Settings.jira_issue_key)" } else { $null }
    $instanceEnvelope = New-NotificationEnvelope -Settings $Settings -ProjectId $projectId `
        -TaskId $TaskId -QuestionInstanceId $InstanceId -JiraIssueKey $jiraKey
    $instanceReq = @{
        envelope   = $instanceEnvelope
        question   = @{ questionId = $questionId; version = 1 }
        recipients = $recipientsArray
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
        instance_id = $InstanceId
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

    .PARAMETER Type
    PRD Section 4.6 question type — singleChoice (default) | approval | freeText
    | priorityRanking. Drives card rendering and response parsing.

    .PARAMETER DeliverableSummary
    Optional 1-3 line summary shown in channel notifications (PRD Section 5.2).

    .PARAMETER Attachments
    Optional array of pre-uploaded attachment metadata returned by
    Invoke-AttachmentBatchUpload (@{ name; description; attachment_id;
    storage_ref; size_bytes }). Emitted on the template payload as
    `attachments[*] = { attachmentId, blobPath = storage_ref, name, sizeBytes }`
    matching server `QuestionAttachment` (Models/QuestionAttachment.cs).
    `storageRef`/`description` are client-side keys and not part of the wire shape.

    .PARAMETER ReviewLinks
    Optional array of @{ title; url; type } for reviewer context. Emitted on
    the template payload as `referenceLinks[*] = { label, url }` matching server
    `ReferenceLink` (Models/ReferenceLink.cs). `title` -> `label`; `type` has no
    server counterpart and is dropped at the wire boundary.

    .OUTPUTS
    Hashtable. On success: @{ success = $true; question_id; instance_id; channel; project_id }.
    On failure: @{ success = $false; reason = "..." } (reason is supplied by Send-ServerNotification).
    #>
    param(
        [Parameter(Mandatory)]
        [object]$TaskContent,

        [Parameter(Mandatory)]
        [object]$PendingQuestion,

        [object]$Settings,

        [string]$Type = 'singleChoice',

        [string]$DeliverableSummary,

        [object[]]$Attachments,

        [object[]]$ReviewLinks
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
        type             = $Type
    }

    if ($DeliverableSummary) {
        $template['deliverableSummary'] = $DeliverableSummary
    }

    if ($Attachments -and @($Attachments).Count -gt 0) {
        # Wire shape matches server QuestionAttachment (Models/QuestionAttachment.cs):
        # required attachmentId + name, exactly one of url/blobPath (we emit blobPath = storageRef).
        # storage_ref/description are client-side keys; not part of the server schema.
        $template['attachments'] = @(foreach ($att in @($Attachments)) {
            $aid  = if ($att -is [hashtable]) { $att['attachment_id'] } else { $att.attachment_id }
            $ref  = if ($att -is [hashtable]) { $att['storage_ref']   } else { $att.storage_ref }
            $name = if ($att -is [hashtable]) { $att['name'] }          else { $att.name }
            $size = if ($att -is [hashtable]) { $att['size_bytes'] }    else { $att.size_bytes }
            @{
                attachmentId = "$aid"
                name         = "$name"
                blobPath     = "$ref"
                sizeBytes    = [int64]$size
            }
        })
    }

    if ($ReviewLinks -and @($ReviewLinks).Count -gt 0) {
        # Wire shape matches server ReferenceLink (Models/ReferenceLink.cs): { label, url }.
        # MCP input still uses review_links/{title,url,type} per PRD Section 4.6; type has no server
        # counterpart and is dropped at this wire boundary.
        # Filter to safe HTTP/HTTPS URLs only — mirrors server IsSafeHttpsUrl validation and
        # prevents SSRF via attacker-controlled task metadata reaching internal endpoints.
        $safeLinks = @(foreach ($link in @($ReviewLinks)) {
            $title = if ($link -is [hashtable]) { $link['title'] } else { $link.title }
            $url   = if ($link -is [hashtable]) { $link['url']   } else { $link.url   }
            if ("$url" -match '^https?://' -and "$url" -notmatch '[<>"''\\]') {
                @{ label = "$title"; url = "$url" }
            }
        })
        if ($safeLinks.Count -gt 0) {
            $template['referenceLinks'] = $safeLinks
        }
    }

    return Send-ServerNotification -CompositeKey $compositeKey -Template $template -Settings $Settings -TaskId "$($TaskContent.id)"
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

    return Send-ServerNotification -CompositeKey $compositeKey -Template $template -Settings $Settings -TaskId "$($TaskContent.id)"
}

function Send-ReviewNotification {
    <#
    .SYNOPSIS
    Notifies reviewers that a task has entered needs-review, via the existing
    server-mediated channel (Teams / Slack / Jira).

    .DESCRIPTION
    needs-review has no natural pending_question, so this synthesizes an
    informational `freeText` payload — mirroring how the interview path builds a
    fake pending question (Dotbot.Task.psm1). Delivery flows through
    Send-TaskNotification -> Send-ServerNotification, so all existing gates
    apply: no-op when notifications are disabled, unconfigured, or the server is
    unreachable.

    Note on type — informational, NOT a decision card. The card deliberately does
    NOT render Approve / Reject buttons. There is no dotbot-side consumer that
    pulls a reviewer's in-channel decision back for a needs-review task: the
    NotificationPoller only scans the needs-input directory (NotificationPoller.psm1),
    so an Approve / Reject click would be recorded server-side but never act on the
    task — leaving it silently stuck in needs-review. Presenting decision buttons
    would therefore promise an action the system cannot fulfil. Instead this is a
    "your review is waiting — open the dashboard to act" signal; the reviewer
    performs the real approve/reject in the dotbot UI (task_submit_review).

    Type is `freeText` (the server's QuestionTypes.AllowedTypes is { singleChoice,
    approval, freeText, priorityRanking }; `documentReview` from the issue draft is
    not allowed and `approval` would render the misleading decision buttons).
    `freeText` is the only type that carries empty options, so the card shows the
    task details + review link with at most an optional comment box — no decision UI.

    .PARAMETER TaskContent
    The task object (id, name, extensions.review). id/name identify the task on
    the card; extensions.review.requested_at stabilises the idempotency key so a
    retry of the same request collapses to one card while a fresh request after a
    reject (new requested_at) produces a new card.

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from config.

    .PARAMETER Reason
    Optional review-request reason. Used as the deliverable summary when no
    explicit summary is supplied, and surfaced in the card context.

    .PARAMETER Actor
    Optional submitting party (actor) shown in the card context.

    .PARAMETER ReviewLinks
    Optional array of @{ title; url } reference links to the review action.

    .PARAMETER DeliverableSummary
    Optional 1-3 line summary; defaults to Reason when omitted.

    .OUTPUTS
    Hashtable. On success: @{ success = $true; question_id; instance_id; channel; project_id }.
    On failure / disabled: @{ success = $false; reason = "..." }.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$TaskContent,

        [object]$Settings,

        [string]$Reason,

        [string]$Actor,

        [object[]]$ReviewLinks,

        [string]$DeliverableSummary
    )

    # Stabilise the idempotency key on the review-request timestamp (carried on
    # extensions.review.requested_at). Falls back to a constant suffix when the
    # review extension carries no timestamp.
    $stamp = $null
    if ($TaskContent.PSObject.Properties['extensions'] -and $TaskContent.extensions) {
        $ext = $TaskContent.extensions
        if ($ext.PSObject.Properties['review'] -and $ext.review -and
            $ext.review.PSObject.Properties['requested_at'] -and $ext.review.requested_at) {
            $stamp = "$($ext.review.requested_at)"
        }
    }
    if (-not $stamp) { $stamp = 'pending' }

    $taskName = if ($TaskContent.PSObject.Properties['name'] -and $TaskContent.name) {
        "$($TaskContent.name)"
    } else {
        "$($TaskContent.id)"
    }

    $contextLines = @("Task '$taskName' (id $($TaskContent.id)) is ready for review.")
    if ($Actor)  { $contextLines += "Submitted by: $Actor" }
    if ($Reason) { $contextLines += "Reason: $Reason" }
    # Make the call-to-action explicit: this is a heads-up, the real review
    # happens in the dotbot dashboard (no in-channel decision is consumed).
    $contextLines += "Open the dotbot dashboard to review and approve or reject this task."

    # Informational card: NO options. freeText carries an empty options array
    # server-side, so the reviewer sees the task details + review link without
    # any Approve / Reject buttons (which would have no dotbot-side consumer for
    # a needs-review task — see the function description).
    $pendingQ = @{
        id       = "review-$stamp"
        question = "Task '$taskName' is ready for review"
        context  = ($contextLines -join "`n")
        options  = @()
    }

    $summary = if ($DeliverableSummary) { $DeliverableSummary }
               elseif ($Reason)         { $Reason }
               else                     { $null }

    $sendArgs = @{
        TaskContent     = $TaskContent
        PendingQuestion = $pendingQ
        Type            = 'freeText'
        Settings        = $Settings
    }
    if ($summary) { $sendArgs['DeliverableSummary'] = $summary }
    if ($ReviewLinks -and @($ReviewLinks).Count -gt 0) { $sendArgs['ReviewLinks'] = $ReviewLinks }

    return Send-TaskNotification @sendArgs
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
            $projectId = ($projectName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        }
    }

    $questionId = $Notification.question_id
    $InstanceId = $Notification.instance_id

    $responsesUrl = "$baseUrl/api/instances/$projectId/$questionId/$InstanceId/responses"

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
    Extracts the answer text from a server response, downloads any attached files,
    and surfaces type-specific fields (comment, ranked_items, reviewed_attachment_ids)
    so the runtime can persist them on the resolved questions_resolved entry.

    .PARAMETER Response
    The response object returned by Get-TaskNotificationResponse. Mirrors the
    server-side ResponseRecordV2 shape (selectedKey, freeText, approvalDecision,
    comment, rankedItems, reviewedAttachmentIds, attachments).

    .PARAMETER Settings
    Notification settings (needs server_url, api_key).

    .PARAMETER AttachDir
    Local directory to save attachment files into (created if needed).

    .OUTPUTS
    Hashtable with keys (only the type-specific keys are present when relevant):
      answer                  - resolved answer string (with paths appended if attachments present).
                                For approval, this is the decision value ("approved" / "rejected").
      attachments             - array of @{ name, size, path } metadata (empty array if none)
      comment                 - optional reviewer comment (approval responses)
      ranked_items            - optional array of ranked items (priorityRanking responses)
      reviewed_attachment_ids - optional array of attachment ids the reviewer ticked
                                (approval with attached documents)
    Returns $null if no valid answer found in the response.
    #>
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string]$AttachDir
    )

    # SPEC-029 enveloped response. The pure parse (type + answer fields) is shared
    # with the UI poller via Get-NotificationEnvelopeAnswer (Private/Envelope.ps1).
    $parsed = Get-NotificationEnvelopeAnswer -Response $Response

    $answer = $parsed.answerString
    $responseAttachments = $parsed.attachments
    $hasAttachments = @($responseAttachments).Count -gt 0
    if (-not $answer -and -not $hasAttachments) { return $null }
    if (-not $answer) { $answer = '' }  # attachments-only — paths appended below

    $attachmentMeta = @()

    if ($hasAttachments) {
        if (-not (Test-Path $AttachDir)) {
            New-Item -ItemType Directory -Force -Path $AttachDir | Out-Null
        }

        foreach ($att in @($responseAttachments)) {
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

    $result = @{
        answer      = $answer
        attachments = $attachmentMeta
    }

    # Surface type-specific fields from the parsed answer so the runtime can write
    # them onto the resolved questions_resolved entry. Each is passed through only when
    # the server actually populated it; the local resolver at the runtime layer decides
    # which fields make sense for the question type.
    if ($parsed.comment) {
        $result['comment'] = "$($parsed.comment)"
    }
    if (@($parsed.rankedItems).Count -gt 0) {
        $result['ranked_items'] = @($parsed.rankedItems)
    }
    if (@($parsed.reviewedAttachmentIds).Count -gt 0) {
        $result['reviewed_attachment_ids'] = @($parsed.reviewedAttachmentIds)
    }

    return $result
}

function Send-AttachmentUpload {
    <#
    .SYNOPSIS
    Uploads a single file to DotbotServer via POST /api/attachments (multipart/form-data).

    .OUTPUTS
    Hashtable on success: @{ success; attachment_id; storage_ref; size_bytes; name; description }.
    attachment_id is the Guid returned by POST /api/attachments and is required
    by the template wire shape (server QuestionAttachment).
    On failure: @{ success = $false; reason }.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [string]$FilePath,

        [string]$Description = ""
    )

    if (-not $Settings.server_url -or -not $Settings.api_key) {
        return @{ success = $false; reason = "Notifications not configured" }
    }

    # Path-traversal guard: MCP tools are driven by untrusted LLM input. Reject
    # any FilePath that resolves outside the project root to prevent exfiltration
    # of arbitrary host files. Fail closed — no DotbotProjectRoot means no upload.
    # Check authorization BEFORE file existence to avoid leaking whether a path exists.
    if (-not (Test-Path Variable:global:DotbotProjectRoot) -or -not $global:DotbotProjectRoot) {
        return @{ success = $false; reason = "Upload rejected: DotbotProjectRoot not set" }
    }

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return @{ success = $false; reason = "File not found: $FilePath" }
    }
    try {
        $resolvedFile = [System.IO.Path]::GetFullPath($FilePath)
        $resolvedRoot = [System.IO.Path]::GetFullPath("$($global:DotbotProjectRoot)").TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        # Windows is case-insensitive; Linux/macOS (including case-sensitive APFS) require Ordinal.
        $pathCmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not $resolvedFile.StartsWith($resolvedRoot, $pathCmp)) {
            return @{ success = $false; reason = "FilePath outside project root: $FilePath" }
        }
    } catch {
        return @{ success = $false; reason = "Invalid file path: $FilePath" }
    }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $headers = @{ "X-Api-Key" = $Settings.api_key }
    $uploadUrl = "$baseUrl/api/attachments"
    $fileItem = Get-Item -LiteralPath $FilePath

    try {
        $form = @{
            file        = $fileItem
            description = $Description
        }
        $resp = Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $headers `
            -Form $form -TimeoutSec 60 -ErrorAction Stop

        $storageRef = if ($resp.storageRef) { "$($resp.storageRef)" }
                      elseif ($resp.storage_ref) { "$($resp.storage_ref)" }
                      else { $null }
        if (-not $storageRef) {
            return @{ success = $false; reason = "Server response missing storageRef" }
        }
        $attachmentId = if ($resp.attachmentId) { "$($resp.attachmentId)" }
                        elseif ($resp.attachment_id) { "$($resp.attachment_id)" }
                        else { $null }
        if (-not $attachmentId) {
            return @{ success = $false; reason = "Server response missing attachmentId" }
        }
        $sizeBytes = if ($resp.sizeBytes) { [int64]$resp.sizeBytes }
                     elseif ($resp.size_bytes) { [int64]$resp.size_bytes }
                     else { [int64]$fileItem.Length }
        return @{
            success       = $true
            attachment_id = $attachmentId
            storage_ref   = $storageRef
            size_bytes    = $sizeBytes
            name          = $fileItem.Name
            description   = $Description
        }
    } catch {
        return @{ success = $false; reason = "Attachment upload failed: $($_.Exception.Message)" }
    }
}

function Remove-Attachment {
    <#
    .SYNOPSIS
    Deletes an attachment from DotbotServer via DELETE /api/attachments/{storageRef}.
    Best-effort; logs warning on failure but does not throw.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [string]$StorageRef
    )

    if (-not $Settings.server_url -or -not $Settings.api_key) { return $false }

    # Reject path-traversal sequences — `..` after segment-encoding stays literal
    # and would let a crafted storageRef escape the attachments route on the server.
    if ($StorageRef -match '(^|/)\.\.(/|$)') {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "Remove-Attachment rejected suspicious storageRef: $StorageRef"
        }
        return $false
    }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $headers = @{ "X-Api-Key" = $Settings.api_key }
    # storageRef is `{guid}/{filename}`. Server route is `{**storageRef}` catch-all and
    # expects literal `/` separators. Segment-encode (split on `/`, EscapeDataString
    # each segment, rejoin) so `/` stays literal while `#`, `?`, spaces, and other
    # reserved chars in filenames get percent-encoded — EscapeUriString alone leaves
    # `#`/`?` unencoded and would truncate the request URI.
    $encoded = ($StorageRef -split '/' | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $url = "$baseUrl/api/attachments/$encoded"

    try {
        $null = Invoke-RestMethod -Uri $url -Method Delete -Headers $headers -TimeoutSec 15 -ErrorAction Stop
        return $true
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Warn -Message "Attachment cleanup failed for $StorageRef" -Exception $_
        }
        return $false
    }
}

function Invoke-AttachmentBatchUpload {
    <#
    .SYNOPSIS
    Uploads an array of attachments sequentially. On any single failure, rolls
    back already-uploaded refs via Remove-Attachment, returns failure.

    .PARAMETER Attachments
    Array of objects/hashtables with { path; description? }.

    .OUTPUTS
    On full success: @{ success = $true; uploads = @(@{ name; description;
    attachment_id; storage_ref; size_bytes }, ...) }. attachment_id is required
    downstream by Send-TaskNotification when emitting the template wire payload
    (server QuestionAttachment requires it).
    On any failure : @{ success = $false; reason; uploaded = @(storage_refs of
    the prior successful uploads that were rolled back via Remove-Attachment) }.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [object[]]$Attachments
    )

    if (-not $Attachments -or @($Attachments).Count -eq 0) {
        return @{ success = $true; uploads = @() }
    }

    $uploaded = @()
    foreach ($att in @($Attachments)) {
        $path = if ($att -is [hashtable]) { $att['path'] } else { $att.path }
        $desc = if ($att -is [hashtable]) { $att['description'] } else { $att.description }
        if (-not $desc) { $desc = "" }

        $result = Send-AttachmentUpload -Settings $Settings -FilePath $path -Description $desc
        if (-not $result.success) {
            # Roll back prior uploads; return the refs we tried to clean up so
            # callers/tests can introspect what was reverted (matches docstring).
            $rolled = @()
            foreach ($prior in $uploaded) {
                $null = Remove-Attachment -Settings $Settings -StorageRef $prior.storage_ref
                $rolled += $prior.storage_ref
            }
            return @{
                success  = $false
                reason   = $result.reason
                uploaded = $rolled
            }
        }
        $uploaded += @{
            name          = $result.name
            description   = $result.description
            attachment_id = $result.attachment_id
            storage_ref   = $result.storage_ref
            size_bytes    = $result.size_bytes
        }
    }

    return @{ success = $true; uploads = $uploaded }
}

function Get-AllTaskNotificationResponse {
    <#
    .SYNOPSIS
    Returns all stored responses for a notification instance, sorted by SubmittedAt.
    Used by the poller to detect dual-surface disagreements and read answered_via.

    .PARAMETER Notification
    The notification metadata object from task JSON. Must have project_id, question_id,
    and instance_id properties. project_id is resolved via fallback if absent.

    .PARAMETER Settings
    Optional notification settings hashtable. If not provided, reads from Get-NotificationSettings.

    .OUTPUTS
    Array of SPEC-029 enveloped response objects ({ envelope, question, answer,
    responder }) sorted ascending by envelope.submittedAt.
    Returns @() when notifications are not configured or on any HTTP error.
    #>
    param(
        [Parameter(Mandatory)] [object]$Notification,
        [object]$Settings = $null
    )

    if (-not $Settings) { $Settings = Get-NotificationSettings }

    if (-not $Settings.enabled -or -not $Settings.server_url -or -not $Settings.api_key) {
        return @()
    }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $headers = @{ "X-Api-Key" = $Settings.api_key }

    $projectId = $Notification.project_id
    if (-not $projectId) {
        if ($Settings.PSObject.Properties['instance_id'] -and $Settings.instance_id) {
            $parsedProjectGuid = [guid]::Empty
            if ([guid]::TryParse("$($Settings.instance_id)", [ref]$parsedProjectGuid)) {
                $projectId = $parsedProjectGuid.ToString()
            }
        }
        if (-not $projectId) {
            $projectName = if ($Settings.project_name) { $Settings.project_name } else { "dotbot" }
            $projectId = ($projectName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        }
    }

    $pGuid = [guid]::Empty
    if (-not [guid]::TryParse("$projectId", [ref]$pGuid)) {
        if (-not [System.Text.RegularExpressions.Regex]::IsMatch(
                "$projectId", '^[a-z0-9][a-z0-9\-]{0,62}[a-z0-9]$')) {
            return @()
        }
    } else {
        $projectId = $pGuid.ToString()
    }

    $qGuid = [guid]::Empty
    $iGuid = [guid]::Empty
    if (-not ([guid]::TryParse("$($Notification.question_id)", [ref]$qGuid)) -or
        -not ([guid]::TryParse("$($Notification.instance_id)", [ref]$iGuid))) {
        return @()
    }

    # Server returns responses sorted ascending by SubmittedAt; index 0 is the first-by-time response.
    $url = "$baseUrl/api/instances/$projectId/$($qGuid.ToString())/$($iGuid.ToString())/responses"
    try {
        $responses = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        return @($responses)
    } catch {
        # Transient error or not yet answered — caller treats empty as unanswered
        return @()
    }
}

function Send-LocalApprovalResponse {
    <#
    .SYNOPSIS
    Pushes a locally-submitted approval decision to the Mothership via POST /api/responses.
    Uses a deterministic ResponseId so retries are idempotent (server returns 200 if already stored).

    .PARAMETER ProjectId
    The project identifier (GUID string or slug) that owns the question.

    .PARAMETER QuestionId
    The GUID string identifying the question template.

    .PARAMETER InstanceId
    The GUID string identifying the task/workflow instance.

    .PARAMETER ApprovalDecision
    The decision value: "approved" or "rejected" (the server-side ApprovalDecisions
    taxonomy was narrowed under [#445]; sending other values fails validation).

    .PARAMETER Comment
    Optional free-text comment. Required by convention when Decision = "rejected".

    .PARAMETER ResponderEmail
    Optional email of the responder. Defaults to the machine hostname for deterministic ResponseId.

    .PARAMETER QuestionVersion
    Version of the question template. Defaults to 1.

    .PARAMETER Settings
    Optional notification settings. If not provided, reads from Get-NotificationSettings.

    .OUTPUTS
    Hashtable. On success: @{ success = $true; response_id = "..."; server_result = ... }.
    On failure: @{ success = $false; reason = "..." }.
    #>
    param(
        [Parameter(Mandatory)] [string]$ProjectId,
        [Parameter(Mandatory)] [string]$QuestionId,
        [Parameter(Mandatory)] [string]$InstanceId,
        [Parameter(Mandatory)] [string]$ApprovalDecision,
        [string]$Comment          = $null,
        [string]$ResponderEmail   = $null,
        [int]$QuestionVersion     = 1,
        [string]$TaskId           = $null,
        [object]$Settings         = $null
    )

    if (-not $Settings) { $Settings = Get-NotificationSettings }

    if (-not $Settings.enabled -or -not $Settings.server_url -or -not $Settings.api_key) {
        return @{ success = $false; reason = "Notifications not configured" }
    }

    $baseUrl = $Settings.server_url.TrimEnd('/')
    $headers = @{ "X-Api-Key" = $Settings.api_key }

    # Deterministic ResponseId — same inputs always yield same GUID so retries are no-ops on server
    $responderKey = if ([string]::IsNullOrEmpty($ResponderEmail)) { [Net.Dns]::GetHostName() } else { $ResponderEmail }
    $keyInput  = "$InstanceId`:$QuestionId`:$responderKey"
    $keyBytes  = [System.Text.Encoding]::UTF8.GetBytes($keyInput)
    $sha1      = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = $sha1.ComputeHash($keyBytes) } finally { $sha1.Dispose() }
    $guidBytes    = New-Object 'System.Byte[]' 16
    [Array]::Copy($hash, $guidBytes, 16)
    $guidBytes[6] = ($guidBytes[6] -band 0x0F) -bor 0x50
    $guidBytes[8] = ($guidBytes[8] -band 0x3F) -bor 0x80
    $responseId   = ([System.Guid]::new([byte[]]$guidBytes)).ToString()

    # SPEC-029 enveloped push-back: { envelope, answer, responder }. The server derives
    # the question from the instance, so questionId/version are not sent in the body.
    $submittedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $envelope = New-NotificationEnvelope -Settings $Settings -ProjectId $ProjectId -TaskId $TaskId `
        -QuestionInstanceId $InstanceId -ResponseId $responseId -SubmittedAt $submittedAt -AnsweredVia 'outpost'

    $answer = @{ approvalDecision = $ApprovalDecision; status = 'submitted' }
    if ($Comment) { $answer['comment'] = $Comment }

    $responder = @{}
    if ($ResponderEmail) { $responder['email'] = $ResponderEmail }

    $body = @{
        envelope  = $envelope
        answer    = $answer
        responder = $responder
    }

    try {
        $result = Invoke-RestMethod -Uri "$baseUrl/api/responses" -Method Post `
            -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json' `
            -Headers $headers -TimeoutSec 15
        return @{ success = $true; response_id = $responseId; server_result = $result }
    } catch {
        return @{ success = $false; reason = "POST /api/responses failed: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function @(
    'New-NotificationEnvelope'
    'ConvertFrom-NotificationEnvelope'
    'Get-NotificationEnvelopeAnswer'
    'Get-NotificationSettings'
    'Test-NotificationServer'
    'Send-TaskNotification'
    'Send-SplitProposalNotification'
    'Send-ReviewNotification'
    'Get-TaskNotificationResponse'
    'Resolve-NotificationAnswer'
    'Send-AttachmentUpload'
    'Remove-Attachment'
    'Invoke-AttachmentBatchUpload'
    'Get-AllTaskNotificationResponse'
    'Send-LocalApprovalResponse'
)
