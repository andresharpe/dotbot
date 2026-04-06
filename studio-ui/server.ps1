<#
.SYNOPSIS
Standalone HTTP server for the dotbot studio.

.DESCRIPTION
Lightweight PowerShell HTTP server using System.Net.HttpListener.
Serves the REST API via StudioAPI.psm1 and static client
files from the static/ directory.

Port selection: tries ports starting from BasePort (default 9001)
until an available one is found. Writes the chosen port to
~/dotbot/.studio-port so the CLI can discover a running studio.

.PARAMETER Port
Base port to start searching from (default: 9001)

.EXAMPLE
pwsh server.ps1
pwsh server.ps1 -Port 4000
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1024, 65535)]
    [int]$Port = 9001
)

Set-StrictMode -Version 1.0

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
$staticRoot = Join-Path $scriptDir 'static'

# Resolve workflows directory: walk up to find dotbot root, fallback ~/dotbot
function Find-DotbotRoot {
    $dir = $scriptDir
    while ($dir -ne [System.IO.Path]::GetPathRoot($dir)) {
        if ((Test-Path (Join-Path $dir 'workflows')) -and (Test-Path (Join-Path $dir 'scripts'))) {
            return $dir
        }
        $dir = Split-Path $dir -Parent
    }
    return Join-Path $HOME 'dotbot'
}

$dotbotRoot = Find-DotbotRoot
$workflowsDir = Join-Path $dotbotRoot 'workflows'

# Import the API module
Import-Module (Join-Path $scriptDir 'StudioAPI.psm1') -Force
Initialize-StudioAPI -WorkflowsDir $workflowsDir -StaticRoot $staticRoot

# ---------------------------------------------------------------------------
# Port file management (defined early so trap/cleanup can reference them)
# ---------------------------------------------------------------------------
$portFile = Join-Path $HOME 'dotbot' '.studio-port'

function Write-PortFile {
    param([int]$Port)
    $dir = Split-Path $portFile -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    @{ port = $Port; pid = $PID } | ConvertTo-Json -Compress | Set-Content -Path $portFile -Encoding UTF8 -NoNewline
}

function Remove-PortFile {
    if (Test-Path $portFile) {
        Remove-Item -Path $portFile -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Port discovery
# ---------------------------------------------------------------------------
$maxAttempts = 20

function Find-AvailablePort {
    param([int]$StartPort)
    for ($p = $StartPort; $p -lt ($StartPort + $maxAttempts); $p++) {
        $http = [System.Net.HttpListener]::new()
        try {
            $http.Prefixes.Add("http://localhost:$p/")
            $http.Start()
            # Port is available — stop the test listener and return
            $http.Stop()
            $http.Close()
            return $p
        } catch {
            try { $http.Close() } catch { }
            continue
        }
    }
    return $null
}

$selectedPort = Find-AvailablePort -StartPort $Port
if (-not $selectedPort) {
    $endPort = $Port + $maxAttempts - 1
    Write-Host ""
    Write-Host "  Could not find an available port to start the studio-ui server." -ForegroundColor Red
    Write-Host "  Tried ports ${Port}-${endPort}, all are in use or blocked." -ForegroundColor Red
    Write-Host "  Try specifying a different port: pwsh server.ps1 -Port 9100" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# ---------------------------------------------------------------------------
# Start server
# ---------------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$selectedPort/")

try {
    $listener.Start()
} catch {
    Write-Host "Failed to start listener on port $selectedPort : $_" -ForegroundColor Red
    exit 1
}

Write-PortFile -Port $selectedPort
$url = "http://localhost:$selectedPort"
Write-Host "dotbot studio running at $url" -ForegroundColor Green

# Auto-open browser (skip if DEV_MODE env is set — Vite handles the UI in dev)
if (-not $env:DEV_MODE) {
    try {
        Start-Process $url
    } catch {
        Write-Host "Open $url in your browser" -ForegroundColor Yellow
    }
}

# Cleanup on exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-PortFile }
trap {
    Remove-PortFile
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}

# ---------------------------------------------------------------------------
# Request loop
# ---------------------------------------------------------------------------
try {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $handled = Invoke-StudioRequest -Context $context
            if (-not $handled) {
                $context.Response.StatusCode = 404
                $buffer = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Not found"}')
                $context.Response.ContentType = 'application/json'
                $context.Response.ContentLength64 = $buffer.Length
                $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
                $context.Response.Close()
            }
        } catch [System.Net.HttpListenerException] {
            # Listener was stopped (Ctrl+C) — exit cleanly
            break
        } catch {
            Write-Host "Request error: $_" -ForegroundColor Yellow
        }
    }
} finally {
    Remove-PortFile
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Host "Server stopped." -ForegroundColor Yellow
}
