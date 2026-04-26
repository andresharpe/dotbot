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
# Pending-tasks runner identity
# ---------------------------------------------------------------------------
# The synthetic pending-tasks runner is identified by the description string
# assigned at launch. The stop endpoint and the running-process detector match
# task-runner processes by description prefix. Defining both here keeps run,
# stop, and detection in lockstep so a future wording change cannot silently
# break stop matching or the synthetic-row LED.
$pendingTasksDescription = 'Pending tasks (unfiltered)'
$pendingTasksDescriptionPrefix = 'Pending tasks*'

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
            try { if ($http.IsListening) { $http.Stop() } } catch { $null = $_ }
            try { $http.Close() } catch { $null = $_ }
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

# Test-ManifestCondition lives in ManifestCondition.psm1 and is needed by
# Get-WorkflowFormConfig (called from /api/info). workflow-manifest.ps1 imports
# it transitively, but dot-source + module scoping made the function invisible
# to handlers in some runs. Mirror task-get-next/script.ps1: explicit absolute
# path import + Get-Command assertion so failure is loud at startup, not 500
# per request.
$manifestConditionModule = Join-Path $botRoot "systems\runtime\modules\ManifestCondition.psm1"
if (-not (Get-Module ManifestCondition)) {
    Import-Module $manifestConditionModule -Force -DisableNameChecking -Global
}
if (-not (Get-Command Test-ManifestCondition -ErrorAction SilentlyContinue)) {
    throw "Test-ManifestCondition not available after importing $manifestConditionModule. Re-run 'pwsh install.ps1' (dotbot repo) or 'dotbot init' (target project) to refresh .bot/ files."
}

# Write selected port so go.ps1 (and other tools) can discover it
$Port.ToString() | Set-Content (Join-Path $controlDir "ui-port") -NoNewline -Encoding UTF8

$processesDir = Join-Path $controlDir "processes"
if (-not (Test-Path $processesDir)) { New-Item -Path $processesDir -ItemType Directory -Force | Out-Null }

# Import FileWatcher module for event-driven state updates
Import-Module (Join-Path $PSScriptRoot "modules\FileWatcher.psm1") -Force

$settingsLoaderModule = Join-Path $botRoot "systems\runtime\modules\SettingsLoader.psm1"
Import-Module $settingsLoaderModule -Force -DisableNameChecking -Global
if (-not (Get-Command Get-MergedSettings -ErrorAction SilentlyContinue)) {
    throw "Get-MergedSettings not available after importing $settingsLoaderModule. Re-run 'pwsh install.ps1' (dotbot repo) or 'dotbot init' (target project) to refresh .bot/ files."
}

# Import domain modules
Import-Module (Join-Path $PSScriptRoot "modules\GitAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\AetherAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ReferenceCache.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\SettingsAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ControlAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\ProductAPI.psm1") -Force
# TaskAPI intentionally exports Delete-RoadmapTask for UI/back-compat, so disable verb-name warnings here.
Import-Module (Join-Path $PSScriptRoot "modules\TaskAPI.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "modules\ProcessAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\StateBuilder.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\NotificationPoller.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\DecisionAPI.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\InboxWatcher.psm1") -Force

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
Initialize-InboxWatcher -BotRoot $botRoot

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
    Write-BotLog -Level Warn -Message "Static directory not found: $staticRoot"
}

# Pre-warm reference cache (makes first Workflow tab file click instant)
if (-not (Test-CacheValidity)) {
    Build-ReferenceCache | Out-Null
} else {
    Write-BotLog -Level Debug -ForceDisplay -Message "Reference cache is valid (skipping rebuild)"
}

# HTTP listener
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
Write-Phosphor "› Starting listener..." -Color Cyan -NoNewline
try {
    $listener.Start()
    Write-Phosphor " ✓" -Color Green
    Write-BotLog -Level Debug -ForceDisplay -Message "Press Ctrl+C to stop"
    Write-Separator -Width 70
} catch {
    Write-Phosphor " ✗" -Color Red
    if ($_.Exception.Message -match 'conflicts with an existing registration') {
        Write-BotLog -Level Error -Message "Port $Port is already in use. Try a different port: .\server.ps1 -Port <number>"
    } else {
        Write-BotLog -Level Error -Message "Error starting listener" -Exception $_
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns',
        '',
        Justification = 'The function versions multiple asset references within one HTML document.'
    )]
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

