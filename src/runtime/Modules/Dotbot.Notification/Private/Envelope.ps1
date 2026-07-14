# SPEC-029 envelope helpers (build + read). Dot-sourced by Dotbot.Notification.psm1
# so they live in module scope and are exported via the manifest.
#
#   New-NotificationEnvelope        - build a publish/instance/response envelope
#   ConvertFrom-NotificationEnvelope - split an enveloped response into its sections
#   Get-NotificationEnvelopeAnswer  - project the answer fields from a response
#
# Envelope handling is a notification-domain concern, so all of it lives here. The
# read helpers are consumed by Resolve-NotificationAnswer and by the UI
# NotificationPoller (which imports this module) - both already depend on
# Dotbot.Notification, so there is no reason to push the parser down into Dotbot.Core.

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

function ConvertFrom-NotificationEnvelope {
    <#
    .SYNOPSIS
    Splits a SPEC-029 enveloped response into its sections.

    .DESCRIPTION
    The structural READ counterpart to New-NotificationEnvelope. Given the
    { envelope, question, answer, responder } wire object returned by
    GET /api/instances/.../responses, returns each section plus a few hoisted
    convenience fields (type, answeredVia, agreesWithFirst). Tolerant of $null and
    of a response missing any section.

    .PARAMETER Response
    The enveloped response object (PSCustomObject from ConvertFrom-Json).

    .OUTPUTS
    Hashtable: envelope, question, answer, responder, type, answeredVia, agreesWithFirst.
    #>
    param($Response)

    $envelope  = if ($Response -and $Response.PSObject.Properties['envelope'])  { $Response.envelope }  else { $null }
    $question  = if ($Response -and $Response.PSObject.Properties['question'])   { $Response.question }   else { $null }
    $answer    = if ($Response -and $Response.PSObject.Properties['answer'])     { $Response.answer }     else { $null }
    $responder = if ($Response -and $Response.PSObject.Properties['responder'])  { $Response.responder }  else { $null }

    return @{
        envelope        = $envelope
        question        = $question
        answer          = $answer
        responder       = $responder
        type            = if ($question -and $question.PSObject.Properties['type']) { "$($question.type)" } else { $null }
        answeredVia     = if ($envelope -and $envelope.PSObject.Properties['answeredVia']) { "$($envelope.answeredVia)" } else { $null }
        agreesWithFirst = if ($envelope -and $envelope.PSObject.Properties['agreesWithFirst']) { $envelope.agreesWithFirst } else { $null }
    }
}

function Get-NotificationEnvelopeAnswer {
    <#
    .SYNOPSIS
    Extracts the answer fields from a SPEC-029 enveloped response.

    .DESCRIPTION
    Sits beside New-NotificationEnvelope (build) and Resolve-NotificationAnswer
    (resolve-to-local-task). Used by Resolve-NotificationAnswer and by the UI
    NotificationPoller split-proposal path. Builds on ConvertFrom-NotificationEnvelope
    for the structural split, then switches on question.type to pick the answer field.
    Falls back to whichever field is populated when the type is absent (preserving the
    old flat reader's precedence).

    .PARAMETER Response
    The enveloped response object (PSCustomObject from ConvertFrom-Json).

    .OUTPUTS
    Hashtable:
      type, answeredVia, agreesWithFirst
      selectedKey, freeText, approvalDecision, comment
      rankedItems, reviewedAttachmentIds, attachments (arrays; empty when absent)
      answerString  - the type-projected single answer string ($null when none)
    #>
    param($Response)

    $parts = ConvertFrom-NotificationEnvelope -Response $Response
    $ans   = $parts.answer
    $type  = $parts.type

    $selectedKey      = if ($ans) { $ans.selectedKey } else { $null }
    $freeText         = if ($ans) { $ans.freeText } else { $null }
    $approvalDecision = if ($ans) { $ans.approvalDecision } else { $null }
    $comment          = if ($ans -and $ans.PSObject.Properties['comment'] -and $ans.comment) { "$($ans.comment)" } else { $null }
    $rankedItems      = if ($ans -and $ans.PSObject.Properties['rankedItems'] -and $ans.rankedItems) { @($ans.rankedItems) } else { @() }
    $reviewedIds      = if ($ans -and $ans.PSObject.Properties['reviewedAttachmentIds'] -and $ans.reviewedAttachmentIds) { @($ans.reviewedAttachmentIds) } else { @() }
    $attachments      = if ($ans -and $ans.PSObject.Properties['attachments'] -and $ans.attachments) { @($ans.attachments) } else { @() }

    $answerString =
        switch ($type) {
            'approval'        { if ($approvalDecision) { "$approvalDecision" } else { $null } }
            'singleChoice'    { if ($selectedKey)      { "$selectedKey" }      elseif ($freeText) { "$freeText" } else { $null } }
            'freeText'        { if ($freeText)         { "$freeText" }         else { $null } }
            'priorityRanking' { if ($rankedItems.Count -gt 0) { (@($rankedItems) | Sort-Object rank | ForEach-Object { "$($_.optionId)" }) -join ', ' } else { $null } }
            default {
                # No type on the wire - fall back to whichever field is populated.
                if     ($approvalDecision)        { "$approvalDecision" }
                elseif ($selectedKey)             { "$selectedKey" }
                elseif ($freeText)                { "$freeText" }
                elseif ($rankedItems.Count -gt 0) { (@($rankedItems) | Sort-Object rank | ForEach-Object { "$($_.optionId)" }) -join ', ' }
                else                              { $null }
            }
        }

    return @{
        type                  = $type
        answeredVia           = $parts.answeredVia
        agreesWithFirst       = $parts.agreesWithFirst
        selectedKey           = $selectedKey
        freeText              = $freeText
        approvalDecision      = $approvalDecision
        comment               = $comment
        rankedItems           = $rankedItems
        reviewedAttachmentIds = $reviewedIds
        attachments           = $attachments
        answerString          = $answerString
    }
}
