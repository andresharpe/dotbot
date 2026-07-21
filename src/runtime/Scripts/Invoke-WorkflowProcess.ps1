<#
.SYNOPSIS
    Workflow (task-runner) process type: unified analyse-then-execute per task.
.DESCRIPTION
    Runs a continuous loop that analyses and then executes each task in sequence.
    Supports concurrent slots, slot stagger/claim guards, and non-prompt task dispatch.
#>

param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

$botRoot = $Context.BotRoot
$procId = $Context.ProcId
$processData = $Context.ProcessData
$modelTier = $Context.ModelName
$claudeSessionId = $Context.SessionId
$ShowDebug = $Context.ShowDebug
$ShowVerbose = $Context.ShowVerbose
$projectRoot = $Context.ProjectRoot
$processesDir = $Context.ProcessesDir
$controlDir = $Context.ControlDir
$settings = $Context.Settings
$Model = $Context.Model
$instanceId = $Context.InstanceId
$Continue = $Context.Continue
$NoWait = $Context.NoWait
$MaxTasks = $Context.MaxTasks
$TaskId = $Context.TaskId
$Slot = $Context.Slot
$RunId = $Context.RunId
$permissionMode = $Context.PermissionMode

$providerCompletionGraceSeconds = 10
if ($settings.execution -and $settings.execution.PSObject.Properties['provider_completion_grace_seconds']) {
    try { $providerCompletionGraceSeconds = [Math]::Max(0, [int]$settings.execution.provider_completion_grace_seconds) } catch { $providerCompletionGraceSeconds = 10 }
}
$providerStopCheckIntervalSeconds = 2
if ($settings.execution -and $settings.execution.PSObject.Properties['provider_stop_check_interval_seconds']) {
    try { $providerStopCheckIntervalSeconds = [Math]::Max(1, [int]$settings.execution.provider_stop_check_interval_seconds) } catch { $providerStopCheckIntervalSeconds = 2 }
}

$tasksBaseDir = Join-Path (Join-Path $botRoot "workspace") "tasks"
$WorkflowName = if ($processData -is [hashtable] -and $processData['workflow_name']) { [string]$processData['workflow_name'] } else { $null }

if (-not (Get-Module Dotbot.TaskInput)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.TaskInput" "Dotbot.TaskInput.psd1") -DisableNameChecking -Global
}

function Get-WorkflowTaskFilePath {
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string]$RunDir
    )

    if ($Task.file_path -and (Test-Path -LiteralPath $Task.file_path -PathType Leaf)) {
        return [string]$Task.file_path
    }

    if ($Task.id) {
        $byName = Join-Path $RunDir "$($Task.id).json"
        if (Test-Path -LiteralPath $byName -PathType Leaf) { return $byName }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $RunDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'run.json' })) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($content.id -eq $Task.id) { return $file.FullName }
        } catch { continue }
    }
    return $null
}

function Get-WorkflowTaskContent {
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string]$RunDir
    )

    $path = Get-WorkflowTaskFilePath -Task $Task -RunDir $RunDir
    if (-not $path) { return $null }
    try {
        return @{
            Path    = $path
            Content = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        }
    } catch {
        Write-BotLog -Level Warn -Message "Failed to read workflow task file '$path'" -Exception $_
        return $null
    }
}

function Get-DotbotObjectProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties[$Name]) { return $Object.PSObject.Properties[$Name].Value }
    return $null
}

function Set-DotbotObjectProperty {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Initialize-DotbotTaskWorktreeForProcess {
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ProcessId,
        [string]$BaseBranch
    )

    Write-Diag "Worktree: required category=$($Task.category)"

    $wtInfo = Get-TaskWorktreeInfo -TaskId $Task.id -BotRoot $BotRoot
    if ($wtInfo -and (Test-Path $wtInfo.worktree_path)) {
        Write-Status "Using worktree: $($wtInfo.worktree_path)" -Type Info
        return @{
            skipped       = $false
            worktree_path = $wtInfo.worktree_path
            branch_name   = $wtInfo.branch_name
            success       = $true
        }
    }

    $guardArgs = @{ ProjectRoot = $ProjectRoot }
    if (-not [string]::IsNullOrWhiteSpace($BaseBranch)) { $guardArgs.BranchName = $BaseBranch }
    try { Assert-OnBaseBranch @guardArgs | Out-Null } catch {
        Write-Status "Branch guard warning: $($_.Exception.Message)" -Type Warn
    }
    $wtResult = New-TaskWorktree -TaskId $Task.id -TaskName $Task.name `
        -ProjectRoot $ProjectRoot -BotRoot $BotRoot -BaseBranch $BaseBranch
    if ($wtResult.success) {
        Write-Status "Worktree: $($wtResult.worktree_path)" -Type Info
        return @{
            skipped       = $false
            worktree_path = $wtResult.worktree_path
            branch_name   = $wtResult.branch_name
            success       = $true
        }
    }

    throw "Worktree setup failed for task '$($Task.name)': $($wtResult.message)"
}

function Set-WorkflowRunLiveStatus {
    param(
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [ValidateSet('running','completed','failed','cancelled')] [string]$Status,
        [string]$CurrentTaskId,
        [string]$ErrorMessage
    )

    if (-not (Get-Command New-WorkflowRunStatus -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psd1") -DisableNameChecking -Global
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $completedAt = if ($Status -in @('completed','failed','cancelled')) { $timestamp } else { $null }
    $taskId = if ($CurrentTaskId) { $CurrentTaskId } else { $null }
    $statusRecord = New-WorkflowRunStatus `
        -RunId $RunId `
        -Status $Status `
        -CurrentTaskId $taskId `
        -CompletedAt $completedAt `
        -LastHeartbeat $timestamp `
        -Error $ErrorMessage

    $workflowRunsControlDir = Join-Path $controlDir "workflow-runs"
    if (-not (Test-Path -LiteralPath $workflowRunsControlDir)) {
        New-Item -ItemType Directory -Path $workflowRunsControlDir -Force | Out-Null
    }
    $statusPath = Join-Path $workflowRunsControlDir "$RunId.json"
    Write-TaskFileAtomic -Path $statusPath -Content $statusRecord -Depth 20 -BotRoot $botRoot
}

function Get-WorkflowTaskRunnerExtension {
    param([Parameter(Mandatory)] $TaskContent)

    $extensions = Get-DotbotObjectProperty -Object $TaskContent -Name 'extensions'
    if ($null -eq $extensions -or
        ($extensions -isnot [System.Collections.IDictionary] -and $extensions -isnot [PSCustomObject])) {
        $extensions = [ordered]@{}
        Set-DotbotObjectProperty -Object $TaskContent -Name 'extensions' -Value $extensions
    }

    $runner = Get-DotbotObjectProperty -Object $extensions -Name 'runner'
    if ($null -eq $runner -or
        ($runner -isnot [System.Collections.IDictionary] -and $runner -isnot [PSCustomObject])) {
        $runner = [ordered]@{}
        Set-DotbotObjectProperty -Object $extensions -Name 'runner' -Value $runner
    }
    return $runner
}

function Set-WorkflowTaskNeedsInput {
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string]$RunDir,
        [Parameter(Mandatory)] [string]$QuestionId,
        [Parameter(Mandatory)] [string]$Question,
        [Parameter(Mandatory)] [string]$Context
    )

    $current = Get-WorkflowTaskContent -Task $Task -RunDir $RunDir
    if (-not $current) { return $false }

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $pendingQuestion = @{
        id             = $QuestionId
        question       = $Question
        context        = $Context
        options        = @(
            @{ key = "A"; label = "Investigate logs and retry"; rationale = "Inspect the worktree, fix the underlying issue, then move the task back to todo" }
            @{ key = "B"; label = "Skip this task"; rationale = "Mark the task skipped and continue with the rest of the workflow" }
        )
        recommendation = "A"
        asked_at       = $timestamp
    }

    $taskData = $current.Content
    Set-DotbotObjectProperty -Object $taskData -Name 'status' -Value 'needs-input'
    Set-DotbotObjectProperty -Object $taskData -Name 'updated_at' -Value $timestamp
    Set-DotbotObjectProperty -Object $taskData -Name 'updated_by' -Value 'workflow-process'
    Set-DotbotObjectProperty -Object $taskData -Name 'completed_at' -Value $null
    $runner = Get-WorkflowTaskRunnerExtension -TaskContent $taskData
    Set-DotbotObjectProperty -Object $runner -Name 'pending_question' -Value $pendingQuestion

    if (-not (Get-Command New-DotbotTaskHandoff -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Handoff" "Dotbot.Handoff.psd1") -DisableNameChecking -Global
    }
    New-DotbotTaskHandoff `
        -TaskContent $taskData `
        -BotRoot $botRoot `
        -QuestionId $QuestionId `
        -Question $Question `
        -Context $Context `
        -Reason 'workflow-escalation' | Out-Null

    Write-TaskFileAtomic -Path $current.Path -Content $taskData -Depth 20 -TaskId $Task.id -BotRoot $botRoot
    return $true
}

# ── Task-status helpers ──────────────────────────────────────────────────────
# Each helper POSTs to the runtime's /tasks/<id>/status endpoint.
if (-not (Get-Command Invoke-RuntimeRequest -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Runtime" "Dotbot.Runtime.psd1") -DisableNameChecking -Global
}

function _PostTaskStatus {
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$To,
        [string]$Reason,
        [string]$SkipReason,
        [string]$SkipDetail
    )
    $body = @{ to = $To; actor = 'workflow-process' }
    if ($Reason) { $body['reason'] = $Reason }
    if ($SkipReason) { $body['skip_reason'] = $SkipReason }
    if ($SkipDetail) { $body['skip_detail'] = $SkipDetail }
    $resp = Invoke-RuntimeRequest -BotRoot $botRoot -Method POST -Path "/tasks/$TaskId/status" -Body $body
    $code = [int]$resp.status_code
    if ($code -ge 200 -and $code -lt 300) {
        return @{ success = $true; status_code = $code; body = $resp.body }
    }
    $msg = if ($resp.body -and $resp.body.PSObject.Properties['message']) { $resp.body.message } else { $resp.raw }
    return @{ success = $false; status_code = $code; message = $msg }
}

function Invoke-TaskMarkInProgress {
    param([hashtable]$Arguments)
    if (-not $Arguments['task_id']) { throw "Task ID is required" }
    _PostTaskStatus -TaskId $Arguments['task_id'] -To 'in-progress'
}

function Invoke-TaskMarkSkipped {
    param([hashtable]$Arguments)
    if (-not $Arguments['task_id']) { throw "Task ID is required" }
    $reasonParts = @()
    if ($Arguments['skip_reason']) { $reasonParts += [string]$Arguments['skip_reason'] }
    if ($Arguments['skip_detail']) { $reasonParts += [string]$Arguments['skip_detail'] }
    $reason = if ($reasonParts.Count -gt 0) { $reasonParts -join ': ' } else { $null }
    _PostTaskStatus -TaskId $Arguments['task_id'] -To 'skipped' -Reason $reason -SkipReason $Arguments['skip_reason'] -SkipDetail $Arguments['skip_detail']
}

function Invoke-TaskMarkFailed {
    param([hashtable]$Arguments)
    if (-not $Arguments['task_id']) { throw "Task ID is required" }
    $reason = if ($Arguments['fail_detail']) { [string]$Arguments['fail_detail'] } else { $null }
    _PostTaskStatus -TaskId $Arguments['task_id'] -To 'failed' -Reason $reason
}

function Set-TaskInProgressForExecutorDispatch {
    param([Parameter(Mandatory)] $Task)

    $taskId = [string](Get-TaskFieldValue -Task $Task -Name 'id')
    $status = [string](Get-TaskFieldValue -Task $Task -Name 'status')
    if (-not $taskId) { throw "Task ID is required" }

    if ($status -eq 'in-progress') { return }

    if ($status -in @('todo', 'needs-input')) {
        $inProgress = Invoke-TaskMarkInProgress -Arguments @{ task_id = $taskId }
        if (-not $inProgress.success) { throw $inProgress.message }
        return
    }

    throw "Cannot dispatch executor task from status '$status'."
}

function Set-TaskTerminalFailureForExecutorDispatch {
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [string]$Detail
    )

    $taskId = [string](Get-TaskFieldValue -Task $Task -Name 'id')
    if (-not $taskId) { throw "Task ID is required" }

    $current = Get-WorkflowTaskContent -Task $Task -RunDir $runDir
    $status = if ($current -and $current.Content.status) {
        [string]$current.Content.status
    } else {
        [string](Get-TaskFieldValue -Task $Task -Name 'status')
    }

    switch ($status) {
        'todo' {
            $result = Invoke-TaskMarkSkipped -Arguments @{ task_id = $taskId; skip_reason = 'non-recoverable'; skip_detail = $Detail }
        }
        'in-progress' {
            $result = Invoke-TaskMarkFailed -Arguments @{ task_id = $taskId; fail_detail = $Detail }
        }
        'needs-input' {
            $result = _PostTaskStatus -TaskId $taskId -To 'cancelled' -Reason $Detail
        }
        { $_ -in @('done','failed','skipped','cancelled') } {
            return
        }
        default {
            throw "Cannot mark executor task failure from status '$status'."
        }
    }

    if ($result -and -not $result.success) { throw $result.message }
}
# ── End shims ───────────────────────────────────────────────────────────────

# Resolve a workflow by name through the two-tier registry. Returns
# the absolute directory of the resolved workflow or $null on miss. We do
# the import lazily here because parent scripts may load Invoke-WorkflowProcess
# inside a worker scope where Dotbot.Workflow has been imported into a
# different module table — calling Get-Command guards against double-import.
function Resolve-WorkflowDirByName {
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Get-Command Find-Workflow -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psd1") -DisableNameChecking -Global
    }
    $resolved = Find-Workflow -BotRoot $BotRoot -Name $Name
    if ($resolved.ok) { return $resolved.path }
    return $null
}

function Resolve-WorkflowPromptTemplateFile {
    param(
        [Parameter(Mandatory)][string]$BotRoot,
        [string]$WorkflowName,
        [Parameter(Mandatory)][string]$PromptReference
    )

    if (-not (Get-Command Resolve-DotbotContentReference -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Content" "Dotbot.Content.psm1") -DisableNameChecking -Global
    }

    $resolvedContentPrompt = Resolve-DotbotContentReference -BotRoot $BotRoot -Type prompts -Reference $PromptReference
    if ($resolvedContentPrompt) { return $resolvedContentPrompt }

    $relativePath = ($PromptReference -replace '\\','/').Trim()
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return $null }
    if (-not $relativePath.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = "$relativePath.md"
    }

    $roots = @()
    if ($WorkflowName) {
        $workflowDir = Resolve-WorkflowDirByName -BotRoot $BotRoot -Name $WorkflowName
        if ($workflowDir) { $roots += $workflowDir }
    }
    $roots += $BotRoot

    foreach ($root in $roots) {
        $path = Join-Path $root $relativePath
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    return $null
}

function Get-TaskFieldValue {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Task -is [System.Collections.IDictionary]) {
        if ($Task.Contains($Name)) { return $Task[$Name] }
        return $null
    }
    $prop = $Task.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function New-ExecutorRunContext {
    param(
        [Parameter(Mandatory)]$Task,
        [string]$WorkflowDir,
        [string]$WorktreePath,
        [string]$BranchName
    )
    $contextBotRoot = if ($WorktreePath) { Join-Path $WorktreePath '.bot' } else { $botRoot }
    $contextProductDir = Join-Path (Join-Path $contextBotRoot 'workspace') 'product'
    $contextProjectRoot = if ($WorktreePath) { $WorktreePath } else { $projectRoot }
    @{
        run_id          = $RunId
        run_dir         = $runDir
        bot_root        = $contextBotRoot
        BotRoot         = $contextBotRoot
        project_root    = $contextProjectRoot
        runtime_root    = $runtimeRoot
        process_id      = $procId
        process_data    = $processData
        settings        = $settings
        model           = $modelTier
        workflow_name   = (Get-TaskFieldValue -Task $Task -Name 'workflow')
        workflow_dir    = $WorkflowDir
        product_dir     = $contextProductDir
        worktree_path   = $WorktreePath
        branch_name     = $BranchName
        permission_mode = $permissionMode
        show_debug      = $ShowDebug
        show_verbose    = $ShowVerbose
        mcp_tools_dir   = (Join-Path $runtimeRoot '..' 'mcp' 'tools')
    }
}

function Read-DotbotMcpPreflightLine {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process]$Process,
        [int]$TimeoutMs = 15000
    )

    $readTask = $Process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait($TimeoutMs)) {
        return @{ ok = $false; message = "Timed out waiting for MCP server response." }
    }

    $line = $readTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        return @{ ok = $false; message = "MCP server exited or returned an empty response." }
    }

    try {
        return @{ ok = $true; response = ($line | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    } catch {
        return @{ ok = $false; message = "MCP server returned invalid JSON: $line" }
    }
}

function Test-DotbotMcpReadiness {
    param(
        [Parameter(Mandatory)] [string]$WorktreePath,
        # Stable main repo root, exported as DOTBOT_STATE_ROOT so the preflight
        # MCP process resolves runtime.json against the main .control/ rather
        # than the worktree's junction, which can be stale on task retry
        # (teardown/re-create is not atomic) and would make the server exit
        # before the handshake. This mirrors the real provider session, which
        # also runs with cwd/DOTBOT_PROJECT_ROOT = worktree and
        # DOTBOT_STATE_ROOT = main root — so preflight tests the same config the
        # task actually runs under. Omitted → no state-root override (backward
        # compatible). See #515.
        [string]$ProjectRoot,
        [string[]]$RequiredTools = @('task_get_context','task_set_status','task_update','decision_create','decision_list')
    )

    if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) {
        return @{ ok = $false; reason = 'missing_worktree'; message = "Worktree path does not exist: $WorktreePath" }
    }

    $mcpConfigPath = Join-Path $WorktreePath '.mcp.json'
    if (-not (Test-Path -LiteralPath $mcpConfigPath -PathType Leaf)) {
        return @{ ok = $false; reason = 'missing_config'; message = "Missing dotbot MCP config at $mcpConfigPath" }
    }

    try {
        $mcpConfig = Get-Content -LiteralPath $mcpConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $mcpConfig.PSObject.Properties['mcpServers'] -or -not $mcpConfig.mcpServers.PSObject.Properties['dotbot']) {
            return @{ ok = $false; reason = 'missing_dotbot_server'; message = ".mcp.json does not define mcpServers.dotbot." }
        }
    } catch {
        return @{ ok = $false; reason = 'invalid_config'; message = "Could not parse $mcpConfigPath`: $($_.Exception.Message)" }
    }

    $frameworkRoot = Get-DotbotInstallPath
    $mcpScript = Join-Path $frameworkRoot 'src/mcp/dotbot-mcp.ps1'
    if (-not (Test-Path -LiteralPath $mcpScript -PathType Leaf)) {
        return @{ ok = $false; reason = 'missing_server_script'; message = "dotbot MCP server script not found at $mcpScript" }
    }

    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pwsh) {
        return @{ ok = $false; reason = 'missing_pwsh'; message = "pwsh is not available on PATH; cannot start the dotbot MCP server." }
    }

    $proc = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwsh.Source
        foreach ($arg in @('-NoProfile','-ExecutionPolicy','Bypass','-File',$mcpScript)) {
            $psi.ArgumentList.Add($arg)
        }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.WorkingDirectory = $WorktreePath
        $psi.Environment['DOTBOT_HOME'] = $frameworkRoot
        $psi.Environment['DOTBOT_PROJECT_ROOT'] = $WorktreePath
        if ($ProjectRoot) { $psi.Environment['DOTBOT_STATE_ROOT'] = $ProjectRoot }
        $psi.Environment['__DOTBOT_MANAGED'] = '1'

        $maxAttempts = 2
        $init = @{ ok = $false; message = 'Preflight loop did not execute.' }
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            # Fresh process per attempt: StreamReader cannot have two concurrent ReadLineAsync
            # calls, and MCP initialize is a one-shot handshake — reusing the same process
            # would send it twice, leaving the server in an undefined state.
            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start() | Out-Null

            $initRequest = @{
                jsonrpc = '2.0'
                id      = 1
                method  = 'initialize'
                params  = @{
                    protocolVersion = '2024-11-05'
                    capabilities    = @{}
                    clientInfo      = @{ name = 'dotbot-workflow-preflight'; version = '1' }
                }
            } | ConvertTo-Json -Depth 10 -Compress
            $proc.StandardInput.WriteLine($initRequest)
            $proc.StandardInput.Flush()

            $init = Read-DotbotMcpPreflightLine -Process $proc
            if ($init.ok) { break }

            if ($attempt -lt $maxAttempts) {
                Write-BotLog -Level Debug -Message "MCP preflight initialize attempt $attempt failed ($($init.message)), retrying..."
                try { $proc.StandardInput.Close() } catch { Write-BotLog -Level Debug -Message "MCP preflight stdin cleanup failed" -Exception $_ }
                if (-not $proc.HasExited) {
                    try {
                        $proc.Kill($true)
                    } catch {
                        Write-BotLog -Level Debug -Message "MCP preflight process-tree kill failed; retrying process kill" -Exception $_
                        try { $proc.Kill() } catch { Write-BotLog -Level Debug -Message "MCP preflight process kill failed" -Exception $_ }
                    }
                    try { $proc.WaitForExit(1000) | Out-Null } catch { Write-BotLog -Level Debug -Message "MCP preflight process wait failed" -Exception $_ }
                }
                $proc.Dispose()
                $proc = $null
            }
        }
        if (-not $init.ok) { return @{ ok = $false; reason = 'initialize_failed'; message = $init.message } }
        if ($init.response -is [hashtable] -and $init.response.ContainsKey('error')) {
            return @{ ok = $false; reason = 'initialize_error'; message = "MCP initialize failed: $($init.response.error.message)" }
        }

        # Server is warm after successful initialize; 15s ceiling shared intentionally.
        $listRequest = @{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } | ConvertTo-Json -Depth 5 -Compress
        $proc.StandardInput.WriteLine($listRequest)
        $proc.StandardInput.Flush()

        $list = Read-DotbotMcpPreflightLine -Process $proc
        if (-not $list.ok) { return @{ ok = $false; reason = 'tools_list_failed'; message = $list.message } }
        if ($list.response -is [hashtable] -and $list.response.ContainsKey('error')) {
            return @{ ok = $false; reason = 'tools_list_error'; message = "MCP tools/list failed: $($list.response.error.message)" }
        }

        $tools = @($list.response.result.tools)
        $toolNames = @($tools | ForEach-Object { [string]$_['name'] })
        $missing = @($RequiredTools | Where-Object { $_ -notin $toolNames })
        if ($missing.Count -gt 0) {
            return @{ ok = $false; reason = 'missing_required_tools'; message = "dotbot MCP tools missing from catalog: $($missing -join ', ')" }
        }

        return @{ ok = $true; tool_count = $tools.Count }
    } catch {
        return @{ ok = $false; reason = 'preflight_exception'; message = $_.Exception.Message }
    } finally {
        if ($proc) {
            try { $proc.StandardInput.Close() } catch { Write-BotLog -Level Debug -Message "MCP preflight stdin cleanup failed" -Exception $_ }
            if (-not $proc.HasExited) {
                try {
                    $proc.Kill($true)
                } catch {
                    Write-BotLog -Level Debug -Message "MCP preflight process-tree kill failed; retrying process kill" -Exception $_
                    try { $proc.Kill() } catch { Write-BotLog -Level Debug -Message "MCP preflight process kill failed" -Exception $_ }
                }
                try { $proc.WaitForExit(1000) | Out-Null } catch { Write-BotLog -Level Debug -Message "MCP preflight process wait failed" -Exception $_ }
            }
            $proc.Dispose()
        }
    }
}

