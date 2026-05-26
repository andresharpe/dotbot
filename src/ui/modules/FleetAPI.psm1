<#
.SYNOPSIS
Control-plane registry and proxy for registered dotbot runtimes.

.DESCRIPTION
Runtimes register themselves with this UI server. The dashboard can list them
and proxy selected project operations to their runtime HTTP APIs. If the
registered URL is not reachable from the mothership, proxy requests fall back
to an outbound command queue picked up by the runtime heartbeat loop.
#>

$script:Config = @{
    ControlDir = $null
    BotRoot = $null
}

if (-not (Get-Module Dotbot.Settings)) {
    Import-Module (Join-Path $PSScriptRoot "..\..\runtime\Modules\Dotbot.Settings\Dotbot.Settings.psd1") -DisableNameChecking -Global
}

function Initialize-FleetAPI {
    param(
        [Parameter(Mandatory)] [string]$ControlDir,
        [Parameter(Mandatory)] [string]$BotRoot
    )

    $script:Config.ControlDir = $ControlDir
    $script:Config.BotRoot = $BotRoot
    foreach ($dir in @((Get-FleetRuntimeDir), (Get-FleetCommandRoot))) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Get-FleetRuntimeDir {
    return Join-Path $script:Config.ControlDir (Join-Path 'fleet' 'runtimes')
}

function Get-FleetCommandRoot {
    return Join-Path $script:Config.ControlDir (Join-Path 'fleet' 'commands')
}

function Test-FleetControlPlaneAuth {
    param($Request)

    $expected = ''
    try {
        $settings = Get-MergedSettings -BotRoot $script:Config.BotRoot
        if ($settings.PSObject.Properties['control_plane'] -and $settings.control_plane.PSObject.Properties['api_key']) {
            $expected = [string]$settings.control_plane.api_key
        }
    } catch { $expected = '' }
    if (-not $expected) { return $true }
    return ([string]$Request.Headers['X-Dotbot-Mothership-Key'] -eq $expected)
}

function Get-FleetRuntimePath {
    param([Parameter(Mandatory)] [string]$RuntimeId)
    $safe = $RuntimeId -replace '[^A-Za-z0-9_.-]', '_'
    return Join-Path (Get-FleetRuntimeDir) "$safe.json"
}

function Get-FleetCommandDir {
    param([Parameter(Mandatory)] [string]$RuntimeId)
    $safe = $RuntimeId -replace '[^A-Za-z0-9_.-]', '_'
    return Join-Path (Get-FleetCommandRoot) $safe
}

function Read-FleetJson {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } catch { return $null }
}

