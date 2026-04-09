<#
.SYNOPSIS
Unified process launcher replacing both loop scripts and ad-hoc Start-Job calls.

.DESCRIPTION
Every Claude invocation is a tracked process. Creates a process registry entry,
builds the appropriate prompt, invokes Claude, and manages the lifecycle.

.PARAMETER Type
Process type: analysis, execution, kickstart, planning, commit, task-creation

.PARAMETER TaskId
Optional: specific task ID (for analysis/execution types)

.PARAMETER Prompt
Optional: custom prompt text (for kickstart/planning/commit/task-creation)

.PARAMETER Continue
If set, continue to next task after completion (analysis/execution only)

.PARAMETER Model
Claude model to use (default: Opus)

.PARAMETER ShowDebug
Show raw JSON events

.PARAMETER ShowVerbose
Show detailed tool results

.PARAMETER MaxTasks
Max tasks to process with -Continue (0 = unlimited)

.PARAMETER Description
Human-readable description for UI display

.PARAMETER ProcessId
Optional: resume an existing process by ID (skips creation)

.PARAMETER NoWait
If set with -Continue, exit when no tasks available instead of waiting.
Used by kickstart pipeline to prevent workflow children from blocking phase progression.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('analysis', 'execution', 'task-runner', 'kickstart', 'analyse', 'planning', 'commit', 'task-creation')]
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
    [switch]$NeedsInterview,
    [switch]$AutoWorkflow,
    [switch]$NoWait,
    [string]$FromPhase,
    [string]$SkipPhases,  # comma-separated phase IDs to skip
    [string]$Workflow,    # filter task queue to this workflow name
    [ValidateRange(-1, 16)]
    [int]$Slot = -1       # concurrent slot index (-1 = single instance, 0..N = multi-slot)
)

Set-StrictMode -Version 1.0

# Parse skip phases
$skipPhaseIds = if ($SkipPhases) { $SkipPhases -split ',' } else { @() }

# --- Configuration ---

# Determine phase for activity logging
$phaseMap = @{
    'analysis'      = 'analysis'
    'execution'     = 'execution'
    'task-runner'   = 'task-runner'
    'kickstart'     = 'execution'
    'analyse'       = 'execution'
    'planning'      = 'execution'
    'commit'        = 'execution'
    'task-creation' = 'execution'
}

$env:DOTBOT_CURRENT_PHASE = $phaseMap[$Type]

# Resolve paths
$botRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$controlDir = Join-Path $botRoot ".control"
$processesDir = Join-Path $controlDir "processes"
$projectRoot = Split-Path -Parent $botRoot
$global:DotbotProjectRoot = $projectRoot

# Ensure directories exist
if (-not (Test-Path $processesDir)) {
    New-Item -Path $processesDir -ItemType Directory -Force | Out-Null
}
$logsDir = Join-Path $controlDir "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
}

# Import DotBotLog FIRST — before all other modules so they can use Write-BotLog
Import-Module "$PSScriptRoot\modules\DotBotLog.psm1" -Force -DisableNameChecking
Initialize-DotBotLog -LogDir $logsDir -ControlDir $controlDir -ProjectRoot $projectRoot

# Validate TaskId format when provided (after DotBotLog import so we can log properly)
if ($TaskId -and $TaskId -notmatch '^[a-f0-9]{8}$') {
    Write-BotLog -Level Warn -Message "TaskId '$TaskId' does not match expected format (8-char hex). Proceeding anyway."
}

# Import modules
Import-Module "$PSScriptRoot\ProviderCLI\ProviderCLI.psm1" -Force
Import-Module "$PSScriptRoot\modules\DotBotTheme.psm1" -Force
Import-Module "$PSScriptRoot\modules\InstanceId.psm1" -Force
$t = Get-DotBotTheme

# Set canonical version from version.json (available to all child scripts)
if (-not $env:DOTBOT_VERSION) {
    $versionFile = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'version.json'
    if (Test-Path $versionFile) {
        try { $env:DOTBOT_VERSION = (Get-Content $versionFile -Raw | ConvertFrom-Json).version } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
    }
}

. "$PSScriptRoot\modules\prompt-builder.ps1"
. "$PSScriptRoot\modules\rate-limit-handler.ps1"

# Import task-based modules for analysis/execution/workflow types
if ($Type -in @('analysis', 'execution', 'task-runner')) {
    Import-Module "$PSScriptRoot\..\mcp\modules\TaskIndexCache.psm1" -Force
    Import-Module "$PSScriptRoot\..\mcp\modules\SessionTracking.psm1" -Force
    . "$PSScriptRoot\modules\cleanup.ps1"
    . "$PSScriptRoot\modules\get-failure-reason.ps1"
    Import-Module "$PSScriptRoot\modules\WorktreeManager.psm1" -Force
    . "$PSScriptRoot\modules\test-task-completion.ps1"

    # MCP tool functions — load ALL tools dynamically (includes workflow-specific ones)
    $mcpToolsDir = Join-Path $PSScriptRoot "..\mcp\tools"
    Get-ChildItem -Path $mcpToolsDir -Directory | ForEach-Object {
        $toolScript = Join-Path $_.FullName "script.ps1"
        if (Test-Path $toolScript) { . $toolScript }
    }
}

