<#
.SYNOPSIS
Unified process launcher. Tracks every Claude invocation as a process and
dispatches to the right engine based on Type.

.DESCRIPTION
Creates a process registry entry, builds the appropriate prompt, invokes
Claude, and manages the lifecycle. After PR-3 the only execution engine is
the task-runner; legacy analysis/execution types are gone.

.PARAMETER Type
Process type. One of: task-runner, planning, commit, task-creation.
- task-runner: continuous analyse-then-execute loop over tasks (used for
  workflow runs and pending-tasks runs).
- planning, commit, task-creation: single-prompt processes.

.PARAMETER TaskId
Optional: pin the task-runner to a specific task ID (8-char hex).

.PARAMETER Prompt
Optional: custom prompt text for the planning / commit / task-creation
single-prompt processes.

.PARAMETER Continue
If set, the task-runner keeps picking up tasks until none remain. Without
it, the runner exits after one task.

.PARAMETER Model
Model tier (fast, balanced, best). Defaults to settings.execution.model.

.PARAMETER ShowDebug
Show raw JSON stream events.

.PARAMETER ShowVerbose
Show detailed tool results.

.PARAMETER MaxTasks
Max tasks to process with -Continue (0 = unlimited).

.PARAMETER Description
Human-readable description for UI display.

.PARAMETER ProcessId
Optional: resume an existing process by ID (skips creation).

.PARAMETER NoWait
If set with -Continue, exit when no tasks are available instead of waiting.
Used so wrapper scripts can chain multiple task-runner invocations without
the inner one blocking on an empty queue.

.PARAMETER Workflow
Optional: filter the task queue to a single workflow name.

.PARAMETER Slot
Concurrent slot index. -1 = single instance (default); 0..N = multi-slot.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('task-runner', 'planning', 'commit', 'task-creation')]
    [string]$Type,

    [string]$TaskId,
    [string]$Prompt,
    [switch]$Continue,
    [string]$Model,
    [switch]$ShowDebug,
    [switch]$ShowVerbose,
    [int]$MaxTasks = 0,
    [string]$Description,
    [string]$ProcessId,
    [switch]$NoWait,
    [string]$Workflow,    # filter task queue to this workflow name
    [string]$RunId,       # WorkflowRun ID — scopes the runner to one run's tasks
    [ValidateRange(-1, 16)]
    [int]$Slot = -1       # concurrent slot index (-1 = single instance, 0..N = multi-slot)
)

Set-StrictMode -Version 1.0

# Reset DOTBOT_CORRELATION_ID per launch. Without this, child processes
# inherit the parent's value via the environment, so Write-BotLog calls in
# this run leak the previous process's correlation_id into activity events.
$env:DOTBOT_CORRELATION_ID = "corr-$([guid]::NewGuid().ToString().Substring(0,8))"

# --- Configuration ---

# Determine phase for activity logging
$phaseMap = @{
    'task-runner'   = 'task-runner'
    'planning'      = 'execution'
    'commit'        = 'execution'
    'task-creation' = 'execution'
}

$env:DOTBOT_CURRENT_PHASE = $phaseMap[$Type]

# Resolve paths
Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$botRoot = Get-DotbotProjectBotPath
$controlDir = Join-Path $botRoot ".control"
$processesDir = Join-Path $controlDir "processes"
$projectRoot = Get-DotbotProjectPath
$global:DotbotProjectRoot = $projectRoot
# Dot-sourced MCP tools resolve their target runtime from $global:DotbotBotRoot.
$global:DotbotBotRoot = $botRoot

# Ensure directories exist
if (-not (Test-Path $processesDir)) {
    New-Item -Path $processesDir -ItemType Directory -Force | Out-Null
}
$logsDir = Join-Path $controlDir "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
}

# Import Dotbot.Logging FIRST — before all other modules so they can use Write-BotLog.
# The module auto-bootstraps via Get-DotbotProjectBotPath on first Write-BotLog call;
# we reconfigure later with settings-driven file/console levels & retention.
Import-Module "$PSScriptRoot\..\Modules\Dotbot.Logging\Dotbot.Logging.psd1" -Force -DisableNameChecking

# Validate TaskId format when provided (after DotbotLog import so we can log properly)
if ($TaskId -and $TaskId -notmatch '^[a-f0-9]{8}$') {
    Write-BotLog -Level Warn -Message "TaskId '$TaskId' does not match expected format (8-char hex). Proceeding anyway."
}

