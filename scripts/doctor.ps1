#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Scan a deployed .bot project for health issues.

.DESCRIPTION
    Checks output hygiene, settings integrity, stale locks, orphaned worktrees,
    dependencies, task queue health, and theme config. Designed to run from the
    dotbot CLI: `dotbot doctor`

.PARAMETER BotRoot
    Path to the .bot directory (default: ./.bot)
#>
param(
    [string]$BotRoot = (Join-Path (Get-Location) ".bot")
)

$ErrorActionPreference = "Continue"

# Import theme if available (for themed output)
$themeModule = Join-Path $BotRoot "systems\runtime\modules\DotBotTheme.psm1"
if (Test-Path $themeModule) {
    Import-Module $themeModule -Force
    $t = Get-DotBotTheme
    $hasTheme = $true
} else {
    $hasTheme = $false
}

# Counters
$passes  = 0
$warns   = 0
$errors  = 0

function Write-Check {
    param([string]$Label, [string]$Result, [ValidateSet('Pass','Warn','Fail')]$Status)
    switch ($Status) {
        'Pass' {
            $script:passes++
            if ($hasTheme) { Write-Status "$Label — $Result" -Type Success }
            else { Write-Host "  ✓ $Label — $Result" -ForegroundColor Green }
        }
        'Warn' {
            $script:warns++
            if ($hasTheme) { Write-Status "$Label — $Result" -Type Warn }
            else { Write-Host "  ⚠ $Label — $Result" -ForegroundColor Yellow }
        }
        'Fail' {
            $script:errors++
            if ($hasTheme) { Write-Status "$Label — $Result" -Type Error }
            else { Write-Host "  ✗ $Label — $Result" -ForegroundColor Red }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# HEADER
# ═══════════════════════════════════════════════════════════════════

$ver = $env:DOTBOT_VERSION ?? 'unknown'
Write-Host ""
Write-Host "  D O T B O T   D O C T O R   v$ver" -ForegroundColor Cyan
Write-Host "  Project: $(Split-Path (Split-Path $BotRoot -Parent) -Leaf)" -ForegroundColor DarkGray
Write-Host ""

if (-not (Test-Path $BotRoot)) {
    Write-Host "  ✗ .bot directory not found at: $BotRoot" -ForegroundColor Red
    Write-Host "  Run 'dotbot init' first." -ForegroundColor Yellow
    exit 2
}

# ═══════════════════════════════════════════════════════════════════
# 1. DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  DEPENDENCIES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# git
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Check "git" "found" Pass
} else {
    Write-Check "git" "not found on PATH" Fail
}

# Provider CLI (claude or openai)
$providerFound = $false
foreach ($exe in @('claude', 'claude.exe', 'openai')) {
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
        Write-Check "Provider CLI" "$exe found" Pass
        $providerFound = $true
        break
    }
}
if (-not $providerFound) {
    Write-Check "Provider CLI" "no provider CLI found (claude/openai)" Fail
}

# powershell-yaml
if (Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue) {
    Write-Check "powershell-yaml" "installed" Pass
} else {
    Write-Check "powershell-yaml" "missing — Install-Module powershell-yaml -Scope CurrentUser" Warn
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# 2. SETTINGS INTEGRITY
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SETTINGS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$settingsPath = Join-Path $BotRoot "settings\settings.default.json"
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.execution -and $settings.analysis) {
            Write-Check "settings.default.json" "valid, has execution + analysis" Pass
        } else {
            Write-Check "settings.default.json" "missing execution or analysis keys" Warn
        }
    } catch {
        Write-Check "settings.default.json" "invalid JSON: $_" Fail
    }
} else {
    Write-Check "settings.default.json" "not found" Fail
}

