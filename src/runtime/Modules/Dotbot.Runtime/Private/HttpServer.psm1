<#
.SYNOPSIS
HTTP listener + auth + routing + request handlers for the runtime.

The listener binds 127.0.0.1 only. Every request runs through Test-BearerAuth;
401 is returned for missing/wrong auth. Routes are resolved by an ordered
table of method + path-pattern → handler entries; pattern captures populate
$Context.RouteParams.

Concurrency: each accepted request is queued to the ThreadPool so listener
acceptance doesn't serialise handler execution. Per-task / per-run
serialisation is achieved inside the handlers via the Mutex.psm1 pool.

Handlers are kept thin — schema validation lives in Dotbot.Task /
Dotbot.Workflow, transition enforcement lives in Dotbot.Task, isolation
rules live in Dotbot.Workflow. This file just routes and serialises.

Executors and transition hooks are out of scope here; the relevant
extension points carry an explicit comment so the next implementer can
find them.
#>

# ---------------------------------------------------------------------------
# Listener state
# ---------------------------------------------------------------------------

$script:DotbotRuntimeListenerState = $null

function _New-RouteTable {
    # Ordered list so static paths can win over patterned ones if needed.
    # Each entry: @{ method = 'GET'; pattern = '^/tasks/(?<id>t_[A-Za-z0-9]{8})$'; handler = { ... } }
    return @(
        @{ method = 'GET';   pattern = '^/health$';                                            handler = 'Invoke-HealthHandler' }

        # Tasks
        @{ method = 'POST';  pattern = '^/tasks$';                                             handler = 'Invoke-CreateTaskHandler' }
        @{ method = 'GET';   pattern = '^/tasks/next$';                                        handler = 'Invoke-GetNextTaskHandler' }
        @{ method = 'GET';   pattern = '^/tasks/(?<id>t_[A-Za-z0-9]{8})$';                     handler = 'Invoke-GetTaskHandler' }
        @{ method = 'PATCH'; pattern = '^/tasks/(?<id>t_[A-Za-z0-9]{8})$';                     handler = 'Invoke-PatchTaskHandler' }
        @{ method = 'POST';  pattern = '^/tasks/(?<id>t_[A-Za-z0-9]{8})/status$';              handler = 'Invoke-TaskStatusHandler' }
        @{ method = 'GET';   pattern = '^/tasks/(?<id>t_[A-Za-z0-9]{8})/context$';             handler = 'Invoke-GetTaskContextHandler' }
        @{ method = 'GET';   pattern = '^/tasks$';                                             handler = 'Invoke-ListTasksHandler' }

        # Workflow runs
        @{ method = 'POST';  pattern = '^/workflows/runs$';                                    handler = 'Invoke-CreateRunHandler' }
        @{ method = 'GET';   pattern = '^/workflows/runs/(?<id>wr_[A-Za-z0-9]{8})$';           handler = 'Invoke-GetRunHandler' }
        @{ method = 'GET';   pattern = '^/workflows/runs$';                                    handler = 'Invoke-ListRunsHandler' }

        # Dashboard/fleet surface. These routes intentionally mirror
        # the UI's project APIs but remain runtime-owned so a remote dashboard
        # can control this project through registration/proxy.
        @{ method = 'GET';   pattern = '^/dashboard/info$';                                    handler = 'Invoke-DashboardInfoHandler' }
        @{ method = 'GET';   pattern = '^/dashboard/state$';                                   handler = 'Invoke-DashboardStateHandler' }
        @{ method = 'GET';   pattern = '^/dashboard/state/poll$';                              handler = 'Invoke-DashboardStateHandler' }
        @{ method = 'GET';   pattern = '^/dashboard/activity/tail$';                           handler = 'Invoke-DashboardActivityTailHandler' }
        @{ method = 'GET';   pattern = '^/dashboard/processes$';                               handler = 'Invoke-DashboardProcessesHandler' }
        @{ method = 'GET';   pattern = '^/dashboard/processes/(?<id>[^/]+)/output$';           handler = 'Invoke-DashboardProcessOutputHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/processes/(?<id>[^/]+)/stop$';             handler = 'Invoke-DashboardProcessStopHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/processes/(?<id>[^/]+)/kill$';             handler = 'Invoke-DashboardProcessKillHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/processes/(?<id>[^/]+)/whisper$';          handler = 'Invoke-DashboardProcessWhisperHandler' }
        @{ method = 'GET';   pattern = '^/dashboard/workflows/installed$';                     handler = 'Invoke-DashboardWorkflowsInstalledHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/workflows/(?<name>[A-Za-z0-9_-]+)/run$';   handler = 'Invoke-DashboardWorkflowRunHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/workflows/(?<name>[A-Za-z0-9_-]+)/stop$';  handler = 'Invoke-DashboardWorkflowStopHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/tasks/run-pending$';                       handler = 'Invoke-DashboardRunPendingHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/tasks/stop-pending$';                      handler = 'Invoke-DashboardStopPendingHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/control$';                                 handler = 'Invoke-DashboardControlHandler' }
        @{ method = 'POST';  pattern = '^/dashboard/whisper$';                                 handler = 'Invoke-DashboardWhisperHandler' }
    )
}

function Start-RuntimeHttpListener {
    <#
    .SYNOPSIS
    Bring up an HttpListener bound to $Url, register the route table, and
    start accepting on a background PowerShell runspace.

    .OUTPUTS
    The HttpListener instance. Caller stops with Stop-RuntimeHttpListener.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Token
    )

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Url)
    $listener.Start()

    # The accept loop and per-request handlers BOTH need a PowerShell runspace —
    # they execute script code (Invoke-RuntimeRequestDispatch). A bare
    # System.Threading.Thread has no Runspace, so we build a small pool and run
    # both the accept loop and each request inside it. PRD User Story 10
    # ("concurrent updates to different tasks proceed in parallel") needs a
    # min/max > 1 so a long-running handler doesn't block the next accept.
    # The module must be imported into the initial session state of each
    # runspace; otherwise per-request runspaces won't see the runtime functions.
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $modulePsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'Dotbot.Runtime.psd1'
    [void]$iss.ImportPSModule(@($modulePsd1))

    $pool = [runspacefactory]::CreateRunspacePool(1, 8, $iss, $Host)
    $pool.Open()

    $script:DotbotRuntimeListenerState = [ordered]@{
        listener      = $listener
        bot_root      = $BotRoot
        token         = $Token
        url           = $Url
        routes        = _New-RouteTable
        started       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        runspace_pool = $pool
        accept_ps     = $null
    }

    # The accept loop. Lives in its own PowerShell instance so it has a
    # Runspace; each accepted context fires another PowerShell instance into
    # the shared pool so the next accept doesn't wait on the handler.
    $acceptScript = {
        param($listener, $botRoot, $token, $routes, $pool, $modulePsd1)

        # Ensure the runtime module is loaded in *this* runspace (the accept
        # loop's). The pool runspaces get it via InitialSessionState.
        Import-Module $modulePsd1 -DisableNameChecking -Force

        while ($listener.IsListening) {
            $ctx = $null
            try {
                $ctx = $listener.GetContext()
            } catch {
                # GetContext throws when the listener is stopped.
                if (-not $listener.IsListening) { return }
                continue
            }

            $handlerScript = {
                param($ctx, $botRoot, $token, $routes)
                try {
                    Invoke-RuntimeRequestDispatch -Context $ctx -BotRoot $botRoot -Token $token -Routes $routes
                } catch {
                    $errMsg = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
                    # Best-effort: also write the failure to a debug file so an
                    # in-runspace exception with no visible output trail can
                    # still be diagnosed during test runs.
                    try {
                        $dbg = Join-Path $botRoot (Join-Path '.control' 'runtime-errors.log')
                        Add-Content -LiteralPath $dbg -Value "[$([DateTime]::UtcNow.ToString('o'))] $errMsg" -ErrorAction SilentlyContinue
                    } catch { $null = $_ }
                    try {
                        $resp = $ctx.Response
                        $resp.StatusCode  = 500
                        $resp.ContentType = 'application/json; charset=utf-8'
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes(((@{ error = 'internal_error'; message = $errMsg } | ConvertTo-Json -Depth 4)))
                        $resp.ContentLength64 = $bytes.Length
                        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
                    } catch { $null = $_ }
                    finally {
                        try { $ctx.Response.Close() } catch { $null = $_ }
                    }
                }
            }
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($handlerScript)
            $null = $ps.AddArgument($ctx)
            $null = $ps.AddArgument($botRoot)
            $null = $ps.AddArgument($token)
            $null = $ps.AddArgument($routes)
            # Fire-and-forget. We discard the IAsyncResult — handler errors are
            # caught inside $handlerScript and surfaced via HTTP 500.
            [void]$ps.BeginInvoke()
        }
    }

    $acceptPs = [powershell]::Create()
    # Give the accept loop its own runspace (NOT in the handler pool; we want
    # the loop's blocking GetContext() call to never compete with a handler
    # for a pool slot).
    $acceptRunspace = [runspacefactory]::CreateRunspace($Host, $iss)
    $acceptRunspace.Open()
    $acceptPs.Runspace = $acceptRunspace
    $null = $acceptPs.AddScript($acceptScript)
    $null = $acceptPs.AddArgument($listener)
    $null = $acceptPs.AddArgument($BotRoot)
    $null = $acceptPs.AddArgument($Token)
    $null = $acceptPs.AddArgument($script:DotbotRuntimeListenerState.routes)
    $null = $acceptPs.AddArgument($pool)
    $null = $acceptPs.AddArgument($modulePsd1)
    [void]$acceptPs.BeginInvoke()

    $script:DotbotRuntimeListenerState['accept_ps']         = $acceptPs
    $script:DotbotRuntimeListenerState['accept_runspace']   = $acceptRunspace

    return $listener
}