# Mandatory-task check (#213): a task is mandatory unless it explicitly
# opts out via optional:true. Used across every failure path in this file.
function Test-TaskIsMandatory {
    param($Task)
    $val = if ($Task -is [System.Collections.IDictionary]) { $Task['optional'] } else { $Task.optional }
    return $val -ne $true
}

# Validate task-declared outputs after a task completes. Parity with the
# the legacy engine. Returns $null on
# success, an error message on failure. Caller decides how to escalate.
# Count visible task JSONs across the whole task workspace. Used both as the
# post-task validation count and as a pre-task baseline so that Test-TaskOutput
# can compare the delta produced by a task_gen/script expansion task instead of
# the absolute total. Workflow-spawned implementation tasks live under
# workflow-runs/<run>/ rather than the legacy todo/ pipeline dirs, so this must
# include recursive run directories while excluding run.json metadata records.
function Measure-TaskFile {
    param([Parameter(Mandatory)][string]$BotRoot)
    # Forward-slash literals so Join-Path on Linux/macOS produces a real path.
    $tasksRoot = Join-Path (Join-Path $BotRoot 'workspace') 'tasks'
    if (-not (Test-Path -LiteralPath $tasksRoot -PathType Container)) {
        return 0
    }

    return @(Get-ChildItem -LiteralPath $tasksRoot -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^[._]' -and $_.Name -ne 'run.json' }).Count
}

# Capture baseline count under outputs_dir before a task runs, so the
# subsequent Test-TaskOutput call can compare against the delta.
function Get-TaskOutputBaseline {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$BotRoot
    )
    $taskOutputsDir = if ($Task -is [System.Collections.IDictionary]) { $Task['outputs_dir'] } else { $Task.outputs_dir }
    if (-not $taskOutputsDir) {
        $taskOutputsDir = if ($Task -is [System.Collections.IDictionary]) { $Task['required_outputs_dir'] } else { $Task.required_outputs_dir }
    }
    if (-not $taskOutputsDir) { return -1 }

    if ($taskOutputsDir -like 'tasks/*' -or $taskOutputsDir -eq 'tasks') {
        return Measure-TaskFile -BotRoot $BotRoot
    }
    # Normalise outputs_dir separator and join via two-segment Join-Path so the
    # resolved path is valid on both Windows and Unix.
    $normalizedOutputsDir = $taskOutputsDir -replace '\\', '/'
    $dirPath = Join-Path (Join-Path $BotRoot 'workspace') $normalizedOutputsDir
    if (Test-Path $dirPath) {
        return @(Get-ChildItem $dirPath -File | Where-Object { $_.Name -notmatch '^[._]' }).Count
    }
    return 0
}

function Test-TaskOutput {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        # -1 means "no baseline captured" — fall back to absolute-count check.
        # 0+ means baseline was captured before the task ran; compare delta.
        [int]$BaselineCount = -1
    )
    $taskOutputs = if ($Task -is [System.Collections.IDictionary]) { $Task['outputs'] } else { $Task.outputs }
    if (-not $taskOutputs) {
        $taskOutputs = if ($Task -is [System.Collections.IDictionary]) { $Task['required_outputs'] } else { $Task.required_outputs }
    }
    $taskOutputsDir = if ($Task -is [System.Collections.IDictionary]) { $Task['outputs_dir'] } else { $Task.outputs_dir }
    if (-not $taskOutputsDir) {
        $taskOutputsDir = if ($Task -is [System.Collections.IDictionary]) { $Task['required_outputs_dir'] } else { $Task.required_outputs_dir }
    }
    if ($taskOutputs) {
        # Output entries may be a bare filename ("x.md"), a repo-rooted path
        # (".bot/workspace/product/x.md" — e.g. emitted by the deep-research
        # generator), or an absolute path. $ProductDir is already
        # <botroot>/workspace/product, so naively Join-Path'ing a rooted entry
        # double-joins (PowerShell only defers to the 2nd arg when it is
        # drive-absolute) and validation always fails. Normalise first.
        $projectRoot = Split-Path -Parent $BotRoot
        foreach ($f in $taskOutputs) {
            $entry = ([string]$f -replace '\\', '/').Trim()
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            # IsPathFullyQualified is the cross-platform "truly absolute" test:
            # on Windows "C:/x" and "//host/x" are fully qualified but a bare "/x"
            # is only drive-relative (correctly treated as relative here); on
            # Linux/macOS "/tmp/x" is fully qualified. This avoids [IO.Path]::
            # IsPathRooted, which treats a bare leading "/" as rooted on Windows.
            $target = if ([System.IO.Path]::IsPathFullyQualified($entry)) {
                $entry
            } elseif ($entry -match '^\.bot/') {
                Join-Path $projectRoot $entry
            } else {
                Join-Path $ProductDir ($entry.TrimStart('/'))
            }
            # -LiteralPath: task-authored entries are untrusted; without it a
            # filename containing [ ] would be treated as a wildcard (mis-validated),
            # and it avoids a wildcard/existence probe on a crafted entry.
            if (-not (Test-Path -LiteralPath $target)) {
                return "Task output not produced: $f"
            }
        }
    } elseif ($taskOutputsDir) {
        $minVal = if ($Task -is [System.Collections.IDictionary]) { $Task['min_output_count'] } else { $Task.min_output_count }
        $minCount = if ($minVal) { [int]$minVal } else { 1 }

        # Special-case outputs_dir under tasks/: a task_gen task generates files
        # into tasks/todo, but in multi-slot runs other slots can claim those
        # files and move them to in-progress before this
        # validation runs. Count visible task JSONs across every pipeline state
        # so concurrent claiming doesn't cause spurious validation failures.
        $isTasksOutput = ($taskOutputsDir -like 'tasks/*' -or $taskOutputsDir -eq 'tasks')

        if ($isTasksOutput) {
            $fileCount = Measure-TaskFile -BotRoot $BotRoot
        } else {
            $normalizedOutputsDir = $taskOutputsDir -replace '\\', '/'
            $dirPath = Join-Path (Join-Path $BotRoot 'workspace') $normalizedOutputsDir
            $fileCount = if (Test-Path $dirPath) {
                @(Get-ChildItem $dirPath -File | Where-Object { $_.Name -notmatch '^[._]' }).Count
            } else { 0 }
        }

        # If a baseline was captured before the task ran, validate against the
        # delta — required for the task-runner case where the manifest pre-
        # creates all tasks into tasks/todo before the process starts (any
        # absolute-count check would always pass). Without a baseline, fall
        # back to the absolute-count check.
        if ($BaselineCount -ge 0) {
            $delta = $fileCount - $BaselineCount
            if ($delta -lt $minCount) {
                # Resume-after-approval: on a resumed run the worktree already
                # holds the artifact from the prior run, so the agent correctly
                # calls task_set_status(done) without re-writing files that
                # already exist — delta is 0 even though the required output is
                # present and correct. For non-tasks/ outputs, fall back to the
                # absolute file count: if the required files are already there
                # (absolute count >= min), pass. tasks/ outputs keep strict
                # delta enforcement because manifest pre-creation makes the
                # absolute count always look satisfied, leaving delta the only
                # meaningful signal.
                if ($isTasksOutput -or $fileCount -lt $minCount) {
                    return "Task output directory '$taskOutputsDir' produced $delta new file(s), expected at least $minCount"
                }
            }
        } elseif ($fileCount -lt $minCount) {
            return "Task output directory '$taskOutputsDir' has $fileCount file(s), expected at least $minCount"
        }
    }
    return $null
}

