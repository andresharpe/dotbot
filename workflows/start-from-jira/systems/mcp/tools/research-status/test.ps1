# Test research-status tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-research-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

$briefingDir = Join-Path $testRoot ".bot\workspace\product\briefing"
$productDir = Join-Path $testRoot ".bot\workspace\product"
New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null

try {
    # Test 1: Empty briefing
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: empty is not-started" `
        -Expected "not-started" `
        -Actual $result.phase

    Assert-Equal -Name "research-status: 4 required artifacts missing" `
        -Expected 4 `
        -Actual $result.required_missing.Count

    # Test 2: jira-context.md -> kickstarted
    "# Initiative" | Set-Content (Join-Path $briefingDir "jira-context.md")
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: jira-context is kickstarted" `
        -Expected "kickstarted" `
        -Actual $result.phase

    # Test 3: Add mission.md -> planned
    "# Mission" | Set-Content (Join-Path $productDir "mission.md")
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: mission is planned" `
        -Expected "planned" `
        -Actual $result.phase

    # Test 4: Add core research files -> research-complete
    "# Internet" | Set-Content (Join-Path $productDir "research-internet.md")
    "# Documents" | Set-Content (Join-Path $productDir "research-documents.md")
    "# Repos" | Set-Content (Join-Path $productDir "research-repos.md")
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: core research is research-complete" `
        -Expected "research-complete" `
        -Actual $result.phase

    Assert-Equal -Name "research-status: no required artifacts missing" `
        -Expected 0 `
        -Actual $result.required_missing.Count

    # Test 5: Add deep dive -> deep-dives-in-progress
    $reposBriefing = Join-Path $briefingDir "repos"
    New-Item -Path $reposBriefing -ItemType Directory -Force | Out-Null
    "# FakeRepo deep dive" | Set-Content (Join-Path $reposBriefing "FakeRepo.md")
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: deep dive is deep-dives-in-progress" `
        -Expected "deep-dives-in-progress" `
        -Actual $result.phase

    Assert-Equal -Name "research-status: deep_dive_count is 1" `
        -Expected 1 `
        -Actual $result.deep_dive_count

    # Test 6: Add implementation research -> implementation-research-complete
    "# Impl Research" | Set-Content (Join-Path $briefingDir "04_IMPLEMENTATION_RESEARCH.md")
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: impl research is implementation-research-complete" `
        -Expected "implementation-research-complete" `
        -Actual $result.phase

    # Test 7: Add index -> refined
    "# Index" | Set-Content (Join-Path $reposBriefing "00_INDEX.md")
    $result = Invoke-ResearchStatus -Arguments @{}

    Assert-Equal -Name "research-status: index is refined" `
        -Expected "refined" `
        -Actual $result.phase

} finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "research-status"
if (-not $allPassed) { exit 1 }