function Stop-RuntimeHttpListener {
    <#
    .SYNOPSIS
    Stop the HTTP listener cleanly. Idempotent.
    #>
    [CmdletBinding()]
    param(
        [System.Net.HttpListener]$Listener
    )

    $state = $script:DotbotRuntimeListenerState
    if (-not $Listener -and $state) {
        $Listener = $state.listener
    }
    if (-not $Listener) { return }

    try { if ($Listener.IsListening) { $Listener.Stop() } } catch { $null = $_ }
    try { $Listener.Close() } catch { $null = $_ }

    if ($state) {
        # The accept loop's GetContext() unblocks when the listener stops; give
        # it a moment to exit so the runspace can dispose cleanly.
        try {
            if ($state.accept_ps) {
                # Brief wait; the accept loop exits within milliseconds of Stop().
                $waitEnd = [DateTime]::UtcNow.AddSeconds(2)
                while (-not $state.accept_ps.InvocationStateInfo.State.HasFlag([System.Management.Automation.PSInvocationState]::Completed) `
                    -and [DateTime]::UtcNow -lt $waitEnd) {
                    Start-Sleep -Milliseconds 25
                }
                $state.accept_ps.Dispose()
            }
        } catch { $null = $_ }
        try { if ($state.accept_runspace) { $state.accept_runspace.Dispose() } } catch { $null = $_ }
        try { if ($state.runspace_pool)   { $state.runspace_pool.Close(); $state.runspace_pool.Dispose() } } catch { $null = $_ }
    }

    $script:DotbotRuntimeListenerState = $null
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

function _Send-JsonResponse {
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] [int]$Status,
        [object]$Body
    )
    $Response.StatusCode  = $Status
    $Response.ContentType = 'application/json; charset=utf-8'

    if ($null -eq $Body) {
        $bytes = [byte[]]@()
    } else {
        $json = $Body | ConvertTo-Json -Depth 20
        # Defensive: ConvertTo-Json returns whitespace for a $null body but a
        # bare string for a single-field hashtable; force string for bytes.
        if ($json -isnot [string]) { $json = [string]$json }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    }

    $Response.ContentLength64 = $bytes.Length
    if ($bytes.Length -gt 0) {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    $Response.Close()
}

function _Send-ErrorResponse {
    param(
        [Parameter(Mandatory)] $Response,
        [Parameter(Mandatory)] [int]$Status,
        [Parameter(Mandatory)] [string]$Code,
        [string]$Message,
        [hashtable]$Extra
    )
    $body = [ordered]@{ error = $Code }
    if ($Message) { $body['message'] = $Message }
    if ($Extra)   { foreach ($k in $Extra.Keys) { $body[$k] = $Extra[$k] } }
    _Send-JsonResponse -Response $Response -Status $Status -Body $body
}

function _Read-RequestBody {
    param($Request)
    if (-not $Request.HasEntityBody) { return $null }
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        $raw = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }
    if (-not $raw) { return $null }
    try {
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Request body is not valid JSON: $($_.Exception.Message)"
    }
}

function _Test-BearerAuth {
    param(
        [Parameter(Mandatory)] $Request,
        [Parameter(Mandatory)] [string]$ExpectedToken
    )
    $authHeader = $Request.Headers['Authorization']
    if (-not $authHeader) { return $false }
    # Format: 'Bearer <token>'. Tolerate extra whitespace.
    if ($authHeader -notmatch '^\s*Bearer\s+(\S+)\s*$') { return $false }
    $presented = $Matches[1]
    # Constant-time compare to keep timing attacks off the table for a token
    # discoverable from a local file. Belt-and-braces; we're loopback only.
    $a = [System.Text.Encoding]::UTF8.GetBytes($presented)
    $b = [System.Text.Encoding]::UTF8.GetBytes($ExpectedToken)
    if ($a.Length -ne $b.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    return ($diff -eq 0)
}

function Invoke-RuntimeRequestDispatch {
    <#
    .SYNOPSIS
    Dispatch one HttpListenerContext to the matching handler.

    .DESCRIPTION
    Public for tests but you should never call this from production code —
    Start-RuntimeHttpListener wires it to the accept loop already.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [object[]]$Routes
    )

    $request  = $Context.Request
    $response = $Context.Response

    # ---- Auth ----
    if (-not (_Test-BearerAuth -Request $request -ExpectedToken $Token)) {
        _Send-ErrorResponse -Response $response -Status 401 -Code 'unauthorized' -Message 'Bearer token missing or invalid.'
        return
    }

    # ---- Path + method match ----
    $rawPath = $request.Url.AbsolutePath
    $method  = $request.HttpMethod.ToUpperInvariant()

    $matched = $null
    $routeParams = @{}
    foreach ($r in $Routes) {
        if ($r.method -ne $method) { continue }
        $m = [regex]::Match($rawPath, $r.pattern)
        if (-not $m.Success) { continue }
        $matched = $r
        foreach ($name in $m.Groups.Keys) {
            # Numeric group keys (0, 1, ...) are also in Groups; skip them.
            if ($name -is [int]) { continue }
            if ($name -eq '0') { continue }
            $routeParams[$name] = $m.Groups[$name].Value
        }
        break
    }

    if (-not $matched) {
        _Send-ErrorResponse -Response $response -Status 404 -Code 'not_found' -Message "No route matches $method $rawPath"
        return
    }

    # Parse query string into a flat hashtable.
    $query = @{}
    foreach ($k in $request.QueryString.AllKeys) {
        if ($null -eq $k) { continue }
        $query[$k] = $request.QueryString[$k]
    }

    # Parse body (JSON) for POST/PATCH. Empty body is ok for both — handlers decide.
    $body = $null
    if ($method -in @('POST', 'PATCH', 'PUT')) {
        try {
            $body = _Read-RequestBody -Request $request
        } catch {
            _Send-ErrorResponse -Response $response -Status 400 -Code 'bad_json' -Message $_.Exception.Message
            return
        }
    }

    # Hand off to the handler. Each handler accepts the same call shape.
    $handlerFn = Get-Command $matched.handler -ErrorAction SilentlyContinue
    if (-not $handlerFn) {
        _Send-ErrorResponse -Response $response -Status 500 -Code 'handler_missing' -Message "Handler '$($matched.handler)' is not registered."
        return
    }

    try {
        & $handlerFn `
            -BotRoot     $BotRoot `
            -Response    $response `
            -Request     $request `
            -RouteParams $routeParams `
            -Query       $query `
            -Body        $body
    } catch {
        _Send-ErrorResponse -Response $response -Status 500 -Code 'internal_error' -Message $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Helpers shared by handlers
# ---------------------------------------------------------------------------

function _Get-WorkspaceRoot {
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path $BotRoot 'workspace'
}

function _Get-TasksRoot {
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path (Join-Path $BotRoot 'workspace') 'tasks'
}

function _Get-RunsControlDir {
    param([Parameter(Mandatory)] [string]$BotRoot)
    return Join-Path $BotRoot (Join-Path '.control' 'workflow-runs')
}

function _Find-TaskFileById {
    <#
    .SYNOPSIS
    Find the file for a given canonical task ID.

    .DESCRIPTION
    Task files are scattered across
    workspace/tasks/workflow-runs/<dir>/t_<id>.json and
    workspace/tasks/standalone/<date>-<slug>-<short>.json.

    Returns the first matching file path or $null when not found. See
    implementation-notes.html — this is a disk walk for the first cut; a
    later PRD can add a FileSystemWatcher-backed index.
    #>
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$TaskId
    )

    if (-not (Test-TaskId -Id $TaskId)) { return $null }

    $tasksRoot = _Get-TasksRoot -BotRoot $BotRoot
    if (-not (Test-Path -LiteralPath $tasksRoot)) { return $null }

    # Fast path: run directories use t_<id>.json filenames.
    $runsRoot = Join-Path $tasksRoot 'workflow-runs'
    if (Test-Path -LiteralPath $runsRoot) {
        $hit = Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter "$TaskId.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    # Slow path: standalone directory uses date-slug-short.json. Read each file
    # and match by `id`.
    $standaloneRoot = Join-Path $tasksRoot 'standalone'
    if (Test-Path -LiteralPath $standaloneRoot) {
        $candidates = Get-ChildItem -LiteralPath $standaloneRoot -Filter '*.json' -File -ErrorAction SilentlyContinue
        foreach ($c in $candidates) {
            try {
                $parsed = Get-Content -LiteralPath $c.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($parsed.id -eq $TaskId) { return $c.FullName }
            } catch { continue }
        }
    }

    return $null
}

function _Read-TaskFile {
    param([Parameter(Mandatory)] [string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    return ($raw | ConvertFrom-Json -AsHashtable)
}

function _Write-TaskFileAtomic {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Content
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$Path.tmp"
    $json = $Content | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function _Now-Utc {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function _Convert-JsonObjectLike {
    param($Value)
    if ($Value -is [string]) {
        $trimmed = $Value.Trim()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try { return ($trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop) } catch { return $Value }
        }
    }
    return $Value
}

function _Merge-JsonObject {
    param($Current, $Incoming)

    $incomingValue = _Convert-JsonObjectLike -Value $Incoming
    if ($incomingValue -isnot [System.Collections.IDictionary] -and
        $incomingValue -isnot [PSCustomObject]) {
        return $incomingValue
    }

    $merged = if ($Current -is [System.Collections.IDictionary]) {
        $Current
    } else {
        @{}
    }

    $incomingItems = if ($incomingValue -is [System.Collections.IDictionary]) {
        $incomingValue.GetEnumerator()
    } else {
        $incomingValue.PSObject.Properties | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Value = $_.Value }
        }
    }

    foreach ($item in $incomingItems) {
        $key = [string]$item.Key
        $next = _Convert-JsonObjectLike -Value $item.Value
        if ($merged.Contains($key) -and
            (($merged[$key] -is [System.Collections.IDictionary] -or $merged[$key] -is [PSCustomObject]) -and
             ($next -is [System.Collections.IDictionary] -or $next -is [PSCustomObject]))) {
            $merged[$key] = _Merge-JsonObject -Current $merged[$key] -Incoming $next
        } else {
            $merged[$key] = $next
        }
    }

    return $merged
}

function _Ensure-DashboardModules {
    param([Parameter(Mandatory)] [string]$BotRoot)

    $controlDir = Join-Path $BotRoot '.control'
    $processesDir = Join-Path $controlDir 'processes'
    if (-not (Test-Path -LiteralPath $processesDir)) {
        New-Item -ItemType Directory -Path $processesDir -Force | Out-Null
    }

    $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    $srcRoot = Split-Path -Parent $runtimeRoot
    $uiModules = Join-Path $srcRoot 'ui/modules'

    foreach ($moduleName in @('StateBuilder', 'ProcessAPI', 'ControlAPI')) {
        $modulePath = Join-Path $uiModules "$moduleName.psm1"
        if (Test-Path -LiteralPath $modulePath) {
            Import-Module $modulePath -DisableNameChecking -ErrorAction Stop
        }
    }

    $projectRoot = Split-Path -Parent $BotRoot
    Initialize-StateBuilder -BotRoot $BotRoot -ControlDir $controlDir -ProcessesDir $processesDir
    Initialize-ProcessAPI -ProcessesDir $processesDir -BotRoot $BotRoot -ControlDir $controlDir
    Initialize-ControlAPI -ControlDir $controlDir -ProcessesDir $processesDir -BotRoot $BotRoot

    return [ordered]@{
        control_dir   = $controlDir
        processes_dir = $processesDir
        project_root  = $projectRoot
    }
}

function _Get-DashboardInfoPayload {
    param([Parameter(Mandatory)] [string]$BotRoot)

    $projectRoot = Split-Path -Parent $BotRoot
    $settings = $null
    try { $settings = Get-MergedSettings -BotRoot $BotRoot } catch { $settings = $null }
    $workflowName = if ($settings -and $settings.PSObject.Properties['workflow']) { [string]$settings.workflow } else { $null }

    $installed = @()
    try {
        $tierRoots = Get-WorkflowTierRoots -BotRoot $BotRoot
        foreach ($tier in @($tierRoots.framework, $tierRoots.project)) {
            if (-not $tier -or -not (Test-Path -LiteralPath $tier)) { continue }
            foreach ($dir in Get-ChildItem -LiteralPath $tier -Directory -ErrorAction SilentlyContinue) {
                if (-not (Test-ValidWorkflowDir -Dir $dir.FullName)) { continue }
                if ($installed -contains $dir.Name) { continue }
                $installed += $dir.Name
            }
        }
    } catch { $installed = @() }

    return [ordered]@{
        project_name        = Split-Path -Leaf $projectRoot
        project_root        = $projectRoot
        bot_root            = $BotRoot
        active_workflow     = $workflowName
        installed_workflows = @($installed | Sort-Object)
        framework           = [ordered]@{
            dotbot_home = Get-DotbotInstallPath
        }
    }
}

function _Get-DashboardInstalledWorkflows {
    param([Parameter(Mandatory)] [string]$BotRoot)

    $layout = _Ensure-DashboardModules -BotRoot $BotRoot
    $tasksDir = Join-Path $BotRoot 'workspace/tasks'
    $tasksByWorkflow = @{}
    foreach ($f in Get-ChildItem -LiteralPath $tasksDir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        if ($f.Name -eq 'run.json') { continue }
        try {
            $task = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $wf = $null
            if ($task.PSObject.Properties['provenance'] -and $task.provenance.PSObject.Properties['workflow']) {
                $wf = [string]$task.provenance.workflow
            }
            $key = if ($wf) { $wf } else { '__default__' }
            if (-not $tasksByWorkflow.ContainsKey($key)) {
                $tasksByWorkflow[$key] = @{ todo = 0; in_progress = 0; done = 0; total = 0 }
            }
            $tasksByWorkflow[$key].total++
            switch ([string]$task.status) {
                'todo'        { $tasksByWorkflow[$key].todo++ }
                'in-progress' { $tasksByWorkflow[$key].in_progress++ }
                'done'        { $tasksByWorkflow[$key].done++ }
            }
        } catch { continue }
    }

    $running = @()
    if (Test-Path -LiteralPath $layout.processes_dir) {
        $running = @(Get-ChildItem -LiteralPath $layout.processes_dir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { $null }
        } | Where-Object { $_ -and $_.status -in @('running','starting') })
    }

    $items = @()
    $seen = @{}
    try {
        $tierRoots = Get-WorkflowTierRoots -BotRoot $BotRoot
        foreach ($tier in @(
            @{ key = 'framework'; dir = $tierRoots.framework },
            @{ key = 'project'; dir = $tierRoots.project }
        )) {
            if (-not $tier.dir -or -not (Test-Path -LiteralPath $tier.dir)) { continue }
            foreach ($dir in Get-ChildItem -LiteralPath $tier.dir -Directory -ErrorAction SilentlyContinue) {
                if (-not (Test-ValidWorkflowDir -Dir $dir.FullName)) { continue }
                $manifest = Read-WorkflowManifest -WorkflowDir $dir.FullName
                $name = [string]$manifest.name
                if (-not $name) { $name = $dir.Name }
                if ($seen.ContainsKey($name) -and $tier.key -ne 'project') { continue }
                if ($seen.ContainsKey($name) -and $tier.key -eq 'project') {
                    $items = @($items | Where-Object { $_.name -ne $name })
                }
                $seen[$name] = $true
                $bucket = if ($tasksByWorkflow.ContainsKey($name)) { $tasksByWorkflow[$name] } else { @{ todo = 0; in_progress = 0; done = 0; total = 0 } }
                $hasRunning = @($running | Where-Object { $_.type -eq 'task-runner' -and "$($_.description)" -like "*$name*" }).Count -gt 0
                $items += [ordered]@{
                    name = $name
                    description = if ($manifest.description) { [string]$manifest.description } else { '' }
                    icon = if ($manifest['icon']) { [string]$manifest['icon'] } else { '' }
                    tags = if ($manifest['tags']) { @($manifest['tags']) } else { @() }
                    status = if ($hasRunning) { 'running' } else { 'idle' }
                    tasks = $bucket
                    has_running_process = $hasRunning
                    has_form = [bool]$manifest['form']
                    source = $tier.key
                }
            }
        }
    } catch { $items = @() }

    return @{ workflows = @($items) }
}

function _Read-RunRecord {
    <#
    .SYNOPSIS
    Read both halves of a workflow run by ID: committed (run.json) and live
    status (.control/workflow-runs/<wr_id>.json). Returns @{ record; status; run_dir }
    or $null when neither half exists.
    #>
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$RunId
    )
    if (-not (Test-WorkflowRunId -Id $RunId)) { return $null }

    $statusPath = Join-Path (_Get-RunsControlDir -BotRoot $BotRoot) "$RunId.json"
    $statusObj  = $null
    if (Test-Path -LiteralPath $statusPath) {
        try {
            $statusObj = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -AsHashtable
        } catch { $statusObj = $null }
    }

    # Committed record dir name uses the 4-char short ID derived from the canonical ID.
    $short = Get-ShortId -Id $RunId
    $runsCommittedRoot = Join-Path (_Get-TasksRoot -BotRoot $BotRoot) 'workflow-runs'
    $recordObj = $null
    $runDir    = $null
    if (Test-Path -LiteralPath $runsCommittedRoot) {
        $candidates = Get-ChildItem -LiteralPath $runsCommittedRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-$short" }
        foreach ($candidate in $candidates) {
            $runJson = Join-Path $candidate.FullName 'run.json'
            if (-not (Test-Path -LiteralPath $runJson)) { continue }
            try {
                $parsed = Get-Content -LiteralPath $runJson -Raw | ConvertFrom-Json -AsHashtable
                if ($parsed.run_id -eq $RunId) {
                    $recordObj = $parsed
                    $runDir    = $candidate.FullName
                    break
                }
            } catch { continue }
        }
    }

    if (-not $recordObj -and -not $statusObj) { return $null }
    return [ordered]@{
        record  = $recordObj
        status  = $statusObj
        run_dir = $runDir
    }
}

function _Get-ActiveRuns {
    <#
    .SYNOPSIS
    Return all currently-running WorkflowRun records for Test-CanStartRun.
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)

    $controlDir = _Get-RunsControlDir -BotRoot $BotRoot
    if (-not (Test-Path -LiteralPath $controlDir)) { return @() }

    $result = @()
    Get-ChildItem -LiteralPath $controlDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $status = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($status.status -ne 'running') { return }
            $runId = $status.run_id
            $bundle = _Read-RunRecord -BotRoot $BotRoot -RunId $runId
            if (-not $bundle -or -not $bundle.record) { return }
            $result += [ordered]@{
                id            = $runId
                status        = 'running'
                workflow_name = $bundle.record.workflow_name
            }
        } catch { return }
    }
    return ,$result
}

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

function Invoke-HealthHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Send-JsonResponse -Response $Response -Status 200 -Body @{
        ok         = $true
        pid        = $PID
        started_at = $script:DotbotRuntimeListenerState.started
    }
}

function Invoke-DashboardInfoHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Send-JsonResponse -Response $Response -Status 200 -Body (_Get-DashboardInfoPayload -BotRoot $BotRoot)
}

function Invoke-DashboardStateHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    _Send-JsonResponse -Response $Response -Status 200 -Body (Get-BotState)
}

function Invoke-DashboardActivityTailHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $position = if ($Query['position']) { [long]$Query['position'] } else { 0L }
    $tail = if ($Query['tail']) { [int]$Query['tail'] } else { 0 }
    _Send-JsonResponse -Response $Response -Status 200 -Body (Get-ActivityTail -Position $position -TailLines $tail)
}

function Invoke-DashboardProcessesHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    _Send-JsonResponse -Response $Response -Status 200 -Body (Get-ProcessList -FilterType $Query['type'] -FilterStatus $Query['status'])
}

function Invoke-DashboardProcessOutputHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $position = if ($Query['position']) { [int]$Query['position'] } else { 0 }
    $tail = if ($Query['tail']) { [int]$Query['tail'] } else { 50 }
    _Send-JsonResponse -Response $Response -Status 200 -Body (Get-ProcessOutput -ProcessId $RouteParams['id'] -Position $position -Tail $tail)
}

function Invoke-DashboardProcessStopHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    _Send-JsonResponse -Response $Response -Status 200 -Body (Stop-ProcessById -ProcessId $RouteParams['id'])
}

function Invoke-DashboardProcessKillHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $result = Stop-ManagedProcessById -ProcessId $RouteParams['id']
    if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) {
        $status = [int]$result._statusCode
        $result.Remove('_statusCode')
        _Send-JsonResponse -Response $Response -Status $status -Body $result
        return
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body $result
}

function Invoke-DashboardProcessWhisperHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $message = if ($Body -and $Body.PSObject.Properties['message']) { [string]$Body.message } else { '' }
    $priority = if ($Body -and $Body.PSObject.Properties['priority']) { [string]$Body.priority } else { 'normal' }
    _Send-JsonResponse -Response $Response -Status 200 -Body (Send-ProcessWhisper -ProcessId $RouteParams['id'] -Message $message -Priority $priority)
}

function Invoke-DashboardWorkflowsInstalledHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Send-JsonResponse -Response $Response -Status 200 -Body (_Get-DashboardInstalledWorkflows -BotRoot $BotRoot)
}

function Invoke-DashboardWorkflowRunHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    $layout = _Ensure-DashboardModules -BotRoot $BotRoot
    $wfName = $RouteParams['name']
    $resolved = Find-Workflow -BotRoot $BotRoot -Name $wfName
    if (-not $resolved.ok) {
        _Send-ErrorResponse -Response $Response -Status 404 -Code 'not_found' -Message "Workflow not found: $wfName"
        return
    }

    $gitCheck = Test-GitReadyForWorktree -ProjectRoot $layout.project_root
    if (-not $gitCheck.ok) {
        _Send-ErrorResponse -Response $Response -Status 422 -Code 'git_not_ready' -Message $gitCheck.message -Extra @{ reason = $gitCheck.reason }
        return
    }

    $activeRuns = Get-ActiveWorkflowRuns -BotRoot $BotRoot
    $startDecision = Test-CanStartRun -NewRun @{ workflow_name = $wfName } -ActiveRuns $activeRuns
    if (-not $startDecision.ok) {
        _Send-ErrorResponse -Response $Response -Status 409 -Code $startDecision.reason -Message $startDecision.message -Extra @{ blocking_run_id = $startDecision.blocking_run_id }
        return
    }

    $manifest = Read-WorkflowManifest -WorkflowDir $resolved.path
    $run = Initialize-WorkflowRun -BotRoot $BotRoot -WorkflowName $wfName -StartedBy 'ui:fleet-workflow-start' -WorkflowPath $resolved.path
    $created = @()
    foreach ($td in @($manifest.tasks)) {
        if ($td -and $td['name']) {
            $created += (New-WorkflowTask -Run $run -TaskDef $td)
        }
    }
    Push-Location $layout.project_root
    try {
        $launch = Start-ProcessLaunch -Type 'task-runner' -Continue $true -Description "Workflow: $wfName" -WorkflowName $wfName -RunId $run.run_id
    } finally {
        Pop-Location
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body @{
        success = $true
        workflow = $wfName
        run_id = $run.run_id
        tasks_created = $created.Count
        slots_launched = $launch.slots_launched
        process_id = $launch.process_id
    }
}

function Invoke-DashboardWorkflowStopHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $wfName = $RouteParams['name']
    $stopped = 0
    $processesDir = Join-Path $BotRoot (Join-Path '.control' 'processes')
    if (Test-Path -LiteralPath $processesDir) {
        foreach ($pf in Get-ChildItem -LiteralPath $processesDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            try {
                $proc = Get-Content -LiteralPath $pf.FullName -Raw | ConvertFrom-Json
                if ($proc.status -in @('running','starting') -and $proc.type -eq 'task-runner' -and "$($proc.description)" -like "*$wfName*") {
                    'stop' | Set-Content -LiteralPath (Join-Path $processesDir "$($proc.id).stop") -Encoding UTF8
                    $stopped++
                }
            } catch { continue }
        }
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body @{ success = $true; stopped = $stopped }
}

function Invoke-DashboardRunPendingHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    $layout = _Ensure-DashboardModules -BotRoot $BotRoot
    Push-Location $layout.project_root
    try {
        $result = Start-ProcessLaunch -Type 'task-runner' -Continue $true -Description 'Pending tasks (unfiltered)'
    } finally {
        Pop-Location
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body $result
}

function Invoke-DashboardStopPendingHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $processesDir = Join-Path $BotRoot (Join-Path '.control' 'processes')
    $stopped = 0
    if (Test-Path -LiteralPath $processesDir) {
        foreach ($pf in Get-ChildItem -LiteralPath $processesDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            try {
                $proc = Get-Content -LiteralPath $pf.FullName -Raw | ConvertFrom-Json
                if ($proc.status -in @('running','starting') -and $proc.type -eq 'task-runner' -and "$($proc.description)" -like 'Pending tasks*') {
                    'stop' | Set-Content -LiteralPath (Join-Path $processesDir "$($proc.id).stop") -Encoding UTF8
                    $stopped++
                }
            } catch { continue }
        }
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body @{ success = $true; stopped = $stopped }
}

function Invoke-DashboardControlHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $action = if ($Body -and $Body.PSObject.Properties['action']) { [string]$Body.action } else { '' }
    $mode = if ($Body -and $Body.PSObject.Properties['mode']) { [string]$Body.mode } else { 'execution' }
    _Send-JsonResponse -Response $Response -Status 200 -Body (Set-ControlSignal -Action $action -Mode $mode)
}

function Invoke-DashboardWhisperHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)
    _Ensure-DashboardModules -BotRoot $BotRoot | Out-Null
    $type = if ($Body -and $Body.PSObject.Properties['instance_type']) { [string]$Body.instance_type } else { 'task-runner' }
    $message = if ($Body -and $Body.PSObject.Properties['message']) { [string]$Body.message } else { '' }
    $priority = if ($Body -and $Body.PSObject.Properties['priority']) { [string]$Body.priority } else { 'normal' }
    _Send-JsonResponse -Response $Response -Status 200 -Body (Send-WhisperToInstance -InstanceType $type -Message $message -Priority $priority)
}

function Invoke-CreateTaskHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    if (-not $Body) {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'missing_body' -Message 'POST /tasks requires a JSON body.'
        return
    }

    # Read fields the caller can supply; New-TaskInstance defaults everything else.
    # Only pass through to the builder when the body actually supplied the field —
    # an empty array splatted into a [string[]] parameter can produce a single
    # empty-string element in PowerShell's type coercion. Letting the builder's
    # own default (@()) handle the missing case sidesteps that.
    $name = $Body.name
    if (-not $name) {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'missing_field' -Message 'name is required.'
        return
    }

    $actor = if ($Body.PSObject.Properties['actor']) { [string]$Body.actor } else { 'system' }

    $params = @{
        Name      = $name
        UpdatedBy = $actor
    }
    if ($Body.PSObject.Properties['description']) { $params['Description'] = [string]$Body.description }
    if ($Body.PSObject.Properties['type'])        { $params['Type']        = [string]$Body.type }
    if ($Body.PSObject.Properties['status'])      { $params['Status']      = [string]$Body.status }
    if ($Body.PSObject.Properties['category'])    { $params['Category']    = [string]$Body.category }
    if ($Body.PSObject.Properties['priority'])    { $params['Priority']    = $Body.priority }
    if ($Body.PSObject.Properties['effort'])      { $params['Effort']      = [string]$Body.effort }
    if ($Body.PSObject.Properties['dependencies']) {
        $vals = @($Body.dependencies | Where-Object { $_ -and $_ -ne '' })
        if ($vals.Count -gt 0) { $params['Dependencies'] = [string[]]$vals }
    }
    if ($Body.PSObject.Properties['acceptance_criteria']) {
        $vals = @($Body.acceptance_criteria | Where-Object { $_ -and $_ -ne '' })
        if ($vals.Count -gt 0) { $params['AcceptanceCriteria'] = [string[]]$vals }
    }
    if ($Body.PSObject.Properties['outputs']) {
        $vals = @($Body.outputs | Where-Object { $_ -and $_ -ne '' })
        if ($vals.Count -gt 0) { $params['Outputs'] = [string[]]$vals }
    }
    if ($Body.PSObject.Properties['provenance']) {
        # Convert PSCustomObject → hashtable for the builder.
        $bag = @{}
        foreach ($p in $Body.provenance.PSObject.Properties) { $bag[$p.Name] = $p.Value }
        $params['Provenance'] = $bag
    }
    if ($Body.PSObject.Properties['extensions']) {
        $bag = @{}
        foreach ($p in $Body.extensions.PSObject.Properties) { $bag[$p.Name] = $p.Value }
        $params['Extensions'] = $bag
    }

    try {
        $task = New-TaskInstance @params
        Assert-TaskInputQuestionPayload -TaskContent $task
    } catch {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'schema_error' -Message $_.Exception.Message
        return
    }

    # Resolve on-disk path.
    if ($task.provenance.run_id) {
        $bundle = _Read-RunRecord -BotRoot $BotRoot -RunId $task.provenance.run_id
        if (-not $bundle -or -not $bundle.run_dir) {
            _Send-ErrorResponse -Response $Response -Status 422 -Code 'no_such_run' -Message "Provenance run_id '$($task.provenance.run_id)' has no committed run record."
            return
        }
        $filePath = Join-Path $bundle.run_dir "$($task.id).json"
    } else {
        $layout = Get-StandaloneTaskLayout -BotRoot $BotRoot -TaskId $task.id -TaskName $task.name -CreatedAt $task.created_at
        $filePath = $layout.file_path
    }

    Lock-TaskMutex -TaskId $task.id | Out-Null
    try {
        _Write-TaskFileAtomic -Path $filePath -Content $task
        Write-ActivityEvent -BotRoot $BotRoot -Type 'task_created' -TaskId $task.id -Actor $actor
    } finally {
        Unlock-TaskMutex -TaskId $task.id
    }

    _Send-JsonResponse -Response $Response -Status 201 -Body @{
        task = $task
        path = $filePath
    }
}

function Invoke-GetTaskHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $taskId = $RouteParams['id']
    $path = _Find-TaskFileById -BotRoot $BotRoot -TaskId $taskId
    if (-not $path) {
        _Send-ErrorResponse -Response $Response -Status 404 -Code 'not_found' -Message "Task $taskId not found."
        return
    }
    $task = _Read-TaskFile -Path $path
    _Send-JsonResponse -Response $Response -Status 200 -Body @{ task = $task; path = $path }
}

function Invoke-ListTasksHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $filterStatus   = $Query['status']
    $filterRun      = $Query['run_id']
    $filterWorkflow = $Query['workflow']

    $items = @()
    $tasksRoot = _Get-TasksRoot -BotRoot $BotRoot
    if (Test-Path -LiteralPath $tasksRoot) {
        Get-ChildItem -LiteralPath $tasksRoot -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'run.json' } |
            ForEach-Object {
                try {
                    $task = _Read-TaskFile -Path $_.FullName
                    if ($filterStatus -and $task.status -ne $filterStatus) { return }
                    if ($filterRun -and $task.provenance.run_id -ne $filterRun) { return }
                    if ($filterWorkflow -and $task.provenance.workflow -ne $filterWorkflow) { return }
                    $items += $task
                } catch { return }
            }
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body @{ tasks = $items; count = $items.Count }
}

function Invoke-PatchTaskHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $taskId = $RouteParams['id']
    if (-not $Body) {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'missing_body' -Message 'PATCH /tasks/<id> requires a JSON body.'
        return
    }
    $actor = if ($Body.PSObject.Properties['actor']) { [string]$Body.actor } else { 'system' }

    Lock-TaskMutex -TaskId $taskId | Out-Null
    try {
        $path = _Find-TaskFileById -BotRoot $BotRoot -TaskId $taskId
        if (-not $path) {
            _Send-ErrorResponse -Response $Response -Status 404 -Code 'not_found' -Message "Task $taskId not found."
            return
        }
        $task = _Read-TaskFile -Path $path

        # PATCH updates non-status fields. Status changes go through
        # POST /tasks/<id>/status so the transition table is enforced.
        $forbidden = @('id', 'status', 'schema_version', 'created_at', 'completed_at')
        # Single-string values for list-shaped fields are coerced to a
        # one-element array so the schema assert downstream accepts them.
        $listFields = @('dependencies', 'acceptance_criteria', 'outputs')
        foreach ($prop in $Body.PSObject.Properties) {
            if ($prop.Name -in @('actor')) { continue }
            if ($prop.Name -in $forbidden) {
                _Send-ErrorResponse -Response $Response -Status 400 -Code 'patch_forbidden_field' -Message "Cannot PATCH '$($prop.Name)' (use the dedicated endpoint or recreate the task)."
                return
            }
            if ($prop.Name -in $listFields -and $prop.Value -is [string]) {
                $prop.Value = @($prop.Value)
            }
            # Extensions deep-merge recursively so a partial PATCH such as
            # extensions.runner.pending_questions preserves sibling runner
            # fields and other namespaces. Other top-level fields use replace
            # semantics.
            if ($prop.Name -eq 'extensions') {
                $task['extensions'] = _Merge-JsonObject -Current $task['extensions'] -Incoming $prop.Value
            } else {
                $task[$prop.Name] = _Convert-JsonObjectLike -Value $prop.Value
            }
        }
        $task['updated_at'] = _Now-Utc
        $task['updated_by'] = $actor

        try {
            Assert-TaskInstance -Task $task
            Assert-TaskInputQuestionPayload -TaskContent $task
        } catch {
            _Send-ErrorResponse -Response $Response -Status 400 -Code 'schema_error' -Message $_.Exception.Message
            return
        }

        _Write-TaskFileAtomic -Path $path -Content $task
        Write-ActivityEvent -BotRoot $BotRoot -Type 'task_updated' -TaskId $task.id -Actor $actor
    } finally {
        Unlock-TaskMutex -TaskId $taskId
    }

    _Send-JsonResponse -Response $Response -Status 200 -Body @{ task = $task }
}

function Invoke-TaskStatusHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $taskId = $RouteParams['id']
    if (-not $Body -or -not $Body.PSObject.Properties['to']) {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'missing_field' -Message 'Body must include { to: <new-status> }.'
        return
    }
    $to     = [string]$Body.to
    $actor  = if ($Body.PSObject.Properties['actor'])  { [string]$Body.actor }  else { 'system' }
    $reason = if ($Body.PSObject.Properties['reason']) { [string]$Body.reason } else { $null }

    Lock-TaskMutex -TaskId $taskId | Out-Null
    try {
        $path = _Find-TaskFileById -BotRoot $BotRoot -TaskId $taskId
        if (-not $path) {
            _Send-ErrorResponse -Response $Response -Status 404 -Code 'not_found' -Message "Task $taskId not found."
            return
        }
        $task = _Read-TaskFile -Path $path
        $from = [string]$task.status

        # Idempotent no-op: setting a task's status to its current value is not
        # a transition. The transition table only lists real edges, so calling
        # Assert-TaskTransition on a self-edge would throw 'illegal_transition'
        # for what the caller (e.g. a retried task_set_status MCP call after a
        # network blip) reasonably expects to be a success. Short-circuit before
        # touching the file or dispatching hooks.
        if ($from -eq $to) {
            _Send-JsonResponse -Response $Response -Status 200 -Body @{
                task         = $task
                hook_results = @()
                no_op        = $true
            }
            return
        }

        try {
            Assert-TaskTransition -From $from -To $to
        } catch {
            _Send-ErrorResponse -Response $Response -Status 422 -Code 'illegal_transition' -Message $_.Exception.Message -Extra @{ from = $from; to = $to }
            return
        }

        $task['status']     = $to
        $task['updated_at'] = _Now-Utc
        $task['updated_by'] = $actor
        $terminal = @('done','failed','skipped','cancelled')
        if ($terminal -contains $to) {
            $task['completed_at'] = $task['updated_at']
        } elseif ($terminal -notcontains $from -and $terminal -notcontains $to) {
            # non-terminal → non-terminal: keep completed_at null
            $task['completed_at'] = $null
        } else {
            # terminal → non-terminal (e.g. done → todo reopen): clear completed_at
            $task['completed_at'] = $null
        }

        if ($to -eq 'skipped') {
            $skipReason = if ($Body.PSObject.Properties['skip_reason']) { [string]$Body.skip_reason } else { $null }
            $skipDetail = if ($Body.PSObject.Properties['skip_detail']) { [string]$Body.skip_detail } else { $null }
            if (-not $skipReason -and $reason) {
                $parts = [string]$reason -split ':', 2
                $skipReason = $parts[0].Trim()
                if (-not $skipDetail -and $parts.Count -gt 1) { $skipDetail = $parts[1].Trim() }
            }
            if ($skipReason) {
                if (-not $task.ContainsKey('extensions') -or -not $task['extensions']) { $task['extensions'] = @{} }
                if (-not $task['extensions'].ContainsKey('runner') -or -not $task['extensions']['runner']) {
                    $task['extensions']['runner'] = @{}
                }
                $task['extensions']['runner']['skip_reason'] = $skipReason
                if ($skipDetail) { $task['extensions']['runner']['skip_detail'] = $skipDetail }
            }
        }

        if ($to -eq 'needs-input') {
            try {
                New-DotbotTaskHandoff -TaskContent $task -BotRoot $BotRoot -Reason 'human-input' | Out-Null
            } catch {
                _Send-ErrorResponse -Response $Response -Status 500 -Code 'handoff_create_failed' -Message $_.Exception.Message
                return
            }
        }

        # A transition that is about to proceed resolves any prior hook-blocked-done
        # breadcrumb (set on the abort-revert path below). Clearing it here means a
        # stale marker never lingers once the task makes forward progress.
        if ($task['extensions'] -and ($task['extensions']['runner'] -is [System.Collections.IDictionary]) -and
            $task['extensions']['runner'].ContainsKey('done_transition_block')) {
            [void]$task['extensions']['runner'].Remove('done_transition_block')
        }

        try {
            Assert-TaskInstance -Task $task
        } catch {
            _Send-ErrorResponse -Response $Response -Status 400 -Code 'schema_error' -Message $_.Exception.Message
            return
        }

        # Write the new status FIRST so hooks observe a consistent on-disk
        # view.
        _Write-TaskFileAtomic -Path $path -Content $task
        Write-ActivityEvent -BotRoot $BotRoot -Type 'task_status_changed' -TaskId $task.id -From $from -To $to -Actor $actor -Reason $reason

        # Transition-hook dispatch. Hooks run synchronously, inline with
        # this handler, inside the task mutex. A failing hook with
        # abort_on_failure: true reverts the transition.
        $hookResult = $null
        $hookError = $null
        try {
            $runContext = @{
                BotRoot  = $BotRoot
                Actor    = $actor
            }
            if ($task.provenance -and $task.provenance.run_id) {
                $bundle = _Read-RunRecord -BotRoot $BotRoot -RunId $task.provenance.run_id
                if ($bundle -and $bundle.record) {
                    $runContext['workflow_run'] = $bundle.record
                }
            }
            $hookResult = Invoke-TransitionHooks `
                -BotRoot     $BotRoot `
                -ToStatus    $to `
                -FromStatus  $from `
                -Task        $task `
                -RunContext  $runContext
        } catch {
            # Hook dispatch itself crashed (not the hook returning failure).
            # Treat as an abort so the runtime doesn't silently leave the
            # task in a half-applied state with no audit trail.
            $hookError = $_.Exception.Message
        }

        if ($hookResult -and $hookResult.aborted) {
            # Revert: write the old status back, clear completed_at, restamp.
            $task['status']     = $from
            $task['updated_at'] = _Now-Utc
            $task['updated_by'] = $actor
            $terminal = @('done','failed','skipped','cancelled')
            if ($terminal -contains $from) {
                # The previous status was already terminal; preserve it.
                # We can't recover the original completed_at without re-reading
                # the file, but Assert-TaskInstance accepts any RFC3339-Z value.
                $task['completed_at'] = $task['updated_at']
            } else {
                $task['completed_at'] = $null
            }
            # Breadcrumb the task-runner reads to escalate a hook-blocked done to
            # needs-input instead of skipped(max-retries). Under extensions.runner
            # (schema rejects unknown top-level fields); cleared on next success.
            if ($to -eq 'done') {
                if (-not $task['extensions'])           { $task['extensions'] = @{} }
                if (-not $task['extensions']['runner']) { $task['extensions']['runner'] = @{} }
                $task['extensions']['runner']['done_transition_block'] = @{
                    hook    = [string]$hookResult.failing_hook
                    message = [string]$hookResult.failing_message
                    at      = $task['updated_at']
                }
            }
            _Write-TaskFileAtomic -Path $path -Content $task

            Write-ActivityEvent `
                -BotRoot $BotRoot `
                -Type    'hook_failed' `
                -TaskId  $task.id `
                -From    $to `
                -To      $from `
                -Actor   $actor `
                -Reason  ("hook '$($hookResult.failing_hook)' failed: $($hookResult.failing_message)")

            _Send-ErrorResponse `
                -Response $Response `
                -Status   422 `
                -Code     'hook_aborted' `
                -Message  "Hook '$($hookResult.failing_hook)' aborted the transition: $($hookResult.failing_message)" `
                -Extra    @{
                    failing_hook    = $hookResult.failing_hook
                    failing_message = $hookResult.failing_message
                    from            = $from
                    attempted_to    = $to
                    reverted_to     = $from
                    hook_results    = $hookResult.hook_results
                }
            return
        }

        if ($hookError) {
            # Hook dispatch itself crashed. Treat like an abort so the
            # response is honest about the half-finished state.
            Write-ActivityEvent `
                -BotRoot $BotRoot `
                -Type    'hook_failed' `
                -TaskId  $task.id `
                -To      $to `
                -Actor   $actor `
                -Reason  "hook dispatch error: $hookError"
            _Send-ErrorResponse `
                -Response $Response `
                -Status   500 `
                -Code     'hook_dispatch_error' `
                -Message  $hookError
            return
        }
    } finally {
        Unlock-TaskMutex -TaskId $taskId
    }

    _Send-JsonResponse -Response $Response -Status 200 -Body @{
        task         = $task
        hook_results = if ($hookResult) { $hookResult.hook_results } else { @() }
    }
}

function Invoke-GetNextTaskHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    # Simple selection: any task in the requested status, defaulting to 'todo',
    # with all dependencies in terminal status 'done'. Ordered by priority then created_at.
    $wanted = if ($Query['status']) { [string]$Query['status'] } else { 'todo' }
    $filterRun = $Query['run_id']

    if ($wanted -eq 'todo' -and (Get-Command Get-NextWorkflowTask -ErrorAction SilentlyContinue)) {
        $selection = Get-NextWorkflowTask -BotRoot $BotRoot -RunId $filterRun
        if (-not $selection.success) {
            _Send-ErrorResponse -Response $Response -Status 500 -Code 'task_selection_failed' -Message $selection.message
            return
        }
        _Send-JsonResponse -Response $Response -Status 200 -Body @{
            task    = $selection.task
            message = $selection.message
        }
        return
    }

    $candidates = @()
    $tasksRoot = _Get-TasksRoot -BotRoot $BotRoot
    if (Test-Path -LiteralPath $tasksRoot) {
        Get-ChildItem -LiteralPath $tasksRoot -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'run.json' } |
            ForEach-Object {
                try {
                    $t = _Read-TaskFile -Path $_.FullName
                    if ($t.status -ne $wanted) { return }
                    if ($filterRun -and $t.provenance.run_id -ne $filterRun) { return }
                    $candidates += $t
                } catch { return }
            }
    }
    if ($candidates.Count -eq 0) {
        _Send-JsonResponse -Response $Response -Status 200 -Body @{ task = $null }
        return
    }
    # Order: priority desc when priority is an int, then created_at asc.
    $next = $candidates | Sort-Object @(
        @{ Expression = { if ($_.priority -is [int] -or $_.priority -is [long]) { -[int]$_.priority } else { 0 } }; Ascending = $true }
        @{ Expression = 'created_at'; Ascending = $true }
    ) | Select-Object -First 1
    _Send-JsonResponse -Response $Response -Status 200 -Body @{ task = $next }
}