# Add JSON front matter to task-declared documents. Reuses Add-JsonFrontMatter
# from ProcessRegistry.psm1.
function Add-TaskFrontMatter {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)][string]$ProcId,
        [string]$ModelName
    )
    $frontMatterDocs = if ($Task -is [System.Collections.IDictionary]) { $Task['front_matter_docs'] } else { $Task.front_matter_docs }
    if (-not $frontMatterDocs) { return }
    $taskId = if ($Task -is [System.Collections.IDictionary]) { $Task['id'] } else { $Task.id }
    $taskMeta = @{
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
        model        = $ModelName
        process_id   = $ProcId
        task         = "task-$taskId"
        generator    = "dotbot-task-runner"
    }
    foreach ($docName in $frontMatterDocs) {
        $docPath = Join-Path $ProductDir $docName
        if (Test-Path $docPath) {
            Add-JsonFrontMatter -FilePath $docPath -Metadata $taskMeta
        }
    }
}

# Post-task clarification-questions HITL loop, adapted from the legacy engine
# to task scope. Detects
# clarification-questions.json written by the agent during task execution,
# pauses the process for human input, polls for clarification-answers.json,
# appends Q&A to interview-summary.md, and runs adjust-after-answers.md as a
# separate provider session. Returns $null on success or skip, an error
# message string on failure.
#
# This is the file-watch path only — Teams notification polling (legacy
# parallel channel) is not yet ported and is tracked as follow-up work.
function Invoke-TaskClarificationLoopIfPresent {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$ProductDir,
        [Parameter(Mandatory)][hashtable]$ProcessData,
        [Parameter(Mandatory)][string]$ProcId,
        [string]$ProjectRoot,
        [string]$ModelName,
        [bool]$ShowDebug,
        [bool]$ShowVerbose,
        [string]$PermissionMode,
        # Canonical project .bot root for process-registry writes (proc-*.json).
        # Distinct from $BotRoot above, which is worktree-scoped (used for the
        # answers-file path) — process state must never resolve through the
        # worktree's transient .control junction (#612).
        [string]$ProcessBotRoot
    )
    $questionsPath = Join-Path $ProductDir "clarification-questions.json"
    if (-not (Test-Path $questionsPath)) { return $null }

    # Per-process answers filename. For task worktrees, $ProductDir is already
    # branch-local (isolated per run), so any name works; the proc-id suffix
    # additionally keeps two runs apart in the rare shared-main case (tasks that
    # skip the worktree). This loop is the SOLE authority on the answers path —
    # it both polls this exact file and publishes it to the process file below,
    # so the UI writer always targets the same location (see Change B in
    # server.ps1 /api/process/answer).
    $answersPath = Join-Path $ProductDir "clarification-answers.$ProcId.json"

    # Reset process state on any error path. Without this, a parse failure
    # leaves the JSON stuck in needs-input until something else overwrites it.
    function Reset-ClarificationState {
        param($PD, $Id, $TaskName)
        $PD.status = 'running'
        $PD.pending_questions = $null
        $PD.heartbeat_status = "Running task: $TaskName"
        Write-ProcessFile -Id $Id -Data $PD -BotRoot $ProcessBotRoot
    }

    $questionsData = $null
    try {
        $questionsData = (Get-Content $questionsPath -Raw) | ConvertFrom-Json
    } catch {
        # Preserve the file so the operator can inspect what couldn't be parsed.
        # Deleting it removed the primary diagnostic artifact, contradicting the
        # rest of the failure-path policy that keeps Q/A JSONs around.
        return "Failed to parse clarification-questions.json at '$questionsPath': $($_.Exception.Message). File preserved for inspection."
    }
    if (-not $questionsData -or -not $questionsData.questions -or $questionsData.questions.Count -eq 0) {
        # Empty/well-formed-but-questionless: safe to remove (no diagnostic value).
        Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
        return $null
    }
    try {
        Assert-TaskInputQuestionsData -QuestionsData $questionsData -Path 'clarification-questions.json'
    } catch {
        return "Invalid clarification-questions.json at '$questionsPath': $($_.Exception.Message). File preserved for inspection."
    }

    Write-Status "Task $($Task.name): $($questionsData.questions.Count) clarification question(s) — waiting for user" -Type Info
    Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Task '$($Task.name)' has $($questionsData.questions.Count) clarification question(s)"

    # Delete any stale answers file BEFORE flipping status to needs-input.
    # If we deleted after, a fresh UI-supplied answers file written between
    # the status flip and the deletion could be wiped, leaving the runner
    # waiting indefinitely.
    if (Test-Path $answersPath) { Remove-Item $answersPath -Force -ErrorAction SilentlyContinue }

    $ProcessData.status = 'needs-input'
    $ProcessData.pending_questions = $questionsData
    # Publish where this run is listening for answers so the UI writer targets
    # the exact (possibly worktree-local) file this loop polls — not a hardcoded
    # main-checkout path. This is what makes concurrent runs' answers isolated
    # and fixes worktree tasks whose answers previously never arrived.
    $ProcessData.product_dir = $ProductDir
    $ProcessData.answers_path = $answersPath
    $ProcessData.heartbeat_status = "Waiting for answers (task: $($Task.name))"
    Write-ProcessFile -Id $ProcId -Data $ProcessData -BotRoot $ProcessBotRoot

    while (-not (Test-Path $answersPath)) {
        if (Test-ProcessStopSignal -Id $ProcId -BotRoot $ProcessBotRoot) {
            $ProcessData.status = 'stopped'
            $ProcessData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            $ProcessData.pending_questions = $null
            Write-ProcessFile -Id $ProcId -Data $ProcessData -BotRoot $ProcessBotRoot
            return "Process stopped by user during clarification wait"
        }
        Start-Sleep -Seconds 2
    }

    # The UI server writes clarification-answers.json via Set-Content (open/
    # truncate/write — non-atomic). Reading it the moment the file appears can
    # race against the writer. Retry parse a few times before deleting and
    # escalating, so a partially-written file doesn't force the user to
    # resubmit answers.
    $answersData = $null
    $lastParseError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $answersData = (Get-Content $answersPath -Raw) | ConvertFrom-Json
            $lastParseError = $null
            break
        } catch {
            $lastParseError = $_.Exception.Message
            if ($attempt -lt 5 -and (Test-Path $answersPath)) {
                Start-Sleep -Milliseconds 300
            }
        }
    }
    if (-not $answersData) {
        # Persistently malformed — delete so next run doesn't loop on the same parse failure.
        Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
        Reset-ClarificationState -PD $ProcessData -Id $ProcId -TaskName $Task.name
        return "Failed to parse clarification-answers.json: $lastParseError"
    }

    if ($answersData -and $answersData.skipped -eq $true) {
        Write-Status "User skipped clarification questions for $($Task.name)" -Type Info
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "User skipped clarification questions for $($Task.name)"
    } elseif ($answersData) {
        # Validate answers are present and non-empty. An empty/missing answers
        # array would silently discard the pending questions without applying
        # anything, so escalate as a malformed payload.
        if (-not $answersData.answers -or $answersData.answers.Count -eq 0) {
            Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
            Reset-ClarificationState -PD $ProcessData -Id $ProcId -TaskName $Task.name
            return "clarification-answers.json has no 'answers' array — pending questions cannot be applied"
        }
        $summaryPath = Join-Path $ProductDir "interview-summary.md"
        $timestamp = (Get-Date).ToUniversalTime().ToString("o")
        $qaSection = "`n`n### Task: $($Task.name)`n"
        $qaSection += "| # | Question | Answer (verbatim) | Interpretation | Timestamp |`n"
        $qaSection += "|---|----------|--------------------|----------------|-----------|`n"
        $qIdx = 0
        foreach ($ans in $answersData.answers) {
            $qIdx++
            $qText = ($ans.question -replace '\|', '\|' -replace "`n", ' ')
            $aText = ($ans.answer -replace '\|', '\|' -replace "`n", ' ')
            $qaSection += "| q$qIdx | $qText | $aText | _pending_ | $timestamp |`n"
        }
        if (Test-Path $summaryPath) {
            $existingContent = Get-Content $summaryPath -Raw
            if ($existingContent -notmatch '## Clarification Log') {
                $qaSection = "`n## Clarification Log`n" + $qaSection
            }
            Add-Content -Path $summaryPath -Value $qaSection -NoNewline
        } else {
            $newSummary = "# Interview Summary`n`n## Clarification Log`n" + $qaSection
            Set-Content -Path $summaryPath -Value $newSummary -NoNewline
        }

        # Resolve the adjust-after-answers recipe through the canonical content
        # resolver (project .bot/content/recipes -> user -> $DOTBOT_HOME/content
        # /recipes). A hardcoded "$BotRoot/recipes/..." never resolves: content
        # install never populates a .bot/recipes tree (the worktree recipe-link is
        # gated on that same non-existent dir), so inside a task worktree the file
        # was always missing and the apply-answers step wrongly escalated.
        $adjustPromptPath = Resolve-DotbotContent -BotRoot $BotRoot -Type recipes -Name 'includes/adjust-after-answers.md'
        if (-not $adjustPromptPath) {
            # Only reachable when the recipe is absent from every content tier —
            # i.e. a broken framework install, which no operator "needs-input"
            # answer can fix. Fail loud with a clear message rather than parking
            # the task in needs-input (and never silently skip the adjust pass).
            Reset-ClarificationState -PD $ProcessData -Id $ProcId -TaskName $Task.name
            return "Adjust-after-answers recipe not found in project or framework content (content/recipes/includes/adjust-after-answers.md) — framework install may be broken."
        }
        $adjustContent = Get-Content $adjustPromptPath -Raw
        $adjustPrompt = @"
$adjustContent

## Context

- **Task that generated questions**: $($Task.name)
- **User's project description**: see workflow-launch-prompt.txt and any briefing files in .bot/workspace/product/briefing/

Instructions:
1. Read .bot/workspace/product/interview-summary.md for the full Q&A history including the new answers
2. Read ALL existing product artifacts in .bot/workspace/product/
3. Assess the impact of the new information across all artifacts
4. Enrich/correct any affected artifacts
5. Fill in the Interpretation column for the new Q&A entries in interview-summary.md
"@
        Write-Status "Running post-answer adjustment for task $($Task.name)..." -Type Process
        Write-ProcessActivity -Id $ProcId -ActivityType "text" -Message "Adjusting artifacts after answers for $($Task.name)"
        $adjustSessionId = $null
        try {
            $adjustSessionId = New-HarnessSession
            $adjustArgs = @{
                Prompt         = $adjustPrompt
                Model          = $ModelName
                SessionId      = $adjustSessionId
                PersistSession = $false
            }
            if ($ShowDebug) { $adjustArgs['ShowDebugJson'] = $true }
            if ($ShowVerbose) { $adjustArgs['ShowVerbose'] = $true }
            if ($PermissionMode) { $adjustArgs['PermissionMode'] = $PermissionMode }
            if ($ProjectRoot) { $adjustArgs['WorkingDirectory'] = $ProjectRoot }
            Invoke-HarnessStream @adjustArgs | Out-Null
            Write-Status "Post-answer adjustment complete for $($Task.name)" -Type Complete
        } catch {
            $adjustErr = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($adjustErr)) { $adjustErr = $_.ToString() }
            Reset-ClarificationState -PD $ProcessData -Id $ProcId -TaskName $Task.name
            # Preserve clarification-questions.json and clarification-answers.json on
            # failure so the operator can inspect them during the needs-input
            # escalation. The escalation pending_question text directs them here.
            return "Post-answer adjustment failed for task '$($Task.name)': $adjustErr"
        } finally {
            if ($adjustSessionId) {
                try {
                    $removeArgs = @{ SessionId = $adjustSessionId }
                    if ($ProjectRoot) { $removeArgs['ProjectRoot'] = $ProjectRoot }
                    Remove-HarnessSession @removeArgs | Out-Null
                } catch { Write-BotLog -Level Debug -Message "Adjust session cleanup failed" -Exception $_ }
            }
        }
    }

    Remove-Item $questionsPath -Force -ErrorAction SilentlyContinue
    Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
    Reset-ClarificationState -PD $ProcessData -Id $ProcId -TaskName $Task.name
    return $null
}