# Import modules
Import-Module "$PSScriptRoot\..\Modules\Dotbot.Harness\Dotbot.Harness.psd1" -Force
Import-Module "$PSScriptRoot\..\Modules\Dotbot.Theme\Dotbot.Theme.psd1" -Force
$t = Get-DotbotTheme

# Set canonical version from version.json (available to all child scripts).
# Prefer the project-local version (deployed to .bot/) so per-project installs
# and dev-source runs see their own version; fall back to the user-global copy.
if (-not $env:DOTBOT_VERSION) {
    $projectVersionFile = Join-Path $botRoot 'version.json'
    $installVersionFile = Join-Path (Get-DotbotInstallPath) 'version.json'
    $versionFile = if (Test-Path $projectVersionFile) { $projectVersionFile } else { $installVersionFile }
    if (Test-Path $versionFile) {
        try { $env:DOTBOT_VERSION = (Get-Content $versionFile -Raw | ConvertFrom-Json).version } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
    }
}

# Dotbot.Task contains Build-TaskPrompt + Test-TaskCompletion + recovery helpers;
# Dotbot.Harness contains harness invocation and failure classification.
Import-Module "$PSScriptRoot\..\Modules\Dotbot.Task\Dotbot.Task.psd1" -Force -DisableNameChecking

# Import task-based modules for analysis/execution/workflow types
if ($Type -eq 'task-runner') {
    Import-Module "$PSScriptRoot\..\Modules\Dotbot.SessionTracking\Dotbot.SessionTracking.psd1" -Force
    Import-Module "$PSScriptRoot\..\Modules\Dotbot.Worktree\Dotbot.Worktree.psd1" -Force

    # MCP tool functions — load ALL tools dynamically (includes workflow-specific ones)
    $mcpToolsDir = Join-Path $PSScriptRoot "..\..\mcp\tools"
    Get-ChildItem -Path $mcpToolsDir -Directory | ForEach-Object {
        $toolScript = Join-Path $_.FullName "script.ps1"
        if (Test-Path $toolScript) { . $toolScript }
    }
}

# Load settings via the shared three-tier loader (user-settings.json and .control/settings.json layer on top)
if (-not (Get-Module Dotbot.Settings)) {
    Import-Module "$PSScriptRoot\..\Modules\Dotbot.Settings\Dotbot.Settings.psd1" -DisableNameChecking -Global
}
$settingsPath = Join-Path $botRoot ".control\settings.json"
$settings = Get-MergedSettings -BotRoot $botRoot
if (-not $settings.PSObject.Properties['execution']) {
    $settings | Add-Member -NotePropertyName execution -NotePropertyValue ([pscustomobject]@{ model = 'best' }) -Force
}
if (-not $settings.PSObject.Properties['analysis']) {
    $settings | Add-Member -NotePropertyName analysis -NotePropertyValue ([pscustomobject]@{ model = 'best' }) -Force
}

# Configure structured logging with settings-driven file/console levels & retention.
# Without this call, Write-BotLog still works via the module's auto-bootstrap defaults.
$logSettings = $settings.logging
if ($logSettings) {
    Initialize-DotbotLog -LogDir $logsDir -ControlDir $controlDir -ProjectRoot $projectRoot `
        -FileLevel ($logSettings.file_level ?? 'Debug') `
        -ConsoleLevel ($logSettings.console_level ?? 'Info') `
        -RetentionDays ($logSettings.retention_days ?? 7) `
        -MaxFileSizeMB ($logSettings.max_file_size_mb ?? 50) `
        -FileRetryCount ($settings.operations.file_retry_count ?? 3) `
        -FileRetryBaseMs ($settings.operations.file_retry_base_ms ?? 50)
}

# Workspace instance ID (stable per .bot workspace).
# Persist the per-project instance ID in machine-local control settings.
$settingsDir = Split-Path -Parent $settingsPath
if (-not (Test-Path -LiteralPath $settingsDir)) {
    New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $settingsPath)) {
    '{}' | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}
$instanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
if (-not $instanceId) {
    $instanceId = ""
}

# Override model selections from UI settings (ui-settings.json)
$uiSettings = $null
$uiSettingsPath = Join-Path $botRoot ".control\ui-settings.json"
if (Test-Path $uiSettingsPath) {
    try {
        $uiSettings = Get-Content $uiSettingsPath -Raw | ConvertFrom-Json
        if ($uiSettings.analysisModel) { $settings.analysis.model = $uiSettings.analysisModel }
        if ($uiSettings.executionModel) { $settings.execution.model = $uiSettings.executionModel }
    } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
}

