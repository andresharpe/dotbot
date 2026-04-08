#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Update one or all registered dotbot extension registries.

.DESCRIPTION
    For git-based registries, fetches and resets to the latest remote state.
    For local (symlinked) registries, re-validates registry.yaml.
    Re-validates content after update and records the update timestamp.

.PARAMETER Name
    Registry name to update. Omit to update all registered registries.

.PARAMETER Force
    For git registries, use 'git reset --hard' instead of '--ff-only' to
    discard any local changes.

.EXAMPLE
    registry-update.ps1
    registry-update.ps1 -Name myorg
    registry-update.ps1 -Name myorg -Force
#>

[CmdletBinding()]
param(
    [string]$Name,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$DotbotBase    = Join-Path $HOME "dotbot"
$RegistriesDir = Join-Path $DotbotBase "registries"
$ConfigPath    = Join-Path $DotbotBase "registries.json"

# Import platform functions
$PlatformFunctionsModule = Join-Path $PSScriptRoot "Platform-Functions.psm1"
if (-not (Test-Path $PlatformFunctionsModule)) {
    Write-Error "Required module not found: $PlatformFunctionsModule — run 'dotbot update' to repair"
    exit 1
}
Import-Module $PlatformFunctionsModule -Force -ErrorAction Stop

Write-DotbotBanner -Title "D O T B O T   v3.5" -Subtitle "Registry: Update"

# ---------------------------------------------------------------------------
# 1. Read registries.json
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    Write-DotbotCommand "No registries configured."
    Write-BlankLine
    Write-DotbotWarning "Add one with: dotbot registry add <name> <source>"
    Write-BlankLine
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
    Write-DotbotCommand "No registries configured."
    Write-BlankLine
    Write-DotbotWarning "Add one with: dotbot registry add <name> <source>"
    Write-BlankLine
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Select registries to update
# ---------------------------------------------------------------------------
if ($Name) {
    $targets = @($config.registries | Where-Object { $_.name -eq $Name })
    if ($targets.Count -eq 0) {
        Write-DotbotError "Registry '$Name' not found"
        Write-BlankLine
        Write-DotbotCommand "Run 'dotbot registry list' to see registered registries"
        Write-BlankLine
        exit 1
    }
} else {
    $targets = @($config.registries)
    Write-Status "Updating $($targets.Count) registry(ies)"
    Write-BlankLine
}

# ---------------------------------------------------------------------------
# Helper: validate registry.yaml (shared with registry-add.ps1 logic)
# ---------------------------------------------------------------------------
function Invoke-RegistryValidation {
    param([string]$RegistryPath, [string]$RegistryName)

    $registryYamlPath = Join-Path $RegistryPath "registry.yaml"

    if (-not (Test-Path $registryYamlPath)) {
        Write-DotbotError "registry.yaml not found in $RegistryPath"
        return $false
    }
    Write-Success "registry.yaml found"

    # Parse
    $meta = @{}
    $contentSection = $null
    try {
        Get-Content $registryYamlPath | ForEach-Object {
            if ($_ -match '^\s*(name|display_name|description|version|min_dotbot_version)\s*:\s*(.+)$') {
                $meta[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            }
            if ($_ -match '^\s*content\s*:') { $contentSection = @{} }
            if ($contentSection -and $_ -match '^\s+(workflows|stacks|tools|skills|agents)\s*:\s*\[(.+)\]') {
                $items = $Matches[2] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
                $contentSection[$Matches[1]] = $items
            }
        }
        if ($contentSection) { $meta['content'] = $contentSection }
    } catch {
        Write-DotbotError "Failed to parse registry.yaml: $_"
        return $false
    }
    Write-Success "registry.yaml parses correctly"

    # Name must match
    if ($meta['name'] -ne $RegistryName) {
        Write-DotbotError "Name mismatch: registry.yaml says '$($meta['name'])', expected '$RegistryName'"
        return $false
    }
    Write-Success "Name matches: '$RegistryName'"

    # Content must declare at least one item
    $contentMap = $meta['content']
    if (-not $contentMap -or $contentMap.Count -eq 0) {
        Write-DotbotError "registry.yaml 'content' section is empty or missing"
        return $false
    }
    $totalContent = 0
    foreach ($key in $contentMap.Keys) { $totalContent += @($contentMap[$key]).Count }
    Write-Success "Content declares $totalContent item(s)"

    # Warn about missing directories (non-fatal)
    $missingDirs = @()
    foreach ($type in $contentMap.Keys) {
        foreach ($item in $contentMap[$type]) {
            $itemDir = Join-Path $RegistryPath "$type\$item"
            if (-not (Test-Path $itemDir)) { $missingDirs += "$type/$item" }
        }
    }
    if ($missingDirs.Count -gt 0) {
        foreach ($d in $missingDirs) { Write-DotbotWarning "Declared content directory not found: $d" }
    } else {
        Write-Success "All declared content directories exist"
    }

    # Surface version for display
    return $meta
}

# ---------------------------------------------------------------------------
# 3. Update each target
# ---------------------------------------------------------------------------
$updatedCount = 0
$failedCount  = 0

foreach ($entry in $targets) {
    $entryName    = $entry.name
    $registryPath = Join-Path $RegistriesDir $entryName

    Write-DotbotSection -Title "$entryName"

    if (-not (Test-Path $registryPath)) {
        Write-DotbotError "Registry directory not found: $registryPath"
        Write-DotbotWarning "Re-add with: dotbot registry add $entryName $($entry.source) --force"
        $failedCount++
        Write-BlankLine
        continue
    }

    $entrySucceeded = $false

    if ($entry.type -eq 'local') {
        # Local: symlink/junction is always current — just re-validate
        Write-Status "Local registry — re-validating (symlink tracks source automatically)"
        $result = Invoke-RegistryValidation -RegistryPath $registryPath -RegistryName $entryName
        if ($result -eq $false) {
            $failedCount++
        } else {
            Write-Success "Registry '$entryName' is valid"
            $updatedCount++
            $entrySucceeded = $true
        }

    } else {
        # Git: fetch + reset
        $branch = if ($entry.branch) { $entry.branch } else { 'main' }

        if ($Force) {
            Write-Status "Fetching $branch (force reset)"
            $fetchOutput = & git -C $registryPath fetch origin $branch 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errText = ($fetchOutput | Out-String).Trim()
                Write-DotbotError "Fetch failed"
                Write-BlankLine
                if ($errText -match 'Authentication failed|401|403|could not read Username|terminal prompts disabled') {
                    Write-DotbotWarning "Authentication required — re-run: dotbot registry add $entryName $($entry.source) --force"
                } elseif ($errText -match 'not found|does not exist|404') {
                    Write-DotbotWarning "Repository not found. Check the URL and your access permissions."
                } else {
                    Write-DotbotCommand "$errText"
                }
                $failedCount++
                Write-BlankLine
                continue
            }
            $resetOutput = & git -C $registryPath reset --hard "origin/$branch" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-DotbotError "Reset failed: $($resetOutput | Out-String)"
                $failedCount++
                Write-BlankLine
                continue
            }
        } else {
            Write-Status "Pulling $branch (fast-forward)"
            $pullOutput = & git -C $registryPath pull --ff-only origin $branch 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errText = ($pullOutput | Out-String).Trim()
                Write-DotbotError "Pull failed"
                Write-BlankLine
                if ($errText -match 'Authentication failed|401|403|could not read Username|terminal prompts disabled') {
                    Write-DotbotWarning "Authentication required — re-run: dotbot registry add $entryName $($entry.source) --force"
                } elseif ($errText -match 'not found|does not exist|404') {
                    Write-DotbotWarning "Repository not found. Check the URL and your access permissions."
                } elseif ($errText -match "Remote branch.*not found|couldn't find remote ref") {
                    Write-DotbotWarning "Branch '$branch' not found on remote."
                } elseif ($errText -match 'Not possible to fast-forward|diverged') {
                    Write-DotbotWarning "Cannot fast-forward — use -Force to reset to remote state"
                } else {
                    Write-DotbotCommand "$errText"
                }
                $failedCount++
                Write-BlankLine
                continue
            }
        }

        Write-Success "Pulled latest from $($entry.source)"

        Write-BlankLine
        Write-DotbotSection -Title "VALIDATION"
        $result = Invoke-RegistryValidation -RegistryPath $registryPath -RegistryName $entryName
        if ($result -eq $false) {
            $failedCount++
        } else {
            $updatedCount++
            $entrySucceeded = $true
        }
    }

    # Record updated_at only when the update and validation both succeeded
    if ($entrySucceeded) {
        $config.registries = @($config.registries | ForEach-Object {
            if ($_.name -eq $entryName) {
                $_ | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) -Force
            }
            $_
        })
    }

    Write-BlankLine
}

# Persist updated timestamps
$config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-DotbotSection -Title "SUMMARY"
if ($updatedCount -gt 0) { Write-Success "$updatedCount registry(ies) updated" }
if ($failedCount -gt 0)  { Write-DotbotError "$failedCount registry(ies) failed" }
Write-BlankLine

if ($failedCount -gt 0) { exit 1 }
