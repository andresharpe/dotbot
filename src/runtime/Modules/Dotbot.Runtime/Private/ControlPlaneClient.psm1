<#
.SYNOPSIS
Runtime-side mothership registration and heartbeat client.

.DESCRIPTION
When settings.control_plane.enabled is true, Start-DotbotRuntime registers this
runtime with the configured mothership URL and starts a lightweight
outbound heartbeat loop. Heartbeat responses may include queued commands; the
worker executes them against its local runtime HTTP API and posts results back.
#>

function Get-ControlPlaneSettings {
    param([Parameter(Mandatory)] [string]$BotRoot)

    $envUrl = [Environment]::GetEnvironmentVariable('DOTBOT_MOTHERSHIP_URL')
    if ($envUrl) {
        $envKey = [Environment]::GetEnvironmentVariable('DOTBOT_MOTHERSHIP_API_KEY')
        return [pscustomobject]@{
            enabled           = $true
            url               = ([string]$envUrl).TrimEnd('/')
            api_key           = if ($envKey) { [string]$envKey } else { "" }
            heartbeat_seconds = 5
        }
    }

    if (-not (Get-Command Get-MergedSettings -ErrorAction SilentlyContinue)) {
        return $null
    }

    $merged = Get-MergedSettings -BotRoot $BotRoot
    if (-not $merged -or -not $merged.PSObject.Properties['control_plane']) {
        return $null
    }

    $cp = $merged.control_plane
    if (-not $cp -or $cp.enabled -ne $true -or -not $cp.url) {
        return $null
    }

    $interval = 5
    if ($cp.PSObject.Properties['heartbeat_seconds'] -and [int]$cp.heartbeat_seconds -gt 0) {
        $interval = [Math]::Max(2, [int]$cp.heartbeat_seconds)
    }

    return [pscustomobject]@{
        enabled           = $true
        url               = ([string]$cp.url).TrimEnd('/')
        api_key           = if ($cp.PSObject.Properties['api_key']) { [string]$cp.api_key } else { "" }
        heartbeat_seconds = $interval
    }
}

function Get-RuntimeRegistrationPayload {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [hashtable]$Runtime
    )

    $projectRoot = Split-Path -Parent $BotRoot
    $settingsPath = Join-Path $BotRoot (Join-Path '.control' 'settings.json')
    $instanceId = $null
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            if ($settings.PSObject.Properties['instance_id'] -and $settings.instance_id) {
                $instanceId = [string]$settings.instance_id
            }
        } catch { $null = $_ }
    }
    if (-not $instanceId -and (Get-Command Get-OrCreateWorkspaceInstanceId -ErrorAction SilentlyContinue)) {
        try { $instanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath } catch { $null = $_ }
    }
    if (-not $instanceId) {
        $instanceId = [guid]::NewGuid().ToString()
    }

    return [ordered]@{
        runtime_id         = $instanceId
        runtime_session_id = $Runtime.session_id
        project_name       = Split-Path -Leaf $projectRoot
        project_root       = $projectRoot
        bot_root           = $BotRoot
        url                = $Runtime.url
        token              = $Runtime.token
        pid                = $Runtime.pid
        started_at         = $Runtime.started_at
        machine            = [System.Environment]::MachineName
        user               = [System.Environment]::UserName
        dotbot_home        = Get-DotbotInstallPath
        capabilities       = @('dashboard-proxy', 'command-poll')
    }
}

function Invoke-ControlPlaneRequest {
    param(
        [Parameter(Mandatory)] [object]$Settings,
        [Parameter(Mandatory)] [ValidateSet('GET','POST')] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [object]$Body,
        [int]$TimeoutSec = 5
    )

    $uri = "$($Settings.url)$Path"
    $headers = @{}
    if ($Settings.api_key) {
        $headers['X-Dotbot-Mothership-Key'] = $Settings.api_key
    }
    $params = @{
        Uri        = $uri
        Method     = $Method
        Headers    = $headers
        TimeoutSec = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'POST') {
        $params['ContentType'] = 'application/json; charset=utf-8'
        $params['Body'] = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 20 }
    }
    return Invoke-RestMethod @params
}

