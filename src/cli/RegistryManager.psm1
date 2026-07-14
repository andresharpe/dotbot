#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Registry state management helpers for dotbot.

.DESCRIPTION
    Provides functions for reading registry metadata and auto-updating stale
    git-based registries. Consumed by dotbot init and dotbot run.
#>

$ErrorActionPreference = "Stop"

function Get-DotbotRegistries {
    <#
    .SYNOPSIS
        Returns all registered registries from registries.json as an array.
        Returns an empty array if the file does not exist or has no entries.
    #>
    param(
        [Parameter(Mandatory)][string]$DotbotBase
    )
    $configPath = Join-Path $DotbotBase "registries.json"
    if (-not (Test-Path $configPath)) { return @() }
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($config.registries) { return @($config.registries) }
    } catch {
        Write-DotbotWarning "Failed to parse registries.json — skipping registry auto-update: $($_.Exception.Message)"
    }
    return @()
}

function Update-StaleRegistries {
    <#
    .SYNOPSIS
        Pulls the latest commits for all git-based registries that have
        auto_update set to true. Silently skips local (symlink) registries.

    .DESCRIPTION
        Called automatically by dotbot init and dotbot run. Failures are
        non-fatal: a warning is emitted and the stale local copy is used.

    .PARAMETER DotbotBase
        Resolved dotbot install path (DOTBOT_HOME).

    .PARAMETER MaxAgeSecs
        Only update registries whose last update is older than this many
        seconds. Defaults to 3600 (1 hour) to avoid hammering git on every
        run. Pass 0 to force-update all eligible registries.
    #>
    param(
        [Parameter(Mandatory)][string]$DotbotBase,
        [int]$MaxAgeSecs = 3600
    )

    $configPath   = Join-Path $DotbotBase "registries.json"
    $registries   = Get-DotbotRegistries -DotbotBase $DotbotBase
    if ($registries.Count -eq 0) { return }

    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $changed = $false

    foreach ($entry in $registries) {
        if (-not $entry.auto_update) { continue }
        if ($entry.type -ne "git")   { continue }

        # Validate name and ensure resolved path stays under the registries root
        $rawName  = [string]$entry.name
        $safeName = [System.IO.Path]::GetFileName($rawName)
        if ($safeName -ne $rawName -or $safeName -in @('.', '..') -or $safeName -notmatch '^[A-Za-z0-9._-]+$') {
            Write-DotbotWarning "Registry name '$rawName' is invalid — skipping auto-update"
            continue
        }
        $registriesRoot = [System.IO.Path]::GetFullPath((Join-Path $DotbotBase "registries"))
        $registryPath   = [System.IO.Path]::GetFullPath((Join-Path $registriesRoot $safeName))
        $rootWithSep    = $registriesRoot.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $registryPath.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-DotbotWarning "Registry '$safeName' resolves outside registries directory — skipping auto-update"
            continue
        }

        if (-not (Test-Path -LiteralPath $registryPath -PathType Container)) {
            Write-DotbotWarning "Registry '$safeName' directory missing — skipping auto-update"
            continue
        }

        # Honour MaxAgeSecs: skip if updated recently
        if ($MaxAgeSecs -gt 0 -and $entry.updated_at) {
            try {
                $lastUpdate = [datetime]::Parse($entry.updated_at)
                $ageSecs = ([datetime]::UtcNow - $lastUpdate.ToUniversalTime()).TotalSeconds
                if ($ageSecs -lt $MaxAgeSecs) { continue }
            } catch { }
        }

        # git fetch + fast-forward merge
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-DotbotWarning "git not found on PATH — skipping registry auto-update"
            return
        }
        $branch = if ($entry.branch) { $entry.branch } else { "main" }
        $null = & git -C $registryPath fetch --quiet origin $branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-DotbotWarning "Auto-update failed for registry '$safeName' (fetch error) — using cached copy"
            continue
        }

        $null = & git -C $registryPath merge --ff-only "origin/$branch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-DotbotWarning "Auto-update failed for registry '$safeName' (cannot fast-forward) — using cached copy"
            continue
        }

        # Record updated_at timestamp
        $config.registries = @($config.registries | ForEach-Object {
            if ($_.name -eq $entry.name) {
                $_ | Add-Member -NotePropertyName 'updated_at' -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
                $changed = $true
            }
            $_
        })
    }

    if ($changed) {
        $config | ConvertTo-Json -Depth 5 | Set-Content $configPath
    }
}

Export-ModuleMember -Function Get-DotbotRegistries, Update-StaleRegistries
