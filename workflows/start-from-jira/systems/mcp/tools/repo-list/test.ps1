# Test repo-list tool

Import-Module $env:DOTBOT_TEST_HELPERS -Force
. "$PSScriptRoot\script.ps1"

Reset-TestResults

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-repo-list-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

try {
    # Test 1: No repos/ directory
    $result = Invoke-RepoList -Arguments @{}

    Assert-True -Name "repo-list: empty when no repos/ directory" `
        -Condition ($result.success -and $result.count -eq 0 -and $result.repos.Count -eq 0) `
        -Message "Expected empty list, got count=$($result.count)"

    # Test 2: Empty repos/ directory
    $reposDir = Join-Path $testRoot "repos"
    New-Item -Path $reposDir -ItemType Directory -Force | Out-Null
    $result = Invoke-RepoList -Arguments @{}

    Assert-True -Name "repo-list: empty for empty repos/" `
        -Condition ($result.success -and $result.count -eq 0) `
        -Message "Expected empty list"

    # Test 3: Fake git repo in repos/
    $fakeRepo = Join-Path $reposDir "FakeRepo"
    New-Item -Path $fakeRepo -ItemType Directory -Force | Out-Null
    Push-Location $fakeRepo
    & git init --quiet 2>&1 | Out-Null
    & git config user.email "test@test.com" 2>&1 | Out-Null
    & git config user.name "Test" 2>&1 | Out-Null
    "test" | Set-Content "README.md"
    & git add -A 2>&1 | Out-Null
    & git commit -m "init" --quiet 2>&1 | Out-Null
    Pop-Location

    $result = Invoke-RepoList -Arguments @{}

    Assert-True -Name "repo-list: finds git repo" `
        -Condition ($result.success -and $result.count -eq 1) `
        -Message "Expected 1 repo, got count=$($result.count)"

    Assert-Equal -Name "repo-list: repo name is FakeRepo" `
        -Expected "FakeRepo" `
        -Actual $result.repos[0].name

    # Test 4: Deep dive artifact advances status to "analyzed"
    $briefingRepos = Join-Path $testRoot ".bot\workspace\product\briefing\repos"
    New-Item -Path $briefingRepos -ItemType Directory -Force | Out-Null
    "# Deep dive" | Set-Content (Join-Path $briefingRepos "FakeRepo.md")

    $result = Invoke-RepoList -Arguments @{}

    Assert-True -Name "repo-list: deep dive sets has_deep_dive" `
        -Condition ($result.repos[0].has_deep_dive -eq $true) `
        -Message "Expected has_deep_dive=true"

    Assert-Equal -Name "repo-list: status advances to analyzed" `
        -Expected "analyzed" `
        -Actual $result.repos[0].status

} finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$allPassed = Write-TestSummary -LayerName "repo-list"
if (-not $allPassed) { exit 1 }