# Load settings for model defaults
$settingsPath = Join-Path $botRoot "settings\settings.default.json"
$settings = @{ execution = @{ model = 'Opus' }; analysis = @{ model = 'Opus' } }
if (Test-Path $settingsPath) {
    try { $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json } catch { Write-BotLog -Level Warn -Message "Failed to load settings" -Exception $_ }
}

# Re-initialize structured logging with actual settings
$logSettings = $settings.logging
if ($logSettings) {
    Initialize-DotBotLog -LogDir $logsDir -ControlDir $controlDir -ProjectRoot $projectRoot `
        -FileLevel ($logSettings.file_level ?? 'Debug') `
        -ConsoleLevel ($logSettings.console_level ?? 'Info') `
        -RetentionDays ($logSettings.retention_days ?? 7) `
        -MaxFileSizeMB ($logSettings.max_file_size_mb ?? 50) `
        -FileRetryCount ($settings.operations.file_retry_count ?? 3) `
        -FileRetryBaseMs ($settings.operations.file_retry_base_ms ?? 50)
}

# Workspace instance ID (stable per .bot workspace).
# For legacy projects missing this field, create and persist one.
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

# Load provider config
$providerConfig = Get-ProviderConfig

# Resolve permission mode (ui-settings > settings.default > provider default)
$permissionMode = $null
if ($uiSettings -and $uiSettings.permissionMode) {
    $permissionMode = $uiSettings.permissionMode
} elseif ($settings.permission_mode) {
    $permissionMode = $settings.permission_mode
}
if ($permissionMode -and $providerConfig.permission_modes -and -not $providerConfig.permission_modes.$permissionMode) {
    Write-BotLog -Level Warn -Message "Permission mode '$permissionMode' not valid for active provider. Using provider default."
    $permissionMode = $null
}
if (-not $permissionMode -and $providerConfig.default_permission_mode) {
    $permissionMode = $providerConfig.default_permission_mode
}

