<#
.SYNOPSIS
Minimal PowerShell web server for .bot autonomous development monitoring

.DESCRIPTION
Serves a terminal-inspired web UI on localhost:8686 that monitors .bot folder state
and provides control signals via file-based communication.

.PARAMETER Port
Port to run the web server on (default: 8686)

.EXAMPLE
.\server.ps1
#>

param(
    [Parameter(Mandatory = $false)]
    [int]$Port = 8686,

    [Parameter(Mandatory = $false)]
    [switch]$AutoPort
)

# ---------------------------------------------------------------------------
# Port availability helper
# ---------------------------------------------------------------------------
function Find-AvailablePort {
    param([int]$StartPort)
    $maxPort = 8699
    for ($p = $StartPort; $p -le $maxPort; $p++) {
        # Phase 1: TCP socket probe
        try {
            $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $tcp.Start()
            $tcp.Stop()
        } catch {
            continue  # Port in use — try next
        }

        # Phase 2: HTTP prefix probe (catches existing HttpListener registrations
        # that a raw TCP check can miss on Windows)
        $http = [System.Net.HttpListener]::new()
        try {
            $http.Prefixes.Add("http://localhost:$p/")
            $http.Start()
            return $p
        } catch {
            continue  # HTTP prefix conflict — try next
        } finally {
            try { if ($http.IsListening) { $http.Stop() } } catch { }
            try { $http.Close() } catch { }
        }
    }
    throw "No available port found in range ${StartPort}–${maxPort}"
}

# Auto-select port when using the default or when -AutoPort is set
$portExplicit = $PSBoundParameters.ContainsKey('Port') -and -not $AutoPort
if (-not $portExplicit) {
    $Port = Find-AvailablePort -StartPort $Port
}

# Find .bot root (server is at .bot/systems/ui, so go up 2 levels)
$botRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$projectRoot = Split-Path -Parent $botRoot
$global:DotbotProjectRoot = $projectRoot
$staticRoot = Join-Path $PSScriptRoot "static"
$controlDir = Join-Path $botRoot ".control"

# Import DotBotTheme
Import-Module (Join-Path $botRoot "systems\runtime\modules\DotBotTheme.psm1") -Force
$t = Get-DotBotTheme

if (-not (Test-Path $controlDir)) { New-Item -Path $controlDir -ItemType Directory -Force | Out-Null }

# Write selected port so go.ps1 (and other tools) can discover it
$Port.ToString() | Set-Content (Join-Path $controlDir "ui-port") -NoNewline -Encoding UTF8

$processesDir = Join-Path $controlDir "processes"
if (-not (Test-Path $processesDir)) { New-Item -Path $processesDir -ItemType Directory -Force | Out-Null }

# Import FileWatcher module for event-driven state updates
Import-Module (Join-Path $PSScriptRoot "modules\FileWatcher.psm1") -Force

# Import domain modules
Import-Module (Join-Path $PSScriptRoot "modules\GitAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\AetherAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ReferenceCache.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\SettingsAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ControlAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ProductAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\TaskAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ProcessAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\StateBuilder.psm1") -Force

# Initialize all domain modules
Initialize-FileWatchers -BotRoot $botRoot
Initialize-GitAPI -ProjectRoot $projectRoot -BotRoot $botRoot
Initialize-AetherAPI -ControlDir $controlDir
Initialize-ReferenceCache -BotRoot $botRoot -ProjectRoot $projectRoot
Initialize-SettingsAPI -ControlDir $controlDir -BotRoot $botRoot -StaticRoot $staticRoot
Initialize-ControlAPI -ControlDir $controlDir -ProcessesDir $processesDir -BotRoot $botRoot
Initialize-ProductAPI -BotRoot $botRoot -ControlDir $controlDir
Initialize-TaskAPI -BotRoot $botRoot -ProjectRoot $projectRoot
Initialize-ProcessAPI -ProcessesDir $processesDir -BotRoot $botRoot -ControlDir $controlDir
Initialize-StateBuilder -BotRoot $botRoot -ControlDir $controlDir -ProcessesDir $processesDir

