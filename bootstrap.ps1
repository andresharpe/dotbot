#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install the dotbot PATH shim — the only machine-wide artefact dotbot ships.

.DESCRIPTION
    Drops bin/shim/dotbot (and dotbot.cmd on Windows) into a user-scoped
    PATH directory. The shim is ~30 lines of shell that reads
    $env:DOTBOT_HOME and execs into <DOTBOT_HOME>/bin/dotbot.ps1.
    Framework code stays in the checkout you set DOTBOT_HOME to.

    Per design decision D4, bootstrap does NOT set DOTBOT_HOME for you —
    set it per-session (or in your shell rc / `setx`) once bootstrap is
    done.

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

foreach ($name in $shimsToCopy) {
    $src = Join-Path $ShimSrc $name
    if (-not (Test-Path $src)) {
        Write-DotbotError "Shim source missing: $src"
        exit 1
    }
    $dst = Join-Path $ShimDir $name
    if ((Test-Path $dst) -and -not $Force) {
        Write-DotbotWarning "Skipping (exists, use -Force): $dst"
        continue
    }
    Copy-Item -Path $src -Destination $dst -Force
    if (-not $IsWindows) {
        & chmod +x $dst 2>$null
    }
    Write-Success "Installed: $dst"
    $installedCount++
}

if ($installedCount -eq 0) {
    Write-BlankLine
    Write-DotbotWarning 'No shim files were installed. Re-run with -Force to overwrite existing copies.'
}

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
# Next steps. D4 explicitly bars us from setting DOTBOT_HOME for the user;
# bootstrap only prints the command.
# ---------------------------------------------------------------------------
Write-BlankLine
Write-DotbotSection -Title 'NEXT STEPS'
Write-DotbotLabel -Label '    1. Point DOTBOT_HOME at this checkout' -Value ''
if ($IsWindows) {
    Write-DotbotCommand "       `$env:DOTBOT_HOME = '$RepoDir'"
    Write-DotbotCommand "       (User scope: setx DOTBOT_HOME `"$RepoDir`")"
} else {
    Write-DotbotCommand "       export DOTBOT_HOME=`"$RepoDir`""
    Write-DotbotCommand '       (add it to ~/.zshrc / ~/.bashrc / ~/.profile to persist)'
}
Write-DotbotLabel -Label '    2. Confirm                              ' -Value 'dotbot status'
Write-DotbotLabel -Label '    3. Initialise a project                 ' -Value 'cd /your/project; dotbot init'
Write-BlankLine