function Invoke-GetTaskContextHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $taskId = $RouteParams['id']
    $path = _Find-TaskFileById -BotRoot $BotRoot -TaskId $taskId
    if (-not $path) {
        _Send-ErrorResponse -Response $Response -Status 404 -Code 'not_found' -Message "Task $taskId not found."
        return
    }
    $task = _Read-TaskFile -Path $path

    $runner = $null
    $analysis = $null
    if ($task.ContainsKey('extensions') -and $task['extensions']) {
        $extensions = $task['extensions']
        if ($extensions -is [System.Collections.IDictionary]) {
            if ($extensions.Contains('runner')) { $runner = $extensions['runner'] }
            if ($extensions.Contains('analysis')) { $analysis = $extensions['analysis'] }
        }
    }

    $resumeContext = $null
    try {
        $resumeContext = Get-DotbotTaskResumeContext -TaskContent $task -BotRoot $BotRoot
    } catch {
        $resumeContext = [ordered]@{ error = $_.Exception.Message }
    }

    # Explicit context envelope. Keep the task plus the same-task
    # session-attempt contract visible to agents.
    $context = [ordered]@{
        task              = $task
        task_standard     = 'single-task-session-attempts'
        session_policy    = 'single_unblocked_attempt'
        has_analysis      = ($null -ne $analysis)
        analysis          = $analysis
        active_attempt_id = if ($runner -and $runner.Contains('active_attempt_id')) { $runner['active_attempt_id'] } else { $null }
        current_handoff   = if ($runner -and $runner.Contains('current_handoff')) { $runner['current_handoff'] } else { $null }
        resume_context    = $resumeContext
    }
    if ($task.provenance.run_id) {
        $bundle = _Read-RunRecord -BotRoot $BotRoot -RunId $task.provenance.run_id
        if ($bundle -and $bundle.record) {
            $context['workflow_run'] = $bundle.record
        }
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body $context
}