# Request counter for single-line logging
$script:requestCount = 0

# Clear screen
Clear-Host

# Display banner
Write-Card -Title "Dotbot Control Panel" -Width 70 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines @(
    "$($t.Amber)Real-time monitoring and control for autonomous development$($t.Reset)"
)

Write-Card -Title "Configuration" -Width 70 -BorderStyle Rounded -BorderColor Label -TitleColor Label -Lines @(
    "$($t.Label)Port:$($t.Reset) $($t.Amber)$Port$($t.Reset)"
    "$($t.Label)URL:$($t.Reset) $($t.Cyan)http://localhost:$Port/$($t.Reset)"
    "$($t.Label).bot root:$($t.Reset) $($t.Amber)$botRoot$($t.Reset)"
    "$($t.Label)Static files:$($t.Reset) $($t.Amber)$staticRoot$($t.Reset)"
)

# Ensure control directory exists
Write-Phosphor "› Initializing server..." -Color Cyan -NoNewline
if (-not (Test-Path $controlDir)) {
    New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
}
Write-Phosphor " ✓" -Color Green

# Check static directory exists
Write-Phosphor "› Checking static files..." -Color Cyan -NoNewline
if (Test-Path $staticRoot) {
    Write-Phosphor " ✓" -Color Green
} else {
    Write-Phosphor " ⚠" -Color Amber
    Write-Status "Static directory not found: $staticRoot" -Type Warn
}

# HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
Write-Phosphor "› Starting listener..." -Color Cyan -NoNewline
try {
    $listener.Start()
    Write-Phosphor " ✓" -Color Green
    Write-Host "$($t.Green)●$($t.Reset) $($t.Label)Press Ctrl+C to stop$($t.Reset)"
    Write-Separator -Width 70
} catch {
    Write-Phosphor " ✗" -Color Red
    if ($_.Exception.Message -match 'conflicts with an existing registration') {
        Write-Status "Port $Port is already in use. Try a different port: .\server.ps1 -Port <number>" -Type Error
    } else {
        Write-Status "Error starting listener: $($_.Exception.Message)" -Type Error
    }
    exit 1
}

