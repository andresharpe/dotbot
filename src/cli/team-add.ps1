#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add a team member to the project's workspace team registry.

.DESCRIPTION
    Persists a new entry to .bot/workspace/team-registry.json. Names must be
    unique (case-insensitive) — a follow-up ticket adds team update / remove.

.PARAMETER Name
    Case-preserving unique identifier for the member.

.PARAMETER Role
    Optional role string (e.g. developer, reviewer, product).

.EXAMPLE
    dotbot team add ana-smith --role developer
#>
param(
    [Parameter(Position = 0)]
    [string]$Name,

    [string]$Role
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
    Write-DotbotWarning "Usage: dotbot team add <name> [--role <role>]"
    Write-DotbotCommand "Example: dotbot team add ana-smith --role developer"
    exit 1
}

try {
    $member = Add-DotbotTeamMember -BotRoot $BotDir -Name $Name -Role $Role
} catch {
    Write-DotbotError $_.Exception.Message
    exit 1
}

$roleDisplay = if ([string]::IsNullOrWhiteSpace($member.role)) { '<none>' } else { $member.role }
Write-Success "Added $($member.name) ($($member.id)) — role: $roleDisplay"
