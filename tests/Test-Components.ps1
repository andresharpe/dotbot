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
# PROVIDERCLI MODULE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROVIDERCLI MODULE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Test that ProviderCLI module loads (use dotbotDir which points to installed profiles)
$providerCliPath = Join-Path $dotbotDir "profiles\default\systems\runtime\ProviderCLI\ProviderCLI.psm1"
$providerCliLoaded = $false
try {
    Import-Module $providerCliPath -Force -ErrorAction Stop
    $providerCliLoaded = $true
} catch {}

Assert-True -Name "ProviderCLI module loads" `
    -Condition $providerCliLoaded `
    -Message "Failed to import ProviderCLI.psm1"

if ($providerCliLoaded) {
    # Test Get-ProviderConfig for Claude (default)
    $claudeConfig = $null
    try { $claudeConfig = Get-ProviderConfig -Name "claude" } catch {}
    Assert-True -Name "Get-ProviderConfig loads claude config" `
        -Condition ($null -ne $claudeConfig -and $claudeConfig.name -eq "claude") `
        -Message "Expected claude config"

    # Test Get-ProviderModels
    $models = $null
    try { $models = Get-ProviderModels -ProviderName "claude" } catch {}
    Assert-True -Name "Get-ProviderModels returns Claude models" `
        -Condition ($null -ne $models -and $models.Count -ge 2) `
        -Message "Expected at least 2 models"

    # Test Resolve-ProviderModelId
    $resolvedId = $null
    try { $resolvedId = Resolve-ProviderModelId -ModelAlias "Opus" -ProviderName "claude" } catch {}
    Assert-True -Name "Resolve-ProviderModelId maps Opus" `
        -Condition ($resolvedId -eq "claude-opus-4-6") `
        -Message "Expected claude-opus-4-6, got $resolvedId"

    # Test cross-provider model rejection
    $crossProviderError = $false
    try { Resolve-ProviderModelId -ModelAlias "Opus" -ProviderName "codex" } catch { $crossProviderError = $true }
    Assert-True -Name "Resolve-ProviderModelId rejects Opus for codex" `
        -Condition $crossProviderError `
        -Message "Should throw for invalid model alias"

    # Test New-ProviderSession for Claude (returns GUID)
    $claudeSession = $null
    try { $claudeSession = New-ProviderSession -ProviderName "claude" } catch {}
    Assert-True -Name "New-ProviderSession returns GUID for Claude" `
        -Condition ($null -ne $claudeSession -and $claudeSession -match '^[0-9a-f]{8}-') `
        -Message "Expected GUID, got $claudeSession"

    # Test New-ProviderSession for Codex (returns null)
    $codexSession = "not-null"
    try { $codexSession = New-ProviderSession -ProviderName "codex" } catch {}
    Assert-True -Name "New-ProviderSession returns null for Codex" `
        -Condition ($null -eq $codexSession) `
        -Message "Expected null, got $codexSession"
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
