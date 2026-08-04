#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Show a single team member record by name (case-insensitive).

.PARAMETER Name
    The member's name.
#>
param(
    [Parameter(Position = 0)]
    [string]$Name
)

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

if (-not $Name) {
    Write-DotbotWarning "Usage: dotbot team get <name>"
    exit 1
}

try {
    $member = Get-DotbotTeamMember -BotRoot $BotDir -Name $Name
} catch {
    Write-DotbotError $_.Exception.Message
    exit 1
}

if (-not $member) {
    Write-DotbotError "No team member named '$Name'."
    exit 1
}

Write-BlankLine
Write-DotbotSection -Title "TEAM MEMBER"
Write-DotbotLabel -Label 'name       ' -Value ([string]$member.name) -ValueType Success
Write-DotbotLabel -Label 'id         ' -Value ([string]$member.id)
Write-DotbotLabel -Label 'email      ' -Value ([string]$member.email)
$role = if ([string]::IsNullOrWhiteSpace($member.role)) { '<none>' } else { [string]$member.role }
Write-DotbotLabel -Label 'role       ' -Value $role
# ConvertFrom-Json -AsHashtable auto-parses ISO strings to [DateTime].
# Render back as UTC ISO so the CLI matches the on-disk format.
$createdAt = if ($member.created_at -is [DateTime]) {
    $member.created_at.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
} else {
    [string]$member.created_at
}
Write-DotbotLabel -Label 'created_at ' -Value $createdAt
Write-DotbotLabel -Label 'created_by ' -Value ([string]$member.created_by)
Write-BlankLine
