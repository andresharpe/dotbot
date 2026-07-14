<#
.SYNOPSIS
Runtime lifecycle: bring the per-project HTTP runtime up, detect stale
runtime.json files, and tear the listener down cleanly.

Start-DotbotRuntime is the single entry point. It checks .control/runtime.json,
attaches when the existing PID is alive, otherwise mints a fresh token, picks
an open port, writes the connection file, and starts the HTTP listener.

The actual HTTP listener is in HttpServer.psm1; this file owns
"bring it up, register it, shut it down" — not the wire protocol.
#>

# Search the IANA dynamic/private port range (49152-65535). Starting at a
# random offset spreads parallel projects across the range so multiple
# `dotbot go` launches don't race for the same low ports. Mirrors the UI
# server's dynamic port-picking strategy in src/ui/server.ps1.
$script:DotbotRuntimePortRangeMin = 49152
$script:DotbotRuntimePortRangeMax = 65535

function New-RuntimeBearerToken {
    <#
    .SYNOPSIS
    Generate a fresh 64-hex-char bearer token (256 bits of entropy).
    #>
    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Find-AvailableRuntimePort {
    <#
    .SYNOPSIS
    Probe for an open port in the IANA dynamic/private range (49152-65535)
    suitable for a loopback HttpListener. Returns the first available port;
    throws when every port in the range is in use.

    .DESCRIPTION
    Two-phase probe (mirrors src/ui/server.ps1's Find-AvailablePort): bind a
    raw TCP socket first to fail fast on OS-level conflicts; then bind an
    HttpListener prefix because the URL ACL story on Windows can reject a
    port even when the raw socket is free.

    The PRD requires loopback-only binding ("bind to 127.0.0.1 by default")
    so the listener prefix and the listener itself BOTH bind to 127.0.0.1.

    Without an explicit -StartPort we start at a random offset in the range
    so two parallel `dotbot go` launches don't both reach for the same low
    ports.
    #>
    param(
        [int]$StartPort = 0,

        # Range bounds kept as parameters so tests can pin a tight window.
        [int]$RangeMin = $script:DotbotRuntimePortRangeMin,
        [int]$RangeMax = $script:DotbotRuntimePortRangeMax,

        # Test-only: when the caller wants the legacy behaviour of "walk
        # forward from StartPort and stop at EndPort," it can pass -EndPort.
        # Production code leaves this 0 and the function wraps the full range.
        [int]$EndPort = 0
    )

    # Back-compat: -EndPort lets a caller fix a narrow contiguous window
    # (the old runtime tests used 19000..19050 to verify the function
    # responds within a known range). When set, behave like the v1 helper.
    if ($EndPort -gt 0) {
        if ($StartPort -le 0) { $StartPort = $RangeMin }
        for ($p = $StartPort; $p -le $EndPort; $p++) {
            $tcp = $null
            try {
                $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
                $tcp.Start()
                $tcp.Stop()
            } catch { continue }
            $http = [System.Net.HttpListener]::new()
            try {
                $http.Prefixes.Add("http://127.0.0.1:$p/")
                $http.Start()
                return $p
            } catch {
                continue
            } finally {
                try { if ($http.IsListening) { $http.Stop() } } catch { $null = $_ }
                try { $http.Close() } catch { $null = $_ }
            }
        }
        throw "Find-AvailableRuntimePort: no open port available in range ${StartPort}-${EndPort}."
    }

    $rangeSize = $RangeMax - $RangeMin + 1
    if ($StartPort -lt $RangeMin -or $StartPort -gt $RangeMax) {
        $StartPort = Get-Random -Minimum $RangeMin -Maximum ($RangeMax + 1)
    }

    for ($i = 0; $i -lt $rangeSize; $i++) {
        $p = $RangeMin + ((($StartPort - $RangeMin) + $i) % $rangeSize)

        # Phase 1: TCP socket bind probe (loopback).
        try {
            $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $tcp.Start()
            $tcp.Stop()
        } catch {
            continue
        }

        # Phase 2: HttpListener prefix probe — the runtime binds 127.0.0.1
        # only.
        $http = [System.Net.HttpListener]::new()
        try {
            $http.Prefixes.Add("http://127.0.0.1:$p/")
            $http.Start()
            return $p
        } catch {
            continue
        } finally {
            try { if ($http.IsListening) { $http.Stop() } } catch { $null = $_ }
            try { $http.Close() } catch { $null = $_ }
        }
    }

    throw "Find-AvailableRuntimePort: no open port available in dynamic range $RangeMin-$RangeMax."
}

function Test-RuntimeAlive {
    <#
    .SYNOPSIS
    Is the runtime described by .bot/.control/runtime.json actually running?

    .DESCRIPTION
    Returns $true when:
      - The connection file exists and parses,
      - It carries a PID,
      - Get-Process -Id <pid> succeeds.

    Returns $false otherwise. PRD calls this "stale-PID detection" and uses
    it to decide whether dotbot go should attach or rewrite.
    #>
    param([Parameter(Mandatory)] [string]$BotRoot)

    $file = Read-RuntimeConnectionFile -BotRoot $BotRoot
    if (-not $file) { return $false }
    if (-not $file.PSObject.Properties['pid']) { return $false }
    $pidValue = $file.pid
    if (-not $pidValue) { return $false }
    try {
        Get-Process -Id $pidValue -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Start-DotbotRuntime {
    <#
    .SYNOPSIS
    Bring the runtime up for the active project, writing the connection
    file and starting the HTTP listener.

    .DESCRIPTION
    Lifecycle:
      - If <BotRoot>/.control/runtime.json exists and its PID is alive,
        attach (don't restart) and return the existing endpoint.
      - Otherwise: mint fresh token, scan for open port from 8686, start the
        listener, write runtime.json (restricted perms), return the new
        endpoint.

    Returns a hashtable: @{ url, token, pid, started_at, attached, listener }
    'attached' is $true when an already-running runtime was discovered;
    $false when this call actually started it. 'listener' is the
    HttpListener instance (only when attached=$false) so the caller can
    Stop-DotbotRuntime cleanly.

    .PARAMETER Foreground
    When $true (default for dotbot go), block here in the listener loop until
    the listener is stopped. When $false, return as soon as the listener is
    accepting requests — the caller owns the lifetime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BotRoot,

        [switch]$Foreground,

        # Tests use this to pin a specific port and skip the scan.
        [int]$Port
    )

    # Idempotent attach path.
    if (Test-RuntimeAlive -BotRoot $BotRoot) {
        $existing = Read-RuntimeConnectionFile -BotRoot $BotRoot
        return [ordered]@{
            url        = $existing.url
            token      = $existing.token
            pid        = $existing.pid
            started_at = $existing.started_at
            attached   = $true
            listener   = $null
            control_plane = $null
            events_consumer = $null
        }
    }

    # Stale runtime.json from a crashed previous run — rewrite with fresh token.
    # Read-then-clobber is fine; we hold no concurrent reader expectation here.

    if (-not $Port) {
        $Port = Find-AvailableRuntimePort
    }
    $token     = New-RuntimeBearerToken
    $url       = "http://127.0.0.1:$Port/"
    $startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $myPid     = $PID
    $sessionId = "rt-$([guid]::NewGuid().ToString('N').Substring(0,12))"

    # Start the listener BEFORE writing runtime.json: if the listener fails to
    # come up (port stolen by a sibling process between scan and Start) we
    # don't leave a stale runtime.json pointing at nothing.
    $listener = Start-RuntimeHttpListener -BotRoot $BotRoot -Url $url -Token $token

    # Write the connection file last so a discovery race never sees a URL
    # that isn't accepting yet.
    Write-RuntimeConnectionFile `
        -BotRoot $BotRoot `
        -Url $url `
        -Token $token `
        -ProcessId $myPid `
        -StartedAt $startedAt | Out-Null

    $result = [ordered]@{
        url        = $url
        token      = $token
        pid        = $myPid
        started_at = $startedAt
        session_id = $sessionId
        attached   = $false
        listener   = $listener
        control_plane = $null
        events_consumer = $null
    }

    $runtimeRegistration = @{
        url        = $url
        token      = $token
        pid        = $myPid
        started_at = $startedAt
        session_id = $sessionId
    }
    try {
        $result.control_plane = Start-ControlPlaneRegistration -BotRoot $BotRoot -Runtime $runtimeRegistration
    } catch {
        $result.control_plane = [ordered]@{ enabled = $true; registered = $false; error = $_.Exception.Message }
    }

    # Event-bus consumer — hosted here so there is exactly one per project in
    # every mode (both `dotbot go` and `dotbot serve` launch the runtime
    # server; the UI server never hosts it). Start-EventConsumer returns $null
    # when the bus is disabled.
    try {
        $result.events_consumer = Start-EventConsumer -BotRoot $BotRoot
    } catch {
        $result.events_consumer = [ordered]@{ enabled = $true; started = $false; error = $_.Exception.Message }
    }

    if ($Foreground) {
        # The listener loop runs on a background ThreadPool job. In foreground
        # mode we block in this caller until someone signals shutdown — that
        # gives `dotbot go` its expected "stay attached" semantics. The
        # listener's own loop picks up the stop via Stop-RuntimeHttpListener
        # called by Stop-DotbotRuntime (which the caller wires to Ctrl+C / signal).
        try {
            while ($listener.IsListening) {
                Start-Sleep -Milliseconds 250
            }
        } finally {
            Stop-DotbotRuntime -BotRoot $BotRoot -Listener $listener -ControlPlaneRegistration $result.control_plane -EventConsumer $result.events_consumer -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function Stop-DotbotRuntime {
    <#
    .SYNOPSIS
    Stop the HTTP listener and remove .bot/.control/runtime.json.

    .DESCRIPTION
    Safe to call from a signal handler / Ctrl+C trap. Idempotent —
    a second call after shutdown is a no-op. The connection file is
    removed entirely (PRD says "remove (or mark pid:null)" — remove is
    simpler and the file should not exist when the runtime isn't running).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [System.Net.HttpListener]$Listener,
        [object]$ControlPlaneRegistration,
        [object]$EventConsumer
    )

    if ($Listener) {
        try { Stop-RuntimeHttpListener -Listener $Listener } catch {
            # Listener stop after an already-failed start is harmless; we still
            # remove runtime.json below. Swallow per CLAUDE.md output hygiene.
            $null = $_
        }
    }

    if ($ControlPlaneRegistration) {
        try { Stop-ControlPlaneRegistration -BotRoot $BotRoot -Registration $ControlPlaneRegistration } catch { $null = $_ }
    }

    if ($EventConsumer) {
        try { Stop-EventConsumer -Consumer $EventConsumer } catch { $null = $_ }
    }

    Remove-RuntimeConnectionFile -BotRoot $BotRoot
    Clear-RuntimeMutexPool
}

Export-ModuleMember -Function @(
    'Start-DotbotRuntime'
    'Stop-DotbotRuntime'
    'Test-RuntimeAlive'
    'New-RuntimeBearerToken'
    'Find-AvailableRuntimePort'
)