# ---------------------------------------------------------------------------
# Workflow form configuration helper
# ---------------------------------------------------------------------------
# Builds the kickstart dialog config for a workflow manifest. Used by both
# /api/info (active/default workflow) and /api/workflows/{name}/form
# (per-workflow lookup) so the modal can be re-populated when the user
# selects a workflow other than the alphabetically-first one.
function Get-WorkflowFormConfig {
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot,
        [Parameter(Mandatory = $false)]
        [object]$Manifest
    )

    $result = @{
        dialog = $null
        phases = $null
        mode   = $null
    }

    if (-not $Manifest) { return $result }

    $form = if ($Manifest -is [System.Collections.IDictionary]) { $Manifest['form'] } else { $Manifest.form }

    $formModes = $null
    if ($form) {
        $formModes = if ($form -is [System.Collections.IDictionary]) { $form['modes'] } else { $form.modes }
    }

    $kickstartDialog = $null
    $activeMode = $null

    if ($formModes -and $formModes.Count -gt 0) {
        foreach ($mode in $formModes) {
            $modeCondition = if ($mode -is [System.Collections.IDictionary]) { $mode['condition'] } else { $mode.condition }
            if (Test-ManifestCondition -ProjectRoot $ProjectRoot -Condition $modeCondition) {
                $activeMode = @{}
                foreach ($key in @('id', 'label', 'description', 'button', 'prompt_placeholder', 'show_interview', 'show_files', 'show_prompt', 'show_auto_workflow', 'default_prompt', 'hidden', 'interview_label', 'interview_hint')) {
                    $val = if ($mode -is [System.Collections.IDictionary]) { $mode[$key] } else { $mode.$key }
                    if ($null -ne $val) { $activeMode[$key] = $val }
                }
                $kickstartDialog = @{
                    description        = $activeMode['description']
                    show_prompt        = if ($null -ne $activeMode['show_prompt']) { [bool]$activeMode['show_prompt'] } else { $true }
                    show_files         = if ($null -ne $activeMode['show_files']) { [bool]$activeMode['show_files'] } else { $true }
                    show_interview     = if ($null -ne $activeMode['show_interview']) { [bool]$activeMode['show_interview'] } else { $true }
                    show_auto_workflow = if ($null -ne $activeMode['show_auto_workflow']) { [bool]$activeMode['show_auto_workflow'] } else { $true }
                    default_prompt     = $activeMode['default_prompt']
                }
                foreach ($key in @('interview_label', 'interview_hint', 'prompt_placeholder')) {
                    if ($activeMode[$key]) { $kickstartDialog[$key] = "$($activeMode[$key])" }
                }
                break
            }
        }
    } elseif ($form) {
        $formDesc = if ($form -is [System.Collections.IDictionary]) { $form['description'] } else { $form.description }
        if ($formDesc) {
            $formShowPrompt = if ($form -is [System.Collections.IDictionary]) { $form['show_prompt'] } else { $form.show_prompt }
            $formShowFiles = if ($form -is [System.Collections.IDictionary]) { $form['show_files'] } else { $form.show_files }
            $formShowInterview = if ($form -is [System.Collections.IDictionary]) { $form['show_interview'] } else { $form.show_interview }
            $formShowAutoWorkflow = if ($form -is [System.Collections.IDictionary]) { $form['show_auto_workflow'] } else { $form.show_auto_workflow }
            $formDefaultPrompt = if ($form -is [System.Collections.IDictionary]) { $form['default_prompt'] } else { $form.default_prompt }
            $kickstartDialog = @{
                description        = "$formDesc"
                show_prompt        = if ($null -ne $formShowPrompt) { [bool]$formShowPrompt } else { $true }
                show_files         = if ($null -ne $formShowFiles) { [bool]$formShowFiles } else { $true }
                show_interview     = if ($null -ne $formShowInterview) { [bool]$formShowInterview } else { $true }
                show_auto_workflow = if ($null -ne $formShowAutoWorkflow) { [bool]$formShowAutoWorkflow } else { $true }
                default_prompt     = "$formDefaultPrompt"
            }
            foreach ($key in @('interview_label', 'interview_hint', 'prompt_placeholder')) {
                $val = if ($form -is [System.Collections.IDictionary]) { $form[$key] } else { $form.$key }
                if ($val) { $kickstartDialog[$key] = "$val" }
            }
        }
    }

    $kickstartPhases = $null
    $tasks = if ($Manifest -is [System.Collections.IDictionary]) { $Manifest['tasks'] } else { $Manifest.tasks }
    if ($tasks -and $tasks.Count -gt 0) {
        $kickstartPhases = @(Convert-ManifestTasksToPhases -Tasks $tasks)
    }

    $result.dialog = $kickstartDialog
    $result.phases = $kickstartPhases
    $result.mode   = $activeMode
    return $result
}

