#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Tests for the 00-privacy-scan.ps1 verify hook.
.DESCRIPTION
    Covers the changes in #362: verify-hook scoping to HEAD~1..HEAD plus
    untracked files, widened noscan/privacy-scan marker, placeholder skip
    list, .bot/workspace/{tasks,decisions} exclusions, and the (file, line)
    dedup that collapses multiple patterns on the same line.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot
$privacyScanScript = Join-Path $repoRoot "core/hooks/verify/00-privacy-scan.ps1"

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host "  Privacy-Scan Hook Tests" -ForegroundColor Blue
Write-Host "======================================================================" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

function Invoke-PrivacyScan {
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [switch]$StagedOnly
    )

    Push-Location $ProjectRoot
    try {
        $args = @("-NoProfile", "-File", $privacyScanScript)
        if ($StagedOnly) { $args += "-StagedOnly" }
        $output = & pwsh @args 2>$null
    } finally {
        Pop-Location
    }
    return $output | ConvertFrom-Json
}

function Initialize-PrivacyTestRepo {
    param([Parameter(Mandatory)] [string]$Prefix)
    $project = New-TestProject -Prefix $Prefix
    & git -C $project commit --allow-empty -q -m "baseline" 2>&1 | Out-Null
    return $project
}

# ─── Pre-commit (staged) scan flags real secrets in staged source files ──────

$proj1 = $null
try {
    $proj1 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-stage"
    $sourceFile = Join-Path $proj1 "src/Config.cs"
    New-Item -ItemType Directory -Path (Split-Path $sourceFile) -Force | Out-Null
    'var x = "Password=R3alSecretValue99;";' | Set-Content -Path $sourceFile -Encoding UTF8
    & git -C $proj1 add src/Config.cs 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj1 -StagedOnly

    Assert-True -Name "Real secret in staged source file is detected" `
        -Condition ($result.success -eq $false -and $result.failures.Count -ge 1) `
        -Message "Expected scanner to flag Password=R3alSecretValue99; in src/Config.cs"
}
finally {
    if ($proj1) { Remove-TestProject -Path $proj1 }
}

# ─── Pre-commit scan ignores .bot/workspace/tasks/ narrative content ─────────

$proj2 = $null
try {
    $proj2 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-tasks"
    $taskFile = Join-Path $proj2 ".bot/workspace/tasks/todo/seeded.json"
    New-Item -ItemType Directory -Path (Split-Path $taskFile) -Force | Out-Null
    '{"description":"Use Password=R3alSecretValue99; as the example"}' | Set-Content -Path $taskFile -Encoding UTF8
    & git -C $proj2 add ".bot/workspace/tasks/todo/seeded.json" 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj2 -StagedOnly

    Assert-True -Name "Same secret inside .bot/workspace/tasks/todo/ is excluded" `
        -Condition ($result.success -eq $true) `
        -Message "Expected scanner to skip files under .bot/workspace/tasks/. Got: $($result.failures | ConvertTo-Json -Compress)"
}
finally {
    if ($proj2) { Remove-TestProject -Path $proj2 }
}

# ─── Pre-commit scan ignores .bot/workspace/decisions/ narrative content ─────

$proj2b = $null
try {
    $proj2b = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-decisions"
    $decFile = Join-Path $proj2b ".bot/workspace/decisions/seeded.json"
    New-Item -ItemType Directory -Path (Split-Path $decFile) -Force | Out-Null
    '{"rationale":"discussion of Password=R3alSecretValue99; example"}' | Set-Content -Path $decFile -Encoding UTF8
    & git -C $proj2b add ".bot/workspace/decisions/seeded.json" 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj2b -StagedOnly

    Assert-True -Name "Same secret inside .bot/workspace/decisions/ is excluded" `
        -Condition ($result.success -eq $true) `
        -Message "Expected scanner to skip files under .bot/workspace/decisions/"
}
finally {
    if ($proj2b) { Remove-TestProject -Path $proj2b }
}

# ─── Inline `# privacy-scan: example` marker skips the violation ─────────────

