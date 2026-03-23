#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Add an enterprise extension registry to dotbot.

.DESCRIPTION
    Registers a git-compatible repository as a dotbot extension registry.
    For local paths, creates a symlink. For git URLs, shallow-clones.
    Validates registry.yaml exists, parses, name matches, content is valid.

.PARAMETER Name
    Registry namespace (e.g., "myorg"). Must match the name field in registry.yaml.

.PARAMETER Source
    Local path or git URL to the registry repo.

.PARAMETER Branch
    Git branch to clone (default: main). Only used for git URLs.

.PARAMETER Force
    Overwrite existing registry with the same name.

.EXAMPLE
    registry-add.ps1 -Name myorg -Source C:\repos\myorg-dotbot-extensions
    registry-add.ps1 -Name myorg -Source https://github.com/org/dotbot-extensions.git
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Source,
    [string]$Branch = "main",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$RegistriesDir = Join-Path $DotbotBase "registries"
$RegistryPath = Join-Path $RegistriesDir $Name
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
if (-not (Get-Command Write-Status -ErrorAction SilentlyContinue)) {
    function Write-Status ($msg) { Write-Host "  → $msg" -ForegroundColor Cyan }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T   v3" -ForegroundColor Blue
Write-Host "    Registry: Add" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Check if registry already exists
# ---------------------------------------------------------------------------
if ((Test-Path $RegistryPath) -and -not $Force) {
    Write-DotbotError "Registry '$Name' already exists at $RegistryPath"
    Write-Host "  Use -Force to overwrite" -ForegroundColor Yellow
    exit 1
}

if ((Test-Path $RegistryPath) -and $Force) {
    Write-DotbotWarning "Removing existing registry '$Name'"
    Remove-Item -Path $RegistryPath -Recurse -Force
}

# ---------------------------------------------------------------------------
# 2. Ensure registries directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $RegistriesDir)) {
    New-Item -Path $RegistriesDir -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# 3. Link or clone the source
# ---------------------------------------------------------------------------
$isLocalPath = Test-Path $Source
$isGitUrl = $Source -match '^https?://|^git@|^ssh://|\.git$'

if ($isLocalPath) {
    $resolvedSource = (Resolve-Path $Source).Path
    Write-Status "Creating symlink: $RegistryPath -> $resolvedSource"

    # On Windows, New-Item -ItemType Junction works without elevation (unlike SymbolicLink)
    if ($IsWindows) {
        New-Item -ItemType Junction -Path $RegistryPath -Target $resolvedSource | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $RegistryPath -Target $resolvedSource | Out-Null
    }
    Write-Success "Linked registry '$Name' from local path"

} elseif ($isGitUrl) {
    Write-Status "Cloning $Source (branch: $Branch) to $RegistryPath"
    $cloneOutput = & git clone --depth 1 --branch $Branch $Source $RegistryPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errText = ($cloneOutput | Out-String).Trim()
        Write-DotbotError "Clone failed"
        Write-Host ""
        if ($errText -match 'Authentication failed|401|403|could not read Username|terminal prompts disabled') {
            Write-Host "  The repository requires authentication. Ensure git can access it:" -ForegroundColor Yellow
            Write-Host ""
            if ($Source -match 'github\.com') {
                Write-Host "    GitHub:     gh auth login" -ForegroundColor White
                Write-Host "                git credential-manager configure" -ForegroundColor DarkGray
            } elseif ($Source -match 'dev\.azure\.com') {
                Write-Host "    Azure DevOps: az login" -ForegroundColor White
                Write-Host "                  git config credential.helper manager" -ForegroundColor DarkGray
            } elseif ($Source -match 'gitlab') {
                Write-Host "    GitLab:     Add SSH key or set a PAT in ~/.netrc" -ForegroundColor White
            } else {
                Write-Host "    Ensure your git credential helper is configured or use SSH" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "    Verify manually: git clone $Source /tmp/test-clone" -ForegroundColor DarkGray
        } elseif ($errText -match 'not found|does not exist|404') {
            Write-Host "  Repository not found. Check the URL and your access permissions." -ForegroundColor Yellow
        } elseif ($errText -match "Remote branch.*not found|couldn't find remote ref") {
            Write-Host "  Branch '$Branch' not found. Try -Branch main or -Branch master" -ForegroundColor Yellow
        } else {
            Write-Host "  $errText" -ForegroundColor DarkGray
        }
        exit 1
    }
    Write-Success "Cloned registry '$Name' from $Source"

} else {
    Write-DotbotError "Source '$Source' is neither a valid local path nor a git URL"
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Validate registry.yaml
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "  VALIDATION" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$registryYamlPath = Join-Path $RegistryPath "registry.yaml"

# 4a. File must exist
if (-not (Test-Path $registryYamlPath)) {
    Write-DotbotError "registry.yaml not found in $RegistryPath"
    Write-Host "  Enterprise registries must have a registry.yaml at the root" -ForegroundColor Yellow
    # Clean up
    Remove-Item -Path $RegistryPath -Recurse -Force
    exit 1
}
Write-Success "registry.yaml found"

# 4b. Must parse
try {
    # Simple YAML parsing (same approach as init-project.ps1 Read-ProfileYaml)
    $registryMeta = @{}
    $contentSection = $null
    Get-Content $registryYamlPath | ForEach-Object {
        if ($_ -match '^\s*(name|display_name|description|version|min_dotbot_version)\s*:\s*(.+)$') {
            $registryMeta[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
        }
        if ($_ -match '^\s*content\s*:') { $contentSection = @{} }
        if ($contentSection -and $_ -match '^\s+(workflows|stacks|tools|skills|agents)\s*:\s*\[(.+)\]') {
            $items = $Matches[2] -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") }
            $contentSection[$Matches[1]] = $items
        }
    }
    if ($contentSection) { $registryMeta['content'] = $contentSection }
} catch {
    Write-DotbotError "Failed to parse registry.yaml: $_"
    Remove-Item -Path $RegistryPath -Recurse -Force
    exit 1
}
Write-Success "registry.yaml parses correctly"

# 4c. Name must match
if ($registryMeta['name'] -ne $Name) {
    Write-DotbotError "Name mismatch: registry.yaml says '$($registryMeta['name'])', expected '$Name'"
    Remove-Item -Path $RegistryPath -Recurse -Force
    exit 1
}
Write-Success "Name matches: '$Name'"

# 4d. Content must list at least one item
$contentMap = $registryMeta['content']
if (-not $contentMap -or $contentMap.Count -eq 0) {
    Write-DotbotError "registry.yaml 'content' section is empty or missing"
    Remove-Item -Path $RegistryPath -Recurse -Force
    exit 1
}
$totalContent = 0
foreach ($key in $contentMap.Keys) {
    $totalContent += @($contentMap[$key]).Count
}
Write-Success "Content declares $totalContent item(s)"

# 4e. Verify referenced directories exist (warn only, non-fatal)
$contentTypeMap = @{
    "workflows" = "workflows"
    "stacks"    = "stacks"
    "tools"     = "tools"
    "skills"    = "skills"
    "agents"    = "agents"
}
$missingDirs = @()
foreach ($type in $contentMap.Keys) {
    $dirPrefix = $contentTypeMap[$type]
    if (-not $dirPrefix) { $dirPrefix = $type }
    foreach ($item in $contentMap[$type]) {
        $itemDir = Join-Path $RegistryPath "$dirPrefix\$item"
        if (-not (Test-Path $itemDir)) {
            $missingDirs += "$dirPrefix/$item"
        }
    }
}

if ($missingDirs.Count -gt 0) {
    foreach ($d in $missingDirs) {
        Write-DotbotWarning "Declared content directory not found: $d"
    }
} else {
    Write-Success "All declared content directories exist"
}

# 4f. Check min_dotbot_version (warn only)
if ($registryMeta['min_dotbot_version']) {
    Write-Host "  Min dotbot version: $($registryMeta['min_dotbot_version'])" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 5. Update registries.json
# ---------------------------------------------------------------------------
$config = @{ registries = @() }
if (Test-Path $ConfigPath) {
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if (-not $config.registries) { $config.registries = @() }
    } catch {
        $config = @{ registries = @() }
    }
}

# Remove existing entry for this name
$config.registries = @($config.registries | Where-Object { $_.name -ne $Name })

# Add new entry
$entry = @{
    name        = $Name
    source      = if ($isLocalPath) { $resolvedSource } else { $Source }
    type        = if ($isLocalPath) { "local" } else { "git" }
    branch      = $Branch
    added_at    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    auto_update = (-not $isLocalPath)
}
$config.registries += $entry
$config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath
Write-Success "Updated registries.json"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  ✓ Registry '$Name' added successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  Display name:  $($registryMeta['display_name'])" -ForegroundColor White
Write-Host "  Version:       $($registryMeta['version'])" -ForegroundColor White
Write-Host "  Path:          $RegistryPath" -ForegroundColor White
Write-Host ""

# List available content
foreach ($type in $contentMap.Keys) {
    foreach ($item in $contentMap[$type]) {
        Write-Host "    ${Name}:${item}" -ForegroundColor Cyan -NoNewline
        Write-Host " ($type)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Use with: dotbot init -Profile ${Name}:<workflow>" -ForegroundColor Yellow
Write-Host ""
