#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: UI server startup sequence tests.
.DESCRIPTION
    Tests that multiple dotbot UI servers for different projects start on
    separate ports and that /api/info returns the correct project_root,
    which go.ps1 relies on to distinguish between projects.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: UI Server Startup Sequence Tests" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "profiles\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Server Startup"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════

function Start-UiServer {
    <#
    .SYNOPSIS
        Start a dotbot UI server as a background process (no window, no browser).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir
    )

    $serverScript = Join-Path $BotDir "systems\ui\server.ps1"
    if (-not (Test-Path $serverScript)) {
        throw "UI server script not found: $serverScript"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`""
    $psi.WorkingDirectory = Split-Path -Parent $BotDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    return $process
}

function Wait-ForUiPort {
    <#
    .SYNOPSIS
        Poll for the ui-port file and return the port number.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir,
        [int]$TimeoutSeconds = 15
    )

    $portFile = Join-Path $BotDir ".control\ui-port"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path $portFile) {
            $raw = (Get-Content $portFile -Raw).Trim()
            if ($raw -match '^\d+$') {
                return [int]$raw
            }
        }
        Start-Sleep -Milliseconds 250
    }
    return 0
}

function Wait-ForServerReady {
    <#
    .SYNOPSIS
        Wait until the server is actually accepting HTTP connections on the given port.
        The port file may be written before the HttpListener is ready (observed on macOS).
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Port,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$Port/api/info" -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                return ($resp.Content | ConvertFrom-Json)
            }
        } catch {
            # Server not ready yet — keep polling
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Stop-UiServer {
    param(
        [System.Diagnostics.Process]$Process
    )
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch {}
        try { $Process.WaitForExit(3000) } catch {}
    }
    try { $Process.Dispose() } catch {}
}

function Initialize-TestBotProject {
    <#
    .SYNOPSIS
        Create a temp project and run dotbot init.
    #>
    $project = New-TestProject
    Push-Location $project
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    & git add -A 2>&1 | Out-Null
    & git commit -m "dotbot init" --quiet 2>&1 | Out-Null
    Pop-Location

    $botDir = Join-Path $project ".bot"
    $controlDir = Join-Path $botDir ".control"
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    return @{
        ProjectRoot = $project
        BotDir      = $botDir
        ControlDir  = $controlDir
    }
}

# ═══════════════════════════════════════════════════════════════════
# MULTI-INSTANCE SERVER TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MULTI-INSTANCE SERVER STARTUP" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$projectA = $null
$projectB = $null
$serverA = $null
$serverB = $null

try {
    # Set up two independent projects
    $projectA = Initialize-TestBotProject
    $projectB = Initialize-TestBotProject

    # Start Project A's server
    $serverA = Start-UiServer -BotDir $projectA.BotDir
    $portA = Wait-ForUiPort -BotDir $projectA.BotDir

    Assert-True -Name "Project A server starts and writes port" `
        -Condition ($portA -gt 0) `
        -Message "Failed to detect port from ui-port file"

    if ($portA -gt 0) {
        # Wait for server A to be fully ready (port file can appear before HttpListener binds)
        $infoA = Wait-ForServerReady -Port $portA

        Assert-True -Name "Project A /api/info responds" `
            -Condition ($null -ne $infoA) `
            -Message "No response from /api/info after waiting for server readiness"

        if ($infoA) {
            Assert-Equal -Name "Project A /api/info returns correct project_root" `
                -Expected $projectA.ProjectRoot `
                -Actual $infoA.project_root
        }

        # Simulate the conflict: write Project A's port into Project B's ui-port file
        $portA.ToString() | Set-Content (Join-Path $projectB.ControlDir "ui-port") -NoNewline -Encoding UTF8

        # Verify that /api/info on the conflicting port returns Project A's root (not B's)
        $infoConflict = $null
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$portA/api/info" -TimeoutSec 2 -ErrorAction Stop
            $infoConflict = $resp.Content | ConvertFrom-Json
        } catch {}

        if ($infoConflict) {
            Assert-True -Name "Conflicting port /api/info returns different project_root" `
                -Condition ($infoConflict.project_root -ne $projectB.ProjectRoot) `
                -Message "Server on port $portA should belong to Project A, not Project B"
        }

        # Remove the conflicting ui-port file before starting server B
        # (just like go.ps1 line 89 does before launching a new server)
        $conflictPortFile = Join-Path $projectB.ControlDir "ui-port"
        if (Test-Path $conflictPortFile) { Remove-Item $conflictPortFile -Force }

        # Start Project B's server — it should auto-select a different port
        $serverB = Start-UiServer -BotDir $projectB.BotDir
        $portB = Wait-ForUiPort -BotDir $projectB.BotDir

        Assert-True -Name "Project B server starts and writes port" `
            -Condition ($portB -gt 0) `
            -Message "Failed to detect port from ui-port file"

        Assert-True -Name "Project B gets a different port than Project A" `
            -Condition ($portB -ne $portA) `
            -Message "Project B got port $portB, same as Project A ($portA)"

        if ($portB -gt 0 -and $portB -ne $portA) {
            # Wait for server B to be fully ready
            $infoB = Wait-ForServerReady -Port $portB

            Assert-True -Name "Project B /api/info responds" `
                -Condition ($null -ne $infoB) `
                -Message "No response from /api/info on port $portB"

            if ($infoB) {
                Assert-Equal -Name "Project B /api/info returns correct project_root" `
                    -Expected $projectB.ProjectRoot `
                    -Actual $infoB.project_root
            }
        }
    }

} catch {
    Write-TestResult -Name "Multi-instance server tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    Stop-UiServer -Process $serverB
    Stop-UiServer -Process $serverA
    if ($projectB) { Remove-TestProject -Path $projectB.ProjectRoot }
    if ($projectA) { Remove-TestProject -Path $projectA.ProjectRoot }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Server Startup"

if (-not $allPassed) {
    exit 1
}