function Write-FleetJson {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Value
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Register-FleetRuntime {
    param([Parameter(Mandatory)] [object]$Body)

    $runtimeId = if ($Body.PSObject.Properties['runtime_id']) { [string]$Body.runtime_id } else { '' }
    if (-not $runtimeId) {
        return @{ _statusCode = 400; success = $false; error = 'runtime_id is required' }
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $record = [ordered]@{
        runtime_id         = $runtimeId
        runtime_session_id = if ($Body.PSObject.Properties['runtime_session_id']) { [string]$Body.runtime_session_id } else { '' }
        project_name       = if ($Body.PSObject.Properties['project_name']) { [string]$Body.project_name } else { '' }
        project_root       = if ($Body.PSObject.Properties['project_root']) { [string]$Body.project_root } else { '' }
        bot_root           = if ($Body.PSObject.Properties['bot_root']) { [string]$Body.bot_root } else { '' }
        url                = if ($Body.PSObject.Properties['url']) { [string]$Body.url } else { '' }
        token              = if ($Body.PSObject.Properties['token']) { [string]$Body.token } else { '' }
        pid                = if ($Body.PSObject.Properties['pid']) { $Body.pid } else { $null }
        started_at         = if ($Body.PSObject.Properties['started_at']) { [string]$Body.started_at } else { '' }
        registered_at      = $now
        last_heartbeat     = $now
        status             = 'online'
        machine            = if ($Body.PSObject.Properties['machine']) { [string]$Body.machine } else { '' }
        user               = if ($Body.PSObject.Properties['user']) { [string]$Body.user } else { '' }
        dotbot_home        = if ($Body.PSObject.Properties['dotbot_home']) { [string]$Body.dotbot_home } else { '' }
        capabilities       = if ($Body.PSObject.Properties['capabilities']) { @($Body.capabilities) } else { @() }
    }

    Write-FleetJson -Path (Get-FleetRuntimePath -RuntimeId $runtimeId) -Value $record
    return @{ success = $true; runtime = (Get-FleetRuntimePublicRecord -Record $record) }
}

function Update-FleetRuntimeHeartbeat {
    param(
        [Parameter(Mandatory)] [string]$RuntimeId,
        [object]$Body
    )

    $path = Get-FleetRuntimePath -RuntimeId $RuntimeId
    $record = Read-FleetJson -Path $path
    if (-not $record) {
        if ($Body) { return Register-FleetRuntime -Body $Body }
        return @{ _statusCode = 404; success = $false; error = 'runtime not registered' }
    }

    $record['last_heartbeat'] = (Get-Date).ToUniversalTime().ToString('o')
    $record['status'] = 'online'
    foreach ($k in @('runtime_session_id','url','token','pid','started_at','project_name','project_root','bot_root','machine','user','dotbot_home')) {
        if ($Body -and $Body.PSObject.Properties[$k]) { $record[$k] = $Body.$k }
    }
    Write-FleetJson -Path $path -Value $record

    return @{ success = $true; commands = @(Get-PendingFleetCommands -RuntimeId $RuntimeId) }
}

function Deregister-FleetRuntime {
    param([Parameter(Mandatory)] [string]$RuntimeId)
    $path = Get-FleetRuntimePath -RuntimeId $RuntimeId
    $record = Read-FleetJson -Path $path
    if ($record) {
        $record['status'] = 'offline'
        $record['last_heartbeat'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-FleetJson -Path $path -Value $record
    }
    return @{ success = $true }
}

function Get-FleetRuntimePublicRecord {
    param([Parameter(Mandatory)] [object]$Record)

    $last = $null
    if ($Record['last_heartbeat']) {
        try { $last = [DateTime]::Parse([string]$Record['last_heartbeat']).ToUniversalTime() } catch { $last = $null }
    }
    $online = $false
    if ($last) {
        $online = (([DateTime]::UtcNow - $last).TotalSeconds -lt 30)
    }

    return [ordered]@{
        runtime_id         = $Record['runtime_id']
        runtime_session_id = $Record['runtime_session_id']
        project_name       = $Record['project_name']
        project_root       = $Record['project_root']
        bot_root           = $Record['bot_root']
        url                = $Record['url']
        pid                = $Record['pid']
        started_at         = $Record['started_at']
        registered_at      = $Record['registered_at']
        last_heartbeat     = $Record['last_heartbeat']
        status             = if ($online) { 'online' } else { 'stale' }
        machine            = $Record['machine']
        user               = $Record['user']
        dotbot_home        = $Record['dotbot_home']
        capabilities       = @($Record['capabilities'])
    }
}

function Get-FleetRuntimes {
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath (Get-FleetRuntimeDir) -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $record = Read-FleetJson -Path $file.FullName
        if ($record) { $items += (Get-FleetRuntimePublicRecord -Record $record) }
    }
    return @{ runtimes = @($items | Sort-Object project_name, machine); count = $items.Count }
}

function Convert-FleetApiPathToRuntimePath {
    param([Parameter(Mandatory)] [string]$ApiPath)

    $path = $ApiPath
    if ($path -eq '/api/info') { return '/dashboard/info' }
    if ($path -eq '/api/state') { return '/dashboard/state' }
    if ($path -eq '/api/state/poll') { return '/dashboard/state/poll' }
    if ($path -eq '/api/activity/tail') { return '/dashboard/activity/tail' }
    if ($path -eq '/api/processes') { return '/dashboard/processes' }
    if ($path -match '^/api/process/([^/]+)/output$') { return "/dashboard/processes/$($Matches[1])/output" }
    if ($path -match '^/api/process/([^/]+)/(stop|kill|whisper)$') { return "/dashboard/processes/$($Matches[1])/$($Matches[2])" }
    if ($path -eq '/api/workflows/installed') { return '/dashboard/workflows/installed' }
    if ($path -match '^/api/workflows/([^/]+)/(run|stop)$') { return "/dashboard/workflows/$($Matches[1])/$($Matches[2])" }
    if ($path -eq '/api/tasks/run-pending') { return '/dashboard/tasks/run-pending' }
    if ($path -eq '/api/tasks/stop-pending') { return '/dashboard/tasks/stop-pending' }
    if ($path -eq '/api/control') { return '/dashboard/control' }
    if ($path -eq '/api/whisper') { return '/dashboard/whisper' }
    return $null
}

function Invoke-FleetRuntimeDirect {
    param(
        [Parameter(Mandatory)] [object]$Runtime,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$RuntimePath,
        [string]$Query,
        [object]$Body
    )

    if (-not $Runtime['url'] -or -not $Runtime['token']) { throw 'runtime has no direct endpoint' }
    $uri = "$(([string]$Runtime['url']).TrimEnd('/'))$RuntimePath"
    if ($Query) { $uri = "$uri`?$Query" }
    $params = @{
        Uri = $uri
        Method = $Method
        Headers = @{ Authorization = "Bearer $($Runtime['token'])" }
        TimeoutSec = 5
        SkipHttpErrorCheck = $true
        ErrorAction = 'Stop'
    }
    if ($Method -ne 'GET' -and $null -ne $Body) {
        $params['ContentType'] = 'application/json; charset=utf-8'
        $params['Body'] = $Body | ConvertTo-Json -Depth 20
    }
    $resp = Invoke-WebRequest @params
    return @{
        status_code = [int]$resp.StatusCode
        content_type = if ($resp.Headers['Content-Type']) { [string]$resp.Headers['Content-Type'] } else { 'application/json; charset=utf-8' }
        content = [string]$resp.Content
    }
}

function New-FleetRuntimeCommand {
    param(
        [Parameter(Mandatory)] [string]$RuntimeId,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$RuntimePath,
        [object]$Body
    )

    $commandId = "cmd-$([guid]::NewGuid().ToString('N').Substring(0,12))"
    $command = [ordered]@{
        id = $commandId
        runtime_id = $RuntimeId
        method = $Method
        path = $RuntimePath
        body = $Body
        status = 'pending'
        created_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $dir = Get-FleetCommandDir -RuntimeId $RuntimeId
    Write-FleetJson -Path (Join-Path $dir "$commandId.json") -Value $command
    return $command
}

function Get-PendingFleetCommands {
    param([Parameter(Mandatory)] [string]$RuntimeId)

    $dir = Get-FleetCommandDir -RuntimeId $RuntimeId
    $commands = @()
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $cmd = Read-FleetJson -Path $file.FullName
        if (-not $cmd -or $cmd['status'] -ne 'pending') { continue }
        $cmd['status'] = 'leased'
        $cmd['leased_at'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-FleetJson -Path $file.FullName -Value $cmd
        $commands += [ordered]@{
            id = $cmd['id']
            method = $cmd['method']
            path = $cmd['path']
            body = $cmd['body']
        }
    }
    return $commands
}

function Set-FleetCommandResult {
    param(
        [Parameter(Mandatory)] [string]$RuntimeId,
        [Parameter(Mandatory)] [string]$CommandId,
        [Parameter(Mandatory)] [object]$Body
    )

    $path = Join-Path (Get-FleetCommandDir -RuntimeId $RuntimeId) "$CommandId.json"
    $cmd = Read-FleetJson -Path $path
    if (-not $cmd) { return @{ _statusCode = 404; success = $false; error = 'command not found' } }
    $cmd['status'] = 'completed'
    $cmd['completed_at'] = (Get-Date).ToUniversalTime().ToString('o')
    $cmd['result'] = $Body
    Write-FleetJson -Path $path -Value $cmd
    return @{ success = $true }
}

function Wait-FleetCommandResult {
    param(
        [Parameter(Mandatory)] [string]$RuntimeId,
        [Parameter(Mandatory)] [string]$CommandId,
        [int]$TimeoutSec = 15
    )

    $path = Join-Path (Get-FleetCommandDir -RuntimeId $RuntimeId) "$CommandId.json"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        $cmd = Read-FleetJson -Path $path
        if ($cmd -and $cmd['status'] -eq 'completed') {
            return $cmd['result']
        }
        Start-Sleep -Milliseconds 250
    }
    return $null
}

function Invoke-FleetRuntimeProxy {
    param(
        [Parameter(Mandatory)] [string]$RuntimeId,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$ApiPath,
        [string]$Query,
        [object]$Body
    )

    $runtimePath = Convert-FleetApiPathToRuntimePath -ApiPath $ApiPath
    if (-not $runtimePath) {
        return @{ status_code = 404; content_type = 'application/json; charset=utf-8'; content = (@{ success = $false; error = "No fleet proxy mapping for $ApiPath" } | ConvertTo-Json -Compress) }
    }

    $runtime = Read-FleetJson -Path (Get-FleetRuntimePath -RuntimeId $RuntimeId)
    if (-not $runtime) {
        return @{ status_code = 404; content_type = 'application/json; charset=utf-8'; content = (@{ success = $false; error = "Runtime not registered: $RuntimeId" } | ConvertTo-Json -Compress) }
    }

    try {
        return Invoke-FleetRuntimeDirect -Runtime $runtime -Method $Method -RuntimePath $runtimePath -Query $Query -Body $Body
    } catch {
        $cmd = New-FleetRuntimeCommand -RuntimeId $RuntimeId -Method $Method -RuntimePath $runtimePath -Body $Body
        $result = Wait-FleetCommandResult -RuntimeId $RuntimeId -CommandId $cmd.id -TimeoutSec 15
        if (-not $result) {
            return @{ status_code = 504; content_type = 'application/json; charset=utf-8'; content = (@{ success = $false; error = 'runtime command timed out' } | ConvertTo-Json -Compress) }
        }
        $status = if ($result.status_code) { [int]$result.status_code } else { 200 }
        $content = if ($null -ne $result.body) { $result.body | ConvertTo-Json -Depth 20 -Compress } else { [string]$result.raw }
        return @{ status_code = $status; content_type = 'application/json; charset=utf-8'; content = $content }
    }
}

Export-ModuleMember -Function @(
    'Initialize-FleetAPI',
    'Test-FleetControlPlaneAuth',
    'Register-FleetRuntime',
    'Update-FleetRuntimeHeartbeat',
    'Deregister-FleetRuntime',
    'Get-FleetRuntimes',
    'Invoke-FleetRuntimeProxy',
    'Set-FleetCommandResult',
    'Convert-FleetApiPathToRuntimePath'
)
