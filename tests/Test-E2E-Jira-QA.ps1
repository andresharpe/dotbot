#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 4: End-to-end test for the Jira Q&A round-trip with approvals.
.DESCRIPTION
    For each fixture (markdown, PDF, image), creates a fresh dotbot project
    configured against a real DotbotServer on the Jira channel, then exercises
    two reply paths:

      Path A: inject a simulated reply via POST /api/test/responses
              (channel-agnostic, same endpoint Teams and Email use) and
              verify Resolve-NotificationAnswer downloads the attachment
              with matching SHA-256.

      Path B: mint a magic-link JWT via POST /api/test/magic-link, then
              POST /respond (multipart form) with the fixture attached,
              and verify a second response with that attachment surfaces
              at /api/instances/.../responses.

    Jira delivery is outbound-only (comment posted to a Jira issue). The
    replying user clicks the magic-link embedded in the comment, which
    opens /respond - same code path Email uses. There is no inbound Jira
    webhook to simulate.

    Required env: DOTBOT_SERVER_URL, DOTBOT_API_KEY, DOTBOT_JIRA_ISSUE_KEY,
    DOTBOT_JIRA_EMAIL_RECIPIENT. Optional: DOTBOT_REQUIRE_REAL_DELIVERY=true
    gates the Tier 3 assertion against instance.sentTo[*].status == "sent".

    The server must be started with DOTBOT_TEST_MODE=true and have
    DeliveryChannels:Jira:Enabled=true in its appsettings.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 4: E2E Jira Q&A with Approvals" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$serverUrl           = $env:DOTBOT_SERVER_URL
$apiKey              = $env:DOTBOT_API_KEY
$jiraIssueKey        = $env:DOTBOT_JIRA_ISSUE_KEY
$jiraEmailRecipient  = $env:DOTBOT_JIRA_EMAIL_RECIPIENT

$missing = @()

if (-not $serverUrl) {
    $missing += "DOTBOT_SERVER_URL"
}

if (-not $apiKey) {
    $missing += "DOTBOT_API_KEY"
}

if (-not $jiraIssueKey) {
    $missing += "DOTBOT_JIRA_ISSUE_KEY"
}

if (-not $jiraEmailRecipient) {
    $missing += "DOTBOT_JIRA_EMAIL_RECIPIENT"
}

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")

if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Fail -Message "dotbot not installed globally"
    Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
    exit 1
}

if ($missing.Count -gt 0) {
    Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Skip `
        -Message "Missing env var(s): $($missing -join ', ')"
    Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
    exit 0
}

if ($jiraEmailRecipient -notmatch '@') {
    Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Fail `
        -Message "DOTBOT_JIRA_EMAIL_RECIPIENT must be an email address (contain '@'): got '$jiraEmailRecipient'"
    Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
    exit 1
}

try {
    $null = Invoke-RestMethod -Uri "$($serverUrl.TrimEnd('/'))/api/health" -Method Get -TimeoutSec 5
} catch {
    Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Skip `
        -Message "DotbotServer at $serverUrl is not reachable: $($_.Exception.Message)"
    Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
    exit 0
}

foreach ($probePath in @('/api/test/responses', '/api/test/magic-link')) {
    try {
        $probe = Invoke-WebRequest -Uri "$($serverUrl.TrimEnd('/'))$probePath" `
            -Method Post -Body "{}" -ContentType "application/json" `
            -Headers @{ "X-Api-Key" = $apiKey } -TimeoutSec 5 -SkipHttpErrorCheck

        if ($probe.StatusCode -eq 404) {
            Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Skip `
                -Message "Server is missing $probePath - start it with DOTBOT_TEST_MODE=true and rebuild"
            Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
            exit 0
        }

        if ($probe.StatusCode -eq 401) {
            Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Fail `
                -Message "Server rejected DOTBOT_API_KEY (401) at $probePath. Check ApiSecurity:ApiKey."
            Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
            exit 1
        }
    } catch {
        Write-TestResult -Name "Layer 4 Jira prerequisites" -Status Skip `
            -Message "Probe $probePath failed: $($_.Exception.Message)"
        Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A" | Out-Null
        exit 0
    }
}

Write-Host "  SETUP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "    Server   : $serverUrl" -ForegroundColor DarkGray
Write-Host "    Channel  : jira" -ForegroundColor DarkGray
Write-Host "    Issue    : $jiraIssueKey" -ForegroundColor DarkGray
Write-Host "    Recipient: $jiraEmailRecipient" -ForegroundColor DarkGray
Write-Host ""

$fixturesDir = Join-Path $PSScriptRoot "fixtures\attachments"
$fixtures = @(
    @{ Label = "markdown"; File = "sample.md";  Key = "md"    }
    @{ Label = "pdf";      File = "sample.pdf"; Key = "pdf"   }
    @{ Label = "image";    File = "sample.png"; Key = "image" }
)

