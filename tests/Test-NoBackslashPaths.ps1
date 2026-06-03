#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Hard gate — fail on Join-Path string literals with backslashes.
.DESCRIPTION
    PowerShell treats backslashes inside Join-Path child path strings as
    literal characters on Linux/macOS. This test fails on tracked PowerShell
    source files outside tests/ when a Join-Path line contains a quoted string
    literal with a backslash.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: No Join-Path Backslash Literals (hard fail)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$unexpected = New-Object System.Collections.Generic.List[string]
$doubleQuotedPathPattern = 'Join-Path.*"[^"]*\\[^"]*"'
$singleQuotedPathPattern = "Join-Path.*'[^']*\\[^']*'"

Push-Location $repoRoot
try {
    $files = & git ls-files -- '*.ps1' '*.psm1' '*.psd1'
} finally {
    Pop-Location
}

foreach ($file in $files) {
    $normalizedFile = $file -replace '\\', '/'
    if ($normalizedFile.StartsWith('tests/')) { continue }

    $path = Join-Path $repoRoot $normalizedFile
    if (-not (Test-Path -LiteralPath $path)) { continue }

    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        $lineNumber++
        if ($line -match $doubleQuotedPathPattern -or $line -match $singleQuotedPathPattern) {
            $unexpected.Add("${normalizedFile}:${lineNumber}:$line")
        }
    }
}

if ($unexpected.Count -gt 0) {
    Write-Host "  ✗ Join-Path backslash literals outside tests/: $($unexpected.Count)" -ForegroundColor Red
    foreach ($line in ($unexpected | Select-Object -First 50)) {
        Write-Host "      $line" -ForegroundColor DarkRed
    }
    if ($unexpected.Count -gt 50) {
        Write-Host "      ... and $($unexpected.Count - 50) more" -ForegroundColor DarkRed
    }
    Write-TestResult -Name "Join-Path string literals use forward slashes" -Status Fail `
        -Message "$($unexpected.Count) Join-Path backslash literal(s) outside tests/"
    [void](Write-TestSummary -LayerName "Layer 1: No Join-Path Backslash Literals")
    exit 1
}

Write-TestResult -Name "Join-Path string literals use forward slashes" -Status Pass
[void](Write-TestSummary -LayerName "Layer 1: No Join-Path Backslash Literals")
exit 0