# Load harness config
$providerConfig = Get-HarnessConfig

# Resolve permission mode (ui-settings > settings.default > harness default)
$permissionMode = $null
if ($uiSettings -and $uiSettings.permissionMode) {
    $permissionMode = $uiSettings.permissionMode
} elseif ($settings.permission_mode) {
    $permissionMode = $settings.permission_mode
}
if ($permissionMode -and $providerConfig.permission_modes -and -not $providerConfig.permission_modes.$permissionMode) {
    Write-BotLog -Level Warn -Message "Permission mode '$permissionMode' not valid for active harness. Using harness default."
    $permissionMode = $null
}
if (-not $permissionMode -and $providerConfig.default_permission_mode) {
    $permissionMode = $providerConfig.default_permission_mode
}

# Resolve model (parameter > settings > harness default)
if (-not $Model) {
    $Model = if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model }
}

try {
    $modelTier = Resolve-HarnessModelTier -Model $Model
} catch {
    Write-BotLog -Level Warn -Message "Model '$Model' not valid for active harness. Falling back to '$($providerConfig.default_model)'."
    $modelTier = Resolve-HarnessModelTier -Model $providerConfig.default_model
}
# Validate model against permission mode restrictions.
if (Test-HarnessModelTierExcluded -Config $providerConfig -ModelTier $modelTier -PermissionMode $permissionMode) {
    Write-BotLog -Level Warn -Message "Model tier '$modelTier' is not supported with permission mode '$permissionMode'. Remapping to '$($providerConfig.default_model)'."
    $modelTier = Resolve-HarnessModelTier -Model $providerConfig.default_model
}

$Model = $modelTier
$env:CLAUDE_MODEL = $modelTier
$env:DOTBOT_MODEL = $modelTier
$env:DOTBOT_MODEL_TIER = $modelTier

# --- Process Registry (module) ---
# Dotbot.Process is stateless: each function derives paths from
# Get-DotbotProjectBotPath, which finds .bot/ by walking up from $PWD.
# Callers may pass -BotRoot to override.
Import-Module "$PSScriptRoot\..\Modules\Dotbot.Process\Dotbot.Process.psd1" -Force

# InterviewLoop is imported from Invoke-WorkflowProcess.ps1 (the only consumer
# after the legacy execution engine was removed), so it does not need to be loaded here.

# Early-initialize variables used by the crash trap (must be set before trap registration)
$procId = if ($ProcessId) { $ProcessId } else { New-ProcessId }
$lockKey = if ($Slot -ge 0) { "$Type-$Slot" } else { $Type }

