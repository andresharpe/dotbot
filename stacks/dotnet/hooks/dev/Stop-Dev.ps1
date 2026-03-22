# Stop-Dev.ps1
# Stops the dev environment

param(
    [switch]$Quiet
)

. "$PSScriptRoot/Common.ps1"
Import-Module "$PSScriptRoot/DevLayout.psm1" -Force -DisableNameChecking

$repoRoot = Invoke-InProjectRoot
$projectName = Get-ProjectName
$sessionName = $projectName.ToLower()

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Stopping $projectName Development Environment" -ForegroundColor White
    Write-Host ("=" * "Stopping $projectName Development Environment".Length) -ForegroundColor White
    Write-Host ""
}

# Close dev layout first
$layoutConfigPath = Join-Path $PSScriptRoot "layout.json"
if (Test-Path $layoutConfigPath) {
    $layoutConfig = Get-Content $layoutConfigPath -Raw | ConvertFrom-Json
    if ($layoutConfig.enabled) {
        $layoutResult = Close-DevLayout -SessionName $sessionName -Quiet:$Quiet
        if (-not $Quiet -and $layoutResult.status -eq "closed") {
            Write-Status "Closed layout session: $sessionName" -Type Success
        }
    }
}

# Read saved PIDs from Start-Dev.ps1
$pidFile = Join-Path $repoRoot ".bot\.dev-pids.json"
$savedPids = $null
if (Test-Path $pidFile) {
    try {
        $savedPids = Get-Content $pidFile -Raw | ConvertFrom-Json
        Write-Status "Found saved PIDs from Start-Dev.ps1" -Type Info
    } catch {
        Write-Status "Could not read PID file" -Type Warn
    }
}

if ($savedPids) {
    # Stop API PowerShell window and its entire process tree
    if ($savedPids.api_pid) {
        $apiProcess = Get-Process -Id $savedPids.api_pid -ErrorAction SilentlyContinue
        if ($apiProcess) {
            # Use taskkill with /T to kill the entire process tree (pwsh + dotnet)
            $result = & taskkill /T /F /PID $savedPids.api_pid 2>&1
            if (-not $Quiet) {
                Write-Status "Stopped API process tree (PID: $($savedPids.api_pid))" -Type Success
            }
        } elseif (-not $Quiet) {
            Write-Status "API window already closed" -Type Neutral
        }
    }
} elseif (-not $Quiet) {
    Write-Status "No PID file found - nothing to stop" -Type Warn
    Write-Status "If processes are still running, stop them manually" -Type Info
}

# Clean up PID file
if (Test-Path $pidFile) {
    Remove-Item $pidFile -Force
    if (-not $Quiet) {
        Write-Status "Cleaned up PID file" -Type Neutral
    }
}

if (-not $Quiet) {
    Write-Host ""
    Write-Status "$projectName stopped" -Type Success
    Write-Host ""
}

# Return status for MCP tool consumption
return @{
    status = "stopped"
}
