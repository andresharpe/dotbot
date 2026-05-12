<#
.SYNOPSIS
    Post-deploy smoke tests for the Dotbot v1 API.

.DESCRIPTION
    Runs automated smoke tests against a deployed Dotbot instance:
      1. Health check (GET /api/health)
      2. Publish a template from SampleQuestions.json (POST /api/templates)
      3. Create an instance targeting a user (POST /api/instances)
      4. Get the instance (GET /api/instances/{projectId}/{instanceId})
      5. List responses (GET /api/instances/{projectId}/{questionId}/{instanceId}/responses)

    Prints a pass/fail summary and manual test instructions.

.PARAMETER BotUrl
    The base URL of the Dotbot app (e.g., https://we-dotbot-bot-test-01.azurewebsites.net)

.PARAMETER Email
    The email address of the test recipient.

.EXAMPLE
    .\scripts\Test-EndToEnd.ps1 `
        -BotUrl "https://we-dotbot-bot-test-01.azurewebsites.net" `
        -Email "user@example.com"
#>
[CmdletBinding()]
param(
    [string]$BotUrl,

    [Parameter(Mandatory)]
    [string]$Email,

    [ValidateSet("teams", "email", "jira")]
    [string]$Channel = "teams"
)

$ErrorActionPreference = 'Stop'

# ── Load environment ─────────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Load-Env.ps1')
$headers = $dotbotHeaders

if (-not $BotUrl) {
    $BotUrl = $dotbotEnv['DOTBOT_QNA_ENDPOINT']
    if (-not $BotUrl) { throw "Supply -BotUrl or set DOTBOT_QNA_ENDPOINT in .env.local" }
}
$baseUrl = $BotUrl.TrimEnd('/')

$results = @()
$instanceId = $null
$projectId = $null
$questionId = $null

function Add-Result($step, $passed, $detail) {
    $script:results += [PSCustomObject]@{
        Step   = $step
        Passed = $passed
        Detail = $detail
    }
}

# ── 1. Health check ─────────────────────────────────────────────────────────
Write-Host "`n[1/5] Health check..." -ForegroundColor Cyan
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/api/health" -Method Get -ErrorAction Stop
    Add-Result "Health check" $true "status=$($health.status)"
    Write-Host "  PASS  status=$($health.status)" -ForegroundColor Green
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    Add-Result "Health check" $false "HTTP $code"
    Write-Host "  FAIL  HTTP $code" -ForegroundColor Red
}

# ── 2. Publish template ─────────────────────────────────────────────────────
Write-Host "[2/5] Publish template..." -ForegroundColor Cyan
try {
    $sampleFile = Join-Path $PSScriptRoot "..\SampleQuestions.json"
    $templates = Get-Content $sampleFile -Raw | ConvertFrom-Json
    $template = $templates[0]
    $projectId = $template.project.projectId
    $questionId = $template.questionId
    $templateJson = $template | ConvertTo-Json -Depth 5

    $templateResp = Invoke-RestMethod -Uri "$baseUrl/api/templates" -Method Post `
        -Body $templateJson -ContentType 'application/json' -Headers $headers -ErrorAction Stop
    Add-Result "Publish template" $true "questionId=$($templateResp.questionId), version=$($templateResp.version)"
    Write-Host "  PASS  questionId=$($templateResp.questionId)" -ForegroundColor Green
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    $err = $_.ErrorDetails.Message
    Add-Result "Publish template" $false "HTTP $code - $err"
    Write-Host "  FAIL  HTTP $code - $err" -ForegroundColor Red
}

# ── 3. Create instance ──────────────────────────────────────────────────────
Write-Host "[3/5] Create instance..." -ForegroundColor Cyan
try {
    $instanceId = [guid]::NewGuid().ToString()
    $instanceReq = @{
        instanceId      = $instanceId
        projectId       = $projectId
        questionId      = $questionId
        questionVersion = 1
        channel         = $Channel
        recipients      = @{ emails = @($Email) }
    } | ConvertTo-Json -Depth 5

    $instanceResp = Invoke-RestMethod -Uri "$baseUrl/api/instances" -Method Post `
        -Body $instanceReq -ContentType 'application/json' -Headers $headers -ErrorAction Stop
    $sentCount = if ($instanceResp.recipients) { @($instanceResp.recipients).Count } else { 0 }
    Add-Result "Create instance" $true "instanceId=$($instanceResp.instanceId), sent=$sentCount"
    Write-Host "  PASS  instanceId=$($instanceResp.instanceId), sent=$sentCount" -ForegroundColor Green
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    $err = $_.ErrorDetails.Message
    Add-Result "Create instance" $false "HTTP $code - $err"
    Write-Host "  FAIL  HTTP $code - $err" -ForegroundColor Red
}

