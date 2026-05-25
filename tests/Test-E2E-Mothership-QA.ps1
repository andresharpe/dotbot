#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 5: Mothership web UI E2E — Playwright against live server + Azurite.
.DESCRIPTION
    Starts the DotbotServer against a local Azurite instance, seeds the blob
    containers, then runs Playwright specs that navigate the magic-link respond
    flow for each question type (singleChoice, approval, documentReview).

    For each question type the script:
      1. POST /api/templates  — creates a template
      2. POST /api/instances  — publishes an instance (no real delivery)
      3. POST /api/test/magic-link — mints a JWT for the test recipient
      4. Exports the magic-link URL to DOTBOT_MOTHERSHIP_RESPOND_URL
      5. Playwright navigates the URL, fills the form, submits
      6. Asserts the response payload at GET /api/instances/.../responses

    Required env:
        DOTBOT_SERVER_URL   — base URL of a running DotbotServer
                              (e.g. http://localhost:5048)
        DOTBOT_API_KEY      — value of ApiSecurity:ApiKey in appsettings

    Optional:
        DOTBOT_START_SERVER — set to "true" to start the server from source
                              (requires dotnet SDK and Azurite already running)

    The server must be started with DOTBOT_TEST_MODE=true so that
    /api/test/* endpoints are enabled.
#>

[CmdletBinding()]
param(
    [switch]$Headed
)

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$e2eDir = Join-Path $PSScriptRoot "e2e"

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 5: Mothership Web UI E2E (Playwright)" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════

$serverUrl = $env:DOTBOT_SERVER_URL
$apiKey    = $env:DOTBOT_API_KEY
$missing   = @()

if (-not $serverUrl) { $missing += "DOTBOT_SERVER_URL" }
if (-not $apiKey)    { $missing += "DOTBOT_API_KEY" }

if ($missing.Count -gt 0) {
    Write-TestResult -Name "Mothership prerequisites" -Status Skip `
        -Message "Missing env var(s): $($missing -join ', ')"
    Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
    exit 0
}

if (-not (Get-Command node -ErrorAction SilentlyContinue) -or
    -not (Get-Command npm  -ErrorAction SilentlyContinue) -or
    -not (Get-Command npx  -ErrorAction SilentlyContinue)) {
    Write-TestResult -Name "Mothership prerequisites" -Status Fail `
        -Message "node/npm/npx not in PATH — install Node.js 18+"
    Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
    exit 1
}

if (-not (Test-Path (Join-Path $e2eDir "package.json"))) {
    Write-TestResult -Name "Mothership prerequisites" -Status Fail `
        -Message "tests/e2e/package.json missing"
    Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
    exit 1
}

# Health check
try {
    $null = Invoke-RestMethod -Uri "$($serverUrl.TrimEnd('/'))/api/health" -Method Get -TimeoutSec 5
} catch {
    Write-TestResult -Name "Mothership prerequisites" -Status Skip `
        -Message "DotbotServer at $serverUrl is not reachable: $($_.Exception.Message)"
    Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
    exit 0
}

# Check DOTBOT_TEST_MODE endpoints available
foreach ($probePath in @('/api/test/magic-link')) {
    try {
        $probe = Invoke-WebRequest -Uri "$($serverUrl.TrimEnd('/'))$probePath" `
            -Method Post -Body "{}" -ContentType "application/json" `
            -Headers @{ "X-Api-Key" = $apiKey } -TimeoutSec 5 -SkipHttpErrorCheck
        if ($probe.StatusCode -eq 404) {
            Write-TestResult -Name "Mothership prerequisites" -Status Skip `
                -Message "Server missing $probePath — start with DOTBOT_TEST_MODE=true"
            Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
            exit 0
        }
        if ($probe.StatusCode -eq 401) {
            Write-TestResult -Name "Mothership prerequisites" -Status Fail `
                -Message "Server rejected DOTBOT_API_KEY (401). Check ApiSecurity:ApiKey."
            Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
            exit 1
        }
    } catch {
        Write-TestResult -Name "Mothership prerequisites" -Status Skip `
            -Message "Probe $probePath failed: $($_.Exception.Message)"
        Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
        exit 0
    }
}

# ═══════════════════════════════════════════════════════════════════
# AUTO-INSTALL: npm deps + Playwright Chromium browser
# ═══════════════════════════════════════════════════════════════════

$playwrightInstalled = Test-Path (Join-Path $e2eDir "node_modules/@playwright/test")
if (-not $playwrightInstalled) {
    $packageLockPath = Join-Path $e2eDir "package-lock.json"
    $npmCommand = if (Test-Path $packageLockPath) { "ci" } else { "install" }
    Write-Host "  → Installing Playwright npm dependencies (one-time)..." -ForegroundColor Cyan
    Push-Location $e2eDir
    try {
        & npm $npmCommand --no-audit --no-fund --loglevel=error 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "npm $npmCommand failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

$browserCacheRoot = if ($IsWindows) {
    Join-Path $env:LOCALAPPDATA "ms-playwright"
} else {
    Join-Path $HOME ".cache/ms-playwright"
}
$chromiumCached = (Test-Path $browserCacheRoot) -and `
    @(Get-ChildItem -Path $browserCacheRoot -Directory -Filter "chromium-*" -ErrorAction SilentlyContinue).Count -gt 0
if (-not $chromiumCached) {
    Write-Host "  → Installing Playwright Chromium browser (~150 MB, one-time)..." -ForegroundColor Cyan
    Push-Location $e2eDir
    try {
        & npx --no-install playwright install --with-deps chromium 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Playwright browser install failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
}

# ═══════════════════════════════════════════════════════════════════
# QUESTION TYPE FIXTURES
# ═══════════════════════════════════════════════════════════════════

$testRecipient = "playwright-test@test.local"
$projectId     = "playwright-e2e"

$questionTypes = @(
    @{
        Type    = "singleChoice"
        Title   = "Playwright E2E: singleChoice"
        Options = @(
            @{ key = "option_a"; label = "Option A" }
            @{ key = "option_b"; label = "Option B" }
        )
        Submit  = @{ selectedKey = "option_a" }
    }
    @{
        Type    = "multiChoice"
        Title   = "Playwright E2E: multiChoice"
        Options = @(
            @{ key = "opt_a"; label = "Alpha" }
            @{ key = "opt_b"; label = "Beta" }
            @{ key = "opt_c"; label = "Gamma" }
        )
        Submit  = @{ selectedKey = "opt_a" }
    }
    @{
        Type               = "approval"
        Title              = "Playwright E2E: approval"
        DeliverableSummary = "Playwright E2E test deliverable for approval"
        Options = @(
            @{ key = "approve"; label = "Approve" }
            @{ key = "reject";  label = "Reject"  }
            @{ key = "abstain"; label = "Abstain" }
        )
        Submit  = @{ approvalDecision = "approve" }
    }
    @{
        Type               = "documentReview"
        Title              = "Playwright E2E: documentReview"
        DeliverableSummary = "Playwright E2E test deliverable for documentReview"
        Options = @(
            @{ key = "approve"; label = "Approve" }
            @{ key = "reject";  label = "Reject"  }
        )
        Submit  = @{ approvalDecision = "approve" }
    }
    @{
        Type   = "freeText"
        Title  = "Playwright E2E: freeText"
        Submit = @{ freeText = "Playwright free text answer" }
    }
    @{
        Type    = "priorityRanking"
        Title   = "Playwright E2E: priorityRanking"
        Options = @(
            @{ key = "item_1"; label = "Item One" }
            @{ key = "item_2"; label = "Item Two" }
            @{ key = "item_3"; label = "Item Three" }
        )
        Submit  = @{}  # rankedItems built from real optionIds after New-Template
    }
)

# ═══════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════

function New-Template {
    param([hashtable]$Qt, [string]$Url, [string]$Key)

    $options = @()
    if ($Qt.ContainsKey('Options')) {
        $options = $Qt.Options | ForEach-Object {
            @{
                optionId = [guid]::NewGuid().ToString()
                key      = $_.key
                title    = $_.label
            }
        }
    }

    $body = @{
        questionId         = [guid]::NewGuid().ToString()
        version            = 1
        type               = $Qt.Type
        title              = $Qt.Title
        context            = "Playwright E2E test fixture"
        deliverableSummary = if ($Qt.ContainsKey('DeliverableSummary')) { $Qt.DeliverableSummary } else { $null }
        options            = @($options)
        project            = @{
            projectId = $projectId
            name      = "Playwright E2E Project"
        }
        status             = "published"
    }

    $response = Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/templates" -Method Post `
        -Body ($body | ConvertTo-Json -Depth 10) -ContentType "application/json" `
        -Headers @{ "X-Api-Key" = $Key } -TimeoutSec 10

    return @{
        QuestionId = $body.questionId
        Version    = 1
        OptionIds  = $options | ForEach-Object { $_.optionId }
    }
}

function New-Instance {
    param([string]$QuestionId, [int]$Version, [string]$Url, [string]$Key)

    # Use 'teams' channel — always registered even without Bot Framework config.
    # Delivery will fail gracefully but the instance record is persisted first,
    # so /respond can still render it.
    $body = @{
        projectId       = $projectId
        questionId      = $QuestionId
        questionVersion = $Version
        channel         = "teams"
        recipients      = @{ emails = @($testRecipient) }
    }

    $response = Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/instances" -Method Post `
        -Body ($body | ConvertTo-Json -Depth 10) -ContentType "application/json" `
        -Headers @{ "X-Api-Key" = $Key } -TimeoutSec 15

    return $response.instanceId.ToString()
}

function Get-MagicLinkToken {
    param([string]$QuestionId, [string]$InstanceId, [string]$Url, [string]$Key)

    $body = @{
        projectId      = $projectId
        instanceId     = $InstanceId
        recipientEmail = $testRecipient
    }

    $response = Invoke-RestMethod -Uri "$($Url.TrimEnd('/'))/api/test/magic-link" -Method Post `
        -Body ($body | ConvertTo-Json -Depth 5) -ContentType "application/json" `
        -Headers @{ "X-Api-Key" = $Key } -TimeoutSec 10

    return $response.token
}

# ═══════════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SETUP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "    Server    : $serverUrl" -ForegroundColor DarkGray
Write-Host "    Recipient : $testRecipient" -ForegroundColor DarkGray
Write-Host "    Project   : $projectId" -ForegroundColor DarkGray
Write-Host ""

$exitCode = 1

try {
    # Build scenario manifest for Playwright
    $scenarios = @()

    foreach ($qt in $questionTypes) {
        $label = $qt.Type
        Write-Host "  SEEDING: $label" -ForegroundColor Cyan

        try {
            $tmpl = New-Template -Qt $qt -Url $serverUrl -Key $apiKey
            Write-TestResult -Name "Mothership[$label]: template created" -Status Pass
        } catch {
            Write-TestResult -Name "Mothership[$label]: template created" -Status Fail -Message $_.Exception.Message
            continue
        }

        try {
            $instanceId = New-Instance -QuestionId $tmpl.QuestionId -Version $tmpl.Version -Url $serverUrl -Key $apiKey
            Write-TestResult -Name "Mothership[$label]: instance created" -Status Pass
        } catch {
            Write-TestResult -Name "Mothership[$label]: instance created" -Status Fail -Message $_.Exception.Message
            continue
        }

        try {
            $token = Get-MagicLinkToken -QuestionId $tmpl.QuestionId -InstanceId $instanceId -Url $serverUrl -Key $apiKey
            Write-TestResult -Name "Mothership[$label]: magic-link minted" -Status Pass
        } catch {
            Write-TestResult -Name "Mothership[$label]: magic-link minted" -Status Fail -Message $_.Exception.Message
            continue
        }

        $respondUrl = "$($serverUrl.TrimEnd('/'))/respond?instanceId=$instanceId" +
                      "&projectId=$([uri]::EscapeDataString($projectId))" +
                      "&questionId=$($tmpl.QuestionId)" +
                      "&token=$([uri]::EscapeDataString($token))"

        # For priorityRanking, build rankedItems from the actual generated optionIds
        $submit = $qt.Submit.Clone()
        if ($qt.Type -eq 'priorityRanking' -and $tmpl.OptionIds) {
            $rank = 1
            $submit.rankedItems = $tmpl.OptionIds | ForEach-Object {
                @{ optionId = $_; rank = $rank++ }
            }
        }

        $scenarios += @{
            type         = $qt.Type
            title        = $qt.Title
            questionId   = $tmpl.QuestionId
            instanceId   = $instanceId
            respondUrl   = $respondUrl
            submit       = $submit
            responsesUrl = "$($serverUrl.TrimEnd('/'))/api/instances/$projectId/$($tmpl.QuestionId)/$instanceId/responses"
            injectUrl    = "$($serverUrl.TrimEnd('/'))/api/test/responses"
            apiKey       = $apiKey
        }

        Write-Host ""
    }

    if ($scenarios.Count -eq 0) {
        Write-TestResult -Name "Mothership: scenario setup" -Status Fail -Message "No scenarios seeded successfully"
        Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null
        exit 1
    }

    # Write manifest for Playwright to consume
    $manifestPath = Join-Path $e2eDir "mothership-scenarios.json"
    $scenarios | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8

    Write-Host "  PLAYWRIGHT" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $env:DOTBOT_E2E_URL               = $serverUrl
    $env:DOTBOT_MOTHERSHIP_SCENARIOS  = $manifestPath

    Push-Location $e2eDir
    try {
        if ($Headed) { $env:PLAYWRIGHT_HEADED = "1" }
        $playwrightArgs = @("--no-install", "playwright", "test", "specs/mothership-question-flow.spec.ts")
        & npx @playwrightArgs 2>&1 | Out-Host
        Remove-Item Env:\PLAYWRIGHT_HEADED -ErrorAction SilentlyContinue
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        Remove-Item Env:\DOTBOT_E2E_URL              -ErrorAction SilentlyContinue
        Remove-Item Env:\DOTBOT_MOTHERSHIP_SCENARIOS -ErrorAction SilentlyContinue
        Remove-Item $manifestPath                    -ErrorAction SilentlyContinue
    }

} catch {
    Write-Host "  ✗ Mothership E2E setup failed: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "  Layer 5 Mothership: ✓ ALL PASSED" -ForegroundColor Green
} else {
    Write-Host "  Layer 5 Mothership: ✗ FAILED (Playwright exit $exitCode)" -ForegroundColor Red
    Write-Host "  HTML report: $e2eDir/playwright-report/index.html" -ForegroundColor DarkGray
    Write-Host "  Traces:      $e2eDir/test-results/" -ForegroundColor DarkGray
}
Write-Host ""

Write-TestSummary -LayerName "Layer 5: Mothership Web UI E2E" | Out-Null

exit $exitCode