# --- Crash Trap ---
# Catch unexpected termination and persist process state before exit
trap {
    if ((Test-Path variable:procId) -and $procId -and (Test-Path variable:processData) -and $processData -and $processData.status -in @('running', 'starting')) {
        $processData.status = 'stopped'
        $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
        $processData.error = "Unexpected termination: $($_.Exception.Message)"
        try { Write-ProcessFile -Id $procId -Data $processData } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        try { Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process terminated unexpectedly: $($_.Exception.Message)" } catch { Write-BotLog -Level Warn -Message "Failed to write process activity" -Exception $_ }
    }
    if (Test-Path variable:lockKey) {
        try { Remove-ProcessLock -LockType $lockKey } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
    }
}

# --- Preflight checks ---
$preflight = Test-Preflight
if (-not $preflight.passed) {
    Write-BotLog -Level Warn -Message "Preflight checks failed:"
    foreach ($check in $preflight.checks) {
        if ($check -match 'MISSING') { Write-BotLog -Level Warn -Message "  $check" }
    }
    exit 1
}

# --- Single-instance guard (slot-aware) ---
if (-not (Request-ProcessLock -LockType $lockKey)) {
    $lockPath = Join-Path $controlDir "launch-$lockKey.lock"
    $existingPid = if (Test-Path $lockPath) { (Get-Content $lockPath -Raw -ErrorAction SilentlyContinue)?.Trim() } else { "unknown" }
    Write-BotLog -Level Warn -Message "Another $lockKey process is already running (PID $existingPid). Exiting."
    exit 1
}

# --- Initialize Process ---
$sessionId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
$claudeSessionId = New-HarnessSession

# Set process ID env var for structured logging. The correlation ID was
# already reset at the top of the script.
$env:DOTBOT_PROCESS_ID = $procId

$processData = @{
    id              = $procId
    correlation_id  = $env:DOTBOT_CORRELATION_ID
    type            = $Type
    status          = 'starting'
    task_id         = $TaskId
    task_name       = $null
    continue        = [bool]$Continue
    no_wait         = [bool]$NoWait
    model           = $Model
    pid             = $PID
    session_id      = $sessionId
    claude_session_id = $claudeSessionId
    started_at      = (Get-Date).ToUniversalTime().ToString("o")
    last_heartbeat  = (Get-Date).ToUniversalTime().ToString("o")
    heartbeat_status = "Starting $Type process"
    heartbeat_next_action = $null
    last_whisper_index = 0
    completed_at    = $null
    failed_at       = $null
    tasks_completed = 0
    error           = $null
    workflow        = $null
    workflow_name   = if ($Workflow) { $Workflow } else { $null }
    run_id          = if ($RunId) { $RunId } else { $null }
    description     = $Description
    phases          = @()
}

Write-ProcessFile -Id $procId -Data $processData

Write-Diag "=== Process started: Type=$Type, ProcId=$procId, PID=$PID, Continue=$Continue, NoWait=$NoWait ==="
Write-Diag "BotRoot=$botRoot | ProcessesDir=$processesDir | ProjectRoot=$projectRoot"
$procFilePath = Join-Path $processesDir "$procId.json"
Write-Diag "Process file exists: $(Test-Path $procFilePath) at $procFilePath"

# Banner
Write-Card -Title "PROCESS: $($Type.ToUpperInvariant())" -Width 50 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines @(
    "$($t.Label)ID:$($t.Reset)    $($t.Cyan)$procId$($t.Reset)"
    "$($t.Label)Model:$($t.Reset) $($t.Purple)$Model$($t.Reset)"
    "$($t.Label)Type:$($t.Reset)  $($t.Amber)$Type$($t.Reset)"
)

Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId started ($Type)"
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Preflight OK: $($preflight.checks -join '; ')"



# --- Task Runner type: unified analyse-then-execute per task ---
if ($Type -eq 'task-runner') {
    $ctx = @{
        Type           = $Type
        BotRoot        = $botRoot
        ProcId         = $procId
        ProcessData    = $processData
        ModelName      = $modelTier
        SessionId      = $claudeSessionId
        ShowDebug      = [bool]$ShowDebug
        ShowVerbose    = [bool]$ShowVerbose
        ProjectRoot    = $projectRoot
        ProcessesDir   = $processesDir
        ControlDir     = $controlDir
        Settings       = $settings
        Model          = $Model
        BatchSessionId = $sessionId
        InstanceId     = $instanceId
        Continue       = [bool]$Continue
        NoWait         = [bool]$NoWait
        MaxTasks       = $MaxTasks
        TaskId         = $TaskId
        Slot           = $Slot
        Workflow       = $Workflow
        RunId          = $RunId
        PermissionMode = $permissionMode
    }
    & "$PSScriptRoot\Invoke-WorkflowProcess.ps1" -Context $ctx
} # --- Prompt-based types: planning, commit, task-creation ---
elseif ($Type -in @('planning', 'commit', 'task-creation')) {
    $ctx = @{
        Type        = $Type
        BotRoot     = $botRoot
        ProcId      = $procId
        ProcessData = $processData
        ModelName   = $modelTier
        SessionId   = $claudeSessionId
        Prompt      = $Prompt
        Description = $Description
        ShowDebug      = [bool]$ShowDebug
        ShowVerbose    = [bool]$ShowVerbose
        PermissionMode = $permissionMode
    }
    & "$PSScriptRoot\Invoke-PromptProcess.ps1" -Context $ctx
}

# Cleanup env vars
Remove-ProcessLock -LockType $lockKey
$env:DOTBOT_PROCESS_ID = $null
$env:DOTBOT_CURRENT_TASK_ID = $null
$env:DOTBOT_CURRENT_PHASE = $null

# Output process ID for caller to use
Write-BotLog -Level Debug -Message ""
try { Write-Status "Process $procId finished with status: $($processData.status)" -Type Info } catch { Write-BotLog -Level Info -Message "Process $procId finished with status: $($processData.status)" }

# 5-second countdown before window closes
Write-BotLog -Level Debug -Message ""
for ($i = 5; $i -ge 1; $i--) {
    Write-BotLog -Level Info -Message "  Window closing in ${i}s..."
    Start-Sleep -Seconds 1
}
Write-BotLog -Level Debug -Message ""
