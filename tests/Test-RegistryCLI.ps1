#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Tests for registry-remove.ps1 and RegistryManager.psm1 (PR #564).
.DESCRIPTION
    Exercises registry remove (path traversal guard, confirmation skip, file
    deletion, registries.json cleanup) and RegistryManager helpers
    (Get-DotbotRegistries, Update-StaleRegistries name validation).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host "  Layer 2: Registry CLI Tests (PR #564)" -ForegroundColor Blue
Write-Host "-----------------------------------------------------------" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed — set DOTBOT_HOME to a dotbot checkout"
    Write-TestSummary -LayerName "Layer 2: Registry CLI"
    exit 1
}

$registryManagerPath = Join-Path $dotbotDir "src/cli/RegistryManager.psm1"
$registryRemovePath  = Join-Path $dotbotDir "src/cli/registry-remove.ps1"

# ===================================================================
# MODULE LOADING
# ===================================================================

Write-Host "  MODULE LOADING" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Assert-True -Name "RegistryManager.psm1 exists on disk" `
    -Condition (Test-Path $registryManagerPath) `
    -Message "Not found: $registryManagerPath"

Assert-True -Name "registry-remove.ps1 exists on disk" `
    -Condition (Test-Path $registryRemovePath) `
    -Message "Not found: $registryRemovePath"

# Load a platform-functions stub so Write-DotbotWarning doesn't break module load
$platformFunctions = Join-Path $dotbotDir "src/cli/Platform-Functions.psm1"
if (Test-Path $platformFunctions) {
    try {
        Import-Module $platformFunctions -Force -DisableNameChecking
    } catch { }
}

try {
    Import-Module $registryManagerPath -Force -DisableNameChecking
    Write-TestResult -Name "RegistryManager.psm1 imports without error" -Status Pass
} catch {
    Write-TestResult -Name "RegistryManager.psm1 imports without error" -Status Fail -Message $_.Exception.Message
    Write-TestSummary -LayerName "Layer 2: Registry CLI"
    exit 1
}

# ===================================================================
# SETUP: isolated temp home dir that mimics DOTBOT_HOME
# ===================================================================

$testHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-regcli-$(Get-Random)"
$registriesDir = Join-Path $testHome "registries"
New-Item -Path $registriesDir -ItemType Directory -Force | Out-Null

function Write-TestRegistriesJson {
    param([array]$Entries)
    $obj = [pscustomobject]@{ registries = $Entries }
    $obj | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $testHome "registries.json") -Encoding utf8NoBOM
}

# ===================================================================
# Get-DotbotRegistries
# ===================================================================

Write-Host ""
Write-Host "  GET-DOTBOTREGISTRIES" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

# No registries.json yet
$result = Get-DotbotRegistries -DotbotBase $testHome
Assert-True -Name "Get-DotbotRegistries returns empty array when no registries.json" `
    -Condition ($result.Count -eq 0) `
    -Message "Expected 0 entries, got $($result.Count)"

# Empty registries array
Write-TestRegistriesJson -Entries @()
$result = Get-DotbotRegistries -DotbotBase $testHome
Assert-True -Name "Get-DotbotRegistries returns empty array for empty registries list" `
    -Condition ($result.Count -eq 0) `
    -Message "Expected 0 entries, got $($result.Count)"

# Two entries
Write-TestRegistriesJson -Entries @(
    [pscustomobject]@{ name = "alpha"; type = "git";   source = "https://example.com/alpha.git"; auto_update = $true  }
    [pscustomobject]@{ name = "beta";  type = "local"; source = "C:/repos/beta";                 auto_update = $false }
)
$result = Get-DotbotRegistries -DotbotBase $testHome
Assert-True -Name "Get-DotbotRegistries returns correct count" `
    -Condition ($result.Count -eq 2) `
    -Message "Expected 2 entries, got $($result.Count)"

Assert-True -Name "Get-DotbotRegistries first entry has correct name" `
    -Condition ($result[0].name -eq "alpha") `
    -Message "Expected 'alpha', got '$($result[0].name)'"

