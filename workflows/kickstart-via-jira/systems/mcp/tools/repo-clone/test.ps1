# Test repo-clone tool
# NOTE: Actual cloning requires network + Azure DevOps PAT.
# This test validates argument parsing and graceful error handling only.

. "$PSScriptRoot\script.ps1"

Write-Host "Testing repo-clone..." -ForegroundColor Cyan

# Test 1: Missing 'project' parameter
Write-Host "`n1. Missing 'project' parameter"
$threwProject = $false
try {
    Invoke-RepoClone -Arguments @{ repo = "SomeRepo" }
} catch {
    if ($_.Exception.Message -like "*project*required*") {
        $threwProject = $true
    }
}
if ($threwProject) {
    Write-Host "   PASS: Throws for missing project" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw for missing project" -ForegroundColor Red
}

# Test 2: Missing 'repo' parameter
Write-Host "`n2. Missing 'repo' parameter"
$threwRepo = $false
try {
    Invoke-RepoClone -Arguments @{ project = "SomeProject" }
} catch {
    if ($_.Exception.Message -like "*repo*required*") {
        $threwRepo = $true
    }
}
if ($threwRepo) {
    Write-Host "   PASS: Throws for missing repo" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw for missing repo" -ForegroundColor Red
}

# Test 3: No credentials → graceful error
Write-Host "`n3. No credentials -> graceful error"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-clone-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

# Save and clear env vars
$savedOrg = $env:AZURE_DEVOPS_ORG_URL
$savedPat = $env:AZURE_DEVOPS_PAT
$env:AZURE_DEVOPS_ORG_URL = $null
$env:AZURE_DEVOPS_PAT = $null

$threwNoCreds = $false
try {
    Invoke-RepoClone -Arguments @{ project = "TestProject"; repo = "TestRepo" }
} catch {
    $threwNoCreds = $true
    Write-Host "   Error: $($_.Exception.Message)" -ForegroundColor Gray
}

# Restore env vars
$env:AZURE_DEVOPS_ORG_URL = $savedOrg
$env:AZURE_DEVOPS_PAT = $savedPat

if ($threwNoCreds) {
    Write-Host "   PASS: Throws when no credentials" -ForegroundColor Green
} else {
    Write-Host "   FAIL: Should throw when no credentials available" -ForegroundColor Red
}

# Cleanup
if (Test-Path $testRoot) {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`nTests complete." -ForegroundColor Cyan
