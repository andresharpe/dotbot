<#
.SYNOPSIS
    Sends a multi-choice question to a user via Dotbot (v1 two-step API).

.DESCRIPTION
    Uses the Dotbot v1 API to deliver a question:
      1. Publishes a QuestionTemplate to POST /api/templates
      2. Creates a QuestionInstance to POST /api/instances

    The target user is specified by email or AAD object ID. The server resolves
    emails via Microsoft Graph — no local az ad calls required.

.PARAMETER BotUrl
    The base URL of the Dotbot app (e.g., https://we-dotbot-bot-test-01.azurewebsites.net)

.PARAMETER User
    The target user - an email address or Azure AD Object ID.

.PARAMETER Question
    The question text (becomes template title).

.PARAMETER Options
    An array of option objects, each with key, label, and optional rationale.

.PARAMETER Context
    Optional context string displayed below the question.

.PARAMETER ProjectName
    The name of the project this question relates to.

.PARAMETER ProjectDescription
    A short description of the project.

.PARAMETER ProjectId
    The project identifier. Auto-generated as kebab-case of ProjectName if omitted.

.PARAMETER Recommendation
    The recommended option key (default: "A"). Sets isRecommended on matching option.

.PARAMETER AllowFreeText
    If set, the user can type a free-text reply instead of picking an option.

.PARAMETER QuestionId
    A unique identifier for the question. Defaults to auto-generated GUID.

.PARAMETER Channel
    Delivery channel: "teams", "email", "jira", or "slack". Default: "teams".

.PARAMETER JiraIssueKey
    Required when -Channel is "jira". The Jira issue key to post the comment to.

.PARAMETER Wait
    If set, polls for the user's answer and displays it.

.PARAMETER TimeoutSeconds
    How long to wait for a response when -Wait is specified. Default: 300.

.PARAMETER PollIntervalSeconds
    How often to poll for a response when -Wait is specified. Default: 3.

.EXAMPLE
    # Simple usage with email and inline options
    .\Send-DotbotQuestion.ps1 `
        -BotUrl "https://we-dotbot-bot-test-01.azurewebsites.net" `
        -User "user@example.com" `
        -Question "Which database should we use?" `
        -Options @(
            @{ key = "A"; label = "PostgreSQL"; rationale = "Mature, open-source, great ecosystem" },
            @{ key = "B"; label = "SQLite"; rationale = "Simple, embedded, zero config" },
            @{ key = "C"; label = "CosmosDB"; rationale = "Azure-native, multi-model, global distribution" }
        ) -Wait

.EXAMPLE
    # Load from SampleQuestions.json (v1 template format)
    $templates = Get-Content .\SampleQuestions.json | ConvertFrom-Json
    $t = $templates[0]
    .\Send-DotbotQuestion.ps1 `
        -BotUrl "https://we-dotbot-bot-test-01.azurewebsites.net" `
        -User "user@example.com" `
        -Question $t.title `
        -Options ($t.options | ForEach-Object { @{ key = $_.key; label = $_.title; rationale = $_.summary } }) `
        -Context $t.context `
        -ProjectName $t.project.name `
        -ProjectDescription $t.project.description `
        -ProjectId $t.project.projectId `
        -QuestionId $t.questionId `
        -AllowFreeText:$t.responseSettings.allowFreeText -Wait
#>
[CmdletBinding()]
param(
    [string]$BotUrl,

    [Parameter(Mandatory)]
    [Alias('UserObjectId')]
    [string]$User,

    [Parameter(Mandatory)]
    [string]$Question,

    [Parameter(Mandatory)]
    [object[]]$Options,

    [string]$Context = "",

    [string]$ProjectName = "",

    [string]$ProjectDescription = "",

    [string]$ProjectId = "",

    [string]$Recommendation = "A",

    [switch]$AllowFreeText,

    [string]$QuestionId = ([guid]::NewGuid().ToString()),

    [ValidateSet("teams", "email", "jira", "slack")]
    [string]$Channel = "teams",

    [string]$JiraIssueKey = "",

    [switch]$Wait,

    [int]$TimeoutSeconds = 300,

    [int]$PollIntervalSeconds = 3
)

$ErrorActionPreference = 'Stop'

# ── Load environment ─────────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'scripts\Load-Env.ps1')
$headers = $dotbotHeaders

if (-not $BotUrl) {
    $BotUrl = $dotbotEnv['DOTBOT_QNA_ENDPOINT']
    if (-not $BotUrl) { throw "Supply -BotUrl or set DOTBOT_QNA_ENDPOINT in .env.local" }
}

# ── Display a project panel in the console ──────────────────────────────────
if ($ProjectName) {
    $nameDisplay = $ProjectName
    $descDisplay = if ($ProjectDescription) { $ProjectDescription } else { '' }
    $innerWidth  = (@($nameDisplay.Length, $descDisplay.Length) | Measure-Object -Maximum).Maximum + 4
    if ($innerWidth -lt 30) { $innerWidth = 30 }
    $top    = "`u{250C}" + ("`u{2500}" * ($innerWidth + 2)) + "`u{2510}"
    $bottom = "`u{2514}" + ("`u{2500}" * ($innerWidth + 2)) + "`u{2518}"
    $namePad = $nameDisplay.PadRight($innerWidth)
    $nameLine = "`u{2502} " + $namePad + " `u{2502}"

    Write-Host ""
    Write-Host $top        -ForegroundColor DarkCyan
    Write-Host $nameLine   -ForegroundColor Cyan
    if ($descDisplay) {
        $descPad = $descDisplay.PadRight($innerWidth)
        $descLine = "`u{2502} " + $descPad + " `u{2502}"
        Write-Host $descLine -ForegroundColor DarkGray
    }
    Write-Host $bottom     -ForegroundColor DarkCyan
    Write-Host ""
}

# ── Derive projectId if not provided ────────────────────────────────────────
if (-not $ProjectId -and $ProjectName) {
    $ProjectId = ($ProjectName.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
}
if (-not $ProjectId) {
    $ProjectId = "default"
}

# ── Build QuestionTemplate ──────────────────────────────────────────────────
$templateOptions = @(foreach ($opt in $Options) {
    $tOpt = @{
        optionId      = [guid]::NewGuid().ToString()
        key           = "$($opt.key)"
        title         = "$($opt.label)"
        summary       = if ($opt.rationale) { "$($opt.rationale)" } else { $null }
        isRecommended = ("$($opt.key)" -eq $Recommendation)
    }
    $tOpt
})

$template = @{
    questionId       = $QuestionId
    version          = 1
    title            = $Question
    context          = if ($Context) { $Context } else { $null }
    options          = $templateOptions
    responseSettings = @{
        allowFreeText = [bool]$AllowFreeText
    }
    project          = @{
        projectId   = $ProjectId
        name        = if ($ProjectName) { $ProjectName } else { $null }
        description = if ($ProjectDescription) { $ProjectDescription } else { $null }
    }
}

$baseUrl = $BotUrl.TrimEnd('/')

# ── Step 1: Publish template ────────────────────────────────────────────────
$templateJson = $template | ConvertTo-Json -Depth 5
$templateUri = "$baseUrl/api/templates"

Write-Host "Publishing template '$QuestionId'..." -ForegroundColor Cyan

try {
    $templateResp = Invoke-RestMethod -Uri $templateUri -Method Post -Body $templateJson -ContentType 'application/json' -Headers $headers
    Write-Host "Template published." -ForegroundColor Green
    Write-Host "   Question ID: $($templateResp.questionId)" -ForegroundColor Gray
    Write-Host "   Version:     $($templateResp.version)" -ForegroundColor Gray
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = $_.ErrorDetails.Message
    Write-Host "Failed to publish template (HTTP $statusCode)" -ForegroundColor Red
    if ($errorBody) { Write-Host "   Error: $errorBody" -ForegroundColor Red }
    throw
}

# ── Step 2: Create instance ─────────────────────────────────────────────────
$instanceId = [guid]::NewGuid().ToString()

$instanceReq = @{
    instanceId      = $instanceId
    projectId       = $ProjectId
    questionId      = $QuestionId
    questionVersion = 1
    channel         = $Channel
    recipients      = @{}
}

# Route user to the right recipient field
if ($Channel -eq 'slack') {
    if ($User -match '@') {
        throw "Slack delivery requires a Slack user ID in -User, not an email address."
    }
    $instanceReq.recipients.slackUserIds = @($User)
} elseif ($User -match '@') {
    $instanceReq.recipients.emails = @($User)
} else {
    $instanceReq.recipients.userObjectIds = @($User)
}

if ($Channel -eq 'jira' -and $JiraIssueKey) {
    $instanceReq.jiraIssueKey = $JiraIssueKey
}

$instanceJson = $instanceReq | ConvertTo-Json -Depth 5
$instanceUri = "$baseUrl/api/instances"

Write-Host "Creating instance for channel '$Channel'..." -ForegroundColor Cyan

try {
    $instanceResp = Invoke-RestMethod -Uri $instanceUri -Method Post -Body $instanceJson -ContentType 'application/json' -Headers $headers
    Write-Host "Instance created." -ForegroundColor Green
    Write-Host "   Instance ID: $($instanceResp.instanceId)" -ForegroundColor Gray
    $sentCount = if ($instanceResp.recipients) { @($instanceResp.recipients).Count } else { 0 }
    Write-Host "   Sent to:     $sentCount recipient(s)" -ForegroundColor Gray
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = $_.ErrorDetails.Message
    Write-Host "Failed to create instance (HTTP $statusCode)" -ForegroundColor Red
    if ($errorBody) { Write-Host "   Error: $errorBody" -ForegroundColor Red }
    throw
}

if (-not $Wait) {
    return
}

# ── Poll for responses ──────────────────────────────────────────────────────
$responsesUri = "$baseUrl/api/instances/$ProjectId/$QuestionId/$instanceId/responses"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

Write-Host "`nWaiting for response (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollIntervalSeconds
    try {
        $responses = Invoke-RestMethod -Uri $responsesUri -Method Get -Headers $headers -ErrorAction Stop
        if ($responses -and @($responses).Count -gt 0) {
            $first = @($responses)[0]
            Write-Host "`nResponse received." -ForegroundColor Green
            Write-Host "   Response ID: $($first.responseId)" -ForegroundColor Gray
            if ($first.selectedKey) {
                Write-Host "   Selected:    $($first.selectedKey)" -ForegroundColor Cyan
            }
            if ($first.freeText) {
                Write-Host "   Free text:   $($first.freeText)" -ForegroundColor Cyan
            }
            Write-Host "   Responder:   $($first.responderEmail)" -ForegroundColor Gray
            Write-Host "   Submitted:   $($first.submittedAt)" -ForegroundColor Gray
            return $first
        }
    }
    catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -ne 404) {
            Write-Host "Poll error (HTTP $code)" -ForegroundColor Yellow
        }
    }
}

Write-Host "`nTimed out waiting for response after ${TimeoutSeconds}s" -ForegroundColor Red
