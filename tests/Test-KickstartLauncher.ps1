#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Kickstart launcher tests.
.DESCRIPTION
    Tests that the kickstart launcher script can be generated correctly and
    that launch-process.ps1 starts up without crashing (module loading,
    directory creation, process registry). Requires Claude CLI on PATH
    to pass preflight — skips gracefully if not available.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Kickstart Launcher Tests" -ForegroundColor Blue
Write-Host "══════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "workflows\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Kickstart Launcher"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════

function New-KickstartLauncher {
    <#
    .SYNOPSIS
        Generate a workflow-launcher.ps1 the same way ProductAPI does.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotDir,
        [string]$Prompt = "Test kickstart prompt"
    )

    $controlDir = Join-Path $BotDir ".control"
    $launchersDir = Join-Path $controlDir "launchers"
    if (-not (Test-Path $launchersDir)) {
        New-Item -Path $launchersDir -ItemType Directory -Force | Out-Null
    }

    $promptFile = Join-Path $launchersDir "workflow-launch-prompt.txt"
    $Prompt | Set-Content -Path $promptFile -Encoding UTF8 -NoNewline

    $launcherPath = Join-Path $BotDir "systems\runtime\launch-process.ps1"
    $wrapperPath = Join-Path $launchersDir "workflow-launcher.ps1"
    @"
`$prompt = Get-Content -LiteralPath '$promptFile' -Raw
& '$launcherPath' -Type kickstart -Prompt `$prompt -Description 'Kickstart: project setup'
"@ | Set-Content -Path $wrapperPath -Encoding UTF8

    return @{
        WrapperPath = $wrapperPath
        PromptFile  = $promptFile
        LaunchersDir = $launchersDir
    }
}

function Start-KickstartLauncher {
    <#
    .SYNOPSIS
        Run the kickstart launcher as a background process.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    return $process
}

function Stop-LauncherProcess {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch { Write-Verbose "Non-critical operation failed: $_" }
        try { [void]$Process.WaitForExit(3000) } catch { Write-Verbose "Cleanup: failed to stop process: $_" }
    }
    try { $Process.Dispose() } catch { Write-Verbose "Cleanup: $_" }
}

# ═══════════════════════════════════════════════════════════════════
# LAUNCHER SCRIPT GENERATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  LAUNCHER SCRIPT GENERATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$project = $null

try {
    $project = Initialize-TestBotProject
    $launcher = New-KickstartLauncher -BotDir $project.BotDir -Prompt "Test kickstart prompt for unit test"

    Assert-PathExists -Name "Launcher script created" `
        -Path $launcher.WrapperPath

    Assert-PathExists -Name "Prompt file created" `
        -Path $launcher.PromptFile

    # Verify launcher is valid PowerShell
    Assert-ValidPowerShell -Name "Launcher script is valid PowerShell" `
        -Path $launcher.WrapperPath

    # Verify launcher references launch-process.ps1
    Assert-FileContains -Name "Launcher calls launch-process.ps1" `
        -Path $launcher.WrapperPath `
        -Pattern "launch-process\.ps1"

    Assert-FileContains -Name "Launcher passes -Type kickstart" `
        -Path $launcher.WrapperPath `
        -Pattern "-Type kickstart"

    # Verify prompt file content
    $promptContent = Get-Content $launcher.PromptFile -Raw
    Assert-True -Name "Prompt file has correct content" `
        -Condition ($promptContent -eq "Test kickstart prompt for unit test") `
        -Message "Prompt file content: '$promptContent'"

} catch {
    Write-TestResult -Name "Launcher generation" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    if ($project) { Remove-TestProject -Path $project.ProjectRoot }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# LAUNCHER STARTUP EXECUTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  LAUNCHER STARTUP EXECUTION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Check if Claude CLI is available (needed for preflight)
$claudeAvailable = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeAvailable) {
    Write-TestResult -Name "Launcher startup tests" -Status Skip `
        -Message "Claude CLI not installed — cannot pass preflight"
} else {
    $project = $null
    $launcherProcess = $null

    try {
        $project = Initialize-TestBotProject
        $launcher = New-KickstartLauncher -BotDir $project.BotDir -Prompt "Test kickstart prompt"

        $launcherProcess = Start-KickstartLauncher `
            -ScriptPath $launcher.WrapperPath `
            -WorkingDirectory $project.ProjectRoot

        # Wait for process to start and create its registry file
        # launch-process.ps1 creates .control/processes/<id>.json early in startup
        $processesDir = Join-Path $project.ControlDir "processes"
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        $processFile = $null

        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path $processesDir) {
                $files = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue
                if ($files -and $files.Count -gt 0) {
                    $processFile = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    break
                }
            }
            Start-Sleep -Milliseconds 500
        }

        Assert-True -Name "Process registry file created" `
            -Condition ($null -ne $processFile) `
            -Message "No process JSON found in $processesDir within timeout"

        if ($processFile) {
            # Verify process file is valid JSON with expected structure
            Assert-ValidJson -Name "Process file is valid JSON" `
                -Path $processFile.FullName

            $processData = Get-Content $processFile.FullName -Raw | ConvertFrom-Json

            Assert-Equal -Name "Process type is kickstart" `
                -Expected "kickstart" `
                -Actual $processData.type

            Assert-True -Name "Process has an ID" `
                -Condition ($null -ne $processData.id -and $processData.id.Length -gt 0) `
                -Message "Process ID is empty"

            Assert-True -Name "Process has a PID" `
                -Condition ($processData.pid -gt 0) `
                -Message "Process PID is $($processData.pid)"

            Assert-True -Name "Process has started_at timestamp" `
                -Condition ($null -ne $processData.started_at) `
                -Message "started_at is null"
        }

        # Verify logs directory was created
        $logsDir = Join-Path $project.ControlDir "logs"
        Assert-PathExists -Name "Logs directory created" `
            -Path $logsDir

    } catch {
        Write-TestResult -Name "Launcher startup" -Status Fail -Message "Exception: $($_.Exception.Message)"
    } finally {
        Stop-LauncherProcess -Process $launcherProcess
        # Also clean up any child processes spawned by launch-process.ps1
        if ($processFile) {
            try {
                $pd = Get-Content $processFile.FullName -Raw | ConvertFrom-Json
                if ($pd.pid) {
                    $childProc = Get-Process -Id $pd.pid -ErrorAction SilentlyContinue
                    if ($childProc -and -not $childProc.HasExited) {
                        $childProc.Kill()
                        $childProc.WaitForExit(3000) | Out-Null
                    }
                }
            } catch { Write-Verbose "Cleanup: $_" }
        }
        if ($project) { Remove-TestProject -Path $project.ProjectRoot }
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Kickstart Launcher"

if (-not $allPassed) {
    exit 1
}
