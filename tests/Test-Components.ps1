#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Component tests for dotbot-v3 MCP tools and modules.
.DESCRIPTION
    Tests MCP server boot, task lifecycle, validation, session tracking,
    and activity logging. No AI/Claude dependency required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Component Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "profiles\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 2: Components"
    exit 1
}

# Check prerequisite: powershell-yaml must be available
$yamlModule = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
if (-not $yamlModule) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "powershell-yaml module not installed"
    Write-TestSummary -LayerName "Layer 2: Components"
    exit 1
}

# Create a test project with .bot initialized
$testProject = New-TestProject
$botDir = Join-Path $testProject ".bot"

Push-Location $testProject
& pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null

# Commit init files so git-clean verification passes during task_mark_done
& git add -A 2>&1 | Out-Null
& git commit -m "dotbot init" --quiet 2>&1 | Out-Null
Pop-Location

# Strip verify config to only include scripts that actually exist in the test project
$verifyConfigPath = Join-Path $botDir "hooks\verify\config.json"
if (Test-Path $verifyConfigPath) {
    try {
        $verifyConfig = Get-Content $verifyConfigPath -Raw | ConvertFrom-Json
        $verifyDir = Join-Path $botDir "hooks\verify"
        $existingScripts = @()
        foreach ($script in $verifyConfig.scripts) {
            if (Test-Path (Join-Path $verifyDir $script)) {
                $existingScripts += $script
            }
        }
        $verifyConfig.scripts = $existingScripts
        $verifyConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $verifyConfigPath -Encoding UTF8
    } catch {}
}

if (-not (Test-Path $botDir)) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "Failed to initialize .bot in test project"
    Remove-TestProject -Path $testProject
    Write-TestSummary -LayerName "Layer 2: Components"
    exit 1
}

function Test-TcpPortAvailable {
    param(
        [Parameter(Mandatory)]
        [int]$Port
    )

    $tcpListener = $null
    try {
        $tcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $tcpListener.Start()
    } catch {
        return $false
    } finally {
        if ($null -ne $tcpListener) {
            try { $tcpListener.Stop() } catch { }
        }
    }

    $httpListener = [System.Net.HttpListener]::new()
    try {
        $httpListener.Prefixes.Add("http://localhost:$Port/")
        $httpListener.Start()
        return $true
    } catch {
        return $false
    } finally {
        try {
            if ($httpListener.IsListening) {
                $httpListener.Stop()
            }
        } catch { }
        try { $httpListener.Close() } catch { }
    }
}

function Wait-HttpReady {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [int]$TimeoutSeconds = 12
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
                return $true
            }
        } catch { }
        Start-Sleep -Milliseconds 300
    }

    return $false
}