# ---------------------------------------------------------------------------
# Project info payload (shared by /api/info and the bootstrap injection)
# ---------------------------------------------------------------------------
# Assembles the hashtable returned by /api/info. Factored out so the `/` route
# can inline the same data via Get-DotbotBootstrapPayload without duplicating
# executive-summary extraction, workflow-manifest loading, and kickstart
# dialog/phases resolution (issue #269).
function Get-ProjectInfoPayload {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    $projectName = Split-Path -Leaf $ProjectRoot

    # Executive summary — scan priority product docs first, then any remaining
    $executiveSummary = $null
    $productDir = Join-Path $BotRoot "workspace\product"
    if (Test-Path $productDir) {
        $priorityFiles = @('overview.md', 'mission.md', 'roadmap.md', 'roadmap-overview.md')
        $allFiles = @(Get-ChildItem -Path $productDir -Filter "*.md" -ErrorAction SilentlyContinue)
        $orderedFiles = @()
        foreach ($pf in $priorityFiles) {
            $match = $allFiles | Where-Object { $_.Name -eq $pf }
            if ($match) { $orderedFiles += $match }
        }
        foreach ($f in $allFiles) { if ($f.Name -notin $priorityFiles) { $orderedFiles += $f } }
        foreach ($file in $orderedFiles) {
            $docContent = Get-Content -Path $file.FullName -Raw
            if ($docContent -match '(?m)##? Executive Summary\s*\r?\n+\s*(.+)') {
                $executiveSummary = $matches[1].Trim()
                break
            }
        }
    }

    # Workflow name from the merged settings chain (default -> user -> control).
    $settingsData = $null
    $workflowName = $null
    try {
        $settingsData = Get-MergedSettings -BotRoot $BotRoot
        $workflowName = if ($settingsData.PSObject.Properties['workflow']) {
            $settingsData.workflow
        } elseif ($settingsData.PSObject.Properties['profile']) {
            $settingsData.profile
        } else {
            $null
        }
    } catch { Write-BotLog -Level Debug -Message "Failed to read settings for workflow name" -Exception $_ }

    # Kickstart dialog + phases + mode from the active workflow manifest.
    # Delegated to Get-WorkflowFormConfig so /api/workflows/{name}/form can
    # share the same logic for per-workflow lookups (issue #235).
    $kickstartDialog = $null
    $kickstartPhases = $null
    $activeMode = $null
    $manifest = Get-ActiveWorkflowManifest -BotRoot $BotRoot
    if ($manifest) {
        $formConfig = Get-WorkflowFormConfig -ProjectRoot $ProjectRoot -Manifest $manifest
        $kickstartDialog = $formConfig.dialog
        $kickstartPhases = $formConfig.phases
        $activeMode = $formConfig.mode
        if (-not $workflowName) { $workflowName = $manifest.name }
    }

    # Legacy settings.kickstart fallback removed in PR-3 (engine deletion).
    # The kickstart_* keys below are populated only from the active workflow.yaml
    # manifest. Frontend rename to workflow_* is a follow-up PR.

    # Installed workflow directory names
    $installedWorkflows = @()
    $workflowsDir = Join-Path $BotRoot "workflows"
    if (Test-Path $workflowsDir) {
        $installedWorkflows = @(Get-ChildItem $workflowsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }

    return @{
        project_name        = $projectName
        project_root        = $ProjectRoot
        full_path           = $ProjectRoot
        executive_summary   = $executiveSummary
        workflow            = $workflowName
        kickstart_dialog    = $kickstartDialog
        kickstart_phases    = $kickstartPhases
        kickstart_mode      = $activeMode
        installed_workflows = $installedWorkflows
    }
}

# ---------------------------------------------------------------------------
# Bootstrap payload (issue #269)
# ---------------------------------------------------------------------------
# Assembles the data inlined into index.html so the first paint already
# carries the correct project name and workflow badge — instead of flashing
# the hardcoded "autonomous" default while the browser fetches /api/info
# and /api/product/list. Scoped intentionally narrow: only the Overview
# executive-summary slot. Left Control panel and right Workflow accordion
# paint via the normal poll cycle.
function Get-DotbotBootstrapPayload {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    $info = Get-ProjectInfoPayload -ProjectRoot $ProjectRoot -BotRoot $BotRoot

    $productList = $null
    try { $productList = Get-ProductList } catch { Write-BotLog -Level Debug -Message "Bootstrap: Get-ProductList failed" -Exception $_ }

    return @{
        info        = $info
        productList = $productList
    }
}

# Encode JSON for safe embedding inside a <script type="application/json">
# element. HTML parsers treat </script (case-insensitive) as the close tag
# even inside a data script, so we escape the `</` sequence. ConvertTo-Json
# already handles quotes/backslashes.
function ConvertTo-InlineScriptJson {
    param([Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 6 -Compress
    return ($json -replace '</', '<\/')
}

# Inject the bootstrap JSON into the index.html template. The HTML keeps
# its hardcoded defaults (project badge "autonomous", empty workflow badge);
# the JS modules read window.__DOTBOT_BOOTSTRAP__ and update the DOM during
# the body fade-in (.theme-loaded transition), so no flash is visible.
function Apply-DotbotBootstrapHtml {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseApprovedVerbs',
        '',
        Justification = 'Apply- describes the operation; rename would churn callers.'
    )]
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][hashtable]$Payload
    )

    $json = ConvertTo-InlineScriptJson -Value $Payload
    return $Html.Replace('{{BOOTSTRAP_JSON}}', $json)
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $timestamp = Get-Date -Format 'HH:mm:ss'
        $method = $request.HttpMethod
        $url = $request.Url.LocalPath

        $script:requestCount++
        Write-BotLog -Level Debug -ForceDisplay -Message "[$timestamp] $method $url (#$script:requestCount)"

        # Route handler
        $statusCode = 200
        $contentType = "text/html; charset=utf-8"
        $content = ""
        $binaryContent = $null

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
                        $rawHtml = Get-Content $indexPath -Raw
                        $bootstrapPayload = $null
                        try {
                            $bootstrapPayload = Get-DotbotBootstrapPayload -ProjectRoot $projectRoot -BotRoot $botRoot
                        } catch {
                            Write-BotLog -Level Warn -Message "Bootstrap payload assembly failed — serving placeholders unfilled" -Exception $_
                        }
                        if ($bootstrapPayload) {
                            $rawHtml = Apply-DotbotBootstrapHtml -Html $rawHtml -Payload $bootstrapPayload
                        } else {
                            # Payload assembly failed — leave the JSON container empty so the
                            # reader skips, and the JS bootstrap falls back to its fetch path.
                            $rawHtml = $rawHtml.Replace('{{BOOTSTRAP_JSON}}', '')
                        }
                        $content = Add-StaticAssetVersions -Html $rawHtml
                    } else {
                        $statusCode = 404
                        $content = "index.html not found"
                    }
                    break
                }

                "/api/info" {
                    $contentType = "application/json; charset=utf-8"
                    $content = (Get-ProjectInfoPayload -ProjectRoot $projectRoot -BotRoot $botRoot) | ConvertTo-Json -Depth 5 -Compress
                    break
                }

                "/api/project/summary" {
                    # POST-only: this endpoint is side-effecting (reads project files and
                    # invokes the LLM provider, burning tokens/compute). Routing it through
                    # POST means the global CSRF check at the top of this handler rejects
                    # cross-origin requests that lack `X-Dotbot-Request: 1`. Browsers
                    # enforce CORS preflight for custom headers, so a malicious web page
                    # cannot silently trigger provider calls against localhost.
                    if ($method -ne "POST") {
                        $statusCode = 405
                        $contentType = "application/json; charset=utf-8"
                        $content = @{ success = $false; error = "Method not allowed; use POST" } | ConvertTo-Json -Compress
                        break
                    }
                    $contentType = "application/json; charset=utf-8"
                    try {
                        # Gather project documentation for context
                        $docContext = ""
                        $sources = @()
                        foreach ($docFile in @("CLAUDE.md", "README.md")) {
                            $docPath = Join-Path $projectRoot $docFile
                            if (Test-Path -LiteralPath $docPath) {
                                $raw = Get-Content -LiteralPath $docPath -Raw -ErrorAction SilentlyContinue
                                if ($raw) {
                                    $cap = [System.Math]::Min($raw.Length, 3000)
                                    $docContext += "`n--- $docFile ---`n$($raw.Substring(0, $cap))`n"
                                    $sources += $docFile
                                }
                            }
                        }
                        # Also check package.json / *.csproj for name+description
                        $pkgJson = Join-Path $projectRoot "package.json"
                        if (Test-Path -LiteralPath $pkgJson) {
                            $raw = Get-Content -LiteralPath $pkgJson -Raw -ErrorAction SilentlyContinue
                            if ($raw) {
                                $cap = [System.Math]::Min($raw.Length, 1500)
                                $docContext += "`n--- package.json ---`n$($raw.Substring(0, $cap))`n"
                                $sources += "package.json"
                            }
                        }
                        foreach ($csproj in @(Get-ChildItem -Path $projectRoot -Filter "*.csproj" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 2)) {
                            $raw = Get-Content -LiteralPath $csproj.FullName -Raw -ErrorAction SilentlyContinue
                            if ($raw) {
                                $raw = $raw.Substring(0, [System.Math]::Min($raw.Length, 1500))
                                $relPath = $csproj.FullName.Replace($projectRoot, "").TrimStart("\", "/")
                                $docContext += "`n--- $relPath ---`n$raw`n"
                                $sources += $relPath
                            }
                        }

                        if (-not $docContext) {
                            $content = @{ success = $false; error = "No project documentation found (no README.md, CLAUDE.md, or package.json)" } | ConvertTo-Json -Compress
                        } else {
                            # Import ProviderCLI and invoke a one-shot summary
                            $providerModule = Join-Path $botRoot "systems\runtime\ProviderCLI\ProviderCLI.psm1"
                            Import-Module $providerModule -Force -ErrorAction Stop

                            $summaryPrompt = @"
You are a project analyst. Based on the documentation below, write a concise project description (2-4 sentences) that covers:
- What the project is and what problem it solves
- Who it's for (target users)
- Key technologies used

Return ONLY the description paragraph, no headings, no bullet points, no markdown formatting. Write in third person.

$docContext
"@
                            $summary = $summaryPrompt | Invoke-Provider
                            if ($summary) {
                                $summary = $summary.Trim()
                                $content = @{ success = $true; summary = $summary; sources = $sources } | ConvertTo-Json -Depth 3 -Compress
                            } else {
                                $content = @{ success = $false; error = "Provider returned empty response" } | ConvertTo-Json -Compress
                            }
                        }
                    } catch {
                        $content = @{ success = $false; error = "Summary generation failed: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                    }
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
                            Write-BotLog -Level Info -Message "Git commit-and-push launched as process (PID: $($result.pid))"
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
                        Write-BotLog -Level Info -Message "Aether conduit discovered: $($result.conduit) (ID: $($result.id))"
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

                "/api/launch-studio" {
                    $contentType = "application/json; charset=utf-8"
                    if ($method -eq "POST") {
                        try {
                            $reader = New-Object System.IO.StreamReader($request.InputStream)
                            $bodyText = $reader.ReadToEnd()
                            $reader.Close()
                            $body = if ($bodyText) { $bodyText | ConvertFrom-Json } else { @{} }
                            $workflowName = if ($body.workflow) { $body.workflow } else { $null }

                            $dotbotBase = Join-Path $HOME 'dotbot'
                            $studioDir = Join-Path $dotbotBase 'studio-ui'
                            $serverScript = Join-Path $studioDir 'server.ps1'
                            $portFile = Join-Path $dotbotBase '.studio-port'

                            if (-not (Test-Path $serverScript)) {
                                $statusCode = 404
                                $content = @{ success = $false; error = 'Studio not installed. Run dotbot update.' } | ConvertTo-Json -Compress
                            } else {
                                $studioUrl = $null
                                # Check if studio is already running
                                if (Test-Path $portFile) {
                                    try {
                                        $portInfo = Get-Content $portFile -Raw | ConvertFrom-Json
                                        $proc = Get-Process -Id $portInfo.pid -ErrorAction SilentlyContinue
                                        if ($proc -and $proc.ProcessName -match 'pwsh|powershell') {
                                            $studioUrl = "http://localhost:$($portInfo.port)"
                                        } else {
                                            Remove-Item $portFile -Force -ErrorAction SilentlyContinue
                                        }
                                    } catch {
                                        Remove-Item $portFile -Force -ErrorAction SilentlyContinue
                                    }
                                }
                                # Start studio if not running
                                if (-not $studioUrl) {
                                    $launchArgs = @{ FilePath = 'pwsh'; ArgumentList = @('-NoProfile', '-File', $serverScript) }
                                    if ($IsWindows) { $launchArgs['WindowStyle'] = 'Hidden' }
                                    Start-Process @launchArgs
                                    # Wait for port file (up to 10 seconds)
                                    $waited = 0
                                    while ($waited -lt 10 -and -not (Test-Path $portFile)) {
                                        Start-Sleep -Milliseconds 500
                                        $waited += 0.5
                                    }
                                    if (Test-Path $portFile) {
                                        $portInfo = Get-Content $portFile -Raw | ConvertFrom-Json
                                        $studioUrl = "http://localhost:$($portInfo.port)"
                                    }
                                }
                                if ($studioUrl) {
                                    if ($workflowName) { $studioUrl += "?workflow=$([System.Uri]::EscapeDataString($workflowName))" }
                                    $content = @{ success = $true; url = $studioUrl } | ConvertTo-Json -Compress
                                } else {
                                    $statusCode = 500
                                    $content = @{ success = $false; error = 'Failed to start studio' } | ConvertTo-Json -Compress
                                }
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to launch studio: $($_.Exception.Message)" } | ConvertTo-Json -Compress
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
                            $result = Send-WhisperToInstance -InstanceType $body.instance_type -Message $body.message -Priority $(if ($body.priority) { $body.priority } else { "normal" })
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

                { $_ -like "/api/product/raw/*" } {
                    $docName = $url -replace "^/api/product/raw/", ""
                    $rawResult = Get-ProductDocumentRaw -Name $docName
                    if ($rawResult.Found) {
                        $contentType = $rawResult.MimeType
                        if ($rawResult.BinaryData) {
                            $binaryContent = $rawResult.BinaryData
                        } else {
                            $content = $rawResult.TextContent
                        }
                    } else {
                        $statusCode = 404
                        $contentType = "text/plain"
                        $content = "File not found"
                    }
                    break
                }

                { $_ -like "/api/product/*" -and $_ -ne "/api/product/list" -and $_ -ne "/api/product/preflight" -and $_ -ne "/api/product/analyse" -and $_ -notlike "/api/product/raw/*" } {
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
                            $content = Submit-TaskAnswer -TaskId $body.task_id -Answer $body.answer -CustomText $body.custom_text -Attachments $body.attachments -QuestionId $body.question_id | ConvertTo-Json -Depth 10 -Compress
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
                            $bWorkflowName = if ($body.PSObject.Properties['workflow_name']) { $body.workflow_name } else { $null }
                            # Start-ProcessLaunch auto-detects max_concurrent for workflow type
                            $result = Start-ProcessLaunch -Type $bType -TaskId $bTaskId -Prompt $bPrompt -Continue $bContinue -Description $bDescription -Model $bModel -WorkflowName $bWorkflowName
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

                # Workflow-agnostic task runner — picks any eligible todo task regardless
                # of `task.workflow`. Closes #301 (re-introduces the escape hatch removed
                # by PR #274 for orphan/untagged tasks).
                "/api/tasks/run-pending" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $launchResult = Start-ProcessLaunch -Type 'task-runner' -Continue $true -Description $pendingTasksDescription
                            $content = $launchResult | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to launch pending-tasks runner: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                "/api/tasks/stop-pending" {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $stopped = 0
                            if (Test-Path $processesDir) {
                                Get-ChildItem $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                                    try {
                                        $proc = Get-Content $_.FullName -Raw | ConvertFrom-Json
                                        if ($proc.status -in @('running', 'starting') -and $proc.type -eq 'task-runner' -and "$($proc.description)" -like $pendingTasksDescriptionPrefix) {
                                            $stopFile = Join-Path $processesDir "$($proc.id).stop"
                                            "stop" | Set-Content $stopFile -Encoding UTF8
                                            $stopped++
                                        }
                                    } catch { Write-BotLog -Level Debug -Message "Failed to read process file for pending-tasks stop signal" -Exception $_ }
                                }
                            }
                            $content = @{ success = $true; stopped = $stopped } | ConvertTo-Json -Compress
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to stop pending-tasks runner: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
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
                                    # Save any per-question attachment files and replace base64 with paths
                                    $allowedAttachExtensions = @('.md', '.docx', '.xlsx', '.pdf', '.txt', '.png', '.jpg', '.jpeg')
                                    $productDir = Join-Path $botRoot "workspace\product"
                                    $processedAnswers = @()
                                    foreach ($ans in @($body.answers)) {
                                        $ansObj = @{
                                            question_id = $ans.question_id
                                            question    = $ans.question
                                            answer      = $ans.answer
                                        }
                                        if ($ans.attachments -and @($ans.attachments).Count -gt 0) {
                                            $attachMeta = @()
                                            $attachDir = Join-Path $productDir "attachments\$($ans.question_id)"
                                            if (-not (Test-Path $attachDir)) {
                                                New-Item -ItemType Directory -Force -Path $attachDir | Out-Null
                                            }
                                            foreach ($att in @($ans.attachments)) {
                                                $safeName = [System.IO.Path]::GetFileName($att.name)
                                                $ext = [System.IO.Path]::GetExtension($safeName).ToLowerInvariant()
                                                if ($ext -notin $allowedAttachExtensions) { continue }
                                                try {
                                                    $bytes = [System.Convert]::FromBase64String($att.content)
                                                    $filePath = Join-Path $attachDir $safeName
                                                    [System.IO.File]::WriteAllBytes($filePath, $bytes)
                                                    $relPath = ".bot/workspace/product/attachments/$($ans.question_id)/$safeName"
                                                    $attachMeta += @{
                                                        name = $safeName
                                                        size = $att.size
                                                        path = $relPath
                                                    }
                                                } catch {
                                                    Write-BotLog -Level 'Warn' -Message "Failed to save kickstart attachment '$safeName'" -Exception $_
                                                }
                                            }
                                            if ($attachMeta.Count -gt 0) {
                                                $ansObj['attachments'] = $attachMeta
                                                # Embed paths in answer text so the AI can locate the files
                                                $pathList = ($attachMeta | ForEach-Object { $_.path }) -join ', '
                                                $pathNote = "Attached: $pathList"
                                                $ansObj['answer'] = if ($ansObj['answer']) { "$($ansObj['answer'])`n$pathNote" } else { $pathNote }
                                            }
                                        }
                                        $processedAnswers += $ansObj
                                    }

                                    # Write answers file that the interview loop is polling for
                                    $answersData = @{
                                        skipped = ($body.skipped -eq $true)
                                        answers = $processedAnswers
                                        submitted_at = (Get-Date).ToUniversalTime().ToString("o")
                                    }
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

                    # Also skip default when an overlay workflow was applied during init
                    if (-not $skipDefault) {
                        $mergedWf = Get-MergedSettings -BotRoot $botRoot
                        $activeWf = if ($mergedWf.PSObject.Properties['workflow']) { $mergedWf.workflow }
                                    elseif ($mergedWf.PSObject.Properties['profile']) { $mergedWf.profile }
                                    else { $null }
                        if ($activeWf -and $activeWf -ne 'default' -and $activeWf -ne $defaultName) {
                            $skipDefault = $true
                        }
                    }

                    if (-not $skipDefault) {
                        # The default workflow's runner is filtered to workflow=default, so
                        # untagged tasks (the __default__ bucket) belong on a separate
                        # synthetic "pending-tasks" row — see the append below — not here.
                        $defaultTasks = if ($tasksByWorkflow.ContainsKey($defaultName)) { $tasksByWorkflow[$defaultName] } else { @{ todo = 0; in_progress = 0; done = 0; total = 0 } }

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

                    # Synthetic "pending-tasks" row — exposes any todo/in-progress tasks that
                    # have no `workflow` field (orphans from workflow phases or manual creation).
                    # Without this, no UI affordance can launch a runner for them. See #324.
                    $pendingBucket = if ($tasksByWorkflow.ContainsKey('__default__')) { $tasksByWorkflow['__default__'] } else { @{ todo = 0; in_progress = 0; done = 0; total = 0 } }
                    $pendingRunning = $runningProcs | Where-Object {
                        $_.type -eq 'task-runner' -and "$($_.description)" -like $pendingTasksDescriptionPrefix
                    }
                    if ($pendingBucket.todo -gt 0 -or $pendingBucket.in_progress -gt 0 -or $pendingRunning) {
                        $installedList += @{
                            name = 'pending-tasks'
                            description = 'Untagged tasks in the queue. Runs a generic task-runner.'
                            icon = 'list'
                            version = ''
                            author = @{}
                            rerun = ''
                            license = ''
                            tags = @('core')
                            categories = @()
                            repository = ''
                            homepage = ''
                            agents = @()
                            skills = @()
                            tools = @()
                            status = if ($pendingRunning) { 'running' } else { 'idle' }
                            tasks = $pendingBucket
                            has_running_process = [bool]$pendingRunning
                            has_form = $false
                            is_synthetic = $true
                        }
                    }

                    $content = @{ workflows = @($installedList) } | ConvertTo-Json -Depth 5 -Compress
                    # Store in response cache
                    $script:workflowsCache = @{ data = $content; timestamp = [datetime]::UtcNow }
                    break
                }

                { $_ -like "/api/workflows/*/form" } {
                    if ($method -eq "GET") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $wfName = ($url -replace "^/api/workflows/", "" -replace "/form$", "")
                            # Validate workflow name to prevent path traversal
                            if ($wfName -notmatch '^[a-zA-Z0-9_-]+$') {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Invalid workflow name: $wfName" } | ConvertTo-Json -Compress
                                break
                            }

                            # Resolve workflow directory: installed workflows live at .bot/workflows/{name}/,
                            # the default/profile workflow at .bot/ root.
                            $wfDir = Join-Path $botRoot "workflows\$wfName"
                            if (-not (Test-Path $wfDir)) {
                                $defaultYaml = Join-Path $botRoot "workflow.yaml"
                                $defaultManifest = if (Test-Path -LiteralPath $defaultYaml) { Read-WorkflowManifest -WorkflowDir $botRoot } else { $null }
                                $defaultName = if ($defaultManifest -and $defaultManifest.name) { $defaultManifest.name } else { 'default' }
                                if ($wfName -eq $defaultName -or $wfName -eq 'default') {
                                    $wfDir = $botRoot
                                }
                            }

                            if (-not (Test-Path (Join-Path $wfDir "workflow.yaml"))) {
                                $statusCode = 404
                                $content = @{ success = $false; error = "Workflow not found: $wfName" } | ConvertTo-Json -Compress
                            } else {
                                $manifest = Read-WorkflowManifest -WorkflowDir $wfDir
                                $formConfig = Get-WorkflowFormConfig -ProjectRoot $projectRoot -Manifest $manifest
                                $content = @{
                                    success = $true
                                    workflow = $wfName
                                    dialog = $formConfig.dialog
                                    phases = $formConfig.phases
                                    mode = $formConfig.mode
                                } | ConvertTo-Json -Depth 5 -Compress
                            }
                        } catch {
                            $statusCode = 500
                            $content = @{ success = $false; error = "Failed to load workflow form: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        }
                    } else {
                        $statusCode = 405
                        $content = @{ success = $false; error = "Method not allowed" } | ConvertTo-Json -Compress
                    }
                    break
                }

                { $_ -like "/api/workflows/*/run" } {
                    if ($method -eq "POST") {
                        $contentType = "application/json; charset=utf-8"
                        try {
                            $wfName = ($url -replace "^/api/workflows/", "" -replace "/run$", "")
                            # Validate workflow name to prevent path traversal
                            if ($wfName -notmatch '^[a-zA-Z0-9_-]+$') {
                                $statusCode = 400
                                $content = @{ success = $false; error = "Invalid workflow name: $wfName" } | ConvertTo-Json -Compress
                                break
                            }
                            # Default workflow lives at .bot/ root; installed workflows at .bot/workflows/{name}/
                            $wfDir = Join-Path $botRoot "workflows\$wfName"
                            if (-not (Test-Path $wfDir)) {
                                # Inline manifest read — Get-CachedManifest may not be defined yet
                                $defaultYaml = Join-Path $botRoot "workflow.yaml"
                                $defaultManifest = if (Test-Path -LiteralPath $defaultYaml) { Read-WorkflowManifest -WorkflowDir $botRoot } else { $null }
                                $defaultName = if ($defaultManifest -and $defaultManifest.name) { $defaultManifest.name } else { 'default' }
                                if ($wfName -eq $defaultName -or $wfName -eq 'default') {
                                    $wfDir = $botRoot
                                    $wfName = $defaultName
                                }
                            }

                            if (-not (Test-Path (Join-Path $wfDir "workflow.yaml"))) {
                                $statusCode = 404
                                $content = @{ success = $false; error = "Workflow not found: $wfName" } | ConvertTo-Json -Compress
                            } else {
                                # Read optional form data (prompt, files) from request body
                                $body = $null
                                try {
                                    $reader = New-Object System.IO.StreamReader($request.InputStream)
                                    $rawBody = $reader.ReadToEnd()
                                    $reader.Close()
                                    if ($rawBody) { $body = $rawBody | ConvertFrom-Json }
                                } catch {
                                    if ($rawBody) {
                                        $statusCode = 400
                                        $content = @{ success = $false; error = "Invalid JSON in request body: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                                        break
                                    }
                                    $body = $null
                                }

                                # Save briefing files if provided
                                $failedFiles = 0
                                if ($body -and $body.files) {
                                    $briefingDir = Join-Path $botRoot "workspace\product\briefing"
                                    if (-not (Test-Path $briefingDir)) {
                                        New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null
                                    }
                                    foreach ($file in @($body.files)) {
                                        if (-not $file -or -not $file.name -or -not $file.content) { continue }
                                        # Sanitize filename: strip path components, remove invalid chars, handle Windows reserved names
                                        $safeName = [System.IO.Path]::GetFileName([string]$file.name)
                                        $safeName = $safeName.Trim().TrimEnd('.', ' ')
                                        $invalidCharsPattern = [Regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
                                        $safeName = [Regex]::Replace($safeName, "[$invalidCharsPattern]", '_')
                                        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "upload.bin" }
                                        if ($safeName -match '^(?i:(con|prn|aux|nul|com[1-9]|lpt[1-9]))(\..*)?$') { $safeName = "_$safeName" }
                                        try {
                                            $decoded = [Convert]::FromBase64String([string]$file.content)
                                            $filePath = Join-Path $briefingDir $safeName
                                            [System.IO.File]::WriteAllBytes($filePath, $decoded)
                                        } catch {
                                            $failedFiles++
                                            continue
                                        }
                                    }
                                }

                                # Save user prompt for task prompt injection (canonical path used by ProductAPI/runtime)
                                if ($body -and $body.prompt) {
                                    $launchersDir = Join-Path $botRoot ".control\launchers"
                                    if (-not (Test-Path $launchersDir)) {
                                        New-Item -Path $launchersDir -ItemType Directory -Force | Out-Null
                                    }
                                    $body.prompt | Set-Content -Path (Join-Path $launchersDir "workflow-launch-prompt.txt") -Encoding UTF8 -NoNewline
                                }

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
                                # NOTE: do not assign to $response here — that variable holds the HttpListenerResponse
                                # used by the outer write loop. Shadowing it causes the response to never be sent.
                                $runResponse = @{
                                    success = $true
                                    workflow = $wfName
                                    tasks_created = $createdTasks.Count
                                    slots_launched = $launchResult.slots_launched
                                    process_id = $launchResult.process_id
                                }
                                if ($failedFiles -gt 0) { $runResponse.files_failed = $failedFiles }
                                $content = $runResponse | ConvertTo-Json -Compress
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
                            ".svg" { "image/svg+xml" }
                            ".ico" { "image/x-icon" }
                            ".png" { "image/png" }
                            default { "application/octet-stream" }
                        }
                        $isBinary = $extension -in @('.ico', '.png', '.gif', '.jpg', '.jpeg', '.woff', '.woff2')
                        if ($isBinary) {
                            $binaryContent = [System.IO.File]::ReadAllBytes($filePath)
                        } else {
                            $content = Get-Content -LiteralPath $filePath -Raw
                        }
                    } else {
                        $statusCode = 404
                        $content = "Not found: $url"
                    }
                }
            }
        } catch {
            $statusCode = 500
            $content = "Server error: $($_.Exception.Message)"
            Write-BotLog -Level Error -Message "Route handler error: $($_.Exception.Message)" -Exception $_
        }
        } # end CSRF-safe block

        # Send response (wrapped to handle client disconnects gracefully)
        try {
            if ($null -eq $content) {
                $content = "{}"
            }
            $response.StatusCode = $statusCode
            $response.ContentType = $contentType
            if ($url -eq "/" -or $contentType -like "text/html*" -or $contentType -like "application/javascript*") {
                $response.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
                $response.Headers['Pragma'] = 'no-cache'
                $response.Headers['Expires'] = '0'
            }
            if ($null -ne $binaryContent) {
                $buffer = $binaryContent
            } else {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($content)
            }
            $response.ContentLength64 = $buffer.Length
            if ($null -ne $response.OutputStream) {
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
                $response.Close()
            }
        } catch {
            if ($_.Exception.Message -match "network name is no longer available|connection was forcibly closed|broken pipe") {
                # Silent handling for expected disconnects
            } else {
                Write-BotLog -Level Warn -Message "Response write failed" -Exception $_
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

    # Stop inbox watchers
    try {
        Stop-InboxWatcher
    } catch {
        Write-BotLog -Level Warn -Message "Cleanup: failed to stop inbox watcher: $_"
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
    Write-BotLog -Level Info -Message "Server stopped"
}