foreach ($f in $fixtures) {
    Assert-PathExists -Name "Jira: fixture '$($f.File)' present" -Path (Join-Path $fixturesDir $f.File)
}

function Invoke-JiraRoundTrip {
    param(
        [Parameter(Mandatory)] [hashtable]$Fixture,
        [Parameter(Mandatory)] [string]$ServerUrl,
        [Parameter(Mandatory)] [string]$ApiKey,
        [Parameter(Mandatory)] [string]$IssueKey,
        [Parameter(Mandatory)] [string]$Recipient,
        [Parameter(Mandatory)] [string]$DotbotDir,
        [Parameter(Mandatory)] [string]$FixturesDir
    )

    $label = $Fixture.Label
    $testProject = New-TestProject -Prefix "dotbot-jira-$($Fixture.Key)"

    try {
        Push-Location $testProject
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        $botDir = Join-Path $testProject ".bot"

        if (-not (Test-Path $botDir)) {
            Write-TestResult -Name "Jira[$label]: .bot initialized" -Status Fail -Message ".bot missing after init-project.ps1"
            return
        }

        $controlDir = Join-Path $botDir ".control"

        if (-not (Test-Path $controlDir)) {
            New-Item -ItemType Directory -Force -Path $controlDir | Out-Null
        }

        $instanceId = [guid]::NewGuid().ToString()
        $control = [ordered]@{
            instance_id = $instanceId
            mothership  = [ordered]@{
                enabled               = $true
                server_url            = $ServerUrl
                api_key               = $ApiKey
                channel               = "jira"
                recipients            = @($Recipient)
                project_name          = "dotbot-jira-test-$label"
                project_description   = "Layer 4 Jira round-trip fixture: $label"
                poll_interval_seconds = 2
                sync_tasks            = $false
                sync_questions        = $true
                jira_issue_key        = $IssueKey
            }
        }
        ($control | ConvertTo-Json -Depth 10) | Set-Content -Path (Join-Path $controlDir "settings.json") -Encoding UTF8

        $notifModule = Join-Path $botDir "core/mcp/modules/NotificationClient.psm1"

        if (-not (Test-Path $notifModule)) {
            Write-TestResult -Name "Jira[$label]: NotificationClient.psm1 present" -Status Fail -Message "Module missing at $notifModule"
            return
        }

        $global:DotbotProjectRoot = $testProject
        Import-Module $notifModule -Force -DisableNameChecking

        $settings = Get-NotificationSettings -BotRoot $botDir
        Assert-Equal -Name "Jira[$label]: settings.enabled resolves" -Expected $true -Actual $settings.enabled
        Assert-Equal -Name "Jira[$label]: settings.channel resolves" -Expected "jira" -Actual $settings.channel
        Assert-Equal -Name "Jira[$label]: settings.jira_issue_key resolves" -Expected $IssueKey -Actual $settings.jira_issue_key

        $questionLocalId = "q-$label-$([guid]::NewGuid().Guid.Substring(0,8))"
        $taskId = "task-$label-$([guid]::NewGuid().Guid.Substring(0,8))"
        $taskContent = [pscustomobject]@{
            id   = $taskId
            name = "Jira E2E fixture: $label"
        }
        $pendingQuestion = [pscustomobject]@{
            id             = $questionLocalId
            question       = "Jira approval E2E: approve this change?"
            context        = "Layer 4 round-trip test. Reply simulated via /api/test/responses and /respond."
            options        = @(
                [pscustomobject]@{ key = "approve"; label = "Approve"; rationale = "Accept the change and move forward." }
                [pscustomobject]@{ key = "reject";  label = "Reject";  rationale = "Block the change." }
            )
            recommendation = "approve"
        }

        $sendResult = Send-TaskNotification -TaskContent $taskContent -PendingQuestion $pendingQuestion -Settings $settings

        if (-not $sendResult.success) {
            Write-TestResult -Name "Jira[$label]: Send-TaskNotification succeeded" -Status Fail -Message $sendResult.reason
            return
        }

        Write-TestResult -Name "Jira[$label]: Send-TaskNotification succeeded" -Status Pass

        $fixturePath = Join-Path $FixturesDir $Fixture.File
        $fixtureBytes = [IO.File]::ReadAllBytes($fixturePath)
        $fixtureSize = [int64]$fixtureBytes.LongLength
        $sourceHash = (Get-FileHash -Path $fixturePath -Algorithm SHA256).Hash

        $injectBody = @{
            projectId      = $sendResult.project_id
            questionId     = $sendResult.question_id
            instanceId     = $sendResult.instance_id
            selectedKey    = "approve"
            freeText       = $null
            responderEmail = $Recipient
            attachments    = @(
                @{
                    name          = $Fixture.File
                    contentBase64 = [Convert]::ToBase64String($fixtureBytes)
                }
            )
        }

        try {
            $null = Invoke-RestMethod -Uri "$($ServerUrl.TrimEnd('/'))/api/test/responses" -Method Post `
                -Body ($injectBody | ConvertTo-Json -Depth 10) -ContentType "application/json" `
                -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 15
            Write-TestResult -Name "Jira[$label]: Path A - injected simulated response" -Status Pass
        } catch {
            Write-TestResult -Name "Jira[$label]: Path A - injected simulated response" -Status Fail -Message $_.Exception.Message
            return
        }

        $notificationMeta = [pscustomobject]@{
            question_id = $sendResult.question_id
            instance_id = $sendResult.instance_id
            project_id  = $sendResult.project_id
            channel     = $sendResult.channel
        }
        $deadline = (Get-Date).AddSeconds(30)
        $response = $null

        while ((Get-Date) -lt $deadline) {
            $response = Get-TaskNotificationResponse -Notification $notificationMeta -Settings $settings

            if ($response) {
                break
            }

            Start-Sleep -Milliseconds 500
        }

        if (-not $response) {
            Write-TestResult -Name "Jira[$label]: Path A - response polled within 30s" -Status Fail -Message "Timed out polling /responses"
            return
        }

        Write-TestResult -Name "Jira[$label]: Path A - response polled within 30s" -Status Pass

        $attachDir = Join-Path $botDir "workspace\product\attachments\$($sendResult.question_id)"
        $resolved = Resolve-NotificationAnswer -Response $response -Settings $settings -AttachDir $attachDir

        if (-not $resolved) {
            Write-TestResult -Name "Jira[$label]: Path A - Resolve-NotificationAnswer returned a result" -Status Fail -Message "null"
            return
        }

        Write-TestResult -Name "Jira[$label]: Path A - Resolve-NotificationAnswer returned a result" -Status Pass
        Assert-Equal -Name "Jira[$label]: Path A - resolved attachments count == 1" -Expected 1 -Actual @($resolved.attachments).Count
        Assert-Equal -Name "Jira[$label]: Path A - answer contains 'approve'" -Expected $true -Actual ($resolved.answer -match 'approve')

        $localFile = Join-Path $attachDir $Fixture.File
        Assert-PathExists -Name "Jira[$label]: Path A - attachment saved at $($Fixture.File)" -Path $localFile

        if (Test-Path $localFile) {
            Assert-Equal -Name "Jira[$label]: Path A - saved byte size matches fixture" -Expected $fixtureSize -Actual (Get-Item $localFile).Length
            Assert-Equal -Name "Jira[$label]: Path A - SHA-256 matches fixture" `
                -Expected $sourceHash -Actual (Get-FileHash -Path $localFile -Algorithm SHA256).Hash
        }

        try {
            $mintBody = @{
                projectId      = $sendResult.project_id
                instanceId     = $sendResult.instance_id
                recipientEmail = $Recipient
            }
            $mint = Invoke-RestMethod -Uri "$($ServerUrl.TrimEnd('/'))/api/test/magic-link" -Method Post `
                -Body ($mintBody | ConvertTo-Json -Depth 5) -ContentType "application/json" `
                -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 10

            if (-not $mint.token) {
                Write-TestResult -Name "Jira[$label]: Path B - minted magic-link token" -Status Fail -Message "No token returned"
                return
            }

            Write-TestResult -Name "Jira[$label]: Path B - minted magic-link token" -Status Pass
        } catch {
            Write-TestResult -Name "Jira[$label]: Path B - minted magic-link token" -Status Fail -Message $_.Exception.Message
            return
        }

        $respondUri = "$($ServerUrl.TrimEnd('/'))/respond?instanceId=$($sendResult.instance_id)" +
                      "&projectId=$([uri]::EscapeDataString($sendResult.project_id))" +
                      "&questionId=$($sendResult.question_id)" +
                      "&token=$([uri]::EscapeDataString($mint.token))"

        $httpHandler = [System.Net.Http.HttpClientHandler]::new()
        $httpHandler.AllowAutoRedirect = $true
        $httpClient = [System.Net.Http.HttpClient]::new($httpHandler)
        $httpClient.Timeout = [TimeSpan]::FromSeconds(15)

        try {
            $multipart = [System.Net.Http.MultipartFormDataContent]::new()
            $multipart.Add([System.Net.Http.StringContent]::new("approve"), "selectedKey")
            $multipart.Add([System.Net.Http.StringContent]::new("Path B approval from $label fixture"), "freeText")
            $fileContent = [System.Net.Http.ByteArrayContent]::new($fixtureBytes)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/octet-stream")
            $multipart.Add($fileContent, "attachment", $Fixture.File)

            $httpResponse = $httpClient.PostAsync($respondUri, $multipart).GetAwaiter().GetResult()

            if (-not $httpResponse.IsSuccessStatusCode) {
                $errBody = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                Write-TestResult -Name "Jira[$label]: Path B - POST /respond returned 2xx" -Status Fail `
                    -Message "HTTP $([int]$httpResponse.StatusCode): $($errBody.Substring(0, [Math]::Min(200, $errBody.Length)))"
                return
            }

            Write-TestResult -Name "Jira[$label]: Path B - POST /respond returned 2xx" -Status Pass
        } catch {
            Write-TestResult -Name "Jira[$label]: Path B - POST /respond" -Status Fail -Message $_.Exception.Message
            return
        } finally {
            $httpClient.Dispose()
            $httpHandler.Dispose()
        }

        try {
            $allResponses = Invoke-RestMethod -Uri "$($ServerUrl.TrimEnd('/'))/api/instances/$($sendResult.project_id)/$($sendResult.question_id)/$($sendResult.instance_id)/responses" `
                -Method Get -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 10
            $webResponse = @($allResponses) | Where-Object { $_.responderEmail -eq $Recipient -and $_.freeText -like "Path B approval*" } | Select-Object -Last 1

            if (-not $webResponse) {
                Write-TestResult -Name "Jira[$label]: Path B - web response surfaced at /responses" -Status Fail -Message "No Path B response with responderEmail=$Recipient found"
                return
            }

            Write-TestResult -Name "Jira[$label]: Path B - web response surfaced at /responses" -Status Pass
            Assert-Equal -Name "Jira[$label]: Path B - web response attachments count == 1" `
                -Expected 1 -Actual @($webResponse.attachments).Count
            Assert-Equal -Name "Jira[$label]: Path B - web response selectedKey is 'approve'" `
                -Expected "approve" -Actual $webResponse.selectedKey
        } catch {
            Write-TestResult -Name "Jira[$label]: Path B - fetch /responses" -Status Fail -Message $_.Exception.Message
            return
        }

        $pathBAttachDir = Join-Path $botDir "workspace\product\attachments\$($sendResult.question_id)-pathb"
        $pathBResolved = Resolve-NotificationAnswer -Response $webResponse -Settings $settings -AttachDir $pathBAttachDir

        if ($pathBResolved -and @($pathBResolved.attachments).Count -eq 1) {
            $pathBFile = Join-Path $pathBAttachDir $Fixture.File

            if (Test-Path $pathBFile) {
                Assert-Equal -Name "Jira[$label]: Path B - SHA-256 matches fixture" `
                    -Expected $sourceHash -Actual (Get-FileHash -Path $pathBFile -Algorithm SHA256).Hash
            } else {
                Write-TestResult -Name "Jira[$label]: Path B - SHA-256 matches fixture" -Status Fail -Message "Downloaded file missing at $pathBFile"
            }
        } else {
            Write-TestResult -Name "Jira[$label]: Path B - SHA-256 matches fixture" -Status Fail -Message "Could not resolve Path B attachment"
        }

        if ($env:DOTBOT_REQUIRE_REAL_DELIVERY -eq "true") {
            try {
                $instance = Invoke-RestMethod -Uri "$($ServerUrl.TrimEnd('/'))/api/instances/$($sendResult.project_id)/$($sendResult.instance_id)" `
                    -Method Get -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 15
                $delivered = @($instance.sentTo | Where-Object { $_.status -eq 'sent' -or $_.status -eq 'reminded' })
                Assert-Equal -Name "Jira[$label]: delivered to >= 1 recipient (Tier 3)" `
                    -Expected $true -Actual ($delivered.Count -ge 1)
            } catch {
                Write-TestResult -Name "Jira[$label]: real delivery assertion (Tier 3)" -Status Fail -Message $_.Exception.Message
            }
        }

    } finally {
        Get-Module NotificationClient -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $testProject
    }
}

foreach ($f in $fixtures) {
    Write-Host "  ROUND-TRIP: $($f.Label)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Invoke-JiraRoundTrip -Fixture $f -ServerUrl $serverUrl -ApiKey $apiKey `
        -IssueKey $jiraIssueKey -Recipient $jiraEmailRecipient -DotbotDir $dotbotDir -FixturesDir $fixturesDir
    Write-Host ""
}

$allPassed = Write-TestSummary -LayerName "Layer 4: E2E Jira Q&A"

if (-not $allPassed) {
    exit 1
}


