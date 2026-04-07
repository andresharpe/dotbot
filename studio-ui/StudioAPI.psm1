<#
.SYNOPSIS
PowerShell module providing the Studio REST API.

.DESCRIPTION
Pure file-I/O HTTP API for workflow CRUD operations.
All YAML parsing/validation is handled client-side.
Designed to be imported by the standalone server.ps1 or
embedded into the full dotbot UI server in the future.

API namespace: /api/studio
#>

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------
$script:WorkflowsDir = $null
$script:StaticRoot   = $null
$script:LayoutFilename = '.studio-layout.json'

<#
.SYNOPSIS
Initialize the module with the workflows directory and static file root.
#>
function Initialize-StudioAPI {
    param(
        [Parameter(Mandatory)][string]$WorkflowsDir,
        [Parameter(Mandatory)][string]$StaticRoot
    )
    $script:WorkflowsDir = $WorkflowsDir
    $script:StaticRoot   = $StaticRoot

    if (-not (Test-Path $script:WorkflowsDir)) {
        New-Item -ItemType Directory -Force -Path $script:WorkflowsDir | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
function Get-SafeWorkflowDir {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Workflow name is required."
    }

    # Accept only simple directory names — no paths or traversal segments
    $safeName = [System.IO.Path]::GetFileName($Name)
    if ($safeName -ne $Name -or $safeName -eq '.' -or $safeName -eq '..') {
        throw "Invalid workflow name."
    }
    if ($safeName -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Invalid workflow name."
    }

    # Canonicalize and verify the result stays under WorkflowsDir
    $workflowsRoot = [System.IO.Path]::GetFullPath($script:WorkflowsDir)
    $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $workflowsRoot $safeName))
    $rootWithSep = $workflowsRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid workflow name."
    }

    return $candidatePath
}

function Test-WorkflowExists {
    param([string]$Name)
    $dir = Get-SafeWorkflowDir $Name
    return (Test-Path $dir) -and (Test-Path $dir -PathType Container)
}

function Send-Json {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [object]$Data,
        [int]$StatusCode = 200
    )
    $json = $Data | ConvertTo-Json -Depth 20 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
}

function Send-Text {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Text,
        [string]$ContentType = 'text/plain; charset=utf-8',
        [int]$StatusCode = 200
    )
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
}

function Send-Error {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$Message,
        [int]$StatusCode = 500
    )
    Send-Json -Response $Response -Data @{ error = $Message } -StatusCode $StatusCode
}

function Read-RequestBody {
    param([System.Net.HttpListenerRequest]$Request)
    $reader = [System.IO.StreamReader]::new($Request.InputStream, $Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Close()
    }
}

function Copy-DirectoryRecursive {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $items = Get-ChildItem -Path $Source
    foreach ($item in $items) {
        $destPath = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-DirectoryRecursive -Source $item.FullName -Destination $destPath
        } else {
            Copy-Item -Path $item.FullName -Destination $destPath -Force
        }
    }
}

# ---------------------------------------------------------------------------
# MIME type helper for static file serving
# ---------------------------------------------------------------------------
function Get-MimeType {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.png'  { 'image/png' }
        '.svg'  { 'image/svg+xml' }
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
}