# Build the briefing-file references and interview-summary context block that
# gets appended to LLM prompts. Read fresh per task so that context created by
# an earlier task in the same run becomes visible to later ones.
function Get-WorkflowPromptContext {
    param([Parameter(Mandatory)][string]$ProductDir)
    $fileRefs = ""
    $briefingDir = Join-Path $ProductDir "briefing"
    if (Test-Path $briefingDir) {
        $briefingFiles = @(Get-ChildItem -Path $briefingDir -File -ErrorAction SilentlyContinue)
        if ($briefingFiles.Count -gt 0) {
            # Emit repo-relative paths instead of $bf.FullName so absolute host
            # paths (which can leak machine/user directory info) aren't sent
            # to the provider. .bot/workspace/product/briefing/ is the canonical
            # location; the agent reads files from there directly.
            $fileRefs = "`n`nBriefing files have been saved to .bot/workspace/product/briefing/. Read and use these for context:`n"
            foreach ($bf in $briefingFiles) { $fileRefs += "- .bot/workspace/product/briefing/$($bf.Name)`n" }
        }
    }
    $interviewContext = ""
    $interviewSummaryPath = Join-Path $ProductDir "interview-summary.md"
    if (Test-Path $interviewSummaryPath) {
        $interviewContext = @"

## Interview Summary

An interview-summary.md file exists in .bot/workspace/product/ containing the user's clarified requirements with both verbatim answers and expanded interpretation. **Read this file** and use it to guide your decisions — it reflects the user's confirmed preferences for platform, architecture, technology, domain model, and other key directions.
"@
    }
    return $fileRefs + $interviewContext
}

# Initialize session for execution phase tracking
$sessionResult = Invoke-SessionInitialize -Arguments @{ session_type = "autonomous" }
if ($sessionResult.success) {
    $sessionId = $sessionResult.session.session_id
}
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Workflow child started (session: $sessionId, PID: $PID)"

# Load the single-session prompt template through Dotbot.Content: project
# overrides at <BotRoot>/content/prompts/ win over DOTBOT_HOME content at
# <DOTBOT_HOME>/content/prompts/. A missing template fails fast at startup.
if (-not (Get-Command Resolve-DotbotContent -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Content" "Dotbot.Content.psm1") -DisableNameChecking -Global
}

$executionTemplateFile = Resolve-DotbotContent -BotRoot $botRoot -Type prompts -Name '100-single-session-task.md'
if (-not $executionTemplateFile) {
    throw "Execution prompt '100-single-session-task.md' not found in project (<BotRoot>/content/prompts/) or DOTBOT_HOME content (<DOTBOT_HOME>/content/prompts/)."
}
try {
    $executionPromptTemplate = Get-Content -Path $executionTemplateFile -Raw -ErrorAction Stop
} catch {
    throw "Failed to load execution prompt template '$executionTemplateFile'. Ensure the file is readable. $($_.Exception.Message)"
}
if ([string]::IsNullOrWhiteSpace($executionPromptTemplate)) {
    throw "Execution prompt template '$executionTemplateFile' is empty. A non-empty prompt template is required."
}
$defaultExecutionPromptTemplate = $executionPromptTemplate

$processData.workflow = "workflow (single-session task attempts)"

# Standards and product context (for execution phase)
$standardsList = ""
$productMission = ""
$entityModel = ""
$standardsDir = Join-Path $botRoot "recipes/standards/global"
if (Test-Path $standardsDir) {
    $standardsFiles = Get-ChildItem -Path $standardsDir -Filter "*.md" -File |
        ForEach-Object { ".bot/recipes/standards/global/$($_.Name)" }
    $standardsList = if ($standardsFiles) { "- " + ($standardsFiles -join "`n- ") } else { "No standards files found." }
}
$productDir = Join-Path (Join-Path $botRoot 'workspace') 'product'
$productMission = if (Test-Path (Join-Path $productDir "mission.md")) { "Read the product mission and context from: .bot/workspace/product/mission.md" } else { "No product mission file found." }
$entityModel = if (Test-Path (Join-Path $productDir "entity-model.md")) { "Read the entity model design from: .bot/workspace/product/entity-model.md" } else { "No entity model file found." }

# Dotbot.Task carries post-task hooks; Dotbot.Executor owns non-prompt
# task execution.
Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Task" "Dotbot.Task.psd1") -Force -DisableNameChecking
$runtimeRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $runtimeRoot "Modules" "Dotbot.Executor" "Dotbot.Executor.psd1") -Force -DisableNameChecking
$executorRegistry = Get-ExecutorRegistry -ExecutorsDir (Get-DotbotExecutorsDir -RuntimeRoot $runtimeRoot)

# Clean up orphan worktrees
Remove-OrphanWorktrees -ProjectRoot $projectRoot -BotRoot $botRoot

# Diagnostic snapshot of the task scope. Workflow runs are bounded by a
# WorkflowRun directory; pending-task runners intentionally run unscoped.
$runDir = $null
if ($RunId) {
    $runDir = Find-WorkflowRunDir -BotRoot $botRoot -RunId $RunId
    if (-not $runDir) {
        throw "Invoke-WorkflowProcess: could not resolve run_dir for RunId '$RunId'. Bootstrap via Initialize-WorkflowRun first."
    }
} else {
    $runDir = $tasksBaseDir
}
$taskSnapshotRecurse = -not [bool]$RunId

# Crash recovery: reset in-progress tasks left by a previously killed runner.
# For RunId runs: scoped to this run's dir — no exclusion needed.
# For no-RunId (pending-task-scope): collect active run IDs so we don't touch
# tasks that belong to a workflow run with a live process.
$crashRecoveryParams = @{ RunDir = $runDir; Recurse = $taskSnapshotRecurse }
if ($WorkflowName) { $crashRecoveryParams['WorkflowName'] = $WorkflowName }
if (-not $RunId) {
    $activeRunIds = @(
        Get-ChildItem -LiteralPath $processesDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $p = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                $pStatus = if ($p.PSObject.Properties['status'])  { [string]$p.status  } else { $null }
                $pRunId  = if ($p.PSObject.Properties['run_id'])  { [string]$p.run_id  } else { $null }
                $pPid    = if ($p.PSObject.Properties['pid'])     { $p.pid             } else { $null }
                # Only exclude run_id when the process is running/starting AND its PID is still alive.
                # Killed processes leave status='running' in their file — PID check distinguishes live vs stale.
                if ($pStatus -in @('running', 'starting') -and $pRunId -and $pPid) {
                    if (Get-Process -Id $pPid -ErrorAction SilentlyContinue) { $pRunId }
                }
            } catch {
                Write-BotLog -Level Debug -Message "Crash recovery: failed to read process file '$($_.Name)'" -Exception $_
            }
        } | Where-Object { $_ }
    )
    if ($activeRunIds.Count -gt 0) { $crashRecoveryParams['ExcludeRunIds'] = $activeRunIds }
}
$recovered = Reset-InProgressTasks @crashRecoveryParams
if (-not $recovered) { $recovered = @() }
if ($recovered.Count -gt 0) {
    $recoveredNames = ($recovered | ForEach-Object { $_['name'] }) -join ', '
    Write-Status "Crash recovery: reset $($recovered.Count) in-progress task(s) to todo: $recoveredNames" -Type Warn
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Crash recovery: reset $($recovered.Count) in-progress task(s) to todo"
}
$needsInputOnStart = @(Get-NeedsInputTasksInScope -RunDir $runDir -Recurse:$taskSnapshotRecurse -WorkflowName $WorkflowName)
if ($needsInputOnStart.Count -gt 0) {
    $niNames = ($needsInputOnStart | ForEach-Object { if ($_.PSObject.Properties['name'] -and $_.name) { [string]$_.name } else { [string]$_.id } }) -join ', '
    Write-Status "Resuming: $($needsInputOnStart.Count) task(s) awaiting user input: $niNames. Open ACTION REQUIRED in the control panel." -Type Warn
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Resuming with $($needsInputOnStart.Count) task(s) awaiting user input: $niNames"
}

$todoCount = 0
foreach ($f in @(Get-ChildItem -LiteralPath $runDir -Filter '*.json' -File -Recurse:$taskSnapshotRecurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -ne 'run.json' })) {
    try {
        $t = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
        if ($WorkflowName -and -not $RunId) {
            $tw = if ($t.PSObject.Properties['provenance'] -and $t.provenance) { [string]$t.provenance.workflow } else { $null }
            if ($tw -ne $WorkflowName) { continue }
        }
        switch ([string]$t.status) {
            'todo'     { $todoCount++ }
        }
    } catch { continue }
}
$scopeLabel = if ($RunId) { "Run $RunId" } else { "Pending task scope" }
Write-ProcessActivity -Id $procId -ActivityType "text" -Message "$scopeLabel loaded: $todoCount todo"

# Pre-flight: warn if main repo has uncommitted non-.bot/ files.
# These don't block execution (verification runs in the worktree) but can
# complicate the squash-merge stash/pop if left unresolved.
try {
    $mainDirtyStatus = git -C $projectRoot status --porcelain 2>$null
    $mainDirtyFiles  = @($mainDirtyStatus | Where-Object { $_ -notmatch '\.bot/' })
    if ($mainDirtyFiles.Count -gt 0) {
        $fileList = ($mainDirtyFiles | ForEach-Object { $_.Substring(3).Trim() }) -join ', '
        Write-Status "Pre-flight: Main repo has $($mainDirtyFiles.Count) uncommitted non-.bot/ file(s). Commit them to avoid squash-merge complications: $fileList" -Type Warn
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pre-flight warning: Main repo has $($mainDirtyFiles.Count) uncommitted file(s) outside .bot/ ($fileList). Consider committing before workflow."
    }
} catch { Write-BotLog -Level Debug -Message "Git operation failed" -Exception $_ }

$tasksProcessed = 0
$maxRetriesPerTask = 2
$consecutiveFailureThreshold = 3

# Workflows require a git repo. Repositories with no commits are valid:
# task worktrees use git's orphan mode until the first completed task
# establishes the base branch.
$gitPath = Join-Path $projectRoot '.git'
if (-not (Test-Path -LiteralPath $gitPath)) {
    throw "Workflow runs require a git repo. Initialise git first, then retry."
}
$isGitRepo = @(git -C $projectRoot rev-parse --is-inside-work-tree 2>$null)
if ($LASTEXITCODE -ne 0 -or $isGitRepo.Count -eq 0 -or ([string]$isGitRepo[0]).Trim() -ne 'true') {
    throw "Workflow runs require a git repo. Initialise git first, then retry."
}
git -C $projectRoot rev-parse --verify HEAD 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pre-flight: Git repo has no commits; first task will use an orphan worktree."
}

# Update process status to running
$processData.status = 'running'
Write-ProcessFile -Id $procId -Data $processData

$integrationBranch = $null
$resolvedBase = $null
if ($RunId) {
    $resolvedBase = Resolve-DotbotBaseBranch -ProjectRoot $projectRoot -BotRoot $botRoot
    if (-not $resolvedBase) {
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "No base branch yet (unborn repo); skipping integration branch — first task uses an orphan worktree."
    } else {
        $integrationSlug  = ConvertTo-WorktreeSlug -Text $WorkflowName
        $integrationShort = Get-ShortId -Id $RunId
        $integrationBranch = Get-WorktreeBranchName -Slug $integrationSlug -ShortId $integrationShort
        git -C $projectRoot rev-parse --verify $integrationBranch 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            git -C $projectRoot branch $integrationBranch $resolvedBase 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create integration branch '$integrationBranch' off '$resolvedBase' in $projectRoot."
            }
        }
        Write-Status "Integration branch: $integrationBranch (off $resolvedBase)" -Type Info
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Integration branch $integrationBranch created off $resolvedBase; tasks will squash-merge into it."
    }
}

