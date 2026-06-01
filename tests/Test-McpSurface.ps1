#!/usr/bin/env pwsh
<#
.SYNOPSIS
    MCP-surface HTTP-boundary tests.
.DESCRIPTION
    Spins up a tmp HttpListener as a fake runtime, points the runtime-client
    helpers at it via DOTBOT_RUNTIME_URL + DOTBOT_RUNTIME_TOKEN, sources each
    new MCP tool's script.ps1, invokes it, and asserts:
      - method + path + body + bearer token of the request the runtime saw
      - the tool's translation rules (e.g. task_set_status: status → to)
      - 401/404/409/422 → MCP error messages with the body text
    Plus a static lint pass on every new tool's metadata.json.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force -DisableNameChecking

$repoRoot = Get-RepoRoot
$mcpToolsDir = Join-Path $repoRoot 'src/mcp/tools'
$runtimeModulePsd1 = Join-Path $repoRoot 'src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1'

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  MCP Surface" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Each new tool defines a snake_case name + a PascalCase function and lives
# under src/mcp/tools/<kebab-case>/. Keep in sync with the §"Tool
# surface" table.
$NewTools = @(
    @{ folder = 'task-create';      name = 'task_create';      func = 'Invoke-TaskCreate' }
    @{ folder = 'task-create-bulk'; name = 'task_create_bulk'; func = 'Invoke-TaskCreateBulk' }
    @{ folder = 'task-get';         name = 'task_get';         func = 'Invoke-TaskGet' }
    @{ folder = 'task-list';        name = 'task_list';        func = 'Invoke-TaskList' }
    @{ folder = 'task-update';      name = 'task_update';      func = 'Invoke-TaskUpdate' }
    @{ folder = 'task-set-status';  name = 'task_set_status';  func = 'Invoke-TaskSetStatus' }
    @{ folder = 'task-get-next';    name = 'task_get_next';    func = 'Invoke-TaskGetNext' }
    @{ folder = 'task-get-context'; name = 'task_get_context'; func = 'Invoke-TaskGetContext' }
    @{ folder = 'workflow-start';   name = 'workflow_start';   func = 'Invoke-WorkflowStart' }
    @{ folder = 'workflow-get';     name = 'workflow_get';     func = 'Invoke-WorkflowGet' }
    @{ folder = 'workflow-list';    name = 'workflow_list';    func = 'Invoke-WorkflowList' }
)

# Removed tools
$RemovedTools = @(
    'task-mark-todo',
    'task-mark-in-progress', 'task-mark-done', 'task-mark-skipped',
    'task-mark-needs-input', 'task-answer-question',
    'task-approve-split', 'task-get-stats'
)

# ----------------------------------------------------------------------------
# Static lint: every new tool exists and ships valid metadata
# ----------------------------------------------------------------------------

