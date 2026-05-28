#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install the dotbot PATH shim and point DOTBOT_HOME at this checkout.

.DESCRIPTION
    Drops bin/shim/dotbot (and dotbot.cmd on Windows) into a user-scoped
    PATH directory. The shim reads $env:DOTBOT_HOME and execs into
    <DOTBOT_HOME>/bin/dotbot.ps1.

    Bootstrap sets DOTBOT_HOME for the current process and writes a fallback
    into the installed shim. It does not edit Windows user environment
    variables or Unix shell rc/profile files. The shim fallback points at
    this checkout and still honors any explicit DOTBOT_HOME set later.

.PARAMETER ShimDir
    Override the default shim install location.
    Default on Linux/macOS: ~/.local/bin
    Default on Windows:     %LOCALAPPDATA%\Microsoft\WindowsApps
    The Windows default is already on PATH on Windows 10+; the Unix
    default is on PATH on most distributions (bootstrap warns otherwise).

.PARAMETER Force
    Overwrite any existing shim files in the destination directory.

.EXAMPLE
    pwsh ./bootstrap.ps1
.EXAMPLE
    pwsh ./bootstrap.ps1 -ShimDir /usr/local/bin -Force
#>

[CmdletBinding()]
param(
    [string]$ShimDir,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

# ---------------------------------------------------------------------------
# PowerShell 7+ guard (the rest of dotbot needs `$IsWindows`/`$IsMacOS`/
# `$IsLinux`, UTF-8 without BOM, and `-Recurse` semantics that PS 5.1
# does not provide reliably).
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('ERROR: PowerShell 7+ is required.')
    [Console]::Error.WriteLine("Current version: $($PSVersionTable.PSVersion)")
    [Console]::Error.WriteLine('Install pwsh from https://aka.ms/powershell, then re-run bootstrap.ps1 under it.')
    exit 1
}

# ---------------------------------------------------------------------------
# Locate the checkout (bootstrap.ps1 must live at the repo root) and the
# shim source dir. Theme helpers come from the same checkout so output
# stays on-brand without requiring DOTBOT_HOME.
# ---------------------------------------------------------------------------
$RepoDir = $PSScriptRoot
$ShimSrc = Join-Path $RepoDir 'bin/shim'
if (-not (Test-Path $ShimSrc)) {
    [Console]::Error.WriteLine("ERROR: bootstrap.ps1 must be run from a dotbot checkout (missing $ShimSrc).")
    exit 1
}

$platformFunctionsPath = Join-Path $RepoDir 'src/cli/Platform-Functions.psm1'
$themeModulePath       = Join-Path $RepoDir 'src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1'
if (Test-Path $platformFunctionsPath) { Import-Module $platformFunctionsPath -Force }
if (Test-Path $themeModulePath)       { Import-Module $themeModulePath       -Force -DisableNameChecking }

function ConvertTo-PosixSingleQuotedString {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + $Value.Replace("'", "'\''") + "'"
}