$loopIteration = 0
try {
    while ($true) {
        $loopIteration++
        Write-Diag "--- Loop iteration $loopIteration ---"

        # Check max tasks
        Write-Diag "MaxTasks check: tasksProcessed=$tasksProcessed, MaxTasks=$MaxTasks"
        if ($MaxTasks -gt 0 -and $tasksProcessed -ge $MaxTasks) {
            Write-Status "Reached maximum task limit ($MaxTasks)" -Type Warn
            Write-Diag "EXIT: MaxTasks reached"
            break
        }

        # Check stop signal
        if (Test-ProcessStopSignal -Id $procId) {
            Write-Status "Stop signal received" -Type Error
            Write-Diag "EXIT: Stop signal received"
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process stopped by user"
            break
        }

        # ===== Pick next task =====
        # Stagger task pulls: each slot waits a random prime-number of seconds.
        # Primes (5,7,11,13) minimize collision probability between slots.
        if ($Slot -gt 0) {
            $staggerOptions = @(5, 7, 11, 13)
            $staggerSec = $staggerOptions | Get-Random
            Write-Status "Slot ${Slot}: stagger wait ${staggerSec}s..." -Type Info
            for ($sw = 0; $sw -lt $staggerSec; $sw++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
        }

        Write-Status "Fetching next task..." -Type Process

        # Walk the run directory fresh on every pickup (no in-memory index).
        $taskResult = Get-NextWorkflowTask -BotRoot $botRoot -RunId $RunId -WorkflowName $WorkflowName

        Write-Diag "TaskPickup: success=$($taskResult.success) hasTask=$($null -ne $taskResult.task) msg=$($taskResult.message)"

        if (-not $taskResult.success) {
            Write-Status "Error fetching task: $($taskResult.message)" -Type Error
            Write-Diag "EXIT: Error fetching task: $($taskResult.message)"
            break
        }

        if (-not $taskResult.task) {
            # The run is bounded — when every task is terminal, the runner has
            # nothing more to do. Exit cleanly instead of polling forever.
            if ($RunId -and (Test-WorkflowComplete -BotRoot $botRoot -RunId $RunId)) {
                $completeMsg = "Workflow run '$RunId' complete — all tasks in terminal state. Exiting task-runner."
                Write-Status $completeMsg -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message $completeMsg
                Write-Diag "EXIT: Run '$RunId' complete"
                break
            }
            if (-not $RunId) {
                $needsInputNow = @(Get-NeedsInputTasksInScope -RunDir $runDir -Recurse:$taskSnapshotRecurse -WorkflowName $WorkflowName)
                if ($needsInputNow.Count -gt 0) {
                    $niNames = ($needsInputNow | ForEach-Object { if ($_.PSObject.Properties['name'] -and $_.name) { [string]$_.name } else { [string]$_.id } }) -join ', '
                    Write-Status "Waiting for user input on $($needsInputNow.Count) task(s): $niNames. Answer in ACTION REQUIRED." -Type Info
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for user input on: $niNames"
                    $foundTask = $false
                    while ($true) {
                        Start-Sleep -Seconds 5
                        if (Test-ProcessStopSignal -Id $procId) {
                            $processData.status = 'stopped'
                            $processData.failed_at = (Get-Date).ToUniversalTime().ToString('o')
                            Write-ProcessFile -Id $procId -Data $processData
                            Write-ProcessActivity -Id $procId -ActivityType 'text' -Message 'Process stopped by user'
                            break
                        }
                        $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                        Write-ProcessFile -Id $procId -Data $processData
                        $taskResult = Get-NextWorkflowTask -BotRoot $botRoot -RunId $RunId -WorkflowName $WorkflowName
                        if ($taskResult.task) { $foundTask = $true; break }
                        $needsInputNow = @(Get-NeedsInputTasksInScope -RunDir $runDir -Recurse:$taskSnapshotRecurse -WorkflowName $WorkflowName)
                        if ($needsInputNow.Count -eq 0) { break }
                    }
                    if ($foundTask) { continue }
                    if ($processData.status -eq 'stopped') { break }
                    continue
                }
                $completeMsg = "No pending tasks available. Exiting pending-tasks runner."
                Write-Status $completeMsg -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message $completeMsg
                Write-Diag "EXIT: Pending task scope drained"
                break
            }

            if ($Continue -and -not $NoWait) {
                $waitReason = if ($taskResult.message) { $taskResult.message } else { "No eligible tasks." }
                Write-Status "No tasks available - waiting... ($waitReason)" -Type Info
                Write-Diag "Entering wait loop (Continue=$Continue, NoWait=$NoWait): $waitReason"
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Waiting for new tasks..."

                $foundTask = $false
                while ($true) {
                    Start-Sleep -Seconds 5
                    if (Test-ProcessStopSignal -Id $procId) { break }
                    $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                    $taskResult = Get-NextWorkflowTask -BotRoot $botRoot -RunId $RunId -WorkflowName $WorkflowName
                    if ($taskResult.task) { $foundTask = $true; break }

                    if ($RunId -and (Test-WorkflowComplete -BotRoot $botRoot -RunId $RunId)) {
                        $completeMsg = "Workflow run '$RunId' complete — all tasks in terminal state. Exiting task-runner."
                        Write-Status $completeMsg -Type Info
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message $completeMsg
                        Write-Diag "EXIT: Run '$RunId' complete during wait loop"
                        break
                    }

                    if ($RunId -and (Test-DependencyDeadlock -ProcessId $procId -BotRoot $botRoot -RunId $RunId)) { break }
                }
                if (-not $foundTask) {
                    Write-Diag "EXIT: No task found after wait loop (foundTask=$foundTask)"
                    break
                }
            } else {
                Write-Status "No tasks available" -Type Info
                Write-Diag "EXIT: No tasks and Continue not set"
                break
            }
        }

        $task = $taskResult.task

        # --- Non-prompt task slot guard (before claim) ---
        # Script/mcp/task_gen tasks must only run on slot 0.
        # Check BEFORE claiming to avoid orphaning tasks in in-progress.
        $taskTypeCheck = if ($task.type) { $task.type } else { 'prompt' }
        if ($taskTypeCheck -eq 'prompt_template') { $taskTypeCheck = 'prompt' }

        # Tasks whose outputs_dir is tasks/* (i.e. task-creating tasks) must
        # also run on slot 0 only. Their baseline-delta validation counts files
        # across the global tasks/ directory and cannot attribute new files to
        # a specific slot, so concurrent execution would yield false-positive
        # validation passes. Covers prompt_template task_gen mappings whose
        # type-check would otherwise let them run on any slot.
        $taskOutputsDirGuard = if ($task -is [System.Collections.IDictionary]) {
            $task['outputs_dir']
        } else { $task.outputs_dir }
        if (-not $taskOutputsDirGuard) {
            $taskOutputsDirGuard = if ($task -is [System.Collections.IDictionary]) {
                $task['required_outputs_dir']
            } else { $task.required_outputs_dir }
        }
        $isTaskGenerator = $taskOutputsDirGuard -and ($taskOutputsDirGuard -like 'tasks/*' -or $taskOutputsDirGuard -eq 'tasks')

        if ($Slot -gt 0 -and ($taskTypeCheck -notin @('prompt') -or $isTaskGenerator)) {
            $reasonLabel = if ($isTaskGenerator) { "$taskTypeCheck task with outputs_dir under tasks/" } else { $taskTypeCheck }
            Write-Status "Slot ${Slot}: skipping $reasonLabel '$($task.name)' (slot 0 only)" -Type Info
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Slot ${Slot}: waiting (skipping $reasonLabel)"
            Start-Sleep -Seconds 5
            continue
        }

        # --- Multi-slot claim guard ---
        # When running with -Slot (concurrent workflow processes), another slot may
        # have claimed this task between our Get-NextWorkflowTask and this point.
        # Only needed for prompt tasks — non-prompt tasks have their own claim guard
        # before worktree creation below.
        if ($Slot -ge 0 -and $taskTypeCheck -eq 'prompt') {
            $claimOk = $false
            for ($claimAttempt = 0; $claimAttempt -lt 5; $claimAttempt++) {
                try {
                    $claimResult = $null
                    if ($task.status -ne 'in-progress') {
                        $claimResult = Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id }
                    }
                    if ($claimResult -and -not $claimResult.success) {
                        throw $claimResult.message
                    }
                    # Detect if another slot already claimed this task. The
                    # runtime status endpoint reports same-status writes as a
                    # no-op inside body.no_op.
                    if ($claimResult -and $claimResult.body -and $claimResult.body.no_op) {
                        throw "Task already claimed"
                    }
                    if ($claimResult) { $task.status = 'in-progress' }
                    $claimOk = $true
                    break
                } catch {
                    Write-Diag "Slot ${Slot}: task $($task.id) claimed by another slot, retrying..."
                    Start-Sleep -Milliseconds 200
                    $taskResult = Get-NextWorkflowTask -BotRoot $botRoot -RunId $RunId -WorkflowName $WorkflowName
                    if (-not $taskResult.task) { break }
                    $task = $taskResult.task
                }
            }
            if (-not $claimOk) {
                Write-Status "Slot ${Slot}: could not claim a task after $($claimAttempt + 1) attempts" -Type Warn
                if ($Continue) { continue } else { break }
            }
        }

        $processData.task_id = $task.id
        $processData.task_name = $task.name
        $env:DOTBOT_CURRENT_TASK_ID = $task.id
        $taskTypeForHeader = if ($task.type) { $task.type } else { 'prompt' }
        Write-TaskHeader -TaskName $task.name -TaskType $taskTypeForHeader -Model $Model -ProcessId $procId
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Processing task: $($task.name) (id: $($task.id), status: $($task.status))"
        Write-Diag "Selected task: id=$($task.id) name=$($task.name) status=$($task.status)"

        try {   # Per-task try/catch — catches failures in BOTH analysis and execution phases

        # Defensive per-iteration init: the post-task hook flags are set on the
        # success path further down (around the execution-phase init block).
        # Set them here too so that any exception escaping before that block
        # (e.g. a Build-TaskPrompt failure) cannot leave the elseif at the
        # post-loop branch reading an unset variable under StrictMode.
        $postScriptFailed = $false
        $postScriptError = $null
        $postScriptFailureSource = 'post_script'

        # --- Prompt setup + executor dispatch for non-prompt tasks ---
        $taskTypeVal = if ($task.type) { $task.type } else { 'prompt' }
        $taskExecutionPromptTemplate = $defaultExecutionPromptTemplate
        # prompt/prompt_template tasks can use a workflow-specific prompt file
        # and then fall through to the normal Claude execution path below.
        if ($taskTypeVal -in @('prompt', 'prompt_template') -and $task.prompt) {
            $templatePath = Resolve-WorkflowPromptTemplateFile -BotRoot $botRoot -WorkflowName $task.workflow -PromptReference $task.prompt
            if ($templatePath) {
                # Override the execution prompt template for this task
                $taskExecutionPromptTemplate = Get-Content -LiteralPath $templatePath -Raw
                Write-Status "Using workflow prompt: $($task.prompt)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Prompt template: $($task.prompt)"
            }
            # Fall through to normal analysis+execution below (treated as 'prompt')
            $taskTypeVal = 'prompt'
        }
        # Recover task_gen tasks that reference a prompt template but have no script_path.
        # Must run before the auto-dispatch gate so a recovered task falls through to the
        # normal analysis+execution path instead of being dispatched (and skipped).
        if ($taskTypeVal -eq 'task_gen' -and -not $task.script_path -and $task.workflow) {
            try {
                if (-not (Get-Command Read-WorkflowManifest -ErrorAction SilentlyContinue)) {
                    Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Workflow" "Dotbot.Workflow.psd1") -DisableNameChecking -Global
                }
                $wfTaskDir = Resolve-WorkflowDirByName -BotRoot $botRoot -Name $task.workflow
                if ($wfTaskDir -and (Test-ValidWorkflowDir -Dir $wfTaskDir)) {
                    $wfManifest = Read-WorkflowManifest -WorkflowDir $wfTaskDir
                    $matchingPhase = $wfManifest.tasks | Where-Object { $_['name'] -eq $task.name } | Select-Object -First 1
                    if ($matchingPhase -and $matchingPhase['workflow']) {
                        $recoveredPromptRef = "prompts/$($matchingPhase['workflow'])"
                        $tplPath = Resolve-WorkflowPromptTemplateFile -BotRoot $botRoot -WorkflowName $task.workflow -PromptReference $recoveredPromptRef
                        if ($tplPath) {
                            Write-Status "Recovering task_gen '$($task.name)' as prompt_template: $recoveredPromptRef" -Type Info
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Recovered prompt template: $recoveredPromptRef"
                            $taskExecutionPromptTemplate = Get-Content -LiteralPath $tplPath -Raw
                            $taskTypeVal = 'prompt'
                        }
                    }
                }
            } catch { Write-BotLog -Level Debug -Message "Manifest recovery failed" -Exception $_ }
        }
        if ($taskTypeVal -notin @('prompt')) {
            Write-Status "Auto-dispatching $taskTypeVal task: $($task.name)" -Type Process
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Auto-dispatch $taskTypeVal task: $($task.name)"

            # --- Non-prompt task claim guard (before worktree) ---
            # Unconditional (no $Slot guard): covers standalone runners (Slot = null/0)
            # AND multi-slot runners on slot 0. The prompt-task guard above is $Slot-gated
            # because prompt concurrency only occurs in multi-slot mode; non-prompt races
            # also occur between standalone processes sharing the same task pool.
            $claimOk = $false
            $claimAttemptsMade = 0
            for ($claimAttempt = 0; $claimAttempt -lt 5; $claimAttempt++) {
                $claimAttemptsMade++
                try {
                    $claimResult = $null
                    if ($task.status -notin @('todo', 'needs-input', 'in-progress')) {
                        throw "Cannot dispatch non-prompt task '$($task.id)' from status '$($task.status)'"
                    }
                    if ($task.status -ne 'in-progress') {
                        $claimResult = Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id }
                    }
                    if ($claimResult -and -not $claimResult.success) {
                        $errMsg = if ($claimResult.message) { $claimResult.message } else { "HTTP $($claimResult.status_code)" }
                        throw "Claim failed: $errMsg"
                    }
                    if ($claimResult -and $claimResult.body -and $claimResult.body.no_op) {
                        throw "Task already claimed"
                    }
                    if ($claimResult) { $task.status = 'in-progress' }
                    $claimOk = $true
                    break
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -notmatch 'already claimed|Claim failed') {
                        Write-Status "Fatal error claiming task $($task.id): $errMsg" -Type Error
                        throw
                    }
                    Write-Diag "Task $($task.id) claimed by another runner, retrying ($taskTypeVal)..."
                    Start-Sleep -Milliseconds 200
                    # Break unconditionally — outer loop re-fetches and re-processes the next
                    # task with full task_gen/prompt_template recovery. Fetching here is dead
                    # code (result discarded on break) and opens a small race window.
                    break
                }
            }
            if (-not $claimOk) {
                Write-Status "Could not claim a $taskTypeVal task after $claimAttemptsMade attempts" -Type Warn
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Could not claim $taskTypeVal task after $claimAttemptsMade attempts"
                if ($Continue) { Start-Sleep -Seconds 2; continue } else { break }
            }
            # Task may have been replaced during claim retry; re-sync process metadata.
            $processData.task_id = $task.id
            $processData.task_name = $task.name
            $env:DOTBOT_CURRENT_TASK_ID = $task.id

            $worktreePath = $null
            $branchName = $null
            $worktreeSetup = Initialize-DotbotTaskWorktreeForProcess -Task $task `
                -ProjectRoot $projectRoot -BotRoot $botRoot -ProcessId $procId -BaseBranch $integrationBranch
            if ($worktreeSetup) {
                $worktreePath = $worktreeSetup.worktree_path
                $branchName = $worktreeSetup.branch_name
            }
            $executionBotRoot = Join-Path $worktreePath ".bot"
            $executionProductDir = Join-Path (Join-Path $executionBotRoot 'workspace') 'product'

            $typeSuccess = $false
            $typeError = $null
            $typeMergeBlocked = $false
            $workflowDir = $null
            if ($task.workflow) {
                $workflowDir = Resolve-WorkflowDirByName -BotRoot $botRoot -Name $task.workflow
            }

            # Snapshot pre-task baseline for outputs_dir validation. Test-TaskOutput
            # uses this to compare the delta the task produced rather than the
            # absolute count, so e.g. a task_gen with min_output_count: 1 must
            # actually produce a new task file (not just rely on tasks already
            # in tasks/todo from manifest pre-creation).
            $taskOutputBaseline = Get-TaskOutputBaseline -Task $task -BotRoot $executionBotRoot

            try {
                $savedGlobalProjectRoot = Get-Variable -Scope Global -Name DotbotProjectRoot -ErrorAction SilentlyContinue
                $savedGlobalBotRoot = Get-Variable -Scope Global -Name DotbotBotRoot -ErrorAction SilentlyContinue
                $savedEnvProjectRoot = $env:DOTBOT_PROJECT_ROOT
                $savedEnvBotRoot = $env:DOTBOT_BOT_ROOT
                try {
                    $global:DotbotProjectRoot = $worktreePath
                    $global:DotbotBotRoot = $executionBotRoot
                    $env:DOTBOT_PROJECT_ROOT = $worktreePath
                    $env:DOTBOT_BOT_ROOT = $executionBotRoot

                    $executorResult = Invoke-TaskExecutor -Task $task -Registry $executorRegistry `
                        -RunContext (New-ExecutorRunContext -Task $task -WorkflowDir $workflowDir -WorktreePath $worktreePath -BranchName $branchName)
                } finally {
                    if ($savedGlobalProjectRoot) { $global:DotbotProjectRoot = $savedGlobalProjectRoot.Value }
                    else { Remove-Variable -Scope Global -Name DotbotProjectRoot -ErrorAction SilentlyContinue }

                    if ($savedGlobalBotRoot) { $global:DotbotBotRoot = $savedGlobalBotRoot.Value }
                    else { Remove-Variable -Scope Global -Name DotbotBotRoot -ErrorAction SilentlyContinue }

                    if ($null -ne $savedEnvProjectRoot) { $env:DOTBOT_PROJECT_ROOT = $savedEnvProjectRoot }
                    else { Remove-Item Env:DOTBOT_PROJECT_ROOT -ErrorAction SilentlyContinue }

                    if ($null -ne $savedEnvBotRoot) { $env:DOTBOT_BOT_ROOT = $savedEnvBotRoot }
                    else { Remove-Item Env:DOTBOT_BOT_ROOT -ErrorAction SilentlyContinue }
                }
                $typeSuccess = [bool]$executorResult['Success']
                if (-not $typeSuccess) {
                    $typeError = if ($executorResult.ContainsKey('Message')) { $executorResult['Message'] } else { "Executor returned Success=false" }
                } elseif ($executorResult.ContainsKey('Message') -and $executorResult['Message']) {
                    Write-Diag "Executor result: $($executorResult['Message'])"
                }
            } catch {
                $typeError = $_.Exception.Message
                Write-Status "Task type execution failed: $typeError" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$($task.name): $typeError"
            }

            # Post-script hook: run after successful executor work, before the
            # move to done/. There is no task_set_status(done) call on this path
            # (executor tasks skip verification hooks), so the post-script is
            # the last thing to run before the task is considered complete. On
            # failure, $typeSuccess is flipped so the task is marked skipped below.
            if ($typeSuccess) {
                $psErr = Invoke-TaskPostScriptIfPresent -Task $task -BotRoot $executionBotRoot `
                    -ProductDir $executionProductDir -Settings $settings -Model $modelTier -ProcessId $procId
                if ($psErr) {
                    $typeSuccess = $false
                    $typeError = $psErr
                }
            }

            if ($typeSuccess) {
                $testOutputArgs = @{
                    Task       = $task
                    BotRoot    = $executionBotRoot
                    ProductDir = $executionProductDir
                }
                if ($null -ne $taskOutputBaseline -and $taskOutputBaseline -ge 0) {
                    $testOutputArgs.BaselineCount = $taskOutputBaseline
                }
                $outputErr = Test-TaskOutput @testOutputArgs
                if ($outputErr) {
                    $typeSuccess = $false
                    $typeError = $outputErr
                }
            }

            if ($typeSuccess) {
                try {
                    Add-TaskFrontMatter -Task $task -ProductDir $executionProductDir -ProcId $procId -ModelName $modelTier
                } catch {
                    # Add-JsonFrontMatter / file IO can throw. Convert to a
                    # controlled task failure so the runner doesn't crash and
                    # the task is reported via the same skipped/failed path.
                    $typeSuccess = $false
                    $typeError = "Failed to add task front matter: $($_.Exception.Message)"
                }
            }

            if ($typeSuccess) {
                # Non-prompt executors use the same runtime status endpoint as
                # prompt tasks. The task file stays in its workflow-run folder;
                # status is data, not a directory move.
                try {
                    $doneResult = _PostTaskStatus -TaskId $task.id -To 'done' -Reason "$taskTypeVal executor completed"
                    if (-not $doneResult.success) {
                        throw $doneResult.message
                    }
                } catch {
                    Write-Status "Failed to mark done: $($_.Exception.Message)" -Type Warn
                    $typeSuccess = $false
                    $typeError = "Failed to mark done: $($_.Exception.Message)"
                }
            }

            if ($typeSuccess) {
                Write-Status "Merging task branch to main..." -Type Process
                $mergeResult = Complete-TaskWorktree -TaskId $task.id -ProjectRoot $projectRoot -BotRoot $botRoot -SkipRemotePush:($null -ne $integrationBranch)
                if ($mergeResult.success) {
                    Write-Status "Merged: $($mergeResult.message)" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Squash-merged to main: $($task.name)"
                    if ($mergeResult.push_result.attempted) {
                        if ($mergeResult.push_result.success) {
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pushed to remote: $($task.name)"
                        } else {
                            Write-Status "Push failed: $($mergeResult.push_result.error)" -Type Warn
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Push failed after merge: $($mergeResult.push_result.error)"
                        }
                    }
                } else {
                    $typeSuccess = $false
                    $typeError = "Merge failed ($($mergeResult.failure_kind)): $($mergeResult.message)"
                    $typeMergeBlocked = $true
                    $mrKind = if ($mergeResult.failure_kind) { $mergeResult.failure_kind } else { 'unknown' }
                    Write-Status "Merge failed ($mrKind): $($mergeResult.message)" -Type Error

                    $mergeContextParts = @("Merge failure kind: $mrKind", "Message: $($mergeResult.message)")
                    if ($mergeResult.failure_detail) { $mergeContextParts += "Detail: $($mergeResult.failure_detail)" }
                    if ($mergeResult.conflict_files) { $mergeContextParts += "Conflict files: $(@($mergeResult.conflict_files) -join ', ')" }
                    if ($worktreePath) { $mergeContextParts += "Worktree preserved at: $worktreePath" }
                    try {
                        $escalated = Set-WorkflowTaskNeedsInput `
                            -Task $task `
                            -RunDir $runDir `
                            -QuestionId "merge-failure-$($task.id)" `
                            -Question "Merge failed for task '$($task.name)'" `
                            -Context ($mergeContextParts -join "`n")
                        if (-not $escalated) {
                            Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Merge-failure escalation could not locate $($task.name)"
                        }
                    } catch {
                        Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Merge-failure escalation failed for $($task.name): $($_.Exception.Message)"
                    }
                }
            }

            if ($typeSuccess) {
                Write-Status "Task completed: $($task.name)" -Type Complete
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completed $taskTypeVal task: $($task.name)"
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $tasksProcessed++
            } elseif ($typeMergeBlocked) {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task merge failed, worktree retained for manual resolution: $($task.name)"
            } else {
                Write-Status "Task failed: $($task.name)" -Type Error
                try {
                    Set-TaskTerminalFailureForExecutorDispatch -Task $task -Detail "$taskTypeVal execution failed: $typeError"
                } catch { Write-BotLog -Level Debug -Message "Session operation failed" -Exception $_ }

                if ($worktreePath) {
                    try {
                        Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                        git -C $projectRoot worktree remove $worktreePath --force 2>$null
                        if ($branchName) { git -C $projectRoot branch -D $branchName 2>$null }
                    } finally {
                        Invoke-WorktreeMapLocked -BotRoot $botRoot -Action {
                            $cleanupMap = Read-WorktreeMap -BotRoot $botRoot
                            $cleanupMap.Remove($task.id)
                            Write-WorktreeMap -Map $cleanupMap -BotRoot $botRoot
                        }
                        try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                    }
                }

                # Mandatory-task halt (#213): executor task failure
                if (Test-TaskIsMandatory $task) {
                    Write-Status "Mandatory task failed: $($task.name) - stopping workflow" -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Mandatory task failed, stopping workflow: $($task.name)"
                    Write-Diag "EXIT: Mandatory task failure ($taskTypeVal execution)"
                    try {
                        $state = Invoke-SessionGetState -Arguments @{}
                        Invoke-SessionUpdate -Arguments @{
                            consecutive_failures = $state.state.consecutive_failures + 1
                            tasks_skipped = $state.state.tasks_skipped + 1
                        } | Out-Null
                    } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
                    $processData.status = 'stopped'
                    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                    Write-ProcessFile -Id $procId -Data $processData
                    break
                }
            }

            # Continue to next task (skip analysis + execution phases)
            $TaskId = $null
            $processData.task_id = $null
            $processData.task_name = $null
            for ($i = 0; $i -lt 3; $i++) {
                Start-Sleep -Seconds 1
                if (Test-ProcessStopSignal -Id $procId) { break }
            }
            continue
        }

        # Create or repair the execution worktree before the provider starts so
        # MCP discovery, discovery reads, and edits use the same checkout.
        $worktreePath = $null
        $branchName = $null
        $worktreeSetup = Initialize-DotbotTaskWorktreeForProcess -Task $task `
            -ProjectRoot $projectRoot -BotRoot $botRoot -ProcessId $procId -BaseBranch $integrationBranch
        if ($worktreeSetup) {
            $worktreePath = $worktreeSetup.worktree_path
            $branchName = $worktreeSetup.branch_name
        }

        Write-Status "Checking dotbot MCP tools..." -Type Process
        $mcpReady = Test-DotbotMcpReadiness -WorktreePath $worktreePath -ProjectRoot $projectRoot
        if (-not $mcpReady.ok) {
            throw "dotbot MCP preflight failed ($($mcpReady.reason)): $($mcpReady.message)"
        }
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "dotbot MCP preflight passed ($($mcpReady.tool_count) tools)"

        # Claim the task for execution directly. Discovery is part of the
        # single provider session, not a separate analysis phase.
        if ($task.status -ne 'in-progress') {
            $claimForExecution = Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id }
            if (-not $claimForExecution.success) { throw $claimForExecution.message }
            if ($claimForExecution.body -and $claimForExecution.body.no_op) {
                throw "Task $($task.id) was already claimed before execution started."
            }
            $task.status = 'in-progress'
        }

        # ===== Execution =====
        Write-Diag "Entering execution phase for task $($task.id)"
        $env:DOTBOT_CURRENT_PHASE = 'execution'
        $processData.heartbeat_status = "Executing: $($task.name)"
        Write-ProcessFile -Id $procId -Data $processData
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution phase started: $($task.name)"

        try {

        # Re-read task data if a concurrent state update changed the selected task.
        $freshTask = Get-NextWorkflowTask -BotRoot $botRoot -RunId $RunId -WorkflowName $WorkflowName
        Write-Diag "Execution TaskGetNext: hasTask=$($null -ne $freshTask.task) matchesId=$($freshTask.task.id -eq $task.id)"
        if ($freshTask.task -and $freshTask.task.id -eq $task.id) {
            $task = $freshTask.task
        }

        # Mark in-progress
        Invoke-TaskMarkInProgress -Arguments @{ task_id = $task.id } | Out-Null
        Invoke-SessionUpdate -Arguments @{ current_task_id = $task.id } | Out-Null

        # Product artifacts are branch-local for task worktrees. Runtime state
        # (tasks/control) remains linked through .bot, so using the worktree's
        # .bot root here gives post-hooks, output checks, and clarification
        # files the same view as the agent executing inside the worktree.
        $executionBotRoot = if ($worktreePath) { Join-Path $worktreePath ".bot" } else { $botRoot }
        $executionProductDir = Join-Path (Join-Path $executionBotRoot 'workspace') 'product'

        # Briefing files are stored per-run under the run directory (never a folder
        # shared across workflow invocations). Copy this run's briefing into the
        # execution product dir — the worktree's branch-local product for isolated
        # tasks — so the agent finds them at the unchanged ".bot/workspace/product/
        # briefing/..." paths that Get-WorkflowPromptContext emits.
        if ($runDir) {
            $runBriefingDir = Join-Path $runDir 'briefing'
            if (Test-Path -LiteralPath $runBriefingDir) {
                $destBriefingDir = Join-Path $executionProductDir 'briefing'
                if (-not (Test-Path -LiteralPath $destBriefingDir)) {
                    New-Item -ItemType Directory -Path $destBriefingDir -Force | Out-Null
                }
                # Enumerate then copy each entry by literal path. (Copy-Item
                # -LiteralPath does NOT expand a '*' wildcard — it would copy
                # nothing — so mirror the worktree seeder's pattern instead.)
                foreach ($bf in @(Get-ChildItem -LiteralPath $runBriefingDir -Force -ErrorAction SilentlyContinue)) {
                    Copy-Item -LiteralPath $bf.FullName -Destination $destBriefingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Use task-level model override > execution model from settings > default
        $executionModel = if ($task.model) { $task.model }
            elseif ($settings.execution?.model) { $settings.execution.model }
            else { 'best' }
        $executionModelTier = Resolve-HarnessModelTier -Model $executionModel

        # Snapshot pre-task baseline for outputs_dir validation (see non-prompt
        # path comment for rationale).
        $taskOutputBaseline = Get-TaskOutputBaseline -Task $task -BotRoot $executionBotRoot

        # Build execution prompt
        $executionPrompt = Build-TaskPrompt `
            -PromptTemplate $taskExecutionPromptTemplate `
            -Task $task `
            -SessionId $sessionId `
            -ProductMission $productMission `
            -EntityModel $entityModel `
            -StandardsList $standardsList `
            -InstanceId $instanceId

        $branchForPrompt = if ($branchName) { $branchName } else { "main" }
        $executionPrompt = $executionPrompt -replace '\{\{BRANCH_NAME\}\}', $branchForPrompt

        $execPromptContext = Get-WorkflowPromptContext -ProductDir $executionProductDir

        $fullExecutionPrompt = @"
