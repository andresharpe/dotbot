#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 5: UI E2E regression suite (Playwright-driven).
.DESCRIPTION
    Boots the dotbot Control Panel UI server (core/ui/server.ps1) against a
    freshly-cloned golden .bot/ snapshot and runs the Playwright specs in
    tests/e2e/ against the live server. Tests interact with the real backend
    over real HTTP — no /api/* mocking. State is driven by seeding real files
    under .bot/workspace/, .bot/.control/processes/, etc.

    On first run, auto-installs npm dependencies inside tests/e2e/ and the
    Playwright Chromium browser binary. Both are cached for subsequent runs.

    Requires:
        - Node.js + npm in PATH
        - PowerShell 7+
        - dotbot installed at ~/dotbot (Run-Tests.ps1 auto-installs it)
        - Network access on first run (registry.npmjs.org + cdn.playwright.dev)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir
$e2eDir    = Join-Path $PSScriptRoot "e2e"

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 5: UI E2E Regression Suite (Playwright)" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════

if (-not (Test-Path (Join-Path $dotbotDir "core/ui/server.ps1"))) {
    Write-TestResult -Name "Layer 5 prerequisites" -Status Fail `
        -Message "dotbot not installed at $dotbotDir — run 'pwsh install.ps1' first"
    Write-TestSummary -LayerName "Layer 5: UI E2E"
    exit 1
}

if (-not (Get-Command node -ErrorAction SilentlyContinue) -or
    -not (Get-Command npm  -ErrorAction SilentlyContinue) -or
    -not (Get-Command npx  -ErrorAction SilentlyContinue)) {
    Write-TestResult -Name "Layer 5 prerequisites" -Status Fail `
        -Message "node/npm/npx not in PATH — install Node.js 18+"
    Write-TestSummary -LayerName "Layer 5: UI E2E"
    exit 1
}

if (-not (Test-Path (Join-Path $e2eDir "package.json"))) {
    Write-TestResult -Name "Layer 5 prerequisites" -Status Fail `
        -Message "tests/e2e/package.json missing — Layer 5 scaffold not in place"
    Write-TestSummary -LayerName "Layer 5: UI E2E"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# AUTO-INSTALL: npm deps + Playwright Chromium browser
# ═══════════════════════════════════════════════════════════════════

$playwrightInstalled = Test-Path (Join-Path $e2eDir "node_modules/@playwright/test")
if (-not $playwrightInstalled) {
    $packageLockPath = Join-Path $e2eDir "package-lock.json"
    $npmCommand = if (Test-Path $packageLockPath) { "ci" } else { "install" }
    Write-Host "  → Installing Playwright npm dependencies (one-time) using 'npm $npmCommand'..." -ForegroundColor Cyan
    Push-Location $e2eDir
    try {
        & npm $npmCommand --no-audit --no-fund --loglevel=error 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "npm $npmCommand failed (exit $LASTEXITCODE)"
        }
    } finally {
        Pop-Location
    }
}

# Any chromium-* subdir counts as cached — Playwright manages exact versioning.
$browserCacheRoot = if ($IsWindows) {
    Join-Path $env:LOCALAPPDATA "ms-playwright"
} else {
    Join-Path $HOME ".cache/ms-playwright"
}
$chromiumCached = (Test-Path $browserCacheRoot) -and `
    @(Get-ChildItem -Path $browserCacheRoot -Directory -Filter "chromium-*" -ErrorAction SilentlyContinue).Count -gt 0
if (-not $chromiumCached) {
    Write-Host "  → Installing Playwright Chromium browser (~150 MB, one-time)..." -ForegroundColor Cyan
    Push-Location $e2eDir
    try {
        # --with-deps installs the OS shared libraries Chromium needs
        # (libnspr4, libnss3, libgbm1, libasound2 …) alongside the browser
        # binary. On Linux it shells out to apt-get and may require sudo;
        # on macOS / Windows it's a no-op.
        & npx --no-install playwright install --with-deps chromium 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Playwright browser install failed (exit $LASTEXITCODE). On Linux without root, run: sudo npx playwright install-deps chromium"
        }
    } finally {
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════
# UI SERVER LIFECYCLE HELPERS (mirrored from Test-ServerStartup.ps1)
# ═══════════════════════════════════════════════════════════════════

function Start-UiServer {
    param([Parameter(Mandatory)][string]$BotDir)

    $serverScript = Join-Path $BotDir "core/ui/server.ps1"
    if (-not (Test-Path $serverScript)) {
        throw "UI server script not found: $serverScript"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName  = "pwsh"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`""
    $psi.WorkingDirectory      = Split-Path -Parent $BotDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    # Drain stdout/stderr async — the server's Write-Host output otherwise
    # fills the OS pipe buffer and stalls the listener.
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    return $process
}

function Wait-ForUiPort {
    param(
        [Parameter(Mandatory)][string]$BotDir,
        [int]$TimeoutSeconds = 30
    )
    $portFile = Join-Path $BotDir ".control/ui-port"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path $portFile) {
            $raw = (Get-Content $portFile -Raw -ErrorAction SilentlyContinue)
            if ($raw) {
                $trimmed = $raw.Trim()
                if ($trimmed -match '^\d+$') { return [int]$trimmed }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}

function Wait-ForServerReady {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSeconds = 30
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$Port/api/info" -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return $true }
        } catch {
            Write-Verbose "Server not ready yet: $_"
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Stop-UiServer {
    param([System.Diagnostics.Process]$Process)
    if (-not $Process) { return }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { Write-Verbose "Stop-UiServer kill: $_" }
        try { [void]$Process.WaitForExit(3000) } catch { Write-Verbose "Stop-UiServer wait: $_" }
    }
    try { $Process.Dispose() } catch { Write-Verbose "Stop-UiServer dispose: $_" }
}

# ═══════════════════════════════════════════════════════════════════
# RUN
# ═══════════════════════════════════════════════════════════════════

$project   = $null
$server    = $null
$exitCode  = 1

try {
    Write-Host "  → Cloning fixture from golden snapshot..." -ForegroundColor Cyan
    $project = New-TestProjectFromGolden -Flavor 'default'

    Write-Host "  → Starting UI server against fixture..." -ForegroundColor Cyan
    $server = Start-UiServer -BotDir $project.BotDir

    $port = Wait-ForUiPort -BotDir $project.BotDir -TimeoutSeconds 30
    if ($port -le 0) {
        throw "UI server did not write .control/ui-port within 30s"
    }

    if (-not (Wait-ForServerReady -Port $port -TimeoutSeconds 30)) {
        throw "UI server bound port $port but /api/info did not respond within 30s"
    }

    $url = "http://localhost:$port"
    Write-Host "  → UI server ready at $url" -ForegroundColor Green
    Write-Host ""

    # DOTBOT_E2E_BOT_DIR lets specs seed real files under the fixture's
    # .bot/ to drive backend state.
    $env:DOTBOT_E2E_URL     = $url
    $env:DOTBOT_E2E_BOT_DIR = $project.BotDir

    Push-Location $e2eDir
    try {
        & npx --no-install playwright test 2>&1 | Out-Host
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        Remove-Item Env:\DOTBOT_E2E_URL     -ErrorAction SilentlyContinue
        Remove-Item Env:\DOTBOT_E2E_BOT_DIR -ErrorAction SilentlyContinue
    }
} catch {
    Write-Host "  ✗ Layer 5 setup failed: $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    Stop-UiServer -Process $server
    if ($project) { Remove-TestProject -Path $project.ProjectRoot }
}

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "  Layer 5: ✓ ALL PASSED" -ForegroundColor Green
} else {
    Write-Host "  Layer 5: ✗ FAILED (Playwright exit $exitCode)" -ForegroundColor Red
    Write-Host "  HTML report: $e2eDir/playwright-report/index.html" -ForegroundColor DarkGray
    Write-Host "  Traces:      $e2eDir/test-results/" -ForegroundColor DarkGray
}
Write-Host ""

exit $exitCode