# ── 4. Get instance ─────────────────────────────────────────────────────────
Write-Host "[4/5] Get instance..." -ForegroundColor Cyan
try {
    $inst = Invoke-RestMethod -Uri "$baseUrl/api/instances/$projectId/$instanceId" `
        -Method Get -Headers $headers -ErrorAction Stop
    $hasData = $null -ne $inst.instanceId
    Add-Result "Get instance" $hasData "overallStatus=$($inst.overallStatus)"
    if ($hasData) {
        Write-Host "  PASS  overallStatus=$($inst.overallStatus)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  empty response" -ForegroundColor Red
    }
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    Add-Result "Get instance" $false "HTTP $code"
    Write-Host "  FAIL  HTTP $code" -ForegroundColor Red
}

# ── 5. List responses ───────────────────────────────────────────────────────
Write-Host "[5/5] List responses..." -ForegroundColor Cyan
try {
    $responses = Invoke-RestMethod `
        -Uri "$baseUrl/api/instances/$projectId/$questionId/$instanceId/responses" `
        -Method Get -Headers $headers -ErrorAction Stop
    $count = @($responses).Count
    # Initially empty is expected — that's a pass
    Add-Result "List responses" $true "count=$count (expected 0 initially)"
    Write-Host "  PASS  count=$count (expected 0 initially)" -ForegroundColor Green
}
catch {
    $code = $_.Exception.Response.StatusCode.value__
    Add-Result "List responses" $false "HTTP $code"
    Write-Host "  FAIL  HTTP $code" -ForegroundColor Red
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n" + ("=" * 60) -ForegroundColor DarkGray
Write-Host "  SMOKE TEST SUMMARY" -ForegroundColor White
Write-Host ("=" * 60) -ForegroundColor DarkGray

$passCount = ($results | Where-Object { $_.Passed }).Count
$failCount = ($results | Where-Object { -not $_.Passed }).Count

foreach ($r in $results) {
    $icon = if ($r.Passed) { "[PASS]" } else { "[FAIL]" }
    $color = if ($r.Passed) { "Green" } else { "Red" }
    Write-Host "  $icon $($r.Step): $($r.Detail)" -ForegroundColor $color
}

Write-Host ""
if ($failCount -eq 0) {
    Write-Host "  All $passCount tests passed!" -ForegroundColor Green
} else {
    Write-Host "  $passCount passed, $failCount failed" -ForegroundColor Yellow
}
Write-Host ("=" * 60) -ForegroundColor DarkGray

# ── Manual test instructions ─────────────────────────────────────────────────
Write-Host "`n  Manual verification steps:" -ForegroundColor White
Write-Host "  1. Open Teams and chat with Dotbot — send any message" -ForegroundColor Gray
Write-Host "     (creates conversation reference for proactive messaging)" -ForegroundColor DarkGray
Write-Host "  2. Run the script again — the question card should arrive in Teams" -ForegroundColor Gray
Write-Host "  3. Click 'Open in Browser' on the card to test the web response UI" -ForegroundColor Gray
Write-Host "  4. Submit an answer and re-run step 5 to verify it was recorded" -ForegroundColor Gray
Write-Host ""
