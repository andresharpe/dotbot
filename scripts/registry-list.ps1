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

# Import platform functions (required for theme helpers)
$PlatformFunctionsModule = Join-Path $PSScriptRoot "Platform-Functions.psm1"
if (-not (Test-Path $PlatformFunctionsModule)) {
    Write-Error "Required module not found: $PlatformFunctionsModule — run 'dotbot update' to repair"
    exit 1
}
Import-Module $PlatformFunctionsModule -Force -ErrorAction Stop
Import-Module (Join-Path $DotbotBase "core/runtime/modules/DotBotTheme.psm1") -Force -DisableNameChecking
. (Join-Path $DotbotBase "core/runtime/modules/workflow-manifest.ps1")

Write-DotbotBanner -Title "D O T B O T   v3.5" -Subtitle "Registries"

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

Write-Status "$($config.registries.Count) registry(ies) registered"
Write-BlankLine

# ---------------------------------------------------------------------------
# 2. Display each registry
# ---------------------------------------------------------------------------
foreach ($entry in $config.registries) {
    $name = $entry.name
    $registryPath = Join-Path $RegistriesDir $name

    Write-DotbotCommand "─────────────────────────────────────────"

    # Health check: does the path exist?
    if (-not (Test-Path $registryPath)) {
        Write-DotbotError "$name (MISSING)"
        Write-DotbotCommand "Source:  $($entry.source)"
        Write-DotbotCommand "Path:   $registryPath"
        Write-DotbotError "Registry directory not found. Re-add with: dotbot registry add $name $($entry.source) --force"
        Write-BlankLine
        continue
    }

    Write-Status "$name"

    # Read registry.yaml for metadata
    $registryYaml = Join-Path $registryPath "registry.yaml"
    $meta = $null
    if (Test-Path $registryYaml) {
        try {
            Import-Module powershell-yaml -ErrorAction Stop
            $meta = Get-Content $registryYaml -Raw | ConvertFrom-Yaml
        } catch {
            Write-BlankLine
            Write-DotbotWarning "Failed to parse registry.yaml"
        }
    } else {
        Write-BlankLine
        Write-DotbotWarning "registry.yaml not found"
    }

    # Display name and version
    if ($meta) {
        $displayName = if ($meta['display_name']) { $meta['display_name'] } else { $name }
        $version = if ($meta['version']) { $meta['version'] } else { '?' }
        Write-DotbotCommand "($displayName v$version)"
    } else {
        Write-BlankLine
    }

    # Registry details
    Write-DotbotLabel -Label "Source  " -Value "$($entry.source)"
    $branchInfo = if ($entry.branch) { "$($entry.type)  Branch: $($entry.branch)" } else { "$($entry.type)" }
    Write-DotbotLabel -Label "Type    " -Value "$branchInfo"
    if ($entry.added_at) {
        $addedDate = try { ([datetime]$entry.added_at).ToString("dd MMM yyyy") } catch { "$($entry.added_at)" }
        Write-DotbotCommand "Added:  $addedDate"
    }

    # Description
    if ($meta -and $meta['description']) {
        Write-DotbotCommand "Desc:   $($meta['description'])"
    }

    # Content listing
    if ($meta -and $meta['content']) {
        Write-BlankLine
        Write-DotbotSection -Title "AVAILABLE CONTENT"

        $contentTypes = @('workflows', 'stacks', 'tools', 'skills', 'agents')
        foreach ($type in $contentTypes) {
            $items = $meta['content'][$type]
            if ($items -and $items.Count -gt 0) {
                foreach ($item in $items) {
                    $itemPath = Join-Path $registryPath "$type\$item"
                    $exists = Test-Path $itemPath
                    $icon = if ($exists) { "✓" } else { "?" }
                    Write-Status "$icon ${name}:${item} ($type)"

                    # Show workflow description from its manifest
                    if ($type -eq 'workflows' -and $exists -and (Test-ValidWorkflowDir -Dir $itemPath)) {
                        $wfManifest = Join-Path $itemPath "workflow.yaml"
                        try {
                            $wfMeta = Get-Content $wfManifest -Raw | ConvertFrom-Yaml
                            $wfDesc = if ($wfMeta['description']) { $wfMeta['description'] }
                                       elseif ($wfMeta['display_name']) { $wfMeta['display_name'] }
                                       else { $null }
                            if ($wfDesc) {
                                Write-DotbotCommand "  $wfDesc"
                            }
                        } catch { Write-DotbotCommand "Parse skipped: $_" }
                    }
                }
            }
        }
    }

    Write-BlankLine
}

Write-BlankLine
Write-DotbotCommand "Use with: dotbot init --workflow <registry>:<workflow>"
Write-BlankLine
