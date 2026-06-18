<#
.SYNOPSIS
SPEC-029 envelope-contract smoke test. Drives the five mothership API endpoints
end-to-end over HTTP and asserts the envelope wire shape + spec error codes.

.DESCRIPTION
Server-side only - exercises the contract directly via HTTP, no outpost/poller.
Requires a running DotbotServer (test mode) backed by Azurite. See
src/server-dotnet/docs/MOTHERSHIP-E2E-SETUP.md for the 2-terminal setup
(Azurite + `dotnet run --launch-profile http-test`).

.PARAMETER ServerUrl
Base URL of the running server. Default: $env:DOTBOT_SERVER_URL or http://localhost:5048.

.PARAMETER ApiKey
X-Api-Key shared secret. Default: $env:DOTBOT_API_KEY (must match ApiSecurity:ApiKey).

.EXAMPLE
$env:DOTBOT_SERVER_URL = "http://localhost:5048"
$env:DOTBOT_API_KEY    = "<ApiSecurity__ApiKey value>"
pwsh tests/Smoke-EnvelopeContract.ps1
#>
param(
    [string]$ServerUrl = $env:DOTBOT_SERVER_URL,
    [string]$ApiKey    = $env:DOTBOT_API_KEY
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/Test-Helpers.psm1" -Force

# Skip (not fail) when the live server is not configured - matches the Layer 5
# Mothership E2E convention so a normal `Run-Tests.ps1 -Layer 5` without a server
# does not hard-fail.
$missing = @()
if (-not $ServerUrl) { $missing += "DOTBOT_SERVER_URL" }
if (-not $ApiKey)    { $missing += "DOTBOT_API_KEY" }
if ($missing.Count -gt 0) {
    Write-TestResult -Name "Envelope smoke prerequisites" -Status Skip `
        -Message "Missing env var(s): $($missing -join ', ')"
    Write-TestSummary -LayerName "Layer 5: Envelope Contract Smoke" | Out-Null
    exit 0
}

$base    = $ServerUrl.TrimEnd('/')
$headers = @{ "X-Api-Key" = $ApiKey }
$project = "smoke-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))

function Check([string]$Name, [bool]$Cond, [string]$Detail = "") {
    if ($Cond) { Write-TestResult -Name $Name -Status Pass }
    else { Write-TestResult -Name $Name -Status Fail -Message $Detail }
}

# HTTP helper - returns @{ status; body }. -SkipHttpErrorCheck so 4xx/5xx don't throw.
function Invoke-Api([string]$Method, [string]$Path, $Body) {
    $params = @{ Uri = "$base$Path"; Method = $Method; Headers = $headers; TimeoutSec = 20; SkipHttpErrorCheck = $true }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 25); $params.ContentType = 'application/json' }
    $resp = Invoke-WebRequest @params
    $parsed = $null
    if ($resp.Content) { try { $parsed = $resp.Content | ConvertFrom-Json } catch { $parsed = $resp.Content } }
    return @{ status = [int]$resp.StatusCode; body = $parsed }
}

function New-Env([string]$ProjId, [string]$Qiid = '00000000-0000-0000-0000-000000000000') {
    @{
        outpostInstanceId  = [guid]::NewGuid().ToString()
        taskId             = "smoke-task"
        mothershipUrl      = $base
        questionInstanceId = $Qiid
        projectId          = $ProjId
    }
}

function New-SingleChoiceQuestion([string]$Qid) {
    @{
        questionId = $Qid; version = 1; type = "singleChoice"; title = "Pick one"
        options    = @(
            @{ optionId = [guid]::NewGuid().ToString(); key = "a"; title = "A" }
            @{ optionId = [guid]::NewGuid().ToString(); key = "b"; title = "B" }
        )
        project    = @{ projectId = $project; name = "Smoke" }
    }
}
function New-ApprovalQuestion([string]$Qid) {
    @{ questionId = $Qid; version = 1; type = "approval"; title = "Approve?"; options = @(); project = @{ projectId = $project; name = "Smoke" } }
}

Write-Host ""
Write-Host "SPEC-029 envelope smoke test" -ForegroundColor Cyan
Write-Host "  server : $base"
Write-Host "  project: $project"
Write-Host ""

# ── Health ────────────────────────────────────────────────────────────────────
try {
    $h = Invoke-Api GET "/api/health" $null
} catch {
    Write-TestResult -Name "server reachable" -Status Skip `
        -Message "Cannot reach $base ($($_.Exception.Message)). Start the server - see src/server-dotnet/docs/MOTHERSHIP-E2E-SETUP.md."
    Write-TestSummary -LayerName "Layer 5: Envelope Contract Smoke" | Out-Null
    exit 0
}
Check "health 200" ($h.status -eq 200) "got $($h.status)"

# ── POST /api/templates ───────────────────────────────────────────────────────
Write-Host "templates" -ForegroundColor Cyan
$scQid = [guid]::NewGuid().ToString()
$r = Invoke-Api POST "/api/templates" @{ envelope = (New-Env $project); question = (New-SingleChoiceQuestion $scQid) }
Check "publish singleChoice -> 201" ($r.status -eq 201) "got $($r.status)"
Check "  echoes envelope.sentAt" ([bool]$r.body.envelope.sentAt) "sentAt empty"
Check "  echoes question.questionId" ($r.body.question.questionId -eq $scQid) "got $($r.body.question.questionId)"

$r = Invoke-Api POST "/api/templates" @{ envelope = (New-Env $project); question = (New-SingleChoiceQuestion $scQid) }
Check "republish same id -> 409 template_exists" ($r.status -eq 409 -and $r.body.error -eq "template_exists") "got $($r.status)/$($r.body.error)"

$badEnv = New-Env $project; $badEnv.outpostInstanceId = "00000000-0000-0000-0000-000000000000"
$r = Invoke-Api POST "/api/templates" @{ envelope = $badEnv; question = (New-SingleChoiceQuestion ([guid]::NewGuid().ToString())) }
Check "missing outpostInstanceId -> 400 outpost_instance_id_required" ($r.status -eq 400 -and $r.body.error -eq "outpost_instance_id_required") "got $($r.status)/$($r.body.error)"

$badEnv = New-Env $project; $badEnv.taskId = ""
$r = Invoke-Api POST "/api/templates" @{ envelope = $badEnv; question = (New-SingleChoiceQuestion ([guid]::NewGuid().ToString())) }
Check "missing taskId -> 400 task_id_required" ($r.status -eq 400 -and $r.body.error -eq "task_id_required") "got $($r.status)/$($r.body.error)"

$noOpts = New-SingleChoiceQuestion ([guid]::NewGuid().ToString()); $noOpts.options = @()
$r = Invoke-Api POST "/api/templates" @{ envelope = (New-Env $project); question = $noOpts }
Check "singleChoice no options -> 400 options_required" ($r.status -eq 400 -and $r.body.error -eq "options_required") "got $($r.status)/$($r.body.error)"

# ── POST /api/instances ───────────────────────────────────────────────────────
Write-Host "instances" -ForegroundColor Cyan
$instBody = @{
    envelope   = (New-Env $project)
    question   = @{ questionId = $scQid; version = 1 }
    recipients = @( @{ email = "smoke@test.local"; channel = "teams" } )
}
$r = Invoke-Api POST "/api/instances" $instBody
Check "create instance -> 200" ($r.status -eq 200) "got $($r.status)"
$scInstanceId = "$($r.body.instanceId)"
Check "  returns instanceId" ([bool]$scInstanceId) "no instanceId"

$badRcpt = @{ envelope = (New-Env $project); question = @{ questionId = $scQid; version = 1 }; recipients = @( @{ channel = "teams" } ) }
$r = Invoke-Api POST "/api/instances" $badRcpt
Check "empty recipient -> 400 invalid_recipient" ($r.status -eq 400 -and $r.body.error -eq "invalid_recipient") "got $($r.status)/$($r.body.error)"

$r = Invoke-Api POST "/api/instances" @{ envelope = (New-Env $project); question = @{ questionId = [guid]::NewGuid().ToString(); version = 1 }; recipients = @( @{ email = "x@test.local"; channel = "teams" } ) }
Check "unknown template -> 404 template_not_found" ($r.status -eq 404 -and $r.body.error -eq "template_not_found") "got $($r.status)/$($r.body.error)"

# ── Approval template + instance for the response leg ─────────────────────────
$apQid = [guid]::NewGuid().ToString()
$null = Invoke-Api POST "/api/templates" @{ envelope = (New-Env $project); question = (New-ApprovalQuestion $apQid) }
$apInst = Invoke-Api POST "/api/instances" @{ envelope = (New-Env $project); question = @{ questionId = $apQid; version = 1 }; recipients = @( @{ email = "smoke@test.local"; channel = "teams" } ) }
$apInstanceId = "$($apInst.body.instanceId)"

# ── POST /api/responses (envelope; outpost dual-surface push) ──────────────────
Write-Host "responses" -ForegroundColor Cyan
$respId = [guid]::NewGuid().ToString()
function Resp-Env([string]$Rid, [string]$Iid, [string]$Via) {
    $e = New-Env $project $Iid
    $e.responseId = $Rid; $e.submittedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); $e.answeredVia = $Via
    $e
}
$body1 = @{ envelope = (Resp-Env $respId $apInstanceId "outpost"); answer = @{ approvalDecision = "approved" }; responder = @{ email = "arch@test.local" } }
$r = Invoke-Api POST "/api/responses" $body1
Check "approval approved -> 201" ($r.status -eq 201 -and $r.body.responseId -eq $respId) "got $($r.status)/$($r.body.responseId)"

