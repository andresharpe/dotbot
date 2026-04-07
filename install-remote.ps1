#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Remote installer for dotbot

.DESCRIPTION
    Downloads the latest release of dotbot and installs it globally.
    Designed to be used with: irm https://raw.githubusercontent.com/andresharpe/dotbot/main/install-remote.ps1 | iex

.EXAMPLE
    irm https://raw.githubusercontent.com/andresharpe/dotbot/main/install-remote.ps1 | iex
#>

$ErrorActionPreference = "Stop"

$RepoOwner = "andresharpe"
$RepoName = "dotbot"

# Inline theme colors (amber/green palette — no module dependency for remote install)
$_p = "`e[38;2;232;160;48m"   # Primary amber
$_d = "`e[38;2;184;120;32m"   # Dim amber
$_s = "`e[38;2;0;255;136m"    # Success green
$_e = "`e[38;2;209;105;105m"  # Error red
$_i = "`e[38;2;95;179;179m"   # Info cyan
$_m = "`e[38;2;136;136;153m"  # Muted
$_b = "`e[38;2;58;59;72m"     # Bezel
$_r = "`e[0m"                 # Reset

$line = '═' * 55
Write-Host ""
Write-Host "${_p}${line}${_r}"
Write-Host ""
Write-Host "${_p}    D O T B O T   v3${_r}"
Write-Host "${_d}    Remote Installer${_r}"
Write-Host ""
Write-Host "${_p}${line}${_r}"
Write-Host ""

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "${_e}  ✗ PowerShell 7+ is required${_r}"
    Write-Host "${_p}    Current version: $($PSVersionTable.PSVersion)${_r}"
    Write-Host "${_i}    Download from: https://aka.ms/powershell${_r}"
    Write-Host ""
    return
}

# Check for git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "${_e}  ✗ Git is required${_r}"
    Write-Host "${_i}    Download from: https://git-scm.com/downloads${_r}"
    Write-Host ""
    return
}

# Determine archive format based on platform (PS 7+ provides $IsWindows automatically)
$archiveExt = if ($IsWindows) { "zip" } else { "tar.gz" }

# Fetch latest release info from GitHub API
Write-Host "${_i}  › ${_m}Fetching latest release...${_r}"
try {
    $releaseUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/releases/latest"
    $release = Invoke-RestMethod -Uri $releaseUrl -Headers @{ 'User-Agent' = 'dotbot-installer' }
    $version = $release.tag_name -replace '^v', ''
    Write-Host "${_s}  ✓ Latest version: v$version${_r}"
} catch {
    # Fallback: clone from main branch if no releases exist yet
    Write-Host "${_p}  ⚠ No releases found, installing from main branch...${_r}"

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-install-$(Get-Random)"
    try {
        git clone --depth 1 "https://github.com/$RepoOwner/$RepoName.git" $tempDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
        & (Join-Path $tempDir "install.ps1")
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return
}

# Find the download URL for the appropriate archive
$archiveAsset = $release.assets | Where-Object { $_.name -like "*.$archiveExt" -and $_.name -notlike "*.sha256" }
if (-not $archiveAsset) {
    Write-Host "${_e}  ✗ No $archiveExt archive found in release v$version${_r}"
    Write-Host "${_p}    Falling back to git clone...${_r}"

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-install-$(Get-Random)"
    try {
        git clone --depth 1 --branch "v$version" "https://github.com/$RepoOwner/$RepoName.git" $tempDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
        & (Join-Path $tempDir "install.ps1")
    } finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return
}

# Download archive
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-install-$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$archivePath = Join-Path $tempDir $archiveAsset.name
Write-Host "${_i}  › ${_m}Downloading v$version...${_r}"

try {
    Invoke-WebRequest -Uri $archiveAsset.browser_download_url -OutFile $archivePath

    # Extract archive
    Write-Host "${_i}  › ${_m}Extracting...${_r}"
    $extractDir = Join-Path $tempDir "extracted"

    if ($archiveExt -eq "zip") {
        Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force
    } else {
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        tar -xzf $archivePath -C $extractDir
    }

    # Find the extracted directory (should be dotbot-{version}/)
    $innerDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $innerDir) {
        throw "Could not find extracted directory"
    }

    # Run install.ps1 from the extracted directory
    $installScript = Join-Path $innerDir.FullName "install.ps1"
    if (-not (Test-Path $installScript)) {
        throw "install.ps1 not found in extracted archive"
    }

    & $installScript

} finally {
    # Clean up temp directory
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
