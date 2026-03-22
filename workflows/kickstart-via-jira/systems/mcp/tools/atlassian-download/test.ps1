# Test atlassian-download tool
# NOTE: Actual downloading requires network + Atlassian credentials.
# This test validates argument parsing and graceful error handling only.

. "$PSScriptRoot\script.ps1"

Write-Host "Testing atlassian-download..." -ForegroundColor Cyan

# Test 1: Missing 'jira_key' parameter
Write-Host "`n1. Missing 'jira_key' parameter"
$threwMissing = $false
try {
    Invoke-AtlassianDownload -Arguments @{}
} catch {
    if ($_.Exception.Message -like "*jira_key*required*") {
        $threwMissing = $true
    }
}
if ($threwMissing) {
    Write-Host "   PASS: Throws for missing jira_key" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw for missing jira_key" -ForegroundColor Red
}

# Test 2: No credentials -> graceful error
Write-Host "`n2. No credentials -> graceful error"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-atl-dl-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

# Save and clear env vars
$savedEmail = $env:ATLASSIAN_EMAIL
$savedToken = $env:ATLASSIAN_API_TOKEN
$savedCloud = $env:ATLASSIAN_CLOUD_ID
$env:ATLASSIAN_EMAIL = $null
$env:ATLASSIAN_API_TOKEN = $null
$env:ATLASSIAN_CLOUD_ID = $null

$threwNoCreds = $false
try {
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-123" }
} catch {
    $threwNoCreds = $true
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Gray
}

# Restore env vars
$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($threwNoCreds) {
    Write-Host "   PASS: Throws when no credentials" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw when no credentials available" -ForegroundColor Red
}

# Test 3: Custom target_dir parameter accepted
Write-Host "`n3. Custom target_dir is accepted"
$env:ATLASSIAN_EMAIL = "test@example.com"
$env:ATLASSIAN_API_TOKEN = "fake-token"
$env:ATLASSIAN_CLOUD_ID = "fake-cloud-id"

$threwApi = $false
try {
    # This will fail at the API call, but should not fail on arg parsing
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-123"; target_dir = "custom/docs" }
} catch {
    $threwApi = $true
}

# Verify the custom directory was created
$customDir = Join-Path $testRoot "custom\docs"
$dirCreated = Test-Path $customDir

$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($dirCreated) {
    Write-Host "   PASS: Custom target_dir created" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Custom target_dir was not created" -ForegroundColor Red
}

# Test 4: URL-format ATLASSIAN_CLOUD_ID is resolved to UUID
Write-Host "`n4. URL-format ATLASSIAN_CLOUD_ID resolves to UUID"
$env:ATLASSIAN_EMAIL = "test@example.com"
$env:ATLASSIAN_API_TOKEN = "fake-token"
$env:ATLASSIAN_CLOUD_ID = "https://mysite.atlassian.net"

try {
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-456" }
} catch {
    # API calls will fail with fake token — that's fine
}

$resolvedId = $env:ATLASSIAN_CLOUD_ID
$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($resolvedId -and $resolvedId -notmatch '\.atlassian\.net' -and $resolvedId -match '^[0-9a-f\-]{36}$') {
    Write-Host "   PASS: URL resolved to UUID ($resolvedId)" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Expected UUID, got: $resolvedId" -ForegroundColor Red
}

# Test 5: Bare domain (no https://) also resolves to UUID
Write-Host "`n5. Bare domain resolves to UUID"
$env:ATLASSIAN_EMAIL = "test@example.com"
$env:ATLASSIAN_API_TOKEN = "fake-token"
$env:ATLASSIAN_CLOUD_ID = "mysite.atlassian.net"

try {
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-789" }
} catch {
    # API calls will fail with fake token — that's fine
}

$resolvedIdBare = $env:ATLASSIAN_CLOUD_ID
$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($resolvedIdBare -and $resolvedIdBare -notmatch '\.atlassian\.net' -and $resolvedIdBare -match '^[0-9a-f\-]{36}$') {
    Write-Host "   PASS: Bare domain resolved to UUID ($resolvedIdBare)" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Expected UUID, got: $resolvedIdBare" -ForegroundColor Red
}

# Test 6: Invalid URL gives helpful error mentioning _edge/tenant_info
Write-Host "`n6. Invalid URL gives helpful error"
$env:ATLASSIAN_EMAIL = "test@example.com"
$env:ATLASSIAN_API_TOKEN = "fake-token"
$env:ATLASSIAN_CLOUD_ID = "https://this-does-not-exist-99999.atlassian.net"

$threwResolution = $false
$mentionsTenantInfo = $false
try {
    Invoke-AtlassianDownload -Arguments @{ jira_key = "TEST-000" }
} catch {
    $threwResolution = $true
    if ($_.Exception.Message -like "*_edge/tenant_info*") {
        $mentionsTenantInfo = $true
    }
}

$env:ATLASSIAN_EMAIL = $savedEmail
$env:ATLASSIAN_API_TOKEN = $savedToken
$env:ATLASSIAN_CLOUD_ID = $savedCloud

if ($threwResolution -and $mentionsTenantInfo) {
    Write-Host "   PASS: Helpful error with _edge/tenant_info reference" -ForegroundColor Green
} elseif ($threwResolution) {
    Write-Host "   WARN: Threw error but did not mention _edge/tenant_info" -ForegroundColor Yellow
} else {
    Write-Host "   SKIP: Domain resolved unexpectedly (network-dependent test)" -ForegroundColor Yellow
}

# Cleanup
if (Test-Path $testRoot) {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nTests complete." -ForegroundColor Cyan
