<#
.SYNOPSIS
Aether (Hue bridge) discovery and configuration API module

.DESCRIPTION
Provides SSDP/mDNS bridge discovery and aether config CRUD.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    ControlDir = $null
    LastConduit = $null
    LastConduitTime = $null
}

function Initialize-AetherAPI {
    param(
        [Parameter(Mandatory)] [string]$ControlDir
    )
    $script:Config.ControlDir = $ControlDir
}

function Find-Conduit {
    $controlDir = $script:Config.ControlDir

    # Check in-memory cache first (avoids re-scanning within 5 minutes)
    if ($script:Config.LastConduit -and $script:Config.LastConduitTime) {
        $age = (Get-Date) - $script:Config.LastConduitTime
        if ($age.TotalMinutes -lt 5) {
            return $script:Config.LastConduit
        }
    }

    # Method 0: Try last known IP from cached config (fastest)
    $configFile = Join-Path $controlDir "aether-config.json"
    if (Test-Path $configFile) {
        try {
            $cachedConfig = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($cachedConfig.conduit) {
                $response = Invoke-RestMethod -Uri "https://$($cachedConfig.conduit)/api/config" -TimeoutSec 2 -SkipCertificateCheck -ErrorAction Stop
                if ($response.bridgeid) {
                    $result = @{ IP = $cachedConfig.conduit; Id = $response.bridgeid }
                    $script:Config.LastConduit = $result
                    $script:Config.LastConduitTime = Get-Date
                    return $result
                }
            }
        } catch {
            # Cached IP no longer valid, continue with discovery
        }
    }

    # Method 1: Try Philips discovery endpoint (meethue.com)
    try {
        $discoveryResponse = Invoke-RestMethod -Uri "https://discovery.meethue.com/" -TimeoutSec 5 -ErrorAction Stop
        if ($discoveryResponse -and $discoveryResponse.Count -gt 0) {
            $result = @{ IP = $discoveryResponse[0].internalipaddress; Id = $discoveryResponse[0].id }
            $script:Config.LastConduit = $result
            $script:Config.LastConduitTime = Get-Date
            return $result
        }
    } catch {
        # Discovery endpoint failed, try SSDP
    }

    # Method 2: SSDP multicast discovery
    try {
        $ssdpMessage = @"
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: urn:schemas-upnp-org:device:basic:1

"@
        $udpClient = New-Object System.Net.Sockets.UdpClient
        $udpClient.Client.ReceiveTimeout = 3000
        $udpClient.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)

        $groupEndpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse("239.255.255.250")), 1900
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($ssdpMessage)
        $udpClient.Send($bytes, $bytes.Length, $groupEndpoint) | Out-Null

        $remoteEndpoint = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0

        # Collect responses for up to 3 seconds
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            try {
                $receiveBytes = $udpClient.Receive([ref]$remoteEndpoint)
                $response = [System.Text.Encoding]::ASCII.GetString($receiveBytes)

                # Look for bridge identifier in response
                if ($response -match "IpBridge|hue-bridgeid") {
                    $ip = $remoteEndpoint.Address.ToString()

                    # Extract bridge ID from response if available
                    $bridgeId = ""
                    if ($response -match "hue-bridgeid:\s*([A-F0-9]+)") {
                        $bridgeId = $matches[1]
                    }

                    $udpClient.Close()
                    $result = @{ IP = $ip; Id = $bridgeId }
                    $script:Config.LastConduit = $result
                    $script:Config.LastConduitTime = Get-Date
                    return $result
                }
            } catch [System.Net.Sockets.SocketException] {
                # Timeout - no more responses
                break
            }
        }

        $udpClient.Close()
    } catch {
        # SSDP failed
    }

    # Method 3: Subnet scan on port 443 — new bridges disable SSDP
    try {
        # Use a UDP socket to let the OS pick the outbound interface — works cross-platform,
        # avoids Docker/VPN/loopback, and requires no actual network traffic.
        $localIp = $null
        $udpSocket = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp
        )
        try {
            $udpSocket.Connect('8.8.8.8', 80)
            $localIp = ($udpSocket.LocalEndPoint -as [System.Net.IPEndPoint]).Address.ToString()
        } catch {
            # No default route — fall back to interface enumeration below.
        } finally {
            $udpSocket.Dispose()
        }

        if (-not $localIp) {
            $localIp = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
                ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
                Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                Select-Object -First 1 -ExpandProperty Address |
                ForEach-Object { $_.ToString() }
        }

        if ($localIp -match "(\d+\.\d+\.\d+)\.\d+") {
            $subnet = $matches[1]
            $tasks = @{}
            1..254 | ForEach-Object {
                $ip = "$subnet.$_"
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tasks[$ip] = @{ Task = $tcp.ConnectAsync($ip, 443); Client = $tcp }
            }
            Start-Sleep -Seconds 2
            foreach ($kv in $tasks.GetEnumerator()) {
                $connected = $kv.Value.Task.Status -eq "RanToCompletion"
                try { $kv.Value.Client.Dispose() } catch { Write-BotLog -Level Warn -Message "Task operation failed" -Exception $_ }
                if ($connected) {
                    try {
                        $response = Invoke-RestMethod -Uri "https://$($kv.Key)/api/config" -SkipCertificateCheck -TimeoutSec 2 -ErrorAction Stop
                        if ($response.bridgeid) {
                            $result = @{ IP = $kv.Key; Id = $response.bridgeid }
                            $script:Config.LastConduit = $result
                            $script:Config.LastConduitTime = Get-Date
                            return $result
                        }
                    } catch {
                        # Not a Hue bridge
                    }
                }
            }
        }
    } catch {
        # Subnet scan failed
    }

    return $null
}