function Invoke-ControlPlaneCommand {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [object]$Command
    )

    $method = [string]$Command.method
    $path = [string]$Command.path
    $body = $null
    if ($Command.PSObject.Properties['body']) { $body = $Command.body }

    $params = @{
        BotRoot    = $BotRoot
        Method     = $method
        Path       = $path
        TimeoutSec = 20
    }
    if ($null -ne $body -and $method -ne 'GET') {
        $params['Body'] = $body
    }

    try {
        $resp = Invoke-RuntimeRequest @params
        return [ordered]@{
            ok          = $true
            status_code = $resp.status_code
            body        = $resp.body
            raw         = $resp.raw
        }
    } catch {
        return [ordered]@{
            ok          = $false
            status_code = 500
            body        = @{ error = 'command_failed'; message = $_.Exception.Message }
            raw         = $_.Exception.Message
        }
    }
}

function Start-ControlPlaneRegistration {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [hashtable]$Runtime
    )

    $settings = Get-ControlPlaneSettings -BotRoot $BotRoot
    if (-not $settings) {
        return $null
    }

    $payload = Get-RuntimeRegistrationPayload -BotRoot $BotRoot -Runtime $Runtime
    try {
        $null = Invoke-ControlPlaneRequest -Settings $settings -Method POST -Path '/api/fleet/runtimes/register' -Body $payload
    } catch {
        return [ordered]@{ enabled = $true; registered = $false; error = $_.Exception.Message }
    }

    $stopFlag = [bool[]]::new(1)
    $modulePsd1 = Join-Path (Split-Path -Parent $PSScriptRoot) 'Dotbot.Runtime.psd1'
    $heartbeatScript = {
        param($settings, $payload, $botRoot, $stopFlag, $modulePsd1)

        Import-Module $modulePsd1 -DisableNameChecking -Force
        while (-not $stopFlag[0]) {
            try {
                $heartbeat = $payload.Clone()
                $heartbeat['last_heartbeat'] = (Get-Date).ToUniversalTime().ToString('o')
                $resp = Invoke-ControlPlaneRequest -Settings $settings -Method POST -Path "/api/fleet/runtimes/$($payload.runtime_id)/heartbeat" -Body $heartbeat -TimeoutSec 10
                foreach ($cmd in @($resp.commands)) {
                    if (-not $cmd -or -not $cmd.id) { continue }
                    $result = Invoke-ControlPlaneCommand -BotRoot $botRoot -Command $cmd
                    $result['command_id'] = [string]$cmd.id
                    $null = Invoke-ControlPlaneRequest -Settings $settings -Method POST -Path "/api/fleet/runtimes/$($payload.runtime_id)/commands/$($cmd.id)/result" -Body $result -TimeoutSec 10
                }
            } catch {
                $null = $_
            }
            $sleepMs = [Math]::Max(500, [int]$settings.heartbeat_seconds * 1000)
            $remaining = $sleepMs
            while ($remaining -gt 0 -and -not $stopFlag[0]) {
                Start-Sleep -Milliseconds ([Math]::Min(250, $remaining))
                $remaining -= 250
            }
        }
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($heartbeatScript)
    $null = $ps.AddArgument($settings)
    $null = $ps.AddArgument($payload)
    $null = $ps.AddArgument($BotRoot)
    $null = $ps.AddArgument($stopFlag)
    $null = $ps.AddArgument($modulePsd1)
    [void]$ps.BeginInvoke()

    return [ordered]@{
        enabled    = $true
        registered = $true
        runtime_id = $payload.runtime_id
        stop_flag  = $stopFlag
        ps         = $ps
        runspace   = $rs
        settings   = $settings
    }
}

function Stop-ControlPlaneRegistration {
    param(
        [string]$BotRoot,
        [object]$Registration
    )

    if (-not $Registration) { return }
    try { if ($Registration.stop_flag) { $Registration.stop_flag[0] = $true } } catch { $null = $_ }
    try {
        if ($Registration.registered -and $Registration.settings -and $Registration.runtime_id) {
            $null = Invoke-ControlPlaneRequest -Settings $Registration.settings -Method POST -Path "/api/fleet/runtimes/$($Registration.runtime_id)/deregister" -Body @{ runtime_id = $Registration.runtime_id } -TimeoutSec 3
        }
    } catch { $null = $_ }
    try { if ($Registration.ps) { $Registration.ps.Stop(); $Registration.ps.Dispose() } } catch { $null = $_ }
    try { if ($Registration.runspace) { $Registration.runspace.Close(); $Registration.runspace.Dispose() } } catch { $null = $_ }
}

Export-ModuleMember -Function @(
    'Get-ControlPlaneSettings',
    'Start-ControlPlaneRegistration',
    'Stop-ControlPlaneRegistration',
    'Invoke-ControlPlaneRequest',
    'Invoke-ControlPlaneCommand'
)
