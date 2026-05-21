#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Enforce error-handling discipline in PowerShell scripts (issue #25).
.DESCRIPTION
    Verifies the three concrete rules from /app/.pwsh-review/standards.md:42-50:

    1. Every entry-point .ps1 sets `Set-StrictMode -Version 3.0` AND
       `$ErrorActionPreference = 'Stop'`.
    2. No empty catch blocks (`catch { }`).
    3. No silent-discard catches (`catch { $null = $_ }`).

    .psm1 modules inherit these from the importing context and are not scanned
    for rule 1. Rules 2 and 3 apply to both .ps1 and .psm1.

    Exclusions for rule 1 (entry-point directives):
      - tests/fixtures/         (fixture data, not executable scripts)
      - tests/e2e/              (E2E payloads)
      - tests/mock-*.ps1        (intentionally minimal mock binaries)
      - .pwsh-review/patterns/  (pattern templates)
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: PowerShell Error-Handling Discipline (issue #25)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$entryPointExcludePatterns = @(
    'tests/fixtures/',
    'tests/e2e/',
    'tests/mock-',
    '.pwsh-review/patterns/',
    # Deferred under follow-up to issue #25: needs PSObject.Properties guards on
    # optional manifest fields before Set-StrictMode -Version 3.0 can be applied.
    'tests/Test-WorkflowManifest.ps1',
    'core/runtime/modules/workflow-manifest.ps1'
)

function Test-ExcludedFromEntryPointCheck {
    param([string]$RelativePath)
    foreach ($pattern in $entryPointExcludePatterns) {
        if ($RelativePath -like "*$pattern*") {
            return $true
        }
    }
    return $false
}

# Collect all PowerShell files via git so we honour .gitignore and stay scoped to tracked files.
Push-Location $repoRoot
$allFiles = & git ls-files '*.ps1' '*.psm1' 2>$null
Pop-Location

if (-not $allFiles) {
    Write-TestResult -Name "Locate PowerShell files" -Status Fail -Message "git ls-files returned no .ps1/.psm1 results"
    [void](Write-TestSummary -LayerName "Layer 1: Error-Handling Discipline")
    exit 1
}

$ps1Files = $allFiles | Where-Object { $_ -like '*.ps1' }
$allPwshFiles = $allFiles

Write-Host "  Scanning $($ps1Files.Count) .ps1 files and $($allPwshFiles.Count - $ps1Files.Count) .psm1 files" -ForegroundColor DarkGray
Write-Host ""

# ─── Rule 1: Entry-point directives ──────────────────────────────────
$missingDirectives = New-Object System.Collections.Generic.List[string]
$strictModePattern = '(?m)^\s*Set-StrictMode\s+-Version\s+3'
$errorActionPattern = '(?m)^\s*\$ErrorActionPreference\s*=\s*[''"]Stop[''"]'

foreach ($relativePath in $ps1Files) {
    if (Test-ExcludedFromEntryPointCheck -RelativePath $relativePath) {
        continue
    }

    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        continue
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    $hasStrictMode = $content -match $strictModePattern
    $hasErrorAction = $content -match $errorActionPattern

    if (-not $hasStrictMode -or -not $hasErrorAction) {
        $missing = @()
        if (-not $hasStrictMode) { $missing += 'Set-StrictMode -Version 3.0' }
        if (-not $hasErrorAction) { $missing += "`$ErrorActionPreference = 'Stop'" }
        $missingDirectives.Add("$relativePath (missing: $($missing -join ', '))")
    }
}

if ($missingDirectives.Count -eq 0) {
    Write-TestResult -Name "Entry-point .ps1 files declare Set-StrictMode and `$ErrorActionPreference" -Status Pass
} else {
    $sample = ($missingDirectives | Select-Object -First 20) -join "`n    "
    $extra = if ($missingDirectives.Count -gt 20) { "`n    ... and $($missingDirectives.Count - 20) more" } else { "" }
    Write-TestResult -Name "Entry-point .ps1 files declare Set-StrictMode and `$ErrorActionPreference" -Status Fail `
        -Message "Found $($missingDirectives.Count) file(s) missing entry-point directives:`n    $sample$extra"
}

# ─── Rule 2: No empty catch blocks ───────────────────────────────────
# Match: catch {}, catch { }, catch [Type] {}, catch [Type] { }, possibly with whitespace/newlines.
# Use a multi-line regex against file content.
# Skip files whose own help text or pattern strings legitimately reference the
# literal catch-block forms scanned for.
$catchPatternExclusions = @('tests/Test-ErrorHandling.ps1')
$emptyCatchPattern = '(?ms)catch(\s*\[[^\]]+\])?\s*\{\s*\}'
$emptyCatches = New-Object System.Collections.Generic.List[string]

foreach ($relativePath in $allPwshFiles) {
    if ($relativePath -in $catchPatternExclusions) {
        continue
    }
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        continue
    }
    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    $regexMatches = [regex]::Matches($content, $emptyCatchPattern)
    foreach ($m in $regexMatches) {
        $lineNum = ($content.Substring(0, $m.Index) -split "`n").Count
        $emptyCatches.Add("$relativePath`:$lineNum")
    }
}

if ($emptyCatches.Count -eq 0) {
    Write-TestResult -Name "No empty catch blocks" -Status Pass
} else {
    $sample = ($emptyCatches | Select-Object -First 20) -join "`n    "
    $extra = if ($emptyCatches.Count -gt 20) { "`n    ... and $($emptyCatches.Count - 20) more" } else { "" }
    Write-TestResult -Name "No empty catch blocks" -Status Fail `
        -Message "Found $($emptyCatches.Count) empty catch block(s). Add `$_` logging or rethrow:`n    $sample$extra"
}

# ─── Rule 3: No silent-discard catches ───────────────────────────────
# Pattern: catch { $null = $_ } or catch { $null = $_; } with whitespace tolerance.
$silentDiscardPattern = '(?ms)catch(\s*\[[^\]]+\])?\s*\{\s*\$null\s*=\s*\$_\s*;?\s*\}'
$silentDiscards = New-Object System.Collections.Generic.List[string]

foreach ($relativePath in $allPwshFiles) {
    if ($relativePath -in $catchPatternExclusions) {
        continue
    }
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        continue
    }
    $content = Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop
    $regexMatches = [regex]::Matches($content, $silentDiscardPattern)
    foreach ($m in $regexMatches) {
        $lineNum = ($content.Substring(0, $m.Index) -split "`n").Count
        $silentDiscards.Add("$relativePath`:$lineNum")
    }
}

if ($silentDiscards.Count -eq 0) {
    Write-TestResult -Name "No 'catch { `$null = `$_ }' silent-discard patterns" -Status Pass
} else {
    $sample = ($silentDiscards | Select-Object -First 20) -join "`n    "
    $extra = if ($silentDiscards.Count -gt 20) { "`n    ... and $($silentDiscards.Count - 20) more" } else { "" }
    Write-TestResult -Name "No 'catch { `$null = `$_ }' silent-discard patterns" -Status Fail `
        -Message "Found $($silentDiscards.Count) silent-discard catch(es). Either log via Write-BotLog or document the tolerant intent:`n    $sample$extra"
}

$allPassed = (Write-TestSummary -LayerName "Layer 1: Error-Handling Discipline")
if ($allPassed) { exit 0 } else { exit 1 }