foreach ($tool in $NewTools) {
    $dir = Join-Path $mcpToolsDir $tool.folder
    Assert-PathExists -Name "tool folder exists: $($tool.folder)" -Path $dir
    Assert-PathExists -Name "tool metadata exists: $($tool.folder)/metadata.json" -Path (Join-Path $dir 'metadata.json')
    Assert-PathExists -Name "tool script exists: $($tool.folder)/script.ps1"      -Path (Join-Path $dir 'script.ps1')

    $meta = Get-Content (Join-Path $dir 'metadata.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Equal -Name "$($tool.folder) metadata.name matches tool name" `
        -Expected $tool.name -Actual $meta.name
    Assert-True -Name "$($tool.folder) metadata.inputSchema present" `
        -Condition ($null -ne $meta.inputSchema) `
        -Message "inputSchema missing"
    Assert-True -Name "$($tool.folder) metadata.description present" `
        -Condition ([string]::IsNullOrWhiteSpace($meta.description) -eq $false) `
        -Message "description missing"
}

foreach ($removed in $RemovedTools) {
    Assert-PathNotExists -Name "removed tool gone: $removed" -Path (Join-Path $mcpToolsDir $removed)
}

# Specific check: task_set_status description must list every status.
$setStatusMeta = Get-Content (Join-Path $mcpToolsDir 'task-set-status/metadata.json') -Raw | ConvertFrom-Json -AsHashtable
$mustMention = @('in-progress','done','failed','skipped','cancelled','needs-input','todo')
foreach ($s in $mustMention) {
    Assert-True -Name "task_set_status description names '$s'" `
        -Condition ($setStatusMeta.description -like "*$s*") `
        -Message "Description does not mention status '$s'"
}

# ----------------------------------------------------------------------------
# Fake runtime (HttpListener) — captures the next request and serves a canned
# response. The MCP tools' Invoke-RuntimeRequest calls land here.
# ----------------------------------------------------------------------------

function Start-FakeRuntime {
    param([string]$Token)

    # Pick an ephemeral port — System.Net.Sockets.TcpListener with port 0 lets
    # the kernel choose. We don't have a portable Get-NextAvailablePort, so
    # bind+release.
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()

    # Shared mailbox: tests set $listenerState.next_response before invoking a
    # tool, then read $listenerState.last_request after. Using a synchronized
    # hashtable so the worker runspace and the test thread share the same
    # underlying object (PSCustomObject property writes from another runspace
    # don't propagate).
    $listenerState = [hashtable]::Synchronized(@{
        listener      = $listener
        url           = "http://127.0.0.1:$port"
        token         = $Token
        last_request  = $null
        next_response = @{ status = 200; body = @{ ok = $true } }
        worker_ps     = $null
        worker_rs     = $null
        cancel        = $false
    })

    # Background worker — a PowerShell runspace that loops on GetContext().
    # Using [powershell]::Create() with its own runspace mirrors the runtime's
    # accept loop and avoids the [Thread]::new(scriptblock) overload issues
    # PowerShell hits with delegate inference.
    $workerScript = {
        param($state)
        while (-not $state.cancel) {
            try {
                $ctx = $state.listener.GetContext()
            } catch { return }
            try {
                $req = $ctx.Request
                $bodyText = $null
                if ($req.HasEntityBody) {
                    $reader = [System.IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
                    try { $bodyText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                $bodyObj = $null
                if ($bodyText) {
                    try { $bodyObj = $bodyText | ConvertFrom-Json -ErrorAction Stop } catch { $bodyObj = $null }
                }
                $state.last_request = [pscustomobject]@{
                    method        = $req.HttpMethod
                    path          = $req.Url.AbsolutePath
                    query         = $req.Url.Query
                    authorization = $req.Headers['Authorization']
                    content_type  = $req.ContentType
                    body_text     = $bodyText
                    body          = $bodyObj
                }
                $resp = $ctx.Response
                $resp.StatusCode = [int]$state.next_response.status
                $resp.ContentType = 'application/json; charset=utf-8'
                $payload = if ($null -eq $state.next_response.body) {
                    '{}'
                } else {
                    $state.next_response.body | ConvertTo-Json -Depth 20 -Compress
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$payload)
                $resp.ContentLength64 = $bytes.Length
                $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                $resp.Close()
            } catch {
                try { $ctx.Response.Close() } catch { $null = $_ }
            }
        }
    }
    $workerRs = [runspacefactory]::CreateRunspace()
    $workerRs.Open()
    $workerPs = [powershell]::Create()
    $workerPs.Runspace = $workerRs
    $null = $workerPs.AddScript($workerScript)
    $null = $workerPs.AddArgument($listenerState)
    [void]$workerPs.BeginInvoke()
    $listenerState.worker_ps = $workerPs
    $listenerState.worker_rs = $workerRs

    return $listenerState
}

function Stop-FakeRuntime {
    param($State)
    if (-not $State) { return }
    $State.cancel = $true
    try { if ($State.listener.IsListening) { $State.listener.Stop() } } catch { $null = $_ }
    try { $State.listener.Close() } catch { $null = $_ }
    try { $State.worker_ps.Dispose() } catch { $null = $_ }
    try { $State.worker_rs.Dispose() } catch { $null = $_ }
}

# ----------------------------------------------------------------------------
# Set up the fake runtime + load the runtime module + load every tool script.
# ----------------------------------------------------------------------------

$token = 'test-token-' + ([System.Guid]::NewGuid().ToString('N').Substring(0,8))
$fake  = Start-FakeRuntime -Token $token

# Use a bogus bot root: env-var endpoint takes precedence so the file layer
# is never consulted, and no file IO happens.
$tmpBotRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-mcp-test-{0}" -f ([System.Guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Force -Path $tmpBotRoot | Out-Null

$env:DOTBOT_RUNTIME_URL   = $fake.url
$env:DOTBOT_RUNTIME_TOKEN = $token
$env:DOTBOT_MCP_SESSION   = 'test-session-42'
$global:DotbotBotRoot     = $tmpBotRoot

# Load the runtime module (gives Invoke-RuntimeRequest, Invoke-McpRuntimeRequest, Get-McpActor).
Import-Module $runtimeModulePsd1 -Force -DisableNameChecking -Global

# Source each tool script (defines Invoke-* functions).
foreach ($tool in $NewTools) {
    . (Join-Path $mcpToolsDir "$($tool.folder)/script.ps1")
}

try {
    # ------------------------------------------------------------------------
    # Get-McpActor sanity
    # ------------------------------------------------------------------------
    Assert-Equal -Name "Get-McpActor uses DOTBOT_MCP_SESSION" `
        -Expected 'mcp:test-session-42' -Actual (Get-McpActor)

    # ------------------------------------------------------------------------
    # task_create — POST /tasks with body containing args + actor
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 201; body = @{ task = @{ id = 't_abcd1234'; name = 'Hello' }; path = '/tmp/x.json' } }
    $result = Invoke-TaskCreate -Arguments @{ name = 'Hello'; description = 'world'; priority = 5 }
    $r = $fake.last_request
    Assert-Equal -Name "task_create: method POST" -Expected 'POST' -Actual $r.method
    Assert-Equal -Name "task_create: path /tasks"  -Expected '/tasks' -Actual $r.path
    Assert-Equal -Name "task_create: bearer token" -Expected "Bearer $token" -Actual $r.authorization
    Assert-Equal -Name "task_create: body.name"    -Expected 'Hello' -Actual $r.body.name
    Assert-Equal -Name "task_create: body.actor"   -Expected 'mcp:test-session-42' -Actual $r.body.actor
    Assert-Equal -Name "task_create: returns body.task.id" -Expected 't_abcd1234' -Actual $result.task.id

    # ------------------------------------------------------------------------
    # task_create_bulk — POST /tasks once per task, preserving planning shorthands
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 201; body = @{ task = @{ id = 't_bulk0001'; name = 'Bulk task' }; path = '/tmp/bulk.json' } }
    $bulkResult = Invoke-TaskCreateBulk -Arguments @{
        tasks = @(
            @{
                name = 'Bulk task'
                description = 'created by bulk tool'
                category = 'feature'
                priority = 10
                effort = 'M'
                group_id = 'group-api'
                applicable_decisions = @('dec-abc12345')
                human_hours = 8
                ai_hours = 1
                steps = @('Create implementation', 'Add tests')
            }
        )
    }
    $r = $fake.last_request
    Assert-Equal -Name "task_create_bulk: method POST" -Expected 'POST' -Actual $r.method
    Assert-Equal -Name "task_create_bulk: path /tasks"  -Expected '/tasks' -Actual $r.path
    Assert-Equal -Name "task_create_bulk: body.actor"   -Expected 'mcp:test-session-42' -Actual $r.body.actor
    Assert-Equal -Name "task_create_bulk: workflow group_id preserved" `
        -Expected 'group-api' -Actual $r.body.extensions.workflow.group_id
    Assert-Equal -Name "task_create_bulk: workflow applicable_decisions preserved" `
        -Expected 'dec-abc12345' -Actual $r.body.extensions.workflow.applicable_decisions[0]
    Assert-Equal -Name "task_create_bulk: count returned" -Expected 1 -Actual $bulkResult.count

    # ------------------------------------------------------------------------
    # task_get — GET /tasks/<id>, no body, no actor (read tool)
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ task = @{ id = 't_abcd1234' } } }
    $null = Invoke-TaskGet -Arguments @{ task_id = 't_abcd1234' }
    $r = $fake.last_request
    Assert-Equal -Name "task_get: method GET"             -Expected 'GET' -Actual $r.method
    Assert-Equal -Name "task_get: path /tasks/<id>"       -Expected '/tasks/t_abcd1234' -Actual $r.path
    Assert-True  -Name "task_get: no request body"         -Condition ([string]::IsNullOrEmpty($r.body_text)) `
        -Message "Body was: $($r.body_text)"

    # ------------------------------------------------------------------------
    # task_list — GET /tasks with filters as query params
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ tasks = @(); count = 0 } }
    $null = Invoke-TaskList -Arguments @{ status = 'todo'; workflow = 'start-from-prompt' }
    $r = $fake.last_request
    Assert-Equal -Name "task_list: method GET"  -Expected 'GET' -Actual $r.method
    Assert-Equal -Name "task_list: path /tasks" -Expected '/tasks' -Actual $r.path
    Assert-True  -Name "task_list: query has status=todo" `
        -Condition ($r.query -match 'status=todo') `
        -Message "Query was: $($r.query)"
    Assert-True  -Name "task_list: query has workflow=start-from-prompt" `
        -Condition ($r.query -match 'workflow=start-from-prompt') `
        -Message "Query was: $($r.query)"

    # ------------------------------------------------------------------------
    # task_update — PATCH /tasks/<id> with non-status fields + actor
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ task = @{ id = 't_abcd1234' } } }
    $null = Invoke-TaskUpdate -Arguments @{ task_id = 't_abcd1234'; description = 'updated'; priority = 1 }
    $r = $fake.last_request
    Assert-Equal -Name "task_update: method PATCH"          -Expected 'PATCH' -Actual $r.method
    Assert-Equal -Name "task_update: path /tasks/<id>"      -Expected '/tasks/t_abcd1234' -Actual $r.path
    Assert-Equal -Name "task_update: body.actor populated"  -Expected 'mcp:test-session-42' -Actual $r.body.actor
    Assert-Equal -Name "task_update: body.description"      -Expected 'updated' -Actual $r.body.description
    Assert-True  -Name "task_update: no task_id in body"     -Condition (-not ($r.body.PSObject.Properties.Name -contains 'task_id')) `
        -Message "task_id should be in the path, not the body"

    $fake.next_response = @{ status = 200; body = @{ task = @{ id = 't_abcd1234' } } }
    $null = Invoke-TaskUpdate -Arguments @{
        task_id = 't_abcd1234'
        extensions = @{
            runner = @{
                pending_questions = @(
                    @{ id = 'q1'; question = 'Pick one'; answer_type = 'option' }
                )
            }
        }
    }
    $r = $fake.last_request
    Assert-Equal -Name "task_update: extensions sent as object" `
        -Expected 'q1' `
        -Actual $r.body.extensions.runner.pending_questions[0].id

    # ------------------------------------------------------------------------
    # task_set_status — POST /tasks/<id>/status with `to` (translated from `status`)
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ task = @{ id = 't_abcd1234'; status = 'in-progress' } } }
    $null = Invoke-TaskSetStatus -Arguments @{ task_id = 't_abcd1234'; status = 'in-progress'; reason = 'ready' }
    $r = $fake.last_request
    Assert-Equal -Name "task_set_status: method POST" -Expected 'POST' -Actual $r.method
    Assert-Equal -Name "task_set_status: path /tasks/<id>/status" `
        -Expected '/tasks/t_abcd1234/status' -Actual $r.path
    Assert-Equal -Name "task_set_status: body.to (translated)" `
        -Expected 'in-progress' -Actual $r.body.to
    Assert-Equal -Name "task_set_status: body.reason" `
        -Expected 'ready' -Actual $r.body.reason
    Assert-Equal -Name "task_set_status: body.actor" `
        -Expected 'mcp:test-session-42' -Actual $r.body.actor

    # ------------------------------------------------------------------------
    # task_get_next — GET /tasks/next with optional status query
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ task = $null } }
    $null = Invoke-TaskGetNext -Arguments @{ status = 'in-progress' }
    $r = $fake.last_request
    Assert-Equal -Name "task_get_next: method GET" -Expected 'GET' -Actual $r.method
    Assert-Equal -Name "task_get_next: path /tasks/next" -Expected '/tasks/next' -Actual $r.path
    Assert-True  -Name "task_get_next: query carries status=in-progress" `
        -Condition ($r.query -match 'status=in-progress') `
        -Message "Query was: $($r.query)"

    # ------------------------------------------------------------------------
    # task_get_context — GET /tasks/<id>/context
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ task = @{ id = 't_abcd1234' } } }
    $null = Invoke-TaskGetContext -Arguments @{ task_id = 't_abcd1234' }
    $r = $fake.last_request
    Assert-Equal -Name "task_get_context: method GET" -Expected 'GET' -Actual $r.method
    Assert-Equal -Name "task_get_context: path /tasks/<id>/context" `
        -Expected '/tasks/t_abcd1234/context' -Actual $r.path

    # ------------------------------------------------------------------------
    # workflow_start — POST /workflows/runs
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 201; body = @{ run = @{ run_id = 'wr_aaaaaaaa' }; status = @{ status = 'running' } } }
    $null = Invoke-WorkflowStart -Arguments @{ workflow_name = 'start-from-prompt'; isolated = $true; branch_name = 'ignored' }
    $r = $fake.last_request
    Assert-Equal -Name "workflow_start: method POST"    -Expected 'POST' -Actual $r.method
    Assert-Equal -Name "workflow_start: path /workflows/runs" -Expected '/workflows/runs' -Actual $r.path
    Assert-Equal -Name "workflow_start: body.workflow_name" `
        -Expected 'start-from-prompt' -Actual $r.body.workflow_name
    Assert-True -Name "workflow_start: body omits removed isolated flag" `
        -Condition (-not ($r.body.PSObject.Properties.Name -contains 'isolated'))
    Assert-True -Name "workflow_start: body omits removed branch override" `
        -Condition (-not ($r.body.PSObject.Properties.Name -contains 'branch_name'))
    Assert-Equal -Name "workflow_start: body.actor"     -Expected 'mcp:test-session-42' -Actual $r.body.actor

    # ------------------------------------------------------------------------
    # workflow_get — GET /workflows/runs/<id>
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ run = @{ run_id = 'wr_aaaaaaaa' } } }
    $null = Invoke-WorkflowGet -Arguments @{ run_id = 'wr_aaaaaaaa' }
    $r = $fake.last_request
    Assert-Equal -Name "workflow_get: method GET" -Expected 'GET' -Actual $r.method
    Assert-Equal -Name "workflow_get: path /workflows/runs/<id>" `
        -Expected '/workflows/runs/wr_aaaaaaaa' -Actual $r.path

    # ------------------------------------------------------------------------
    # workflow_list — GET /workflows/runs
    # ------------------------------------------------------------------------
    $fake.next_response = @{ status = 200; body = @{ runs = @(); count = 0 } }
    $null = Invoke-WorkflowList -Arguments @{}
    $r = $fake.last_request
    Assert-Equal -Name "workflow_list: method GET" -Expected 'GET' -Actual $r.method
    Assert-Equal -Name "workflow_list: path /workflows/runs" -Expected '/workflows/runs' -Actual $r.path

    # ------------------------------------------------------------------------
    # Error mapping — 404 / 409 / 422 / 401 → MCP exception with body message
    # ------------------------------------------------------------------------
    $cases = @(
        @{ status = 404; body = @{ error = 'not_found';          message = 'Task t_bad not found.' }; tag = 'not found' }
        @{ status = 409; body = @{ error = 'same_workflow_conflict'; message = 'Another run of this workflow is active.' }; tag = 'conflict' }
        @{ status = 422; body = @{ error = 'illegal_transition'; message = 'todo → done not allowed.' }; tag = 'invalid transition' }
        @{ status = 422; body = @{ error = 'schema_error';       message = 'Field name is required.' }; tag = 'validation error' }
    )
    foreach ($case in $cases) {
        $fake.next_response = @{ status = $case.status; body = $case.body }
        $threwMessage = $null
        try {
            Invoke-TaskGet -Arguments @{ task_id = 't_bad00001' } | Out-Null
        } catch {
            $threwMessage = $_.Exception.Message
        }
        Assert-True -Name "error mapping ($($case.status) $($case.tag)): tool throws" `
            -Condition ($null -ne $threwMessage) `
            -Message "Expected throw for status=$($case.status)"
        Assert-True -Name "error mapping ($($case.status) $($case.tag)): tag in message" `
            -Condition ($threwMessage -like "*$($case.tag)*") `
            -Message "Got message: $threwMessage"
        Assert-True -Name "error mapping ($($case.status) $($case.tag)): server message surfaced" `
            -Condition ($threwMessage -like "*$($case.body.message)*") `
            -Message "Got message: $threwMessage"
    }

    # 401 specifically — note that Invoke-RuntimeRequest re-discovers on 401
    # before giving up. With the env-var endpoint stable, the retry still gets
    # 401 (we haven't changed the canned response) so the final mapping fires.
    $fake.next_response = @{ status = 401; body = @{ error = 'unauthorized'; message = 'Bearer token invalid.' } }
    $threwMessage = $null
    try {
        Invoke-TaskGet -Arguments @{ task_id = 't_xxxxxxxx' } | Out-Null
    } catch { $threwMessage = $_.Exception.Message }
    Assert-True -Name "error mapping (401 authentication error)" `
        -Condition ($threwMessage -like "*authentication error*") `
        -Message "Got: $threwMessage"

} finally {
    Stop-FakeRuntime -State $fake
    Remove-Item -LiteralPath $tmpBotRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:DOTBOT_RUNTIME_URL -ErrorAction SilentlyContinue
    Remove-Item Env:DOTBOT_RUNTIME_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:DOTBOT_MCP_SESSION -ErrorAction SilentlyContinue
}

$allPassed = Write-TestSummary -LayerName "MCP Surface"
if (-not $allPassed) { exit 1 }
