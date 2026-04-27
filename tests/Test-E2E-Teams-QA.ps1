#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 4: End-to-end test for the MS Teams Q&A round-trip with attachments.
.DESCRIPTION
    For each fixture (markdown, PDF, image), creates a fresh dotbot project
    configured against a real DotbotServer, sends a Teams notification via
    Send-TaskNotification, injects a simulated reply through the test-mode
    endpoint POST /api/test/responses, polls Get-TaskNotificationResponse,
    then asserts Resolve-NotificationAnswer downloads the attachment.

    Required env: DOTBOT_SERVER_URL, DOTBOT_API_KEY,
    DOTBOT_TEAMS_RECIPIENT. Optional: DOTBOT_TEAMS_CHANNEL.
    The server must be started with DOTBOT_TEST_MODE=true.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 4: E2E MS Teams Q&A with Attachments" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$serverUrl      = $env:DOTBOT_SERVER_URL
$apiKey         = $env:DOTBOT_API_KEY
$teamsRecipient = $env:DOTBOT_TEAMS_RECIPIENT
$teamsChannel   = if ($env:DOTBOT_TEAMS_CHANNEL) { $env:DOTBOT_TEAMS_CHANNEL } else { "teams" }

$missing = @()

if (-not $serverUrl) {
    $missing += "DOTBOT_SERVER_URL"
}

if (-not $apiKey) {
    $missing += "DOTBOT_API_KEY"
}

if (-not $teamsRecipient) {
    $missing += "DOTBOT_TEAMS_RECIPIENT"
}

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 4 Teams prerequisites" -Status Fail -Message "dotbot not installed globally"
    Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A" | Out-Null
    exit 1
}

if ($missing.Count -gt 0) {
    Write-TestResult -Name "Layer 4 Teams prerequisites" -Status Skip `
        -Message "Missing env var(s): $($missing -join ', ')"
    Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A" | Out-Null
    exit 0
}

try {
    $null = Invoke-RestMethod -Uri "$($serverUrl.TrimEnd('/'))/api/health" -Method Get -TimeoutSec 5
} catch {
    Write-TestResult -Name "Layer 4 Teams prerequisites" -Status Skip `
        -Message "DotbotServer at $serverUrl is not reachable: $($_.Exception.Message)"
    Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A" | Out-Null
    exit 0
}