# ---------------------------------------------------------------------------
# Route handler — called for every incoming request
# ---------------------------------------------------------------------------
<#
.SYNOPSIS
Handle a single HTTP request. Returns $true if handled, $false if not matched.
#>
function Invoke-StudioRequest {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context
    )

    $req = $Context.Request
    $res = $Context.Response
    $method = $req.HttpMethod
    $path = $req.Url.AbsolutePath

    # Add CORS headers
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')

    # Handle CORS preflight
    if ($method -eq 'OPTIONS') {
        $res.StatusCode = 204
        $res.Close()
        return $true
    }

    try {
        # ---------------------------------------------------------------
        # API routes: /api/studio/...
        # ---------------------------------------------------------------
        $apiPrefix = '/api/studio'

        if ($path -eq $apiPrefix -or $path -eq "$apiPrefix/") {
            # GET  /api/studio  — List all workflows (return folder + raw YAML)
            # POST /api/studio  — Create a new workflow
            if ($method -eq 'GET') {
                $result = @()
                $folders = Get-ChildItem -Path $script:WorkflowsDir -Directory -ErrorAction SilentlyContinue |
                           Sort-Object Name
                foreach ($folder in $folders) {
                    $yamlPath = Join-Path $folder.FullName 'workflow.yaml'
                    $yaml = $null
                    if (Test-Path $yamlPath) {
                        $yaml = Get-Content -Path $yamlPath -Raw -Encoding UTF8
                    }
                    $result += @{ folder = $folder.Name; yaml = $yaml }
                }
                Send-Json -Response $res -Data $result
                return $true
            }
            elseif ($method -eq 'POST') {
                $body = Read-RequestBody -Request $req | ConvertFrom-Json
                $name = $body.name
                if (-not $name -or -not $name.Trim()) {
                    Send-Error -Response $res -Message 'Workflow name is required' -StatusCode 400
                    return $true
                }
                if (Test-WorkflowExists $name) {
                    Send-Error -Response $res -Message "Workflow '$name' already exists" -StatusCode 409
                    return $true
                }
                $dir = Get-SafeWorkflowDir $name
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                New-Item -ItemType Directory -Force -Path (Join-Path $dir 'recipes' 'prompts') | Out-Null
                New-Item -ItemType Directory -Force -Path (Join-Path $dir 'recipes' 'agents') | Out-Null
                New-Item -ItemType Directory -Force -Path (Join-Path $dir 'recipes' 'skills') | Out-Null

                # Write skeleton workflow.yaml if yaml provided, otherwise use default
                if ($body.yaml) {
                    Set-Content -Path (Join-Path $dir 'workflow.yaml') -Value $body.yaml -Encoding UTF8 -NoNewline
                } else {
                    $skeleton = @"
name: $name
version: 1.0.0
description: ""
min_dotbot_version: 3.5.0
requires: {}
tasks: []
"@
                    Set-Content -Path (Join-Path $dir 'workflow.yaml') -Value $skeleton -Encoding UTF8 -NoNewline
                }
                Send-Json -Response $res -Data @{ success = $true; name = $name } -StatusCode 201
                return $true
            }
            else {
                Send-Error -Response $res -Message 'Method not allowed' -StatusCode 405
                return $true
            }
        }

        if ($path.StartsWith("$apiPrefix/")) {
            $remainder = $path.Substring($apiPrefix.Length + 1)  # strip "/api/studio/"
            $segments = $remainder.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)

            if ($segments.Count -eq 0) {
                Send-Error -Response $res -Message 'Not found' -StatusCode 404
                return $true
            }

            $workflowName = [System.Uri]::UnescapeDataString($segments[0])

            # -- Single-segment: /api/studio/:name --
            if ($segments.Count -eq 1) {
                if ($method -eq 'GET') {
                    # Read workflow: return raw YAML + layout + prompt files
                    if (-not (Test-WorkflowExists $workflowName)) {
                        Send-Error -Response $res -Message "Workflow '$workflowName' not found" -StatusCode 404
                        return $true
                    }
                    $dir = Get-SafeWorkflowDir $workflowName
                    $yamlPath = Join-Path $dir 'workflow.yaml'
                    $yaml = $null
                    if (Test-Path $yamlPath) {
                        $yaml = Get-Content -Path $yamlPath -Raw -Encoding UTF8
                    }

                    $layoutPath = Join-Path $dir $script:LayoutFilename
                    $layout = $null
                    if (Test-Path $layoutPath) {
                        $layout = Get-Content -Path $layoutPath -Raw -Encoding UTF8
                    }

                    $promptDir = Join-Path $dir 'recipes' 'prompts'
                    $promptFiles = @()
                    if (Test-Path $promptDir) {
                        $promptFiles = Get-ChildItem -Path $promptDir -File -ErrorAction SilentlyContinue |
                                       ForEach-Object { $_.Name } | Sort-Object
                    }

                    $agentsDir = Join-Path $dir 'recipes' 'agents'
                    $agentFiles = @()
                    if (Test-Path $agentsDir) {
                        $agentFiles = Get-ChildItem -Path $agentsDir -Directory -ErrorAction SilentlyContinue |
                                      ForEach-Object { $_.Name } | Sort-Object
                    }

                    $skillsDir = Join-Path $dir 'recipes' 'skills'
                    $skillFiles = @()
                    if (Test-Path $skillsDir) {
                        $skillFiles = Get-ChildItem -Path $skillsDir -Directory -ErrorAction SilentlyContinue |
                                      ForEach-Object { $_.Name } | Sort-Object
                    }

                    Send-Json -Response $res -Data @{
                        yaml        = $yaml
                        layout      = $layout
                        promptFiles = $promptFiles
                        agentFiles  = $agentFiles
                        skillFiles  = $skillFiles
                    }
                    return $true
                }
                elseif ($method -eq 'PUT') {
                    # Save workflow: receive raw YAML + optional layout
                    $body = Read-RequestBody -Request $req | ConvertFrom-Json
                    if (-not $body.yaml) {
                        Send-Error -Response $res -Message 'Request body must include yaml' -StatusCode 400
                        return $true
                    }
                    $dir = Get-SafeWorkflowDir $workflowName
                    if (-not (Test-Path $dir)) {
                        New-Item -ItemType Directory -Force -Path $dir | Out-Null
                    }
                    Set-Content -Path (Join-Path $dir 'workflow.yaml') -Value $body.yaml -Encoding UTF8 -NoNewline
                    if ($body.layout) {
                        Set-Content -Path (Join-Path $dir $script:LayoutFilename) -Value $body.layout -Encoding UTF8 -NoNewline
                    }
                    Send-Json -Response $res -Data @{ success = $true }
                    return $true
                }
                elseif ($method -eq 'DELETE') {
                    if (-not (Test-WorkflowExists $workflowName)) {
                        Send-Error -Response $res -Message "Workflow '$workflowName' not found" -StatusCode 404
                        return $true
                    }
                    $dir = Get-SafeWorkflowDir $workflowName
                    Remove-Item -Path $dir -Recurse -Force
                    Send-Json -Response $res -Data @{ success = $true }
                    return $true
                }
                else {
                    Send-Error -Response $res -Message 'Method not allowed' -StatusCode 405
                    return $true
                }
            }

            # -- /api/studio/:name/copy --
            if ($segments.Count -eq 2 -and $segments[1] -eq 'copy' -and $method -eq 'POST') {
                $body = Read-RequestBody -Request $req | ConvertFrom-Json
                $newName = $body.newName
                if (-not $newName -or -not $newName.Trim()) {
                    Send-Error -Response $res -Message 'New workflow name is required' -StatusCode 400
                    return $true
                }
                if (-not (Test-WorkflowExists $workflowName)) {
                    Send-Error -Response $res -Message "Source workflow '$workflowName' not found" -StatusCode 404
                    return $true
                }
                if (Test-WorkflowExists $newName) {
                    Send-Error -Response $res -Message "Workflow '$newName' already exists" -StatusCode 409
                    return $true
                }
                $srcDir = Get-SafeWorkflowDir $workflowName
                $destDir = Get-SafeWorkflowDir $newName
                Copy-DirectoryRecursive -Source $srcDir -Destination $destDir
                Send-Json -Response $res -Data @{ success = $true; name = $newName } -StatusCode 201
                return $true
            }

            # -- /api/studio/:name/layout --
            if ($segments.Count -eq 2 -and $segments[1] -eq 'layout' -and $method -eq 'PUT') {
                $bodyText = Read-RequestBody -Request $req
                $dir = Get-SafeWorkflowDir $workflowName
                if (-not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Force -Path $dir | Out-Null
                }
                Set-Content -Path (Join-Path $dir $script:LayoutFilename) -Value $bodyText -Encoding UTF8 -NoNewline
                Send-Json -Response $res -Data @{ success = $true }
                return $true
            }

            # -- /api/studio/:name/files[/...] --
            if ($segments.Count -ge 2 -and $segments[1] -eq 'files') {
                $dir = Get-SafeWorkflowDir $workflowName

                if ($segments.Count -eq 2 -and $method -eq 'GET') {
                    # List files in workflow root
                    $files = @()
                    if (Test-Path $dir) {
                        $items = Get-ChildItem -Path $dir -ErrorAction SilentlyContinue | Sort-Object Name
                        foreach ($item in $items) {
                            if ($item.PSIsContainer) {
                                $files += "$($item.Name)/"
                            } else {
                                $files += $item.Name
                            }
                        }
                    }
                    Send-Json -Response $res -Data $files
                    return $true
                }

                if ($segments.Count -ge 3) {
                    $filePath = ($segments[2..($segments.Count - 1)] | ForEach-Object { [System.Uri]::UnescapeDataString($_) }) -join '/'

                    # Reject path traversal attempts explicitly
                    if ($filePath -match '(^|[\/])\.\.([\/ ]|$)') {
                        Send-Error -Response $res -Message 'Invalid file path' -StatusCode 400
                        return $true
                    }

                    $fullPath = Join-Path $dir $filePath
                    # Canonicalize both paths for safe comparison
                    $canonicalDir = [System.IO.Path]::GetFullPath($dir + [System.IO.Path]::DirectorySeparatorChar)
                    $canonicalFull = [System.IO.Path]::GetFullPath($fullPath)

                    $pathComparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
                        [System.StringComparison]::OrdinalIgnoreCase
                    } else {
                        [System.StringComparison]::Ordinal
                    }

                    if (-not $canonicalFull.StartsWith($canonicalDir, $pathComparison)) {
                        Send-Error -Response $res -Message 'Invalid file path' -StatusCode 400
                        return $true
                    }

                    if ($method -eq 'GET') {
                        if (Test-Path $canonicalFull -PathType Leaf) {
                            $content = Get-Content -Path $canonicalFull -Raw -Encoding UTF8
                            Send-Text -Response $res -Text $content
                        } else {
                            Send-Error -Response $res -Message "File not found: $filePath" -StatusCode 404
                        }
                        return $true
                    }
                    elseif ($method -eq 'PUT') {
                        # Write/create a file
                        $parentDir = Split-Path $canonicalFull -Parent
                        if (-not (Test-Path $parentDir)) {
                            New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
                        }
                        $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                        $body = $reader.ReadToEnd()
                        $reader.Close()
                        Set-Content -Path $canonicalFull -Value $body -Encoding UTF8 -NoNewline
                        Send-Json -Response $res -Data @{ success = $true }
                        return $true
                    }
                    else {
                        Send-Error -Response $res -Message 'Method not allowed' -StatusCode 405
                        return $true
                    }
                }

                Send-Error -Response $res -Message 'Bad request' -StatusCode 400
                return $true
            }

            # Unmatched API path
            Send-Error -Response $res -Message 'Not found' -StatusCode 404
            return $true
        }

        # ---------------------------------------------------------------
        # Static file serving (for standalone mode)
        # ---------------------------------------------------------------
        if ($script:StaticRoot -and (Test-Path $script:StaticRoot)) {
            $filePath = $path.TrimStart('/', '\')
            if (-not $filePath -or $filePath -eq '') { $filePath = 'index.html' }

            # Reject path traversal in static file requests
            $pathSegments = $filePath -split '[/\\]'
            $isTraversal = $pathSegments -contains '..'

            if (-not $isTraversal) {
                $staticRootFull = [System.IO.Path]::GetFullPath($script:StaticRoot)
                $staticRootPrefix = $staticRootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
                $fullPath = [System.IO.Path]::GetFullPath((Join-Path $staticRootFull $filePath))

                if ($fullPath.StartsWith($staticRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path $fullPath -PathType Leaf)) {
                    $contentType = Get-MimeType $fullPath
                    $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
                    $res.StatusCode = 200
                    $res.ContentType = $contentType
                    $res.ContentLength64 = $fileBytes.Length
                    $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                    return $true
                }
            }

            # SPA fallback: serve index.html for non-API routes
            $indexPath = Join-Path ([System.IO.Path]::GetFullPath($script:StaticRoot)) 'index.html'
            if (Test-Path $indexPath -PathType Leaf) {
                $contentType = 'text/html; charset=utf-8'
                $fileBytes = [System.IO.File]::ReadAllBytes($indexPath)
                $res.StatusCode = 200
                $res.ContentType = $contentType
                $res.ContentLength64 = $fileBytes.Length
                $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
                return $true
            }
        }

        # Not handled
        return $false
    }
    catch {
        try {
            Send-Error -Response $res -Message $_.Exception.Message -StatusCode 500
        } catch {
            # Response may already be closed
        }
        return $true
    }
    finally {
        try { $res.Close() } catch { }
    }
}

Export-ModuleMember -Function Initialize-StudioAPI, Invoke-StudioRequest