# --- Workflow runs -----------------------------------------------------------

function Invoke-CreateRunHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    if (-not $Body) {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'missing_body' -Message 'POST /workflows/runs requires a JSON body.'
        return
    }
    $workflowName = if ($Body.PSObject.Properties['workflow_name']) { [string]$Body.workflow_name } else { $null }
    if (-not $workflowName) {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'missing_field' -Message 'workflow_name is required.'
        return
    }
    $startedBy = if ($Body.PSObject.Properties['actor']) { [string]$Body.actor } else { 'system' }
    $taskIds = @()
    if ($Body.PSObject.Properties['task_ids']) {
        $taskIds = @($Body.task_ids | Where-Object { $_ -and $_ -ne '' })
    }
    $taskDefs = $null
    if ($Body.PSObject.Properties['task_definitions']) {
        $taskDefs = @($Body.task_definitions | Where-Object { $_ })
        if ($taskDefs.Count -eq 0) { $taskDefs = $null }
    }

    # Git-ready precondition. Every workflow run executes in a worktree.
    $projectRoot = Split-Path -Parent $BotRoot
    $gitCheck = Test-GitReadyForWorktree -ProjectRoot $projectRoot
    if (-not $gitCheck.ok) {
        _Send-ErrorResponse -Response $Response -Status 422 -Code 'git_not_ready' -Message $gitCheck.message -Extra @{ reason = $gitCheck.reason }
        return
    }

    # concurrency rule: consult the active runs.
    $newRun = @{ workflow_name = $workflowName }
    $active = _Get-ActiveRuns -BotRoot $BotRoot
    $decision = Test-CanStartRun -NewRun $newRun -ActiveRuns $active
    if (-not $decision.ok) {
        _Send-ErrorResponse -Response $Response -Status 409 -Code $decision.reason -Message $decision.message -Extra @{ blocking_run_id = $decision.blocking_run_id }
        return
    }

    # Build committed + live status records.
    $recordParams = @{
        WorkflowName = $workflowName
        StartedBy    = $startedBy
    }
    if ($taskIds.Count -gt 0) { $recordParams['TaskIds'] = [string[]]$taskIds }
    if ($taskDefs) { $recordParams['TaskDefinitions'] = $taskDefs }

    try {
        $record = New-WorkflowRunRecord @recordParams
    } catch {
        _Send-ErrorResponse -Response $Response -Status 400 -Code 'schema_error' -Message $_.Exception.Message
        return
    }

    $runId = $record.run_id
    Lock-RunMutex -RunId $runId | Out-Null
    try {
        $status = New-WorkflowRunStatus -RunId $runId -Status 'running' -LastHeartbeat (_Now-Utc)

        $layout = Get-WorkflowRunLayout -BotRoot $BotRoot -WorkflowName $workflowName -RunId $runId -StartedAt $record.started_at

        if (-not (Test-Path -LiteralPath $layout.run_dir)) {
            New-Item -ItemType Directory -Path $layout.run_dir -Force | Out-Null
        }
        _Write-TaskFileAtomic -Path $layout.run_record_path -Content $record
        _Write-TaskFileAtomic -Path $layout.live_status_path -Content $status

        Write-ActivityEvent -BotRoot $BotRoot -Type 'workflow_run_started' -RunId $runId -Actor $startedBy
    } finally {
        Unlock-RunMutex -RunId $runId
    }

    # Executor dispatch extension point — task execution spawns from here.

    _Send-JsonResponse -Response $Response -Status 201 -Body @{
        run        = $record
        status     = $status
        run_dir    = $layout.run_dir
        record_at  = $layout.run_record_path
        status_at  = $layout.live_status_path
    }
}