try {
    $probeResp = Invoke-WebRequest -Uri "$($serverUrl.TrimEnd('/'))/api/test/responses" `
        -Method Post -Body "{}" -ContentType "application/json" `
        -Headers @{ "X-Api-Key" = $apiKey } -TimeoutSec 5 -SkipHttpErrorCheck
    if ($probeResp.StatusCode -eq 404) {
        Write-TestResult -Name "Layer 4 Teams prerequisites" -Status Skip `
            -Message "Server is missing /api/test/responses - start it with DOTBOT_TEST_MODE=true"
        Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A" | Out-Null
        exit 0
    }
    if ($probeResp.StatusCode -eq 401) {
        Write-TestResult -Name "Layer 4 Teams prerequisites" -Status Fail `
            -Message "Server rejected DOTBOT_API_KEY (401). Check ApiSecurity:ApiKey."
        Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A" | Out-Null
        exit 1
    }
} catch {
    Write-TestResult -Name "Layer 4 Teams prerequisites" -Status Skip `
        -Message "Probe failed: $($_.Exception.Message)"
    Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A" | Out-Null
    exit 0
}

Write-Host "  SETUP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "    Server   : $serverUrl" -ForegroundColor DarkGray
Write-Host "    Channel  : $teamsChannel" -ForegroundColor DarkGray
Write-Host "    Recipient: $teamsRecipient" -ForegroundColor DarkGray
Write-Host ""

$fixturesDir = Join-Path $PSScriptRoot "fixtures\attachments"
$fixtures = @(
    @{ Label = "markdown"; File = "sample.md";  Key = "md"    }
    @{ Label = "pdf";      File = "sample.pdf"; Key = "pdf"   }
    @{ Label = "image";    File = "sample.png"; Key = "image" }
)

foreach ($f in $fixtures) {
    Assert-PathExists -Name "Teams: fixture '$($f.File)' present" -Path (Join-Path $fixturesDir $f.File)
}

function Invoke-TeamsRoundTrip {
    param(
        [Parameter(Mandatory)] [hashtable]$Fixture,
        [Parameter(Mandatory)] [string]$ServerUrl,
        [Parameter(Mandatory)] [string]$ApiKey,
        [Parameter(Mandatory)] [string]$Recipient,
        [Parameter(Mandatory)] [string]$Channel,
        [Parameter(Mandatory)] [string]$DotbotDir,
        [Parameter(Mandatory)] [string]$FixturesDir
    )

    $label = $Fixture.Label
    $testProject = New-TestProject -Prefix "dotbot-teams-$($Fixture.Key)"

    try {
        Push-Location $testProject
        try {
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $DotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        $botDir = Join-Path $testProject ".bot"
        if (-not (Test-Path $botDir)) {
            Write-TestResult -Name "Teams[$label]: .bot initialized" -Status Fail -Message ".bot missing after init-project.ps1"
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
                channel               = $Channel
                recipients            = @($Recipient)
                project_name          = "dotbot-test-$label"
                project_description   = "Layer 4 Teams round-trip fixture: $label"
                poll_interval_seconds = 2
                sync_tasks            = $false
                sync_questions        = $true
            }
        }
        ($control | ConvertTo-Json -Depth 10) | Set-Content -Path (Join-Path $controlDir "settings.json") -Encoding UTF8

        $notifModule = Join-Path $botDir "core/mcp/modules/NotificationClient.psm1"
        if (-not (Test-Path $notifModule)) {
            Write-TestResult -Name "Teams[$label]: NotificationClient.psm1 present" -Status Fail -Message "Module missing at $notifModule"
            return
        }
        $global:DotbotProjectRoot = $testProject
        Import-Module $notifModule -Force -DisableNameChecking

        $settings = Get-NotificationSettings -BotRoot $botDir
        Assert-Equal -Name "Teams[$label]: settings.enabled resolves" -Expected $true -Actual $settings.enabled
        Assert-Equal -Name "Teams[$label]: settings.channel resolves" -Expected $Channel -Actual $settings.channel

        $questionLocalId = "q-$label-$([guid]::NewGuid().Guid.Substring(0,8))"
        $taskId = "task-$label-$([guid]::NewGuid().Guid.Substring(0,8))"
        $taskContent = [pscustomobject]@{
            id   = $taskId
            name = "Teams E2E fixture: $label"
        }
        $pendingQuestion = [pscustomobject]@{
            id             = $questionLocalId
            question       = "Teams E2E: please attach the $label fixture and choose 'accept'."
            context        = "Layer 4 round-trip test. Operator reply simulated via /api/test/responses."
            options        = @(
                [pscustomobject]@{ key = "accept"; label = "Accept"; rationale = "Confirm the attachment uploaded." }
                [pscustomobject]@{ key = "reject"; label = "Reject"; rationale = "Should not be picked in this test." }
            )
            recommendation = "accept"
        }

        $sendResult = Send-TaskNotification -TaskContent $taskContent -PendingQuestion $pendingQuestion -Settings $settings
        if (-not $sendResult.success) {
            Write-TestResult -Name "Teams[$label]: Send-TaskNotification succeeded" -Status Fail -Message $sendResult.reason
            return
        }
        Write-TestResult -Name "Teams[$label]: Send-TaskNotification succeeded" -Status Pass

        $fixturePath = Join-Path $FixturesDir $Fixture.File
        $fixtureBytes = [IO.File]::ReadAllBytes($fixturePath)
        $fixtureSize = [int64]$fixtureBytes.LongLength
        $injectBody = @{
            projectId    = $sendResult.project_id
            questionId   = $sendResult.question_id
            instanceId   = $sendResult.instance_id
            selectedKey  = "accept"
            freeText     = $null
            attachments  = @(
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
            Write-TestResult -Name "Teams[$label]: injected simulated response" -Status Pass
        } catch {
            Write-TestResult -Name "Teams[$label]: injected simulated response" -Status Fail -Message $_.Exception.Message
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
            Write-TestResult -Name "Teams[$label]: response polled within 30s" -Status Fail -Message "Timed out polling /responses"
            return
        }
        Write-TestResult -Name "Teams[$label]: response polled within 30s" -Status Pass

        $attachDir = Join-Path $botDir "workspace\product\attachments\$($sendResult.question_id)"
        $resolved = Resolve-NotificationAnswer -Response $response -Settings $settings -AttachDir $attachDir
        if (-not $resolved) {
            Write-TestResult -Name "Teams[$label]: Resolve-NotificationAnswer returned a result" -Status Fail -Message "null"
            return
        }
        Write-TestResult -Name "Teams[$label]: Resolve-NotificationAnswer returned a result" -Status Pass
        Assert-Equal -Name "Teams[$label]: resolved attachments count == 1" -Expected 1 -Actual @($resolved.attachments).Count

        $localFile = Join-Path $attachDir $Fixture.File
        Assert-PathExists -Name "Teams[$label]: attachment saved at $($Fixture.File)" -Path $localFile
        if (Test-Path $localFile) {
            $savedSize = (Get-Item $localFile).Length
            Assert-Equal -Name "Teams[$label]: saved byte size matches fixture" -Expected $fixtureSize -Actual $savedSize

            $sourceHash = (Get-FileHash -Path $fixturePath -Algorithm SHA256).Hash
            $savedHash  = (Get-FileHash -Path $localFile -Algorithm SHA256).Hash
            Assert-Equal -Name "Teams[$label]: SHA-256 matches fixture" -Expected $sourceHash -Actual $savedHash
        }

        if ($env:DOTBOT_REQUIRE_REAL_DELIVERY -eq "true") {
            try {
                $instance = Invoke-RestMethod -Uri "$($ServerUrl.TrimEnd('/'))/api/instances/$($sendResult.project_id)/$($sendResult.instance_id)" `
                    -Method Get -Headers @{ "X-Api-Key" = $ApiKey } -TimeoutSec 15
                $delivered = @($instance.sentTo | Where-Object { $_.status -eq 'sent' -or $_.status -eq 'reminded' })
                Assert-Equal -Name "Teams[$label]: delivered to >= 1 recipient (Tier 3)" `
                    -Expected $true -Actual ($delivered.Count -ge 1)
            } catch {
                Write-TestResult -Name "Teams[$label]: real delivery assertion (Tier 3)" -Status Fail -Message $_.Exception.Message
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
    Invoke-TeamsRoundTrip -Fixture $f -ServerUrl $serverUrl -ApiKey $apiKey `
        -Recipient $teamsRecipient -Channel $teamsChannel -DotbotDir $dotbotDir -FixturesDir $fixturesDir
    Write-Host ""
}

$allPassed = Write-TestSummary -LayerName "Layer 4: E2E Teams Q&A"

if (-not $allPassed) {
    exit 1
}


