# SPEC-029 envelope BUILD helper. Dot-sourced by Dotbot.Notification.psm1 so the
# function lives in module scope and is exported via the manifest.
#
# Build is a Notification-only concern (template publish, instance create, local
# approval push-back all originate here), so it stays in this module. The READ side
# is shared with the UI poller and lives in Dotbot.Core (Get-DotbotEnvelopeAnswer).

function New-NotificationEnvelope {
    <#
    .SYNOPSIS
    Builds the SPEC-029 envelope hashtable shared by template publish, instance
    create, and local-approval push-back. One place that knows the envelope shape.

    .PARAMETER Settings
    Notification settings (supplies instance_id -> outpostInstanceId, server_url ->
    mothershipUrl).

    .PARAMETER ProjectId
    Resolved project id.

    .PARAMETER TaskId
    Originating outpost task short id.

    .PARAMETER QuestionInstanceId
    Per-delivery instance id. All-zero for a template publish (no instance yet).

    .PARAMETER ResponseId / SubmittedAt / AnsweredVia
    Response-only fields - set only when building a POST /api/responses body.

    .PARAMETER JiraIssueKey
    Delivery routing for the jira channel - which issue to file the question against.
    #>
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)] [string]$ProjectId,
        [string]$TaskId,
        [string]$QuestionInstanceId = '00000000-0000-0000-0000-000000000000',
        [string]$ResponseId,
        [string]$SubmittedAt,
        [string]$AnsweredVia,
        [string]$JiraIssueKey
    )

    $outpostId = '00000000-0000-0000-0000-000000000000'
    if ($Settings.PSObject.Properties['instance_id'] -and $Settings.instance_id) {
        $parsed = [guid]::Empty
        if ([guid]::TryParse("$($Settings.instance_id)", [ref]$parsed)) {
            $outpostId = $parsed.ToString()
        }
    }

    $mothershipUrl = if ($Settings.server_url) { $Settings.server_url.TrimEnd('/') } else { '' }

    $envelope = @{
        outpostInstanceId  = $outpostId
        taskId             = "$TaskId"
        mothershipUrl      = $mothershipUrl
        questionInstanceId = "$QuestionInstanceId"
        projectId          = "$ProjectId"
    }
    if ($ResponseId)   { $envelope['responseId']   = "$ResponseId" }
    if ($SubmittedAt)  { $envelope['submittedAt']  = "$SubmittedAt" }
    if ($AnsweredVia)  { $envelope['answeredVia']  = "$AnsweredVia" }
    if ($JiraIssueKey) { $envelope['jiraIssueKey'] = "$JiraIssueKey" }

    return $envelope
}