# Corrupt JSON — should return empty, not throw
"not valid json {{{{" | Set-Content (Join-Path $testHome "registries.json") -Encoding utf8NoBOM
$result = Get-DotbotRegistries -DotbotBase $testHome
Assert-True -Name "Get-DotbotRegistries returns empty array on corrupt registries.json" `
    -Condition ($result.Count -eq 0) `
    -Message "Expected 0 entries on parse failure, got $($result.Count)"

# ===================================================================
# Update-StaleRegistries — name validation (path traversal guard)
# ===================================================================

Write-Host ""
Write-Host "  UPDATE-STALEREGISTRIES (name validation)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

# Registry with a path-traversal name — should be skipped, not throw
$evilEntries = @(
    [pscustomobject]@{ name = "../evil"; type = "git"; source = "https://example.com/evil.git"; auto_update = $true; branch = "main" }
)
Write-TestRegistriesJson -Entries $evilEntries

try {
    Update-StaleRegistries -DotbotBase $testHome -MaxAgeSecs 0
    Write-TestResult -Name "Update-StaleRegistries does not throw on path-traversal name" -Status Pass
} catch {
    Write-TestResult -Name "Update-StaleRegistries does not throw on path-traversal name" -Status Fail -Message $_.Exception.Message
}

# Registry with invalid characters in name — should be skipped, not throw
$badNameEntries = @(
    [pscustomobject]@{ name = "reg; rm -rf /"; type = "git"; source = "https://example.com/x.git"; auto_update = $true; branch = "main" }
)
Write-TestRegistriesJson -Entries $badNameEntries

try {
    Update-StaleRegistries -DotbotBase $testHome -MaxAgeSecs 0
    Write-TestResult -Name "Update-StaleRegistries does not throw on name with shell metacharacters" -Status Pass
} catch {
    Write-TestResult -Name "Update-StaleRegistries does not throw on name with shell metacharacters" -Status Fail -Message $_.Exception.Message
}

# Valid name but directory missing — should be skipped, not throw
Write-TestRegistriesJson -Entries @(
    [pscustomobject]@{ name = "myorg"; type = "git"; source = "https://example.com/myorg.git"; auto_update = $true; branch = "main" }
)
try {
    Update-StaleRegistries -DotbotBase $testHome -MaxAgeSecs 0
    Write-TestResult -Name "Update-StaleRegistries does not throw when registry directory is missing" -Status Pass
} catch {
    Write-TestResult -Name "Update-StaleRegistries does not throw when registry directory is missing" -Status Fail -Message $_.Exception.Message
}

# MaxAgeSecs skips recently-updated registry (updated_at = now)
$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$recentDir = Join-Path $registriesDir "recent"
New-Item -Path $recentDir -ItemType Directory -Force | Out-Null
Write-TestRegistriesJson -Entries @(
    [pscustomobject]@{ name = "recent"; type = "git"; source = "https://example.com/r.git"; auto_update = $true; branch = "main"; updated_at = $nowUtc }
)
# Spy: if it tried to run git it would fail (no .git dir) — but MaxAgeSecs should skip it
$configBefore = Get-Content (Join-Path $testHome "registries.json") -Raw
Update-StaleRegistries -DotbotBase $testHome -MaxAgeSecs 3600
$configAfter = Get-Content (Join-Path $testHome "registries.json") -Raw
Assert-True -Name "Update-StaleRegistries skips registry updated within MaxAgeSecs" `
    -Condition ($configBefore -eq $configAfter) `
    -Message "registries.json changed — registry should have been skipped as recently updated"

# Local (non-git) registry is always skipped
$localDir = Join-Path $registriesDir "localreg"
New-Item -Path $localDir -ItemType Directory -Force | Out-Null
Write-TestRegistriesJson -Entries @(
    [pscustomobject]@{ name = "localreg"; type = "local"; source = "C:/repos/localreg"; auto_update = $false }
)
try {
    Update-StaleRegistries -DotbotBase $testHome -MaxAgeSecs 0
    Write-TestResult -Name "Update-StaleRegistries skips local registries without error" -Status Pass
} catch {
    Write-TestResult -Name "Update-StaleRegistries skips local registries without error" -Status Fail -Message $_.Exception.Message
}

