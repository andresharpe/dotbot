#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Component tests for dotbot MCP tools and modules.
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
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "workflows\default")
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
    } catch { Write-Verbose "Failed to write file: $_" }
}

if (-not (Test-Path $botDir)) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "Failed to initialize .bot in test project"
    Remove-TestProject -Path $testProject
    Write-TestSummary -LayerName "Layer 2: Components"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# WORKSPACE INSTANCE ID
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKSPACE INSTANCE ID" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$settingsPath = Join-Path $botDir "settings\settings.default.json"
Assert-PathExists -Name "settings.default.json exists" -Path $settingsPath
if (Test-Path $settingsPath) {
    $settingsJson = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $parsedGuid = [guid]::Empty
    $hasInitGuid = $settingsJson.PSObject.Properties['instance_id'] -and [guid]::TryParse("$($settingsJson.instance_id)", [ref]$parsedGuid)
    Assert-True -Name "settings.instance_id is valid after init" `
        -Condition $hasInitGuid `
        -Message "Expected a valid GUID in settings.instance_id"
}

$instanceIdModule = Join-Path $botDir "systems\runtime\modules\InstanceId.psm1"
if (Test-Path $instanceIdModule) {
    Import-Module $instanceIdModule -Force

    # Simulate legacy project: remove instance_id then ensure it is recreated and persisted
    $legacySettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    [void]$legacySettings.PSObject.Properties.Remove('instance_id')
    $legacySettings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath

    $generatedInstanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
    $generatedGuid = [guid]::Empty
    Assert-True -Name "legacy settings missing instance_id gets backfilled" `
        -Condition ([guid]::TryParse("$generatedInstanceId", [ref]$generatedGuid)) `
        -Message "Expected Get-OrCreateWorkspaceInstanceId to create a valid GUID"

    $settingsAfterBackfill = Get-Content $settingsPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "backfilled instance_id is persisted to settings" `
        -Expected "$generatedGuid" `
        -Actual "$($settingsAfterBackfill.instance_id)"

    $sameInstanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
    Assert-Equal -Name "Get-OrCreateWorkspaceInstanceId is stable when already set" `
        -Expected "$generatedGuid" `
        -Actual "$sameInstanceId"
} else {
    Write-TestResult -Name "InstanceId module exists" -Status Fail -Message "Module not found at $instanceIdModule"
}

$worktreeManagerModule = Join-Path $botDir "systems\runtime\modules\WorktreeManager.psm1"
if (Test-Path $worktreeManagerModule) {
    Import-Module $worktreeManagerModule -Force

    Add-Content -Path (Join-Path $testProject ".gitignore") -Value ".serena/"
    $serenaCacheDir = Join-Path $testProject ".serena\cache"
    New-Item -Path $serenaCacheDir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $serenaCacheDir "index.json") -Value '{"cache":true}'
    Set-Content -Path (Join-Path $testProject ".env") -Value "DOTBOT_TEST=1"

    $gitignoredCopyPaths = @(Get-GitignoredCopyPaths -ProjectRoot $testProject)

    Assert-True -Name "Get-GitignoredCopyPaths keeps ignored env files" `
        -Condition ($gitignoredCopyPaths -contains ".env") `
        -Message "Expected .env to be copied into worktrees"
    Assert-True -Name "Get-GitignoredCopyPaths excludes legacy .serena caches" `
        -Condition (-not ($gitignoredCopyPaths -contains ".serena/cache/index.json")) `
        -Message "Legacy .serena cache contents should stay excluded from worktree copies"
} else {
    Write-TestResult -Name "WorktreeManager module exists" -Status Fail -Message "Module not found at $worktreeManagerModule"
}

$promptBuilderScript = Join-Path $botDir "systems\runtime\modules\prompt-builder.ps1"
if (Test-Path $promptBuilderScript) {
    . $promptBuilderScript
    $promptTask = [PSCustomObject]@{
        id = "7b012fb8-d6fa-45e8-b89e-062b4bcb16ae"
        name = "Prompt Builder Test"
        category = "feature"
        priority = 10
        description = "Validate short ID interpolation"
        applicable_standards = @()
        applicable_agents = @()
        acceptance_criteria = @()
        steps = @()
        questions_resolved = @()
    }

    $promptTemplate = "[task:{{TASK_ID_SHORT}}] [bot:{{INSTANCE_ID_SHORT}}] [bot-full:{{INSTANCE_ID}}]"
    $promptResult = Build-TaskPrompt -PromptTemplate $promptTemplate -Task $promptTask -SessionId "sess-1" -InstanceId "A1B2C3D4-1111-2222-3333-444455556666"

    Assert-True -Name "Build-TaskPrompt replaces TASK_ID_SHORT" `
        -Condition ($promptResult -match '\[task:7b012fb8\]') `
        -Message "Expected [task:7b012fb8] in prompt output"
    Assert-True -Name "Build-TaskPrompt replaces INSTANCE_ID_SHORT" `
        -Condition ($promptResult -match '\[bot:a1b2c3d4\]') `
        -Message "Expected [bot:a1b2c3d4] in prompt output"
    Assert-True -Name "Build-TaskPrompt keeps full INSTANCE_ID available" `
        -Condition ($promptResult -match '\[bot-full:A1B2C3D4-1111-2222-3333-444455556666\]') `
        -Message "Expected full INSTANCE_ID replacement"
} else {
    Write-TestResult -Name "prompt-builder script exists" -Status Fail -Message "Script not found at $promptBuilderScript"
}

$extractCommitInfoScript = Join-Path $botDir "systems\mcp\modules\Extract-CommitInfo.ps1"
if (Test-Path $extractCommitInfoScript) {
    . $extractCommitInfoScript

    $parserTaskShort = "feedc0de"
    Push-Location $testProject
    try {
        "short" | Set-Content -Path (Join-Path $testProject "parser-short.txt")
        & git add parser-short.txt 2>&1 | Out-Null
        & git commit -m "Parser short tag test" -m "[task:$parserTaskShort]" -m "[bot:a1b2c3d4]" --quiet 2>&1 | Out-Null

        "full" | Set-Content -Path (Join-Path $testProject "parser-full.txt")
        & git add parser-full.txt 2>&1 | Out-Null
        & git commit -m "Parser full tag test" -m "[task:$parserTaskShort]" -m "[bot:a1b2c3d4-1111-2222-3333-444455556666]" --quiet 2>&1 | Out-Null
    } finally {
        Pop-Location
    }

    $commitInfo = Get-TaskCommitInfo -TaskId $parserTaskShort -ProjectRoot $testProject -MaxCommits 20
    $shortTagCommit = @($commitInfo | Where-Object { $_.commit_subject -eq "Parser short tag test" }) | Select-Object -First 1
    $fullTagCommit = @($commitInfo | Where-Object { $_.commit_subject -eq "Parser full tag test" }) | Select-Object -First 1

    Assert-True -Name "Get-TaskCommitInfo finds short [bot:XXXXXXXX] tags" `
        -Condition ($null -ne $shortTagCommit -and $shortTagCommit.workspace_short_id -eq "a1b2c3d4") `
        -Message "Expected workspace_short_id a1b2c3d4 from short bot tag"
    Assert-True -Name "Get-TaskCommitInfo derives short ID from full bot GUID tag" `
        -Condition ($null -ne $fullTagCommit -and $fullTagCommit.workspace_short_id -eq "a1b2c3d4") `
        -Message "Expected workspace_short_id a1b2c3d4 from full GUID bot tag"
} else {
    Write-TestResult -Name "Extract-CommitInfo module exists" -Status Fail -Message "Module not found at $extractCommitInfoScript"
}

Write-Host ""

# PROCESS STATUS SANITIZATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROCESS STATUS SANITIZATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$fileWatcherModule = Join-Path $botDir "systems\ui\modules\FileWatcher.psm1"
$controlApiModule = Join-Path $botDir "systems\ui\modules\ControlAPI.psm1"
$processApiModule = Join-Path $botDir "systems\ui\modules\ProcessAPI.psm1"
$stateBuilderModule = Join-Path $botDir "systems\ui\modules\StateBuilder.psm1"
$steeringHeartbeatScript = Join-Path $botDir "systems\mcp\tools\steering-heartbeat\script.ps1"
$dotBotLogModule = Join-Path $botDir "systems\runtime\modules\DotBotLog.psm1"
$consoleSanitizerModule = Join-Path $botDir "systems\runtime\modules\ConsoleSequenceSanitizer.psm1"
$testControlDir = Join-Path $botDir ".control"
$testProcessesDir = Join-Path $testControlDir "processes"
$testLogsDir = Join-Path $testControlDir "logs"

