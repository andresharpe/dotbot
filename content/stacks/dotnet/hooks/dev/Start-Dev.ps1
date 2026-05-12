# Start-Dev.ps1
# Loads .env.local and starts the development environment

param(
    [switch]$NoLayout
)

. "$PSScriptRoot/Common.ps1"
Import-Module "$PSScriptRoot/DevLayout.psm1" -Force -DisableNameChecking

$repoRoot = Invoke-InProjectRoot
$projectName = Get-ProjectName
$sessionName = $projectName.ToLower()

Write-Host ""
Write-Host "$projectName Development Environment" -ForegroundColor White
Write-Host ("=" * "$projectName Development Environment".Length) -ForegroundColor White
Write-Host ""

# Load environment variables
$envFile = Join-Path $repoRoot ".env.local"
if (Test-Path $envFile) {
    Write-Status "Loading .env.local file" -Type Info
    try {
        $envVars = Load-EnvFile -Path $envFile -Export
        Write-Status "Loaded $($envVars.Count) environment variables" -Type Success
    }
    catch {
        Write-Status "Failed to load .env.local: $_" -Type Error
        exit 1
    }
}
else {
    Write-Status ".env.local file not found" -Type Warn
    Write-Status "Copy .env.example to .env.local and configure your settings" -Type Info
}

Write-Host ""

# Stop any existing processes first (makes this idempotent)
& "$PSScriptRoot\Stop-Dev.ps1" -Quiet

# Auto-detect API project
$apiProjectRelPath = Find-ApiProject -RepoRoot $repoRoot
if (-not $apiProjectRelPath) {
    Write-Status "No *Api.csproj found under src/" -Type Error
    exit 1
}
$apiProjectPath = Join-Path $repoRoot $apiProjectRelPath
if (-not (Test-Path $apiProjectPath)) {
    Write-Status "API project not found at: $apiProjectPath" -Type Error
    exit 1
}
Write-Status "Found API project: $apiProjectRelPath" -Type Info

# Ensure logs directory exists
$logsDir = Join-Path $repoRoot "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

# Ensure data directory exists (for SQLite)
$dataDir = Join-Path $repoRoot "data"
if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

# Read layout config for port and URL
$layoutConfigPath = Join-Path $PSScriptRoot "layout.json"
$port = 5000
$openUrl = ""
if (Test-Path $layoutConfigPath) {
    $layoutConfig = Get-Content $layoutConfigPath -Raw | ConvertFrom-Json
    if ($layoutConfig.port) { $port = $layoutConfig.port }
    if ($layoutConfig.openUrl) { $openUrl = $layoutConfig.openUrl }
}

$apiUrl = "http://localhost:$port"
$healthUrl = "$apiUrl/health"
$browserUrl = "$apiUrl$openUrl"

# Open dev layout (which starts the API via dotnet watch)
$layoutResult = $null
if (-not $NoLayout -and (Test-Path $layoutConfigPath) -and $layoutConfig.enabled) {
    # Build the terminal command
    $commonScript = Join-Path $PSScriptRoot "Common.ps1"
    $terminalCommand = @"
. '$commonScript'
`$envFile = '$envFile'
if (Test-Path `$envFile) {
    Load-EnvFile -Path `$envFile -Export | Out-Null
}
Set-Location '$repoRoot'
dotnet watch --project $apiProjectRelPath
"@

    Write-Status "Opening dev layout..." -Type Info
    $layoutResult = Open-DevLayout `
        -Monitor $layoutConfig.monitor `
        -Layout $layoutConfig.layout `
        -Terminals @($terminalCommand) `
        -Urls @($browserUrl) `
        -SessionName $sessionName

    if ($layoutResult.status -eq "running") {
        Write-Status "Layout opened: $($layoutResult.terminals) terminal(s), $($layoutResult.browsers) browser(s)" -Type Success
    }
}

