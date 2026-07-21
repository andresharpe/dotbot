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

# Import platform functions for themed output
$PlatformFunctionsModule = Join-Path $PSScriptRoot "Platform-Functions.psm1"
if (-not (Test-Path $PlatformFunctionsModule)) {
    Write-Error "Required module not found: $PlatformFunctionsModule"
    exit 1
}
Import-Module $PlatformFunctionsModule -Force -ErrorAction Stop

# Dotbot.Core provides Resolve-DotbotExternalCommand (split-PATH detection).
Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking

# Dotbot.Theme is optional here — it lights up the summary grid and separators.
# If a project ships without it (e.g. doctor invoked before .bot is fully
# materialized) the script must still run with Platform-Functions alone.
$DotbotThemeModule = Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1"
$HaveDotbotTheme = $false
if (Test-Path $DotbotThemeModule) {
    Import-Module $DotbotThemeModule -Force -DisableNameChecking -ErrorAction SilentlyContinue
    $HaveDotbotTheme = $true
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
            Write-Success "$Label — $Result"
        }
        'Warn' {
            $script:warns++
            Write-DotbotWarning "$Label — $Result"
        }
        'Fail' {
            $script:errors++
            Write-DotbotError "$Label — $Result"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# HEADER
# ═══════════════════════════════════════════════════════════════════

$ver = $env:DOTBOT_VERSION ?? 'unknown'
Write-DotbotBanner -Title "D O T B O T   D O C T O R   v$ver" -Subtitle "Project: $(Split-Path (Split-Path $BotRoot -Parent) -Leaf)"

if (-not (Test-Path $BotRoot)) {
    Write-DotbotError ".bot directory not found at: $BotRoot"
    Write-DotbotWarning "Run 'dotbot init' first."
    exit 2
}

# ═══════════════════════════════════════════════════════════════════
# 1. DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════

Write-DotbotSection -Title "DEPENDENCIES"

# Emits the Warn + fix guidance for a dependency that is registered in the
# Machine/User registry PATH but missing from this process PATH. Doctor
# diagnoses the split instead of repairing it - repairing here would erase
# the very condition being reported.
function Write-SplitPathCheck {
    param([string]$Label, [hashtable]$Resolution)
    Write-Check $Label "found via $($Resolution.Scope) PATH but missing from this process PATH (split PATH detected)" Warn
    Write-DotbotCommand "Fix this session:  `$env:PATH += ';$($Resolution.Directory)'"
    Write-DotbotCommand "Fix permanently:   restart your terminal (or the app that launched it) so it re-merges the $($Resolution.Scope) PATH"
}

# git
$gitRes = Resolve-DotbotExternalCommand -Name 'git'
if ($gitRes.Found -and $gitRes.Scope -eq 'Process') {
    Write-Check "git" "found" Pass
} elseif ($gitRes.Found) {
    Write-SplitPathCheck -Label "git" -Resolution $gitRes
} else {
    Write-Check "git" "not found in process, Machine, or User PATH" Fail
}

# Provider CLI (claude, codex, Antigravity's agy, OpenCode, or GitHub Copilot CLI)
$providerFound = $false
foreach ($exe in @('claude', 'claude.exe', 'codex', 'codex.exe', 'agy', 'agy.exe', 'opencode', 'opencode.exe', 'copilot', 'copilot.exe')) {
    $provRes = Resolve-DotbotExternalCommand -Name $exe
    if (-not $provRes.Found) { continue }
    if ($provRes.Scope -eq 'Process') {
        Write-Check "Provider CLI" "$exe found" Pass
    } else {
        Write-SplitPathCheck -Label "Provider CLI ($exe)" -Resolution $provRes
    }
    $providerFound = $true
    break
}
if (-not $providerFound -and (Resolve-DotbotExternalCommand -Name 'gh').Found) {
    Write-Check "Provider CLI" "gh found (can run preview 'gh copilot')" Pass
    $providerFound = $true
}
if (-not $providerFound) {
    Write-Check "Provider CLI" "no provider CLI found (claude/codex/agy/opencode/copilot) in process, Machine, or User PATH" Fail
}

Write-BlankLine

# ═══════════════════════════════════════════════════════════════════
# 2. SETTINGS INTEGRITY
# ═══════════════════════════════════════════════════════════════════

Write-DotbotSection -Title "SETTINGS"

try {
    $settingsModule = Join-Path $PSScriptRoot '../runtime/Modules/Dotbot.Settings/Dotbot.Settings.psd1'
    Import-Module $settingsModule -DisableNameChecking -Global
    $settings = Get-MergedSettings -BotRoot $BotRoot
    if ($settings.execution -and $settings.analysis) {
        Write-Check "Merged settings" "valid, has execution + analysis" Pass
    } else {
        Write-Check "Merged settings" "missing execution or analysis keys" Warn
    }
} catch {
    Write-Check "Merged settings" "could not resolve: $_" Fail
}

# Theme config
$themeDefault = Join-Path $PSScriptRoot "../../content/settings/theme.default.json"
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

Write-BlankLine

# ═══════════════════════════════════════════════════════════════════
# 3. STALE PROCESS LOCKS
# ═══════════════════════════════════════════════════════════════════

Write-DotbotSection -Title "PROCESS LOCKS"

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

Write-BlankLine

# ═══════════════════════════════════════════════════════════════════
# 4. ORPHANED WORKTREES
# ═══════════════════════════════════════════════════════════════════

Write-DotbotSection -Title "WORKTREES"

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

Write-BlankLine

# ═══════════════════════════════════════════════════════════════════
# 5. TASK QUEUE HEALTH
# ═══════════════════════════════════════════════════════════════════

Write-DotbotSection -Title "TASK QUEUE"

$tasksDir = Join-Path $BotRoot "workspace/tasks"
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

Write-BlankLine

# ═══════════════════════════════════════════════════════════════════
# 6. OUTPUT HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-DotbotSection -Title "OUTPUT HYGIENE"

$scanDirs = @()
$scriptsDir = Join-Path $BotRoot "src" "cli"
if (Test-Path $scriptsDir) { $scanDirs += $scriptsDir }
# Doctor only scans the project tier (<BotRoot>/content/workflows/). Framework
# workflows live under <DOTBOT_HOME>/content/workflows/ and are the framework's
# own hygiene concern, not the project's. The legacy <BotRoot>/workflows/
# location is no longer part of the discovery layout.
$projectWorkflowsDir = Join-Path $BotRoot "content" "workflows"
if (Test-Path $projectWorkflowsDir) {
    Get-ChildItem $projectWorkflowsDir -Directory | ForEach-Object {
        $wfScripts = Join-Path $_.FullName "src" "cli"
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
        Write-Check "Write-Host usage" "$writeHostCount occurrence(s) — use Write-BotLog or theme helpers instead" Warn
    }
    if ($consoleErrorCount -gt 0) {
        Write-Check "Console.Error traces" "$consoleErrorCount occurrence(s) — remove debug traces" Warn
    }
    foreach ($f in $findings) {
        Write-DotbotCommand "$f"
    }
}

Write-BlankLine

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

if ($HaveDotbotTheme) {
    Write-Separator -Width 44
    Write-BlankLine
    Write-Grid -Columns 3 -Items @(
        (Format-Phosphor "PASS: $passes" Success)
        (Format-Phosphor "WARN: $warns"  $(if ($warns  -gt 0) { 'Warning' } else { 'Muted' }))
        (Format-Phosphor "FAIL: $errors" $(if ($errors -gt 0) { 'Error'   } else { 'Muted' }))
    )
    Write-BlankLine
} else {
    Write-DotbotCommand "────────────────────────────────────────────"
    Write-BlankLine
    $summary = "$passes passed, $warns warnings, $errors errors"
    if ($errors -gt 0) {
        Write-DotbotError $summary
    } elseif ($warns -gt 0) {
        Write-DotbotWarning $summary
    } else {
        Write-Success $summary
    }
    Write-BlankLine
}

if ($errors -gt 0) { exit 2 }
elseif ($warns -gt 0) { exit 1 }
else { exit 0 }