$proj3 = $null
try {
    $proj3 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-marker"
    $sourceFile = Join-Path $proj3 "src/Sample.ps1"
    New-Item -ItemType Directory -Path (Split-Path $sourceFile) -Force | Out-Null
    @'
# privacy-scan: example
$conn = "Password=R3alSecretValue99;"
'@ | Set-Content -Path $sourceFile -Encoding UTF8
    & git -C $proj3 add src/Sample.ps1 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj3 -StagedOnly

    Assert-True -Name "Line tagged with '# privacy-scan: example' is skipped" `
        -Condition ($result.success -eq $true) `
        -Message "Expected the marker comment to suppress the violation"

    # Sanity: the existing `noscan` marker still works.
    $sourceFile2 = Join-Path $proj3 "src/Sample2.ps1"
    "`$conn = `"Password=AnotherSecret456;`"  # noscan" | Set-Content -Path $sourceFile2 -Encoding UTF8
    & git -C $proj3 add src/Sample2.ps1 2>&1 | Out-Null

    $result2 = Invoke-PrivacyScan -ProjectRoot $proj3 -StagedOnly
    Assert-True -Name "Existing `noscan` marker still suppresses violations" `
        -Condition ($result2.success -eq $true) `
        -Message "Expected `noscan` to keep working"
}
finally {
    if ($proj3) { Remove-TestProject -Path $proj3 }
}

# ─── Placeholder tokens (hunter2 etc.) are recognised as documented examples ─

$proj4 = $null
try {
    $proj4 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-placeholder"
    $sourceFile = Join-Path $proj4 "docs/example.md"
    New-Item -ItemType Directory -Path (Split-Path $sourceFile) -Force | Out-Null
    'Connection: `Password=hunter2;` is a documented example.' | Set-Content -Path $sourceFile -Encoding UTF8
    & git -C $proj4 add docs/example.md 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj4 -StagedOnly

    Assert-True -Name "Placeholder token 'hunter2' suppresses violation" `
        -Condition ($result.success -eq $true) `
        -Message "Expected placeholder list to skip the line"
}
finally {
    if ($proj4) { Remove-TestProject -Path $proj4 }
}

# ─── Multiple patterns matching one line collapse to a single violation ──────

$proj5 = $null
try {
    $proj5 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-dedup"
    $sourceFile = Join-Path $proj5 "src/Multi.ps1"
    New-Item -ItemType Directory -Path (Split-Path $sourceFile) -Force | Out-Null
    # One line matches both `secret_value` (`password=...`) and
    # `connection_string_password` (`Password=...`).
    "`$cs = `"Password=R3alSecretValue99;`"" | Set-Content -Path $sourceFile -Encoding UTF8
    & git -C $proj5 add src/Multi.ps1 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj5 -StagedOnly

    $violationsForLine = @($result.details.violations | Where-Object { $_.file -like "*Multi.ps1" })
    Assert-Equal -Name "Two patterns on one line produce one violation entry" `
        -Expected 1 `
        -Actual $violationsForLine.Count

    if ($violationsForLine.Count -eq 1) {
        $patterns = @($violationsForLine[0].patterns)
        Assert-True -Name "Single violation lists both pattern names" `
            -Condition ($patterns.Count -ge 2 -and $patterns -contains 'secret_value' -and $patterns -contains 'connection_string_password') `
            -Message "Expected patterns list to include secret_value and connection_string_password. Got: $($patterns -join ',')"
    }
}
finally {
    if ($proj5) { Remove-TestProject -Path $proj5 }
}

# ─── Verify-hook scan scopes to HEAD~1..HEAD plus untracked files ────────────

$proj6 = $null
try {
    $proj6 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-scope"

    # An older committed file with a secret. After we add a new commit, this
    # file is in HEAD~2 and should NOT be re-scanned by HEAD~1..HEAD.
    $oldFile = Join-Path $proj6 "src/Old.ps1"
    New-Item -ItemType Directory -Path (Split-Path $oldFile) -Force | Out-Null
    "`$old = `"Password=OldSecretValue42;`"" | Set-Content -Path $oldFile -Encoding UTF8
    & git -C $proj6 add src/Old.ps1 2>&1 | Out-Null
    & git -C $proj6 commit -q -m "old commit with secret" 2>&1 | Out-Null

    # A second commit that does NOT introduce any secret. HEAD~1..HEAD should
    # show only this commit's diff.
    $cleanFile = Join-Path $proj6 "src/Clean.ps1"
    "Write-Host 'no secrets here'" | Set-Content -Path $cleanFile -Encoding UTF8
    & git -C $proj6 add src/Clean.ps1 2>&1 | Out-Null
    & git -C $proj6 commit -q -m "clean commit" 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj6
    Assert-True -Name "Verify-hook ignores secrets in older commits outside HEAD~1..HEAD" `
        -Condition ($result.success -eq $true) `
        -Message "Expected verify-hook scan to scope to HEAD~1..HEAD. Got failures: $($result.failures | ConvertTo-Json -Compress)"

    # Untracked files are still scanned.
    $untracked = Join-Path $proj6 "src/Untracked.ps1"
    "`$x = `"Password=BrandNewSecret77;`"" | Set-Content -Path $untracked -Encoding UTF8

    $result2 = Invoke-PrivacyScan -ProjectRoot $proj6
    Assert-True -Name "Verify-hook still scans untracked working-tree files" `
        -Condition ($result2.success -eq $false) `
        -Message "Expected untracked file with new secret to trip the scanner"
}
finally {
    if ($proj6) { Remove-TestProject -Path $proj6 }
}

$allPassed = Write-TestSummary -LayerName "Privacy-Scan Hook Tests"

if (-not $allPassed) {
    exit 1
}
