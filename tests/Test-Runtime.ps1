#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1/2: runtime HTTP server tests.
.DESCRIPTION
    Covers the public surface of Dotbot.Runtime:

      - HTTP API: every endpoint with valid auth = 2xx with expected body shape;
        missing/wrong auth = 401; illegal transition = 422; same-workflow
        concurrent run = 409.
      - Mutex: spawn N concurrent PATCH calls against the same task; final state
        contains all updates (no lost writes); audit log shows them in some order.
      - Endpoint discovery: env > settings > .control/runtime.json fallback,
        and the "nothing available" throw case.
      - Lifecycle: stale-PID runtime.json is rewritten on Start; shutdown cleans up.

    Test pattern is established here: spin the runtime up via Start-DotbotRuntime
    on an ephemeral port (no port collision in parallel CI), point
    Invoke-RuntimeRequest at it via env-var override, assert on response codes
    and parsed bodies. Prior art: Test-ServerStartup.ps1's listener pattern.

    No installed dotbot needed (module is imported directly from src/).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Runtime HTTP Server" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1") -Force -DisableNameChecking -Global
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1") -Force -DisableNameChecking -Global
Import-Module (Join-Path $repoRoot "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1") -Force -DisableNameChecking -Global
Import-Module (Join-Path $repoRoot "src/ui/modules/FleetAPI.psm1") -Force -DisableNameChecking -Global

# Small helper: assert a scriptblock throws and (optionally) message matches a pattern.
function Assert-Throws {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$Pattern
    )
    $threw = $false
    $msg = ''
    try { & $Action } catch { $threw = $true; $msg = $_.Exception.Message }
    if (-not $threw) {
        Write-TestResult -Name $Name -Status Fail -Message "Expected an exception, got none."
        return
    }
    if ($Pattern -and ($msg -notmatch $Pattern)) {
        Write-TestResult -Name $Name -Status Fail -Message "Exception '$msg' did not match pattern '$Pattern'."
        return
    }
    Write-TestResult -Name $Name -Status Pass
}

# ───────────────────────────────────────────────────────────────────────────
# Test bed: a temporary project that looks like a .bot/ root
# ───────────────────────────────────────────────────────────────────────────

function New-TestBotRoot {
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-prd04-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    $bot  = Join-Path $base '.bot'
    New-Item -ItemType Directory -Path $bot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bot '.control') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bot 'workspace') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $bot 'workspace') 'tasks') | Out-Null

    # Make the project root a valid git repo with one commit so workflow
    # runs satisfy Test-GitReadyForWorktree.
    Push-Location $base
    try {
        & git init -q | Out-Null
        & git config user.email "test@example.com" | Out-Null
        & git config user.name  "test" | Out-Null
        New-Item -Path (Join-Path $base 'README.md') -ItemType File -Value 'test' -Force | Out-Null
        & git add . | Out-Null
        & git -c commit.gpgsign=false commit -q -m "init" | Out-Null
    } finally {
        Pop-Location
    }
    return $bot
}

function Remove-TestBotRoot {
    param([Parameter(Mandatory)][string]$BotRoot)
    $project = Split-Path -Parent $BotRoot
    try { Remove-Item -Recurse -Force $project } catch { $null = $_ }
}