# ===================================================================
# registry-remove.ps1 — subprocess tests
# Use real DOTBOT_HOME so modules (Dotbot.Theme etc.) resolve correctly.
# Registry dirs and registries.json are created inside the real
# registries directory and cleaned up after each test.
# ===================================================================

$realDotbotHome  = $dotbotDir
$realRegistries  = Join-Path $realDotbotHome "registries"
$realConfigPath  = Join-Path $realDotbotHome "registries.json"

if (-not (Test-Path -LiteralPath $realRegistries)) {
    New-Item -Path $realRegistries -ItemType Directory -Force | Out-Null
}

# Backup existing registries.json so we can restore it after tests
$configBackup = $null
if (Test-Path $realConfigPath) {
    $configBackup = Get-Content $realConfigPath -Raw
}

function Write-RealRegistriesJson {
    param([array]$Entries)
    $obj = [pscustomobject]@{ registries = $Entries }
    $obj | ConvertTo-Json -Depth 5 | Set-Content $realConfigPath -Encoding utf8NoBOM
}

function Restore-RegistriesJson {
    if ($null -ne $configBackup) {
        $configBackup | Set-Content $realConfigPath -Encoding utf8NoBOM
    } elseif (Test-Path $realConfigPath) {
        Remove-Item $realConfigPath -Force
    }
}

# ===================================================================
# registry-remove.ps1 — path traversal guard
# ===================================================================

Write-Host ""
Write-Host "  REGISTRY-REMOVE (path traversal guard)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Write-RealRegistriesJson -Entries @(
    [pscustomobject]@{ name = "testorg-traversal"; type = "local"; source = "C:/repos/x"; auto_update = $false }
)

$null = & pwsh -NoProfile -NonInteractive -Command `
    "& '$registryRemovePath' -Name '../evil' -Force" 2>&1
Assert-True -Name "registry-remove.ps1 exits non-zero for path-traversal name" `
    -Condition ($LASTEXITCODE -ne 0) `
    -Message "Expected non-zero exit for '../evil', got $LASTEXITCODE"

Restore-RegistriesJson

# ===================================================================
# registry-remove.ps1 — removes registry dir and registries.json entry
# ===================================================================

Write-Host ""
Write-Host "  REGISTRY-REMOVE (happy path)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$testRegName = "dotbot-test-reg-$(Get-Random)"
$testRegDir  = Join-Path $realRegistries $testRegName
New-Item -Path $testRegDir -ItemType Directory -Force | Out-Null

Write-RealRegistriesJson -Entries @(
    [pscustomobject]@{ name = $testRegName; type = "local"; source = "C:/repos/x"; auto_update = $false }
    [pscustomobject]@{ name = "other-keep"; type = "git";  source = "https://example.com/o.git"; auto_update = $true }
)

$removeOut = & pwsh -NoProfile -NonInteractive -Command `
    "& '$registryRemovePath' -Name '$testRegName' -Force" 2>&1
$removeExitCode = $LASTEXITCODE

Assert-True -Name "registry-remove.ps1 exits 0 for valid registry" `
    -Condition ($removeExitCode -eq 0) `
    -Message "Exit code: $removeExitCode. Output: $($removeOut | Out-String)"

Assert-True -Name "registry-remove.ps1 deletes registry directory" `
    -Condition (-not (Test-Path $testRegDir)) `
    -Message "Directory still exists: $testRegDir"

$configAfterRemove = Get-Content $realConfigPath -Raw | ConvertFrom-Json
$remaining = @($configAfterRemove.registries | Where-Object { $_.name -eq $testRegName })
Assert-True -Name "registry-remove.ps1 removes entry from registries.json" `
    -Condition ($remaining.Count -eq 0) `
    -Message "Entry '$testRegName' still present in registries.json"

$otherRemaining = @($configAfterRemove.registries | Where-Object { $_.name -eq "other-keep" })
Assert-True -Name "registry-remove.ps1 leaves other entries intact in registries.json" `
    -Condition ($otherRemaining.Count -eq 1) `
    -Message "Entry 'other-keep' was unexpectedly removed"

Restore-RegistriesJson

# ===================================================================
# registry-remove.ps1 — exits non-zero for unknown registry
# ===================================================================

Write-Host ""
Write-Host "  REGISTRY-REMOVE (error cases)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