function Start-UiServerProcess {
    param(
        [Parameter(Mandatory)]
        [string]$BotDir,
        [Parameter(Mandatory)]
        [int]$Port
    )

    $serverScript = Join-Path $BotDir "systems\ui\server.ps1"
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`" -Port $Port"
    $psi.WorkingDirectory = $BotDir
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    return [System.Diagnostics.Process]::Start($psi)
}

# ═══════════════════════════════════════════════════════════════════
# UI PORT AUTO-SELECTION (go.ps1)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  UI PORT AUTO-SELECTION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$primaryUiProcess = $null
$secondaryUiPid = $null
$goHarnessScript = $null
$goHarnessProcess = $null
$tempHome = $null
$goUrlCapturePath = Join-Path $botDir ".control\go-url-capture.txt"
$goPidCapturePath = Join-Path $botDir ".control\go-server-pid.txt"

try {
    if (-not (Test-TcpPortAvailable -Port 8686)) {
        Write-TestResult -Name "go.ps1 fallback test prerequisites (port 8686 free)" -Status Skip -Message "Port 8686 is already in use on this machine"
    } else {
        if (Test-Path $goUrlCapturePath) { Remove-Item -Path $goUrlCapturePath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $goPidCapturePath) { Remove-Item -Path $goPidCapturePath -Force -ErrorAction SilentlyContinue }

        $primaryUiProcess = Start-UiServerProcess -BotDir $botDir -Port 8686
        Start-Sleep -Seconds 2

        Assert-True -Name "primary UI server process starts on 8686" `
            -Condition ($null -ne $primaryUiProcess -and -not $primaryUiProcess.HasExited) `
            -Message "Primary server failed to start on port 8686"

        $primaryReady = $false
        if ($null -ne $primaryUiProcess -and -not $primaryUiProcess.HasExited) {
            $primaryReady = Wait-HttpReady -Url "http://localhost:8686/"
        }

        Assert-True -Name "primary UI server responds on 8686" `
            -Condition $primaryReady `
            -Message "http://localhost:8686 did not become reachable"

        if ($primaryReady) {
            $goScriptPath = Join-Path $botDir "go.ps1"
            $goScriptLiteral = $goScriptPath.Replace("'", "''")
            $botDirLiteral = $botDir.Replace("'", "''")
            $urlCaptureLiteral = $goUrlCapturePath.Replace("'", "''")
            $pidCaptureLiteral = $goPidCapturePath.Replace("'", "''")

            $tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-home-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $tempHome -Force | Out-Null

            $goHarnessScript = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-go-harness-$([System.Guid]::NewGuid().ToString('N')).ps1"
            $harnessContent = @"
`$ErrorActionPreference = 'Stop'
function Start-Process {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = `$true)]
        [string]`$FilePath,
        [string[]]`$ArgumentList
    )

    if (`$FilePath -eq 'pwsh') {
        `$proc = Microsoft.PowerShell.Management\Start-Process -FilePath `$FilePath -ArgumentList `$ArgumentList -PassThru
        Set-Content -Path '$pidCaptureLiteral' -Value `$proc.Id -Encoding UTF8
        return `$proc
    }

    Set-Content -Path '$urlCaptureLiteral' -Value `$FilePath -Encoding UTF8
    return `$null
}

Set-Location '$botDirLiteral'
. '$goScriptLiteral'
"@
            Set-Content -Path $goHarnessScript -Value $harnessContent -Encoding UTF8

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = "pwsh"
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$goHarnessScript`""
            $psi.WorkingDirectory = $botDir
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.Environment["HOME"] = $tempHome
            $psi.Environment["USERPROFILE"] = $tempHome

            $goHarnessProcess = [System.Diagnostics.Process]::Start($psi)
            if ($null -eq $goHarnessProcess) {
                Write-TestResult -Name "go.ps1 harness process starts" -Status Fail -Message "Unable to start harness process"
            } else {
                if (-not $goHarnessProcess.WaitForExit(20000)) {
                    try { $goHarnessProcess.Kill() } catch { }
                    Write-TestResult -Name "go.ps1 harness exits in time" -Status Fail -Message "Harness timed out after 20s"
                } else {
                    $goStdErr = $goHarnessProcess.StandardError.ReadToEnd()
                    $goStdOut = $goHarnessProcess.StandardOutput.ReadToEnd()
                    Assert-True -Name "go.ps1 harness exits cleanly" `
                        -Condition ($goHarnessProcess.ExitCode -eq 0) `
                        -Message "ExitCode=$($goHarnessProcess.ExitCode) stderr=$goStdErr stdout=$goStdOut"

                    $capturedUrl = if (Test-Path $goUrlCapturePath) { (Get-Content -Path $goUrlCapturePath -Raw).Trim() } else { "" }
                    Assert-True -Name "go.ps1 opens a localhost URL" `
                        -Condition ($capturedUrl -match '^http://localhost:\d+/?$') `
                        -Message "Captured URL was '$capturedUrl'"

                    $selectedPort = 0
                    if ($capturedUrl -match '^http://localhost:(\d+)/?$') {
                        $selectedPort = [int]$Matches[1]
                    }

                    Assert-True -Name "go.ps1 selects a port above busy 8686" `
                        -Condition ($selectedPort -ge 8687) `
                        -Message "Selected port was $selectedPort"

                    $secondaryPidText = if (Test-Path $goPidCapturePath) { (Get-Content -Path $goPidCapturePath -Raw).Trim() } else { "" }
                    if ($secondaryPidText -match '^\d+$') {
                        $secondaryUiPid = [int]$secondaryPidText
                    }

                    Assert-True -Name "go.ps1 launches a second UI server process" `
                        -Condition ($secondaryUiPid -gt 0) `
                        -Message "No secondary server PID captured"

                    if ($selectedPort -gt 0) {
                        $secondaryReady = Wait-HttpReady -Url "http://localhost:$selectedPort/"
                        Assert-True -Name "secondary UI server responds on selected port" `
                            -Condition $secondaryReady `
                            -Message "http://localhost:$selectedPort did not become reachable"
                    }
                }
            }
        }
    }
} catch {
    Write-TestResult -Name "go.ps1 auto-port tests" -Status Fail -Message $_.Exception.Message
} finally {
    if ($goHarnessProcess) {
        try {
            if (-not $goHarnessProcess.HasExited) { $goHarnessProcess.Kill() }
            $goHarnessProcess.Dispose()
        } catch { }
    }

    if ($secondaryUiPid -gt 0) {
        try {
            $secondaryProc = Get-Process -Id $secondaryUiPid -ErrorAction SilentlyContinue
            if ($secondaryProc) { $secondaryProc.Kill() }
        } catch { }
    }

    if ($primaryUiProcess) {
        try {
            if (-not $primaryUiProcess.HasExited) { $primaryUiProcess.Kill() }
            $primaryUiProcess.Dispose()
        } catch { }
    }

    if ($goHarnessScript -and (Test-Path $goHarnessScript)) {
        Remove-Item -Path $goHarnessScript -Force -ErrorAction SilentlyContinue
    }

    if ($tempHome -and (Test-Path $tempHome)) {
        Remove-Item -Path $tempHome -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $goUrlCapturePath) {
        Remove-Item -Path $goUrlCapturePath -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $goPidCapturePath) {
        Remove-Item -Path $goPidCapturePath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# MCP SERVER BOOT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MCP SERVER" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$mcpProcess = $null
$requestId = 0

try {
    $mcpProcess = Start-McpServer -BotDir $botDir
    Assert-True -Name "MCP server starts" -Condition (-not $mcpProcess.HasExited) -Message "Server process exited immediately"

    # Initialize
    $initResponse = Send-McpInitialize -Process $mcpProcess
    Assert-True -Name "MCP initialize responds" `
        -Condition ($null -ne $initResponse) `
        -Message "No response from initialize"

    if ($initResponse) {
        Assert-True -Name "MCP returns protocol version" `
            -Condition ($null -ne $initResponse.result.protocolVersion) `
            -Message "Missing protocolVersion in response"

        Assert-True -Name "MCP returns server info" `
            -Condition ($null -ne $initResponse.result.serverInfo) `
            -Message "Missing serverInfo in response"
    }

    # List tools
    $requestId++
    $listResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/list'
        params  = @{}
    }

    Assert-True -Name "MCP tools/list responds" `
        -Condition ($null -ne $listResponse) `
        -Message "No response from tools/list"

    if ($listResponse -and $listResponse.result) {
        $toolCount = $listResponse.result.tools.Count
        Assert-True -Name "MCP has tools loaded (found $toolCount)" `
            -Condition ($toolCount -gt 0) `
            -Message "No tools loaded"

        # Check key tools exist
        $toolNames = $listResponse.result.tools | ForEach-Object { $_.name }
        $expectedTools = @('task_create', 'task_get_next', 'task_mark_in_progress', 'task_mark_done', 'task_list', 'task_get_stats', 'session_initialize')
        foreach ($tool in $expectedTools) {
            Assert-True -Name "Tool '$tool' registered" `
                -Condition ($tool -in $toolNames) `
                -Message "Tool not found in tools/list"
        }
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK LIFECYCLE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK LIFECYCLE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Create a task
    $requestId++
    $createResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Test Task Alpha'
                description = 'A test task for integration testing'
                category    = 'feature'
                priority    = 10
                effort      = 'S'
            }
        }
    }

    Assert-True -Name "task_create responds" `
        -Condition ($null -ne $createResponse) `
        -Message "No response"

    $taskId = $null
    if ($createResponse -and $createResponse.result) {
        $resultText = $createResponse.result.content[0].text
        $resultObj = $resultText | ConvertFrom-Json
        Assert-True -Name "task_create returns success" `
            -Condition ($resultObj.success -eq $true) `
            -Message "success was not true: $resultText"
        $taskId = $resultObj.task_id
        Assert-True -Name "task_create returns task_id" `
            -Condition ($null -ne $taskId -and $taskId.Length -gt 0) `
            -Message "No task_id in response"
    }

    # Verify file exists in todo/
    if ($taskId) {
        $todoDir = Join-Path $botDir "workspace\tasks\todo"
        $todoFiles = Get-ChildItem -Path $todoDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Task JSON file created in todo/" `
            -Condition ($todoFiles.Count -gt 0) `
            -Message "No JSON files found in todo/"
    }

    # List tasks to verify creation (more reliable than get_next which uses index cache)
    $requestId++
    $listResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_list'
            arguments = @{}
        }
    }

    Assert-True -Name "task_list responds" `
        -Condition ($null -ne $listResponse) `
        -Message "No response"

    if ($listResponse -and $listResponse.result) {
        $listText = $listResponse.result.content[0].text
        $listObj = $listText | ConvertFrom-Json
        $taskCount = if ($listObj.tasks) { $listObj.tasks.Count } else { 0 }
        Assert-True -Name "task_list shows created task" `
            -Condition ($listObj.success -eq $true -and $taskCount -gt 0) `
            -Message "No tasks found: $listText"
    }

    # Mark in-progress
    if ($taskId) {
        $requestId++
        $progressResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_in_progress'
                arguments = @{ task_id = $taskId }
            }
        }

        Assert-True -Name "task_mark_in_progress responds" `
            -Condition ($null -ne $progressResponse) `
            -Message "No response"

        if ($progressResponse -and $progressResponse.result) {
            $progText = $progressResponse.result.content[0].text
            $progObj = $progText | ConvertFrom-Json
            Assert-True -Name "task_mark_in_progress succeeds" `
                -Condition ($progObj.success -eq $true) `
                -Message "Failed: $progText"
        }

        # Verify file moved to in-progress/
        $inProgressDir = Join-Path $botDir "workspace\tasks\in-progress"
        $ipFiles = Get-ChildItem -Path $inProgressDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Task file moved to in-progress/" `
            -Condition ($ipFiles.Count -gt 0) `
            -Message "No files found in in-progress/"

        # Mark done
        $requestId++
        $doneResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_done'
                arguments = @{ task_id = $taskId }
            }
        }

        Assert-True -Name "task_mark_done responds" `
            -Condition ($null -ne $doneResponse) `
            -Message "No response"

        if ($doneResponse -and $doneResponse.result) {
            $doneText = $doneResponse.result.content[0].text
            $doneObj = $doneText | ConvertFrom-Json
            Assert-True -Name "task_mark_done succeeds" `
                -Condition ($doneObj.success -eq $true) `
                -Message "Failed: $doneText"
        }

        # Verify file moved to done/
        $doneDir = Join-Path $botDir "workspace\tasks\done"
        $doneFiles = Get-ChildItem -Path $doneDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Task file moved to done/" `
            -Condition ($doneFiles.Count -gt 0) `
            -Message "No files found in done/"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK VALIDATION
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK VALIDATION" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Missing name should fail
    $requestId++
    $badResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                description = 'A task with no name'
            }
        }
    }

    Assert-True -Name "task_create rejects missing name" `
        -Condition ($null -ne $badResponse -and $null -ne $badResponse.error) `
        -Message "Expected error response for missing name"

    # Invalid category should fail
    $requestId++
    $badCatResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Bad Category Task'
                description = 'A task with invalid category'
                category    = 'invalid-category'
            }
        }
    }

    Assert-True -Name "task_create rejects invalid category" `
        -Condition ($null -ne $badCatResponse -and $null -ne $badCatResponse.error) `
        -Message "Expected error response for invalid category"

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK STATS
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK STATS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $requestId++
    $statsResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_get_stats'
            arguments = @{}
        }
    }

    Assert-True -Name "task_get_stats responds" `
        -Condition ($null -ne $statsResponse) `
        -Message "No response"

    if ($statsResponse -and $statsResponse.result) {
        $statsText = $statsResponse.result.content[0].text
        $statsObj = $statsText | ConvertFrom-Json
        Assert-True -Name "task_get_stats returns counts" `
            -Condition ($statsObj.success -eq $true -and $null -ne $statsObj.total_tasks) `
            -Message "No count data: $statsText"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # SESSION LIFECYCLE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  SESSION LIFECYCLE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Initialize session
    $requestId++
    $sessionInitResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'session_initialize'
            arguments = @{}
        }
    }

    Assert-True -Name "session_initialize responds" `
        -Condition ($null -ne $sessionInitResponse) `
        -Message "No response"

    # Get session state
    $requestId++
    $sessionStateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'session_get_state'
            arguments = @{}
        }
    }

    Assert-True -Name "session_get_state responds" `
        -Condition ($null -ne $sessionStateResponse) `
        -Message "No response"

    # Get session stats
    $requestId++
    $sessionStatsResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'session_get_stats'
            arguments = @{}
        }
    }

    Assert-True -Name "session_get_stats responds" `
        -Condition ($null -ne $sessionStatsResponse) `
        -Message "No response"

} catch {
    Write-TestResult -Name "MCP server tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    if ($mcpProcess) {
        Stop-McpServer -Process $mcpProcess
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════

Remove-TestProject -Path $testProject

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Components"

if (-not $allPassed) {
    exit 1
}
