#!/usr/bin/env pwsh
<#
.SYNOPSIS
    List all registered dotbot extension registries.

.DESCRIPTION
    Reads ~/dotbot/registries.json and displays each registered registry
    with its metadata, health status, and available content.

.EXAMPLE
    registry-list.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$RegistriesDir = Join-Path $DotbotBase "registries"
$ConfigPath = Join-Path $DotbotBase "registries.json"

# Import platform functions if available
$platformFunctionsPath = Join-Path $DotbotBase "scripts\Platform-Functions.psm1"
if (Test-Path $platformFunctionsPath) {
    Import-Module $platformFunctionsPath -Force
}

# Helper: write output consistently even if Platform-Functions not loaded
if (-not (Get-Command Write-Success -ErrorAction SilentlyContinue)) {
    function Write-Success ($msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }
}
if (-not (Get-Command Write-DotbotWarning -ErrorAction SilentlyContinue)) {
    function Write-DotbotWarning ($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
}
if (-not (Get-Command Write-DotbotError -ErrorAction SilentlyContinue)) {
    function Write-DotbotError ($msg) { Write-Host "  ✗ $msg" -ForegroundColor Red }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T   v3.5" -ForegroundColor Blue
Write-Host "    Registries" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Read registries.json
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-Host "  No registries configured." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Add one with: dotbot registry add <name> <source>" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

$config = $null
try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-DotbotError "Failed to parse registries.json: $($_.Exception.Message)"
    exit 1
}

if (-not $config.registries -or $config.registries.Count -eq 0) {
    Write-Host "  No registries configured." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Add one with: dotbot registry add <name> <source>" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

Write-Host "  $($config.registries.Count) registry(ies) registered" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------------------
# 2. Display each registry
# ---------------------------------------------------------------------------
foreach ($entry in $config.registries) {
    $name = $entry.name
    $registryPath = Join-Path $RegistriesDir $name

    Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  $name" -ForegroundColor Cyan -NoNewline

    # Health check: does the path exist?
    if (-not (Test-Path $registryPath)) {
        Write-Host "  (MISSING)" -ForegroundColor Red
        Write-Host "    Source:  $($entry.source)" -ForegroundColor DarkGray
        Write-Host "    Path:   $registryPath" -ForegroundColor DarkGray
        Write-DotbotError "Registry directory not found. Re-add with: dotbot registry add $name $($entry.source) --force"
        Write-Host ""
        continue
    }

    # Read registry.yaml for metadata
    $registryYaml = Join-Path $registryPath "registry.yaml"
    $meta = $null
    $contentMap = @{}

    if (Test-Path $registryYaml) {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $meta = Get-Content $registryYaml -Raw | ConvertFrom-Yaml
        } catch {
            Write-Host ""
            Write-DotbotWarning "Failed to parse registry.yaml"
        }
    } else {
        Write-Host ""
        Write-DotbotWarning "registry.yaml not found"
    }

    # Display name and version
    if ($meta) {
        $displayName = if ($meta['display_name']) { $meta['display_name'] } else { $name }
        $version = if ($meta['version']) { $meta['version'] } else { '?' }
        Write-Host "  ($displayName v$version)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }

    # Registry details
    Write-Host "    Source:  $($entry.source)" -ForegroundColor White
    Write-Host "    Type:   $($entry.type)" -ForegroundColor White -NoNewline
    if ($entry.branch) {
        Write-Host "  Branch: $($entry.branch)" -ForegroundColor White
    } else {
        Write-Host ""
    }
    if ($entry.added_at) {
        $addedDate = try { ([datetime]$entry.added_at).ToString("dd MMM yyyy") } catch { "$($entry.added_at)" }
        Write-Host "    Added:  $addedDate" -ForegroundColor DarkGray
    }

    # Description
    if ($meta -and $meta['description']) {
        Write-Host "    Desc:   $($meta['description'])" -ForegroundColor DarkGray
    }

    # Content listing
    if ($meta -and $meta['content']) {
        Write-Host ""
        Write-Host "    AVAILABLE CONTENT" -ForegroundColor Yellow

        $contentTypes = @('workflows', 'stacks', 'tools', 'skills', 'agents')
        foreach ($type in $contentTypes) {
            $items = $meta['content'][$type]
            if ($items -and $items.Count -gt 0) {
                foreach ($item in $items) {
                    $itemPath = Join-Path $registryPath "$type\$item"
                    $exists = Test-Path $itemPath
                    $icon = if ($exists) { "✓" } else { "?" }
                    $color = if ($exists) { "Green" } else { "Yellow" }
                    Write-Host "      $icon " -ForegroundColor $color -NoNewline
                    Write-Host "${name}:${item}" -ForegroundColor Cyan -NoNewline
                    Write-Host " ($type)" -ForegroundColor DarkGray

                    # Show workflow description from its manifest
                    if ($type -eq 'workflows' -and $exists) {
                        $wfManifest = Join-Path $itemPath "workflow.yaml"
                        if (-not (Test-Path $wfManifest)) {
                            $wfManifest = Join-Path $itemPath "profile.yaml"
                        }
                        if (Test-Path $wfManifest) {
                            try {
                                $wfMeta = Get-Content $wfManifest -Raw | ConvertFrom-Yaml
                                $wfDesc = if ($wfMeta['description']) { $wfMeta['description'] }
                                           elseif ($wfMeta['display_name']) { $wfMeta['display_name'] }
                                           else { $null }
                                if ($wfDesc) {
                                    Write-Host "        $wfDesc" -ForegroundColor DarkGray
                                }
                            } catch { Write-Verbose "Failed to parse data: $_" }
                        }
                    }
                }
            }
        }
    }

    Write-Host ""
}

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  Use with: dotbot init --workflow <registry>:<workflow>" -ForegroundColor Yellow
Write-Host ""
