#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List every member in the project's workspace team registry.
#>
param()

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$BotDir     = Get-DotbotProjectBotPath

Import-Module (Join-Path $DotbotBase "src/cli/Platform-Functions.psm1") -Force
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1") -Force -DisableNameChecking
Import-Module (Join-Path $DotbotBase "src/runtime/Modules/Dotbot.TeamRegistry/Dotbot.TeamRegistry.psd1") -Force -DisableNameChecking

if (-not (Test-Path $BotDir)) {
    Write-DotbotError "No .bot directory found. Run 'dotbot init' first."
    exit 1
}

try {
    $members = Get-DotbotTeamMembers -BotRoot $BotDir
} catch {
    Write-DotbotError $_.Exception.Message
    exit 1
}

Write-BlankLine
Write-DotbotSection -Title "TEAM MEMBERS"

if (-not $members -or $members.Count -eq 0) {
    Write-DotbotCommand "(none)"
    Write-BlankLine
    return
}

foreach ($m in $members) {
    $role = if ([string]::IsNullOrWhiteSpace($m.role)) { '<none>' } else { [string]$m.role }
    # ConvertFrom-Json -AsHashtable auto-parses ISO strings to [DateTime].
    # Render back as UTC ISO so the CLI matches the on-disk format.
    $addedAt = if ($m.created_at -is [DateTime]) {
        $m.created_at.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    } else {
        [string]$m.created_at
    }
    Write-DotbotLabel -Label $([string]$m.name).PadRight(24) -Value $role -ValueType Info
    Write-DotbotCommand "$(' ' * 24)id: $($m.id) · added: $addedAt"
}

Write-BlankLine