if ($NoLayout -or -not $layoutResult) {
    Write-Status "No layout - starting API directly..." -Type Info
    Write-Status "Logs will be written to: $logsDir" -Type Info

    # Build the startup command that loads env vars and runs the API
    $commonScript = Join-Path $PSScriptRoot "Common.ps1"
    $startupCommand = @"
. '$commonScript'
`$envFile = '$envFile'
if (Test-Path `$envFile) {
    Load-EnvFile -Path `$envFile -Export | Out-Null
}
Set-Location '$repoRoot'
dotnet watch --project $apiProjectRelPath
"@

    # Start API in a visible window
    $apiProcess = Start-Process -FilePath "pwsh" -ArgumentList @(
        "-NoExit",
        "-Command",
        $startupCommand
    ) -PassThru

    Write-Status "API window opened (PID: $($apiProcess.Id))" -Type Success

    # Save PID for cleanup
    $pidFile = Join-Path $repoRoot ".bot\.dev-pids.json"
    $pids = @{
        api_pid = $apiProcess.Id
        started_at = (Get-Date).ToString('o')
    }
    $pids | ConvertTo-Json | Set-Content $pidFile -Force
}

# Wait for health endpoint (up to 30 seconds)
Write-Host ""
Write-Status "Waiting for API to start..." -Type Info

$timeout = 30
$elapsed = 0
$healthCheckPassed = $false

# Helper function to check if API port is listening
function Test-ApiPortListening {
    param([int]$Port)
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $listener
}

$portWasListening = $false

while ($elapsed -lt $timeout) {
    $isListening = Test-ApiPortListening -Port $port
    if ($isListening) {
        $portWasListening = $true
    } elseif ($portWasListening) {
        # Port was listening but stopped - app crashed after starting
        Write-Status "API stopped listening (app may have crashed)" -Type Error
        break
    }

    try {
        $response = Invoke-WebRequest -Uri $healthUrl -Method GET -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            $healthCheckPassed = $true
            break
        }
    }
    catch {
        # API not ready yet
    }
    Start-Sleep -Milliseconds 500
    $elapsed += 0.5
}

# Determine final status
$finalStatus = "running"
if ($healthCheckPassed) {
    Write-Status "API is healthy" -Type Success

    # Refresh browser windows now that API is ready
    if ($layoutResult -and $sessionName) {
        $refreshResult = Send-BrowserRefresh -SessionName $sessionName -Quiet
        if ($refreshResult.count -gt 0) {
            Write-Status "Refreshed $($refreshResult.count) browser window(s)" -Type Success
        }
    }
} else {
    # Health check failed - determine why
    $isListening = Test-ApiPortListening -Port $port
    if ($portWasListening -and -not $isListening) {
        $finalStatus = "failed"
        Write-Status "API crashed after starting" -Type Error
        Write-Status "Check logs at: $logsDir" -Type Info
    } elseif (-not $portWasListening) {
        $finalStatus = "failed"
        Write-Status "API never started listening on port $port" -Type Error
        Write-Status "Check the terminal window for build/startup errors" -Type Info
    } else {
        # Port is listening but health check failed
        $finalStatus = "starting"
        Write-Status "API is listening but health check timed out" -Type Warn
        Write-Status "Check logs for errors: $logsDir" -Type Info
    }
}

Write-Host ""
Write-Host "  API:     $apiUrl" -ForegroundColor Cyan
Write-Host "  Health:  $healthUrl" -ForegroundColor Gray
Write-Host "  Logs:    $logsDir" -ForegroundColor Gray
Write-Host ""
Write-Host "  Use 'dev_stop' MCP tool or run Stop-Dev.ps1 to stop" -ForegroundColor Gray
Write-Host ""

# Return status for MCP tool consumption
$result = @{
    api_url = $apiUrl
    status = $finalStatus
}
if ($layoutResult) {
    $result.layout = $layoutResult
}
return $result