# Helper: Get directory list for bot directories (used by multiple prompts routes)
function Get-BotDirectoryList {
    param([string]$Directory)

    $dirPath = Join-Path $botRoot "prompts\$Directory"
    $groups = [System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]]::new()

    if (Test-Path $dirPath) {
        # Get all .md files recursively, excluding archived folders
        $mdFiles = @(Get-ChildItem -Path $dirPath -Filter "*.md" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\archived\\' })

        foreach ($file in $mdFiles) {
            if ($null -eq $file) { continue }

            # Calculate relative path from directory root
            $relativePath = $file.FullName.Replace("$dirPath\", "").Replace("\", "/")

            # Determine folder group
            $folder = "(root)"
            if ($relativePath -like '*/*') {
                $folder = Split-Path $relativePath -Parent
            }

            # Initialize group if needed
            if (-not $groups.ContainsKey($folder)) {
                $groups[$folder] = [System.Collections.ArrayList]::new()
            }

            # Add item to group
            [void]$groups[$folder].Add(@{
                name = $file.BaseName
                filename = $relativePath
                basename = $file.BaseName
            })
        }
    }

    # Convert to grouped structure
    $groupedItems = [System.Collections.ArrayList]::new()
    foreach ($key in @($groups.Keys)) {
        $itemsArray = @()
        $groupItems = $groups[$key]
        if ($null -ne $groupItems -and $groupItems.Count -gt 0) {
            $sortable = @()
            foreach ($item in $groupItems) {
                $sortable += [PSCustomObject]@{
                    name = $item.name
                    filename = $item.filename
                    basename = $item.basename
                }
            }
            $itemsArray = @($sortable | Sort-Object -Property name)
        }
        [void]$groupedItems.Add([PSCustomObject]@{
            folder = if ($key -eq "(root)") { "" } else { $key.Replace('\', '/') }
            items = $itemsArray
        })
    }

    # Sort groups by folder name (empty string first for root)
    $sorted = @()
    if ($groupedItems.Count -gt 0) {
        $sorted = @($groupedItems | Sort-Object -Property folder)
    }

    return @{ groups = $sorted } | ConvertTo-Json -Depth 5 -Compress
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $timestamp = Get-Date -Format 'HH:mm:ss'
        $method = $request.HttpMethod
        $url = $request.Url.LocalPath

        # Request logging - polling endpoints use single-line overwrite, others get newlines
        $script:requestCount++

        # Refresh theme periodically (every 100 requests) to pick up UI changes
        if ($script:requestCount % 100 -eq 0) {
            if (Update-DotBotTheme) {
                $t = Get-DotBotTheme
            }
        }

        $isPollingEndpoint = $url -in @('/api/state', '/api/activity/tail', '/api/git-status', '/api/processes') -or $url -like '/api/process/*/output'
        $logLine = "$($t.Bezel)[$timestamp]$($t.Reset) $($t.Label)$method$($t.Reset) $($t.Cyan)$url$($t.Reset) $($t.Bezel)(#$script:requestCount)$($t.Reset)"

        if ($isPollingEndpoint) {
            $clearPad = ' ' * [Math]::Max(0, 70 - (Get-VisualWidth $logLine))
            Write-Host "`r$logLine$clearPad" -NoNewline
        } else {
            Write-Host ""
            Write-Host $logLine
        }

        # Route handler
        $statusCode = 200
        $contentType = "text/html; charset=utf-8"
        $content = ""

        # CSRF protection: require X-Dotbot-Request header on state-changing requests.
        # Browsers enforce CORS preflight for custom headers, blocking cross-origin attacks.
        if ($method -in @('POST', 'PUT', 'DELETE')) {
            $csrfHeader = $request.Headers['X-Dotbot-Request']
            if ($csrfHeader -ne '1') {
                $statusCode = 403
                $contentType = "application/json; charset=utf-8"
                $content = '{"success":false,"error":"Missing CSRF header"}'
            }
        }

        if ($statusCode -eq 200) {
        try {
            Write-Verbose "Processing URL: $url"
            switch ($url) {
                "/" {
                    $indexPath = Join-Path $staticRoot "index.html"
                    if (Test-Path $indexPath) {
                        $content = Get-Content $indexPath -Raw
                    } else {
                        $statusCode = 404
                        $content = "index.html not found"
                    }
                    break
                }

                "/api/info" {
                    $contentType = "application/json; charset=utf-8"
                    $projectName = Split-Path -Leaf $projectRoot

                    # Try to extract executive summary from product docs
                    $executiveSummary = $null
                    $productDir = Join-Path $botRoot "workspace\product"
                    if (Test-Path $productDir) {
                        $priorityFiles = @('overview.md', 'mission.md', 'roadmap.md', 'roadmap-overview.md')
                        $allFiles = @(Get-ChildItem -Path $productDir -Filter "*.md" -ErrorAction SilentlyContinue)

                        $orderedFiles = @()
                        foreach ($pf in $priorityFiles) {
                            $match = $allFiles | Where-Object { $_.Name -eq $pf }
                            if ($match) { $orderedFiles += $match }
                        }
                        foreach ($f in $allFiles) {
                            if ($f.Name -notin $priorityFiles) { $orderedFiles += $f }
                        }

                        foreach ($file in $orderedFiles) {
                            $docContent = Get-Content -Path $file.FullName -Raw
                            if ($docContent -match '(?m)##? Executive Summary\s*\r?\n+\s*(.+)') {
                                $executiveSummary = $matches[1].Trim()
                                break
                            }
                        }
                    }

                    # Detect existing code via git history
                    $hasExistingCode = $false
                    try {
                        $gitLog = git -C $projectRoot log --oneline 2>$null
                        if ($gitLog) {
                            $commitCount = @($gitLog).Count
                            $hasExistingCode = $commitCount -gt 1
                        }
                    } catch {}

                    $content = @{
                        project_name = $projectName
                        project_root = $projectRoot
                        full_path = $projectRoot
                        executive_summary = $executiveSummary
                        has_existing_code = $hasExistingCode
                    } | ConvertTo-Json -Compress
                    break
                }

                # --- State & Polling ---

                "/api/state" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-BotState | ConvertTo-Json -Depth 20 -Compress
                    break
                }

                "/api/state/poll" {
                    $contentType = "application/json; charset=utf-8"
                    $timeout = if ($request.QueryString["timeout"]) { [int]$request.QueryString["timeout"] } else { 30000 }
                    $lastSeen = if ($request.QueryString["since"]) {
                        try { [DateTime]::Parse($request.QueryString["since"]) } catch { [DateTime]::MinValue }
                    } else { [DateTime]::MinValue }

                    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeout)
                    $pollInterval = 100
                    $state = $null

                    while ([DateTime]::UtcNow -lt $deadline) {
                        if (Test-StateChanged -Since $lastSeen) {
                            $state = Get-BotState
                            break
                        }
                        Start-Sleep -Milliseconds $pollInterval
                    }

                    if (-not $state) {
                        $state = Get-BotState
                        $state.timeout = $true
                    }
                    $state.polled_at = [DateTime]::UtcNow.ToString("o")
                    $content = $state | ConvertTo-Json -Depth 20 -Compress
                    break
                }

                # --- Git ---

                "/api/git-status" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-GitStatus | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                "/api/git/commit-and-push" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $result = Start-GitCommitAndPush
                            $content = $result | ConvertTo-Json -Compress
                            Write-Status "Git commit-and-push launched as process (PID: $($result.pid))" -Type Info
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to start commit: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                # --- Aether ---

                "/api/aether/scan" {
                    $contentType = "application/json; charset=utf-8"
                    $result = Get-AetherScanResult
                    if ($result.found) {
                        Write-Status "Aether conduit discovered: $($result.conduit) (ID: $($result.id))" -Type Success
                    }
                    $content = $result | ConvertTo-Json -Compress
                    break
                }

                "/api/aether/config" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $content = Get-AetherConfig | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd()
                            $reader.Close()
                            $result = Set-AetherConfig -Body $body
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to save config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                # --- Reference Cache ---

                { $_ -like "/api/file/*" } {
                    $contentType = "application/json; charset=utf-8"
                    $pathParts = ($url -replace "^/api/file/", "") -split '/', 2
                    if ($pathParts.Count -eq 2) {
                        $type = $pathParts[0]
                        $filename = [System.Web.HttpUtility]::UrlDecode($pathParts[1])
                        $result = Get-FileWithReferences -Type $type -Filename $filename
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    } else {
                        $statusCode = 400
                        $content = @{ success = $false; error = "Invalid file path" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/cache/clear" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $content = Clear-ReferenceCache | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                # --- Settings & Config ---

                "/api/theme" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-Theme
                        if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-Theme -Body $body
                            if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update theme: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/settings" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $content = Get-Settings | ConvertTo-Json -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $content = Set-Settings -Body $body | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update settings: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/config/analysis" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-AnalysisConfig
                        if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-AnalysisConfig -Body $body
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update analysis config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/config/costs" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-CostConfig
                        if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-CostConfig -Body $body
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update cost config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/config/editor" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-EditorConfig
                        if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-EditorConfig -Body $body
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update editor config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/editors" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $refresh = $request.Url.Query -match 'refresh=true'
                        $result = Get-EditorRegistry -Refresh:$refresh
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/open-editor" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $result = Invoke-OpenEditor -ProjectRoot $projectRoot
                            if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to open editor: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/config/verification" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-VerificationConfig
                        if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-VerificationConfig -Body $body
                            if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update verification config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                # --- Control & Whisper ---

                "/api/control" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $reader = New-Object System.IO.StreamReader($request.InputStream)
                        $body = $reader.ReadToEnd() | ConvertFrom-Json
                        $reader.Close()
                        $content = Set-ControlSignal -Action $body.action -Mode $body.mode | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/whisper" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Send-Whisper -InstanceType $body.instance_type -Message $body.message -Priority $(if ($body.priority) { $body.priority } else { "normal" })
                            $content = $result | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to send whisper: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/activity/tail" {
                    $contentType = "application/json; charset=utf-8"
                    $position = if ($request.QueryString["position"]) { [long]$request.QueryString["position"] } else { 0L }
                    $tailLines = if ($request.QueryString["tail"]) { [int]$request.QueryString["tail"] } else { 0 }
                    $content = Get-ActivityTail -Position $position -TailLines $tailLines | ConvertTo-Json -Depth 10 -Compress
                    break
                }

                # --- Product ---

                "/api/product/list" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-ProductList | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                "/api/product/kickstart" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.prompt) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'prompt' field" } | ConvertTo-Json -Compress
                            } else {
                                $result = Start-ProductKickstart -UserPrompt $body.prompt -Files @($body.files) -NeedsInterview ($body.needs_interview -eq $true)
                                if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                                $content = $result | ConvertTo-Json -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to kickstart project: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/product/analyse" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            $result = Start-ProductAnalyse -UserPrompt $body.prompt -Model $(if ($body.model) { $body.model } else { "Sonnet" })
                            if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to analyse project: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/product/plan-roadmap" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $result = Start-RoadmapPlanning
                            if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to start roadmap planning: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                { $_ -like "/api/product/*" -and $_ -ne "/api/product/list" -and $_ -ne "/api/product/analyse" } {
                    $contentType = "application/json; charset=utf-8"
                    $docName = $url -replace "^/api/product/", ""
                    $result = Get-ProductDocument -Name $docName
                    if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                    $content = $result | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                # --- Tasks ---

                "/api/tasks/action-required" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-ActionRequired | ConvertTo-Json -Depth 20 -Compress
                    break
                }

                "/api/task/answer" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $content = Submit-TaskAnswer -TaskId $body.task_id -Answer $body.answer -CustomText $body.custom_text | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to submit answer: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/task/approve-split" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $content = Submit-SplitApproval -TaskId $body.task_id -Approved $body.approved | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to process split: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/task/create" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.prompt) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'prompt' field" } | ConvertTo-Json -Compress
                            } else {
                                $content = Start-TaskCreation -UserPrompt $body.prompt -NeedsInterview ($body.needs_interview -eq $true) | ConvertTo-Json -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to create task: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                { $_ -like "/api/plan/*" } {
                    $contentType = "application/json; charset=utf-8"
                    $taskId = [System.Web.HttpUtility]::UrlDecode($url -replace "^/api/plan/", "")
                    $result = Get-TaskPlan -TaskId $taskId
                    if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                    $content = $result | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                # --- Processes ---

                "/api/processes" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-ProcessList -FilterType $request.QueryString["type"] -FilterStatus $request.QueryString["status"] | ConvertTo-Json -Depth 10 -Compress
                    break
                }

                "/api/process/launch" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $reader = New-Object System.IO.StreamReader($request.InputStream)
                        $body = $reader.ReadToEnd() | ConvertFrom-Json
                        $reader.Close()

                        if (-not $body.type) {
                            $content = @{ success = $false; error = "type is required" } | ConvertTo-Json -Compress
                        } else {
                            $result = Start-ProcessLaunch -Type $body.type -TaskId $body.task_id -Prompt $body.prompt -Continue ($body.continue -eq $true) -Description $body.description -Model $body.model
                            $content = $result | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/process/stop-by-type" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $reader = New-Object System.IO.StreamReader($request.InputStream)
                        $body = $reader.ReadToEnd() | ConvertFrom-Json
                        $reader.Close()
                        $content = Stop-ProcessByType -Type $body.type | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/process/kill-by-type" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $reader = New-Object System.IO.StreamReader($request.InputStream)
                        $body = $reader.ReadToEnd() | ConvertFrom-Json
                        $reader.Close()
                        $content = Stop-ManagedProcessByType -Type $body.type | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/process/kill-all" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $content = Stop-AllManagedProcesses | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                "/api/process/answer" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.process_id) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'process_id' field" } | ConvertTo-Json -Compress
                            } else {
                                # Find the process to get its product dir
                                $procFile = Join-Path $processesDir "$($body.process_id).json"
                                if (-not (Test-Path $procFile)) {
                                    $statusCode = 404
                                    $content = @{ success = $false; error = "Process not found: $($body.process_id)" } | ConvertTo-Json -Compress
                                } else {
                                    # Write answers file that the interview loop is polling for
                                    $answersData = @{
                                        skipped = ($body.skipped -eq $true)
                                        answers = @($body.answers)
                                        submitted_at = (Get-Date).ToUniversalTime().ToString("o")
                                    }
                                    $productDir = Join-Path $botRoot "workspace\product"
                                    $answersPath = Join-Path $productDir "clarification-answers.json"
                                    $answersData | ConvertTo-Json -Depth 10 | Set-Content -Path $answersPath -Encoding utf8NoBOM
                                    $content = @{ success = $true } | ConvertTo-Json -Compress
                                }
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to submit answer: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                { $_ -like "/api/process/*/output" } {
                    $contentType = "application/json; charset=utf-8"
                    $procId = ($url -replace "^/api/process/", "" -replace "/output$", "")
                    $position = [int]($request.QueryString["position"])
                    $tail = [int]($request.QueryString["tail"])
                    $content = Get-ProcessOutput -ProcessId $procId -Position $position -Tail $tail | ConvertTo-Json -Depth 10 -Compress
                    break
                }

                { $_ -like "/api/process/*/stop" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $procId = ($url -replace "^/api/process/", "" -replace "/stop$", "")
                        $content = Stop-ProcessById -ProcessId $procId | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                { $_ -like "/api/process/*/kill" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $procId = ($url -replace "^/api/process/", "" -replace "/kill$", "")
                        $result = Stop-ManagedProcessById -ProcessId $procId
                        if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                { $_ -like "/api/process/*/whisper" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $procId = ($url -replace "^/api/process/", "" -replace "/whisper$", "")
                        $reader = New-Object System.IO.StreamReader($request.InputStream)
                        $body = $reader.ReadToEnd() | ConvertFrom-Json
                        $reader.Close()
                        $content = Send-ProcessWhisper -ProcessId $procId -Message $body.message -Priority $(if ($body.priority) { $body.priority } else { "normal" }) | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = "Method not allowed"
                    }
                    break
                }

                { $_ -like "/api/process/*" -and $_ -notlike "/api/process/*/output" -and $_ -notlike "/api/process/*/stop" -and $_ -notlike "/api/process/*/kill" -and $_ -notlike "/api/process/*/whisper" -and $_ -ne "/api/process/launch" -and $_ -ne "/api/process/stop-by-type" -and $_ -ne "/api/process/kill-by-type" -and $_ -ne "/api/process/kill-all" } {
                    $contentType = "application/json; charset=utf-8"
                    $procId = $url -replace "^/api/process/", ""
                    $result = Get-ProcessDetail -ProcessId $procId
                    if ($result._statusCode) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                    $content = $result | ConvertTo-Json -Depth 10 -Compress
                    break
                }

                # --- Prompts (inline, uses local helper) ---

                "/api/commands/list" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-BotDirectoryList -Directory "commands"
                    break
                }

                "/api/workflows/list" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-BotDirectoryList -Directory "workflows"
                    break
                }

                "/api/agents/list" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-BotDirectoryList -Directory "agents"
                    break
                }

                "/api/standards/list" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-BotDirectoryList -Directory "standards"
                    break
                }

                "/api/prompts/directories" {
                    $contentType = "application/json; charset=utf-8"
                    $promptsDir = Join-Path $botRoot "prompts"
                    $directories = @()

                    if (Test-Path $promptsDir) {
                        $directories = @(Get-ChildItem -Path $promptsDir -Directory | ForEach-Object {
                            $name = $_.Name
                            $shortType = $name.Substring(0, [Math]::Min(3, $name.Length))
                            $itemCount = @(Get-ChildItem -Path $_.FullName -Filter "*.md" -Recurse -ErrorAction SilentlyContinue |
                                Where-Object { $_.FullName -notmatch '\\archived\\' }).Count
                            @{
                                name = $name
                                displayName = (Get-Culture).TextInfo.ToTitleCase($name)
                                shortType = $shortType
                                itemCount = $itemCount
                            }
                        })
                    }

                    $content = @{ directories = $directories } | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                # Generic handler for any prompts directory list
                { $_ -match "^/api/(\w+)/list$" } {
                    $contentType = "application/json; charset=utf-8"
                    if ($url -match "^/api/(\w+)/list$") {
                        $dirName = $Matches[1]
                    } else {
                        $dirName = "unknown"
                    }
                    $dirPath = Join-Path $botRoot "prompts\$dirName"

                    if (Test-Path $dirPath) {
                        $content = Get-BotDirectoryList -Directory $dirName
                    } else {
                        $statusCode = 404
                        $content = @{ success = $false; error = "Directory not found: $dirName" } | ConvertTo-Json -Compress
                    }
                    break
                }

                default {
                    # Serve static files
                    $filePath = Join-Path $staticRoot $url.TrimStart('/')

                    if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                        $extension = [System.IO.Path]::GetExtension($filePath)
                        $contentType = switch ($extension) {
                            ".html" { "text/html; charset=utf-8" }
                            ".css" { "text/css; charset=utf-8" }
                            ".js" { "application/javascript; charset=utf-8" }
                            ".json" { "application/json; charset=utf-8" }
                            default { "application/octet-stream" }
                        }
                        $content = Get-Content -LiteralPath $filePath -Raw
                    } else {
                        $statusCode = 404
                        $content = "Not found: $url"
                    }
                }
            }
        } catch {
            $statusCode = 500
            $content = "Server error: $($_.Exception.Message)"
            Write-Host ""
            Write-Status "[$timestamp] ERROR: $($_.Exception.Message)" -Type Error
            Write-Host "  Script: $($_.InvocationInfo.ScriptName)" -ForegroundColor Red
            Write-Host "  Line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
            Write-Host "  Statement: $($_.InvocationInfo.Line.Trim())" -ForegroundColor Red
        }
        } # end CSRF-safe block

        # Send response (wrapped to handle client disconnects gracefully)
        try {
            if ($null -eq $content) {
                $content = "{}"
            }
            $response.StatusCode = $statusCode
            $response.ContentType = $contentType
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
            $response.ContentLength64 = $buffer.Length
            if ($null -ne $response.OutputStream) {
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
                $response.Close()
            }
        } catch {
            if ($_.Exception.Message -match "network name is no longer available|connection was forcibly closed|broken pipe") {
                # Silent handling for expected disconnects
            } else {
                Write-Host ""
                Write-Status "Response write failed: $($_.Exception.Message)" -Type Warn
            }
            try { $response.Close() } catch { }
        }
    }
} finally {
    # Stop file watchers
    try {
        Stop-FileWatchers
    } catch {
        # Ignore watcher disposal errors
    }

    # Safely stop listener if it's still running
    if ($listener -and $listener.IsListening) {
        try {
            $listener.Stop()
            $listener.Close()
        } catch {
            # Ignore disposal errors
        }
    }
    Write-Status "Server stopped" -Type Warn
}