$r = Invoke-Api POST "/api/responses" $body1
Check "same responseId retry -> 200 (idempotent)" ($r.status -eq 200) "got $($r.status)"

$rej = @{ envelope = (Resp-Env ([guid]::NewGuid().ToString()) $apInstanceId "outpost"); answer = @{ approvalDecision = "rejected" }; responder = @{ email = "x@test.local" } }
$r = Invoke-Api POST "/api/responses" $rej
Check "rejected without comment -> 400 comment_required_on_reject" ($r.status -eq 400 -and $r.body.error -eq "comment_required_on_reject") "got $($r.status)/$($r.body.error)"

$bad = @{ envelope = (Resp-Env ([guid]::NewGuid().ToString()) $apInstanceId "outpost"); answer = @{ approvalDecision = "maybe" }; responder = @{ email = "x@test.local" } }
$r = Invoke-Api POST "/api/responses" $bad
Check "junk decision -> 400 invalid_decision_for_type" ($r.status -eq 400 -and $r.body.error -eq "invalid_decision_for_type") "got $($r.status)/$($r.body.error)"

$noInst = @{ envelope = (Resp-Env ([guid]::NewGuid().ToString()) ([guid]::NewGuid().ToString()) "outpost"); answer = @{ approvalDecision = "approved" }; responder = @{ email = "x@test.local" } }
$r = Invoke-Api POST "/api/responses" $noInst
Check "unknown instance -> 404 instance_not_found" ($r.status -eq 404 -and $r.body.error -eq "instance_not_found") "got $($r.status)/$($r.body.error)"

