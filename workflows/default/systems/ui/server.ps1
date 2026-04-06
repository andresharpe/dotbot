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
    [ValidateRange(1024, 65535)]
    [int]$Port = 8686,

    [Parameter(Mandatory = $false)]
    [switch]$AutoPort
)

Set-StrictMode -Version 1.0

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
            try { if ($http.IsListening) { $http.Stop() } } catch { Write-Verbose "Port probe: failed to stop HttpListener: $_" }
            try { $http.Close() } catch { Write-Verbose "Port probe: failed to close HttpListener: $_" }
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

# Import DotBotLog and DotBotTheme
if (-not (Test-Path $controlDir)) { New-Item -Path $controlDir -ItemType Directory -Force | Out-Null }
$dotBotLogPath = Join-Path $botRoot "systems\runtime\modules\DotBotLog.psm1"
if (Test-Path $dotBotLogPath) {
    $logsDir = Join-Path $controlDir "logs"
    if (-not (Test-Path $logsDir)) { New-Item -Path $logsDir -ItemType Directory -Force | Out-Null }
    Import-Module $dotBotLogPath -Force -DisableNameChecking
    Initialize-DotBotLog -LogDir $logsDir -ControlDir $controlDir -ProjectRoot $projectRoot
}
Import-Module (Join-Path $botRoot "systems\runtime\modules\DotBotTheme.psm1") -Force
$t = Get-DotBotTheme

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
Import-Module (Join-Path $PSScriptRoot "modules\NotificationPoller.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\DecisionAPI.psm1") -Force

# Import workflow manifest utilities (for installed workflows API)
. (Join-Path $botRoot "systems\runtime\modules\workflow-manifest.ps1")

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
Initialize-NotificationPoller -BotRoot $botRoot
Initialize-DecisionAPI -BotRoot $botRoot

# Request counter for single-line logging
$script:requestCount = 0

# --- Performance caches for /api/workflows/installed ---
# Response-level cache (10s TTL)
$script:workflowsCache = @{ data = $null; timestamp = [datetime]::MinValue }
$script:workflowsCacheTTL = [timespan]::FromSeconds(10)
# Manifest read cache: keyed by directory path → @{ manifest; lastModified }
$script:manifestCache = @{}
# Task file cache: keyed by file path → @{ workflow; lastModified }
$script:taskFileCache = @{}

# Clear screen (may fail when running without a console, e.g. redirected output)
try { Clear-Host } catch { Write-BotLog -Level Debug -Message "Clear-Host not available" -Exception $_ }

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

# Pre-warm reference cache (makes first Workflow tab file click instant)
if (-not (Test-CacheValidity)) {
    Build-ReferenceCache | Out-Null
} else {
    Write-Status "Reference cache is valid (skipping rebuild)" -Type Success
}

# HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
Write-Phosphor "› Starting listener..." -Color Cyan -NoNewline
try {
    $listener.Start()
    Write-Phosphor " ✓" -Color Green
    Write-BotLog -Level Info -Message "Press Ctrl+C to stop"
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

    $dirPath = Join-Path $botRoot "recipes\$Directory"
    $groups = [System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]]::new()

    if (Test-Path $dirPath) {
        # Get all .md files recursively, excluding archived folders
        $mdFiles = @(Get-ChildItem -Path $dirPath -Filter "*.md" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\archived\\' })

        foreach ($file in $mdFiles) {
            if ($null -eq $file) { continue }

            # Calculate relative path from directory root (case-insensitive on Windows)
            $relativePath = [System.IO.Path]::GetRelativePath($dirPath, $file.FullName).Replace("\", "/")

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

function Get-StaticAssetVersion {
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    $normalizedPath = $RelativePath.TrimStart('/').Replace('/', '\')
    $assetPath = Join-Path $staticRoot $normalizedPath
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        return $null
    }

    return (Get-Item -LiteralPath $assetPath).LastWriteTimeUtc.Ticks.ToString()
}

function Add-StaticAssetVersions {
    param(
        [Parameter(Mandatory)]
        [string]$Html
    )

    $pattern = '(?<attr>\b(?:src|href))="(?<path>(?!https?:|data:|#|//)[^"?]+?\.(?:js|css|json))(?<query>\?[^"]*)?"'

    return [regex]::Replace($Html, $pattern, {
        param($match)

        $assetPath = $match.Groups['path'].Value
        $version = Get-StaticAssetVersion -RelativePath $assetPath
        if (-not $version) {
            return $match.Value
        }

        return '{0}="{1}?v={2}"' -f $match.Groups['attr'].Value, $assetPath, $version
    })
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
            # Skip logging for high-frequency polling endpoints to avoid log bloat
        } else {
            Write-BotLog -Level Debug -Message ""
            Write-BotLog -Level Info -Message "$logLine"
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
            Write-BotLog -Level Debug -Message "Processing URL: $url"
            switch ($url) {
                "/" {
                    $indexPath = Join-Path $staticRoot "index.html"
                    if (Test-Path $indexPath) {
                        $content = Add-StaticAssetVersions -Html (Get-Content $indexPath -Raw)
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

                    # Read workflow name from settings
                    $settingsFile = Join-Path $botRoot "settings\settings.default.json"
                    $workflowName = $null
                    if (Test-Path $settingsFile) {
                        try {
                            $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
                            $workflowName = if ($settingsData.PSObject.Properties['workflow']) { $settingsData.workflow } else { $settingsData.profile }
                        } catch { Write-BotLog -Level Debug -Message "Failed to read settings for workflow name" -Exception $_ }
                    }

                    # Read kickstart dialog + phases from workflow manifest (primary source)
                    $kickstartDialog = $null
                    $kickstartPhases = $null
                    $activeMode = $null
                    $manifest = Get-ActiveWorkflowManifest -BotRoot $botRoot
                    if ($manifest) {
                        $form = $manifest.form

                        # Evaluate form.modes if declared (condition-driven CTA)
                        $formModes = $null
                        if ($form) {
                            $formModes = if ($form -is [System.Collections.IDictionary]) { $form['modes'] } else { $form.modes }
                        }
                        if ($formModes -and $formModes.Count -gt 0) {
                            foreach ($mode in $formModes) {
                                $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
                                if (Test-ManifestCondition -ProjectRoot $projectRoot -Condition $modeCondition) {
                                    $activeMode = @{}
                                    foreach ($key in @('id', 'label', 'description', 'button', 'prompt_placeholder', 'show_interview', 'show_files', 'show_prompt', 'show_auto_workflow', 'default_prompt', 'hidden', 'interview_label', 'interview_hint')) {
                                        $val = if ($mode -is [System.Collections.IDictionary]) { $mode[$key] } else { $mode.$key }
                                        if ($null -ne $val) { $activeMode[$key] = $val }
                                    }
                                    # Map mode fields to kickstartDialog shape for backward compat
                                    $kickstartDialog = @{
                                        description = $activeMode['description']
                                        show_prompt = if ($null -ne $activeMode['show_prompt']) { [bool]$activeMode['show_prompt'] } else { $true }
                                        show_files = if ($null -ne $activeMode['show_files']) { [bool]$activeMode['show_files'] } else { $true }
                                        show_interview = if ($null -ne $activeMode['show_interview']) { [bool]$activeMode['show_interview'] } else { $true }
                                        default_prompt = $activeMode['default_prompt']
                                    }
                                    foreach ($key in @('interview_label', 'interview_hint', 'prompt_placeholder')) {
                                        if ($activeMode[$key]) { $kickstartDialog[$key] = "$($activeMode[$key])" }
                                    }
                                    break
                                }
                            }
                        } elseif ($form) {
                            # No modes — use flat form fields
                            $formDesc = if ($form -is [System.Collections.IDictionary]) { $form['description'] } else { $form.description }
                            if ($formDesc) {
                                $formShowPrompt = if ($form -is [System.Collections.IDictionary]) { $form['show_prompt'] } else { $form.show_prompt }
                                $formShowFiles = if ($form -is [System.Collections.IDictionary]) { $form['show_files'] } else { $form.show_files }
                                $formShowInterview = if ($form -is [System.Collections.IDictionary]) { $form['show_interview'] } else { $form.show_interview }
                                $formDefaultPrompt = if ($form -is [System.Collections.IDictionary]) { $form['default_prompt'] } else { $form.default_prompt }
                                $kickstartDialog = @{
                                    description = "$formDesc"
                                    show_prompt = if ($null -ne $formShowPrompt) { [bool]$formShowPrompt } else { $true }
                                    show_files = if ($null -ne $formShowFiles) { [bool]$formShowFiles } else { $true }
                                    show_interview = if ($null -ne $formShowInterview) { [bool]$formShowInterview } else { $true }
                                    default_prompt = "$formDefaultPrompt"
                                }
                                foreach ($key in @('interview_label', 'interview_hint', 'prompt_placeholder')) {
                                    $val = if ($form -is [System.Collections.IDictionary]) { $form[$key] } else { $form.$key }
                                    if ($val) { $kickstartDialog[$key] = "$val" }
                                }
                            }
                        }
                        # Phases from manifest tasks
                        if ($manifest.tasks -and $manifest.tasks.Count -gt 0) {
                            $kickstartPhases = @(Convert-ManifestTasksToPhases -Tasks $manifest.tasks)
                        }
                        if (-not $workflowName) { $workflowName = $manifest.name }
                    }

                    # Fallback to settings.kickstart for legacy installs
                    if (-not $kickstartDialog -and $settingsData -and $settingsData.kickstart -and $settingsData.kickstart.dialog) {
                        $kickstartDialog = $settingsData.kickstart.dialog
                    }
                    if (-not $kickstartPhases -and $settingsData -and $settingsData.kickstart -and $settingsData.kickstart.phases) {
                        $kickstartPhases = @($settingsData.kickstart.phases | ForEach-Object {
                            @{ id = $_.id; name = $_.name; optional = [bool]$_.optional }
                        })
                    }

                    # Scan installed workflows
                    $installedWorkflows = @()
                    $workflowsDir = Join-Path $botRoot "workflows"
                    if (Test-Path $workflowsDir) {
                        $installedWorkflows = @(Get-ChildItem $workflowsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                    }

                    $content = @{
                        project_name = $projectName
                        project_root = $projectRoot
                        full_path = $projectRoot
                        executive_summary = $executiveSummary
                        workflow = $workflowName
                        kickstart_dialog = $kickstartDialog
                        kickstart_phases = $kickstartPhases
                        kickstart_mode = $activeMode
                        installed_workflows = $installedWorkflows
                    } | ConvertTo-Json -Depth 5 -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/aether/bond" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $bodyJson = $reader.ReadToEnd()
                            $reader.Close()
                            $bodyObj = $bodyJson | ConvertFrom-Json
                            $result = Invoke-ConduitBond -IP $bodyObj.conduit
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Bond failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/aether/command" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $bodyJson = $reader.ReadToEnd()
                            $reader.Close()
                            $bodyObj = $bodyJson | ConvertFrom-Json
                            $config = Get-AetherConfig
                            if (-not $config.conduit -or -not $config.token) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Aether not configured" } | ConvertTo-Json -Compress
                            } else {
                                $stateJson = $bodyObj.state | ConvertTo-Json -Depth 5 -Compress
                                $result = Invoke-ConduitCommand -IP $config.conduit -Token $config.token -Nodes @($bodyObj.nodes) -State $stateJson
                                $content = $result | ConvertTo-Json -Depth 5 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Command failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/aether/nodes" {
                    $contentType = "application/json; charset=utf-8"
                    $config = Get-AetherConfig
                    if (-not $config.conduit -or -not $config.token) {
                        $statusCode = 400
                        $content = @{ success = $false; error = "Aether not configured" } | ConvertTo-Json -Compress
                    } else {
                        $result = Get-ConduitNodes -IP $config.conduit -Token $config.token
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    break
                }

                "/api/aether/verify" {
                    $contentType = "application/json; charset=utf-8"
                    $config = Get-AetherConfig
                    if (-not $config.conduit -or -not $config.token) {
                        $content = @{ valid = $false } | ConvertTo-Json -Compress
                    } else {
                        $result = Test-ConduitLink -IP $config.conduit -Token $config.token
                        $content = $result | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                # --- Settings & Config ---

                "/api/theme" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-Theme
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-Theme -Body $body
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update theme: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/providers" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-ProviderList
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-ActiveProvider -Body $body
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update provider: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/config/analysis" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-AnalysisConfig
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/config/costs" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-CostConfig
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/config/editor" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-EditorConfig
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/open-editor" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $result = Invoke-OpenEditor -ProjectRoot $projectRoot
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to open editor: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/config/mothership" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-MothershipConfig
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-MothershipConfig -Body $body
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update mothership config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/config/mothership/test" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $result = Test-MothershipServerFromUI
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ reachable = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/config/verification" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $result = Get-VerificationConfig
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 5 -Compress
                    }
                    elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()
                            $result = Set-VerificationConfig -Body $body
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to update verification config: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    }
                    else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                                $result = Start-ProductKickstart -UserPrompt $body.prompt -Files @($body.files) -NeedsInterview ($body.needs_interview -eq $true) -AutoWorkflow ($body.auto_workflow -eq $true) -SkipPhases @($body.skip_phases)
                                if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                                $content = $result | ConvertTo-Json -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to kickstart project: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/kickstart/status" {
                    $contentType = "application/json; charset=utf-8"
                    $result = Get-KickstartStatus
                    $content = $result | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                "/api/product/kickstart/resume" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $result = Resume-ProductKickstart
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to resume kickstart: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/product/preflight" {
                    $contentType = "application/json; charset=utf-8"
                    $result = Get-PreflightResults
                    $content = $result | ConvertTo-Json -Depth 5 -Compress
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
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to analyse project: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/product/plan-roadmap" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $result = Start-RoadmapPlanning
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to start roadmap planning: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/product/*" -and $_ -ne "/api/product/list" -and $_ -ne "/api/product/preflight" -and $_ -ne "/api/product/analyse" -and $_ -notlike "/api/product/kickstart*" } {
                    $contentType = "application/json; charset=utf-8"
                    $docName = $url -replace "^/api/product/", ""
                    $result = Get-ProductDocument -Name $docName
                    if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/task/ignore" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.task_id) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'task_id' field" } | ConvertTo-Json -Compress
                            } else {
                                $content = Set-RoadmapTaskIgnore -TaskId $body.task_id -Ignored ($body.ignored -eq $true) -Actor $body.actor | ConvertTo-Json -Depth 10 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to toggle ignore: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/task/edit" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.task_id) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'task_id' field" } | ConvertTo-Json -Compress
                            } elseif (-not $body.updates) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'updates' field" } | ConvertTo-Json -Compress
                            } else {
                                $content = Update-RoadmapTask -TaskId $body.task_id -Updates $body.updates -Actor $body.actor | ConvertTo-Json -Depth 10 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to edit task: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/task/delete" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.task_id) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'task_id' field" } | ConvertTo-Json -Compress
                            } else {
                                $content = Delete-RoadmapTask -TaskId $body.task_id -Actor $body.actor | ConvertTo-Json -Depth 10 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to delete task: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/task/deleted" {
                    $contentType = "application/json; charset=utf-8"
                    $content = Get-DeletedRoadmapTasks | ConvertTo-Json -Depth 20 -Compress
                    break
                }

                "/api/task/restore-version" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json
                            $reader.Close()

                            if (-not $body.task_id -or -not $body.version_id) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing required 'task_id' or 'version_id' field" } | ConvertTo-Json -Compress
                            } else {
                                $content = Restore-RoadmapTaskVersion -TaskId $body.task_id -VersionId $body.version_id -Actor $body.actor | ConvertTo-Json -Depth 10 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to restore task version: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/task/history/*" } {
                    $contentType = "application/json; charset=utf-8"
                    $taskId = [System.Web.HttpUtility]::UrlDecode(($url -replace "^/api/task/history/", ""))
                    $content = Get-RoadmapTaskHistory -TaskId $taskId | ConvertTo-Json -Depth 20 -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/plan/*" } {
                    $contentType = "application/json; charset=utf-8"
                    $taskId = [System.Web.HttpUtility]::UrlDecode(($url -replace "^/api/plan/", ""))
                    $result = Get-TaskPlan -TaskId $taskId
                    if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
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

                        $bType = if ($body.PSObject.Properties['type']) { $body.type } else { $null }
                        if (-not $bType) {
                            $content = @{ success = $false; error = "type is required" } | ConvertTo-Json -Compress
                        } else {
                            $bTaskId = if ($body.PSObject.Properties['task_id']) { $body.task_id } else { $null }
                            $bPrompt = if ($body.PSObject.Properties['prompt']) { $body.prompt } else { $null }
                            $bContinue = if ($body.PSObject.Properties['continue']) { $body.continue -eq $true } else { $false }
                            $bDescription = if ($body.PSObject.Properties['description']) { $body.description } else { $null }
                            $bModel = if ($body.PSObject.Properties['model']) { $body.model } else { $null }
                            # Start-ProcessLaunch auto-detects max_concurrent for workflow type
                            $result = Start-ProcessLaunch -Type $bType -TaskId $bTaskId -Prompt $bPrompt -Continue $bContinue -Description $bDescription -Model $bModel
                            $content = $result | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/process/kill-all" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $content = Stop-AllManagedProcesses | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/process/*/kill" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        $procId = ($url -replace "^/api/process/", "" -replace "/kill$", "")
                        $result = Stop-ManagedProcessById -ProcessId $procId
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Compress
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
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
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/process/*" -and $_ -notlike "/api/process/*/output" -and $_ -notlike "/api/process/*/stop" -and $_ -notlike "/api/process/*/kill" -and $_ -notlike "/api/process/*/whisper" -and $_ -ne "/api/process/launch" -and $_ -ne "/api/process/stop-by-type" -and $_ -ne "/api/process/kill-by-type" -and $_ -ne "/api/process/kill-all" } {
                    $contentType = "application/json; charset=utf-8"
                    $procId = $url -replace "^/api/process/", ""
                    $result = Get-ProcessDetail -ProcessId $procId
                    if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                    $content = $result | ConvertTo-Json -Depth 10 -Compress
                    break
                }

                # --- Workflows (installed manifests) ---

                "/api/workflows/installed" {
                    $contentType = "application/json; charset=utf-8"

                    # --- Response-level cache (10s TTL) ---
                    $cacheAge = [datetime]::UtcNow - $script:workflowsCache.timestamp
                    if ($script:workflowsCache.data -and $cacheAge -lt $script:workflowsCacheTTL) {
                        $content = $script:workflowsCache.data
                        break
                    }

                    $workflowsDir = Join-Path $botRoot "workflows"
                    $installedList = @()
                    $tasksDir = Join-Path $botRoot "workspace\tasks"

                    # --- Helper: cached manifest read (mtime-based) ---
                    function Get-CachedManifest {
                        param([string]$Dir)
                        $yamlPath = Join-Path $Dir "workflow.yaml"
                        if (-not (Test-Path $yamlPath)) { return $null }
                        $mtime = (Get-Item $yamlPath).LastWriteTimeUtc
                        $cached = $script:manifestCache[$Dir]
                        if ($cached -and $cached.lastModified -eq $mtime) {
                            return $cached.manifest
                        }
                        $m = Read-WorkflowManifest -WorkflowDir $Dir
                        $script:manifestCache[$Dir] = @{ manifest = $m; lastModified = $mtime }
                        return $m
                    }

                    # --- Helper: cached task file read (mtime-based) ---
                    function Get-CachedTaskWorkflow {
                        param([System.IO.FileInfo]$File)
                        $mtime = $File.LastWriteTimeUtc
                        $cached = $script:taskFileCache[$File.FullName]
                        if ($cached -and $cached.lastModified -eq $mtime) {
                            return $cached.workflow
                        }
                        try {
                            $tc = Get-Content $File.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                            $wf = if ($tc.workflow) { $tc.workflow } else { '' }
                        } catch { $wf = '' }
                        $script:taskFileCache[$File.FullName] = @{ workflow = $wf; lastModified = $mtime }
                        return $wf
                    }

                    # --- Scan all task files once, bucket by workflow ---
                    $tasksByWorkflow = @{}
                    foreach ($statusDir in @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped')) {
                        $dir = Join-Path $tasksDir $statusDir
                        if (-not (Test-Path $dir)) { continue }
                        Get-ChildItem $dir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                            $wf = Get-CachedTaskWorkflow -File $_
                            $key = if ($wf) { $wf } else { '__default__' }
                            if (-not $tasksByWorkflow.ContainsKey($key)) {
                                $tasksByWorkflow[$key] = @{ todo = 0; in_progress = 0; done = 0; total = 0 }
                            }
                            $tasksByWorkflow[$key]['total']++
                            switch ($statusDir) {
                                'todo'        { $tasksByWorkflow[$key]['todo']++ }
                                'in-progress' { $tasksByWorkflow[$key]['in_progress']++ }
                                'done'        { $tasksByWorkflow[$key]['done']++ }
                            }
                        }
                    }

                    # Get running processes to check workflow liveness
                    $runningProcs = @()
                    if (Test-Path $processesDir) {
                        $runningProcs = @(Get-ChildItem $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                            try { if (Test-Path $_.FullName) { Get-Content $_.FullName -Raw | ConvertFrom-Json } else { $null } } catch { $null }
                        } | Where-Object { $_ -and $_.status -in @('running', 'starting') })
                    }

                    # Collect installed workflow directory names for dedup check
                    $installedWfNames = @()
                    if (Test-Path $workflowsDir) {
                        $installedWfNames = @(Get-ChildItem $workflowsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                    }

                    # Include the "default" base workflow only if its name doesn't duplicate an installed one
                    $defaultManifest = Get-CachedManifest -Dir $botRoot
                    $defaultName = if ($defaultManifest) { $defaultManifest.name } else { 'default' }
                    $skipDefault = $installedWfNames -contains $defaultName

                    if (-not $skipDefault) {
                        $defaultTasks = if ($tasksByWorkflow.ContainsKey('__default__')) { $tasksByWorkflow['__default__'] } else { @{ todo = 0; in_progress = 0; done = 0; total = 0 } }

                        # Check for running analysis/execution processes (default workflow processes)
                        $defaultRunning = $runningProcs | Where-Object {
                            $_.type -in @('analysis', 'execution') -or ($_.type -eq 'task-runner' -and -not $_.description -like '*:*')
                        }
                        # Discover agents/skills from prompts directories
                        $defaultAgents = @()
                        $defaultSkills = @()
                        $agentsDir = Join-Path $botRoot "recipes\agents"
                        $skillsDir = Join-Path $botRoot "recipes\skills"
                        if (Test-Path $agentsDir) {
                            $defaultAgents = @(Get-ChildItem $agentsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                        }
                        if (Test-Path $skillsDir) {
                            $defaultSkills = @(Get-ChildItem $skillsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                        }

                        $installedList += @{
                            name = $defaultName
                            description = if ($defaultManifest) { "$($defaultManifest.description)" } else { 'Base dotbot framework — task execution, analysis, and product planning.' }
                            icon = if ($defaultManifest -and $defaultManifest['icon']) { "$($defaultManifest['icon'])" } else { 'terminal' }
                            version = if ($defaultManifest -and $defaultManifest['version']) { "$($defaultManifest['version'])" } else { '' }
                            author = if ($defaultManifest -and $defaultManifest['author']) { $defaultManifest['author'] } else { @{} }
                            rerun = if ($defaultManifest -and $defaultManifest['rerun']) { "$($defaultManifest['rerun'])" } else { '' }
                            license = if ($defaultManifest -and $defaultManifest['license']) { "$($defaultManifest['license'])" } else { '' }
                            tags = if ($defaultManifest -and $defaultManifest['tags']) { @($defaultManifest['tags'] | Where-Object { $_ }) } else { @('core', 'framework') }
                            categories = if ($defaultManifest -and $defaultManifest['categories']) { @($defaultManifest['categories'] | Where-Object { $_ }) } else { @() }
                            repository = if ($defaultManifest -and $defaultManifest['repository']) { "$($defaultManifest['repository'])" } else { '' }
                            homepage = if ($defaultManifest -and $defaultManifest['homepage']) { "$($defaultManifest['homepage'])" } else { '' }
                            agents = $defaultAgents
                            skills = $defaultSkills
                            tools = @()
                            status = if ($defaultRunning) { 'running' } else { 'idle' }
                            tasks = $defaultTasks
                            has_running_process = [bool]$defaultRunning
                            has_form = [bool]($defaultManifest -and $defaultManifest['form'])
                            is_default = $true
                        }
                    }

                    if (Test-Path $workflowsDir) {
                        Get-ChildItem $workflowsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                            $wfDir = $_.FullName
                            $wfName = $_.Name
                            $manifest = Get-CachedManifest -Dir $wfDir

                            # Task counts from pre-scanned bucket
                            $wfTasks = if ($tasksByWorkflow.ContainsKey($wfName)) { $tasksByWorkflow[$wfName] } else { @{ todo = 0; in_progress = 0; done = 0; total = 0 } }

                            # Check if a workflow process is running for this workflow
                            $hasRunning = $runningProcs | Where-Object {
                                $_.type -eq 'task-runner' -and $_.description -like "*$wfName*"
                            }

                            $installedList += @{
                                name = "$($manifest.name)"
                                description = "$($manifest.description)"
                                icon = if ($manifest['icon']) { "$($manifest['icon'])" } else { '' }
                                version = if ($manifest['version']) { "$($manifest['version'])" } else { '' }
                                author = if ($manifest['author']) { $manifest['author'] } else { @{} }
                                rerun = if ($manifest['rerun']) { "$($manifest['rerun'])" } else { '' }
                                license = if ($manifest['license']) { "$($manifest['license'])" } else { '' }
                                tags = if ($manifest['tags']) { @($manifest['tags'] | Where-Object { $_ }) } else { @() }
                                categories = if ($manifest['categories']) { @($manifest['categories'] | Where-Object { $_ }) } else { @() }
                                repository = if ($manifest['repository']) { "$($manifest['repository'])" } else { '' }
                                homepage = if ($manifest['homepage']) { "$($manifest['homepage'])" } else { '' }
                                agents = if ($manifest['agents'] -and $manifest['agents'].Count -gt 0) { @($manifest['agents'] | Where-Object { $_ }) } else {
                                    # Fallback: discover from prompts directory
                                    $wfAgentsDir = Join-Path $wfDir "recipes\agents"
                                    if (Test-Path $wfAgentsDir) { @(Get-ChildItem $wfAgentsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } else { @() }
                                }
                                skills = if ($manifest['skills'] -and $manifest['skills'].Count -gt 0) { @($manifest['skills'] | Where-Object { $_ }) } else {
                                    $wfSkillsDir = Join-Path $wfDir "recipes\skills"
                                    if (Test-Path $wfSkillsDir) { @(Get-ChildItem $wfSkillsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) } else { @() }
                                }
                                tools = if ($manifest['tools'] -and $manifest['tools'].Count -gt 0) { @($manifest['tools'] | Where-Object { $_ }) } else { @() }
                                status = if ($hasRunning) { 'running' } else { 'idle' }
                                tasks = $wfTasks
                                has_running_process = [bool]$hasRunning
                                has_form = [bool]($manifest['form'])
                            }
                        }
                    }

                    $content = @{ workflows = @($installedList) } | ConvertTo-Json -Depth 5 -Compress
                    # Store in response cache
                    $script:workflowsCache = @{ data = $content; timestamp = [datetime]::UtcNow }
                    break
                }

                { $_ -like "/api/workflows/*/run" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $wfName = ($url -replace "^/api/workflows/", "" -replace "/run$", "")
                            $wfDir = Join-Path $botRoot "workflows\$wfName"

                            if (-not (Test-Path $wfDir)) {
                                $statusCode = 404
                                $content = @{ success = $false; error = "Workflow not found: $wfName" } | ConvertTo-Json -Compress
                            } else {
                                $manifest = Read-WorkflowManifest -WorkflowDir $wfDir

                                # Clear tasks if rerun: fresh
                                if ($manifest.rerun -eq 'fresh') {
                                    $tasksBaseDir = Join-Path $botRoot "workspace\tasks"
                                    if (Test-Path $tasksBaseDir) {
                                        Clear-WorkflowTasks -TasksBaseDir $tasksBaseDir -WorkflowName $wfName
                                    }
                                }

                                # Create tasks from manifest
                                $createdTasks = @()
                                $taskDefs = @($manifest.tasks)
                                foreach ($td in $taskDefs) {
                                    if ($td -and $td['name']) {
                                        $result = New-WorkflowTask -ProjectBotDir $botRoot -WorkflowName $wfName -TaskDef $td
                                        $createdTasks += $result
                                    }
                                }

                                # Start-ProcessLaunch auto-detects max_concurrent for workflow type
                                $launchResult = Start-ProcessLaunch -Type 'task-runner' -Continue $true -Description "Workflow: $wfName" -WorkflowName $wfName
                                $content = @{
                                    success = $true
                                    workflow = $wfName
                                    tasks_created = $createdTasks.Count
                                    slots_launched = $launchResult.slots_launched
                                    process_id = $launchResult.process_id
                                } | ConvertTo-Json -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to run workflow: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/workflows/*/stop" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $wfName = ($url -replace "^/api/workflows/", "" -replace "/stop$", "")
                            # Find running workflow processes matching this workflow name
                            $stopped = 0
                            if (Test-Path $processesDir) {
                                Get-ChildItem $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                                    try {
                                        $proc = Get-Content $_.FullName -Raw | ConvertFrom-Json
                                        if ($proc.status -in @('running', 'starting') -and $proc.type -eq 'task-runner' -and $proc.description -like "*$wfName*") {
                                            # Create stop signal file
                                            $stopFile = Join-Path $processesDir "$($proc.id).stop"
                                            "stop" | Set-Content $stopFile -Encoding UTF8
                                            $stopped++
                                        }
                                    } catch { Write-BotLog -Level Debug -Message "Failed to read process file for stop signal" -Exception $_ }
                                }
                            }
                            $content = @{ success = $true; workflow = $wfName; stopped = $stopped } | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to stop workflow: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
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
                    $promptsDir = Join-Path $botRoot "recipes"
                    $directories = @()
                    $titleCase = (Get-Culture).TextInfo

                    if (Test-Path $promptsDir) {
                        $directories = @(Get-ChildItem -Path $promptsDir -Directory | ForEach-Object {
                            $name = $_.Name
                            @{
                                name = $name
                                displayName = $titleCase.ToTitleCase($name)
                                shortType = $name.Substring(0, [Math]::Min(3, $name.Length))
                            }
                        })
                    }

                    # Also scan workflow prompt directories
                    $workflowsDir = Join-Path $botRoot "workflows"
                    if (Test-Path $workflowsDir) {
                        Get-ChildItem $workflowsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                            $wfName = $_.Name
                            $wfPromptsDir = Join-Path $_.FullName "recipes"
                            if (Test-Path $wfPromptsDir) {
                                Get-ChildItem $wfPromptsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                                    $subName = $_.Name
                                    $directories += @{
                                        name = "$wfName/$subName"
                                        displayName = "$wfName / $($titleCase.ToTitleCase($subName))"
                                        shortType = "$($wfName)_$($subName.Substring(0, [Math]::Min(3, $subName.Length)))"
                                        workflow = $wfName
                                    }
                                }
                            }
                        }
                    }

                    $content = @{ directories = $directories } | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                # --- Decision API ---

                "/api/decisions" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "GET") {
                        $statusFilter = $request.QueryString['status']
                        $result = Get-DecisionList -StatusFilter $statusFilter
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 10 -Compress
                    } elseif ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                            $reader.Close()
                            $result = New-Decision -Body $body
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/decisions/*" -and $_ -notlike "/api/decisions/*/status" } {
                    $contentType = "application/json; charset=utf-8"
                    $decisionId = ($url -replace "^/api/decisions/", "").Trim('/')
                    if ($method -eq "GET") {
                        $result = Get-DecisionDetail -DecisionId $decisionId
                        if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                        $content = $result | ConvertTo-Json -Depth 10 -Compress
                    } elseif ($method -eq "PUT" -or $method -eq "PATCH") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                            $reader.Close()
                            $result = Update-Decision -DecisionId $decisionId -Body $body
                            if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                            $content = $result | ConvertTo-Json -Depth 5 -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/decisions/*/status" } {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $decisionId = ($url -replace "^/api/decisions/", "" -replace "/status$", "").Trim('/')
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $body = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                            $reader.Close()
                            $newStatus    = $body['status']
                            $supersededBy = $body['superseded_by']
                            $reason       = $body['reason']
                            if (-not $newStatus) {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Missing 'status' field" } | ConvertTo-Json -Compress
                            } else {
                                $result = Set-DecisionStatus -DecisionId $decisionId -NewStatus $newStatus -SupersededBy $supersededBy -Reason $reason
                                if ($result -is [hashtable] -and $result.ContainsKey('_statusCode')) { $statusCode = $result._statusCode; $result.Remove('_statusCode') }
                                $content = $result | ConvertTo-Json -Depth 5 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                # Workflow-scoped prompt directory list (e.g. /api/iwg-bs-scoring/agents/list)
                { $_ -match "^/api/([\w-]+)/([\w-]+)/list$" } {
                    $contentType = "application/json; charset=utf-8"
                    if ($url -match "^/api/([\w-]+)/([\w-]+)/list$") {
                        $wfName = $Matches[1]
                        $subDir = $Matches[2]
                    } else {
                        $wfName = "unknown"; $subDir = "unknown"
                    }
                    $wfPromptDir = Join-Path $botRoot "workflows\$wfName\recipes\$subDir"
                    if (Test-Path $wfPromptDir) {
                        # Reuse same grouping logic as Get-BotDirectoryList but from workflow path
                        $groups = [System.Collections.Generic.Dictionary[string, System.Collections.ArrayList]]::new()
                        $mdFiles = @(Get-ChildItem -Path $wfPromptDir -Filter "*.md" -Recurse -ErrorAction SilentlyContinue |
                            Where-Object { $_.FullName -notmatch '\\archived\\' })
                        foreach ($file in $mdFiles) {
                            if ($null -eq $file) { continue }
                            $relativePath = [System.IO.Path]::GetRelativePath($wfPromptDir, $file.FullName).Replace("\", "/")
                            $folder = if ($relativePath -like '*/*') { Split-Path $relativePath -Parent } else { "(root)" }
                            if (-not $groups.ContainsKey($folder)) { $groups[$folder] = [System.Collections.ArrayList]::new() }
                            [void]$groups[$folder].Add(@{ name = $file.BaseName; filename = $relativePath; basename = $file.BaseName })
                        }
                        $groupedItems = @($groups.Keys | Sort-Object | ForEach-Object {
                            $key = $_
                            $items = @($groups[$key] | ForEach-Object { [PSCustomObject]$_ } | Sort-Object -Property name)
                            [PSCustomObject]@{ folder = if ($key -eq '(root)') { '' } else { $key.Replace('\', '/') }; items = $items }
                        })
                        $content = @{ groups = $groupedItems } | ConvertTo-Json -Depth 5 -Compress
                    } else {
                        $statusCode = 404
                        $content = @{ success = $false; error = "Workflow prompt directory not found: $wfName/$subDir" } | ConvertTo-Json -Compress
                    }
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
                    $dirPath = Join-Path $botRoot "recipes\$dirName"

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
            Write-BotLog -Level Debug -Message ""
            Write-Status "[$timestamp] ERROR: $($_.Exception.Message)" -Type Error
            Write-BotLog -Level Error -Message "  Script: $($_.InvocationInfo.ScriptName)"
            Write-BotLog -Level Error -Message "  Line: $($_.InvocationInfo.ScriptLineNumber)"
            Write-BotLog -Level Error -Message "  Statement: $($_.InvocationInfo.Line.Trim())"
        }
        } # end CSRF-safe block

        # Send response (wrapped to handle client disconnects gracefully)
        try {
            if ($null -eq $content) {
                $content = "{}"
            }
            $response.StatusCode = $statusCode
            $response.ContentType = $contentType
            if ($url -eq "/" -or $contentType -like "text/html*") {
                $response.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
                $response.Headers['Pragma'] = 'no-cache'
                $response.Headers['Expires'] = '0'
            }
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
                Write-BotLog -Level Debug -Message ""
                Write-Status "Response write failed: $($_.Exception.Message)" -Type Warn
            }
            try { $response.Close() } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to close response" -Exception $_ }
        }
    }
} finally {
    # Stop file watchers
    try {
        Stop-FileWatchers
    } catch {
        Write-BotLog -Level Debug -Message "Cleanup: failed to stop file watchers" -Exception $_
    }

    # Safely stop listener if it's still running
    if ($listener -and $listener.IsListening) {
        try {
            $listener.Stop()
            $listener.Close()
        } catch {
            Write-BotLog -Level Debug -Message "Cleanup: failed to stop HTTP listener" -Exception $_
        }
    }
    Write-Status "Server stopped" -Type Warn
}