if ((Test-Path $fileWatcherModule) -and (Test-Path $controlApiModule) -and (Test-Path $processApiModule) -and (Test-Path $stateBuilderModule) -and (Test-Path $steeringHeartbeatScript) -and (Test-Path $dotBotLogModule) -and (Test-Path $consoleSanitizerModule)) {
    Import-Module $consoleSanitizerModule -Force
    Import-Module $dotBotLogModule -Force
    Import-Module $fileWatcherModule -Force
    Import-Module $controlApiModule -Force
    Import-Module $processApiModule -Force
    Import-Module $stateBuilderModule -Force
    $global:DotbotProjectRoot = $testProject
    . $steeringHeartbeatScript

    if (-not (Test-Path $testLogsDir)) {
        New-Item -Path $testLogsDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $testProcessesDir)) {
        New-Item -Path $testProcessesDir -ItemType Directory -Force | Out-Null
    }
    Initialize-DotBotLog -LogDir $testLogsDir -ControlDir $testControlDir -ProjectRoot $testProject
    Initialize-FileWatchers -BotRoot $botDir
    Initialize-ControlAPI -ControlDir $testControlDir -ProcessesDir $testProcessesDir -BotRoot $botDir
    Initialize-ProcessAPI -ProcessesDir $testProcessesDir -BotRoot $botDir -ControlDir $testControlDir
    Initialize-StateBuilder -BotRoot $botDir -ControlDir $testControlDir -ProcessesDir $testProcessesDir

    $testProcId = "proc-ansi-sanitize"
    $testProcFile = Join-Path $testProcessesDir "$testProcId.json"
    $testActivityFile = Join-Path $testProcessesDir "$testProcId.activity.jsonl"
    $globalActivityFile = Join-Path $testControlDir "activity.jsonl"
    $esc = [char]27

    try {
        @{
            id = $testProcId
            type = "execution"
            status = "running"
            pid = $PID
            started_at = (Get-Date).ToUniversalTime().ToString("o")
            last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
            last_whisper_index = 0
            heartbeat_status = $null
            heartbeat_next_action = $null
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $heartbeatResult = Invoke-SteeringHeartbeat -Arguments @{
            session_id = "test-session-ansi"
            process_id = $testProcId
            status = "${esc}[38;2;56;52;44mIdle${esc}[0m"
            next_action = "${esc}[38;2;112;104;92mWait${esc}[0m"
        }

        Assert-True -Name "steering_heartbeat accepts ANSI-bearing status text" `
            -Condition ($heartbeatResult.success -eq $true) `
            -Message "Expected heartbeat tool to succeed"

        $storedProc = Get-Content $testProcFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "steering_heartbeat strips ANSI from stored heartbeat_status" `
            -Expected "Idle" `
            -Actual $storedProc.heartbeat_status
        Assert-Equal -Name "steering_heartbeat strips ANSI from stored heartbeat_next_action" `
            -Expected "Wait" `
            -Actual $storedProc.heartbeat_next_action
        Assert-Equal -Name "Console sanitizer preserves plain bracketed text" `
            -Expected "[1]" `
            -Actual (ConvertTo-SanitizedConsoleText "[1]")
        Assert-Equal -Name "Console sanitizer preserves bracketed words" `
            -Expected "[kickstart] phase 1" `
            -Actual (ConvertTo-SanitizedConsoleText "[kickstart] phase 1")
        Assert-True -Name "Console sanitizer strips parameterless orphaned reset fragment" `
            -Condition ($null -eq (ConvertTo-SanitizedConsoleText "[m")) `
            -Message "Expected parameterless reset fragment to be removed"

        $heartbeatBlankResult = Invoke-SteeringHeartbeat -Arguments @{
            session_id = "test-session-ansi"
            process_id = $testProcId
            status = "${esc}[0m"
            next_action = "${esc}[0m"
        }

        Assert-True -Name "steering_heartbeat accepts control-only heartbeat updates" `
            -Condition ($heartbeatBlankResult.success -eq $true) `
            -Message "Expected heartbeat tool to succeed"

        $storedProc = Get-Content $testProcFile -Raw | ConvertFrom-Json
        Assert-True -Name "steering_heartbeat normalizes empty heartbeat_status to null" `
            -Condition ($null -eq $storedProc.heartbeat_status) `
            -Message "Expected heartbeat_status to be null after sanitization"
        Assert-True -Name "steering_heartbeat normalizes empty heartbeat_next_action to null" `
            -Condition ($null -eq $storedProc.heartbeat_next_action) `
            -Message "Expected heartbeat_next_action to be null after sanitization"

        $storedProc.heartbeat_status = "[38;2;56;52;44mIdle[0m"
        $storedProc.heartbeat_next_action = "[38;2;112;104;92mWait[0m"
        $storedProc | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $listedProc = @((Get-ProcessList).processes | Where-Object { $_.id -eq $testProcId }) | Select-Object -First 1
        Assert-Equal -Name "Get-ProcessList strips orphaned ANSI fragments from heartbeat_status" `
            -Expected "Idle" `
            -Actual $listedProc.heartbeat_status
        Assert-Equal -Name "Get-ProcessList strips orphaned ANSI fragments from heartbeat_next_action" `
            -Expected "Wait" `
            -Actual $listedProc.heartbeat_next_action

        Clear-StateCache
        $state = Get-BotState
        Assert-Equal -Name "Get-BotState exposes sanitized execution status" `
            -Expected "Idle" `
            -Actual $state.instances.execution.status
        Assert-Equal -Name "Get-BotState exposes sanitized execution next_action" `
            -Expected "Wait" `
            -Actual $state.instances.execution.next_action

        $storedProc.heartbeat_status = "[0m"
        $storedProc.heartbeat_next_action = "[0m"
        $storedProc | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $listedProc = @((Get-ProcessList).processes | Where-Object { $_.id -eq $testProcId }) | Select-Object -First 1
        Assert-True -Name "Get-ProcessList normalizes empty heartbeat_status to null" `
            -Condition ($null -eq $listedProc.heartbeat_status) `
            -Message "Expected heartbeat_status to be null after sanitization"
        Assert-True -Name "Get-ProcessList normalizes empty heartbeat_next_action to null" `
            -Condition ($null -eq $listedProc.heartbeat_next_action) `
            -Message "Expected heartbeat_next_action to be null after sanitization"

        Clear-StateCache
        $state = Get-BotState
        Assert-True -Name "Get-BotState normalizes empty execution status to null" `
            -Condition ($null -eq $state.instances.execution.status) `
            -Message "Expected execution status to be null after sanitization"
        Assert-True -Name "Get-BotState normalizes empty execution next_action to null" `
            -Condition ($null -eq $state.instances.execution.next_action) `
            -Message "Expected execution next_action to be null after sanitization"

        $storedProc.status = "running"
        $storedProc.pid = 999999
        $storedProc | Add-Member -NotePropertyName failed_at -NotePropertyValue $null -Force
        $storedProc | Add-Member -NotePropertyName error -NotePropertyValue $null -Force
        $storedProc.heartbeat_status = "[38;2;56;52;44mIdle[0m"
        $storedProc.heartbeat_next_action = "[0m"
        $storedProc | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $listedProc = @((Get-ProcessList).processes | Where-Object { $_.id -eq $testProcId }) | Select-Object -First 1
        $rewrittenProc = Get-Content $testProcFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "dead PID rewrite persists sanitized heartbeat_status" `
            -Expected "Idle" `
            -Actual $rewrittenProc.heartbeat_status
        Assert-True -Name "dead PID rewrite persists null heartbeat_next_action" `
            -Condition ($null -eq $rewrittenProc.heartbeat_next_action) `
            -Message "Expected heartbeat_next_action to be null after dead PID rewrite"
        Assert-Equal -Name "dead PID rewrite returns stopped process" `
            -Expected "stopped" `
            -Actual $listedProc.status

        @(
            (@{
                timestamp = (Get-Date).ToUniversalTime().ToString("o")
                type = "text"
                message = "[38;2;56;52;44m[12:28:39][0m [38;2;112;104;92mGET[0m [kickstart]"
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $testActivityFile -Encoding utf8NoBOM

        $outputData = Get-ProcessOutput -ProcessId $testProcId -Position 0 -Tail 50
        Assert-Equal -Name "Get-ProcessOutput strips ANSI fragments from activity messages" `
            -Expected "[12:28:39] GET [kickstart]" `
            -Actual $outputData.events[0].message

        @(
            (@{
                timestamp = (Get-Date).ToUniversalTime().ToString("o")
                type = "text"
                message = "[38;2;56;52;44m[12:28:39][0m [38;2;112;104;92mGET[0m [kickstart]"
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $globalActivityFile -Encoding utf8NoBOM

        $activityTail = Get-ActivityTail -Position 0 -TailLines 50
        Assert-Equal -Name "Get-ActivityTail strips ANSI fragments from global activity messages" `
            -Expected "[12:28:39] GET [kickstart]" `
            -Actual $activityTail.events[0].message
    } finally {
        if (Test-Path $testProcFile) {
            Remove-Item $testProcFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $testActivityFile) {
            Remove-Item $testActivityFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $globalActivityFile) {
            Remove-Item $globalActivityFile -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-TestResult -Name "Process status sanitization test modules exist" -Status Fail -Message "One or more UI/process modules were not found in $botDir"
}

Write-Host ""

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
        $expectedTools = @('task_create', 'task_get_next', 'task_mark_in_progress', 'task_mark_done', 'task_list', 'task_get_stats', 'session_initialize', 'decision_create', 'decision_get', 'decision_list', 'decision_update', 'decision_mark_accepted', 'decision_mark_deprecated', 'decision_mark_superseded')
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
    # TASK TYPES
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK TYPES" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Create a script-type task
    $requestId++
    $scriptTaskResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Test Script Task'
                description = 'Run a PowerShell script'
                type        = 'script'
                script_path = 'scripts/test-script.ps1'
                priority    = 5
                effort      = 'XS'
            }
        }
    }

    if ($scriptTaskResponse -and $scriptTaskResponse.result) {
        $stText = $scriptTaskResponse.result.content[0].text
        $stObj = $stText | ConvertFrom-Json
        Assert-True -Name "task_create with type 'script' succeeds" `
            -Condition ($stObj.success -eq $true) `
            -Message "Failed: $stText"

        # Verify type and skip fields persist
        if ($stObj.file_path -and (Test-Path $stObj.file_path)) {
            $stContent = Get-Content $stObj.file_path -Raw | ConvertFrom-Json
            Assert-Equal -Name "script task type persists" -Expected "script" -Actual $stContent.type
            Assert-Equal -Name "script task script_path persists" -Expected "scripts/test-script.ps1" -Actual $stContent.script_path
            Assert-True -Name "script task skip_analysis defaults true" `
                -Condition ($stContent.skip_analysis -eq $true) `
                -Message "Expected skip_analysis=true, got $($stContent.skip_analysis)"
            Assert-True -Name "script task skip_worktree defaults true" `
                -Condition ($stContent.skip_worktree -eq $true) `
                -Message "Expected skip_worktree=true, got $($stContent.skip_worktree)"
        }
    } else {
        Assert-True -Name "task_create with type 'script' succeeds" `
            -Condition ($false) -Message "Error or no response"
    }

    # Create an mcp-type task
    $requestId++
    $mcpTaskResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Test MCP Task'
                description = 'Call an MCP tool'
                type        = 'mcp'
                mcp_tool    = 'bs_yaml_aggregate'
                priority    = 5
                effort      = 'XS'
            }
        }
    }

    if ($mcpTaskResponse -and $mcpTaskResponse.result) {
        $mtText = $mcpTaskResponse.result.content[0].text
        $mtObj = $mtText | ConvertFrom-Json
        Assert-True -Name "task_create with type 'mcp' succeeds" `
            -Condition ($mtObj.success -eq $true) `
            -Message "Failed: $mtText"

        if ($mtObj.file_path -and (Test-Path $mtObj.file_path)) {
            $mtContent = Get-Content $mtObj.file_path -Raw | ConvertFrom-Json
            Assert-Equal -Name "mcp task type persists" -Expected "mcp" -Actual $mtContent.type
            Assert-Equal -Name "mcp task mcp_tool persists" -Expected "bs_yaml_aggregate" -Actual $mtContent.mcp_tool
        }
    } else {
        Assert-True -Name "task_create with type 'mcp' succeeds" `
            -Condition ($false) -Message "Error or no response"
    }

    # Create a task_gen-type task
    $requestId++
    $tgTaskResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Test Task Gen'
                description = 'Generate more tasks'
                type        = 'task_gen'
                script_path = 'scripts/gen-tasks.ps1'
                priority    = 5
                effort      = 'XS'
            }
        }
    }

    if ($tgTaskResponse -and $tgTaskResponse.result) {
        $tgText = $tgTaskResponse.result.content[0].text
        $tgObj = $tgText | ConvertFrom-Json
        Assert-True -Name "task_create with type 'task_gen' succeeds" `
            -Condition ($tgObj.success -eq $true) `
            -Message "Failed: $tgText"

        if ($tgObj.file_path -and (Test-Path $tgObj.file_path)) {
            $tgContent = Get-Content $tgObj.file_path -Raw | ConvertFrom-Json
            Assert-Equal -Name "task_gen task type persists" -Expected "task_gen" -Actual $tgContent.type
        }
    } else {
        Assert-True -Name "task_create with type 'task_gen' succeeds" `
            -Condition ($false) -Message "Error or no response"
    }

    # Prompt task defaults: type='prompt', skip_analysis=false
    $requestId++
    $promptTaskResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Test Prompt Task'
                description = 'Default prompt task'
                priority    = 5
                effort      = 'XS'
            }
        }
    }

    if ($promptTaskResponse -and $promptTaskResponse.result) {
        $ptText = $promptTaskResponse.result.content[0].text
        $ptObj = $ptText | ConvertFrom-Json
        if ($ptObj.file_path -and (Test-Path $ptObj.file_path)) {
            $ptContent = Get-Content $ptObj.file_path -Raw | ConvertFrom-Json
            Assert-Equal -Name "prompt task type defaults to 'prompt'" -Expected "prompt" -Actual $ptContent.type
            Assert-True -Name "prompt task skip_analysis defaults false" `
                -Condition ($ptContent.skip_analysis -eq $false) `
                -Message "Expected skip_analysis=false, got $($ptContent.skip_analysis)"
        }
    }

    # Validation: script type without script_path should fail
    $requestId++
    $badScriptResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Bad Script Task'
                description = 'Missing script_path'
                type        = 'script'
            }
        }
    }

    Assert-True -Name "task_create rejects script type without script_path" `
        -Condition ($null -ne $badScriptResponse -and $null -ne $badScriptResponse.error) `
        -Message "Expected error for script type without script_path"

    # Validation: mcp type without mcp_tool should fail
    $requestId++
    $badMcpResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Bad MCP Task'
                description = 'Missing mcp_tool'
                type        = 'mcp'
            }
        }
    }

    Assert-True -Name "task_create rejects mcp type without mcp_tool" `
        -Condition ($null -ne $badMcpResponse -and $null -ne $badMcpResponse.error) `
        -Message "Expected error for mcp type without mcp_tool"

    # Validation: invalid type should fail
    $requestId++
    $badTypeResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Bad Type Task'
                description = 'Invalid type'
                type        = 'invalid_type'
            }
        }
    }

    Assert-True -Name "task_create rejects invalid type" `
        -Condition ($null -ne $badTypeResponse -and $null -ne $badTypeResponse.error) `
        -Message "Expected error for invalid type"

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
    # DECISION LIFECYCLE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  DECISION LIFECYCLE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Create a decision
    $requestId++
    $decCreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_create'
            arguments = @{
                title   = 'Use PowerShell for MCP Server'
                context = 'We need a language for the MCP server implementation'
                decision = 'Use PowerShell 7+ as the sole implementation language'
                type    = 'architecture'
                impact  = 'high'
                consequences = 'Limited to PowerShell ecosystem'
            }
        }
    }

    Assert-True -Name "decision_create responds" `
        -Condition ($null -ne $decCreateResponse) `
        -Message "No response"

    $decId = $null
    if ($decCreateResponse -and $decCreateResponse.result) {
        $decText = $decCreateResponse.result.content[0].text
        $decObj = $decText | ConvertFrom-Json
        Assert-True -Name "decision_create returns success" `
            -Condition ($decObj.success -eq $true) `
            -Message "success was not true: $decText"
        $decId = $decObj.decision_id
        Assert-True -Name "decision_create returns decision_id" `
            -Condition ($null -ne $decId -and $decId.Length -gt 0) `
            -Message "No decision_id in response"
    }

    # Verify decision file exists in proposed/
    if ($decId) {
        $proposedDir = Join-Path $botDir "workspace\decisions\proposed"
        $proposedFiles = Get-ChildItem -Path $proposedDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file created in proposed/" `
            -Condition ($proposedFiles.Count -gt 0) `
            -Message "No .json files found in proposed/"
    }

    # List decisions
    $requestId++
    $decListResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_list'
            arguments = @{}
        }
    }

    Assert-True -Name "decision_list responds" `
        -Condition ($null -ne $decListResponse) `
        -Message "No response"

    if ($decListResponse -and $decListResponse.result) {
        $decListText = $decListResponse.result.content[0].text
        $decListObj = $decListText | ConvertFrom-Json
        $decCount = if ($decListObj.decisions) { $decListObj.decisions.Count } else { 0 }
        Assert-True -Name "decision_list shows created decision" `
            -Condition ($decListObj.success -eq $true -and $decCount -gt 0) `
            -Message "No decisions found: $decListText"
    }

    # Get decision
    if ($decId) {
        $requestId++
        $decGetResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_get'
                arguments = @{ decision_id = $decId }
            }
        }

        Assert-True -Name "decision_get responds" `
            -Condition ($null -ne $decGetResponse) `
            -Message "No response"

        if ($decGetResponse -and $decGetResponse.result) {
            $decGetText = $decGetResponse.result.content[0].text
            $decGetObj = $decGetText | ConvertFrom-Json
            Assert-True -Name "decision_get returns success" `
                -Condition ($decGetObj.success -eq $true) `
                -Message "Failed: $decGetText"
            Assert-True -Name "decision_get returns correct title" `
                -Condition ($decGetObj.title -eq 'Use PowerShell for MCP Server') `
                -Message "Wrong title: $($decGetObj.title)"
        }
    }

    # Update decision
    if ($decId) {
        $requestId++
        $decUpdateResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_update'
                arguments = @{
                    decision_id = $decId
                    consequences = 'Limited to PowerShell ecosystem but mitigated by cross-platform pwsh'
                }
            }
        }

        Assert-True -Name "decision_update responds" `
            -Condition ($null -ne $decUpdateResponse) `
            -Message "No response"

        if ($decUpdateResponse -and $decUpdateResponse.result) {
            $decUpdateText = $decUpdateResponse.result.content[0].text
            $decUpdateObj = $decUpdateText | ConvertFrom-Json
            Assert-True -Name "decision_update succeeds" `
                -Condition ($decUpdateObj.success -eq $true) `
                -Message "Failed: $decUpdateText"
        }
    }

    # Mark accepted
    if ($decId) {
        $requestId++
        $decAcceptResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_mark_accepted'
                arguments = @{ decision_id = $decId }
            }
        }

        Assert-True -Name "decision_mark_accepted responds" `
            -Condition ($null -ne $decAcceptResponse) `
            -Message "No response"

        if ($decAcceptResponse -and $decAcceptResponse.result) {
            $decAcceptText = $decAcceptResponse.result.content[0].text
            $decAcceptObj = $decAcceptText | ConvertFrom-Json
            Assert-True -Name "decision_mark_accepted succeeds" `
                -Condition ($decAcceptObj.success -eq $true) `
                -Message "Failed: $decAcceptText"
        }

        # Verify file moved to accepted/
        $acceptedDir = Join-Path $botDir "workspace\decisions\accepted"
        $acceptedFiles = Get-ChildItem -Path $acceptedDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file moved to accepted/" `
            -Condition ($acceptedFiles.Count -gt 0) `
            -Message "No .json files found in accepted/"
    }

    # Create a second decision to test superseded
    $requestId++
    $dec2CreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_create'
            arguments = @{
                title    = 'Switch to TypeScript for MCP'
                context  = 'Performance concerns with PowerShell approach'
                decision = 'Migrate MCP server to TypeScript'
                status   = 'accepted'
            }
        }
    }

    $dec2Id = $null
    if ($dec2CreateResponse -and $dec2CreateResponse.result) {
        $dec2Text = $dec2CreateResponse.result.content[0].text
        $dec2Obj = $dec2Text | ConvertFrom-Json
        $dec2Id = $dec2Obj.decision_id
    }

    # Mark first decision as superseded by second
    if ($decId -and $dec2Id) {
        $requestId++
        $decSuperResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_mark_superseded'
                arguments = @{
                    decision_id   = $decId
                    superseded_by = $dec2Id
                }
            }
        }

        Assert-True -Name "decision_mark_superseded responds" `
            -Condition ($null -ne $decSuperResponse) `
            -Message "No response"

        if ($decSuperResponse -and $decSuperResponse.result) {
            $decSuperText = $decSuperResponse.result.content[0].text
            $decSuperObj = $decSuperText | ConvertFrom-Json
            Assert-True -Name "decision_mark_superseded succeeds" `
                -Condition ($decSuperObj.success -eq $true) `
                -Message "Failed: $decSuperText"
        }

        # Verify file moved to superseded/
        $supersededDir = Join-Path $botDir "workspace\decisions\superseded"
        $supersededFiles = Get-ChildItem -Path $supersededDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file moved to superseded/" `
            -Condition ($supersededFiles.Count -gt 0) `
            -Message "No .json files found in superseded/"
    }

    # Create a third decision to test deprecated
    $requestId++
    $dec3CreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_create'
            arguments = @{
                title    = 'Use Redis for Caching'
                context  = 'Need caching layer for performance'
                decision = 'Use Redis as the caching backend'
                status   = 'accepted'
            }
        }
    }

    $dec3Id = $null
    if ($dec3CreateResponse -and $dec3CreateResponse.result) {
        $dec3Text = $dec3CreateResponse.result.content[0].text
        $dec3Obj = $dec3Text | ConvertFrom-Json
        $dec3Id = $dec3Obj.decision_id
    }

    # Mark deprecated
    if ($dec3Id) {
        $requestId++
        $decDepResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_mark_deprecated'
                arguments = @{
                    decision_id = $dec3Id
                    reason = 'Caching no longer needed after architecture simplification'
                }
            }
        }

        Assert-True -Name "decision_mark_deprecated responds" `
            -Condition ($null -ne $decDepResponse) `
            -Message "No response"

        if ($decDepResponse -and $decDepResponse.result) {
            $decDepText = $decDepResponse.result.content[0].text
            $decDepObj = $decDepText | ConvertFrom-Json
            Assert-True -Name "decision_mark_deprecated succeeds" `
                -Condition ($decDepObj.success -eq $true) `
                -Message "Failed: $decDepText"
        }

        # Verify file moved to deprecated/
        $deprecatedDir = Join-Path $botDir "workspace\decisions\deprecated"
        $deprecatedFiles = Get-ChildItem -Path $deprecatedDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file moved to deprecated/" `
            -Condition ($deprecatedFiles.Count -gt 0) `
            -Message "No .json files found in deprecated/"
    }

    # List with status filter
    $requestId++
    $decListFilteredResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_list'
            arguments = @{ status = 'accepted' }
        }
    }

    Assert-True -Name "decision_list with status filter responds" `
        -Condition ($null -ne $decListFilteredResponse) `
        -Message "No response"

    if ($decListFilteredResponse -and $decListFilteredResponse.result) {
        $decFilterText = $decListFilteredResponse.result.content[0].text
        $decFilterObj = $decFilterText | ConvertFrom-Json
        Assert-True -Name "decision_list filters by status" `
            -Condition ($decFilterObj.success -eq $true) `
            -Message "Failed: $decFilterText"
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
$providerCliPath = Join-Path $dotbotDir "workflows\default\systems\runtime\ProviderCLI\ProviderCLI.psm1"
$providerCliLoaded = $false
try {
    Import-Module $providerCliPath -Force -ErrorAction Stop
    $providerCliLoaded = $true
} catch { Write-Verbose "Non-critical operation failed: $_" }

Assert-True -Name "ProviderCLI module loads" `
    -Condition $providerCliLoaded `
    -Message "Failed to import ProviderCLI.psm1"

if ($providerCliLoaded) {
    # Test Get-ProviderConfig for Claude (default)
    $claudeConfig = $null
    try { $claudeConfig = Get-ProviderConfig -Name "claude" } catch { Write-Verbose "Settings operation failed: $_" }
    Assert-True -Name "Get-ProviderConfig loads claude config" `
        -Condition ($null -ne $claudeConfig -and $claudeConfig.name -eq "claude") `
        -Message "Expected claude config"

    # Test Get-ProviderModels
    $models = $null
    try { $models = Get-ProviderModels -ProviderName "claude" } catch { Write-Verbose "Settings operation failed: $_" }
    Assert-True -Name "Get-ProviderModels returns Claude models" `
        -Condition ($null -ne $models -and $models.Count -ge 2) `
        -Message "Expected at least 2 models"

    # Test Resolve-ProviderModelId
    $resolvedId = $null
    try { $resolvedId = Resolve-ProviderModelId -ModelAlias "Opus" -ProviderName "claude" } catch { Write-Verbose "Non-critical operation failed: $_" }
    Assert-True -Name "Resolve-ProviderModelId maps Opus" `
        -Condition ($resolvedId -eq "opus") `
        -Message "Expected opus, got $resolvedId"

    # Test cross-provider model rejection
    $crossProviderError = $false
    try { Resolve-ProviderModelId -ModelAlias "Opus" -ProviderName "codex" } catch { $crossProviderError = $true }
    Assert-True -Name "Resolve-ProviderModelId rejects Opus for codex" `
        -Condition $crossProviderError `
        -Message "Should throw for invalid model alias"

    # Test New-ProviderSession for Claude (returns GUID)
    $claudeSession = $null
    try { $claudeSession = New-ProviderSession -ProviderName "claude" } catch { Write-Verbose "Session operation failed: $_" }
    Assert-True -Name "New-ProviderSession returns GUID for Claude" `
        -Condition ($null -ne $claudeSession -and $claudeSession -match '^[0-9a-f]{8}-') `
        -Message "Expected GUID, got $claudeSession"

    # Test New-ProviderSession for Codex (returns null)
    $codexSession = "not-null"
    try { $codexSession = New-ProviderSession -ProviderName "codex" } catch { Write-Verbose "Session operation failed: $_" }
    Assert-True -Name "New-ProviderSession returns null for Codex" `
        -Condition ($null -eq $codexSession) `
        -Message "Expected null, got $codexSession"

    # ─────────────────────────────────────────────
    # PERMISSION MODE TESTS
    # ─────────────────────────────────────────────

    Write-Host ""
    Write-Host "  PERMISSION MODE TESTS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Test provider config has permission_modes
    if ($claudeConfig) {
        Assert-True -Name "Claude config has permission_modes" `
            -Condition ($null -ne $claudeConfig.permission_modes) `
            -Message "Missing permission_modes on loaded config"

        Assert-True -Name "Claude config has default_permission_mode" `
            -Condition ($null -ne $claudeConfig.default_permission_mode) `
            -Message "Missing default_permission_mode"

        Assert-True -Name "Claude default_permission_mode is bypassPermissions" `
            -Condition ($claudeConfig.default_permission_mode -eq "bypassPermissions") `
            -Message "Expected bypassPermissions, got $($claudeConfig.default_permission_mode)"
    }

    # Test Build-ProviderCliArgs with default permission mode (no PermissionMode param)
    if ($claudeConfig) {
        $defaultArgs = $null
        try {
            $defaultArgs = Build-ProviderCliArgs -Config $claudeConfig -Prompt "test" -ModelId "opus" -Streaming $false
        } catch { Write-Verbose "Build args failed: $_" }
        Assert-True -Name "Build-ProviderCliArgs returns args without PermissionMode" `
            -Condition ($null -ne $defaultArgs -and $defaultArgs.Count -gt 0) `
            -Message "Expected non-empty args array"

        if ($defaultArgs) {
            $hasBypass = $defaultArgs -contains "--dangerously-skip-permissions"
            Assert-True -Name "Default permission mode uses --dangerously-skip-permissions" `
                -Condition $hasBypass `
                -Message "Expected --dangerously-skip-permissions in args: $($defaultArgs -join ' ')"
        }
    }

    # Test Build-ProviderCliArgs with explicit auto permission mode
    if ($claudeConfig) {
        $autoArgs = $null
        try {
            $autoArgs = Build-ProviderCliArgs -Config $claudeConfig -Prompt "test" -ModelId "opus" -Streaming $false -PermissionMode "auto"
        } catch { Write-Verbose "Build args failed: $_" }
        Assert-True -Name "Build-ProviderCliArgs returns args with auto mode" `
            -Condition ($null -ne $autoArgs -and $autoArgs.Count -gt 0) `
            -Message "Expected non-empty args array"

        if ($autoArgs) {
            $hasPermMode = ($autoArgs -contains "--permission-mode")
            $hasAuto = ($autoArgs -contains "auto")
            Assert-True -Name "Auto permission mode uses --permission-mode auto" `
                -Condition ($hasPermMode -and $hasAuto) `
                -Message "Expected --permission-mode auto in args: $($autoArgs -join ' ')"

            $noBypass = -not ($autoArgs -contains "--dangerously-skip-permissions")
            Assert-True -Name "Auto permission mode does not include bypass flag" `
                -Condition $noBypass `
                -Message "Should not contain --dangerously-skip-permissions with auto mode"
        }
    }

    # Test Build-ProviderCliArgs with explicit bypassPermissions mode
    if ($claudeConfig) {
        $bypassArgs = $null
        try {
            $bypassArgs = Build-ProviderCliArgs -Config $claudeConfig -Prompt "test" -ModelId "opus" -Streaming $false -PermissionMode "bypassPermissions"
        } catch { Write-Verbose "Build args failed: $_" }

        if ($bypassArgs) {
            $hasBypass = $bypassArgs -contains "--dangerously-skip-permissions"
            Assert-True -Name "bypassPermissions mode uses --dangerously-skip-permissions" `
                -Condition $hasBypass `
                -Message "Expected bypass flag in args: $($bypassArgs -join ' ')"
        }
    }

    # Test Build-ProviderCliArgs for Codex with full-auto mode
    $codexConfig = $null
    try { $codexConfig = Get-ProviderConfig -Name "codex" } catch { Write-Verbose "Config load failed: $_" }
    if ($codexConfig -and $codexConfig.permission_modes) {
        $codexAutoArgs = $null
        try {
            $codexAutoArgs = Build-ProviderCliArgs -Config $codexConfig -Prompt "test" -ModelId "gpt-5.4" -Streaming $false -PermissionMode "full-auto"
        } catch { Write-Verbose "Build args failed: $_" }

        if ($codexAutoArgs) {
            $hasFullAuto = $codexAutoArgs -contains "--full-auto"
            Assert-True -Name "Codex full-auto mode uses --full-auto" `
                -Condition $hasFullAuto `
                -Message "Expected --full-auto in args: $($codexAutoArgs -join ' ')"
        }
    }

    # Test Build-ProviderCliArgs for Gemini with auto_edit mode
    $geminiConfig = $null
    try { $geminiConfig = Get-ProviderConfig -Name "gemini" } catch { Write-Verbose "Config load failed: $_" }
    if ($geminiConfig -and $geminiConfig.permission_modes) {
        $geminiEditArgs = $null
        try {
            $geminiEditArgs = Build-ProviderCliArgs -Config $geminiConfig -Prompt "test" -ModelId "gemini-3-pro-preview" -Streaming $false -PermissionMode "auto_edit"
        } catch { Write-Verbose "Build args failed: $_" }

        if ($geminiEditArgs) {
            $hasApproval = $geminiEditArgs -contains "--approval-mode"
            $hasAutoEdit = $geminiEditArgs -contains "auto_edit"
            Assert-True -Name "Gemini auto_edit mode uses --approval-mode auto_edit" `
                -Condition ($hasApproval -and $hasAutoEdit) `
                -Message "Expected --approval-mode auto_edit in args: $($geminiEditArgs -join ' ')"
        }
    }

    # Test backwards compat: config without permission_modes falls back to cli_args.permissions_bypass
    $fallbackConfig = @{
        name = "test-provider"
        executable = "test"
        cli_args = @{
            model = "--model"
            permissions_bypass = "--legacy-bypass-flag"
        }
    } | ConvertTo-Json -Depth 5 | ConvertFrom-Json

    $fallbackArgs = $null
    try {
        $fallbackArgs = Build-ProviderCliArgs -Config $fallbackConfig -Prompt "test" -ModelId "test" -Streaming $false
    } catch { Write-Verbose "Build args failed: $_" }

    if ($fallbackArgs) {
        $hasLegacy = $fallbackArgs -contains "--legacy-bypass-flag"
        Assert-True -Name "Config without permission_modes falls back to cli_args.permissions_bypass" `
            -Condition $hasLegacy `
            -Message "Expected --legacy-bypass-flag in args: $($fallbackArgs -join ' ')"
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# NOTIFICATION CLIENT MODULE TESTS
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- NotificationClient Module ---" -ForegroundColor Cyan

$notifModule = Join-Path $botDir "systems\mcp\modules\NotificationClient.psm1"

if (Test-Path $notifModule) {
    Import-Module $notifModule -Force

    # Test Get-NotificationSettings returns defaults when disabled
    $settings = Get-NotificationSettings -BotRoot $botDir
    Assert-True -Name "Get-NotificationSettings returns disabled by default" `
        -Condition ($settings.enabled -eq $false) `
        -Message "Expected enabled=false, got $($settings.enabled)"

    Assert-True -Name "Get-NotificationSettings returns default channel" `
        -Condition ($settings.channel -eq "teams") `
        -Message "Expected channel=teams, got $($settings.channel)"

    Assert-True -Name "Get-NotificationSettings returns default poll interval" `
        -Condition ($settings.poll_interval_seconds -eq 30) `
        -Message "Expected 30, got $($settings.poll_interval_seconds)"


    $parsedNotifGuid = [guid]::Empty
    Assert-True -Name "Get-NotificationSettings includes workspace instance_id" `
        -Condition ([guid]::TryParse("$($settings.instance_id)", [ref]$parsedNotifGuid)) `
        -Message "Expected settings.instance_id to be a valid GUID"
    # Test Test-NotificationServer returns false when no server configured
    $reachable = Test-NotificationServer -Settings $settings
    Assert-True -Name "Test-NotificationServer returns false when no URL" `
        -Condition ($reachable -eq $false) `
        -Message "Expected false with no server URL"

    # Test Send-TaskNotification no-ops when disabled
    $mockTask = [PSCustomObject]@{ id = "test123"; name = "Test task" }
    $mockQuestion = [PSCustomObject]@{
        id = "q1"
        question = "Which database?"
        context = "We need a DB"
        options = @(
            [PSCustomObject]@{ key = "A"; label = "PostgreSQL"; rationale = "Mature" },
            [PSCustomObject]@{ key = "B"; label = "SQLite"; rationale = "Simple" }
        )
        recommendation = "A"
    }
    $sendResult = Send-TaskNotification -TaskContent $mockTask -PendingQuestion $mockQuestion -Settings $settings
    Assert-True -Name "Send-TaskNotification returns not-configured when disabled" `
        -Condition ($sendResult.success -eq $false) `
        -Message "Expected success=false"

    # Test Get-TaskNotificationResponse returns null when disabled
    $mockNotification = [PSCustomObject]@{ question_id = "q1"; instance_id = "inst1" }
    $pollResult = Get-TaskNotificationResponse -Notification $mockNotification -Settings $settings
    Assert-True -Name "Get-TaskNotificationResponse returns null when disabled" `
        -Condition ($null -eq $pollResult) `
        -Message "Expected null"
} else {
    Write-TestResult -Name "NotificationClient module exists" -Status Fail -Message "Module not found at $notifModule"
}

# ═══════════════════════════════════════════════════════════════════
# NOTIFICATION POLLER MODULE TESTS
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- NotificationPoller Module ---" -ForegroundColor Cyan

$pollerModule = Join-Path $botDir "systems\ui\modules\NotificationPoller.psm1"

if (Test-Path $pollerModule) {
    Import-Module $pollerModule -Force

    # Test Initialize-NotificationPoller does not throw when disabled
    $pollerError = $false
    try {
        Initialize-NotificationPoller -BotRoot $botDir
    } catch {
        $pollerError = $true
    }
    Assert-True -Name "Initialize-NotificationPoller no-op when disabled" `
        -Condition (-not $pollerError) `
        -Message "Should not throw when notifications disabled"

    # Test Invoke-NotificationPollTick does not throw with empty needs-input
    $pollTickError = $false
    try {
        Invoke-NotificationPollTick
    } catch {
        $pollTickError = $true
    }
    Assert-True -Name "Invoke-NotificationPollTick no-op when no tasks" `
        -Condition (-not $pollTickError) `
        -Message "Should not throw with empty needs-input"
} else {
    Write-TestResult -Name "NotificationPoller module exists" -Status Fail -Message "Module not found at $pollerModule"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# kickstart-via-jira PROFILE: TOOL REGISTRATION & CATEGORIES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  kickstart-via-jira TOOL REGISTRATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$kickstartViaJiraProfile = Join-Path $dotbotDir "workflows\kickstart-via-jira"
if (Test-Path $kickstartViaJiraProfile) {
    $mrTestProject = New-TestProject
    $mrBotDir = Join-Path $mrTestProject ".bot"

    Push-Location $mrTestProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-jira 2>&1 | Out-Null
    & git add -A 2>&1 | Out-Null
    & git commit -m "dotbot init kickstart-via-jira" --quiet 2>&1 | Out-Null
    Pop-Location

    # Strip verify config to only include scripts that actually exist in the test project
    $mrVerifyConfig = Join-Path $mrBotDir "hooks\verify\config.json"
    if (Test-Path $mrVerifyConfig) {
        try {
            $vc = Get-Content $mrVerifyConfig -Raw | ConvertFrom-Json
            $vd = Join-Path $mrBotDir "hooks\verify"
            $existing = @()
            foreach ($s in $vc.scripts) {
                if (Test-Path (Join-Path $vd $s.name)) { $existing += $s }
            }
            $vc.scripts = $existing
            $vc | ConvertTo-Json -Depth 5 | Set-Content -Path $mrVerifyConfig -Encoding UTF8
        } catch { Write-Verbose "Failed to parse data: $_" }
    }

    $mrMcpProcess = $null
    $mrRequestId = 0

    try {
        $mrMcpProcess = Start-McpServer -BotDir $mrBotDir
        Assert-True -Name "kickstart-via-jira MCP server starts" `
            -Condition (-not $mrMcpProcess.HasExited) `
            -Message "Server process exited immediately"

        $mrInitResponse = Send-McpInitialize -Process $mrMcpProcess
        Assert-True -Name "kickstart-via-jira MCP initialize responds" `
            -Condition ($null -ne $mrInitResponse) `
            -Message "No response"

        # List tools
        $mrRequestId++
        $mrListResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/list'
            params  = @{}
        }

        Assert-True -Name "kickstart-via-jira tools/list responds" `
            -Condition ($null -ne $mrListResponse) `
            -Message "No response"

        if ($mrListResponse -and $mrListResponse.result) {
            $mrToolNames = $mrListResponse.result.tools | ForEach-Object { $_.name }

            # Check the 3 new tools are registered
            foreach ($toolName in @('repo_clone', 'repo_list', 'research_status')) {
                Assert-True -Name "kickstart-via-jira tool '$toolName' registered" `
                    -Condition ($toolName -in $mrToolNames) `
                    -Message "Tool not found in tools/list"
            }

            # Check inputSchema is present for each new tool
            foreach ($toolName in @('repo_clone', 'repo_list', 'research_status')) {
                $toolDef = $mrListResponse.result.tools | Where-Object { $_.name -eq $toolName }
                Assert-True -Name "kickstart-via-jira tool '$toolName' has inputSchema" `
                    -Condition ($null -ne $toolDef.inputSchema) `
                    -Message "inputSchema missing"
            }
        }

        Write-Host ""
        Write-Host "  kickstart-via-jira CATEGORIES" -ForegroundColor Cyan
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

        # Test task_create with kickstart-via-jira category "research"
        $mrRequestId++
        $researchResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'Test Research Task'
                    description = 'Integration test for research category'
                    category    = 'research'
                    priority    = 10
                    effort      = 'S'
                }
            }
        }

        if ($researchResponse -and $researchResponse.result) {
            $researchText = $researchResponse.result.content[0].text
            $researchObj = $researchText | ConvertFrom-Json
            Assert-True -Name "task_create with category 'research' succeeds" `
                -Condition ($researchObj.success -eq $true) `
                -Message "Failed: $researchText"
        } else {
            Assert-True -Name "task_create with category 'research' succeeds" `
                -Condition ($false) `
                -Message "Error or no response: $($researchResponse | ConvertTo-Json -Compress -Depth 3)"
        }

        # Test task_create with kickstart-via-jira category "analysis"
        $mrRequestId++
        $analysisResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'Test Analysis Task'
                    description = 'Integration test for analysis category'
                    category    = 'analysis'
                    priority    = 10
                    effort      = 'S'
                }
            }
        }

        if ($analysisResponse -and $analysisResponse.result) {
            $analysisText = $analysisResponse.result.content[0].text
            $analysisObj = $analysisText | ConvertFrom-Json
            Assert-True -Name "task_create with category 'analysis' succeeds" `
                -Condition ($analysisObj.success -eq $true) `
                -Message "Failed: $analysisText"
        } else {
            Assert-True -Name "task_create with category 'analysis' succeeds" `
                -Condition ($false) `
                -Message "Error or no response: $($analysisResponse | ConvertTo-Json -Compress -Depth 3)"
        }

        # Test task_create with working_dir → field persists in task JSON
        $mrRequestId++
        $wdResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'Test Working Dir Task'
                    description = 'Integration test for working_dir field'
                    category    = 'research'
                    priority    = 10
                    effort      = 'S'
                    working_dir = 'repos/FakeRepo'
                }
            }
        }

        if ($wdResponse -and $wdResponse.result) {
            $wdText = $wdResponse.result.content[0].text
            $wdObj = $wdText | ConvertFrom-Json
            Assert-True -Name "task_create with working_dir succeeds" `
                -Condition ($wdObj.success -eq $true) `
                -Message "Failed: $wdText"

            # Read the task file to verify working_dir persists
            if ($wdObj.file_path -and (Test-Path $wdObj.file_path)) {
                $taskContent = Get-Content $wdObj.file_path -Raw | ConvertFrom-Json
                Assert-Equal -Name "working_dir persists in task JSON" `
                    -Expected "repos/FakeRepo" `
                    -Actual $taskContent.working_dir
            }
        } else {
            Assert-True -Name "task_create with working_dir succeeds" `
                -Condition ($false) `
                -Message "Error or no response"
        }

    } catch {
        Write-TestResult -Name "kickstart-via-jira MCP tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
    } finally {
        if ($mrMcpProcess) {
            Stop-McpServer -Process $mrMcpProcess
        }
        Remove-TestProject -Path $mrTestProject
    }
} else {
    Write-TestResult -Name "kickstart-via-jira tool registration" -Status Skip -Message "kickstart-via-jira profile not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# kickstart-via-pr PROFILE: TOOL REGISTRATION & DIRECT TOOL TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  kickstart-via-pr TOOL REGISTRATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$kickstartViaPrProfile = Join-Path $dotbotDir "workflows\kickstart-via-pr"
Assert-PathExists -Name "kickstart-via-pr profile source exists" -Path $kickstartViaPrProfile
if (Test-Path $kickstartViaPrProfile) {
    $prTestProject = New-TestProject
    $prBotDir = Join-Path $prTestProject ".bot"

    Push-Location $prTestProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-pr 2>&1 | Out-Null
    & git add -A 2>&1 | Out-Null
    & git commit -m "dotbot init kickstart-via-pr" --quiet 2>&1 | Out-Null
    Pop-Location

    $prVerifyConfig = Join-Path $prBotDir "hooks\verify\config.json"
    if (Test-Path $prVerifyConfig) {
        try {
            $vc = Get-Content $prVerifyConfig -Raw | ConvertFrom-Json
            $vd = Join-Path $prBotDir "hooks\verify"
            $existing = @()
            foreach ($s in $vc.scripts) {
                if (Test-Path (Join-Path $vd $s)) { $existing += $s }
            }
            $vc.scripts = $existing
            $vc | ConvertTo-Json -Depth 5 | Set-Content -Path $prVerifyConfig -Encoding UTF8
        } catch { Write-Verbose "Failed to parse data: $_" }
    }

    $prMcpProcess = $null
    $prRequestId = 0

    try {
        $prMcpProcess = Start-McpServer -BotDir $prBotDir
        Assert-True -Name "kickstart-via-pr MCP server starts" `
            -Condition (-not $prMcpProcess.HasExited) `
            -Message "Server process exited immediately"

        $prInitResponse = Send-McpInitialize -Process $prMcpProcess
        Assert-True -Name "kickstart-via-pr MCP initialize responds" `
            -Condition ($null -ne $prInitResponse) `
            -Message "No response"

        $prRequestId++
        $prListResponse = Send-McpRequest -Process $prMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $prRequestId
            method  = 'tools/list'
            params  = @{}
        }

        Assert-True -Name "kickstart-via-pr tools/list responds" `
            -Condition ($null -ne $prListResponse) `
            -Message "No response"

        if ($prListResponse -and $prListResponse.result) {
            $prToolNames = $prListResponse.result.tools | ForEach-Object { $_.name }
            Assert-True -Name "kickstart-via-pr tool 'pr_context' registered" `
                -Condition ('pr_context' -in $prToolNames) `
                -Message "Tool not found in tools/list"

            $prToolDef = $prListResponse.result.tools | Where-Object { $_.name -eq 'pr_context' }
            Assert-True -Name "kickstart-via-pr tool 'pr_context' has inputSchema" `
                -Condition ($null -ne $prToolDef.inputSchema) `
                -Message "inputSchema missing"
        }

        $prRequestId++
        $analysisResponse = Send-McpRequest -Process $prMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $prRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'PR Analysis Task'
                    description = 'Integration test for kickstart-via-pr analysis category'
                    category    = 'analysis'
                    priority    = 10
                    effort      = 'S'
                }
            }
        }

        if ($analysisResponse -and $analysisResponse.result) {
            $analysisText = $analysisResponse.result.content[0].text
            $analysisObj = $analysisText | ConvertFrom-Json
            Assert-True -Name "kickstart-via-pr task_create with category 'analysis' succeeds" `
                -Condition ($analysisObj.success -eq $true) `
                -Message "Failed: $analysisText"
        } else {
            Assert-True -Name "kickstart-via-pr task_create with category 'analysis' succeeds" `
                -Condition ($false) `
                -Message "Error or no response"
        }
    } catch {
        Write-TestResult -Name "kickstart-via-pr MCP tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
    } finally {
        if ($prMcpProcess) {
            Stop-McpServer -Process $prMcpProcess
        }
        Remove-TestProject -Path $prTestProject
    }

    Write-Host ""
    Write-Host "  kickstart-via-pr DIRECT TOOL TESTS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $prContextScript = Join-Path $kickstartViaPrProfile "systems\mcp\tools\pr-context\script.ps1"
    if (Test-Path $prContextScript) {
        . $prContextScript

        $directTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-pr-context-" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $directTestRoot -ItemType Directory -Force | Out-Null
        $global:DotbotProjectRoot = $directTestRoot
        Set-Content -Path (Join-Path $directTestRoot ".env.local") -Value "AZURE_DEVOPS_PAT=test-pat`nGITHUB_TOKEN=test-gh" -Encoding UTF8

        $savedGithubToken = $env:GITHUB_TOKEN
        $savedGhToken = $env:GH_TOKEN
        $savedAdoPat = $env:AZURE_DEVOPS_PAT

        try {
            $githubResult = & {
                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/pulls/42') {
                        return [pscustomobject]@{
                            number = 42
                            title = 'Add billing validation'
                            body = "Implements billing validation.`n`nFixes #123"
                            html_url = 'https://github.com/acme/widgets/pull/42'
                            state = 'open'
                            user = [pscustomobject]@{ login = 'octocat' }
                            head = [pscustomobject]@{ ref = 'feature/billing-validation' }
                            base = [pscustomobject]@{ ref = 'main' }
                        }
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/pulls/42/files?per_page=100&page=1') {
                        $pageFiles = [System.Collections.ArrayList]::new()
                        for ($index = 1; $index -le 100; $index++) {
                            [void]$pageFiles.Add([pscustomobject]@{
                                filename = ('src/File{0:D3}.cs' -f $index)
                                status = 'modified'
                            })
                        }

                        return @($pageFiles)
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/pulls/42/files?per_page=100&page=2') {
                        return @(
                            [pscustomobject]@{ filename = 'docs/billing.md'; status = 'modified' }
                        )
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/issues/123') {
                        return [pscustomobject]@{
                            number = 123
                            title = 'Billing validation rules'
                            state = 'open'
                            html_url = 'https://github.com/acme/widgets/issues/123'
                        }
                    }

                    throw "Unexpected GitHub URI: $Uri"
                }

                Invoke-PrContext -Arguments @{ pr_url = 'https://github.com/acme/widgets/pull/42' }
            }

            Assert-Equal -Name "Invoke-PrContext GitHub URL: provider" -Expected 'github' -Actual $githubResult.provider
            Assert-Equal -Name "Invoke-PrContext GitHub URL: title" -Expected 'Add billing validation' -Actual $githubResult.title
            Assert-Equal -Name "Invoke-PrContext GitHub URL: linked issue count" -Expected 1 -Actual @($githubResult.linked_issues).Count
            Assert-Equal -Name "Invoke-PrContext GitHub URL: changed file count" -Expected 101 -Actual @($githubResult.changed_files).Count
            Assert-Equal -Name "Invoke-PrContext GitHub URL: first changed file path" -Expected 'src/File001.cs' -Actual $githubResult.changed_files[0].path
            Assert-Equal -Name "Invoke-PrContext GitHub URL: paginated file path included" -Expected 'docs/billing.md' -Actual $githubResult.changed_files[100].path

            $githubAutoResult = & {
                function git {
                    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                    $joined = $Arguments -join ' '
                    switch ($joined) {
                        'remote get-url origin' { return 'https://github.com/acme/service.api.git' }
                        'branch --show-current' { return 'feature/billing-validation' }
                        default { throw "Unexpected git invocation: $joined" }
                    }
                }

                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -like 'https://api.github.com/repos/acme/service.api/pulls?*head=acme:feature/billing-validation*state=open*') {
                        return @(
                            [pscustomobject]@{
                                number = 77
                                title = 'Auto-detected PR'
                                body = 'Detect current branch PR'
                                html_url = 'https://github.com/acme/service.api/pull/77'
                                state = 'open'
                                user = [pscustomobject]@{ login = 'octocat' }
                                head = [pscustomobject]@{ ref = 'feature/billing-validation' }
                                base = [pscustomobject]@{ ref = 'main' }
                            }
                        )
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/service.api/pulls/77/files?per_page=100&page=1') {
                        return @([pscustomobject]@{ filename = 'src/AutoDetected.cs'; status = 'modified' })
                    }

                    throw "Unexpected GitHub auto-detect URI: $Uri"
                }

                Invoke-PrContext -Arguments @{}
            }

            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: URL" -Expected 'https://github.com/acme/service.api/pull/77' -Actual $githubAutoResult.pr_url
            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: source branch" -Expected 'feature/billing-validation' -Actual $githubAutoResult.source_branch
            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: repository" -Expected 'acme/service.api' -Actual $githubAutoResult.repository
            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: changed file count" -Expected 1 -Actual @($githubAutoResult.changed_files).Count

            $githubCrossRepoIssues = & {
                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -eq 'https://api.github.com/repos/other-org/other-repo/issues/456') {
                        return [pscustomobject]@{
                            number = 456
                            title = 'Cross-repo issue'
                            state = 'open'
                            html_url = 'https://github.com/other-org/other-repo/issues/456'
                        }
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/issues/123') {
                        return [pscustomobject]@{
                            number = 123
                            title = 'Local repo issue'
                            state = 'open'
                            html_url = 'https://github.com/acme/widgets/issues/123'
                        }
                    }

                    throw "Unexpected GitHub linked issue URI: $Uri"
                }

                Get-GitHubLinkedIssues -Owner 'acme' -Repo 'widgets' -Texts @('See other-org/other-repo#456 and #123')
            }

            Assert-Equal -Name "Get-GitHubLinkedIssues cross-repo count" -Expected 2 -Actual @($githubCrossRepoIssues).Count
            Assert-Equal -Name "Get-GitHubLinkedIssues cross-repo first key" -Expected 'other-org/other-repo#456' -Actual $githubCrossRepoIssues[0].key
            Assert-Equal -Name "Get-GitHubLinkedIssues cross-repo second key" -Expected '#123' -Actual $githubCrossRepoIssues[1].key

            $adoResult = & {
                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99?api-version=7.1') {
                        return [pscustomobject]@{
                            pullRequestId = 99
                            title = 'Storefront tax alignment'
                            description = 'Align tax calculation with PRD.'
                            status = 'active'
                            createdBy = [pscustomobject]@{ displayName = 'Ada Lovelace' }
                            sourceRefName = 'refs/heads/feature/tax-alignment'
                            targetRefName = 'refs/heads/main'
                            repository = [pscustomobject]@{
                                name = 'Storefront'
                                webUrl = 'https://dev.azure.com/contoso/Commerce/_git/Storefront'
                            }
                            url = 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99'
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/workitems?api-version=7.1') {
                        return [pscustomobject]@{
                            value = @(
                                [pscustomobject]@{ id = '456'; url = 'https://dev.azure.com/contoso/Commerce/_apis/wit/workItems/456' }
                            )
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/wit/workItems/456?api-version=7.1') {
                        return [pscustomobject]@{
                            id = 456
                            fields = [pscustomobject]@{
                                'System.Title' = 'Tax rules rollout'
                                'System.State' = 'Active'
                                'System.WorkItemType' = 'User Story'
                            }
                            _links = [pscustomobject]@{
                                html = [pscustomobject]@{ href = 'https://dev.azure.com/contoso/Commerce/_workitems/edit/456' }
                            }
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/iterations?api-version=7.1') {
                        return [pscustomobject]@{
                            value = @(
                                [pscustomobject]@{ id = 1 },
                                [pscustomobject]@{ id = 3 }
                            )
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/iterations/3/changes?$compareTo=0&$top=2000&$skip=0&api-version=7.1') {
                        return [pscustomobject]@{
                            changeEntries = @(
                                [pscustomobject]@{
                                    changeType = 'edit'
                                    item = [pscustomobject]@{ path = '/src/TaxService.cs' }
                                },
                                [pscustomobject]@{
                                    changeType = 'add'
                                    item = [pscustomobject]@{ path = '/tests/TaxServiceTests.cs' }
                                }
                            )
                            nextSkip = 2
                            nextTop = 2000
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/iterations/3/changes?$compareTo=0&$top=2000&$skip=2&api-version=7.1') {
                        return [pscustomobject]@{
                            changeEntries = @(
                                [pscustomobject]@{
                                    changeType = 'rename'
                                    item = [pscustomobject]@{ path = '/docs/TaxGuide.md' }
                                }
                            )
                            nextSkip = 0
                            nextTop = 0
                        }
                    }

                    throw "Unexpected ADO URI: $Uri"
                }

                Invoke-PrContext -Arguments @{ pr_url = 'https://dev.azure.com/contoso/Commerce/_git/Storefront/pullrequest/99?path=/src/TaxService.cs&_a=overview' }
            }

            Assert-Equal -Name "Invoke-PrContext ADO URL: provider" -Expected 'azure-devops' -Actual $adoResult.provider
            Assert-Equal -Name "Invoke-PrContext ADO URL: title" -Expected 'Storefront tax alignment' -Actual $adoResult.title
            Assert-Equal -Name "Invoke-PrContext ADO URL: resolved URL" -Expected 'https://dev.azure.com/contoso/Commerce/_git/Storefront/pullrequest/99?path=/src/TaxService.cs&_a=overview' -Actual $adoResult.pr_url
            Assert-Equal -Name "Invoke-PrContext ADO URL: linked issue count" -Expected 1 -Actual @($adoResult.linked_issues).Count
            Assert-Equal -Name "Invoke-PrContext ADO URL: changed file count" -Expected 3 -Actual @($adoResult.changed_files).Count
            Assert-Equal -Name "Invoke-PrContext ADO URL: first changed file path" -Expected '/src/TaxService.cs' -Actual $adoResult.changed_files[0].path
            Assert-Equal -Name "Invoke-PrContext ADO URL: cumulative change path included" -Expected '/docs/TaxGuide.md' -Actual $adoResult.changed_files[2].path

            $gitHubRemoteInfo = Convert-RemoteToGitHubInfo -RemoteUrl 'https://github.com/acme/service.api.git'
            Assert-Equal -Name "Convert-RemoteToGitHubInfo accepts dotted repo names" -Expected 'service.api' -Actual $gitHubRemoteInfo.repo

            $adoRemoteInfo = Convert-RemoteToAdoInfo -RemoteUrl 'https://dev.azure.com/contoso/Commerce/_git/Storefront.Core.git'
            Assert-Equal -Name "Convert-RemoteToAdoInfo accepts dotted repo names" -Expected 'Storefront.Core' -Actual $adoRemoteInfo.repo
        } finally {
            $env:GITHUB_TOKEN = $savedGithubToken
            $env:GH_TOKEN = $savedGhToken
            $env:AZURE_DEVOPS_PAT = $savedAdoPat
            if (Test-Path $directTestRoot) {
                Remove-Item $directTestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-TestResult -Name "kickstart-via-pr direct tool tests" -Status Fail -Message "Tool script not found at $prContextScript"
    }
} else {
    Write-TestResult -Name "kickstart-via-pr tool registration" -Status Skip -Message "kickstart-via-pr profile not found"
}

Write-Host ""
Write-Host "  PRODUCT API DIRECT TESTS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$repoRoot = Split-Path $PSScriptRoot -Parent
$productApiModule = Join-Path $repoRoot "workflows\default\systems\ui\modules\ProductAPI.psm1"
if (Test-Path $productApiModule) {
    Import-Module $productApiModule -Force

    $productApiTestProject = New-TestProject
    try {
        $productBotRoot = Join-Path $productApiTestProject ".bot"
        $productDir = Join-Path $productBotRoot "workspace\product"
        $briefingDir = Join-Path $productDir "briefing"
        $controlDir = Join-Path $productBotRoot ".control"

        New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null

        Set-Content -Path (Join-Path $productDir "mission.md") -Value "# Mission" -Encoding UTF8
        Set-Content -Path (Join-Path $productDir "roadmap-overview.md") -Value "# Roadmap" -Encoding UTF8
        Set-Content -Path (Join-Path $productDir "interview-summary.md") -Value "# Interview Summary" -Encoding UTF8
        Set-Content -Path (Join-Path $briefingDir "pr-context.md") -Value "# Pull Request Context" -Encoding UTF8
        # JSON files for type/resolution tests
        Set-Content -Path (Join-Path $productDir "config.json") -Value '{"key":"value"}' -Encoding UTF8
        Set-Content -Path (Join-Path $productDir "mission.json") -Value '{"title":"Mission JSON"}' -Encoding UTF8
        # Binary file for type/size tests
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "logo.png"), [byte[]](0x89, 0x50, 0x4E, 0x47))
        # .gitkeep should be excluded
        Set-Content -Path (Join-Path $briefingDir ".gitkeep") -Value "" -Encoding UTF8

        Initialize-ProductAPI -BotRoot $productBotRoot -ControlDir $controlDir

        $docs = @((Get-ProductList).docs)
        Assert-Equal -Name "ProductAPI lists nested product docs" `
            -Expected 7 `
            -Actual $docs.Count
        Assert-Equal -Name "ProductAPI keeps mission first in priority order" `
            -Expected "mission" `
            -Actual $docs[0].name
        Assert-True -Name "ProductAPI includes briefing/pr-context in list" `
            -Condition ($docs.name -contains "briefing/pr-context") `
            -Message "Nested briefing document missing from product list"
        Assert-True -Name "ProductAPI surfaces relative filename for briefing docs" `
            -Condition ($docs.filename -contains "briefing/pr-context.md") `
            -Message "Expected relative filename briefing/pr-context.md"

        $briefingDoc = Get-ProductDocument -Name "briefing/pr-context"
        Assert-True -Name "ProductAPI loads nested briefing doc by relative name" `
            -Condition ($briefingDoc.success -eq $true -and $briefingDoc.content -match 'Pull Request Context') `
            -Message "Nested briefing doc could not be loaded"

        $encodedBriefingDoc = Get-ProductDocument -Name "briefing%2Fpr-context"
        Assert-True -Name "ProductAPI loads nested briefing doc by encoded route name" `
            -Condition ($encodedBriefingDoc.success -eq $true -and $encodedBriefingDoc.name -eq 'briefing/pr-context') `
            -Message "Encoded nested route name did not resolve"

        $traversalDoc = Get-ProductDocument -Name "../secrets"
        Assert-True -Name "ProductAPI blocks path traversal outside workspace/product" `
            -Condition ($traversalDoc.success -eq $false -and $traversalDoc._statusCode -eq 404) `
            -Message "Path traversal should return not found"

        # Metadata field tests (type, size, depth)
        $logoPng = $docs | Where-Object { $_.name -eq 'logo.png' }
        Assert-True -Name "ProductAPI includes binary files in list" `
            -Condition ($null -ne $logoPng) `
            -Message "Binary file logo.png missing from product list"
        Assert-Equal -Name "ProductAPI returns type=binary for non-md files" `
            -Expected "binary" `
            -Actual $logoPng.type
        Assert-True -Name "ProductAPI returns size field for binary files" `
            -Condition ($logoPng.size -gt 0) `
            -Message "Expected non-zero size for logo.png"
        Assert-Equal -Name "ProductAPI returns depth=0 for root files" `
            -Expected 0 `
            -Actual $logoPng.depth
        $missionDoc = $docs | Where-Object { $_.name -eq 'mission' }
        Assert-Equal -Name "ProductAPI returns type=md for markdown files" `
            -Expected "md" `
            -Actual $missionDoc.type
        $briefingPrContext = $docs | Where-Object { $_.name -eq 'briefing/pr-context' }
        Assert-Equal -Name "ProductAPI returns depth=1 for nested files" `
            -Expected 1 `
            -Actual $briefingPrContext.depth
        Assert-True -Name "ProductAPI excludes .gitkeep files" `
            -Condition (-not ($docs.filename -contains 'briefing/.gitkeep')) `
            -Message ".gitkeep should be excluded from product list"

        # JSON document support tests
        $configJson = $docs | Where-Object { $_.name -eq 'config.json' }
        Assert-True -Name "ProductAPI includes JSON files in list" `
            -Condition ($null -ne $configJson) `
            -Message "JSON file config.json missing from product list"
        Assert-Equal -Name "ProductAPI returns type=json for JSON files" `
            -Expected "json" `
            -Actual $configJson.type
        Assert-Equal -Name "ProductAPI retains .json extension in name" `
            -Expected "config.json" `
            -Actual $configJson.name

        $jsonDoc = Get-ProductDocument -Name "config.json"
        Assert-True -Name "ProductAPI loads JSON doc by name" `
            -Condition ($jsonDoc.success -eq $true -and $jsonDoc.content -match 'key') `
            -Message "JSON doc config.json could not be loaded"

        # .md takes priority over .json when both exist (mission.md + mission.json)
        $missionResolved = Get-ProductDocument -Name "mission"
        Assert-True -Name "ProductAPI resolves .md over .json when both exist" `
            -Condition ($missionResolved.success -eq $true -and $missionResolved.content -match 'Mission') `
            -Message "Expected mission.md content when requesting by base name"

        # Explicit .json route loads JSON even when .md exists
        $missionJsonDoc = Get-ProductDocument -Name "mission.json"
        Assert-True -Name "ProductAPI loads explicit .json route when .md also exists" `
            -Condition ($missionJsonDoc.success -eq $true -and $missionJsonDoc.content -match 'Mission JSON') `
            -Message "Expected mission.json content when requested explicitly"
    } finally {
        Remove-TestProject -Path $productApiTestProject
        Remove-Module ProductAPI -ErrorAction SilentlyContinue
    }
} else {
    Write-TestResult -Name "ProductAPI direct tests" -Status Skip -Message "Module not found at $productApiModule"
}
# ═══════════════════════════════════════════════════════════════════
# DOTBOTLOG MODULE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  DOTBOTLOG MODULE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$dotBotLogModule = Join-Path $dotbotDir "workflows\default\systems\runtime\modules\DotBotLog.psm1"
if (Test-Path $dotBotLogModule) {
    # Use a dedicated temp directory for DotBotLog tests
    $logTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-log-test-$([guid]::NewGuid().ToString().Substring(0,6))"
    $logTestControlDir = Join-Path $logTestDir ".control"
    $logTestLogsDir = Join-Path $logTestControlDir "logs"
    $logTestProcessesDir = Join-Path $logTestControlDir "processes"
    New-Item -Path $logTestProcessesDir -ItemType Directory -Force | Out-Null

    try {
        # Import module fresh
        Import-Module $dotBotLogModule -Force -DisableNameChecking

        # Test 1: Initialize-DotBotLog creates logs directory
        Initialize-DotBotLog -LogDir $logTestLogsDir -ControlDir $logTestControlDir -ProjectRoot $logTestDir
        Assert-True -Name "DotBotLog: Initialize creates logs directory" `
            -Condition (Test-Path $logTestLogsDir) `
            -Message "Logs directory not created at $logTestLogsDir"

        # Test 2: Write-BotLog writes JSONL to log file
        Write-BotLog -Level Info -Message "Test log entry"
        $dateStamp = Get-Date -Format 'yyyy-MM-dd'
        $logFile = Join-Path $logTestLogsDir "dotbot-$dateStamp.jsonl"
        Assert-True -Name "DotBotLog: Write-BotLog creates log file" `
            -Condition (Test-Path $logFile) `
            -Message "Log file not created at $logFile"

        # Test 3: Log file contains valid JSONL with correct schema
        $logLines = @(Get-Content $logFile)
        $lastLine = $logLines[-1] | ConvertFrom-Json
        $hasRequiredFields = ($null -ne $lastLine.ts) -and ($lastLine.level -eq 'Info') -and ($lastLine.msg -eq 'Test log entry') -and ($null -ne $lastLine.pid)
        Assert-True -Name "DotBotLog: JSONL entry has correct schema (ts, level, msg, pid)" `
            -Condition $hasRequiredFields `
            -Message "Missing fields. Got: $($logLines[-1])"

        # Test 4: Level filtering — Debug below file_level=Warn should not write
        Initialize-DotBotLog -LogDir $logTestLogsDir -ControlDir $logTestControlDir -ProjectRoot $logTestDir -FileLevel Warn -ConsoleEnabled $false
        $lineCountBefore = (Get-Content $logFile).Count
        Write-BotLog -Level Debug -Message "Should be filtered out"
        $lineCountAfter = (Get-Content $logFile).Count
        Assert-True -Name "DotBotLog: Debug filtered when FileLevel=Warn" `
            -Condition ($lineCountAfter -eq $lineCountBefore) `
            -Message "Expected $lineCountBefore lines, got $lineCountAfter"

        # Test 5: Activity.jsonl integration — Info+ events go to activity.jsonl
        Initialize-DotBotLog -LogDir $logTestLogsDir -ControlDir $logTestControlDir -ProjectRoot $logTestDir -ConsoleEnabled $false
        Write-BotLog -Level Info -Message "Activity test"
        $activityFile = Join-Path $logTestControlDir "activity.jsonl"
        Assert-True -Name "DotBotLog: Info writes to activity.jsonl" `
            -Condition (Test-Path $activityFile) `
            -Message "activity.jsonl not created"

        if (Test-Path $activityFile) {
            $actLines = Get-Content $activityFile
            $actEntry = $actLines[-1] | ConvertFrom-Json
            $actOk = ($null -ne $actEntry.timestamp) -and ($actEntry.type -eq 'info') -and ($actEntry.message -eq 'Activity test')
            Assert-True -Name "DotBotLog: activity.jsonl entry has correct schema" `
                -Condition $actOk `
                -Message "Bad activity entry: $($actLines[-1])"
        }

        # Test 6: Per-process activity log
        $testProcId = "proc-test01"
        $env:DOTBOT_PROCESS_ID = $testProcId
        Write-BotLog -Level Info -Message "Process activity test"
        $procLogFile = Join-Path $logTestProcessesDir "$testProcId.activity.jsonl"
        Assert-True -Name "DotBotLog: Per-process activity log created" `
            -Condition (Test-Path $procLogFile) `
            -Message "Process activity log not created at $procLogFile"
        $env:DOTBOT_PROCESS_ID = $null

        # Test 7: Exception logging populates error and stack fields
        try { throw "Test exception for logging" } catch { $testException = $_ }
        Write-BotLog -Level Error -Message "Exception test" -Exception $testException
        $logLines = @(Get-Content $logFile)
        $errEntry = $logLines[-1] | ConvertFrom-Json
        Assert-True -Name "DotBotLog: Exception populates error field" `
            -Condition ($errEntry.error -eq 'Test exception for logging') `
            -Message "Error field: $($errEntry.error)"

        # Test 8: Rotate-DotBotLog removes old files
        $oldLogFile = Join-Path $logTestLogsDir "dotbot-2020-01-01.jsonl"
        "old log entry" | Set-Content $oldLogFile
        (Get-Item $oldLogFile).LastWriteTime = (Get-Date).AddDays(-30)
        Rotate-DotBotLog
        Assert-True -Name "DotBotLog: Rotation removes old log files" `
            -Condition (-not (Test-Path $oldLogFile)) `
            -Message "Old log file still exists"

        # Test 9: Write-Diag delegates to Write-BotLog (Debug level)
        $lineCountBefore = (Get-Content $logFile).Count
        Write-Diag "Diag test message"
        $lineCountAfter = (Get-Content $logFile).Count
        Assert-True -Name "DotBotLog: Write-Diag writes to log file" `
            -Condition ($lineCountAfter -gt $lineCountBefore) `
            -Message "Write-Diag did not produce a log entry"

        if ($lineCountAfter -gt $lineCountBefore) {
            $diagEntry = @(Get-Content $logFile)[-1] | ConvertFrom-Json
            Assert-True -Name "DotBotLog: Write-Diag uses Debug level" `
                -Condition ($diagEntry.level -eq 'Debug') `
                -Message "Expected Debug level, got $($diagEntry.level)"
        }

        # Test 10: Correlation ID included in log entries
        $env:DOTBOT_CORRELATION_ID = "corr-test1234"
        Write-BotLog -Level Info -Message "Correlation test"
        $corrEntry = @(Get-Content $logFile)[-1] | ConvertFrom-Json
        Assert-True -Name "DotBotLog: Correlation ID included in log entry" `
            -Condition ($corrEntry.correlation_id -eq 'corr-test1234') `
            -Message "Expected corr-test1234, got $($corrEntry.correlation_id)"
        $env:DOTBOT_CORRELATION_ID = $null

    } finally {
        # Cleanup
        Remove-Module DotBotLog -ErrorAction SilentlyContinue
        $env:DOTBOT_PROCESS_ID = $null
        $env:DOTBOT_CORRELATION_ID = $null
        if (Test-Path $logTestDir) { Remove-Item $logTestDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-TestResult -Name "DotBotLog module tests" -Status Skip -Message "Module not found at $dotBotLogModule"
}

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
