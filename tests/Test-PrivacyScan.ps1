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
        $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NonInteractive", "-File", $privacyScanScript)
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

# ─── Verify-hook scan scopes to the task-branch merge-base diff ──────────────
# Exercise the actual merge-base scoping on a real two-branch layout. A
# baseline secret on `main` must NOT be re-flagged from a feature branch, and
# secrets introduced in EARLY commits on the feature branch (not just the
# latest one) must still be detected.

$proj6 = $null
try {
    $proj6 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-scope"

    # Resolve the default branch name (`main` on modern git, `master` on old).
    $defaultBranch = (& git -C $proj6 rev-parse --abbrev-ref HEAD 2>$null).Trim()

    # Commit a secret on the default branch — this represents prior history
    # the task did not introduce.
    $baseSecretFile = Join-Path $proj6 "src/BaselineSecret.ps1"
    New-Item -ItemType Directory -Path (Split-Path $baseSecretFile) -Force | Out-Null
    "`$base = `"Password=BaselineSecret42;`"" | Set-Content -Path $baseSecretFile -Encoding UTF8
    & git -C $proj6 add src/BaselineSecret.ps1 2>&1 | Out-Null
    & git -C $proj6 commit -q -m "baseline secret on $defaultBranch" 2>&1 | Out-Null

    # Branch off and add two commits on the feature branch. The first commit
    # introduces a secret; the second does not. With HEAD~1..HEAD scoping the
    # earlier secret would be missed. With merge-base scoping it must still
    # be flagged.
    & git -C $proj6 checkout -q -b task/feature-x 2>&1 | Out-Null

    $earlyTaskFile = Join-Path $proj6 "src/EarlyTask.ps1"
    "`$task = `"Password=EarlyTaskSecret77;`"" | Set-Content -Path $earlyTaskFile -Encoding UTF8
    & git -C $proj6 add src/EarlyTask.ps1 2>&1 | Out-Null
    & git -C $proj6 commit -q -m "task: early commit with secret" 2>&1 | Out-Null

    $cleanFile = Join-Path $proj6 "src/CleanLater.ps1"
    "Write-Host 'no secrets here'" | Set-Content -Path $cleanFile -Encoding UTF8
    & git -C $proj6 add src/CleanLater.ps1 2>&1 | Out-Null
    & git -C $proj6 commit -q -m "task: later clean commit" 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj6
    Assert-True -Name "Verify-hook flags task-branch secret introduced before the latest commit" `
        -Condition ($result.success -eq $false) `
        -Message "Expected merge-base scoping to surface src/EarlyTask.ps1's secret. Got: $($result.failures | ConvertTo-Json -Compress)"
    if ($result.failures) {
        $earlyHit = @($result.failures | Where-Object { $_.issue -match 'src[/\\]EarlyTask\.ps1' })
        Assert-True -Name "Verify-hook flag names src/EarlyTask.ps1" `
            -Condition ($earlyHit.Count -gt 0) `
            -Message "Expected at least one violation citing src/EarlyTask.ps1. Got: $($result.failures | ConvertTo-Json -Compress)"
        $baselineHit = @($result.failures | Where-Object { $_.issue -match 'src[/\\]BaselineSecret\.ps1' })
        Assert-True -Name "Verify-hook does not re-flag baseline-branch secret" `
            -Condition ($baselineHit.Count -eq 0) `
            -Message "Expected merge-base scoping to skip src/BaselineSecret.ps1, but it was flagged"
    }

    # Untracked files are still scanned regardless of branch position.
    $untracked = Join-Path $proj6 "src/Untracked.ps1"
    "`$x = `"Password=BrandNewSecret77;`"" | Set-Content -Path $untracked -Encoding UTF8

    $result2 = Invoke-PrivacyScan -ProjectRoot $proj6
    $untrackedHit = @($result2.failures | Where-Object { $_.issue -match 'src[/\\]Untracked\.ps1' })
    Assert-True -Name "Verify-hook still scans untracked working-tree files" `
        -Condition ($untrackedHit.Count -gt 0) `
        -Message "Expected untracked file with new secret to trip the scanner"
}
finally {
    if ($proj6) { Remove-TestProject -Path $proj6 }
}

# ─── merge-base==HEAD edge case falls back to HEAD~1..HEAD ───────────────────
# When HEAD is on the base branch itself (no remote, single-branch repo), the
# merge-base equals HEAD and the diff range would be empty. The hook must
# fall back so secrets in the most recent commit are still scanned.

$proj7 = $null
try {
    $proj7 = Initialize-PrivacyTestRepo -Prefix "dotbot-privacy-mb-eq-head"

    $secretFile = Join-Path $proj7 "src/JustCommitted.ps1"
    New-Item -ItemType Directory -Path (Split-Path $secretFile) -Force | Out-Null
    "`$x = `"Password=FreshSecret88;`"" | Set-Content -Path $secretFile -Encoding UTF8
    & git -C $proj7 add src/JustCommitted.ps1 2>&1 | Out-Null
    & git -C $proj7 commit -q -m "secret on default branch" 2>&1 | Out-Null

    $result = Invoke-PrivacyScan -ProjectRoot $proj7
    $hit = @($result.failures | Where-Object { $_.issue -match 'src[/\\]JustCommitted\.ps1' })
    Assert-True -Name "Verify-hook scans the latest commit when merge-base equals HEAD" `
        -Condition ($hit.Count -gt 0) `
        -Message "Expected fallback to HEAD~1..HEAD when on the base branch. Got: $($result.failures | ConvertTo-Json -Compress)"
}
finally {
    if ($proj7) { Remove-TestProject -Path $proj7 }
}

$allPassed = Write-TestSummary -LayerName "Privacy-Scan Hook Tests"

if (-not $allPassed) {
    exit 1
}