function ConvertTo-PowerShellSingleQuotedString {
    param([Parameter(Mandatory = $true)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-CmdSetValue {
    param([Parameter(Mandatory = $true)][string]$Value)

    return $Value.Replace('%', '%%').Replace('"', '""')
}

function Set-DotbotHomeFallbackInShim {
    param(
        [Parameter(Mandatory = $true)][string]$ShimPath,
        [Parameter(Mandatory = $true)][string]$DotbotHome,
        [Parameter(Mandatory = $true)][string]$ShimName
    )

    $content = Get-Content -Path $ShimPath -Raw

    if ($ShimName -eq 'dotbot') {
        $startMarker = '# >>> dotbot bootstrap fallback >>>'
        $endMarker = '# <<< dotbot bootstrap fallback <<<'
        $quotedHome = ConvertTo-PosixSingleQuotedString -Value $DotbotHome
        $block = @"
$startMarker
if [ -z "`${DOTBOT_HOME:-}" ]; then
  DOTBOT_HOME=$quotedHome
  export DOTBOT_HOME
fi
$endMarker

"@

        $pattern = "(?ms)^$([regex]::Escape($startMarker))\r?\n.*?\r?\n$([regex]::Escape($endMarker))\r?\n\r?"
        $content = [regex]::Replace($content, $pattern, '', 1)

        if ($content -match '^(#![^\r\n]*(?:\r?\n))') {
            $updated = $matches[1] + $block + $content.Substring($matches[1].Length)
        } else {
            $updated = $block + $content
        }
    } elseif ($ShimName -eq 'dotbot.ps1') {
        $startMarker = '# >>> dotbot bootstrap fallback >>>'
        $endMarker = '# <<< dotbot bootstrap fallback <<<'
        $quotedHome = ConvertTo-PowerShellSingleQuotedString -Value $DotbotHome
        $block = @"
$startMarker
if ([string]::IsNullOrWhiteSpace(`$env:DOTBOT_HOME)) {
    `$env:DOTBOT_HOME = $quotedHome
}
$endMarker

"@

        $pattern = "(?ms)^$([regex]::Escape($startMarker))\r?\n.*?\r?\n$([regex]::Escape($endMarker))\r?\n\r?"
        $content = [regex]::Replace($content, $pattern, '', 1)

        if ($content -match '^(#![^\r\n]*(?:\r?\n))') {
            $updated = $matches[1] + $block + $content.Substring($matches[1].Length)
        } else {
            $updated = $block + $content
        }
    } elseif ($ShimName -eq 'dotbot.cmd') {
        $startMarker = 'REM >>> dotbot bootstrap fallback >>>'
        $endMarker = 'REM <<< dotbot bootstrap fallback <<<'
        $cmdHome = ConvertTo-CmdSetValue -Value $DotbotHome
        $block = @"
$startMarker
if "%DOTBOT_HOME%"=="" set "DOTBOT_HOME=$cmdHome"
$endMarker

"@

        $pattern = "(?ms)^$([regex]::Escape($startMarker))\r?\n.*?\r?\n$([regex]::Escape($endMarker))\r?\n\r?"
        $content = [regex]::Replace($content, $pattern, '', 1)

        if ($content -match '^(@echo off[^\r\n]*(?:\r?\n))') {
            $updated = $matches[1] + $block + $content.Substring($matches[1].Length)
        } else {
            $updated = $block + $content
        }
    } else {
        return
    }

    Set-Content -Path $ShimPath -Value $updated -NoNewline
}

# ---------------------------------------------------------------------------
# Resolve target shim directory per platform.
# ---------------------------------------------------------------------------
if (-not $ShimDir) {
    if ($IsWindows) {
        $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = Join-Path $HOME 'AppData/Local'
        }
        $ShimDir = Join-Path $base 'Microsoft' 'WindowsApps'
    } else {
        $ShimDir = Join-Path $HOME '.local' 'bin'
    }
}

Write-DotbotBanner -Title 'D O T B O T   bootstrap' -Subtitle 'Install PATH shim'

# ---------------------------------------------------------------------------
# Copy the shim files. On Unix only the POSIX wrapper is needed; on
# Windows we install both the .cmd (so plain `dotbot` works from cmd /
# Windows Terminal) and the .ps1 (so pwsh callers see a native script).
# ---------------------------------------------------------------------------
if (-not (Test-Path $ShimDir)) {
    New-Item -ItemType Directory -Path $ShimDir -Force | Out-Null
}

$shimsToCopy = if ($IsWindows) { @('dotbot.cmd', 'dotbot.ps1') } else { @('dotbot') }
$installedCount = 0

Write-DotbotSection -Title 'SHIM INSTALL'
Write-DotbotLabel -Label '    Source     ' -Value "$ShimSrc"
Write-DotbotLabel -Label '    Target     ' -Value "$ShimDir"
Write-BlankLine

$shimPlan = foreach ($name in $shimsToCopy) {
    $src = Join-Path $ShimSrc $name
    if (-not (Test-Path $src)) {
        Write-DotbotError "Shim source missing: $src"
        exit 1
    }

    [pscustomobject]@{
        Name        = $name
        Source      = $src
        Destination = Join-Path $ShimDir $name
    }
}

$replaceExisting = [bool]$Force
$existingShims = @($shimPlan | Where-Object { Test-Path $_.Destination })
if ($existingShims.Count -gt 0 -and -not $Force) {
    foreach ($shim in $existingShims) {
        Write-DotbotWarning "Shim already exists: $($shim.Destination)"
    }

    $replaceExisting = Read-DotbotConfirmation -Message 'Replace existing shim files?'
}

foreach ($shim in $shimPlan) {
    $dst = $shim.Destination
    if ((Test-Path $dst) -and -not $replaceExisting) {
        Write-DotbotCommand "Shim unchanged: $dst"
        continue
    }

    $src = $shim.Source
    Copy-Item -Path $src -Destination $dst -Force
    Set-DotbotHomeFallbackInShim -ShimPath $dst -DotbotHome $RepoDir -ShimName $shim.Name
    if (-not $IsWindows) {
        & chmod +x $dst 2>$null
    }
    Write-Success "Installed: $dst"
    $installedCount++
}

if ($installedCount -eq 0) {
    Write-BlankLine
    Write-DotbotWarning 'No shim files were changed.'
}

$env:DOTBOT_HOME = $RepoDir

# ---------------------------------------------------------------------------
# PATH visibility check — purely diagnostic; bootstrap never edits PATH
# on behalf of the user.
# ---------------------------------------------------------------------------
$pathSep   = [System.IO.Path]::PathSeparator
$pathDirs  = (($env:PATH -split $pathSep) | ForEach-Object { ($_ -as [string]).TrimEnd('/','\') })
$normShim  = $ShimDir.TrimEnd('/','\')
$onPath    = $pathDirs -contains $normShim

Write-BlankLine
Write-DotbotSection -Title 'PATH VISIBILITY'
if ($onPath) {
    Write-Success "$ShimDir is on PATH for this shell."
} else {
    Write-DotbotWarning "$ShimDir is NOT on PATH for this shell."
    if ($IsWindows) {
        Write-DotbotCommand 'Reopen your shell — Windows adds %LOCALAPPDATA%\Microsoft\WindowsApps to PATH by default.'
    } else {
        Write-DotbotCommand "Add this to your shell rc (zshrc/bashrc/profile):"
        Write-DotbotCommand "  export PATH=`"$ShimDir`":`$PATH"
    }
}

# ---------------------------------------------------------------------------
# DOTBOT_HOME and next steps.
# ---------------------------------------------------------------------------
Write-BlankLine
Write-DotbotSection -Title 'DOTBOT_HOME'
Write-Success "DOTBOT_HOME points at: $RepoDir"
if ($IsWindows) {
    Write-DotbotCommand "The installed shims use this checkout when DOTBOT_HOME is unset."
    Write-DotbotCommand "No Windows user environment variables were changed."
} else {
    Write-DotbotCommand "The installed shim uses this checkout when DOTBOT_HOME is unset."
    Write-DotbotCommand "No shell rc/profile files were changed."
}

Write-BlankLine
Write-DotbotSection -Title 'NEXT STEPS'
Write-DotbotLabel -Label '    1. Confirm                              ' -Value 'dotbot status'
Write-DotbotLabel -Label '    2. Initialise a project                 ' -Value 'cd /your/project; dotbot init'
Write-BlankLine
