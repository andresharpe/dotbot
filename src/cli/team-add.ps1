#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add a team member to the project's team registry.

.DESCRIPTION
    Persists a new entry to .bot/team-registry.json. Names must be unique
    (case-insensitive). Email is required — it's the contact address the
    downstream Q&A routing (#632/#600/#609) delivers questions to.
    A follow-up ticket (#631) adds team update / remove.

.PARAMETER Name
    Case-preserving unique identifier for the member.

.PARAMETER Email
    Contact address. Required. Basic 'user@domain.tld' shape enforced.

.PARAMETER Role
    Optional role. Must be one of: developer, lead, reviewer, qa.

.EXAMPLE
    dotbot team add ana-smith ana@example.com --role developer
    dotbot team add ana-smith --email ana@example.com --role developer
#>
param(
    [Parameter(Position = 0)]
    [string]$Name,

    [string]$Email,

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

if (-not $Name -or -not $Email) {
    Write-DotbotWarning "Usage: dotbot team add <name> <email> [--role <role>]"
    Write-DotbotCommand "Example: dotbot team add ana-smith ana@example.com --role developer"
    Write-DotbotCommand "Roles:   developer | lead | reviewer | qa"
    exit 1
}

try {
    $member = Add-DotbotTeamMember -BotRoot $BotDir -Name $Name -Email $Email -Role $Role
} catch {
    Write-DotbotError $_.Exception.Message
    exit 1
}

$roleDisplay = if ([string]::IsNullOrWhiteSpace($member.role)) { '<none>' } else { $member.role }
Write-Success "Added $($member.name) <$($member.email)> ($($member.id)) — role: $roleDisplay"
