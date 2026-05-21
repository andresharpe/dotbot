#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Enforce file encoding hygiene for PowerShell scripts (issue #25).
.DESCRIPTION
    Verifies the three concrete rules from /app/.pwsh-review/standards.md:177-184:

    1. No .ps1/.psm1 file starts with a UTF-8 BOM (bytes EF BB BF).
    2. Every Set-Content / Add-Content / Out-File call site declares -Encoding
       explicitly (or uses splatting, which we cannot statically verify).
    3. /app/.gitattributes declares LF line endings for *.ps1, *.psm1, *.psd1.

    Rule 2 ignores comments and splatted parameter sets (`@params`). Multi-line
    invocations using backtick line-continuation are reconstructed before
    scanning so the -Encoding check covers the full logical statement.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: PowerShell File Encoding (issue #25)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Push-Location $repoRoot
$allFiles = & git ls-files '*.ps1' '*.psm1' 2>$null
Pop-Location

if (-not $allFiles) {
    Write-TestResult -Name "Locate PowerShell files" -Status Fail -Message "git ls-files returned no .ps1/.psm1 results"
    [void](Write-TestSummary -LayerName "Layer 1: File Encoding")
    exit 1
}

Write-Host "  Scanning $($allFiles.Count) PowerShell files" -ForegroundColor DarkGray
Write-Host ""

# ─── Rule 1: No UTF-8 BOM ────────────────────────────────────────────
$bomFiles = New-Object System.Collections.Generic.List[string]
$bomBytes = [byte[]]@(0xEF, 0xBB, 0xBF)

foreach ($relativePath in $allFiles) {
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        continue
    }
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        $buffer = New-Object byte[] 3
        $read = $stream.Read($buffer, 0, 3)
        if ($read -eq 3 -and $buffer[0] -eq $bomBytes[0] -and $buffer[1] -eq $bomBytes[1] -and $buffer[2] -eq $bomBytes[2]) {
            $bomFiles.Add($relativePath)
        }
    } finally {
        $stream.Dispose()
    }
}

if ($bomFiles.Count -eq 0) {
    Write-TestResult -Name "No .ps1/.psm1 files have a UTF-8 BOM" -Status Pass
} else {
    $sample = ($bomFiles | Select-Object -First 20) -join "`n    "
    Write-TestResult -Name "No .ps1/.psm1 files have a UTF-8 BOM" -Status Fail `
        -Message "Found $($bomFiles.Count) BOM-prefixed file(s). Re-save as UTF-8 without BOM:`n    $sample"
}

# ─── Rule 2: Explicit -Encoding on file writes ───────────────────────
# Reconstruct logical statements by joining backtick-continuation lines.
# Then look for Set-Content / Add-Content / Out-File without -Encoding.

# Skip this file: its pattern definitions legitimately reference the cmdlet
# names it scans for.
$encodingPatternExclusions = @('tests/Test-FileEncoding.ps1')
$writeCmdletPattern = '\b(Set-Content|Add-Content|Out-File)\b'
$encodingPattern = '-Encoding\b'
$splatPattern = '@\w+'
$missingEncoding = New-Object System.Collections.Generic.List[string]

