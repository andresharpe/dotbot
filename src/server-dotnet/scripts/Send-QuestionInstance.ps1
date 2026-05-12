param(
  [string]$BotUrl,
  [int]$Question = 1,
  [string[]]$Emails = @(),
  [string[]]$UserObjectIds = @(),

  [ValidateSet("teams", "email", "jira")]
  [string]$Channel = "teams",
  [string]$JiraIssueKey = "",

  [switch]$NoWait,
  [int]$TimeoutSeconds = 0
)
$ErrorActionPreference = 'Stop'

# ── Load environment ─────────────────────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Load-Env.ps1')
$headers = $dotbotHeaders

if (-not $BotUrl) {
    $BotUrl = $dotbotEnv['DOTBOT_QNA_ENDPOINT']
    if (-not $BotUrl) { throw "Supply -BotUrl or set DOTBOT_QNA_ENDPOINT in .env.local" }
}

# ── Load question from SampleQuestions.json ───────────────────────────────
$sampleFile = Join-Path $PSScriptRoot '..\SampleQuestions.json'
$samples = Get-Content $sampleFile -Raw | ConvertFrom-Json
if ($Question -lt 1 -or $Question -gt $samples.Count) {
    throw "Question must be between 1 and $($samples.Count). Got: $Question"
}
$q = $samples[$Question - 1]
$ProjectId       = $q.project.projectId
$QuestionId      = $q.questionId
$QuestionVersion = $q.version

Write-Host "Q${Question}: $($q.title)" -ForegroundColor White
Write-Host "   Project: $($q.project.name)" -ForegroundColor Gray

$base = $BotUrl.TrimEnd('/')

# ── Publish template (idempotent) ───────────────────────────────────────
$templateJson = $q | ConvertTo-Json -Depth 5
Invoke-RestMethod -Uri "$base/api/templates" -Method Post -ContentType 'application/json' -Body $templateJson -Headers $headers | Out-Null

# ── Build and send instance ────────────────────────────────────────────
$instanceId = [guid]::NewGuid()
$body = @{
  instanceId      = $instanceId
  projectId       = $ProjectId
  questionId      = $QuestionId
  questionVersion = $QuestionVersion
  channel         = $Channel
  recipients      = @{ emails = $Emails; userObjectIds = $UserObjectIds }
}

if ($Channel -eq 'jira' -and $JiraIssueKey) {
    $body.jiraIssueKey = $JiraIssueKey
}

$bodyJson = $body | ConvertTo-Json -Depth 6

Write-Host "Sending instance via '$Channel' to $base..." -ForegroundColor Cyan
Invoke-RestMethod -Uri "$base/api/instances" -Method Post -ContentType 'application/json' -Body $bodyJson -Headers $headers | Out-Null
Write-Host "Instance created: $instanceId" -ForegroundColor Green

if ($NoWait) { return $instanceId }

# ── Poll for responses ─────────────────────────────────────────────────
if ($TimeoutSeconds -gt 0) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  Write-Host "Waiting for response (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow
} else {
  $deadline = $null
  Write-Host "Waiting for response..." -ForegroundColor Yellow
}

while ($null -eq $deadline -or (Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  try {
    $resp = Invoke-RestMethod -Uri "$base/api/instances/$ProjectId/$QuestionId/$instanceId/responses" -Headers $headers -ErrorAction Stop
    if ($resp -and $resp.Count -gt 0) { return $resp }
  } catch {}
}
throw "Timed out waiting for responses for instance $instanceId"
