#!/usr/bin/env pwsh

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: No Wildcard-Interpreting Composed Paths (hard fail)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$unexpected = New-Object System.Collections.Generic.List[string]
$composedPathPattern = 'Test-Path\s+(-Path\s+)?\(Join-Path'

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
        if ($line -match $composedPathPattern) {
            $unexpected.Add("${normalizedFile}:${lineNumber}:$line")
        }
    }
}

if ($unexpected.Count -gt 0) {
    Write-Host "  ✗ Composed paths probed without -LiteralPath: $($unexpected.Count)" -ForegroundColor Red
    Write-Host "    PowerShell reads [ ] * ? in -Path as a wildcard pattern, so a probe built" -ForegroundColor Yellow
    Write-Host "    from a user-controlled directory silently reports False for a path that" -ForegroundColor Yellow
    Write-Host "    exists. Use Test-Path -LiteralPath (Join-Path ...) instead." -ForegroundColor Yellow
    Write-Host ""
    foreach ($line in ($unexpected | Select-Object -First 50)) {
        Write-Host "      $line" -ForegroundColor DarkRed
    }
    if ($unexpected.Count -gt 50) {
        Write-Host "      ... and $($unexpected.Count - 50) more" -ForegroundColor DarkRed
    }
    Write-TestResult -Name "Test-Path on a composed path uses -LiteralPath" -Status Fail `
        -Message "$($unexpected.Count) wildcard-interpreting composed path probe(s) outside tests/"
    [void](Write-TestSummary -LayerName "Layer 1: No Wildcard-Interpreting Composed Paths")
    exit 1
}

Write-TestResult -Name "Test-Path on a composed path uses -LiteralPath" -Status Pass
[void](Write-TestSummary -LayerName "Layer 1: No Wildcard-Interpreting Composed Paths")
exit 0