function Invoke-GetRunHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $runId = $RouteParams['id']
    $bundle = _Read-RunRecord -BotRoot $BotRoot -RunId $runId
    if (-not $bundle) {
        _Send-ErrorResponse -Response $Response -Status 404 -Code 'not_found' -Message "Run $runId not found."
        return
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body @{
        run    = $bundle.record
        status = $bundle.status
    }
}

function Invoke-ListRunsHandler {
    [CmdletBinding()] param($BotRoot, $Response, $Request, $RouteParams, $Query, $Body)

    $items = @()
    $controlDir = _Get-RunsControlDir -BotRoot $BotRoot
    if (Test-Path -LiteralPath $controlDir) {
        Get-ChildItem -LiteralPath $controlDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $statusObj = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
                if (-not $statusObj.run_id) { return }
                $bundle = _Read-RunRecord -BotRoot $BotRoot -RunId $statusObj.run_id
                if (-not $bundle) { return }
                $items += [ordered]@{
                    run    = $bundle.record
                    status = $bundle.status
                }
            } catch { return }
        }
    }
    _Send-JsonResponse -Response $Response -Status 200 -Body @{ runs = $items; count = $items.Count }
}

Export-ModuleMember -Function @(
    'Start-RuntimeHttpListener'
    'Stop-RuntimeHttpListener'
    'Invoke-RuntimeRequestDispatch'
    'Invoke-HealthHandler'
    'Invoke-CreateTaskHandler'
    'Invoke-GetTaskHandler'
    'Invoke-ListTasksHandler'
    'Invoke-PatchTaskHandler'
    'Invoke-TaskStatusHandler'
    'Invoke-GetNextTaskHandler'
    'Invoke-GetTaskContextHandler'
    'Invoke-CreateRunHandler'
    'Invoke-GetRunHandler'
    'Invoke-ListRunsHandler'
    'Invoke-DashboardInfoHandler'
    'Invoke-DashboardStateHandler'
    'Invoke-DashboardActivityTailHandler'
    'Invoke-DashboardProcessesHandler'
    'Invoke-DashboardProcessOutputHandler'
    'Invoke-DashboardProcessStopHandler'
    'Invoke-DashboardProcessKillHandler'
    'Invoke-DashboardProcessWhisperHandler'
    'Invoke-DashboardWorkflowsInstalledHandler'
    'Invoke-DashboardWorkflowRunHandler'
    'Invoke-DashboardWorkflowStopHandler'
    'Invoke-DashboardRunPendingHandler'
    'Invoke-DashboardStopPendingHandler'
    'Invoke-DashboardControlHandler'
    'Invoke-DashboardWhisperHandler'
)