$localTime = @{ envelope = (Resp-Env ([guid]::NewGuid().ToString()) $apInstanceId "outpost"); answer = @{ approvalDecision = "approved" }; responder = @{ email = "x@test.local" } }
$localTime.envelope.submittedAt = "2026-05-21T11:54:32"  # no Z
$r = Invoke-Api POST "/api/responses" $localTime
Check "local-time submittedAt -> 400 invalid_timestamp" ($r.status -eq 400 -and $r.body.error -eq "invalid_timestamp") "got $($r.status)/$($r.body.error)"

# ── GET responses (assembled envelopes) ───────────────────────────────────────
Write-Host "get responses + dual-surface" -ForegroundColor Cyan
# Second response, different decision, via mothership -> dual-surface conflict.
$body2 = @{ envelope = (Resp-Env ([guid]::NewGuid().ToString()) $apInstanceId "mothership"); answer = @{ approvalDecision = "rejected"; comment = "disagree" }; responder = @{ email = "lead@test.local" } }
$null = Invoke-Api POST "/api/responses" $body2

$r = Invoke-Api GET "/api/instances/$project/$apQid/$apInstanceId/responses" $null
Check "get responses -> 200 array of 2" ($r.status -eq 200 -and @($r.body).Count -eq 2) "got $($r.status)/count=$(@($r.body).Count)"
$first = @($r.body)[0]; $second = @($r.body)[1]
Check "  [0] enveloped (envelope/question/answer/responder)" ([bool]$first.envelope -and [bool]$first.question -and [bool]$first.answer -and [bool]$first.responder) "missing sections"
Check "  [0] answer.approvalDecision=approved, answeredVia=outpost" ($first.answer.approvalDecision -eq "approved" -and $first.envelope.answeredVia -eq "outpost") "got $($first.answer.approvalDecision)/$($first.envelope.answeredVia)"
Check "  [0] question.type=approval" ($first.question.type -eq "approval") "got $($first.question.type)"
Check "  [0] agreesWithFirst absent (earliest)" ($null -eq $first.envelope.agreesWithFirst) "got $($first.envelope.agreesWithFirst)"
Check "  [1] agreesWithFirst=false (conflict)" ($second.envelope.agreesWithFirst -eq $false) "got $($second.envelope.agreesWithFirst)"

# ── GET instance record (3-seg) ───────────────────────────────────────────────
Write-Host "get instance record" -ForegroundColor Cyan
$r = Invoke-Api GET "/api/instances/$project/$apQid/$apInstanceId" $null
Check "get instance record -> 200 envelope+question+recipients" ($r.status -eq 200 -and [bool]$r.body.envelope -and [bool]$r.body.question -and [bool]$r.body.recipients) "got $($r.status)"
$r = Invoke-Api GET "/api/instances/$project/$([guid]::NewGuid().ToString())/$apInstanceId" $null
Check "wrong questionId -> 404 instance_not_found" ($r.status -eq 404) "got $($r.status)"

# ── Summary ───────────────────────────────────────────────────────────────────
$ok = Write-TestSummary -LayerName "Layer 5: Envelope Contract Smoke"
exit $(if ($ok) { 0 } else { 1 })
