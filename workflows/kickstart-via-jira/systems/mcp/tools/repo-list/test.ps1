# Test repo-list tool

. "$PSScriptRoot\script.ps1"

Write-Host "Testing repo-list..." -ForegroundColor Cyan

# Set up isolated test root
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-repo-list-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
$global:DotbotProjectRoot = $testRoot

try {
    # Test 1: No repos/ directory → empty result
    Write-Host "`n1. No repos/ directory"
    $result = Invoke-RepoList -Arguments @{}
    if ($result.success -and $result.count -eq 0 -and $result.repos.Count -eq 0) {
        Write-Host "   PASS: Returns empty list" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected empty list, got count=$($result.count)" -ForegroundColor Red
    }

    # Test 2: Empty repos/ directory
    Write-Host "`n2. Empty repos/ directory"
    $reposDir = Join-Path $testRoot "repos"
    New-Item -Path $reposDir -ItemType Directory -Force | Out-Null
    $result = Invoke-RepoList -Arguments @{}
    if ($result.success -and $result.count -eq 0) {
        Write-Host "   PASS: Returns empty list for empty repos/" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected empty list" -ForegroundColor Red
    }

    # Test 3: Fake git repo in repos/
    Write-Host "`n3. Fake git repo in repos/"
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
    if ($result.success -and $result.count -eq 1 -and $result.repos[0].name -eq "FakeRepo") {
        Write-Host "   PASS: Found FakeRepo with status '$($result.repos[0].status)'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected 1 repo named FakeRepo, got count=$($result.count)" -ForegroundColor Red
    }

    # Test 4: Deep dive artifact → status advances to "analyzed"
    Write-Host "`n4. Deep dive artifact advances status"
    $briefingRepos = Join-Path $testRoot ".bot\workspace\product\briefing\repos"
    New-Item -Path $briefingRepos -ItemType Directory -Force | Out-Null
    "# Deep dive" | Set-Content (Join-Path $briefingRepos "FakeRepo.md")

    $result = Invoke-RepoList -Arguments @{}
    if ($result.success -and $result.repos[0].has_deep_dive -eq $true -and $result.repos[0].status -eq "analyzed") {
        Write-Host "   PASS: Status advanced to 'analyzed'" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Expected status='analyzed', got '$($result.repos[0].status)'" -ForegroundColor Red
    }

} finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`nTests complete." -ForegroundColor Cyan
