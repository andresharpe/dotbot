#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remove a registered dotbot extension registry.

.DESCRIPTION
    Removes a registry by name: deletes the local registry directory (cloned
    repo or junction/symlink) and removes the entry from registries.json.

.PARAMETER Name
    Registry namespace to remove (e.g., "myorg").

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    registry-remove.ps1 -Name myorg
    registry-remove.ps1 -Name myorg -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$DotbotBase = Get-DotbotInstallPath
$RegistriesDir = Join-Path $DotbotBase "registries"
$RegistryPath = Join-Path $RegistriesDir $Name
$ConfigPath = Join-Path $DotbotBase "registries.json"

# Import platform functions (required for theme helpers)
$PlatformFunctionsModule = Join-Path $PSScriptRoot "Platform-Functions.psm1"
if (-not (Test-Path $PlatformFunctionsModule)) {
    Write-Error "Required module not found: $PlatformFunctionsModule — run 'dotbot update' to repair"
    exit 1
}
Import-Module $PlatformFunctionsModule -Force -ErrorAction Stop
Import-Module (Join-Path (Get-DotbotInstallPath) "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1") -Force -DisableNameChecking

Write-DotbotBanner -Title "D O T B O T" -Subtitle "Registry: Remove"

# ---------------------------------------------------------------------------
# 1. Check registry exists in registries.json
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-DotbotError "No registries.json found — no registries have been added"
    exit 1
}

$config = $null
try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-DotbotError "Failed to parse registries.json: $_"
    exit 1
}

if (-not $config.registries) {
    Write-DotbotError "registries.json contains no registries"
    exit 1
}

$entry = $config.registries | Where-Object { $_.name -eq $Name }
if (-not $entry) {
    Write-DotbotError "Registry '$Name' is not registered"
    Write-DotbotCommand "Run 'dotbot registry list' to see registered registries"
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Confirm removal
# ---------------------------------------------------------------------------
if (-not $Force) {
    Write-DotbotWarning "This will remove registry '$Name' and delete its local files"
    Write-DotbotLabel -Label "Source" -Value "$($entry.source)"
    Write-DotbotLabel -Label "Type  " -Value "$($entry.type)"
    Write-BlankLine
    $answer = Read-Host "Remove registry '$Name'? [y/N]"
    if ($answer -notmatch '^[Yy]$') {
        Write-DotbotWarning "Aborted"
        exit 0
    }
}

# ---------------------------------------------------------------------------
# 3. Delete the local registry directory / symlink / junction
# ---------------------------------------------------------------------------
if (Test-Path $RegistryPath) {
    $item = Get-Item -LiteralPath $RegistryPath -Force
    # Junctions and symlinks must be removed without -Recurse to avoid
    # deleting the target contents
    $isJunctionOrSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isJunctionOrSymlink) {
        Write-Status "Removing symlink/junction: $RegistryPath"
        $item.Delete()
    } else {
        Write-Status "Removing registry directory: $RegistryPath"
        Remove-Item -Path $RegistryPath -Recurse -Force
    }
    Write-Success "Removed local registry files"
} else {
    Write-DotbotWarning "Registry directory not found at $RegistryPath — skipping file removal"
}

# ---------------------------------------------------------------------------
# 4. Remove entry from registries.json
# ---------------------------------------------------------------------------
$config.registries = @($config.registries | Where-Object { $_.name -ne $Name })
$config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath
Write-Success "Removed '$Name' from registries.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-BlankLine
Write-DotbotBanner -Title "Registry '$Name' removed"
Write-BlankLine