function Get-AetherScanResult {
    $conduit = Find-Conduit
    if ($conduit) {
        return @{
            found = $true
            conduit = $conduit.IP
            id = $conduit.Id
        }
    } else {
        return @{
            found = $false
            conduit = $null
            id = $null
        }
    }
}

function Get-AetherConfig {
    $configFile = Join-Path $script:Config.ControlDir "aether-config.json"

    if (Test-Path $configFile) {
        try {
            return Get-Content $configFile -Raw | ConvertFrom-Json
        } catch {
            return @{ linked = $false }
        }
    } else {
        return @{ linked = $false }
    }
}

function Set-AetherConfig {
    param(
        [Parameter(Mandatory)] [string]$Body
    )
    $controlDir = $script:Config.ControlDir
    $configFile = Join-Path $controlDir "aether-config.json"

    $config = $Body | ConvertFrom-Json
    $config | ConvertTo-Json -Depth 5 | Set-Content $configFile -Force

    # Log bond result with details
    if ($config.linked) {
        $nodeCount = if ($config.nodes) { $config.nodes.Count } else { 0 }
        Write-Status "Aether bonded to $($config.conduit) with $nodeCount node(s)" -Type Success
    } else {
        Write-Status "Aether unlinked" -Type Warn
    }

    return @{
        success = $true
        config = $config
    }
}

function Invoke-ConduitBond {
    param(
        [Parameter(Mandatory)] [string]$IP
    )
    try {
        $body = @{ devicetype = "dotbot#aether" } | ConvertTo-Json -Compress
        $response = Invoke-RestMethod -Uri "https://$IP/api" -Method Post -Body $body -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 5 -ErrorAction Stop
        if ($response -is [array] -and $response[0].success) {
            return @{ success = $true; username = $response[0].success.username }
        }
        # Button not pressed yet or other error
        $errorType = if ($response -is [array] -and $response[0].error) { $response[0].error.type } else { "unknown" }
        $errorDesc = if ($response -is [array] -and $response[0].error) { $response[0].error.description } else { "Unknown error" }
        return @{ success = $false; error = $errorType; description = $errorDesc }
    } catch {
        return @{ success = $false; error = "connection"; description = $_.Exception.Message }
    }
}

function Get-ConduitNodes {
    param(
        [Parameter(Mandatory)] [string]$IP,
        [Parameter(Mandatory)] [string]$Token
    )
    try {
        $response = Invoke-RestMethod -Uri "https://$IP/api/$Token/lights" -SkipCertificateCheck -TimeoutSec 5 -ErrorAction Stop
        $nodes = @()
        foreach ($prop in $response.PSObject.Properties) {
            $light = $prop.Value
            $nodes += @{
                id = $prop.Name
                name = $light.name
                type = $light.type
                reachable = $light.state.reachable
            }
        }
        return @{ success = $true; nodes = $nodes }
    } catch {
        return @{ success = $false; nodes = @(); error = $_.Exception.Message }
    }
}

function Test-ConduitLink {
    param(
        [Parameter(Mandatory)] [string]$IP,
        [Parameter(Mandatory)] [string]$Token
    )
    try {
        $null = Invoke-RestMethod -Uri "https://$IP/api/$Token/lights" -SkipCertificateCheck -TimeoutSec 3 -ErrorAction Stop
        return @{ valid = $true }
    } catch {
        return @{ valid = $false }
    }
}

function Invoke-ConduitCommand {
    param(
        [Parameter(Mandatory)] [string]$IP,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [array]$Nodes,
        [Parameter(Mandatory)] [string]$State
    )
    $results = @()
    foreach ($nodeId in $Nodes) {
        try {
            $response = Invoke-RestMethod -Uri "https://$IP/api/$Token/lights/$nodeId/state" -Method Put -Body $State -ContentType "application/json" -SkipCertificateCheck -TimeoutSec 3 -ErrorAction Stop
            $results += @{ nodeId = $nodeId; success = $true }
        } catch {
            $results += @{ nodeId = $nodeId; success = $false; error = $_.Exception.Message }
        }
    }
    return @{ success = $true; results = $results }
}

Export-ModuleMember -Function @('Initialize-AetherAPI', 'Find-Conduit', 'Get-AetherScanResult', 'Get-AetherConfig', 'Set-AetherConfig', 'Invoke-ConduitBond', 'Get-ConduitNodes', 'Test-ConduitLink', 'Invoke-ConduitCommand')