function Invoke-RuntimeRaw {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [string]$Token,
        $Body,
        [hashtable]$Headers
    )
    $h = @{}
    if ($Token) { $h['Authorization'] = "Bearer $Token" }
    if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
    $params = @{
        Uri = ($Url.TrimEnd('/') + $Path)
        Method = $Method
        Headers = $h
        SkipHttpErrorCheck = $true
        TimeoutSec = 10
    }
    if ($Body -ne $null -and $Method -ne 'GET') {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 20)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    $resp = Invoke-WebRequest @params
    $parsed = $null
    try { $parsed = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    return [ordered]@{
        status_code = [int]$resp.StatusCode
        body        = $parsed
        raw         = [string]$resp.Content
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# Mothership CLI binding
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Mothership CLI binding" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$serveCommand = Get-Command (Join-Path $repoRoot "src/cli/serve.ps1")
$mothershipAliases = @($serveCommand.Parameters['Mothership'].Aliases)
$mothershipKeyAliases = @($serveCommand.Parameters['MothershipApiKey'].Aliases)
Assert-Equal -Name "serve --mothership has no aliases" -Expected 0 -Actual $mothershipAliases.Count
Assert-Equal -Name "serve key has one alias" -Expected 1 -Actual $mothershipKeyAliases.Count
Assert-Equal -Name "serve key alias is --mothership-key" -Expected 'mothership-key' -Actual $mothershipKeyAliases[0]

$bot = New-TestBotRoot
try {
    $oldMothershipUrl = $env:DOTBOT_MOTHERSHIP_URL
    $oldMothershipKey = $env:DOTBOT_MOTHERSHIP_API_KEY

    Remove-Item Env:\DOTBOT_MOTHERSHIP_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTBOT_MOTHERSHIP_API_KEY -ErrorAction SilentlyContinue

    $env:DOTBOT_MOTHERSHIP_URL = 'http://mothership.example'
    $env:DOTBOT_MOTHERSHIP_API_KEY = 'ship-key'
    $settings = Get-ControlPlaneSettings -BotRoot $bot
    Assert-True -Name "DOTBOT_MOTHERSHIP_URL enables registration" -Condition ($settings.enabled -eq $true)
    Assert-Equal -Name "DOTBOT_MOTHERSHIP_URL is used" -Expected 'http://mothership.example' -Actual $settings.url
    Assert-Equal -Name "DOTBOT_MOTHERSHIP_API_KEY is used" -Expected 'ship-key' -Actual $settings.api_key
} finally {
    if ($null -ne $oldMothershipUrl) { $env:DOTBOT_MOTHERSHIP_URL = $oldMothershipUrl } else { Remove-Item Env:\DOTBOT_MOTHERSHIP_URL -ErrorAction SilentlyContinue }
    if ($null -ne $oldMothershipKey) { $env:DOTBOT_MOTHERSHIP_API_KEY = $oldMothershipKey } else { Remove-Item Env:\DOTBOT_MOTHERSHIP_API_KEY -ErrorAction SilentlyContinue }
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Endpoint discovery
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Endpoint discovery (env > settings > runtime.json)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
try {
    # 1. Nothing available → throws
    $envBackupUrl   = $env:DOTBOT_RUNTIME_URL
    $envBackupToken = $env:DOTBOT_RUNTIME_TOKEN
    Remove-Item Env:\DOTBOT_RUNTIME_URL   -ErrorAction SilentlyContinue
    Remove-Item Env:\DOTBOT_RUNTIME_TOKEN -ErrorAction SilentlyContinue

    Assert-Throws -Name "Resolve-RuntimeEndpoint throws when no layer is set" `
        -Action { Resolve-RuntimeEndpoint -BotRoot $bot } `
        -Pattern 'runtime endpoint not available'

    # 1b. NoThrow variant returns $null
    $r = Resolve-RuntimeEndpoint -BotRoot $bot -NoThrow
    Assert-True -Name "Resolve-RuntimeEndpoint -NoThrow returns null when missing" -Condition ($null -eq $r)

    # 2. Connection file present → source=file
    Write-RuntimeConnectionFile -BotRoot $bot -Url 'http://127.0.0.1:9999/' -Token 'tok-from-file' -ProcessId $PID -StartedAt '2026-05-20T00:00:00Z' | Out-Null
    $r = Resolve-RuntimeEndpoint -BotRoot $bot
    Assert-Equal -Name "file layer: source = 'file'"   -Expected 'file'              -Actual $r.source
    Assert-Equal -Name "file layer: url is loaded"      -Expected 'http://127.0.0.1:9999/' -Actual $r.url
    Assert-Equal -Name "file layer: token is loaded"    -Expected 'tok-from-file'    -Actual $r.token

    # 3. Env vars override the file
    $env:DOTBOT_RUNTIME_URL   = 'http://127.0.0.1:1111/'
    $env:DOTBOT_RUNTIME_TOKEN = 'tok-from-env'
    $r = Resolve-RuntimeEndpoint -BotRoot $bot
    Assert-Equal -Name "env layer wins over file"      -Expected 'env'              -Actual $r.source
    Assert-Equal -Name "env layer: url is loaded"      -Expected 'http://127.0.0.1:1111/' -Actual $r.url
    Assert-Equal -Name "env layer: token is loaded"    -Expected 'tok-from-env'     -Actual $r.token

    # 3b. Partial env (URL only) falls through
    Remove-Item Env:\DOTBOT_RUNTIME_TOKEN -ErrorAction SilentlyContinue
    $r = Resolve-RuntimeEndpoint -BotRoot $bot
    Assert-True -Name "partial env (URL only) falls through to file" -Condition ($r.source -eq 'file')

    Remove-Item Env:\DOTBOT_RUNTIME_URL -ErrorAction SilentlyContinue

    # 4. Restricted permissions on POSIX. BSD stat (macOS default) uses -f;
    # GNU stat (Linux) uses -c. Pick the right one so this runs on both.
    if ($IsLinux -or $IsMacOS) {
        $connFile = Get-RuntimeConnectionFilePath -BotRoot $bot
        $statMode = if ($IsMacOS) {
            (& stat -f '%Lp' $connFile 2>$null)
        } else {
            (& stat -c '%a' $connFile 2>$null)
        }
        Assert-Equal -Name "runtime.json is mode 600 on POSIX" -Expected '600' -Actual ("$statMode").Trim()
    } else {
        Write-TestResult -Name "runtime.json restricted-perms check (POSIX-only)" -Status Skip -Message "Not POSIX"
    }
} finally {
    # Restore env
    if ($envBackupUrl)   { $env:DOTBOT_RUNTIME_URL   = $envBackupUrl }   else { Remove-Item Env:\DOTBOT_RUNTIME_URL   -ErrorAction SilentlyContinue }
    if ($envBackupToken) { $env:DOTBOT_RUNTIME_TOKEN = $envBackupToken } else { Remove-Item Env:\DOTBOT_RUNTIME_TOKEN -ErrorAction SilentlyContinue }
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Lifecycle
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Lifecycle (token, port scan, stale-PID detection)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

# Tokens
$tok = New-RuntimeBearerToken
Assert-True -Name "New-RuntimeBearerToken is 64 hex chars" -Condition ($tok -cmatch '^[0-9a-f]{64}$')
$tok2 = New-RuntimeBearerToken
Assert-True -Name "New-RuntimeBearerToken returns a fresh token each call" -Condition ($tok -ne $tok2)

# Port scanning — should succeed on any healthy system
$port = Find-AvailableRuntimePort -StartPort 19000 -EndPort 19050
Assert-True -Name "Find-AvailableRuntimePort returns a port in the range" -Condition ($port -ge 19000 -and $port -le 19050)

# Stale-PID detection
$bot = New-TestBotRoot
try {
    # Write a runtime.json with a known-dead PID (PID 2 is init/kthreadd; PID 999999 is virtually never alive).
    Write-RuntimeConnectionFile -BotRoot $bot -Url 'http://127.0.0.1:1/' -Token 'dead' -ProcessId 999999 -StartedAt '2026-05-20T00:00:00Z' | Out-Null
    Assert-True -Name "Test-RuntimeAlive returns false for a stale PID" -Condition (-not (Test-RuntimeAlive -BotRoot $bot))

    # Start the runtime — it should detect stale and rewrite with a fresh token.
    $oldToken = (Read-RuntimeConnectionFile -BotRoot $bot).token
    $startResult = Start-DotbotRuntime -BotRoot $bot
    try {
        Assert-True -Name "Start-DotbotRuntime rewrote runtime.json with a fresh token" -Condition ($startResult.token -ne $oldToken)
        Assert-True -Name "Start-DotbotRuntime returned attached=false on cold start"   -Condition (-not $startResult.attached)
        Assert-True -Name "Test-RuntimeAlive returns true after Start"                  -Condition (Test-RuntimeAlive -BotRoot $bot)

        # Second Start should attach (idempotent).
        $second = Start-DotbotRuntime -BotRoot $bot
        Assert-True -Name "Second Start-DotbotRuntime returns attached=true" -Condition ($second.attached)
        Assert-Equal -Name "Second Start-DotbotRuntime reuses the URL" -Expected $startResult.url -Actual $second.url
        Assert-Equal -Name "Second Start-DotbotRuntime reuses the token" -Expected $startResult.token -Actual $second.token
    } finally {
        Stop-DotbotRuntime -BotRoot $bot -Listener $startResult.listener -ErrorAction SilentlyContinue
    }

    Assert-True -Name "Stop-DotbotRuntime removes runtime.json" -Condition (-not (Test-Path (Get-RuntimeConnectionFilePath -BotRoot $bot)))
} finally {
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# HTTP surface: auth + routing
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  HTTP surface: auth, routing, schema enforcement" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
$start = $null
try {
    $start = Start-DotbotRuntime -BotRoot $bot

    # Wait for the listener to be ready (very fast — usually <100ms).
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    $ready = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/health' -Token $start.token
            if ($r.status_code -eq 200) { $ready = $true; break }
        } catch { Start-Sleep -Milliseconds 100 }
    }
    Assert-True -Name "Runtime /health responds 200 with valid auth" -Condition $ready

    # 401: missing token
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/health'
    Assert-Equal -Name "Missing bearer → 401" -Expected 401 -Actual $r.status_code
    Assert-Equal -Name "Missing bearer body has error='unauthorized'" -Expected 'unauthorized' -Actual $r.body.error

    # 401: wrong token
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/health' -Token 'wrong'
    Assert-Equal -Name "Wrong bearer → 401" -Expected 401 -Actual $r.status_code

    # 404: unknown route
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/nope' -Token $start.token
    Assert-Equal -Name "Unknown route → 404" -Expected 404 -Actual $r.status_code

    # POST /tasks (standalone)
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/tasks' -Token $start.token -Body @{
        name = 'First test task'; description = 'hello'; actor = 'test:ci'
    }
    Assert-Equal -Name "POST /tasks → 201" -Expected 201 -Actual $r.status_code
    Assert-True  -Name "POST /tasks body carries task with t_ ID" -Condition ($r.body.task.id -cmatch '^t_[A-Za-z0-9]{8}$')
    $newTaskId = $r.body.task.id

    # POST /tasks with bad body
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/tasks' -Token $start.token -Body @{ description = 'no name' }
    Assert-Equal -Name "POST /tasks without name → 400" -Expected 400 -Actual $r.status_code

    # GET /tasks/<id>
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path "/tasks/$newTaskId" -Token $start.token
    Assert-Equal -Name "GET /tasks/<id> → 200"             -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "GET /tasks/<id> returns matching id" -Expected $newTaskId -Actual $r.body.task.id

    # GET /tasks/<bogus>
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/tasks/t_99999999' -Token $start.token
    Assert-Equal -Name "GET /tasks/<missing> → 404" -Expected 404 -Actual $r.status_code

    # PATCH /tasks/<id> — update description
    $r = Invoke-RuntimeRaw -Url $start.url -Method PATCH -Path "/tasks/$newTaskId" -Token $start.token -Body @{
        description = 'updated via PATCH'; actor = 'test:ci'
    }
    Assert-Equal -Name "PATCH /tasks/<id> → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "PATCH /tasks/<id> persists new description" -Expected 'updated via PATCH' -Actual $r.body.task.description

    # PATCH /tasks/<id> — malformed human-input questions are rejected before the UI renders them.
    $r = Invoke-RuntimeRaw -Url $start.url -Method PATCH -Path "/tasks/$newTaskId" -Token $start.token -Body @{
        actor = 'test:ci'
        extensions = @{
            runner = @{
                pending_questions = @(
                    @{
                        id = 'q1'
                        question = 'Hook keeps failing. Options: (A) push it; (B) authorize push; (C) treat as bug'
                    }
                )
            }
        }
    }
    Assert-Equal -Name "PATCH rejects pending_questions without structured options → 400" -Expected 400 -Actual $r.status_code
    Assert-Equal -Name "PATCH malformed questions → error=schema_error" -Expected 'schema_error' -Actual $r.body.error
    Assert-True  -Name "PATCH malformed questions message mentions structured options" `
        -Condition ($r.body.message -match 'options') `
        -Message "Expected options validation error, got: $($r.body.message)"

    $r = Invoke-RuntimeRaw -Url $start.url -Method PATCH -Path "/tasks/$newTaskId" -Token $start.token -Body @{
        actor = 'test:ci'
        extensions = @{
            runner = @{
                pending_questions = @(
                    @{
                        id = 'q1'
                        question = 'How should the hook failure be handled?'
                        context = 'The completion hook failed after implementation.'
                        options = @(
                            @{ key = 'A'; label = 'Push from this machine'; rationale = 'Fastest if credentials are available' }
                            @{ key = 'B'; label = 'Authorize the agent to push'; rationale = 'Lets automation complete the workflow' }
                            @{ key = 'C'; label = 'Treat as framework bug'; rationale = 'Preserve the worktree for diagnosis' }
                        )
                        recommendation = 'A'
                    }
                )
            }
        }
    }
    Assert-Equal -Name "PATCH accepts structured pending_questions → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "PATCH structured pending_questions keeps option A label" `
        -Expected 'Push from this machine' `
        -Actual $r.body.task.extensions.runner.pending_questions[0].options[0].label

    # PATCH rejects forbidden fields
    $r = Invoke-RuntimeRaw -Url $start.url -Method PATCH -Path "/tasks/$newTaskId" -Token $start.token -Body @{
        status = 'done'; actor = 'test:ci'
    }
    Assert-Equal -Name "PATCH refuses status field → 400" -Expected 400 -Actual $r.status_code
    Assert-Equal -Name "PATCH refuses status → error=patch_forbidden_field" -Expected 'patch_forbidden_field' -Actual $r.body.error

    # POST /tasks/<id>/status — legal transition
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path "/tasks/$newTaskId/status" -Token $start.token -Body @{
        to = 'in-progress'; actor = 'test:ci'
    }
    Assert-Equal -Name "POST status: todo → in-progress → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "POST status: response carries new status" -Expected 'in-progress' -Actual $r.body.task.status

    # POST /tasks/<id>/status — illegal transition (in-progress → todo is not in the table)
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path "/tasks/$newTaskId/status" -Token $start.token -Body @{
        to = 'todo'; actor = 'test:ci'
    }
    Assert-Equal -Name "POST status: illegal transition → 422"     -Expected 422 -Actual $r.status_code
    Assert-Equal -Name "POST status: illegal transition error code" -Expected 'illegal_transition' -Actual $r.body.error

    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/tasks' -Token $start.token -Body @{
        name = 'Skipped test task'; description = 'skip metadata'; actor = 'test:ci'
    }
    Assert-Equal -Name "POST /tasks for skip metadata → 201" -Expected 201 -Actual $r.status_code
    $skipTaskId = $r.body.task.id

    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path "/tasks/$skipTaskId/status" -Token $start.token -Body @{
        to = 'skipped'; actor = 'test:ci'; skip_reason = 'condition-not-met'; skip_detail = 'missing file'
    }
    Assert-Equal -Name "POST status skipped persists → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "POST skipped status persists runner skip_reason" `
        -Expected 'condition-not-met' `
        -Actual $r.body.task.extensions.runner.skip_reason

    # GET /tasks
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/tasks' -Token $start.token
    Assert-Equal -Name "GET /tasks → 200" -Expected 200 -Actual $r.status_code
    Assert-True  -Name "GET /tasks lists at least the created task" -Condition ($r.body.count -ge 1)

    # GET /tasks/next
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/tasks/next?status=in-progress' -Token $start.token
    Assert-Equal -Name "GET /tasks/next?status=in-progress → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "GET /tasks/next returns the in-progress task" -Expected $newTaskId -Actual $r.body.task.id

    # GET /tasks/<id>/context
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path "/tasks/$newTaskId/context" -Token $start.token
    Assert-Equal -Name "GET /tasks/<id>/context → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "GET /tasks/<id>/context: task standard" -Expected 'single-task-session-attempts' -Actual $r.body.task_standard
    Assert-Equal -Name "GET /tasks/<id>/context: session policy" -Expected 'single_unblocked_attempt' -Actual $r.body.session_policy
    Assert-True  -Name "GET /tasks/<id>/context: resume context present in envelope" -Condition ($null -ne $r.body.PSObject.Properties['resume_context'])

    # POST /tasks/<id>/status — active task can be intentionally skipped after discovery.
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/tasks' -Token $start.token -Body @{
        name = 'skip after discovery'; actor = 'test:ci'
    }
    Assert-Equal -Name "POST /tasks for active skip fixture → 201" -Expected 201 -Actual $r.status_code
    $skipTaskId = $r.body.task.id

    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path "/tasks/$skipTaskId/status" -Token $start.token -Body @{
        to = 'in-progress'; actor = 'test:ci'
    }
    Assert-Equal -Name "POST status: skip fixture todo → in-progress → 200" -Expected 200 -Actual $r.status_code

    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path "/tasks/$skipTaskId/status" -Token $start.token -Body @{
        to = 'skipped'; actor = 'test:ci'; reason = 'not needed after discovery'
    }
    Assert-Equal -Name "POST status: in-progress → skipped → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "POST status: active skip response carries skipped" -Expected 'skipped' -Actual $r.body.task.status
    Assert-True  -Name "POST status: active skip sets completed_at" -Condition ($null -ne $r.body.task.completed_at)

    # ───── Workflow runs ─────
    # POST /workflows/runs — no active conflict
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/workflows/runs' -Token $start.token -Body @{
        workflow_name = 'demo-workflow'
        actor         = 'test:ci'
        task_ids      = @()
    }
    Assert-Equal -Name "POST /workflows/runs → 201" -Expected 201 -Actual $r.status_code
    Assert-True  -Name "POST /workflows/runs returns wr_ ID" -Condition ($r.body.run.run_id -cmatch '^wr_[A-Za-z0-9]{8}$')
    $firstRunId = $r.body.run.run_id

    # GET /workflows/runs/<id>
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path "/workflows/runs/$firstRunId" -Token $start.token
    Assert-Equal -Name "GET /workflows/runs/<id> → 200" -Expected 200 -Actual $r.status_code
    Assert-Equal -Name "GET /workflows/runs/<id> status is running" -Expected 'running' -Actual $r.body.status.status

    # POST /workflows/runs — a second isolated instance of the SAME workflow is
    # allowed while the first is still running. Isolated runs are self-contained
    # (own run dir + per-branch product/worktree), so concurrent instances of
    # one workflow can run side by side.
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/workflows/runs' -Token $start.token -Body @{
        workflow_name = 'demo-workflow'; actor = 'test:ci'; task_ids = @()
    }
    Assert-Equal -Name "Second isolated instance of same workflow → 201" -Expected 201 -Actual $r.status_code
    Assert-True  -Name "Second same-workflow run gets its own run_id" `
        -Condition ($r.body.run.run_id -cmatch '^wr_[A-Za-z0-9]{8}$' -and $r.body.run.run_id -ne $firstRunId)

    # POST /workflows/runs — another workflow can run alongside
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/workflows/runs' -Token $start.token -Body @{
        workflow_name = 'demo-workflow-2'; actor = 'test:ci'; task_ids = @()
    }
    Assert-Equal -Name "Different workflow run alongside first → 201" -Expected 201 -Actual $r.status_code

    # GET /workflows/runs
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/workflows/runs' -Token $start.token
    Assert-Equal -Name "GET /workflows/runs → 200" -Expected 200 -Actual $r.status_code
    Assert-True  -Name "GET /workflows/runs lists at least 2 runs" -Condition ($r.body.count -ge 2)

    # Dashboard/fleet surface
    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/dashboard/info' -Token $start.token
    Assert-Equal -Name "GET /dashboard/info → 200" -Expected 200 -Actual $r.status_code
    Assert-True  -Name "GET /dashboard/info includes project root" -Condition ([bool]$r.body.project_root)

    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/dashboard/processes' -Token $start.token
    Assert-Equal -Name "GET /dashboard/processes → 200" -Expected 200 -Actual $r.status_code
    Assert-True  -Name "GET /dashboard/processes has processes array" -Condition ($null -ne $r.body.processes)

    $r = Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/dashboard/workflows/installed' -Token $start.token
    Assert-Equal -Name "GET /dashboard/workflows/installed → 200" -Expected 200 -Actual $r.status_code
    Assert-True  -Name "GET /dashboard/workflows/installed has workflows array" -Condition ($null -ne $r.body.workflows)

    Initialize-FleetAPI -ControlDir (Join-Path $bot '.control') -BotRoot $bot
    $fleetSettingsPath = Join-Path $bot '.control/settings.json'
    $fleetSettingsJson = @{ control_plane = @{ api_key = 'fleet-secret' } } | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($fleetSettingsPath, $fleetSettingsJson, [System.Text.UTF8Encoding]::new($false))
    Assert-True -Name "FleetAPI rejects missing mothership key" -Condition (-not (Test-FleetControlPlaneAuth -Request ([pscustomobject]@{ Headers = @{} })))
    Assert-True -Name "FleetAPI accepts mothership key header" -Condition (Test-FleetControlPlaneAuth -Request ([pscustomobject]@{ Headers = @{ 'X-Dotbot-Mothership-Key' = 'fleet-secret' } }))
    $reg = Register-FleetRuntime -Body ([pscustomobject]@{
        runtime_id = 'rt-test-runtime'
        project_name = 'runtime-test'
        url = $start.url
        token = $start.token
        pid = $start.pid
        started_at = $start.started_at
    })
    Assert-True -Name "FleetAPI registers runtime" -Condition ([bool]$reg.success)
    $fleet = Get-FleetRuntimes
    Assert-True -Name "FleetAPI lists registered runtime" -Condition (@($fleet.runtimes | Where-Object { $_.runtime_id -eq 'rt-test-runtime' }).Count -eq 1)
    $proxy = Invoke-FleetRuntimeProxy -RuntimeId 'rt-test-runtime' -Method GET -ApiPath '/api/info'
    Assert-Equal -Name "FleetAPI proxies /api/info to runtime" -Expected 200 -Actual $proxy.status_code

    # ───── Activity log ─────
    $logPath = Get-ActivityLogPath -BotRoot $bot
    Assert-True -Name "activity.jsonl exists after mutations" -Condition (Test-Path -LiteralPath $logPath)
    $lines = Get-Content -LiteralPath $logPath
    Assert-True -Name "activity.jsonl has multiple entries" -Condition ($lines.Count -ge 4)
    $hasCreated  = $false; $hasUpdated = $false; $hasStatus = $false; $hasRunStarted = $false
    foreach ($l in $lines) {
        $obj = $l | ConvertFrom-Json
        if ($obj.type -eq 'task_created')           { $hasCreated = $true }
        if ($obj.type -eq 'task_updated')           { $hasUpdated = $true }
        if ($obj.type -eq 'task_status_changed')    { $hasStatus  = $true }
        if ($obj.type -eq 'workflow_run_started')   { $hasRunStarted = $true }
    }
    Assert-True -Name "activity.jsonl contains task_created"        -Condition $hasCreated
    Assert-True -Name "activity.jsonl contains task_updated"        -Condition $hasUpdated
    Assert-True -Name "activity.jsonl contains task_status_changed" -Condition $hasStatus
    Assert-True -Name "activity.jsonl contains workflow_run_started" -Condition $hasRunStarted

    # ───── Invoke-RuntimeRequest (client helper) ─────
    $oldUrl   = $env:DOTBOT_RUNTIME_URL
    $oldToken = $env:DOTBOT_RUNTIME_TOKEN
    $env:DOTBOT_RUNTIME_URL   = $start.url
    $env:DOTBOT_RUNTIME_TOKEN = $start.token
    try {
        $clientResp = Invoke-RuntimeRequest -BotRoot $bot -Method GET -Path '/health'
        Assert-Equal -Name "Invoke-RuntimeRequest reads endpoint from env vars" -Expected 200 -Actual $clientResp.status_code
        Assert-Equal -Name "Invoke-RuntimeRequest parses JSON body"               -Expected $true -Actual ([bool]$clientResp.body.ok)

        # Stale-token 401 retry — replace token with wrong, re-resolve happens, but stays wrong → 401 surfaces.
        $env:DOTBOT_RUNTIME_TOKEN = 'totally-wrong'
        $clientResp = Invoke-RuntimeRequest -BotRoot $bot -Method GET -Path '/health'
        Assert-Equal -Name "Invoke-RuntimeRequest surfaces 401 when token cannot be refreshed" -Expected 401 -Actual $clientResp.status_code
    } finally {
        if ($oldUrl)   { $env:DOTBOT_RUNTIME_URL   = $oldUrl }   else { Remove-Item Env:\DOTBOT_RUNTIME_URL   -ErrorAction SilentlyContinue }
        if ($oldToken) { $env:DOTBOT_RUNTIME_TOKEN = $oldToken } else { Remove-Item Env:\DOTBOT_RUNTIME_TOKEN -ErrorAction SilentlyContinue }
    }

} finally {
    if ($start) { Stop-DotbotRuntime -BotRoot $bot -Listener $start.listener -ErrorAction SilentlyContinue }
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Mutex: no lost-writes under concurrent PATCH against the same task
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Mutex: concurrent PATCH does not lose writes" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$bot = New-TestBotRoot
$start = $null
try {
    $start = Start-DotbotRuntime -BotRoot $bot

    # Wait for ready
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try { Invoke-RuntimeRaw -Url $start.url -Method GET -Path '/health' -Token $start.token | Out-Null; break } catch { Start-Sleep -Milliseconds 100 }
    }

    # Create one task
    $r = Invoke-RuntimeRaw -Url $start.url -Method POST -Path '/tasks' -Token $start.token -Body @{
        name = 'mutex-target'; actor = 'test:setup'
    }
    $tid = $r.body.task.id
    Assert-True -Name "Mutex target task created" -Condition ($null -ne $tid)

    # Spawn N concurrent PATCH calls. Each PATCH sets description = "patch-i".
    # The PRD requires "final state contains all updates (no lost writes)" —
    # in practice that means the file is well-formed JSON containing one of the
    # PATCH values (since they overwrite the same field) AND the activity log
    # has N task_updated lines.
    $jobs = 1..10 | ForEach-Object {
        $i = $_
        Start-ThreadJob -ScriptBlock {
            param($url, $token, $tid, $i)
            $body = @{ description = "patch-$i"; actor = "test:job$i" } | ConvertTo-Json -Depth 5
            Invoke-WebRequest `
                -Uri "$($url.TrimEnd('/'))/tasks/$tid" `
                -Method PATCH `
                -Headers @{ Authorization = "Bearer $token" } `
                -Body $body `
                -ContentType 'application/json' `
                -SkipHttpErrorCheck `
                -TimeoutSec 30 | Out-Null
        } -ArgumentList $start.url, $start.token, $tid, $i
    }
    $null = $jobs | Wait-Job -Timeout 60
    $jobs | Remove-Job -Force

    # Final task is well-formed and lands on one of the patch-i values.
    $final = Invoke-RuntimeRaw -Url $start.url -Method GET -Path "/tasks/$tid" -Token $start.token
    Assert-Equal -Name "Post-concurrency: final GET returns 200"            -Expected 200 -Actual $final.status_code
    Assert-True  -Name "Post-concurrency: description matches one of patch-*" `
        -Condition ($final.body.task.description -match '^patch-\d+$')

    # Activity log carries one task_updated line per successful PATCH (10 total).
    $logPath = Get-ActivityLogPath -BotRoot $bot
    $updatedLines = 0
    Get-Content -LiteralPath $logPath | ForEach-Object {
        try {
            $obj = $_ | ConvertFrom-Json -ErrorAction Stop
            if ($obj.type -eq 'task_updated' -and $obj.task_id -eq $tid) { $updatedLines++ }
        } catch { }
    }
    Assert-Equal -Name "Activity log contains exactly 10 task_updated lines for the target task" -Expected 10 -Actual $updatedLines

} finally {
    if ($start) { Stop-DotbotRuntime -BotRoot $bot -Listener $start.listener -ErrorAction SilentlyContinue }
    Remove-TestBotRoot -BotRoot $bot
}

# ═══════════════════════════════════════════════════════════════════════════
# Mutex: deterministic acquire order for multi-task ops
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Mutex: multi-task acquire order is canonical-ID-ascending" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

Clear-RuntimeMutexPool
$ids = @('t_ZZZZZZZZ','t_AAAAAAAA','t_MMMMMMMM')
$ordered = Lock-TaskMutexes -TaskIds $ids
try {
    Assert-Equal -Name "Lock-TaskMutexes sorts IDs ascending" -Expected 't_AAAAAAAA t_MMMMMMMM t_ZZZZZZZZ' -Actual ($ordered -join ' ')
} finally {
    Unlock-TaskMutexes -TaskIds $ids
}
Clear-RuntimeMutexPool

# ═══════════════════════════════════════════════════════════════════════════
# _Send-JsonResponse idempotency: regression for the needs-input escalation
# crash. Any handler that sends a response and then throws would previously
# trip the dispatcher into re-serializing onto a closed HttpListenerResponse
# and crash with "already submitted" / "disposed object" from the property
# setters. Fix: the first send stamps _dotbotSent on the response; every
# subsequent _Send-* is a no-op.
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  _Send-JsonResponse idempotency (double-send guard)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

# HttpListenerResponse is a sealed .NET class with no public constructor,
# so we stand in a PSCustomObject exposing just the surface _Send-JsonResponse
# touches: StatusCode / ContentType / ContentLength64 / OutputStream / Close().
function New-FakeHttpResponse {
    $r = [PSCustomObject]@{
        StatusCode      = 0
        ContentType     = ''
        ContentLength64 = 0
        OutputStream    = [System.IO.MemoryStream]::new()
        CloseCount      = 0
    }
    $r | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.CloseCount++ }
    return $r
}

# _Send-JsonResponse is defined in Dotbot.Runtime's HttpServer *nested* module.
# The top-level Dotbot.Runtime scope can't see nested private functions, so we
# grab the nested-module handle by name and invoke through it — same trick
# Pester's InModuleScope uses.
$httpMod = (Get-Module Dotbot.Runtime).NestedModules | Where-Object { $_.Name -eq 'HttpServer' } | Select-Object -First 1
Assert-True -Name "HttpServer nested module is loaded (test scaffolding sanity)" -Condition ($null -ne $httpMod)

$fake = New-FakeHttpResponse
& $httpMod {
    param($resp)
    _Send-JsonResponse -Response $resp -Status 200 -Body @{ ok = $true; n = 1 }
} $fake

Assert-Equal -Name "First send sets StatusCode = 200"          -Expected 200 -Actual $fake.StatusCode
Assert-Equal -Name "First send calls Close() exactly once"     -Expected 1   -Actual $fake.CloseCount
Assert-True  -Name "First send stamps _dotbotSent on response" `
    -Condition ($fake.PSObject.Properties['_dotbotSent'] -and $fake._dotbotSent -eq $true)
Assert-True  -Name "First send writes body bytes to OutputStream" `
    -Condition ($fake.OutputStream.Length -gt 0)

$bytesAfterFirst = $fake.OutputStream.Length

# Second call — simulates the dispatcher's catch calling _Send-ErrorResponse
# after the handler already responded. Must be a no-op: no StatusCode change,
# no additional Close(), no additional bytes written.
& $httpMod {
    param($resp)
    _Send-JsonResponse -Response $resp -Status 500 -Body @{ error = 'internal_error' }
} $fake

Assert-Equal -Name "Second send does NOT overwrite StatusCode" -Expected 200 -Actual $fake.StatusCode
Assert-Equal -Name "Second send does NOT re-Close()"           -Expected 1   -Actual $fake.CloseCount
Assert-Equal -Name "Second send writes no additional bytes"    -Expected $bytesAfterFirst -Actual $fake.OutputStream.Length

# _Send-ErrorResponse delegates to _Send-JsonResponse, so the guard covers it
# too — the dispatcher's catch calls _Send-ErrorResponse on the closed response.
$fake2 = New-FakeHttpResponse
& $httpMod {
    param($resp)
    _Send-JsonResponse   -Response $resp -Status 200 -Body @{ ok = $true }
    _Send-ErrorResponse  -Response $resp -Status 500 -Code 'internal_error' -Message 'post-response throw'
} $fake2

Assert-Equal -Name "_Send-ErrorResponse after prior send is a no-op (StatusCode preserved)" `
    -Expected 200 -Actual $fake2.StatusCode
Assert-Equal -Name "_Send-ErrorResponse after prior send does not re-Close()" `
    -Expected 1   -Actual $fake2.CloseCount

Write-TestSummary -LayerName "Runtime"

if ((Get-TestResults).Failed -gt 0) { exit 1 } else { exit 0 }
