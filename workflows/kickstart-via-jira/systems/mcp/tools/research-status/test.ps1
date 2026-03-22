# Test research-status tool

. "$PSScriptRoot\script.ps1"

Write-Host "Testing research-status..." -ForegroundColor Cyan

# Set up isolated test root
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-research-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

$briefingDir = Join-Path $testRoot ".bot\workspace\product\briefing"
$productDir = Join-Path $testRoot ".bot\workspace\product"
New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null

try {
    # Test 1: Empty briefing → not-started
    Write-Host "`n1. Empty briefing directory"
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.success -and $result.phase -eq "not-started") {
        Write-Host "   PASS: Phase is 'not-started'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'not-started', got '$($result.phase)'" -ForegroundColor Red
    }
    if ($result.required_missing.Count -eq 4) {
        Write-Host "   PASS: 4 required artifacts missing" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 4 required missing, got $($result.required_missing.Count)" -ForegroundColor Red
    }

    # Test 2: Create jira-context.md → kickstarted
    Write-Host "`n2. jira-context.md only -> kickstarted"
    "# Initiative" | Set-Content (Join-Path $briefingDir "jira-context.md")
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.phase -eq "kickstarted") {
        Write-Host "   PASS: Phase is 'kickstarted'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'kickstarted', got '$($result.phase)'" -ForegroundColor Red
    }

    # Test 3: Add mission.md → planned
    Write-Host "`n3. Add mission.md -> planned"
    "# Mission" | Set-Content (Join-Path $productDir "mission.md")
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.phase -eq "planned") {
        Write-Host "   PASS: Phase is 'planned'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'planned', got '$($result.phase)'" -ForegroundColor Red
    }

    # Test 4: Add 3 core research files → research-complete
    Write-Host "`n4. Add core research files -> research-complete"
    "# Internet" | Set-Content (Join-Path $productDir "research-internet.md")
    "# Documents" | Set-Content (Join-Path $productDir "research-documents.md")
    "# Repos" | Set-Content (Join-Path $productDir "research-repos.md")
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.phase -eq "research-complete") {
        Write-Host "   PASS: Phase is 'research-complete'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'research-complete', got '$($result.phase)'" -ForegroundColor Red
    }
    if ($result.required_missing.Count -eq 0) {
        Write-Host "   PASS: No required artifacts missing" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Still missing: $($result.required_missing -join ', ')" -ForegroundColor Red
    }

    # Test 5: Add deep dive → deep-dives-in-progress
    Write-Host "`n5. Add deep dive report -> deep-dives-in-progress"
    $reposBriefing = Join-Path $briefingDir "repos"
    New-Item -Path $reposBriefing -ItemType Directory -Force | Out-Null
    "# FakeRepo deep dive" | Set-Content (Join-Path $reposBriefing "FakeRepo.md")
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.phase -eq "deep-dives-in-progress") {
        Write-Host "   PASS: Phase is 'deep-dives-in-progress'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'deep-dives-in-progress', got '$($result.phase)'" -ForegroundColor Red
    }
    if ($result.deep_dive_count -eq 1) {
        Write-Host "   PASS: 1 deep dive found" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 1 deep dive, got $($result.deep_dive_count)" -ForegroundColor Red
    }

    # Test 6: Add implementation research → implementation-research-complete
    Write-Host "`n6. Add implementation research -> implementation-research-complete"
    "# Impl Research" | Set-Content (Join-Path $briefingDir "04_IMPLEMENTATION_RESEARCH.md")
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.phase -eq "implementation-research-complete") {
        Write-Host "   PASS: Phase is 'implementation-research-complete'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'implementation-research-complete', got '$($result.phase)'" -ForegroundColor Red
    }

    # Test 7: Add index → refined
    Write-Host "`n7. Add repos index -> refined"
    "# Index" | Set-Content (Join-Path $reposBriefing "00_INDEX.md")
    $result = Invoke-ResearchStatus -Arguments @{}
    if ($result.phase -eq "refined") {
        Write-Host "   PASS: Phase is 'refined'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 'refined', got '$($result.phase)'" -ForegroundColor Red
    }

} finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nTests complete." -ForegroundColor Cyan
