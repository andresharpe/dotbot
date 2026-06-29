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
    } catch { }
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

        $registryPath = Join-Path $DotbotBase "registries" $entry.name

        if (-not (Test-Path $registryPath)) {
            Write-Warning "dotbot: registry '$($entry.name)' directory missing — skipping auto-update"
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
        $branch = if ($entry.branch) { $entry.branch } else { "main" }
        $fetchOut = & git -C $registryPath fetch --quiet origin $branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "dotbot: auto-update failed for registry '$($entry.name)' (fetch error) — using cached copy"
            continue
        }

        $mergeOut = & git -C $registryPath merge --ff-only "origin/$branch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "dotbot: auto-update failed for registry '$($entry.name)' (cannot fast-forward) — using cached copy"
            continue
        }

        # Record updated_at timestamp
        $idx = [array]::IndexOf($config.registries, ($config.registries | Where-Object { $_.name -eq $entry.name }))
        if ($idx -ge 0) {
            $config.registries[$idx] | Add-Member -NotePropertyName "updated_at" -NotePropertyValue (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ") -Force
            $changed = $true
        }
    }

    if ($changed) {
        $config | ConvertTo-Json -Depth 5 | Set-Content $configPath
    }
}

Export-ModuleMember -Function Get-DotbotRegistries, Update-StaleRegistries