# Resolve model (parameter > settings > provider default)
if (-not $Model) {
    $Model = switch ($Type) {
        { $_ -in @('analysis', 'kickstart') } { if ($settings.analysis?.model) { $settings.analysis.model } else { $providerConfig.default_model } }
        'task-runner' { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
        default    { if ($settings.execution?.model) { $settings.execution.model } else { $providerConfig.default_model } }
    }
}

try {
    $claudeModelName = Resolve-ProviderModelId -ModelAlias $Model
} catch {
    Write-BotLog -Level Warn -Message "Model '$Model' not valid for active provider. Falling back to '$($providerConfig.default_model)'."
    $claudeModelName = Resolve-ProviderModelId -ModelAlias $providerConfig.default_model
}
# Validate model against permission mode restrictions (e.g. Haiku excluded in auto mode)
if ($permissionMode -and $providerConfig.permission_modes -and $providerConfig.permission_modes.$permissionMode) {
    $modeConfig = $providerConfig.permission_modes.$permissionMode
    if ($modeConfig.restrictions -and $modeConfig.restrictions.excluded_models) {
        $excluded = @($modeConfig.restrictions.excluded_models)
        if ($Model -in $excluded) {
            Write-BotLog -Level Warn -Message "Model '$Model' is not supported with permission mode '$permissionMode'. Remapping to '$($providerConfig.default_model)'."
            $Model = $providerConfig.default_model
            $claudeModelName = Resolve-ProviderModelId -ModelAlias $Model
        }
    }
}

$env:CLAUDE_MODEL = $claudeModelName
$env:DOTBOT_MODEL = $claudeModelName

# --- Process Registry (module) ---
Import-Module "$PSScriptRoot\modules\ProcessRegistry.psm1" -Force
Initialize-ProcessRegistry `
    -ProcessesDir $processesDir `
    -ControlDir $controlDir `
    -Settings $settings `
    -ProviderConfig $providerConfig `
    -BotRoot $botRoot

# --- Interview Loop (dot-sourced for kickstart) ---
. "$PSScriptRoot\modules\InterviewLoop.ps1"

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
if (-not (Acquire-ProcessLock -LockType $lockKey)) {
    $lockPath = Join-Path $controlDir "launch-$lockKey.lock"
    $existingPid = if (Test-Path $lockPath) { (Get-Content $lockPath -Raw -ErrorAction SilentlyContinue)?.Trim() } else { "unknown" }
    Write-BotLog -Level Warn -Message "Another $lockKey process is already running (PID $existingPid). Exiting."
    exit 1
}

# --- Initialize Process ---
$sessionId = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH-mm-ssZ")
$claudeSessionId = New-ProviderSession

# Set process ID and correlation ID env vars for structured logging
$env:DOTBOT_PROCESS_ID = $procId
if (-not $env:DOTBOT_CORRELATION_ID) {
    $env:DOTBOT_CORRELATION_ID = "corr-$([guid]::NewGuid().ToString().Substring(0,8))"
}

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
    description     = $Description
    phases          = @()
    skip_phases     = $skipPhaseIds
}

Write-ProcessFile -Id $procId -Data $processData

# Initialize diagnostic log (update module with diag path now that procId is known)
$script:diagLogPath = Join-Path $controlDir "diag-$procId.log"
Initialize-ProcessRegistry `
    -ProcessesDir $processesDir `
    -ControlDir $controlDir `
    -DiagLogPath $script:diagLogPath `
    -Settings $settings `
    -ProviderConfig $providerConfig `
    -BotRoot $botRoot
Write-Diag "=== Process started: Type=$Type, ProcId=$procId, PID=$PID, Continue=$Continue, NoWait=$NoWait ==="
Write-Diag "BotRoot=$botRoot | ProcessesDir=$processesDir | ProjectRoot=$projectRoot"
$procFilePath = Join-Path $processesDir "$procId.json"
Write-Diag "Process file exists: $(Test-Path $procFilePath) at $procFilePath"

# Banner
Write-Card -Title "PROCESS: $($Type.ToUpper())" -Width 50 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines @(
    "$($t.Label)ID:$($t.Reset)    $($t.Cyan)$procId$($t.Reset)"
    "$($t.Label)Model:$($t.Reset) $($t.Purple)$Model$($t.Reset)"
    "$($t.Label)Type:$($t.Reset)  $($t.Amber)$Type$($t.Reset)"
)

Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId started ($Type)"
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Preflight OK: $($preflight.checks -join '; ')"



# --- Task-based types: analysis/execution ---
if ($Type -in @('analysis', 'execution', 'analyse')) {
    $ctx = @{
        Type           = $Type
        BotRoot        = $botRoot
        ProcId         = $procId
        ProcessData    = $processData
        ModelName      = $claudeModelName
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
        PermissionMode = $permissionMode
    }
    if ($Type -in @('analysis', 'analyse')) {
        & "$PSScriptRoot\modules\ProcessTypes\Invoke-AnalysisProcess.ps1" -Context $ctx
    } else {
        & "$PSScriptRoot\modules\ProcessTypes\Invoke-ExecutionProcess.ps1" -Context $ctx
    }
} # --- Task Runner type: unified analyse-then-execute per task ---
elseif ($Type -eq 'task-runner') {
    $ctx = @{
        Type           = $Type
        BotRoot        = $botRoot
        ProcId         = $procId
        ProcessData    = $processData
        ModelName      = $claudeModelName
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
        PermissionMode = $permissionMode
    }
    & "$PSScriptRoot\modules\ProcessTypes\Invoke-WorkflowProcess.ps1" -Context $ctx
} # --- Kickstart type: three-phase product setup ---
elseif ($Type -eq 'kickstart') {
    $ctx = @{
        Type           = $Type
        BotRoot        = $botRoot
        ProcId         = $procId
        ProcessData    = $processData
        ModelName      = $claudeModelName
        SessionId      = $claudeSessionId
        Prompt         = $Prompt
        Description    = $Description
        ShowDebug      = [bool]$ShowDebug
        ShowVerbose    = [bool]$ShowVerbose
        ProjectRoot    = $projectRoot
        ControlDir     = $controlDir
        Settings       = $settings
        Model          = $Model
        NeedsInterview = [bool]$NeedsInterview
        FromPhase      = $FromPhase
        SkipPhaseIds   = $skipPhaseIds
        PermissionMode = $permissionMode
    }
    & "$PSScriptRoot\modules\ProcessTypes\Invoke-KickstartProcess.ps1" -Context $ctx
} # --- Prompt-based types: planning, commit, task-creation ---
elseif ($Type -in @('planning', 'commit', 'task-creation')) {
    $ctx = @{
        Type        = $Type
        BotRoot     = $botRoot
        ProcId      = $procId
        ProcessData = $processData
        ModelName   = $claudeModelName
        SessionId   = $claudeSessionId
        Prompt      = $Prompt
        Description = $Description
        ShowDebug      = [bool]$ShowDebug
        ShowVerbose    = [bool]$ShowVerbose
        PermissionMode = $permissionMode
    }
    & "$PSScriptRoot\modules\ProcessTypes\Invoke-PromptProcess.ps1" -Context $ctx
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