Write-RealRegistriesJson -Entries @(
    [pscustomobject]@{ name = "someorg"; type = "local"; source = "C:/repos/x"; auto_update = $false }
)

$null = & pwsh -NoProfile -NonInteractive -Command `
    "& '$registryRemovePath' -Name 'doesnotexist' -Force" 2>&1
Assert-True -Name "registry-remove.ps1 exits non-zero for unregistered name" `
    -Condition ($LASTEXITCODE -ne 0) `
    -Message "Expected non-zero exit for unknown registry, got $LASTEXITCODE"

Restore-RegistriesJson

# ===================================================================
# Update-StaleRegistries — legacy registry.yaml migration hook
# ===================================================================

Write-Host ""
Write-Host "  UPDATE-STALEREGISTRIES (legacy YAML migration)" -ForegroundColor Cyan
Write-Host "  --------------------------------------------" -ForegroundColor DarkGray

$legacyHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-regyaml-$(Get-Random)"
$legacyOrg = Join-Path $legacyHome "registries/legacyorg"
New-Item -Path (Join-Path $legacyOrg "workflows/deploy") -ItemType Directory -Force | Out-Null
@"
name: legacyorg
version: "1.0"
content:
  workflows: [deploy]
"@ | Set-Content (Join-Path $legacyOrg "registry.yaml")
"name: deploy" | Set-Content (Join-Path $legacyOrg "workflows/deploy/workflow.yaml")

Update-StaleRegistries -DotbotBase $legacyHome *>&1 | Out-Null

Assert-PathExists -Name "Update-StaleRegistries converts legacy registry.yaml" `
    -Path (Join-Path $legacyOrg "registry.json")
Assert-PathExists -Name "Legacy registry.yaml kept as .migrated" `
    -Path (Join-Path $legacyOrg "registry.yaml.migrated")
Assert-PathExists -Name "Nested legacy workflow.yaml converted" `
    -Path (Join-Path $legacyOrg "workflows/deploy/workflow.json")

$regMeta = Get-Content (Join-Path $legacyOrg "registry.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
Assert-True -Name "Converted registry.json carries YAML content map" `
    -Condition ($null -ne $regMeta -and $regMeta.name -eq "legacyorg" -and $regMeta.content.workflows[0] -eq "deploy") `
    -Message "registry.json missing or does not match the source YAML"

Remove-Item $legacyHome -Recurse -Force -ErrorAction SilentlyContinue

$ambigHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-regambig-$(Get-Random)"
$ambigOrg = Join-Path $ambigHome "registries/ambigorg"
New-Item -Path $ambigOrg -ItemType Directory -Force | Out-Null
'{"name":"ambigorg","content":{"workflows":["a"]}}' | Set-Content (Join-Path $ambigOrg "registry.json")
"name: ambigorg" | Set-Content (Join-Path $ambigOrg "registry.yaml")
$jsonBefore = (Get-Item (Join-Path $ambigOrg "registry.json")).LastWriteTimeUtc

$ambigOutput = Update-StaleRegistries -DotbotBase $ambigHome *>&1 | ForEach-Object { "$_" } | Out-String

Assert-True -Name "Ambiguous registry.yaml + registry.json warns loudly" `
    -Condition ($ambigOutput -match 'reads only registry.json') `
    -Message "Expected ambiguity warning, got: $ambigOutput"
Assert-True -Name "Ambiguous registry.json left untouched" `
    -Condition ((Get-Item (Join-Path $ambigOrg "registry.json")).LastWriteTimeUtc -eq $jsonBefore) `
    -Message "registry.json was modified in ambiguous state"
Assert-PathExists -Name "Ambiguous registry.yaml left in place" `
    -Path (Join-Path $ambigOrg "registry.yaml")

Remove-Item $ambigHome -Recurse -Force -ErrorAction SilentlyContinue

# ===================================================================
# CLEANUP
# ===================================================================

try {
    Remove-Item $testHome -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

Write-Host ""

# ===================================================================
# SUMMARY
# ===================================================================

$allPassed = Write-TestSummary -LayerName "Layer 2: Registry CLI"

if (-not $allPassed) {
    exit 1
}
