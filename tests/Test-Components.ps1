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

# Commit any framework file changes made by the tests above (e.g. config.json
# stripping, settings backfill) so the integrity gate sees a clean state.
Push-Location $testProject
$manifestModule = Join-Path $botDir "systems\mcp\modules\FrameworkIntegrity.psm1"
if (Test-Path $manifestModule) {
    Import-Module $manifestModule -Force
    $frameworkPaths = Get-FrameworkProtectedPaths
    # Manifest.psm1 is a sibling of FrameworkIntegrity.psm1 in both source and target.
    $manifestMod = Join-Path (Split-Path $manifestModule) "Manifest.psm1"
    if (Test-Path $manifestMod) {
        Import-Module $manifestMod -Force
        $null = New-DotbotManifest -ProjectRoot $testProject -ProtectedPaths $frameworkPaths -Generator 'test-setup'
    }
}
& git add -A 2>&1 | Out-Null
$env:DOTBOT_FORCE_COMMIT = "1"
& git commit -m "test: sync framework state" --quiet 2>&1 | Out-Null
$env:DOTBOT_FORCE_COMMIT = $null
Pop-Location

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

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK_GET_NEXT
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK_GET_NEXT" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Create a fresh task for get_next tests
    $requestId++
    $gnCreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'GetNext Test Task'
                description = 'Task for testing task_get_next'
                category    = 'feature'
                priority    = 5
                effort      = 'S'
            }
        }
    }
    $gnTaskId = $null
    if ($gnCreateResponse -and $gnCreateResponse.result) {
        $gnObj = $gnCreateResponse.result.content[0].text | ConvertFrom-Json
        $gnTaskId = $gnObj.task_id
    }

    Assert-True -Name "task_create for get_next test succeeds" `
        -Condition ($null -ne $gnTaskId) `
        -Message "Failed to create test task for get_next tests"

    # task_get_next returns a todo task
    $requestId++
    $getNextResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_get_next'
            arguments = @{ prefer_analysed = $false }
        }
    }

    $getNextObj = $null
    if ($getNextResponse -and $getNextResponse.result) {
        $getNextObj = $getNextResponse.result.content[0].text | ConvertFrom-Json
    }
    Assert-True -Name "task_get_next returns a todo task" `
        -Condition ($null -ne $getNextObj -and $getNextObj.success -eq $true -and $null -ne $getNextObj.task) `
        -Message "Expected success with a task"

    # task_get_next prefers analysed over todo (default)
    $requestId++
    $gnAnalysedCreate = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Analysed Priority Task'
                description = 'Should be preferred by get_next'
                category    = 'feature'
                priority    = 1
                effort      = 'S'
            }
        }
    }
    $gnAnalysedTaskId = $null
    if ($gnAnalysedCreate -and $gnAnalysedCreate.result) {
        $gnAnalysedTaskId = ($gnAnalysedCreate.result.content[0].text | ConvertFrom-Json).task_id
    }

    if ($gnAnalysedTaskId) {
        $requestId++
        Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysing'
                arguments = @{ task_id = $gnAnalysedTaskId }
            }
        } | Out-Null

        $requestId++
        Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysed'
                arguments = @{
                    task_id  = $gnAnalysedTaskId
                    analysis = @{ summary = 'Test analysis'; files = @() }
                }
            }
        } | Out-Null

        $requestId++
        $preferAnalysedResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_get_next'
                arguments = @{}
            }
        }

        $preferAnalysedObj = $null
        if ($preferAnalysedResponse -and $preferAnalysedResponse.result) {
            $preferAnalysedObj = $preferAnalysedResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_get_next prefers analysed tasks (default)" `
            -Condition ($null -ne $preferAnalysedObj -and $preferAnalysedObj.task.id -eq $gnAnalysedTaskId) `
            -Message "Expected analysed task $gnAnalysedTaskId, got: $($preferAnalysedObj.task.id)"

        # task_get_next with prefer_analysed=false returns todo task
        $requestId++
        $todoOnlyResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_get_next'
                arguments = @{ prefer_analysed = $false }
            }
        }

        $todoOnlyObj = $null
        if ($todoOnlyResponse -and $todoOnlyResponse.result) {
            $todoOnlyObj = $todoOnlyResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_get_next with prefer_analysed=false returns todo task" `
            -Condition ($null -ne $todoOnlyObj -and $null -ne $todoOnlyObj.task -and $todoOnlyObj.task.id -ne $gnAnalysedTaskId) `
            -Message "Expected a todo task (not $gnAnalysedTaskId)"
    }

    # task_get_next returns highest priority task
    $requestId++
    $highPrioCreate = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'High Priority Task'
                description = 'Priority 1 should come first'
                category    = 'feature'
                priority    = 1
                effort      = 'S'
            }
        }
    }
    $highPrioId = $null
    if ($highPrioCreate -and $highPrioCreate.result) {
        $highPrioId = ($highPrioCreate.result.content[0].text | ConvertFrom-Json).task_id
    }

    $requestId++
    $prioNextResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_get_next'
            arguments = @{ prefer_analysed = $false }
        }
    }

    $prioNextObj = $null
    if ($prioNextResponse -and $prioNextResponse.result) {
        $prioNextObj = $prioNextResponse.result.content[0].text | ConvertFrom-Json
    }
    Assert-True -Name "task_get_next returns highest priority task first" `
        -Condition ($null -ne $prioNextObj -and $null -ne $prioNextObj.task -and $prioNextObj.task.id -eq $highPrioId -and $prioNextObj.task.priority -eq 1) `
        -Message "Expected task $highPrioId with priority=1, got task $($prioNextObj.task.id) with priority=$($prioNextObj.task.priority)"

    # task_get_next returns null when queue is empty
    $requestId++
    $allTasksResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_list'
            arguments = @{}
        }
    }
    if ($allTasksResponse -and $allTasksResponse.result) {
        $allTasksObj = $allTasksResponse.result.content[0].text | ConvertFrom-Json
        if ($allTasksObj.tasks) {
            foreach ($t in $allTasksObj.tasks) {
                if ($t.status -eq 'todo' -or $t.status -eq 'analysed') {
                    if ($t.status -eq 'todo') {
                        $requestId++
                        Send-McpRequest -Process $mcpProcess -Request @{
                            jsonrpc = '2.0'; id = $requestId; method = 'tools/call'
                            params = @{ name = 'task_mark_in_progress'; arguments = @{ task_id = $t.id } }
                        } | Out-Null
                    }
                    if ($t.status -eq 'analysed') {
                        $requestId++
                        Send-McpRequest -Process $mcpProcess -Request @{
                            jsonrpc = '2.0'; id = $requestId; method = 'tools/call'
                            params = @{ name = 'task_mark_in_progress'; arguments = @{ task_id = $t.id } }
                        } | Out-Null
                    }
                    $requestId++
                    Send-McpRequest -Process $mcpProcess -Request @{
                        jsonrpc = '2.0'; id = $requestId; method = 'tools/call'
                        params = @{ name = 'task_mark_done'; arguments = @{ task_id = $t.id } }
                    } | Out-Null
                }
            }
        }
    }

    $requestId++
    $emptyQueueResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_get_next'
            arguments = @{ prefer_analysed = $false }
        }
    }

    $emptyQueueObj = $null
    if ($emptyQueueResponse -and $emptyQueueResponse.result) {
        $emptyQueueObj = $emptyQueueResponse.result.content[0].text | ConvertFrom-Json
    }
    Assert-True -Name "task_get_next returns null when all remaining tasks are terminal" `
        -Condition ($null -ne $emptyQueueObj -and $emptyQueueObj.success -eq $true -and $null -eq $emptyQueueObj.task) `
        -Message "Expected success with null task when no non-terminal tasks remain"

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK_MARK_ANALYSING
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK_MARK_ANALYSING" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $requestId++
    $maCreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name        = 'Analysing Test Task'
                description = 'Task for testing mark_analysing'
                category    = 'feature'
                priority    = 5
                effort      = 'S'
            }
        }
    }
    $maTaskId = $null
    if ($maCreateResponse -and $maCreateResponse.result) {
        $maTaskId = ($maCreateResponse.result.content[0].text | ConvertFrom-Json).task_id
    }

    # task_mark_analysing transitions todo → analysing
    if ($maTaskId) {
        $requestId++
        $analysingResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysing'
                arguments = @{ task_id = $maTaskId }
            }
        }

        $analysingObj = $null
        if ($analysingResponse -and $analysingResponse.result) {
            $analysingObj = $analysingResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_mark_analysing transitions todo to analysing" `
            -Condition ($null -ne $analysingObj -and $analysingObj.success -eq $true -and $analysingObj.new_status -eq 'analysing') `
            -Message "Expected new_status=analysing, got: $($analysingObj.new_status)"

        # task_mark_analysing sets analysis_started_at
        Assert-True -Name "task_mark_analysing sets analysis_started_at" `
            -Condition ($null -ne $analysingObj -and $null -ne $analysingObj.analysis_started_at) `
            -Message "Expected analysis_started_at timestamp"

        # task_mark_analysing is idempotent
        $requestId++
        $idempotentResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysing'
                arguments = @{ task_id = $maTaskId }
            }
        }

        $idempotentObj = $null
        if ($idempotentResponse -and $idempotentResponse.result) {
            $idempotentObj = $idempotentResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_mark_analysing is idempotent (already analysing)" `
            -Condition ($null -ne $idempotentObj -and $idempotentObj.success -eq $true -and $idempotentObj.message -like '*already*') `
            -Message "Expected success with already-in-state message"
    }

    # task_mark_analysing rejects missing task_id
    $requestId++
    $noIdResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_mark_analysing'
            arguments = @{}
        }
    }
    Assert-True -Name "task_mark_analysing rejects missing task_id" `
        -Condition ($null -ne $noIdResponse -and $null -ne $noIdResponse.error) `
        -Message "Expected error for missing task_id"

    # task_mark_analysing rejects non-existent task
    $requestId++
    $fakeIdResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_mark_analysing'
            arguments = @{ task_id = 'non-existent-task-id-12345' }
        }
    }
    Assert-True -Name "task_mark_analysing rejects non-existent task" `
        -Condition ($null -ne $fakeIdResponse -and $null -ne $fakeIdResponse.error) `
        -Message "Expected error for non-existent task"

    # task_mark_analysing rejects task in done state
    $requestId++
    $doneForReject = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{ name = 'Done Task For Reject'; description = 'Will be moved to done'; category = 'feature'; priority = 10; effort = 'XS' }
        }
    }
    $doneRejectId = $null
    if ($doneForReject -and $doneForReject.result) { $doneRejectId = ($doneForReject.result.content[0].text | ConvertFrom-Json).task_id }

    if ($doneRejectId) {
        $requestId++
        Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_mark_in_progress'; arguments = @{ task_id = $doneRejectId } } } | Out-Null
        $requestId++
        Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_mark_done'; arguments = @{ task_id = $doneRejectId } } } | Out-Null

        $requestId++
        $doneAnalysingResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysing'
                arguments = @{ task_id = $doneRejectId }
            }
        }
        Assert-True -Name "task_mark_analysing rejects task in done state" `
            -Condition ($null -ne $doneAnalysingResponse -and $null -ne $doneAnalysingResponse.error) `
            -Message "Expected error for done task"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK_MARK_ANALYSED
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK_MARK_ANALYSED" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # task_mark_analysed transitions analysing → analysed
    if ($maTaskId) {
        $requestId++
        $analysedResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysed'
                arguments = @{
                    task_id  = $maTaskId
                    analysis = @{
                        summary        = 'Test analysis summary'
                        files          = @('src/main.ps1', 'src/utils.ps1')
                        entities       = @('TaskStore', 'MCP Server')
                        implementation = @{ approach = 'Modify existing module'; risks = @('Breaking change to API') }
                    }
                }
            }
        }

        $analysedObj = $null
        if ($analysedResponse -and $analysedResponse.result) {
            $analysedObj = $analysedResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_mark_analysed transitions analysing to analysed" `
            -Condition ($null -ne $analysedObj -and $analysedObj.success -eq $true -and $analysedObj.new_status -eq 'analysed') `
            -Message "Expected new_status=analysed, got: $($analysedObj.new_status)"

        # task_mark_analysed stores analysis data
        if ($analysedObj -and $analysedObj.file_path -and (Test-Path $analysedObj.file_path)) {
            $analysedContent = Get-Content $analysedObj.file_path -Raw | ConvertFrom-Json
            Assert-True -Name "task_mark_analysed stores analysis data" `
                -Condition ($null -ne $analysedContent.analysis -and $analysedContent.analysis.summary -eq 'Test analysis summary') `
                -Message "Expected analysis.summary='Test analysis summary'"
        } else {
            Write-TestResult -Name "task_mark_analysed stores analysis data" -Status Fail -Message "Task file not found"
        }

        # task_mark_analysed sets timestamps
        Assert-True -Name "task_mark_analysed sets analysis_completed_at" `
            -Condition ($null -ne $analysedObj -and $null -ne $analysedObj.analysis_completed_at) `
            -Message "Expected analysis_completed_at timestamp"

        # task_mark_analysed is idempotent (re-analyse updates data)
        $requestId++
        $reanalysedResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysed'
                arguments = @{
                    task_id  = $maTaskId
                    analysis = @{ summary = 'Updated analysis summary'; files = @('src/updated.ps1') }
                }
            }
        }

        $reanalysedObj = $null
        if ($reanalysedResponse -and $reanalysedResponse.result) {
            $reanalysedObj = $reanalysedResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_mark_analysed is idempotent (re-analyse updates data)" `
            -Condition ($null -ne $reanalysedObj -and $reanalysedObj.success -eq $true) `
            -Message "Expected success on re-analyse"

        if ($reanalysedObj -and $reanalysedObj.file_path -and (Test-Path $reanalysedObj.file_path)) {
            $updatedContent = Get-Content $reanalysedObj.file_path -Raw | ConvertFrom-Json
            Assert-True -Name "task_mark_analysed re-analyse updates analysis content" `
                -Condition ($updatedContent.analysis.summary -eq 'Updated analysis summary') `
                -Message "Expected updated summary, got: $($updatedContent.analysis.summary)"
        }
    }

    # task_mark_analysed rejects missing task_id
    $requestId++
    $noIdAnalysedResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_mark_analysed'
            arguments = @{ analysis = @{ summary = 'No task id' } }
        }
    }
    Assert-True -Name "task_mark_analysed rejects missing task_id" `
        -Condition ($null -ne $noIdAnalysedResponse -and $null -ne $noIdAnalysedResponse.error) `
        -Message "Expected error for missing task_id"

    # task_mark_analysed rejects missing analysis data
    $requestId++
    $noAnalysisResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_mark_analysed'
            arguments = @{ task_id = $maTaskId }
        }
    }
    Assert-True -Name "task_mark_analysed rejects missing analysis data" `
        -Condition ($null -ne $noAnalysisResponse -and $null -ne $noAnalysisResponse.error) `
        -Message "Expected error for missing analysis"

    # task_mark_analysed rejects task in todo state
    $requestId++
    $todoForAnalysedReject = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{ name = 'Todo Task For Analysed Reject'; description = 'Should not be markable as analysed'; category = 'feature'; priority = 10; effort = 'XS' }
        }
    }
    $todoForAnalysedId = $null
    if ($todoForAnalysedReject -and $todoForAnalysedReject.result) {
        $todoForAnalysedId = ($todoForAnalysedReject.result.content[0].text | ConvertFrom-Json).task_id
    }

    if ($todoForAnalysedId) {
        $requestId++
        $todoAnalysedResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_mark_analysed'
                arguments = @{ task_id = $todoForAnalysedId; analysis = @{ summary = 'Should fail' } }
            }
        }
        Assert-True -Name "task_mark_analysed rejects task in todo state" `
            -Condition ($null -ne $todoAnalysedResponse -and $null -ne $todoAnalysedResponse.error) `
            -Message "Expected error for todo task"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # TASK_GET_CONTEXT
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  TASK_GET_CONTEXT" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # task_get_context returns context for analysed task
    if ($maTaskId) {
        $requestId++
        $contextResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_get_context'
                arguments = @{ task_id = $maTaskId }
            }
        }

        $contextObj = $null
        if ($contextResponse -and $contextResponse.result) {
            $contextObj = $contextResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_get_context returns context for analysed task" `
            -Condition ($null -ne $contextObj -and $contextObj.success -eq $true -and $contextObj.has_analysis -eq $true) `
            -Message "Expected success with has_analysis=true"

        # task_get_context includes task fields
        Assert-True -Name "task_get_context includes task fields" `
            -Condition ($null -ne $contextObj -and $null -ne $contextObj.task -and $null -ne $contextObj.task.name -and $null -ne $contextObj.task.description) `
            -Message "Expected task.name and task.description in context"
    }

    # task_get_context returns minimal context without analysis
    $requestId++
    $noAnalysisCreate = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{ name = 'No Analysis Context Task'; description = 'Task without analysis'; category = 'feature'; priority = 5; effort = 'S' }
        }
    }
    $noAnalysisTaskId = $null
    if ($noAnalysisCreate -and $noAnalysisCreate.result) {
        $noAnalysisTaskId = ($noAnalysisCreate.result.content[0].text | ConvertFrom-Json).task_id
    }

    if ($noAnalysisTaskId) {
        $requestId++
        Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'; id = $requestId; method = 'tools/call'
            params = @{ name = 'task_mark_in_progress'; arguments = @{ task_id = $noAnalysisTaskId } }
        } | Out-Null

        $requestId++
        $minimalContextResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_get_context'
                arguments = @{ task_id = $noAnalysisTaskId }
            }
        }

        $minimalContextObj = $null
        if ($minimalContextResponse -and $minimalContextResponse.result) {
            $minimalContextObj = $minimalContextResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_get_context returns minimal context without analysis" `
            -Condition ($null -ne $minimalContextObj -and $minimalContextObj.success -eq $true -and $minimalContextObj.has_analysis -eq $false) `
            -Message "Expected has_analysis=false for task without analysis"
    }

    # task_get_context works for in-progress task
    if ($maTaskId) {
        $requestId++
        Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'; id = $requestId; method = 'tools/call'
            params = @{ name = 'task_mark_in_progress'; arguments = @{ task_id = $maTaskId } }
        } | Out-Null

        $requestId++
        $ipContextResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_get_context'
                arguments = @{ task_id = $maTaskId }
            }
        }

        $ipContextObj = $null
        if ($ipContextResponse -and $ipContextResponse.result) {
            $ipContextObj = $ipContextResponse.result.content[0].text | ConvertFrom-Json
        }
        Assert-True -Name "task_get_context works for in-progress task" `
            -Condition ($null -ne $ipContextObj -and $ipContextObj.success -eq $true -and $ipContextObj.status -eq 'in-progress') `
            -Message "Expected success with status=in-progress"
    }

    # task_get_context rejects missing task_id
    $requestId++
    $noIdContextResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_get_context'
            arguments = @{}
        }
    }
    Assert-True -Name "task_get_context rejects missing task_id" `
        -Condition ($null -ne $noIdContextResponse -and $null -ne $noIdContextResponse.error) `
        -Message "Expected error for missing task_id"

    # task_get_context rejects task not in analysed/in-progress
    if ($todoForAnalysedId) {
        $requestId++
        $todoContextResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_get_context'
                arguments = @{ task_id = $todoForAnalysedId }
            }
        }
        Assert-True -Name "task_get_context rejects task in todo state" `
            -Condition ($null -ne $todoContextResponse -and $null -ne $todoContextResponse.error) `
            -Message "Expected error for todo task"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # FULL WORKFLOW LIFECYCLE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  FULL WORKFLOW LIFECYCLE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # End-to-end autonomous lifecycle
    $requestId++
    $e2eCreate = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'task_create'
            arguments = @{
                name = 'E2E Lifecycle Task'
                description = 'Full workflow: create > get_next > analysing > analysed > get_context > in_progress > done'
                category = 'feature'; priority = 1; effort = 'M'
                acceptance_criteria = @('Criterion 1', 'Criterion 2')
                steps = @('Step 1', 'Step 2', 'Step 3')
            }
        }
    }
    $e2eTaskId = $null
    $e2ePassed = $true
    $e2eFailReason = ""

    if ($e2eCreate -and $e2eCreate.result) { $e2eTaskId = ($e2eCreate.result.content[0].text | ConvertFrom-Json).task_id }
    if (-not $e2eTaskId) { $e2ePassed = $false; $e2eFailReason = "Create failed" }

    if ($e2ePassed) {
        $requestId++
        $e2eNext = Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_get_next'; arguments = @{ prefer_analysed = $false } } }
        $e2eNextObj = $null
        if ($e2eNext -and $e2eNext.result) { $e2eNextObj = $e2eNext.result.content[0].text | ConvertFrom-Json }
        if (-not $e2eNextObj -or -not $e2eNextObj.task) { $e2ePassed = $false; $e2eFailReason = "get_next returned no task" }
        elseif ($e2eNextObj.task.id -ne $e2eTaskId) { $e2ePassed = $false; $e2eFailReason = "get_next returned unexpected task $($e2eNextObj.task.id), expected $e2eTaskId" }
    }

    if ($e2ePassed) {
        $requestId++
        $e2eAnalysing = Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_mark_analysing'; arguments = @{ task_id = $e2eTaskId } } }
        $e2eAnalysingObj = $null
        if ($e2eAnalysing -and $e2eAnalysing.result) { $e2eAnalysingObj = $e2eAnalysing.result.content[0].text | ConvertFrom-Json }
        if (-not $e2eAnalysingObj -or $e2eAnalysingObj.new_status -ne 'analysing') { $e2ePassed = $false; $e2eFailReason = "mark_analysing failed" }
    }

    if ($e2ePassed) {
        $requestId++
        $e2eAnalysed = Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_mark_analysed'; arguments = @{ task_id = $e2eTaskId; analysis = @{ summary = 'E2E analysis'; files = @('src/app.ps1'); entities = @('AppModule') } } } }
        $e2eAnalysedObj = $null
        if ($e2eAnalysed -and $e2eAnalysed.result) { $e2eAnalysedObj = $e2eAnalysed.result.content[0].text | ConvertFrom-Json }
        if (-not $e2eAnalysedObj -or $e2eAnalysedObj.new_status -ne 'analysed') { $e2ePassed = $false; $e2eFailReason = "mark_analysed failed" }
    }

    if ($e2ePassed) {
        $requestId++
        $e2eContext = Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_get_context'; arguments = @{ task_id = $e2eTaskId } } }
        $e2eContextObj = $null
        if ($e2eContext -and $e2eContext.result) { $e2eContextObj = $e2eContext.result.content[0].text | ConvertFrom-Json }
        if (-not $e2eContextObj -or $e2eContextObj.has_analysis -ne $true) { $e2ePassed = $false; $e2eFailReason = "get_context failed or missing analysis" }
    }

    if ($e2ePassed) {
        $requestId++
        $e2eProgress = Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_mark_in_progress'; arguments = @{ task_id = $e2eTaskId } } }
        $e2eProgressObj = $null
        if ($e2eProgress -and $e2eProgress.result) { $e2eProgressObj = $e2eProgress.result.content[0].text | ConvertFrom-Json }
        if (-not $e2eProgressObj -or $e2eProgressObj.success -ne $true) { $e2ePassed = $false; $e2eFailReason = "mark_in_progress failed" }
    }

    if ($e2ePassed) {
        $requestId++
        $e2eDone = Send-McpRequest -Process $mcpProcess -Request @{ jsonrpc = '2.0'; id = $requestId; method = 'tools/call'; params = @{ name = 'task_mark_done'; arguments = @{ task_id = $e2eTaskId } } }
        $e2eDoneObj = $null
        if ($e2eDone -and $e2eDone.result) { $e2eDoneObj = $e2eDone.result.content[0].text | ConvertFrom-Json }
        if (-not $e2eDoneObj -or $e2eDoneObj.success -ne $true) { $e2ePassed = $false; $e2eFailReason = "mark_done failed" }
    }

    Assert-True -Name "Full lifecycle: create > get_next > analysing > analysed > get_context > in_progress > done" `
        -Condition $e2ePassed `
        -Message "Lifecycle failed at: $e2eFailReason"

    Write-Host ""

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

    # ── Send-SplitProposalNotification tests ─────────────────────────
    $mockSplitTask = [PSCustomObject]@{ id = "split-test-1"; name = "Refactor auth" }
    $mockSplitProposal = [PSCustomObject]@{
        reason = "Task is too large"
        proposed_at = "2026-01-15T10:00:00Z"
        sub_tasks = @(
            [PSCustomObject]@{ name = "Extract middleware"; effort = "S"; description = "Pull out auth middleware" },
            [PSCustomObject]@{ name = "Add token rotation"; effort = "M"; description = "Implement refresh tokens" }
        )
    }

    $splitResult = Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $mockSplitProposal -Settings $settings
    Assert-True -Name "Send-SplitProposalNotification returns not-configured when disabled" `
        -Condition ($splitResult.success -eq $false) `
        -Message "Expected success=false, got $($splitResult.success)"

    # Test empty sub_tasks guard
    $emptySplitProposal = [PSCustomObject]@{
        reason = "Should fail"
        proposed_at = "2026-01-15T10:00:00Z"
        sub_tasks = @()
    }
    $emptyResult = Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $emptySplitProposal -Settings $settings
    Assert-True -Name "Send-SplitProposalNotification rejects empty sub_tasks" `
        -Condition ($emptyResult.success -eq $false -and $emptyResult.reason -match "no sub-tasks") `
        -Message "Expected failure with 'no sub-tasks' reason, got: $($emptyResult.reason)"

    # Test missing proposed_at guard
    $noPropAtProposal = [PSCustomObject]@{
        reason = "Should fail"
        sub_tasks = @(
            [PSCustomObject]@{ name = "Some task"; effort = "S" }
        )
    }
    $noPropAtResult = Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $noPropAtProposal -Settings $settings
    Assert-True -Name "Send-SplitProposalNotification rejects missing proposed_at" `
        -Condition ($noPropAtResult.success -eq $false -and $noPropAtResult.reason -match "proposed_at") `
        -Message "Expected failure with 'proposed_at' reason, got: $($noPropAtResult.reason)"

    # Test template structure with enabled settings (mock REST to verify shape)
    $enabledSettings = [PSCustomObject]@{
        enabled = $true; server_url = "http://localhost:9999"; api_key = "test-key"
        channel = "teams"; recipients = @("user@example.com")
        project_name = "test-proj"; project_description = "desc"; instance_id = ""
    }
    $templateCapture = $null
    function global:Invoke-RestMethod {
        param([string]$Method = 'Get', [string]$Uri, [string]$Body, $Headers, $ContentType, $TimeoutSec)
        if ($Uri -match '/api/templates$') {
            $global:templateCapture = $Body | ConvertFrom-Json
            return @{}
        }
        if ($Uri -match '/api/instances$') {
            return @{}
        }
        throw "Unexpected URI: $Uri"
    }
    $splitTemplateResult = try {
        Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $mockSplitProposal -Settings $enabledSettings
    } finally {
        Remove-Item -Path 'function:global:Invoke-RestMethod' -ErrorAction SilentlyContinue
    }
    $templateCapture = $global:templateCapture
    Assert-True -Name "Send-SplitProposalNotification returns success with mock server" `
        -Condition ($splitTemplateResult.success -eq $true) `
        -Message "Expected success=true, got: $($splitTemplateResult | ConvertTo-Json -Depth 5)"

    if ($templateCapture) {
        Assert-True -Name "Split template title contains task name" `
            -Condition ($templateCapture.title -match "Refactor auth") `
            -Message "Expected title to contain task name, got: $($templateCapture.title)"

        Assert-True -Name "Split template has 2 options (Approve/Reject)" `
            -Condition ($templateCapture.options.Count -eq 2) `
            -Message "Expected 2 options, got $($templateCapture.options.Count)"

        $optionKeys = @($templateCapture.options | ForEach-Object { $_.key })
        Assert-True -Name "Split template options are 'approve' and 'reject'" `
            -Condition ($optionKeys -contains 'approve' -and $optionKeys -contains 'reject') `
            -Message "Expected approve/reject keys, got: $($optionKeys -join ', ')"

        Assert-True -Name "Split template context contains reason" `
            -Condition ($templateCapture.context -match "too large") `
            -Message "Expected context to contain reason"

        Assert-True -Name "Split template context contains sub-task names" `
            -Condition ($templateCapture.context -match "Extract middleware" -and $templateCapture.context -match "Add token rotation") `
            -Message "Expected context to list sub-tasks"

        Assert-True -Name "Split template has questionId (deterministic GUID)" `
            -Condition ($null -ne $templateCapture.questionId -and $templateCapture.questionId.Length -eq 36) `
            -Message "Expected 36-char GUID questionId, got: $($templateCapture.questionId)"

        Assert-True -Name "Split template disables free-text (Approve/Reject binary)" `
            -Condition ($templateCapture.responseSettings.allowFreeText -eq $false) `
            -Message "Expected allowFreeText=false for split proposal, got: $($templateCapture.responseSettings.allowFreeText)"
    }
} else {
    Write-TestResult -Name "NotificationClient module exists" -Status Fail -Message "Module not found at $notifModule"
}

# ═══════════════════════════════════════════════════════════════════
# MERGE CONFLICT ESCALATION MODULE TESTS (issue #224)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- MergeConflictEscalation Module ---" -ForegroundColor Cyan

$mergeEscModule = Join-Path $botDir "systems\runtime\modules\MergeConflictEscalation.psm1"

if (Test-Path $mergeEscModule) {
    Import-Module $mergeEscModule -Force

    # Ensure the helper is exported
    $cmd = Get-Command Move-TaskToMergeConflictNeedsInput -ErrorAction SilentlyContinue
    Assert-True -Name "Move-TaskToMergeConflictNeedsInput is exported" `
        -Condition ($null -ne $cmd) `
        -Message "Expected exported function"

    # Build an isolated workspace with a fake done/ task
    $mceWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-mce-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    $mceDone = Join-Path $mceWorkspace "done"
    $mceNeedsInput = Join-Path $mceWorkspace "needs-input"
    New-Item -ItemType Directory -Force -Path $mceDone | Out-Null

    $fakeTaskId = "abc12345"
    # Seed an open execution session on the task so the session-close path is
    # actually exercised. The runtime parent nulls $env:CLAUDE_SESSION_ID before
    # the squash-merge step, so the helper must source the session id from
    # $taskContent.execution_sessions, NOT from the env var.
    $fakeTaskJson = @{
        id                 = $fakeTaskId
        name               = "Fake merge-conflict task"
        status             = "done"
        created_at         = "2026-04-11T00:00:00.0000000Z"
        updated_at         = "2026-04-11T00:00:00.0000000Z"
        execution_sessions = @(
            @{ id = "exec-session-1"; started_at = "2026-04-11T00:00:01Z"; ended_at = $null }
        )
    } | ConvertTo-Json -Depth 10
    $fakeTaskFile = Join-Path $mceDone "$fakeTaskId.json"
    Set-Content -Path $fakeTaskFile -Value $fakeTaskJson -Encoding UTF8

    # NB: PSCustomObject branch of conflict_files extraction is defensive only —
    # Complete-TaskWorktree returns a [hashtable] in production (WorktreeManager.psm1
    # 652/707/747/771/816/909/917). The hashtable regression test below is the one
    # that pins production behaviour.
    $fakeMergeResult = [PSCustomObject]@{
        success        = $false
        message        = "conflict in 2 files"
        conflict_files = @("src/foo.cs", "src/bar.cs")
    }
    $fakeWorktreePath = "C:\worktrees\dotbot\task-$fakeTaskId-fake"

    # Point DotbotProjectRoot at the isolated temp workspace that has no `.bot/` —
    # `Test-Path` on NotificationClient.psm1 fails, so the notification branch short-circuits
    # to notified=$false deterministically, regardless of the developer's $testProject config.
    # NB: we pass `-BotRoot $mceBotRoot` explicitly to mirror how the runtime wires the helper
    # (Invoke-WorkflowProcess / Invoke-ExecutionProcess pass the `.bot` directory, NOT the
    # project root). This pins the regression: if the helper ever treats `$BotRoot` as a
    # project root again and appends `.bot`, these tests fail instead of passing vacuously.
    $mceBotRoot = Join-Path $mceWorkspace ".bot"
    $savedDotbotRoot = $global:DotbotProjectRoot
    $savedSessionEnv = $env:CLAUDE_SESSION_ID
    $global:DotbotProjectRoot = $mceWorkspace
    $env:CLAUDE_SESSION_ID = $null

    try {
        $result = Move-TaskToMergeConflictNeedsInput `
            -TaskId $fakeTaskId `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot

        Assert-True -Name "Move-TaskToMergeConflictNeedsInput returns success" `
            -Condition ($result.success -eq $true) `
            -Message "Expected success=true"

        Assert-True -Name "Task file moved out of done/" `
            -Condition (-not (Test-Path $fakeTaskFile)) `
            -Message "Original file still exists in done/"

        $newPath = Join-Path $mceNeedsInput "$fakeTaskId.json"
        Assert-True -Name "Task file created in needs-input/" `
            -Condition (Test-Path $newPath) `
            -Message "Expected file at $newPath"

        if (Test-Path $newPath) {
            $moved = Get-Content $newPath -Raw | ConvertFrom-Json

            Assert-True -Name "Status transitioned to needs-input" `
                -Condition ($moved.status -eq "needs-input") `
                -Message "Expected status=needs-input, got $($moved.status)"

            Assert-True -Name "pending_question.id is merge-conflict" `
                -Condition ($moved.pending_question.id -eq "merge-conflict") `
                -Message "Expected id=merge-conflict"

            Assert-True -Name "pending_question has 3 options (A/B/C)" `
                -Condition (@($moved.pending_question.options).Count -eq 3) `
                -Message "Expected 3 options, got $(@($moved.pending_question.options).Count)"

            $keys = @($moved.pending_question.options | ForEach-Object { $_.key }) -join ","
            Assert-True -Name "pending_question option keys are A,B,C" `
                -Condition ($keys -eq "A,B,C") `
                -Message "Expected A,B,C, got $keys"

            Assert-True -Name "pending_question recommendation is A" `
                -Condition ($moved.pending_question.recommendation -eq "A") `
                -Message "Expected recommendation=A"

            Assert-True -Name "pending_question context includes conflict files" `
                -Condition ($moved.pending_question.context -match "src/foo\.cs" -and $moved.pending_question.context -match "src/bar\.cs") `
                -Message "Expected conflict file names in context"

            Assert-True -Name "pending_question context includes worktree path" `
                -Condition ($moved.pending_question.context -match [regex]::Escape($fakeWorktreePath)) `
                -Message "Expected worktree path in context"
        }

        # No .bot/ under $mceWorkspace → NotificationClient not found → notified=$false deterministically
        Assert-True -Name "Escalation reports notified=false when NotificationClient absent" `
            -Condition ($result.notified -eq $false) `
            -Message "Expected notified=false when .bot/systems/mcp/modules/NotificationClient.psm1 is missing"

        Assert-True -Name "Escalation reason is 'NotificationClient module not found'" `
            -Condition ($result.notification_reason -eq "NotificationClient module not found") `
            -Message "Expected reason='NotificationClient module not found', got '$($result.notification_reason)'"

        # notification_silent must be $true for a project that hasn't opted in,
        # so the wrapper's call sites stay quiet on every escalation.
        Assert-True -Name "Escalation reports notification_silent=true when no module" `
            -Condition ($result.notification_silent -eq $true) `
            -Message "Expected notification_silent=true (project never opted in)"

        # Session-close: when SessionTracking.psm1 is unavailable under the temp
        # workspace, the helper must NOT throw and must still complete the file
        # move. The execution_sessions array must therefore survive untouched
        # (still exists, still has the open entry) — the close-with-module branch
        # is exercised explicitly in the notified=$true block below by stubbing
        # SessionTracking alongside NotificationClient.
        if (Test-Path $newPath) {
            $movedNoSession = Get-Content $newPath -Raw | ConvertFrom-Json
            Assert-True -Name "Session-close: helper survives missing SessionTracking module" `
                -Condition ($movedNoSession.execution_sessions -and @($movedNoSession.execution_sessions).Count -eq 1) `
                -Message "Expected execution_sessions to survive helper run"
        }

        # Missing-task case: calling again with a task id that is no longer in done/
        $missingResult = Move-TaskToMergeConflictNeedsInput `
            -TaskId "does-not-exist" `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot
        Assert-True -Name "Missing task returns success=false" `
            -Condition ($missingResult.success -eq $false) `
            -Message "Expected success=false when task file not found in done/"

        # --- Regression: hashtable shape (matches Complete-TaskWorktree's real return) ---
        # Previously the helper probed $MergeResult.PSObject.Properties['conflict_files'],
        # which is $null for [hashtable], so conflict_files were silently dropped from the
        # pending_question context and from the Teams card. (issue #224 review defect #2)
        $fakeTaskId2 = "hash1234"
        $fakeTaskJson2 = @{
            id         = $fakeTaskId2
            name       = "Fake hashtable merge-conflict task"
            status     = "done"
            created_at = "2026-04-11T00:00:00.0000000Z"
            updated_at = "2026-04-11T00:00:00.0000000Z"
        } | ConvertTo-Json -Depth 10
        $fakeTaskFile2 = Join-Path $mceDone "$fakeTaskId2.json"
        Set-Content -Path $fakeTaskFile2 -Value $fakeTaskJson2 -Encoding UTF8

        $fakeMergeResultHashtable = @{
            success        = $false
            message        = "conflict in 2 files"
            conflict_files = @("src/hash-foo.cs", "src/hash-bar.cs")
        }
        $fakeWorktreePath2 = "C:\worktrees\dotbot\task-$fakeTaskId2-fake"

        $resultHash = Move-TaskToMergeConflictNeedsInput `
            -TaskId $fakeTaskId2 `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResultHashtable `
            -WorktreePath $fakeWorktreePath2 `
            -BotRoot $mceBotRoot

        Assert-True -Name "Hashtable MergeResult: escalation returns success" `
            -Condition ($resultHash.success -eq $true) `
            -Message "Expected success=true for hashtable shape"

        $newPath2 = Join-Path $mceNeedsInput "$fakeTaskId2.json"
        if (Test-Path $newPath2) {
            $movedHash = Get-Content $newPath2 -Raw | ConvertFrom-Json
            Assert-True -Name "Hashtable MergeResult: context includes both conflict files" `
                -Condition ($movedHash.pending_question.context -match "src/hash-foo\.cs" -and $movedHash.pending_question.context -match "src/hash-bar\.cs") `
                -Message "Expected hashtable conflict_files to appear in pending_question.context (regression for issue #224 review defect #2)"
        } else {
            Write-TestResult -Name "Hashtable MergeResult: task file created in needs-input/" -Status Fail -Message "Expected file at $newPath2"
        }

        # --- notified=$true path: stub NotificationClient under the temp root ---
        # Materialise a fake .bot/systems/mcp/modules/NotificationClient.psm1 so the
        # helper's Test-Path succeeds and Send-TaskNotification returns a canned
        # success payload. This is the direct unit-level guarantee for issue #224:
        # without it, the entire success branch (Add-Member notification, second
        # JSON write, notification metadata persistence) would be untested.
        $stubModulesDir = Join-Path $mceWorkspace ".bot\systems\mcp\modules"
        New-Item -ItemType Directory -Force -Path $stubModulesDir | Out-Null
        $stubModulePath = Join-Path $stubModulesDir "NotificationClient.psm1"
        $stubModuleContent = @'
function Get-NotificationSettings {
    return [pscustomobject]@{ enabled = $true }
}
function Send-TaskNotification {
    param($TaskContent, $PendingQuestion)
    return @{
        success     = $true
        question_id = 'q-test'
        instance_id = 'i-test'
        channel     = 'teams'
        project_id  = 'p-test'
    }
}
Export-ModuleMember -Function 'Get-NotificationSettings','Send-TaskNotification'
'@
        Set-Content -Path $stubModulePath -Value $stubModuleContent -Encoding UTF8

        # Also stub SessionTracking.psm1 so the helper's session-close branch is
        # exercised end-to-end (review defect #1: helper used to read $env:CLAUDE_SESSION_ID
        # which is always null in the runtime parent — must source from execution_sessions).
        $stubSessionPath = Join-Path $stubModulesDir "SessionTracking.psm1"
        $stubSessionContent = @'
function Close-SessionOnTask {
    param($TaskContent, $SessionId, $Phase)
    if (-not $SessionId) { return }
    $arrayName = "${Phase}_sessions"
    if (-not $TaskContent.PSObject.Properties[$arrayName]) { return }
    foreach ($s in $TaskContent.$arrayName) {
        if ($s.id -eq $SessionId -and -not $s.ended_at) {
            $s | Add-Member -NotePropertyName ended_at -NotePropertyValue '2026-04-11T12:34:56Z' -Force
            break
        }
    }
}
Export-ModuleMember -Function 'Close-SessionOnTask'
'@
        Set-Content -Path $stubSessionPath -Value $stubSessionContent -Encoding UTF8

        # Seed the task with an open execution session so Close-SessionOnTask has
        # a target. Note: NO $env:CLAUDE_SESSION_ID — the helper must source the
        # session id from execution_sessions only.
        $fakeTaskId3 = "notif001"
        $fakeTaskJson3 = @{
            id                 = $fakeTaskId3
            name               = "Fake notify merge-conflict task"
            status             = "done"
            created_at         = "2026-04-11T00:00:00Z"
            updated_at         = "2026-04-11T00:00:00Z"
            execution_sessions = @(
                @{ id = "exec-notif-001"; started_at = "2026-04-11T00:00:01Z"; ended_at = $null }
            )
        } | ConvertTo-Json -Depth 10
        $fakeTaskFile3 = Join-Path $mceDone "$fakeTaskId3.json"
        Set-Content -Path $fakeTaskFile3 -Value $fakeTaskJson3 -Encoding UTF8

        # Env var already nulled and captured by the outer block — do not re-capture
        # here or the finally would wipe the developer's real shell var.

        $resultNotif = Move-TaskToMergeConflictNeedsInput `
            -TaskId $fakeTaskId3 `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot

        Assert-True -Name "Notified path: escalation returns success" `
            -Condition ($resultNotif.success -eq $true) `
            -Message "Expected success=true"

        Assert-True -Name "Notified path: notified=true" `
            -Condition ($resultNotif.notified -eq $true) `
            -Message "Expected notified=true when NotificationClient stub returns success"

        Assert-True -Name "Notified path: reason is 'Notification dispatched'" `
            -Condition ($resultNotif.notification_reason -eq "Notification dispatched") `
            -Message "Expected notification_reason='Notification dispatched', got '$($resultNotif.notification_reason)'"

        $newPath3 = Join-Path $mceNeedsInput "$fakeTaskId3.json"
        if (Test-Path $newPath3) {
            $movedNotif = Get-Content $newPath3 -Raw | ConvertFrom-Json

            Assert-True -Name "Notified path: notification.question_id persisted" `
                -Condition ($movedNotif.notification.question_id -eq "q-test") `
                -Message "Expected notification.question_id='q-test'"

            Assert-True -Name "Notified path: notification.channel persisted" `
                -Condition ($movedNotif.notification.channel -eq "teams") `
                -Message "Expected notification.channel='teams'"

            Assert-True -Name "Notified path: notification.instance_id persisted" `
                -Condition ($movedNotif.notification.instance_id -eq "i-test") `
                -Message "Expected notification.instance_id='i-test'"

            # Timestamp format guard for review defect #2 — second-precision, trailing Z.
            # NB: ConvertFrom-Json auto-coerces ISO 8601 strings to [datetime], which then
            # round-trips through local culture and breaks the regex. Pin the *on-disk*
            # serialised form by grepping the raw JSON text instead.
            $rawNotifJson = Get-Content $newPath3 -Raw
            $tsPattern = '"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
            Assert-True -Name "Notified path: notification.sent_at is second-precision (on disk)" `
                -Condition ($rawNotifJson -match "(?s)`"sent_at`"\s*:\s*$tsPattern") `
                -Message "Expected sent_at to be serialised as second-precision UTC string"

            Assert-True -Name "Notified path: pending_question.asked_at is second-precision (on disk)" `
                -Condition ($rawNotifJson -match "(?s)`"asked_at`"\s*:\s*$tsPattern") `
                -Message "Expected asked_at to be serialised as second-precision UTC string"

            # Session-close: helper must have stamped ended_at on the open
            # execution_sessions entry by sourcing its id from the task content
            # (NOT from $env:CLAUDE_SESSION_ID, which is empty in this test).
            $execSessions = @($movedNotif.execution_sessions)
            Assert-True -Name "Session-close: execution_sessions still has 1 entry" `
                -Condition ($execSessions.Count -eq 1) `
                -Message "Expected single execution session entry"

            if ($execSessions.Count -eq 1) {
                Assert-True -Name "Session-close: ended_at populated on previously-open session" `
                    -Condition ($null -ne $execSessions[0].ended_at -and "$($execSessions[0].ended_at)") `
                    -Message "Expected ended_at to be set after escalation; got '$($execSessions[0].ended_at)'"

                Assert-True -Name "Session-close: id matches the seeded open session" `
                    -Condition ($execSessions[0].id -eq "exec-notif-001") `
                    -Message "Expected id=exec-notif-001, got '$($execSessions[0].id)'"
            }
        } else {
            Write-TestResult -Name "Notified path: task file created in needs-input/" -Status Fail -Message "Expected file at $newPath3"
        }

    } finally {
        # Unload the stub so it cannot leak into later tests that rely on the real module.
        # Must run in finally: $ErrorActionPreference=Stop means any assertion failure
        # above would otherwise skip cleanup and shadow the real NotificationClient
        # in subsequent tests.
        Remove-Module NotificationClient -Force -ErrorAction SilentlyContinue
        Remove-Module SessionTracking -Force -ErrorAction SilentlyContinue
        if ($null -ne $savedSessionEnv) { $env:CLAUDE_SESSION_ID = $savedSessionEnv } else { Remove-Item Env:CLAUDE_SESSION_ID -ErrorAction SilentlyContinue }
        $global:DotbotProjectRoot = $savedDotbotRoot
        Remove-Item -Path $mceWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-TestResult -Name "MergeConflictEscalation module exists" -Status Fail -Message "Module not found at $mergeEscModule"
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

    # ── Invoke-SplitTransitionFromNotification tests ─────────────────
    $needsInputDir = Join-Path $botDir "workspace" "tasks" "needs-input"
    $analysingDir  = Join-Path $botDir "workspace" "tasks" "analysing"
    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }

    # --- Reject path test ---
    $rejectTask = [PSCustomObject]@{
        id = "split-reject-test"
        name = "Task to reject"
        status = "needs-input"
        split_proposal = [PSCustomObject]@{
            reason = "Too big"
            sub_tasks = @([PSCustomObject]@{ name = "Sub A" })
            proposed_at = "2026-01-15T10:00:00Z"
        }
        notification = [PSCustomObject]@{
            question_id = "q-reject"; instance_id = "i-reject"; channel = "teams"; project_id = "proj1"
        }
        updated_at = "2026-01-15T10:00:00Z"
    }
    $rejectFile = Join-Path $needsInputDir "split-reject-test.json"
    $rejectTask | ConvertTo-Json -Depth 20 | Set-Content -Path $rejectFile -Encoding UTF8
    $rejectFileInfo = Get-Item $rejectFile

    $rejectError = $false
    try {
        Invoke-SplitTransitionFromNotification -TaskFile $rejectFileInfo -TaskContent $rejectTask `
            -AnswerKey 'reject' -BotRoot $botDir
    } catch {
        $rejectError = $true
    }
    Assert-True -Name "Invoke-SplitTransitionFromNotification reject does not throw" `
        -Condition (-not $rejectError) `
        -Message "Reject path threw an error"

    Assert-PathNotExists -Name "Reject: task removed from needs-input" -Path $rejectFile

    $rejectedFile = Join-Path $analysingDir "split-reject-test.json"
    Assert-PathExists -Name "Reject: task moved to analysing" -Path $rejectedFile

    if (Test-Path $rejectedFile) {
        $rejectedContent = Get-Content -Path $rejectedFile -Raw | ConvertFrom-Json
        Assert-True -Name "Reject: split_proposal.status is 'rejected'" `
            -Condition ($rejectedContent.split_proposal.status -eq 'rejected') `
            -Message "Expected 'rejected', got '$($rejectedContent.split_proposal.status)'"
        Assert-True -Name "Reject: split_proposal.answered_via is 'notification'" `
            -Condition ($rejectedContent.split_proposal.answered_via -eq 'notification') `
            -Message "Expected 'notification', got '$($rejectedContent.split_proposal.answered_via)'"
        Assert-True -Name "Reject: notification metadata cleared" `
            -Condition ($null -eq $rejectedContent.notification) `
            -Message "Expected notification=null"
        Assert-True -Name "Reject: task status is 'analysing'" `
            -Condition ($rejectedContent.status -eq 'analysing') `
            -Message "Expected 'analysing', got '$($rejectedContent.status)'"
        # Cleanup
        Remove-Item -Path $rejectedFile -Force -ErrorAction SilentlyContinue
    }

    # --- Invalid key test (no-op) ---
    $invalidKeyTask = [PSCustomObject]@{
        id = "split-invalid-test"
        name = "Task with bad key"
        status = "needs-input"
        split_proposal = [PSCustomObject]@{
            reason = "Reason"; sub_tasks = @([PSCustomObject]@{ name = "Sub" })
            proposed_at = "2026-01-15T10:00:00Z"
        }
        notification = [PSCustomObject]@{
            question_id = "q-inv"; instance_id = "i-inv"; channel = "teams"; project_id = "proj1"
        }
        updated_at = "2026-01-15T10:00:00Z"
    }
    $invalidFile = Join-Path $needsInputDir "split-invalid-test.json"
    $invalidKeyTask | ConvertTo-Json -Depth 20 | Set-Content -Path $invalidFile -Encoding UTF8
    $invalidFileInfo = Get-Item $invalidFile

    $invalidError = $false
    try {
        Invoke-SplitTransitionFromNotification -TaskFile $invalidFileInfo -TaskContent $invalidKeyTask `
            -AnswerKey 'maybe' -BotRoot $botDir
    } catch {
        $invalidError = $true
    }
    Assert-True -Name "Invoke-SplitTransitionFromNotification ignores invalid key" `
        -Condition (-not $invalidError) `
        -Message "Invalid key should not throw"

    Assert-PathExists -Name "Invalid key: task stays in needs-input" -Path $invalidFile

    if (Test-Path $invalidFile) {
        $invalidContent = Get-Content -Path $invalidFile -Raw | ConvertFrom-Json
        Assert-True -Name "Invalid key: notification metadata cleared (prevents poll loop)" `
            -Condition ($null -eq $invalidContent.notification) `
            -Message "Expected notification=null after invalid-key ignore"
        Assert-True -Name "Invalid key: split_proposal preserved" `
            -Condition ($null -ne $invalidContent.split_proposal -and $invalidContent.split_proposal.reason -eq 'Reason') `
            -Message "Expected split_proposal preserved"
    }
    # Cleanup
    Remove-Item -Path $invalidFile -Force -ErrorAction SilentlyContinue
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
        # Image files for type tests
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "logo.png"), [byte[]](0x89, 0x50, 0x4E, 0x47))
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "screenshot.jpg"), [byte[]](0xFF, 0xD8, 0xFF, 0xE0))
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "animation.gif"), [byte[]](0x47, 0x49, 0x46, 0x38))
        Set-Content -Path (Join-Path $productDir "diagram.svg") -Value '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>' -Encoding UTF8
        # Text file for txt type tests
        Set-Content -Path (Join-Path $productDir "notes.txt") -Value "Plain text content with <html> special chars" -Encoding UTF8
        # True binary file for binary type tests
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "document.pdf"), [byte[]](0x25, 0x50, 0x44, 0x46))
        # .gitkeep should be excluded
        Set-Content -Path (Join-Path $briefingDir ".gitkeep") -Value "" -Encoding UTF8

        Initialize-ProductAPI -BotRoot $productBotRoot -ControlDir $controlDir

        $docs = @((Get-ProductList).docs)
        Assert-Equal -Name "ProductAPI lists nested product docs" `
            -Expected 12 `
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
        Assert-True -Name "ProductAPI includes image files in list" `
            -Condition ($null -ne $logoPng) `
            -Message "Image file logo.png missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .png files" `
            -Expected "image" `
            -Actual $logoPng.type
        Assert-True -Name "ProductAPI returns size field for image files" `
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

        # ── Text file (.txt) support tests ──

        $notesTxt = $docs | Where-Object { $_.name -eq 'notes.txt' }
        Assert-True -Name "ProductAPI includes .txt files in list" `
            -Condition ($null -ne $notesTxt) `
            -Message "Text file notes.txt missing from product list"
        Assert-Equal -Name "ProductAPI returns type=txt for .txt files" `
            -Expected "txt" `
            -Actual $notesTxt.type
        Assert-Equal -Name "ProductAPI retains .txt extension in name" `
            -Expected "notes.txt" `
            -Actual $notesTxt.name

        $txtDoc = Get-ProductDocument -Name "notes.txt"
        Assert-True -Name "ProductAPI loads .txt doc by name" `
            -Condition ($txtDoc.success -eq $true -and $txtDoc.content -match 'Plain text content') `
            -Message "Text doc notes.txt could not be loaded"

        # ── Image file type detection tests ──

        $screenshotJpg = $docs | Where-Object { $_.name -eq 'screenshot.jpg' }
        Assert-True -Name "ProductAPI includes .jpg files in list" `
            -Condition ($null -ne $screenshotJpg) `
            -Message "Image file screenshot.jpg missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .jpg files" `
            -Expected "image" `
            -Actual $screenshotJpg.type

        $animationGif = $docs | Where-Object { $_.name -eq 'animation.gif' }
        Assert-True -Name "ProductAPI includes .gif files in list" `
            -Condition ($null -ne $animationGif) `
            -Message "Image file animation.gif missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .gif files" `
            -Expected "image" `
            -Actual $animationGif.type

        $diagramSvg = $docs | Where-Object { $_.name -eq 'diagram.svg' }
        Assert-True -Name "ProductAPI includes .svg files in list" `
            -Condition ($null -ne $diagramSvg) `
            -Message "Image file diagram.svg missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .svg files" `
            -Expected "image" `
            -Actual $diagramSvg.type

        Assert-Equal -Name "ProductAPI retains image extension in name" `
            -Expected "screenshot.jpg" `
            -Actual $screenshotJpg.name

        # ── True binary files still classified as binary ──

        $documentPdf = $docs | Where-Object { $_.name -eq 'document.pdf' }
        Assert-True -Name "ProductAPI includes true binary files in list" `
            -Condition ($null -ne $documentPdf) `
            -Message "Binary file document.pdf missing from product list"
        Assert-Equal -Name "ProductAPI returns type=binary for unknown extensions" `
            -Expected "binary" `
            -Actual $documentPdf.type

        # ── Get-ProductDocumentRaw tests ──

        $rawPng = Get-ProductDocumentRaw -Name "logo.png"
        Assert-True -Name "ProductDocumentRaw finds .png file" `
            -Condition ($rawPng.Found -eq $true) `
            -Message "Get-ProductDocumentRaw did not find logo.png"
        Assert-Equal -Name "ProductDocumentRaw returns image/png MIME type" `
            -Expected "image/png" `
            -Actual $rawPng.MimeType
        Assert-True -Name "ProductDocumentRaw returns binary data for .png" `
            -Condition ($null -ne $rawPng.BinaryData -and $rawPng.BinaryData.Length -gt 0) `
            -Message "Expected non-empty BinaryData for logo.png"

        $rawJpg = Get-ProductDocumentRaw -Name "screenshot.jpg"
        Assert-Equal -Name "ProductDocumentRaw returns image/jpeg MIME type for .jpg" `
            -Expected "image/jpeg" `
            -Actual $rawJpg.MimeType
        Assert-True -Name "ProductDocumentRaw returns binary data for .jpg" `
            -Condition ($null -ne $rawJpg.BinaryData -and $rawJpg.BinaryData.Length -gt 0) `
            -Message "Expected non-empty BinaryData for screenshot.jpg"

        $rawGif = Get-ProductDocumentRaw -Name "animation.gif"
        Assert-Equal -Name "ProductDocumentRaw returns image/gif MIME type" `
            -Expected "image/gif" `
            -Actual $rawGif.MimeType

        $rawSvg = Get-ProductDocumentRaw -Name "diagram.svg"
        Assert-True -Name "ProductDocumentRaw finds .svg file" `
            -Condition ($rawSvg.Found -eq $true) `
            -Message "Get-ProductDocumentRaw did not find diagram.svg"
        Assert-Equal -Name "ProductDocumentRaw returns image/svg+xml MIME type" `
            -Expected "image/svg+xml" `
            -Actual $rawSvg.MimeType
        Assert-True -Name "ProductDocumentRaw returns text content for .svg (not binary)" `
            -Condition ($null -ne $rawSvg.TextContent -and $rawSvg.TextContent -match '<svg') `
            -Message "Expected SVG text content, not binary data"
        Assert-True -Name "ProductDocumentRaw does not return binary data for .svg" `
            -Condition ($null -eq $rawSvg.BinaryData) `
            -Message "SVG should use TextContent, not BinaryData"

        $rawTxt = Get-ProductDocumentRaw -Name "notes.txt"
        Assert-True -Name "ProductDocumentRaw finds .txt file" `
            -Condition ($rawTxt.Found -eq $true) `
            -Message "Get-ProductDocumentRaw did not find notes.txt"
        Assert-Equal -Name "ProductDocumentRaw returns text/plain MIME type for .txt" `
            -Expected "text/plain; charset=utf-8" `
            -Actual $rawTxt.MimeType
        Assert-True -Name "ProductDocumentRaw returns text content for .txt" `
            -Condition ($null -ne $rawTxt.TextContent -and $rawTxt.TextContent -match 'Plain text content') `
            -Message "Expected text content for notes.txt"

        $rawMissing = Get-ProductDocumentRaw -Name "nonexistent.png"
        Assert-True -Name "ProductDocumentRaw returns Found=false for missing file" `
            -Condition ($rawMissing.Found -eq $false) `
            -Message "Expected Found=false for nonexistent file"

        $rawTraversal = Get-ProductDocumentRaw -Name "../secrets.png"
        Assert-True -Name "ProductDocumentRaw blocks path traversal" `
            -Condition ($rawTraversal.Found -eq $false) `
            -Message "Path traversal should return not found"

        # ═════════════════════════════════════════════════════════════════
        # Get-KickstartStatus — script-phase probe + process-type filter
        # Regression tests for #244: Overview stuck on Task Group Expansion
        # ═════════════════════════════════════════════════════════════════

        # Set up a fresh, isolated workspace for kickstart status tests so
        # state doesn't leak into the doc tests above.
        $kickstartTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-kickstart-status-$([guid]::NewGuid().ToString().Substring(0,8))"
        $kickstartBotRoot  = Join-Path $kickstartTestRoot ".bot"
        $kickstartControl  = Join-Path $kickstartBotRoot ".control"
        $kickstartSettings = Join-Path $kickstartBotRoot "settings"
        $kickstartTasksDir = Join-Path $kickstartBotRoot "workspace\tasks"
        $kickstartProductDir = Join-Path $kickstartBotRoot "workspace\product"
        $kickstartDecisionsDir = Join-Path $kickstartBotRoot "workspace\decisions"

        foreach ($d in @($kickstartControl, (Join-Path $kickstartControl 'processes'), $kickstartSettings, $kickstartProductDir, $kickstartDecisionsDir)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
        # Create the full canonical task pipeline dir set (matches
        # workflow-manifest.ps1 Clear-WorkspaceTaskDirs).
        foreach ($td in @('todo','analysing','needs-input','analysed','in-progress','done','skipped','cancelled','split')) {
            New-Item -Path (Join-Path $kickstartTasksDir $td) -ItemType Directory -Force | Out-Null
        }

        # Mark the first three phases complete via disk artifacts
        Set-Content -Path (Join-Path $kickstartProductDir 'mission.md') -Value '# Mission' -Encoding UTF8
        Set-Content -Path (Join-Path $kickstartProductDir 'tech-stack.md') -Value '# Tech' -Encoding UTF8
        Set-Content -Path (Join-Path $kickstartProductDir 'entity-model.md') -Value '# Entities' -Encoding UTF8
        Set-Content -Path (Join-Path $kickstartProductDir 'task-groups.json') -Value '{"groups":[]}' -Encoding UTF8
        Set-Content -Path (Join-Path $kickstartDecisionsDir 'dec-0001.md') -Value '# Decision 1' -Encoding UTF8

        # Minimal legacy kickstart phase list via settings.default.json — the
        # Get-KickstartStatus fallback path. Avoids needing a YAML parser in
        # the test environment.
        $kickstartPhasesJson = @'
{
  "kickstart": {
    "phases": [
      {
        "id": "product-documents",
        "name": "Product Documents",
        "type": "prompt",
        "outputs": ["mission.md", "tech-stack.md", "entity-model.md"]
      },
      {
        "id": "generate-decisions",
        "name": "Generate Decisions",
        "type": "prompt",
        "outputs_dir": "decisions",
        "min_output_count": 1
      },
      {
        "id": "task-groups",
        "name": "Task Groups",
        "type": "prompt",
        "outputs": ["task-groups.json"]
      },
      {
        "id": "task-group-expansion",
        "name": "Task Group Expansion",
        "type": "script",
        "script": "expand-task-groups.ps1",
        "commit": { "paths": ["workspace/tasks/"] }
      }
    ]
  }
}
'@
        Set-Content -Path (Join-Path $kickstartSettings 'settings.default.json') -Value $kickstartPhasesJson -Encoding UTF8

        # Get-KickstartStatus dot-sources $BotRoot/systems/runtime/modules/workflow-manifest.ps1
        # and that file imports ManifestCondition.psm1 from the same directory.
        # Copy both helpers into the test bot root so the integration test can run.
        $runtimeModulesDir = Join-Path $kickstartBotRoot "systems\runtime\modules"
        New-Item -Path $runtimeModulesDir -ItemType Directory -Force | Out-Null
        $repoRootForTest = Split-Path $PSScriptRoot -Parent
        $realRuntimeModules = Join-Path $repoRootForTest "workflows\default\systems\runtime\modules"
        Copy-Item -Path (Join-Path $realRuntimeModules 'workflow-manifest.ps1') -Destination $runtimeModulesDir -Force
        Copy-Item -Path (Join-Path $realRuntimeModules 'ManifestCondition.psm1') -Destination $runtimeModulesDir -Force

        # Re-initialize ProductAPI against the isolated kickstart test root
        Initialize-ProductAPI -BotRoot $kickstartBotRoot -ControlDir $kickstartControl

        # Helper: invoke the module-private Resolve-PhaseStatusFromOutputs
        # directly. It's not exported so we use module-scope invocation.
        $productApiModuleObj = Get-Module ProductAPI
        $resolvePhaseStatus = {
            param($Phase, $BotRoot)
            Resolve-PhaseStatusFromOutputs -Phase $Phase -BotRoot $BotRoot
        }

        # ── Defect 2: script-phase probe (Resolve-PhaseStatusFromOutputs) ──

        $scriptPhaseCommitTasks = [pscustomobject]@{
            id = 'task-group-expansion'
            name = 'Task Group Expansion'
            type = 'script'
            script = 'expand-task-groups.ps1'
            commit = [pscustomobject]@{ paths = @('workspace/tasks/') }
        }

        # Case A: entirely empty pipeline dirs → pending (was: pending — same)
        $statusEmpty = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: empty tasks/ → pending" `
            -Expected "pending" -Actual $statusEmpty

        # Case B: a task file in tasks/todo/ → completed
        # (This is the #244 bug: before the fix, returned "pending" because
        # Get-ChildItem -File on the tasks/ parent had no top-level files.)
        Set-Content -Path (Join-Path $kickstartTasksDir 'todo/expanded-task-1.json') `
            -Value '{"id":"t1","name":"test"}' -Encoding UTF8
        $statusWithTodo = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/todo/ → completed (#244 regression)" `
            -Expected "completed" -Actual $statusWithTodo

        # Case C: task only in tasks/done/ (workflow task moved through pipeline) → completed
        Remove-Item (Join-Path $kickstartTasksDir 'todo/expanded-task-1.json') -Force
        Set-Content -Path (Join-Path $kickstartTasksDir 'done/expanded-task-1.json') `
            -Value '{"id":"t1","name":"test"}' -Encoding UTF8
        $statusWithDone = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/done/ → completed" `
            -Expected "completed" -Actual $statusWithDone
        Remove-Item (Join-Path $kickstartTasksDir 'done/expanded-task-1.json') -Force

        # Case C2: task only in tasks/skipped/ → completed (pipeline-dir list
        # must stay aligned with the outputs_dir branch, which also counts
        # skipped + cancelled as evidence the phase ran).
        Set-Content -Path (Join-Path $kickstartTasksDir 'skipped/expanded-task-s.json') `
            -Value '{"id":"ts","name":"skipped"}' -Encoding UTF8
        $statusWithSkipped = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/skipped/ → completed" `
            -Expected "completed" -Actual $statusWithSkipped
        Remove-Item (Join-Path $kickstartTasksDir 'skipped/expanded-task-s.json') -Force

        # Case C3: task only in tasks/cancelled/ → completed
        Set-Content -Path (Join-Path $kickstartTasksDir 'cancelled/expanded-task-c.json') `
            -Value '{"id":"tc","name":"cancelled"}' -Encoding UTF8
        $statusWithCancelled = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/cancelled/ → completed" `
            -Expected "completed" -Actual $statusWithCancelled
        Remove-Item (Join-Path $kickstartTasksDir 'cancelled/expanded-task-c.json') -Force

        # Case C4: task only in tasks/needs-input/ → completed
        # (Split/needs-input are legitimate pipeline statuses per
        # workflow-manifest.ps1 Clear-WorkspaceTaskDirs — must be recognized.)
        Set-Content -Path (Join-Path $kickstartTasksDir 'needs-input/expanded-task-n.json') `
            -Value '{"id":"tn","name":"needs-input"}' -Encoding UTF8
        $statusWithNeedsInput = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/needs-input/ → completed" `
            -Expected "completed" -Actual $statusWithNeedsInput
        Remove-Item (Join-Path $kickstartTasksDir 'needs-input/expanded-task-n.json') -Force

        # Case C5: task only in tasks/split/ → completed
        Set-Content -Path (Join-Path $kickstartTasksDir 'split/expanded-task-sp.json') `
            -Value '{"id":"tsp","name":"split"}' -Encoding UTF8
        $statusWithSplit = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/split/ → completed" `
            -Expected "completed" -Actual $statusWithSplit
        Remove-Item (Join-Path $kickstartTasksDir 'split/expanded-task-sp.json') -Force

        # Case D: only .gitkeep sentinels in pipeline dirs → pending
        # (Sentinels must not trip the probe — that would mask a never-ran state.)
        Set-Content -Path (Join-Path $kickstartTasksDir 'todo/.gitkeep') -Value '' -Encoding UTF8
        Set-Content -Path (Join-Path $kickstartTasksDir 'done/.gitkeep') -Value '' -Encoding UTF8
        $statusOnlyGitkeep = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: only .gitkeep sentinels → pending" `
            -Expected "pending" -Actual $statusOnlyGitkeep
        Remove-Item (Join-Path $kickstartTasksDir 'todo/.gitkeep') -Force
        Remove-Item (Join-Path $kickstartTasksDir 'done/.gitkeep') -Force

        # Case E: general recursive case — a non-tasks commit path with
        # committed files nested two levels deep. The old probe used a flat
        # file count on the top-level dir and would have missed these.
        $customDir = Join-Path $kickstartBotRoot 'workspace\custom\nested\deep'
        New-Item -Path $customDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $customDir 'artifact.txt') -Value 'hello' -Encoding UTF8
        $scriptPhaseCustom = [pscustomobject]@{
            id = 'custom-phase'
            name = 'Custom Phase'
            type = 'script'
            script = 'custom.ps1'
            commit = [pscustomobject]@{ paths = @('workspace/custom/') }
        }
        $statusRecursive = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCustom $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: nested artifacts → completed (recursive general case)" `
            -Expected "completed" -Actual $statusRecursive

        # Case F: general recursive case with only .gitkeep → pending
        Remove-Item (Join-Path $customDir 'artifact.txt') -Force
        Set-Content -Path (Join-Path $customDir '.gitkeep') -Value '' -Encoding UTF8
        $statusRecursiveGitkeep = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCustom $kickstartBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: nested .gitkeep only → pending" `
            -Expected "pending" -Actual $statusRecursiveGitkeep

        # ── Integration: Get-KickstartStatus full-stack ──

        # With a real task file and no process record, all four phases should
        # report completed via filesystem inference (P1 + P3 working end-to-end).
        Set-Content -Path (Join-Path $kickstartTasksDir 'todo/expanded-task-1.json') `
            -Value '{"id":"t1","name":"test"}' -Encoding UTF8

        $statusNoProc = Get-KickstartStatus
        Assert-Equal -Name "Get-KickstartStatus: overall status with 4 complete phases (no proc)" `
            -Expected "completed" -Actual $statusNoProc.status
        $expansionPhase = $statusNoProc.phases | Where-Object { $_.id -eq 'task-group-expansion' }
        Assert-Equal -Name "Get-KickstartStatus: expansion phase completed via filesystem inference" `
            -Expected "completed" -Actual $expansionPhase.status
        Assert-True -Name "Get-KickstartStatus: resume_from is null when all phases complete" `
            -Condition ([string]::IsNullOrEmpty($statusNoProc.resume_from)) `
            -Message "Expected resume_from null/empty, got '$($statusNoProc.resume_from)'"

        # ── Defect 1: process-type filter (P2) ──

        $procDir = Join-Path $kickstartControl 'processes'

        # P2 positive: task-runner process with matching workflow_name IS picked up.
        # This case requires a real YAML manifest so that $workflowName gets
        # populated inside Get-KickstartStatus (the legacy settings.default.json
        # fallback leaves workflowName null, which would short-circuit the match).
        # Skip if powershell-yaml is unavailable in the test environment.
        $haveYamlModule = $null -ne (Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue)
        if ($haveYamlModule) {
            $manifestDir = Join-Path $kickstartBotRoot "workflows\kickstart-from-scratch"
            New-Item -Path $manifestDir -ItemType Directory -Force | Out-Null
            $manifestYaml = @'
name: kickstart-from-scratch
version: "1.0"
description: Test manifest for #244 regression
tasks:
  - name: "Product Documents"
    id: product-documents
    type: prompt
    outputs: ["mission.md", "tech-stack.md", "entity-model.md"]
  - name: "Generate Decisions"
    id: generate-decisions
    type: prompt
    outputs_dir: "decisions"
    min_output_count: 1
  - name: "Task Groups"
    id: task-groups
    type: prompt
    outputs: ["task-groups.json"]
  - name: "Task Group Expansion"
    id: task-group-expansion
    type: script
    script: "expand-task-groups.ps1"
    outputs_dir: "tasks/todo"
    min_output_count: 1
    commit:
      paths: ["workspace/tasks/"]
'@
            Set-Content -Path (Join-Path $manifestDir 'workflow.yaml') -Value $manifestYaml -Encoding UTF8

            $matchingProc = @{
                id = 'proc-test-match'
                type = 'task-runner'
                workflow_name = 'kickstart-from-scratch'
                status = 'completed'
                phases = @()
            } | ConvertTo-Json -Depth 4
            Set-Content -Path (Join-Path $procDir 'proc-test-match.json') -Value $matchingProc -Encoding UTF8
            $statusMatch = Get-KickstartStatus
            Assert-Equal -Name "Get-KickstartStatus P2: task-runner proc with matching workflow_name → process_id populated" `
                -Expected 'proc-test-match' -Actual $statusMatch.process_id
            Assert-Equal -Name "Get-KickstartStatus P2: workflow_name surfaced in response" `
                -Expected 'kickstart-from-scratch' -Actual $statusMatch.workflow_name
            Remove-Item (Join-Path $procDir 'proc-test-match.json') -Force
            # Leave the manifest in place for the remaining P2 tests.
        } else {
            Write-TestResult -Name "Get-KickstartStatus P2: task-runner proc with matching workflow_name" `
                -Status Skip -Message "powershell-yaml module not available"
        }

        # P2 regression: task-runner process with DIFFERENT workflow_name is ignored
        $otherProc = @{
            id = 'proc-test-other'
            type = 'task-runner'
            workflow_name = 'some-other-workflow'
            status = 'completed'
            phases = @()
        } | ConvertTo-Json -Depth 4
        Set-Content -Path (Join-Path $procDir 'proc-test-other.json') -Value $otherProc -Encoding UTF8
        $statusOther = Get-KickstartStatus
        Assert-True -Name "Get-KickstartStatus P2: task-runner proc with non-matching workflow_name → process_id null" `
            -Condition ([string]::IsNullOrEmpty($statusOther.process_id)) `
            -Message "Expected null process_id, got '$($statusOther.process_id)'"
        Remove-Item (Join-Path $procDir 'proc-test-other.json') -Force

        # P2 compatibility: type=kickstart still works (back-compat)
        $legacyProc = @{
            id = 'proc-test-legacy'
            type = 'kickstart'
            status = 'completed'
            phases = @()
        } | ConvertTo-Json -Depth 4
        Set-Content -Path (Join-Path $procDir 'proc-test-legacy.json') -Value $legacyProc -Encoding UTF8
        $statusLegacy = Get-KickstartStatus
        Assert-Equal -Name "Get-KickstartStatus P2: legacy type=kickstart proc still matched" `
            -Expected 'proc-test-legacy' -Actual $statusLegacy.process_id
        Remove-Item (Join-Path $procDir 'proc-test-legacy.json') -Force

        # Cleanup isolated kickstart test root
        if (Test-Path $kickstartTestRoot) {
            Remove-Item $kickstartTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-TestProject -Path $productApiTestProject
        Remove-Module ProductAPI -ErrorAction SilentlyContinue
        if ($kickstartTestRoot -and (Test-Path $kickstartTestRoot)) {
            Remove-Item $kickstartTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
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
# FRAMEWORK INTEGRITY — BEHAVIORAL TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FRAMEWORK INTEGRITY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$repoRoot = Get-RepoRoot
$manifestModule = Join-Path $dotbotDir "workflows" "default" "systems" "mcp" "modules" "Manifest.psm1"
$frameworkIntegrityModule = Join-Path $dotbotDir "workflows" "default" "systems" "mcp" "modules" "FrameworkIntegrity.psm1"

if ((Test-Path $manifestModule) -and (Test-Path $frameworkIntegrityModule)) {
    Import-Module $manifestModule -Force
    Import-Module $frameworkIntegrityModule -Force

    # Build a minimal mock .bot/ in a temp directory with git
    $fiTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-fi-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $fiTestDir -Force | Out-Null
    Push-Location $fiTestDir
    try {
        & git init --quiet 2>$null
        & git config user.email "test@test.com" 2>$null
        & git config user.name "Test" 2>$null

        # Create a .bot/ structure with two protected dirs and a protected file.
        # Include the sentinel file (dotbot-mcp.ps1) that Test-FrameworkIntegrity
        # uses to detect pre-first-commit state via git log.
        $protectedPaths = @('.bot/systems', '.bot/go.ps1')
        New-Item -ItemType Directory -Path (Join-Path $fiTestDir ".bot/systems/mcp") -Force | Out-Null
        Set-Content -Path (Join-Path $fiTestDir ".bot/systems/mcp/dotbot-mcp.ps1") -Value "# mcp server" -Encoding UTF8
        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# go" -Encoding UTF8

        # ── New-DotbotManifest: generates valid JSON with correct hashes ──

        $mfPath = New-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths -Generator 'test'
        Assert-True -Name "New-DotbotManifest returns manifest path" `
            -Condition ($null -ne $mfPath -and (Test-Path $mfPath)) `
            -Message "Expected a valid file path, got $mfPath"

        $mfJson = $null
        try { $mfJson = Get-Content $mfPath -Raw | ConvertFrom-Json } catch {}
        Assert-True -Name "New-DotbotManifest produces valid JSON" `
            -Condition ($null -ne $mfJson) `
            -Message "Manifest file is not valid JSON"

        Assert-True -Name "Manifest has version field" `
            -Condition ($mfJson.version -eq 1) `
            -Message "Expected version=1, got $($mfJson.version)"
        Assert-True -Name "Manifest has generator field" `
            -Condition ($mfJson.generator -eq 'test') `
            -Message "Expected generator=test, got $($mfJson.generator)"
        Assert-True -Name "Manifest has files object" `
            -Condition ($null -ne $mfJson.files) `
            -Message "Missing files object"
        Assert-True -Name "Manifest has user_paths array" `
            -Condition ($null -ne $mfJson.user_paths) `
            -Message "Missing user_paths field"

        # Verify manifest hash matches Get-FrameworkContentHash (content hash,
        # not raw SHA256 — the manifest normalises CR bytes so CRLF/LF line-ending
        # drift between init and clone does not trigger a false tamper report).
        $goHash = Get-FrameworkContentHash -Path (Join-Path $fiTestDir ".bot/go.ps1")
        $manifestGoHash = $mfJson.files.'.bot/go.ps1'.sha256
        Assert-True -Name "Manifest hash matches Get-FrameworkContentHash" `
            -Condition ($manifestGoHash -eq $goHash) `
            -Message "Expected $goHash, got $manifestGoHash"

        # Verify both files are in the manifest
        $fileKeys = @($mfJson.files.PSObject.Properties.Name)
        Assert-True -Name "Manifest contains both protected files" `
            -Condition ($fileKeys.Count -eq 2) `
            -Message "Expected 2 files, got $($fileKeys.Count): $($fileKeys -join ', ')"

        # ── Test-DotbotManifest: clean state ──

        $cleanResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest clean: success=true" `
            -Condition ($cleanResult.success -eq $true) `
            -Message "Expected success, got reason=$($cleanResult.reason)"
        Assert-True -Name "Test-DotbotManifest clean: reason=clean" `
            -Condition ($cleanResult.reason -eq 'clean') `
            -Message "Expected reason=clean, got $($cleanResult.reason)"

        # ── Test-DotbotManifest: tampered file ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# TAMPERED" -Encoding UTF8
        $tamperResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest tampered: success=false" `
            -Condition ($tamperResult.success -eq $false) `
            -Message "Expected failure for tampered file"
        Assert-True -Name "Test-DotbotManifest tampered: reason=tampered" `
            -Condition ($tamperResult.reason -eq 'tampered') `
            -Message "Expected reason=tampered, got $($tamperResult.reason)"
        Assert-True -Name "Test-DotbotManifest tampered: flags correct file" `
            -Condition ($tamperResult.files -contains '.bot/go.ps1') `
            -Message "Expected .bot/go.ps1 in files, got $($tamperResult.files -join ', ')"
        # Restore
        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# go" -Encoding UTF8

        # ── Test-DotbotManifest: added file ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/systems/extra.ps1") -Value "# extra" -Encoding UTF8
        $addResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest added: success=false" `
            -Condition ($addResult.success -eq $false) `
            -Message "Expected failure for added file"
        Assert-True -Name "Test-DotbotManifest added: flags the new file" `
            -Condition ($addResult.files -contains '.bot/systems/extra.ps1') `
            -Message "Expected .bot/systems/extra.ps1 in files, got $($addResult.files -join ', ')"
        Remove-Item (Join-Path $fiTestDir ".bot/systems/extra.ps1") -Force

        # ── Test-DotbotManifest: deleted file ──

        Rename-Item (Join-Path $fiTestDir ".bot/go.ps1") (Join-Path $fiTestDir ".bot/go.ps1.bak")
        $delResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest deleted: success=false" `
            -Condition ($delResult.success -eq $false) `
            -Message "Expected failure for deleted file"
        Assert-True -Name "Test-DotbotManifest deleted: flags missing file" `
            -Condition ($delResult.files -contains '.bot/go.ps1') `
            -Message "Expected .bot/go.ps1 in files, got $($delResult.files -join ', ')"
        Rename-Item (Join-Path $fiTestDir ".bot/go.ps1.bak") (Join-Path $fiTestDir ".bot/go.ps1")

        # ── Test-DotbotManifest: missing manifest ──

        $savedManifest = Get-Content $mfPath -Raw
        Remove-Item $mfPath -Force
        $missingResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest missing-manifest: reason=missing-manifest" `
            -Condition ($missingResult.reason -eq 'missing-manifest') `
            -Message "Expected reason=missing-manifest, got $($missingResult.reason)"
        # Restore
        [System.IO.File]::WriteAllText($mfPath, $savedManifest, [System.Text.UTF8Encoding]::new($false))

        # ── Test-FrameworkIntegrity: pre-first-commit (no git history) ──

        $preCommitResult = Test-FrameworkIntegrity
        Assert-True -Name "Test-FrameworkIntegrity pre-first-commit: success=true" `
            -Condition ($preCommitResult.success -eq $true) `
            -Message "Expected success for pre-first-commit, got reason=$($preCommitResult.reason)"
        Assert-True -Name "Test-FrameworkIntegrity pre-first-commit: reason=pre-first-commit" `
            -Condition ($preCommitResult.reason -eq 'pre-first-commit') `
            -Message "Expected reason=pre-first-commit, got $($preCommitResult.reason)"

        # ── Test-FrameworkIntegrity: clean (after commit) ──

        & git add -A 2>$null
        & git commit -m "init" --quiet 2>$null
        $cleanInteg = Test-FrameworkIntegrity
        Assert-True -Name "Test-FrameworkIntegrity clean: success=true" `
            -Condition ($cleanInteg.success -eq $true) `
            -Message "Expected success, got reason=$($cleanInteg.reason) message=$($cleanInteg.message)"
        Assert-True -Name "Test-FrameworkIntegrity clean: reason=clean" `
            -Condition ($cleanInteg.reason -eq 'clean') `
            -Message "Expected reason=clean, got $($cleanInteg.reason)"

        # ── Test-FrameworkIntegrity: tampered (uncommitted edit) ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# TAMPERED" -Encoding UTF8
        $tamperedInteg = Test-FrameworkIntegrity
        Assert-True -Name "Test-FrameworkIntegrity tampered: success=false" `
            -Condition ($tamperedInteg.success -eq $false) `
            -Message "Expected failure for tampered file"
        Assert-True -Name "Test-FrameworkIntegrity tampered: reason=tampered" `
            -Condition ($tamperedInteg.reason -eq 'tampered') `
            -Message "Expected reason=tampered, got $($tamperedInteg.reason)"
        & git checkout -- ".bot/go.ps1" 2>$null

        # ── Invoke-FrameworkIntegrityGate: passes on clean ──

        $gateClean = Invoke-FrameworkIntegrityGate -ProjectRoot $fiTestDir
        Assert-True -Name "Invoke-FrameworkIntegrityGate clean: returns null" `
            -Condition ($null -eq $gateClean) `
            -Message "Expected null for clean state, got $($gateClean | ConvertTo-Json -Compress)"

        # ── Invoke-FrameworkIntegrityGate: blocks on tampered ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# TAMPERED" -Encoding UTF8
        $gateBlocked = Invoke-FrameworkIntegrityGate -ProjectRoot $fiTestDir -TaskId 'test-123'
        Assert-True -Name "Invoke-FrameworkIntegrityGate tampered: returns hashtable" `
            -Condition ($null -ne $gateBlocked) `
            -Message "Expected a blocking hashtable for tampered state"
        Assert-True -Name "Invoke-FrameworkIntegrityGate tampered: success=false" `
            -Condition ($gateBlocked.success -eq $false) `
            -Message "Expected success=false"
        Assert-True -Name "Invoke-FrameworkIntegrityGate tampered: includes task_id" `
            -Condition ($gateBlocked.task_id -eq 'test-123') `
            -Message "Expected task_id=test-123, got $($gateBlocked.task_id)"

    } finally {
        Pop-Location
        if (Test-Path $fiTestDir) { Remove-Item $fiTestDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-TestResult -Name "Framework integrity tests" -Status Skip -Message "Manifest.psm1 or FrameworkIntegrity.psm1 not found"
}

# ═══════════════════════════════════════════════════════════════════
# INBOX WATCHER MODULE TESTS
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- InboxWatcher Module ---" -ForegroundColor Cyan

$inboxWatcherModule = Join-Path $botDir "systems\ui\modules\InboxWatcher.psm1"

if (Test-Path $inboxWatcherModule) {
    # DotBotLog may have been removed by the preceding DotBotLog test section — re-import it
    if (-not (Get-Module DotBotLog)) {
        if (Test-Path $dotBotLogModule) { Import-Module $dotBotLogModule -Force }
    }

    $inboxTestRoot = Join-Path ([IO.Path]::GetTempPath()) "inbox-watcher-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        # ── Scaffolding ──────────────────────────────────────────────────
        $inboxBotRoot  = Join-Path $inboxTestRoot ".bot"
        $settingsDir   = Join-Path $inboxBotRoot "settings"
        $controlDir    = Join-Path $inboxBotRoot ".control"
        $inboxFolder   = Join-Path $inboxBotRoot "workspace" "inbox"
        $logPath       = Join-Path $controlDir "logs" "inbox-watcher.log"

        foreach ($dir in @($settingsDir, $controlDir, $inboxFolder)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $defaultSettingsPath  = Join-Path $settingsDir "settings.default.json"
        $overrideSettingsPath = Join-Path $controlDir "settings.json"

        function Write-InboxSettings {
            param([object]$Config)
            $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $defaultSettingsPath -Encoding UTF8
        }

        function Reset-InboxWatcher {
            try { Stop-InboxWatcher } catch {}
            Remove-Module InboxWatcher -ErrorAction SilentlyContinue
            Import-Module $inboxWatcherModule -Force
        }

        # Test 1. Config guard-rails — missing file, disabled, empty watchers, malformed JSON ─
        # None of these reach initialization so $Initialized never flips; one Reset at the end suffices.
        Import-Module $inboxWatcherModule -Force

        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op when settings file is missing" -Condition (-not $threw)

        Write-InboxSettings @{ file_listener = @{ enabled = $false; watchers = @() } }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op when file_listener is disabled" -Condition (-not $threw)

        Write-InboxSettings @{ file_listener = @{ enabled = $true; watchers = @() } }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op when watchers list is empty" -Condition (-not $threw)

        "{ not valid json" | Set-Content -LiteralPath $defaultSettingsPath -Encoding UTF8
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op on malformed settings JSON" -Condition (-not $threw)

        Reset-InboxWatcher

        # Test 2. Override resilience — invalid override falls back; valid override replaces defaults ─
        Write-InboxSettings @{ file_listener = @{ enabled = $false; watchers = @() } }
        "{ bad" | Set-Content -LiteralPath $overrideSettingsPath -Encoding UTF8
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Override: invalid .control/settings.json falls back to defaults without throw" `
            -Condition (-not $threw)
        Remove-Item -LiteralPath $overrideSettingsPath -ErrorAction SilentlyContinue
        Reset-InboxWatcher

        Write-InboxSettings @{ file_listener = @{ enabled = $false; watchers = @() } }
        @{ file_listener = @{ enabled = $true; watchers = @() } } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $overrideSettingsPath -Encoding UTF8
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Override: valid .control/settings.json overrides disabled default without throw" `
            -Condition (-not $threw)
        Remove-Item -LiteralPath $overrideSettingsPath -ErrorAction SilentlyContinue
        Reset-InboxWatcher

        # Test 3. Path security — rooted path and path traversal both rejected silently ─────────
        $rootedPath = if ($IsWindows) { 'C:\Windows' } else { '/etc' }
        Write-InboxSettings @{
            file_listener = @{
                enabled  = $true
                watchers = @(
                    @{ folder = $rootedPath; events = @('created') }
                    @{ folder = '../../etc'; events = @('created') }
                )
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Security: rooted path and path-traversal folder both rejected without throw" `
            -Condition (-not $threw)
        Reset-InboxWatcher

        # Test 4. Folder & event validation — nonexistent folder skipped; unknown event warned ──
        Write-InboxSettings @{
            file_listener = @{
                enabled  = $true
                watchers = @(
                    @{ folder = 'does-not-exist'; events = @('created') }
                    @{ folder = 'inbox';          events = @('create')  }   # typo: 'create' not 'created'
                )
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Validation: nonexistent folder and unknown event type both skip without throw" `
            -Condition (-not $threw)
        Reset-InboxWatcher

        # Test 5. Config defaults — non-numeric max_concurrent and coalesce_window fall back ─────
        Write-InboxSettings @{
            file_listener = @{
                enabled                 = $true
                max_concurrent          = "bad"
                coalesce_window_seconds = "bad"
                watchers                = @(@{ folder = 'inbox'; events = @('created') })
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Defaults: non-numeric max_concurrent and coalesce_window fall back without throw" `
            -Condition (-not $threw)
        Reset-InboxWatcher

        # Test 6. Worker startup — valid config spawns worker, creates log, writes startup entry ─
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
        Write-InboxSettings @{
            file_listener = @{
                enabled  = $true
                watchers = @(@{ folder = 'inbox'; events = @('created') })
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Startup: worker starts for valid config without throw" -Condition (-not $threw)

        Start-Sleep -Milliseconds 600   # let worker runspace write its startup log entry
        Assert-True -Name "Startup: log file created by worker runspace" `
            -Condition (Test-Path -LiteralPath $logPath)
        if (Test-Path -LiteralPath $logPath) {
            $startupLog = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
            Assert-True -Name "Startup: log contains 'Worker started' message" `
                -Condition ($startupLog -match 'Worker started') `
                -Message "Expected 'Worker started' in log"
        }

        # Test 7. Lifecycle — re-entrancy guard, stop cleans up, re-init after stop ─────────────
        # Continues with the running worker from Test 6; no reset needed.
        $linesBefore = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue).Count
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Start-Sleep -Milliseconds 300
        $linesAfter = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue).Count
        Assert-True -Name "Lifecycle: re-entrancy guard — second init spawns no additional workers" `
            -Condition ($linesAfter -eq $linesBefore) `
            -Message "Log grew after 2nd init: before=$linesBefore after=$linesAfter"

        $threw = $false
        try { Stop-InboxWatcher } catch { $threw = $true }
        Assert-True -Name "Lifecycle: Stop-InboxWatcher cleans up without throw" -Condition (-not $threw)

        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Lifecycle: re-init after stop succeeds (Initialized flag reset)" -Condition (-not $threw)
        Stop-InboxWatcher

        # ═══════════════════════════════════════════════════════════════
        # Behavioral tests — stub launcher satisfies the Test-Path guard
        # without needing a real dotbot install.
        # ═══════════════════════════════════════════════════════════════
        $stubLauncherDir = Join-Path $inboxBotRoot "systems" "runtime"
        $null = New-Item -ItemType Directory -Force -Path $stubLauncherDir
        "# test stub — exits immediately" |
            Set-Content -LiteralPath (Join-Path $stubLauncherDir "launch-process.ps1") -Encoding UTF8

        $launchersDir = Join-Path $controlDir "launchers"

        function Get-NewLog {
            param([int]$After = 0)
            if (-not (Test-Path -LiteralPath $logPath)) { return '' }
            $lines = Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue
            if ($null -eq $lines -or $After -ge $lines.Count) { return '' }
            ($lines[$After..($lines.Count - 1)]) -join "`n"
        }
        function Get-LogLineCount {
            if (-not (Test-Path -LiteralPath $logPath)) { return 0 }
            @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue).Count
        }

        $behavSettings = @{
            file_listener = @{
                enabled                 = $true
                coalesce_window_seconds = 1
                watchers                = @(@{ folder = 'inbox'; events = @('created') })
            }
        }

        # Test 8. File detection + launcher creation ──────────────────────────────────────────
        # Worst-case timing: 2s WaitForChanged timeout + 1s coalesce + 2s next timeout + 2s buffer = 7s
        Write-InboxSettings $behavSettings
        Reset-InboxWatcher
        Initialize-InboxWatcher -BotRoot $inboxBotRoot
        Start-Sleep -Milliseconds 600   # let runspace reach WaitForChanged before dropping file
        $mark8 = Get-LogLineCount

        'hello' | Set-Content -LiteralPath (Join-Path $inboxFolder "detect-test.txt") -Encoding UTF8
        Start-Sleep -Seconds 7

        $log8 = Get-NewLog -After $mark8
        Assert-True -Name "Detection: worker detects and queues a newly created file" `
            -Condition ($log8 -match 'Queued.*detect-test\.txt') `
            -Message "Expected 'Queued.*detect-test.txt'; log: $log8"
        Assert-True -Name "Detection: task-creation launched after coalesce window" `
            -Condition ($log8 -match 'Launched:') `
            -Message "Expected 'Launched:' in log; got: $log8"
        $launchers8 = @(Get-ChildItem -Path $launchersDir -Filter "inbox-launcher-*.ps1" -File -ErrorAction SilentlyContinue)
        Assert-True -Name "Detection: inbox-launcher-*.ps1 wrapper created in .control/launchers/" `
            -Condition ($launchers8.Count -gt 0) `
            -Message "Expected inbox-launcher-*.ps1 in $launchersDir"
        if ($launchers8.Count -gt 0) {
            $wc8 = Get-Content -LiteralPath $launchers8[0].FullName -Raw -ErrorAction SilentlyContinue
            Assert-True -Name "Detection: launcher wrapper invokes launch-process.ps1 with -Type task-creation" `
                -Condition ($wc8 -match 'launch-process\.ps1' -and $wc8 -match 'task-creation') `
                -Message "Wrapper missing launch-process.ps1 or task-creation; content: $wc8"
        }
        Stop-InboxWatcher
        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # Test 9. Debounce + coalescing — shared watcher, two sequential sub-scenarios ──────────
        Write-InboxSettings @{
            file_listener = @{
                enabled                 = $true
                coalesce_window_seconds = 1
                watchers                = @(@{ folder = 'inbox'; events = @('created', 'updated') })
            }
        }
        Reset-InboxWatcher
        Initialize-InboxWatcher -BotRoot $inboxBotRoot
        Start-Sleep -Milliseconds 600

        # Sub-case A: same file touched twice within 5 s → only one Queued entry (debounced)
        $mark9a = Get-LogLineCount
        $debounceFile = Join-Path $inboxFolder "dedup.txt"
        'v1' | Set-Content -LiteralPath $debounceFile -Encoding UTF8    # first event — queued
        Start-Sleep -Milliseconds 800                                    # well within 5 s debounce window
        'v2' | Set-Content -LiteralPath $debounceFile -Encoding UTF8    # second event — debounced
        Start-Sleep -Seconds 7
        $log9a = Get-NewLog -After $mark9a
        Assert-True -Name "Debounce: same file touched twice within 5 s produces only one Queued entry" `
            -Condition (([regex]::Matches($log9a, 'Queued.*dedup\.txt')).Count -eq 1) `
            -Message "Expected 1 Queued entry for dedup.txt; log: $log9a"

        # Sub-case B: three files in quick succession → single batch launch for all three
        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $mark9b = Get-LogLineCount
        'a' | Set-Content -LiteralPath (Join-Path $inboxFolder "batch-a.txt") -Encoding UTF8
        Start-Sleep -Milliseconds 200
        'b' | Set-Content -LiteralPath (Join-Path $inboxFolder "batch-b.txt") -Encoding UTF8
        Start-Sleep -Milliseconds 200
        'c' | Set-Content -LiteralPath (Join-Path $inboxFolder "batch-c.txt") -Encoding UTF8
        Start-Sleep -Seconds 7
        $log9b = Get-NewLog -After $mark9b
        Assert-True -Name "Coalescing: three quick files trigger a single batch launch" `
            -Condition (([regex]::Matches($log9b, 'Launching task-creation')).Count -eq 1) `
            -Message "Expected 1 batch launch; log: $log9b"
        Assert-True -Name "Coalescing: batch launch reports all three files" `
            -Condition ($log9b -match 'Launching task-creation for 3 file') `
            -Message "Expected 'for 3 file' in launch log; got: $log9b"

        Stop-InboxWatcher
        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # Test 10. Filename sanitization + stop boundary ──────────────────────────────────────
        Write-InboxSettings $behavSettings
        Reset-InboxWatcher
        Initialize-InboxWatcher -BotRoot $inboxBotRoot
        Start-Sleep -Milliseconds 600

        # Sub-case A: backtick and dollar in filename are replaced with underscore in wrapper
        $mark10a = Get-LogLineCount
        $unsafeFile = Join-Path $inboxFolder 'test`$name.txt'
        'payload' | Set-Content -LiteralPath $unsafeFile -Encoding UTF8
        Start-Sleep -Seconds 7
        $log10a = Get-NewLog -After $mark10a
        Assert-True -Name "Sanitization: file with backtick and dollar is detected and queued" `
            -Condition ($log10a -match 'Queued') `
            -Message "Expected file to be detected; log: $log10a"
        $wrappers10 = @(Get-ChildItem -Path $launchersDir -Filter "inbox-launcher-*.ps1" -File -ErrorAction SilentlyContinue)
        if ($wrappers10.Count -gt 0) {
            $wc10 = Get-Content -LiteralPath $wrappers10[0].FullName -Raw -ErrorAction SilentlyContinue
            Assert-True -Name "Sanitization: wrapper replaces backtick and dollar with underscore" `
                -Condition ($wc10 -match 'test__name\.txt') `
                -Message "Expected 'test__name.txt' in wrapper; got: $wc10"
        } else {
            Write-TestResult -Name "Sanitization: wrapper replaces backtick and dollar with underscore" `
                -Status Skip -Message "No launcher wrapper found (file detection may have failed)"
        }

        # Sub-case B: no worker activity after Stop-InboxWatcher
        Stop-InboxWatcher
        Start-Sleep -Milliseconds 400   # let runspace fully exit
        $mark10b = Get-LogLineCount
        'payload' | Set-Content -LiteralPath (Join-Path $inboxFolder "after-stop.txt") -Encoding UTF8
        Start-Sleep -Seconds 6
        $log10b = Get-NewLog -After $mark10b
        Assert-True -Name "Stop boundary: no file events logged after Stop-InboxWatcher" `
            -Condition (-not ($log10b -match 'Queued|Launching')) `
            -Message "Worker still active after stop; new log: $log10b"

        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

    } finally {
        try { Stop-InboxWatcher } catch {}
        Remove-Module InboxWatcher -ErrorAction SilentlyContinue
        if ($inboxTestRoot -and (Test-Path $inboxTestRoot)) {
            Remove-Item $inboxTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-TestResult -Name "InboxWatcher module exists" -Status Skip -Message "Module not found at $inboxWatcherModule"
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