# Theme config
$themeDefault = Join-Path $BotRoot "settings\theme.default.json"
if (Test-Path $themeDefault) {
    try {
        Get-Content $themeDefault -Raw | ConvertFrom-Json | Out-Null
        Write-Check "theme.default.json" "valid" Pass
    } catch {
        Write-Check "theme.default.json" "invalid JSON" Warn
    }
} else {
    Write-Check "theme.default.json" "not found (will use fallback)" Warn
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# 3. STALE PROCESS LOCKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROCESS LOCKS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$controlDir = Join-Path $BotRoot ".control"
$lockFiles = @()
if (Test-Path $controlDir) {
    $lockFiles = @(Get-ChildItem $controlDir -Filter "launch-*.lock" -File -ErrorAction SilentlyContinue)
}

if ($lockFiles.Count -eq 0) {
    Write-Check "Process locks" "none (clean)" Pass
} else {
    $staleCount = 0
    foreach ($lf in $lockFiles) {
        $pidStr = (Get-Content $lf.FullName -Raw -ErrorAction SilentlyContinue)?.Trim()
        if ($pidStr -and $pidStr -match '^\d+$') {
            try {
                Get-Process -Id ([int]$pidStr) -ErrorAction Stop | Out-Null
                # Process still running — OK
            } catch {
                $staleCount++
                Write-Check "Lock: $($lf.Name)" "PID $pidStr no longer running (stale)" Warn
            }
        }
    }
    if ($staleCount -eq 0) {
        Write-Check "Process locks" "$($lockFiles.Count) active (all PIDs alive)" Pass
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# 4. ORPHANED WORKTREES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKTREES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$wtMapPath = Join-Path $controlDir "worktree-map.json"
if (Test-Path $wtMapPath) {
    try {
        $wtMap = Get-Content $wtMapPath -Raw | ConvertFrom-Json
        $orphaned = 0
        foreach ($prop in $wtMap.PSObject.Properties) {
            $wtPath = $prop.Value.worktree_path
            if ($wtPath -and -not (Test-Path $wtPath)) {
                $orphaned++
                Write-Check "Worktree: $($prop.Name)" "path missing: $wtPath" Warn
            }
        }
        if ($orphaned -eq 0) {
            $total = @($wtMap.PSObject.Properties).Count
            Write-Check "Worktree map" "$total entries, all paths valid" Pass
        }
    } catch {
        Write-Check "worktree-map.json" "invalid JSON" Warn
    }
} else {
    Write-Check "Worktree map" "no map file (clean)" Pass
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# 5. TASK QUEUE HEALTH
# ═══════════════════════════════════════════════════════════════════

Write-Host "  TASK QUEUE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$tasksDir = Join-Path $BotRoot "workspace\tasks"
if (Test-Path $tasksDir) {
    $badJson = 0
    $missingId = 0
    $totalTasks = 0
    foreach ($dir in (Get-ChildItem $tasksDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($f in (Get-ChildItem $dir.FullName -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            if ($f.Name.StartsWith('_')) { continue }
            $totalTasks++
            try {
                $task = Get-Content $f.FullName -Raw | ConvertFrom-Json
                if (-not $task.id -or -not $task.name) { $missingId++ }
            } catch {
                $badJson++
            }
        }
    }
    if ($badJson -gt 0) {
        Write-Check "Task files" "$badJson files with invalid JSON" Fail
    }
    if ($missingId -gt 0) {
        Write-Check "Task files" "$missingId files missing id or name" Warn
    }
    if ($badJson -eq 0 -and $missingId -eq 0) {
        Write-Check "Task queue" "$totalTasks tasks, all valid" Pass
    }
} else {
    Write-Check "Task queue" "no tasks directory" Pass
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# 6. OUTPUT HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  OUTPUT HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$scanDirs = @()
$scriptsDir = Join-Path $BotRoot "scripts"
if (Test-Path $scriptsDir) { $scanDirs += $scriptsDir }
$wfDir = Join-Path $BotRoot "workflows"
if (Test-Path $wfDir) {
    Get-ChildItem $wfDir -Directory | ForEach-Object {
        $wfScripts = Join-Path $_.FullName "scripts"
        if (Test-Path $wfScripts) { $scanDirs += $wfScripts }
    }
}

$writeHostCount = 0
$consoleErrorCount = 0
$findings = @()

foreach ($dir in $scanDirs) {
    Get-ChildItem $dir -Filter "*.ps1" -File -Recurse | ForEach-Object {
        $relPath = $_.FullName.Replace($BotRoot, '.bot')
        $lineNum = 0
        Get-Content $_.FullName | ForEach-Object {
            $lineNum++
            if ($_ -match '^\s*Write-Host\s' -and $_ -notmatch '#.*Write-Host') {
                $writeHostCount++
                if ($findings.Count -lt 10) {
                    $findings += "$relPath`:$lineNum Write-Host"
                }
            }
            if ($_ -match '\[Console\]::Error\.Write') {
                $consoleErrorCount++
                if ($findings.Count -lt 10) {
                    $findings += "$relPath`:$lineNum [Console]::Error.Write"
                }
            }
        }
    }
}

if ($writeHostCount -eq 0 -and $consoleErrorCount -eq 0) {
    Write-Check "Output hygiene" "all scripts use themed output" Pass
} else {
    if ($writeHostCount -gt 0) {
        Write-Check "Write-Host usage" "$writeHostCount occurrence(s) — use Write-Status/Write-Phosphor instead" Warn
    }
    if ($consoleErrorCount -gt 0) {
        Write-Check "Console.Error traces" "$consoleErrorCount occurrence(s) — remove debug traces" Warn
    }
    foreach ($f in $findings) {
        Write-Host "    $f" -ForegroundColor DarkGray
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
$total = $passes + $warns + $errors
Write-Host "  $passes passed" -NoNewline -ForegroundColor Green
Write-Host ", " -NoNewline
Write-Host "$warns warnings" -NoNewline -ForegroundColor Yellow
Write-Host ", " -NoNewline
Write-Host "$errors errors" -ForegroundColor $(if ($errors -gt 0) { 'Red' } else { 'Green' })
Write-Host ""

if ($errors -gt 0) { exit 2 }
elseif ($warns -gt 0) { exit 1 }
else { exit 0 }