foreach ($relativePath in $allFiles) {
    if ($relativePath -in $encodingPatternExclusions) {
        continue
    }
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        continue
    }

    $rawLines = Get-Content -LiteralPath $fullPath -ErrorAction Stop
    if ($null -eq $rawLines) { continue }
    if ($rawLines -isnot [array]) { $rawLines = @($rawLines) }

    # Strip block comments (`<# ... #>`) by blanking out their lines so they
    # cannot trigger false positives. Track whether we're inside one.
    $inBlockComment = $false
    $strippedLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $rawLines.Count; $i++) {
        $line = $rawLines[$i]
        if ($inBlockComment) {
            if ($line -match '#>') { $inBlockComment = $false }
            $strippedLines.Add('') | Out-Null
            continue
        }
        if ($line -match '<#' -and $line -notmatch '<#.*#>') {
            $inBlockComment = $true
            $strippedLines.Add('') | Out-Null
            continue
        }
        $strippedLines.Add($line) | Out-Null
    }

    # Join backtick-continuation lines into single logical statements while
    # preserving the original line number of each statement.
    $logicalStatements = New-Object System.Collections.Generic.List[object]
    $accumulator = ""
    $startLine = 0
    for ($i = 0; $i -lt $strippedLines.Count; $i++) {
        $line = $strippedLines[$i]
        if ($accumulator -eq "") { $startLine = $i + 1 }
        $accumulator = if ($accumulator -eq "") { $line } else { "$accumulator $line" }
        if ($line -notmatch '`\s*$') {
            $logicalStatements.Add([pscustomobject]@{ Line = $startLine; Text = $accumulator })
            $accumulator = ""
        }
    }
    if ($accumulator -ne "") {
        $logicalStatements.Add([pscustomobject]@{ Line = $startLine; Text = $accumulator })
    }

    foreach ($stmt in $logicalStatements) {
        $text = $stmt.Text
        # Skip pure comment lines.
        if ($text.TrimStart() -match '^\s*#') { continue }
        if ($text -notmatch $writeCmdletPattern) { continue }
        # Strip inline comments (everything after a # outside quotes — approximated).
        $codePart = ($text -split '(?<!`)#', 2)[0]
        if ($codePart -notmatch $writeCmdletPattern) { continue }
        if ($codePart -match $encodingPattern) { continue }
        if ($codePart -match $splatPattern) { continue }
        $missingEncoding.Add("$relativePath`:$($stmt.Line)  $($text.Trim())")
    }
}

if ($missingEncoding.Count -eq 0) {
    Write-TestResult -Name "Set-Content/Add-Content/Out-File calls declare -Encoding" -Status Pass
} else {
    $sample = ($missingEncoding | Select-Object -First 20) -join "`n    "
    $extra = if ($missingEncoding.Count -gt 20) { "`n    ... and $($missingEncoding.Count - 20) more" } else { "" }
    Write-TestResult -Name "Set-Content/Add-Content/Out-File calls declare -Encoding" -Status Fail `
        -Message "Found $($missingEncoding.Count) write(s) without explicit -Encoding. Add '-Encoding utf8NoBOM':`n    $sample$extra"
}

# ─── Rule 3: .gitattributes declares LF for PowerShell files ────────
$gitAttrsPath = Join-Path $repoRoot ".gitattributes"
if (-not (Test-Path -LiteralPath $gitAttrsPath)) {
    Write-TestResult -Name ".gitattributes declares LF for *.ps1/*.psm1/*.psd1" -Status Fail `
        -Message ".gitattributes does not exist at repo root"
} else {
    $gitAttrs = Get-Content -LiteralPath $gitAttrsPath -Raw -ErrorAction Stop
    $required = @(
        @{ Pattern = '\*\.ps1\b';  Name = '*.ps1' },
        @{ Pattern = '\*\.psm1\b'; Name = '*.psm1' },
        @{ Pattern = '\*\.psd1\b'; Name = '*.psd1' }
    )
    $missing = @()
    foreach ($r in $required) {
        $line = ($gitAttrs -split "`n") | Where-Object { $_ -match $r.Pattern -and $_ -match 'eol=lf' }
        if (-not $line) { $missing += $r.Name }
    }
    if ($missing.Count -eq 0) {
        Write-TestResult -Name ".gitattributes declares LF for *.ps1/*.psm1/*.psd1" -Status Pass
    } else {
        Write-TestResult -Name ".gitattributes declares LF for *.ps1/*.psm1/*.psd1" -Status Fail `
            -Message "Missing eol=lf rule(s) for: $($missing -join ', '). Add e.g. '*.ps1 text eol=lf' to .gitattributes."
    }
}

$allPassed = (Write-TestSummary -LayerName "Layer 1: File Encoding")
if ($allPassed) { exit 0 } else { exit 1 }