$executionPrompt
$execPromptContext
## Process Context

- **Process ID:** $procId
- **Instance Type:** workflow (execution phase)

Use the Process ID when calling ``steering_heartbeat`` (pass it as ``process_id``).

## Completion Goal

Task $($task.id) is complete: all acceptance criteria met, verification passed, and task marked done.

Work on this task autonomously. When complete, ensure you call ``task_set_status({ task_id, status: 'done' })`` via MCP.
"@

        # Invoke provider for execution
        $executionSessionId = New-HarnessSession
        $env:CLAUDE_SESSION_ID = $executionSessionId
        $processData.claude_session_id = $executionSessionId
        Write-ProcessFile -Id $procId -Data $processData

        try {
            if (-not (Get-Command Start-DotbotTaskSessionAttempt -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $PSScriptRoot ".." "Modules" "Dotbot.Handoff" "Dotbot.Handoff.psd1") -DisableNameChecking -Global
            }
            $attemptTask = Get-WorkflowTaskContent -Task $task -RunDir $runDir
            if ($attemptTask -and $attemptTask.Content) {
                Start-DotbotTaskSessionAttempt -TaskContent $attemptTask.Content -ProviderSessionId $executionSessionId | Out-Null
                Write-TaskFileAtomic -Path $attemptTask.Path -Content $attemptTask.Content -Depth 20 -TaskId $task.id -BotRoot $botRoot
            }
        } catch {
            Write-BotLog -Level Warn -Message "Failed to record task session attempt for $($task.id)" -Exception $_
        }

        $taskSuccess = $false
        # Set when the agent calls task_set_status(needs-input). Distinct from
        # taskSuccess because a paused task is neither a success nor a failure
        # — its worktree must be retained so the next same-task session attempt
        # can resume after the human answer requeues the task.
        $taskParked = $false
        # Set when the task ended in a terminal state other than done
        # (skipped/cancelled/split). Distinct from taskSuccess because we must
        # NOT squash-merge the worktree, NOT count the task as completed, and
        # NOT log "task -> done". The worktree still has to be cleaned up.
        $taskTerminal = $false
        $taskTerminalState = $null
        $postScriptFailed = $false
        $postScriptError = $null
        # Distinguishes which post-task hook actually flipped postScriptFailed
        # so escalation messaging accurately names the failure source.
        $postScriptFailureSource = 'post_script'
        $attemptNumber = 0

        if ($worktreePath) { Push-Location $worktreePath }
        try {
        while ($attemptNumber -le $maxRetriesPerTask) {
            $attemptNumber++
            if ($attemptNumber -gt 1) {
                Write-Status "Retry attempt $attemptNumber of $maxRetriesPerTask" -Type Warn
            }
            if (Test-ProcessStopSignal -Id $procId -BotRoot $botRoot) {
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData -BotRoot $botRoot
                break
            }

            Write-Header "Execution Phase"
            $streamResult = $null
            $execErrorText = ''
            try {
                $streamArgs = @{
                    Prompt = $fullExecutionPrompt
                    Model = $executionModelTier
                    SessionId = $executionSessionId
                    PersistSession = $false
                }
                if ($ShowDebug) { $streamArgs['ShowDebugJson'] = $true }
                if ($ShowVerbose) { $streamArgs['ShowVerbose'] = $true }

                if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }
                # Execution phase: pin the provider cwd to the worktree so
                # Edit/Write/Bash land on the task branch instead of project
                # root (#314).
                if ($worktreePath) { $streamArgs['WorkingDirectory'] = $worktreePath }
                $streamArgs['ShouldStopStream'] = {
                    $completion = Test-TaskCompletion -TaskId $task.id
                    return [bool]$completion.completed
                }
                $streamArgs['StopReason'] = "task '$($task.id)' reached a terminal state"
                $streamArgs['StopGraceSeconds'] = $providerCompletionGraceSeconds
                $streamArgs['StopCheckIntervalSeconds'] = $providerStopCheckIntervalSeconds
                $streamResult = Invoke-HarnessStream @streamArgs
                $exitCode = if ($streamResult -and $streamResult.PSObject.Properties['ExitCode']) { [int]$streamResult.ExitCode } else { 0 }
            } catch {
                $execErrorText = $_.Exception.Message
                Write-Status "Execution error: $execErrorText" -Type Error
                $exitCode = 1
            }

            # Kill any background processes the provider may have spawned in the worktree
            # (e.g., dev servers started with pnpm dev &, npx next start &)
            if ($worktreePath) {
                $cleanedUp = Stop-WorktreeProcesses -WorktreePath $worktreePath
                if ($cleanedUp -gt 0) {
                    Write-Diag "Cleaned up $cleanedUp orphan process(es) after execution attempt"
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Cleaned up $cleanedUp background process(es) from worktree"
                }
            }

            # Update heartbeat
            $processData.last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData -BotRoot $botRoot

            # Check completion
            $completionCheck = Test-TaskCompletion -TaskId $task.id
            Write-Diag "Completion check: completed=$($completionCheck.completed) method=$($completionCheck.method) terminal_state=$($completionCheck.terminal_state)"
            if ($completionCheck.completed) {
                # Issue #318: distinguish done from other terminal states
                # (skipped/cancelled/split). Only done squash-merges to main and
                # counts as a completed task. Other terminals must clean up the
                # worktree without merging — otherwise an agent calling
                # task_set_status(skipped) silently merges its abandoned work.
                if ($completionCheck.method -eq 'TerminalState' -and $completionCheck.terminal_state -ne 'done') {
                    $taskTerminalState = $completionCheck.terminal_state
                    Write-Status "Task ended in terminal state: $taskTerminalState" -Type Info
                    Write-Information "task_state_change: $($task.id) -> $taskTerminalState [execution]" -Tags @('dotbot', 'task', 'state')
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task ended in terminal state '$taskTerminalState': $($task.name)"
                    $taskTerminal = $true
                    break
                }
                Write-Status "Task completed!" -Type Complete
                Write-Information "task_state_change: $($task.id) -> done [execution]" -Tags @('dotbot', 'task', 'state')
                Invoke-SessionIncrementCompleted -Arguments @{} | Out-Null
                $taskSuccess = $true
                break
            }

            # Task not completed - log diagnostic to help distinguish failure modes.
            $stillInProgress = $false
            $nowNeedsInput   = $false
            $doneHookBlock   = $null
            try {
                $currentTask = Get-WorkflowTaskContent -Task $task -RunDir $runDir
                if ($currentTask -and $currentTask.Content) {
                    $currentStatus = [string]$currentTask.Content.status
                    $stillInProgress = ($currentStatus -eq 'in-progress')
                    $nowNeedsInput = ($currentStatus -eq 'needs-input')
                    # Breadcrumb left by the transition layer when a verify hook
                    # aborted this task's done-transition (e.g. privacy scan).
                    $ext = $currentTask.Content.extensions
                    if ($ext -and $ext.runner -and $ext.runner.done_transition_block) {
                        $doneHookBlock = $ext.runner.done_transition_block
                    }
                }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }

            # Agent called task_set_status(needs-input) - task is paused for human input.
            # Mark it parked (not success, not failure) so the post-task path
            # below leaves the worktree alive and does not squash-merge.
            if ($nowNeedsInput) {
                Write-Status "Task paused for human input: $($task.name)" -Type Info
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task '$($task.name)' paused — waiting for human input (needs-input)"
                $taskParked = $true
                break
            }

            # A verify hook (e.g. privacy scan) blocked the done-transition: park to
            # needs-input so the operator fixes the flagged content, instead of
            # burning retries and mislabeling a done task skipped(max-retries).
            # Checked before the harness-error classification so this definitive
            # on-disk signal isn't pre-empted by heuristic text matching.
            if ($doneHookBlock) {
                $hookName = [string]$doneHookBlock.hook
                $hookMsg  = [string]$doneHookBlock.message
                # Defensive cap (breadcrumb is already truncated at the source) so an
                # oversized hook message can't bloat the task record / handoff — mirrors AuthError.
                if ($hookMsg.Length -gt 1000) { $hookMsg = $hookMsg.Substring(0, 1000) + " … [truncated, showing 1000 of $($hookMsg.Length) chars]" }
                $blockContext = "The done-transition was blocked by verify hook '$hookName': $hookMsg`nThe task's declared work may already be complete — resolve the flagged content (e.g. redact absolute local paths from the committed artifact), then re-run or approve. The retry budget was not consumed."
                Write-Status "Done-transition blocked by verify hook — parking for operator: $($task.name)" -Type Warn
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task '$($task.name)' parked (needs-input): verify hook '$hookName' blocked the done-transition"
                Set-WorkflowTaskNeedsInput -Task $task -RunDir $runDir `
                    -QuestionId "verify-hook-block-$($task.id)" `
                    -Question "Verify hook blocked completion of '$($task.name)'" `
                    -Context $blockContext | Out-Null
                $taskParked = $true
                break
            }

            if ($stillInProgress) {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' still has status in-progress. Check activity log: if a 'task_set_status(done) blocked' entry exists, verification failed; otherwise task_set_status(done) was likely never called."
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Completion check failed (attempt $attemptNumber): '$($task.name)' is not in-progress or done (unexpected state)."
            }

            # Task not completed - handle failure. Feed the classifier the real
            # harness error text (stream-json error event and/or caught exception)
            # so type-aware rules like AuthError can match instead of always
            # falling through to the generic Crash default.
            $harnessErrText = @($streamResult.ErrorText, $execErrorText | Where-Object { $_ }) -join "`n"
            $failureReason = Get-FailureReason -ExitCode $exitCode -Stdout $harnessErrText -Stderr $harnessErrText -TimedOut $false

            # Auth expiry mid-run: park to needs-input (worktree retained, no
            # merge, retry budget not consumed) and prompt the operator to
            # re-authenticate, instead of burning retries against the same wall.
            if ($failureReason.type -eq 'AuthError') {
                $authDetail = if ($harnessErrText.Length -gt 1000) { $harnessErrText.Substring(0, 1000) + " … [truncated, showing 1000 of $($harnessErrText.Length) chars]" } else { $harnessErrText }
                $authContext = "$($failureReason.description). $($failureReason.suggested_action). Detail: $authDetail"
                Write-Status "Auth expiry detected — parking for re-authentication: $($task.name)" -Type Warn
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task '$($task.name)' parked (needs-input): re-authentication required"
                Set-WorkflowTaskNeedsInput -Task $task -RunDir $runDir `
                    -QuestionId "auth-expiry-$($task.id)" `
                    -Question "Re-authentication required for task '$($task.name)'" `
                    -Context $authContext | Out-Null
                $taskParked = $true
                break
            }

            if (-not $failureReason.recoverable) {
                Write-Status "Non-recoverable failure - skipping" -Type Error
                try {
                    $detail = $failureReason.description ?? $failureReason.type ?? 'non-recoverable failure'
                    Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = 'non-recoverable'; skip_detail = $detail } | Out-Null
                } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                break
            }

            if ($attemptNumber -ge $maxRetriesPerTask) {
                Write-Status "Max retries exhausted" -Type Error
                try {
                    Invoke-TaskMarkSkipped -Arguments @{ task_id = $task.id; skip_reason = 'max-retries'; skip_detail = "Retry budget exhausted after $attemptNumber attempt(s)" } | Out-Null
                } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                break
            }
        }

        # Post-script hook: run inside the worktree (CWD is still the worktree
        # here — Pop-Location happens in the finally below) so the script can
        # operate on the task's artefacts before the squash-merge.
        #
        # At this point task_set_status(done) has already moved the task JSON to done/,
        # so a failure here is NOT a generic task failure — we must NOT destroy
        # the worktree or increment consecutive_failures. Instead we set
        # $postScriptFailed and escalate to needs-input/ below, mirroring the
        # merge-failure escalation pattern.
        if ($taskSuccess) {
            $psErr = Invoke-TaskPostScriptIfPresent -Task $task -BotRoot $executionBotRoot `
                -ProductDir $executionProductDir -Settings $settings -Model $modelTier -ProcessId $procId
            if ($psErr) {
                $taskSuccess = $false
                $postScriptFailed = $true
                $postScriptError = $psErr
            }
        }

        # Post-task clarification-questions HITL loop (parity with legacy
        # engine). Runs BEFORE outputs validation and front-matter injection
        # because the adjust-after-answers pass can rewrite product artifacts —
        # if it ran after, it could remove the JSON front matter we just
        # injected or invalidate already-validated outputs. By running first
        # we settle artifact contents before the final checks. Failure
        # escalates like a post-script failure so the worktree merge is held.
        if ($taskSuccess) {
            $clarErr = Invoke-TaskClarificationLoopIfPresent -Task $task -BotRoot $executionBotRoot `
                -ProductDir $executionProductDir -ProcessData $processData -ProcId $procId `
                -ProjectRoot $worktreePath `
                -ModelName $modelTier -ShowDebug $ShowDebug `
                -ShowVerbose $ShowVerbose -PermissionMode $permissionMode `
                -ProcessBotRoot $botRoot
            if ($clarErr) {
                $taskSuccess = $false
                $postScriptFailed = $true
                $postScriptError = $clarErr
                $postScriptFailureSource = 'clarification'
            }
        }

        # Outputs validation. On failure, escalate
        # via the same path as a post-script failure — task is in done/ already
        # but we don't want to merge a task whose declared outputs are missing.
        if ($taskSuccess) {
            $testOutputArgs = @{
                Task       = $task
                BotRoot    = $executionBotRoot
                ProductDir = $executionProductDir
            }
            if ($null -ne $taskOutputBaseline -and $taskOutputBaseline -ge 0) {
                $testOutputArgs.BaselineCount = $taskOutputBaseline
            }
            $outputErr = Test-TaskOutput @testOutputArgs
            if ($outputErr) {
                $taskSuccess = $false
                $postScriptFailed = $true
                $postScriptError = $outputErr
                $postScriptFailureSource = 'outputs'
            }
        }

        # Front-matter injection. Final step
        # before merge — by here outputs are validated and the clarification
        # adjust pass has settled artifact contents. Wrap in try/catch so an
        # IO/Add-JsonFrontMatter failure routes through the post-task escalation
        # path (worktree preserved, accurate pending_question) instead of
        # bubbling to the surrounding execution catch which would treat it as
        # an execution-phase failure and destroy the worktree.
        if ($taskSuccess) {
            try {
                Add-TaskFrontMatter -Task $task -ProductDir $executionProductDir -ProcId $procId -ModelName $modelTier
            } catch {
                $taskSuccess = $false
                $postScriptFailed = $true
                $postScriptError = $_.Exception.Message
                $postScriptFailureSource = 'front_matter'
            }
        }
        } finally {
            # Final safety-net cleanup: kill any remaining worktree processes
            if ($worktreePath) {
                Stop-WorktreeProcesses -WorktreePath $worktreePath | Out-Null
                Pop-Location
            }
        }

        # Clean up execution session
        try { Remove-HarnessSession -SessionId $executionSessionId -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process" -Exception $_ }

        } catch {
            # Execution phase setup/run failed — escalate to needs-input so the
            # task picker stops re-selecting the same task and looping. The
            # operator can inspect pending_question on the task record.
            # Some exceptions surface with an empty .Message; fall back to the
            # full error record so operators always see actionable context.
            $execErrorMessage = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($execErrorMessage)) {
                $execErrorMessage = $_.ToString()
            }
            if ([string]::IsNullOrWhiteSpace($execErrorMessage)) {
                $execErrorMessage = '<no error details available>'
            }
            Write-Diag "Execution EXCEPTION: $execErrorMessage"
            Write-Status "Execution failed: $execErrorMessage" -Type Error
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Execution failed for $($task.name): $execErrorMessage"
            try {
                $escalated = Set-WorkflowTaskNeedsInput `
                    -Task $task `
                    -RunDir $runDir `
                    -QuestionId "execution-failure-$($task.id)" `
                    -Question "Execution failed for task '$($task.name)'" `
                    -Context "Execution-phase exception: $execErrorMessage"
                if ($escalated) {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Escalated task $($task.name) to needs-input after execution failure"
                }
            } catch { Write-BotLog -Level Warn -Message "Failed to escalate task" -Exception $_ }
            $taskSuccess = $false
        }

        # Update process data
        $env:DOTBOT_CURRENT_TASK_ID = $null
        $env:CLAUDE_SESSION_ID = $null

        Write-Diag "Task result: success=$taskSuccess parked=$taskParked"

        if ($taskParked) {
            # Task is paused awaiting user input. Leave the worktree alive so
            # the next same-task session attempt can resume after the answer
            # requeues the task to todo with its handoff context attached.
            # Do NOT squash-merge, do NOT count as completed.
            $processData.heartbeat_status = "Paused (needs-input): $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task parked (needs-input): $($task.name) — worktree retained at $worktreePath"
        } elseif ($taskSuccess) {
            $mergeCompleted = $true

            # Squash-merge task branch to main
            if ($worktreePath) {
                Write-Status "Merging task branch to main..." -Type Process
                $mergeResult = Complete-TaskWorktree -TaskId $task.id -ProjectRoot $projectRoot -BotRoot $botRoot -SkipRemotePush:($null -ne $integrationBranch)
                if ($mergeResult.success) {
                    Write-Status "Merged: $($mergeResult.message)" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Squash-merged to main: $($task.name)"
                    if ($mergeResult.push_result.attempted) {
                        if ($mergeResult.push_result.success) {
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Pushed to remote: $($task.name)"
                        } else {
                            Write-Status "Push failed: $($mergeResult.push_result.error)" -Type Warn
                            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Push failed after merge: $($mergeResult.push_result.error)"
                        }
                    }
                } else {
                    $mergeCompleted = $false
                    $mrKind = if ($mergeResult.failure_kind) { $mergeResult.failure_kind } else { 'unknown' }
                    Write-Status "Merge failed ($mrKind): $($mergeResult.message)" -Type Error

                    $mergeContextParts = @("Merge failure kind: $mrKind", "Message: $($mergeResult.message)")
                    if ($mergeResult.failure_detail) { $mergeContextParts += "Detail: $($mergeResult.failure_detail)" }
                    if ($mergeResult.conflict_files) { $mergeContextParts += "Conflict files: $(@($mergeResult.conflict_files) -join ', ')" }
                    if ($worktreePath) { $mergeContextParts += "Worktree preserved at: $worktreePath" }
                    $escalated = Set-WorkflowTaskNeedsInput `
                        -Task $task `
                        -RunDir $runDir `
                        -QuestionId "merge-failure-$($task.id)" `
                        -Question "Merge failed for task '$($task.name)'" `
                        -Context ($mergeContextParts -join "`n")
                    if (-not $escalated) {
                        Write-Status "Merge-failure escalation could not locate the task file" -Type Error
                        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Merge-failure escalation could not locate $($task.name)"
                    }
                }
            }

            if ($mergeCompleted) {
                $tasksProcessed++
                Write-Diag "Tasks processed: $tasksProcessed"
                $processData.tasks_completed = $tasksProcessed
                $processData.heartbeat_status = "Completed: $($task.name)"
                Write-ProcessFile -Id $procId -Data $processData
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task completed (analyse+execute): $($task.name)"
            } else {
                $processData.heartbeat_status = "Merge failed: $($task.name)"
                Write-ProcessFile -Id $procId -Data $processData
            }
        } elseif ($postScriptFailed) {
            # A post-task hook (post_script, clarification loop, outputs validation,
            # or front-matter injection) failed after the task reached done.
            # Preserve the worktree and set needs-input in the run task file
            # with a source-specific pending_question. Skip worktree destruction
            # and consecutive_failures bump — operator-recoverable, not agent failure.
            $sourceLabel = switch ($postScriptFailureSource) {
                'clarification' { 'clarification loop' }
                'outputs'       { 'outputs validation' }
                'front_matter'  { 'front-matter injection' }
                default         { 'post_script' }
            }
            Write-Status "$sourceLabel failed for $($task.name) — escalating to needs-input" -Type Warn
            Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$sourceLabel failed for $($task.name): $postScriptError — worktree preserved at $worktreePath"

            try {
                $contextText = if ($worktreePath) {
                    "Error: $postScriptError. Worktree preserved at: $worktreePath"
                } else {
                    "Error: $postScriptError"
                }
                $moved = Set-WorkflowTaskNeedsInput `
                    -Task $task `
                    -RunDir $runDir `
                    -QuestionId "$($postScriptFailureSource)-failure-$($task.id)" `
                    -Question "$sourceLabel failed during task completion" `
                    -Context $contextText
                if ($moved) {
                    Write-Status "Task set to needs-input for manual $sourceLabel resolution" -Type Warn
                } else {
                    Write-Status "Could not locate task during $sourceLabel escalation — state may be inconsistent" -Type Error
                    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$sourceLabel escalation could not find $($task.name)"
                }
            } catch {
                Write-Status "$sourceLabel escalation failed: $($_.Exception.Message)" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "error" -Message "$sourceLabel escalation failed for $($task.name): $($_.Exception.Message)"
            }
        } elseif ($taskTerminal) {
            # Issue #318: task settled into a terminal state other than done
            # (skipped/cancelled/split). Clean up the worktree without
            # squash-merging — the work is intentionally abandoned (intentional
            # skip) or the agent already produced child tasks (split). Do NOT
            # bump consecutive_failures — these are not failures.
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task ended in terminal state '$taskTerminalState': $($task.name) — cleaning worktree, no merge"
            if ($worktreePath) {
                Write-Status "Cleaning up worktree for $taskTerminalState task..." -Type Info
                try {
                    Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                    git -C $projectRoot worktree remove $worktreePath --force 2>$null
                    git -C $projectRoot branch -D $branchName 2>$null
                } finally {
                    Invoke-WorktreeMapLocked -BotRoot $botRoot -Action {
                        $cleanupMap = Read-WorktreeMap -BotRoot $botRoot
                        $cleanupMap.Remove($task.id)
                        Write-WorktreeMap -Map $cleanupMap -BotRoot $botRoot
                    }
                    try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                }
            }
            $processData.heartbeat_status = "Terminal ($taskTerminalState): $($task.name)"
            Write-ProcessFile -Id $procId -Data $processData
        } else {
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task failed: $($task.name)"

            # Clean up worktree for failed/skipped tasks
            if ($worktreePath) {
                Write-Status "Cleaning up worktree for failed task..." -Type Info
                try {
                    Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null
                    git -C $projectRoot worktree remove $worktreePath --force 2>$null
                    git -C $projectRoot branch -D $branchName 2>$null
                } finally {
                    # Map removal always runs even if junction/worktree cleanup throws (Fix: inconsistent registry)
                    Invoke-WorktreeMapLocked -BotRoot $botRoot -Action {
                        $cleanupMap = Read-WorktreeMap -BotRoot $botRoot
                        $cleanupMap.Remove($task.id)
                        Write-WorktreeMap -Map $cleanupMap -BotRoot $botRoot
                    }
                    # Re-assert base branch after failed-task cleanup (Fix: wrong-branch merge)
                    try { Assert-OnBaseBranch -ProjectRoot $projectRoot | Out-Null } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                }
            }

            # Mandatory-task halt (#213): prompt-path failure (Claude execution)
            if (Test-TaskIsMandatory $task) {
                Write-Status "Mandatory task failed: $($task.name) - stopping workflow" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Mandatory task failed, stopping workflow: $($task.name)"
                Write-Diag "EXIT: Mandatory task failure (prompt execution)"
                try {
                    $state = Invoke-SessionGetState -Arguments @{}
                    Invoke-SessionUpdate -Arguments @{
                        consecutive_failures = $state.state.consecutive_failures + 1
                        tasks_skipped = $state.state.tasks_skipped + 1
                    } | Out-Null
                } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                break
            }

            # Update session failure counters
            try {
                $state = Invoke-SessionGetState -Arguments @{}
                $newFailures = $state.state.consecutive_failures + 1
                Invoke-SessionUpdate -Arguments @{
                    consecutive_failures = $newFailures
                    tasks_skipped = $state.state.tasks_skipped + 1
                } | Out-Null

                Write-Diag "Consecutive failures: $newFailures (threshold=$consecutiveFailureThreshold)"
                if ($newFailures -ge $consecutiveFailureThreshold) {
                    Write-Status "$consecutiveFailureThreshold consecutive failures - stopping" -Type Error
                    Write-Diag "EXIT: Consecutive failure threshold reached"
                    break
                }
            } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        }

        } catch {
            # Per-task error recovery — catches anything that escapes the inner try/catches
            Write-Diag "Per-task EXCEPTION: $($_.Exception.Message)"
            Write-Status "Task failed unexpectedly: $($_.Exception.Message)" -Type Error
            Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Task $($task.name) failed: $($_.Exception.Message)"

            # Recover task: escalate from whatever state to needs-input so the
            # task picker stops re-selecting the same task and looping.
            # Some exceptions surface with an empty .Message; fall back to the
            # full error record so operators always see actionable context.
            $perTaskErrorMessage = $_.Exception.Message
            if ([string]::IsNullOrWhiteSpace($perTaskErrorMessage)) {
                $perTaskErrorMessage = $_.ToString()
            }
            if ([string]::IsNullOrWhiteSpace($perTaskErrorMessage)) {
                $perTaskErrorMessage = '<no error details available>'
            }
            try {
                $escalated = Set-WorkflowTaskNeedsInput `
                    -Task $task `
                    -RunDir $runDir `
                    -QuestionId "per-task-failure-$($task.id)" `
                    -Question "Per-task failure for '$($task.name)'" `
                    -Context "Per-task exception: $perTaskErrorMessage"
                if ($escalated) {
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Escalated task $($task.name) to needs-input after per-task failure"
                }
            } catch { Write-BotLog -Level Warn -Message "Failed to escalate task" -Exception $_ }

            if (Test-TaskIsMandatory $task) {
                Write-Status "Mandatory task failed: $($task.name) - stopping workflow" -Type Error
                Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Mandatory task failed, stopping workflow: $($task.name)"
                Write-Diag "EXIT: Mandatory task failure (per-task exception)"
                try {
                    $state = Invoke-SessionGetState -Arguments @{}
                    Invoke-SessionUpdate -Arguments @{
                        consecutive_failures = $state.state.consecutive_failures + 1
                        tasks_skipped = $state.state.tasks_skipped + 1
                    } | Out-Null
                } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
                $processData.status = 'stopped'
                $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
                Write-ProcessFile -Id $procId -Data $processData
                break
            }
        }

        # Continue to next task?
        Write-Diag "Continue check: Continue=$Continue"
        if (-not $Continue) {
            Write-Diag "EXIT: Continue not set"
            break
        }

        # Clear task ID for next iteration
        $TaskId = $null
        $processData.task_id = $null
        $processData.task_name = $null

        # Delay between tasks
        Write-Status "Waiting 3s before next task..." -Type Info
        for ($i = 0; $i -lt 3; $i++) {
            Start-Sleep -Seconds 1
            if (Test-ProcessStopSignal -Id $procId) { break }
        }

        if (Test-ProcessStopSignal -Id $procId) {
            Write-Diag "EXIT: Stop signal after task completion"
            $processData.status = 'stopped'
            $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
            Write-ProcessFile -Id $procId -Data $processData
            break
        }
    }
} catch {
    # Process-level error handler — catches anything that escapes the per-task try/catch
    Write-Diag "PROCESS-LEVEL EXCEPTION: $($_.Exception.Message)"
    $processData.status = 'failed'
    $processData.error = $_.Exception.Message
    $processData.failed_at = (Get-Date).ToUniversalTime().ToString("o")
    Write-Information "process_failed: id=$procId error=$($_.Exception.Message)" -Tags @('dotbot', 'process', 'lifecycle')
    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process failed: $($_.Exception.Message)"
    try { Write-Status "Process failed: $($_.Exception.Message)" -Type Error } catch { Write-BotLog -Level Error -Message "Process failed: $($_.Exception.Message)" }
} finally {
    # Final cleanup
    if ($processData.status -eq 'running') {
        $processData.status = 'completed'
        $processData.completed_at = (Get-Date).ToUniversalTime().ToString("o")
    }
    if ($RunId) {
        try {
            $runStatus = switch ([string]$processData.status) {
                'completed' { 'completed' }
                'failed'    { 'failed' }
                'stopped'   { 'cancelled' }
                default     { 'running' }
            }
            Set-WorkflowRunLiveStatus -RunId $RunId -Status $runStatus -CurrentTaskId $processData.task_id -ErrorMessage $processData.error
        } catch {
            Write-BotLog -Level Warn -Message "Failed to update WorkflowRun live status for $RunId" -Exception $_
        }
    }

    if ($integrationBranch) {
        try {
            $integrationRemote = git -C $projectRoot remote get-url origin 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($integrationRemote)) {
                $pushOutput = git -C $projectRoot push -u origin $integrationBranch 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Status "Integration branch pushed: $integrationBranch" -Type Complete
                    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Integration branch $integrationBranch pushed to $($integrationRemote.Trim()). Open a PR into $resolvedBase."
                } else {
                    $pushError = ($pushOutput | Out-String).Trim()
                    Write-Status "Integration branch push failed; branch preserved locally." -Type Warn
                    Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Failed to push integration branch $integrationBranch (preserved locally): $pushError. Push manually with: git push -u origin $integrationBranch"
                }
            } else {
                Write-ProcessActivity -Id $procId -ActivityType "text" -Message "No remote configured; integration branch $integrationBranch preserved locally. Push it and open a PR into $resolvedBase when ready."
            }
        } catch {
            Write-ProcessActivity -Id $procId -ActivityType "error" -Message "Integration branch push step failed (branch $integrationBranch preserved locally): $($_.Exception.Message)"
        }

        if ($resolvedBase) {
            try {
                git -C $projectRoot checkout $resolvedBase 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-BotLog -Level Warn -Message "Failed to restore working copy to base branch '$resolvedBase' after run $RunId"
                }
            } catch {
                Write-BotLog -Level Warn -Message "Failed to restore working copy to base branch '$resolvedBase'" -Exception $_
            }
        }
    }

    Write-ProcessFile -Id $procId -Data $processData
    Write-ProcessActivity -Id $procId -ActivityType "text" -Message "Process $procId finished ($($processData.status), tasks_completed: $tasksProcessed)"
    Write-Information "process_end: id=$procId status=$($processData.status) tasks_completed=$tasksProcessed" -Tags @('dotbot', 'process', 'lifecycle')
    Write-Diag "=== Process ending: status=$($processData.status) tasksProcessed=$tasksProcessed ==="

    try { Invoke-SessionUpdate -Arguments @{ status = "stopped" } | Out-Null } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
}
