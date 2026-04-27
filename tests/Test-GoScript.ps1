#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: go.ps1 entry point tests.
.DESCRIPTION
    Tests that go.ps1 successfully launches the UI server, writes the port file,
    and the server responds on the expected port.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Go Script (go.ps1) Tests" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "core")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Go Script"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════

function Start-GoScript {
    <#
    .SYNOPSIS
        Run go.ps1 as a background process with browser opening suppressed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir
    )

    $goScript = Join-Path $BotDir "go.ps1"
    if (-not (Test-Path $goScript)) {
        throw "go.ps1 not found: $goScript"
    }

    $escapedPath = $goScript -replace "'", "''"

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    # Define a no-op Open-Url so go.ps1 skips browser opening,
    # and override Start-Process to suppress the fallback browser launch
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"function Open-Url { param(`$u) }; function Start-Process { param(`$FilePath, `$ArgumentList, [switch]`$NoNewWindow) if (`$FilePath -eq 'pwsh') { Microsoft.PowerShell.Management\Start-Process -FilePath `$FilePath -ArgumentList `$ArgumentList -NoNewWindow:`$NoNewWindow } }; & '$escapedPath' -Headless`""
    $psi.WorkingDirectory = Split-Path -Parent $BotDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    # Drain stdout/stderr asynchronously to prevent pipe buffer deadlock
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    return $process
}

function Wait-ForGoScript {
    <#
    .SYNOPSIS
        Wait for go.ps1 process to exit and return exit code.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )

    $exited = $Process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $Process.Kill() } catch { Write-Verbose "Non-critical operation failed: $_" }
        return -1
    }
    return $Process.ExitCode
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
            $content = Get-Content $portFile -Raw
            if ($null -ne $content) {
                $raw = $content.Trim()
                if ($raw -match '^\d+$') {
                    return [int]$raw
                }
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
            Write-Verbose "Server not ready yet — keep polling: $_"
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Stop-ServerOnPort {
    <#
    .SYNOPSIS
        Find and kill the server process listening on a given port (cross-platform).
    #>
    param([int]$Port)
    if ($Port -le 0) { return }
    try {
        if ($IsWindows) {
            $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
            if ($conn) {
                $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
                if ($proc) {
                    $proc.Kill()
                    $proc.WaitForExit(3000) | Out-Null
                }
            }
        } else {
            # macOS/Linux: use lsof to find the process listening on the port
            $lsofOutput = & lsof -ti "tcp:$Port" 2>/dev/null
            if ($lsofOutput) {
                foreach ($pid in ($lsofOutput -split "`n")) {
                    if ($pid -match '^\d+$') {
                        & kill $pid 2>/dev/null
                    }
                }
            }
        }
    } catch {
        Write-Verbose "Failed to stop server on port ${Port}: $_"
    }
}

function Stop-OrphanedServerProcesses {
    <#
    .SYNOPSIS
        Kill any pwsh processes whose command line includes the test project's server.ps1 path.
        Fallback cleanup for cases where the port was never written or Stop-ServerOnPort missed it.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir
    )
    try {
        $serverScript = Join-Path $BotDir "core/ui/server.ps1"
        # Find pwsh processes whose command line references this project's server.ps1
        $candidates = Get-Process -Name pwsh -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $cmdLine = if ($IsWindows) {
                        (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)" -ErrorAction SilentlyContinue).CommandLine
                    } else {
                        # ps -p works on both macOS and Linux (/proc is Linux-only)
                        & ps -p $_.Id -o command= 2>/dev/null
                    }
                    $cmdLine -and $cmdLine.Contains($serverScript)
                } catch { $false }
            }
        foreach ($proc in $candidates) {
            try {
                $proc.Kill()
                $proc.WaitForExit(3000) | Out-Null
            } catch { Write-Verbose "Failed to kill orphaned server process $($proc.Id): $_" }
        }
    } catch {
        Write-Verbose "Orphan cleanup failed: $_"
    }
}

# ═══════════════════════════════════════════════════════════════════
# GO.PS1 BASIC EXECUTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GO.PS1 BASIC EXECUTION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$project = $null
$goProcess = $null
$port = 0

try {
    # Set up test project
    $project = Initialize-TestBotProject

    # Run go.ps1
    $goProcess = Start-GoScript -BotDir $project.BotDir
    $exitCode = Wait-ForGoScript -Process $goProcess -TimeoutSeconds 30

    Assert-True -Name "go.ps1 exits successfully" `
        -Condition ($exitCode -eq 0) `
        -Message "go.ps1 exited with code $exitCode"

    # Wait for port file and server readiness
    $port = Wait-ForUiPort -BotDir $project.BotDir -TimeoutSeconds 15

    Assert-True -Name "Port file created by server" `
        -Condition ($port -gt 0) `
        -Message "ui-port file not created within timeout"

    Assert-PathExists -Name ".control directory exists" `
        -Path $project.ControlDir

    if ($port -gt 0) {
        $info = Wait-ForServerReady -Port $port -TimeoutSeconds 30

        Assert-True -Name "Server responds on port $port" `
            -Condition ($null -ne $info) `
            -Message "Server did not respond on /api/info"

        if ($null -ne $info) {
            Assert-Equal -Name "/api/info returns correct project_root" `
                -Expected $project.ProjectRoot `
                -Actual $info.project_root
        }
    }

} catch {
    Write-TestResult -Name "go.ps1 execution" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    if ($port -gt 0) { Stop-ServerOnPort -Port $port }
    # Kill any server processes spawned for this test project (catches orphans when port was never written)
    if ($project) { Stop-OrphanedServerProcesses -BotDir $project.BotDir }
    if ($goProcess -and -not $goProcess.HasExited) {
        try { $goProcess.Kill() } catch { Write-Verbose "Non-critical operation failed: $_" }
    }
    if ($goProcess) { try { $goProcess.Dispose() } catch { Write-Verbose "Cleanup: $_" } }
    if ($project) { Remove-TestProject -Path $project.ProjectRoot }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Go Script"

if (-not $allPassed) {
    exit 1
}
