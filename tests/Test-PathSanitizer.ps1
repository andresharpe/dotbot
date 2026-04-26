#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Unit tests for PathSanitizer module (Remove-AbsolutePaths).
.DESCRIPTION
    Tests path sanitization with Windows, macOS, Linux paths,
    JSON-escaped backslashes, git-bash style paths, and edge cases.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  PathSanitizer Unit Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Import the module under test
$modulePath = Join-Path $PSScriptRoot "../core/mcp/modules/PathSanitizer.psm1"
Import-Module $modulePath -Force

# ═══════════════════════════════════════════════════════════════════
# NULL / EMPTY INPUT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  NULL / EMPTY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$result = Remove-AbsolutePaths -Text $null -ProjectRoot "C:\Users\testuser\repos\myproject"
Assert-True -Name "Null input returns null" -Condition ($null -eq $result -or $result -eq "") -Message "Got: '$result'"

$result = Remove-AbsolutePaths -Text "" -ProjectRoot "C:\Users\testuser\repos\myproject"
Assert-True -Name "Empty input returns empty" -Condition ($result -eq "") -Message "Got: '$result'"

$result = Remove-AbsolutePaths -Text "hello world" -ProjectRoot ""
Assert-Equal -Name "Empty project root still applies safety net" -Expected "hello world" -Actual $result

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROJECT ROOT REPLACEMENT (WINDOWS)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROJECT ROOT (WINDOWS)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$projectRoot = "C:\Users\testuser\repos\my-project"

# Native backslash path
$result = Remove-AbsolutePaths -Text "Reading C:\Users\testuser\repos\my-project\.bot\workspace\tasks\todo\task.json" -ProjectRoot $projectRoot
Assert-Equal -Name "Windows backslash project root replaced" `
    -Expected "Reading .\.bot\workspace\tasks\todo\task.json" -Actual $result

# Forward-slash variant
$result = Remove-AbsolutePaths -Text "cd C:/Users/testuser/repos/my-project && git status" -ProjectRoot $projectRoot
Assert-Equal -Name "Forward-slash project root replaced" `
    -Expected "cd . && git status" -Actual $result

# Git-bash style /c/Users/...
$result = Remove-AbsolutePaths -Text "cd /c/Users/testuser/repos/my-project && git add ." -ProjectRoot $projectRoot
Assert-Equal -Name "Git-bash /c/ project root replaced" `
    -Expected "cd . && git add ." -Actual $result

# JSON-escaped double backslash
$result = Remove-AbsolutePaths -Text "path=C:\\Users\\testuser\\repos\\my-project\\.bot" -ProjectRoot $projectRoot
Assert-Equal -Name "JSON-escaped double backslash project root replaced" `
    -Expected "path=.\\.bot" -Actual $result

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SAFETY NET: WINDOWS USER PATHS (outside project root)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SAFETY NET (WINDOWS)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$result = Remove-AbsolutePaths -Text "C:\Users\testuser\.claude\projects\cache.txt" -ProjectRoot $projectRoot
Assert-Equal -Name "Windows path outside project root redacted" `
    -Expected "<REDACTED>\.claude\projects\cache.txt" -Actual $result

$result = Remove-AbsolutePaths -Text "D:\Users\otheruser\documents\file.txt" -ProjectRoot $projectRoot
Assert-Equal -Name "Different drive letter user path redacted" `
    -Expected "<REDACTED>\documents\file.txt" -Actual $result

$result = Remove-AbsolutePaths -Text "C:/Users/testuser/.claude/settings.json" -ProjectRoot $projectRoot
Assert-Equal -Name "Forward-slash Windows user path redacted" `
    -Expected "<REDACTED>/.claude/settings.json" -Actual $result

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SAFETY NET: LINUX / macOS PATHS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SAFETY NET (LINUX / macOS)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$result = Remove-AbsolutePaths -Text "file at /home/developer/project/src/main.py" -ProjectRoot ""
Assert-Equal -Name "Linux /home/ path redacted" `
    -Expected "file at <REDACTED>/project/src/main.py" -Actual $result

$result = Remove-AbsolutePaths -Text "reading /Users/macuser/.config/app.json" -ProjectRoot ""
Assert-Equal -Name "macOS /Users/ path redacted" `
    -Expected "reading <REDACTED>/.config/app.json" -Actual $result

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# MIXED CONTENT (paths embedded in larger messages)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MIXED CONTENT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$msg = "cd /c/Users/testuser/repos/my-project && grep -in 'Users' ""C:\Users\testuser\.claude\projects\file.txt"""
$result = Remove-AbsolutePaths -Text $msg -ProjectRoot $projectRoot
$hasProjectRoot = $result -match [regex]::Escape($projectRoot)
$hasUserPath = $result -match '[A-Za-z]:[/\\]+Users[/\\]+\w+'
Assert-True -Name "Mixed message: no project root or user paths remain" `
    -Condition (-not $hasProjectRoot -and -not $hasUserPath) `
    -Message "Got: $result"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SHOULD NOT MATCH (safe content)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SHOULD NOT MATCH" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$result = Remove-AbsolutePaths -Text "No paths here, just regular text" -ProjectRoot $projectRoot
Assert-Equal -Name "Plain text unchanged" `
    -Expected "No paths here, just regular text" -Actual $result

$result = Remove-AbsolutePaths -Text ".bot/workspace/tasks/done/task.json" -ProjectRoot $projectRoot
Assert-Equal -Name "Relative path unchanged" `
    -Expected ".bot/workspace/tasks/done/task.json" -Actual $result

$result = Remove-AbsolutePaths -Text "https://example.com/Users/api/v2" -ProjectRoot $projectRoot
# This would match /Users/api but that's acceptable — it's the safety net
# The important thing is it doesn't crash
Assert-True -Name "URL with /Users/ doesn't crash" -Condition ($null -ne $result) -Message "Result was null"

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROJECT ROOT ON LINUX/macOS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROJECT ROOT (LINUX)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$linuxRoot = "/home/developer/repos/myproject"
$result = Remove-AbsolutePaths -Text "Reading /home/developer/repos/myproject/src/main.py" -ProjectRoot $linuxRoot
Assert-Equal -Name "Linux project root replaced" `
    -Expected "Reading ./src/main.py" -Actual $result

$macRoot = "/Users/macuser/repos/myproject"
$result = Remove-AbsolutePaths -Text "Reading /Users/macuser/repos/myproject/src/main.py" -ProjectRoot $macRoot
Assert-Equal -Name "macOS project root replaced" `
    -Expected "Reading ./src/main.py" -Actual $result

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "PathSanitizer Unit Tests"
if (-not $allPassed) { exit 1 }
