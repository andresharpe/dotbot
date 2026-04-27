<#
.SYNOPSIS
Product document management API module

.DESCRIPTION
Provides product document listing, retrieval, workflow-launch (Claude-driven doc creation),
and roadmap planning functionality.
Extracted from server.ps1 for modularity.
#>

if (-not (Get-Module SettingsLoader)) {
    Import-Module (Join-Path $PSScriptRoot "..\..\runtime\modules\SettingsLoader.psm1") -DisableNameChecking -Global
}

$script:Config = @{
    BotRoot = $null
    ControlDir = $null
}
$script:McpListCache = $null

function Initialize-ProductAPI {
    param(
        [Parameter(Mandatory)] [string]$BotRoot,
        [Parameter(Mandatory)] [string]$ControlDir
    )
    $script:Config.BotRoot = $BotRoot
    $script:Config.ControlDir = $ControlDir
}

function Resolve-ProductDocumentInfo {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo]$File,
        [Parameter(Mandatory)] [string]$ProductDir
    )

    $relativePath = [System.IO.Path]::GetRelativePath($ProductDir, $File.FullName) -replace '\\', '/'
    $ext = $File.Extension.ToLowerInvariant()
    $isMd = $ext -eq '.md'
    $isJson = $ext -eq '.json'
    $isTxt = $ext -eq '.txt'
    $isImage = $ext -in @('.png', '.jpg', '.jpeg', '.gif', '.svg')
    # Only strip .md; all other types keep extension to avoid name collisions
    $name = if ($isMd) { $relativePath -replace '\.md$', '' } else { $relativePath }
    $segments = @($name -split '/')

    $type = if ($isMd) { 'md' }
            elseif ($isJson) { 'json' }
            elseif ($isTxt) { 'txt' }
            elseif ($isImage) { 'image' }
            else { 'binary' }

    return [PSCustomObject]@{
        Name = $name
        Filename = $relativePath
        Depth = [Math]::Max(0, $segments.Count - 1)
        BaseName = $File.BaseName
        Type = $type
        Size = $File.Length
    }
}

function Resolve-ProductDocumentPath {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ProductDir
    )

    $decodedName = [System.Web.HttpUtility]::UrlDecode($Name)
    if ([string]::IsNullOrWhiteSpace($decodedName)) {
        return $null
    }

    $normalizedName = ($decodedName.Trim() -replace '\\', '/').TrimStart('/')

    # Determine extension search order based on the requested name.
    # If the request explicitly ends with .json, resolve only .json (honor the caller's intent).
    # If it ends with .md, strip the extension and try .md first then .json.
    # Otherwise, try .md first then .json (default priority).
    $explicitJson = $false
    $explicitDirect = $false
    if ($normalizedName.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedName = $normalizedName.Substring(0, $normalizedName.Length - 3)
    } elseif ($normalizedName.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
        $explicitJson = $true
        # Keep normalizedName as-is (includes .json) since JSON names retain their extension
    } elseif ($normalizedName -match '\.(txt|png|jpe?g|gif|svg)$') {
        $explicitDirect = $true
        # Viewable non-md/json types keep their extension and resolve directly
    }

    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        return $null
    }

    $relativePath = ($normalizedName -split '/') -join [System.IO.Path]::DirectorySeparatorChar

    try {
        $productDirFull = [System.IO.Path]::GetFullPath($ProductDir)
    } catch {
        return $null
    }

    $productPrefix = if ($productDirFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $productDirFull
    } else {
        "$productDirFull$([System.IO.Path]::DirectorySeparatorChar)"
    }

    if ($explicitJson -or $explicitDirect) {
        # Explicit extension request — resolve directly without extension loop
        $candidatePath = Join-Path $ProductDir $relativePath
        try {
            $candidateFull = [System.IO.Path]::GetFullPath($candidatePath)
        } catch {
            return $null
        }
        if ($candidateFull -notlike "$productPrefix*") {
            return $null
        }
        if (Test-Path -LiteralPath $candidateFull) {
            return @{
                Name = $normalizedName
                FullPath = $candidateFull
            }
        }
        return @{
            Name = $normalizedName
            FullPath = $candidateFull
        }
    }

    # Try extensions in order: .md then .json
    foreach ($ext in @('.md', '.json')) {
        $candidatePath = Join-Path $ProductDir "$relativePath$ext"
        try {
            $candidateFull = [System.IO.Path]::GetFullPath($candidatePath)
        } catch {
            continue
        }

        if ($candidateFull -notlike "$productPrefix*") {
            continue
        }

        if (Test-Path -LiteralPath $candidateFull) {
            # For .json matches, include extension in the returned name
            $returnName = if ($ext -eq '.json') { "$normalizedName.json" } else { $normalizedName }
            return @{
                Name = $returnName
                FullPath = $candidateFull
            }
        }
    }

    # Fallback: return .md path so Get-ProductDocument can return a 404
    $fallbackPath = Join-Path $ProductDir "$relativePath.md"
    try {
        $fallbackFull = [System.IO.Path]::GetFullPath($fallbackPath)
    } catch {
        return $null
    }

    if ($fallbackFull -notlike "$productPrefix*") {
        return $null
    }

    return @{
        Name = $normalizedName
        FullPath = $fallbackFull
    }
}

function Get-ProductList {
    $botRoot = $script:Config.BotRoot
    $productDir = Join-Path $botRoot "workspace\product"
    $docs = @()

    if (Test-Path $productDir) {
        $allFiles = @(Get-ChildItem -Path $productDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' })

        # Define priority order for product files
        $priorityOrder = [System.Collections.Generic.List[string]]@(
            'mission',
            'entity-model',
            'tech-stack',
            'roadmap',
            'roadmap-overview'
        )

        # Separate files into priority root docs, other root docs, and nested docs
        $priorityFiles = [System.Collections.ArrayList]@()
        $rootFiles = [System.Collections.ArrayList]@()
        $nestedFiles = [System.Collections.ArrayList]@()

        foreach ($file in $allFiles) {
            if ($null -eq $file) { continue }

            $doc = Resolve-ProductDocumentInfo -File $file -ProductDir $productDir
            $priorityIndex = if ($doc.Depth -eq 0 -and $doc.Type -eq 'md') { $priorityOrder.IndexOf($file.BaseName) } else { -1 }

            if ($priorityIndex -ge 0) {
                [void]$priorityFiles.Add([PSCustomObject]@{
                    Doc = $doc
                    Priority = $priorityIndex
                })
            } elseif ($doc.Depth -eq 0) {
                [void]$rootFiles.Add($doc)
            } else {
                [void]$nestedFiles.Add($doc)
            }
        }

        if ($priorityFiles.Count -gt 0) {
            $priorityFiles = @($priorityFiles | Sort-Object -Property Priority)
        }
        if ($rootFiles.Count -gt 0) {
            $rootFiles = @($rootFiles | Sort-Object -Property Filename)
        }
        if ($nestedFiles.Count -gt 0) {
            $nestedFiles = @($nestedFiles | Sort-Object -Property Filename)
        }

        foreach ($pf in $priorityFiles) {
            if ($null -eq $pf) { continue }
            $docs += @{
                name = $pf.Doc.Name
                filename = $pf.Doc.Filename
                depth = $pf.Doc.Depth
                type = $pf.Doc.Type
                size = $pf.Doc.Size
            }
        }
        foreach ($file in $rootFiles) {
            if ($null -eq $file) { continue }
            $docs += @{
                name = $file.Name
                filename = $file.Filename
                depth = $file.Depth
                type = $file.Type
                size = $file.Size
            }
        }
        foreach ($file in $nestedFiles) {
            if ($null -eq $file) { continue }
            $docs += @{
                name = $file.Name
                filename = $file.Filename
                depth = $file.Depth
                type = $file.Type
                size = $file.Size
            }
        }
    }

    return @{ docs = $docs }
}

function Get-ProductDocument {
    param(
        [Parameter(Mandatory)] [string]$Name
    )
    $botRoot = $script:Config.BotRoot
    $productDir = Join-Path $botRoot "workspace\product"
    $resolvedDoc = Resolve-ProductDocumentPath -Name $Name -ProductDir $productDir

    if ($resolvedDoc -and (Test-Path -LiteralPath $resolvedDoc.FullPath)) {
        $docContent = Get-Content -LiteralPath $resolvedDoc.FullPath -Raw
        return @{
            success = $true
            name = $resolvedDoc.Name
            content = $docContent
        }
    } else {
        return @{
            _statusCode = 404
            success = $false
            error = "Document not found: $Name"
        }
    }
}

function Get-ProductDocumentRaw {
    param(
        [Parameter(Mandatory)] [string]$Name
    )
    $botRoot = $script:Config.BotRoot
    $productDir = Join-Path $botRoot "workspace\product"
    $resolvedDoc = Resolve-ProductDocumentPath -Name $Name -ProductDir $productDir

    if (-not $resolvedDoc -or -not (Test-Path -LiteralPath $resolvedDoc.FullPath)) {
        return @{ Found = $false }
    }

    $ext = [System.IO.Path]::GetExtension($resolvedDoc.FullPath).ToLowerInvariant()
    $mimeType = switch ($ext) {
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.gif'  { 'image/gif' }
        '.svg'  { 'image/svg+xml' }
        '.txt'  { 'text/plain; charset=utf-8' }
        default { 'application/octet-stream' }
    }

    $isBinary = $ext -in @('.png', '.jpg', '.jpeg', '.gif')
    if ($isBinary) {
        return @{
            Found = $true
            MimeType = $mimeType
            BinaryData = [System.IO.File]::ReadAllBytes($resolvedDoc.FullPath)
        }
    } else {
        return @{
            Found = $true
            MimeType = $mimeType
            TextContent = (Get-Content -LiteralPath $resolvedDoc.FullPath -Raw)
        }
    }
}

function Get-PreflightResults {
    $botRoot = $script:Config.BotRoot
    $projectRoot = Split-Path -Parent $botRoot

    # Load manifest helpers
    . "$BotRoot/core/runtime/modules/workflow-manifest.ps1"

    # Try manifest first
    $preflightChecks = @()
    $manifest = Get-ActiveWorkflowManifest -BotRoot $botRoot
    if ($manifest -and $manifest.requires) {
        $preflightChecks = @(Convert-ManifestRequiresToPreflightChecks -Requires $manifest.requires)
    }

    # Legacy settings.workflow.preflight fallback removed in PR-3 (engine deletion).
    if ($preflightChecks.Count -eq 0) {
        return @{ success = $true; checks = @() }
    }

    $results = @()
    $allPassed = $true

    foreach ($check in $preflightChecks) {
        if (-not $check -or -not $check.type) { continue }

        $passed = $false
        $hint = $check.hint

        if ($check.type -eq 'env_var') {
            $varName = if ($check.var) { $check.var } else { $check.name }
            $envLocalPath = Join-Path $projectRoot ".env.local"
            $envValue = $null
            if (Test-Path $envLocalPath) {
                $envLines = Get-Content $envLocalPath -ErrorAction SilentlyContinue
                foreach ($line in $envLines) {
                    if ($line -match "^\s*$([regex]::Escape($varName))\s*=\s*(.+)$") {
                        $envValue = $matches[1].Trim()
                    }
                }
            }
            $passed = [bool]$envValue
            if (-not $hint -and -not $passed) {
                $hint = "Set $varName in .env.local"
            }
        }
        elseif ($check.type -eq 'mcp_server') {
            $mcpFound = $false

            # 1) Check .mcp.json (fast path)
            $mcpJsonPath = Join-Path $projectRoot ".mcp.json"
            if (Test-Path $mcpJsonPath) {
                try {
                    $mcpData = Get-Content $mcpJsonPath -Raw | ConvertFrom-Json
                    if ($mcpData.mcpServers -and $mcpData.mcpServers.PSObject.Properties.Name -contains $check.name) {
                        $mcpFound = $true
                    }
                } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
            }

            # 2) Fall back to CLI registry (claude mcp list) — cached at module scope
            if (-not $mcpFound) {
                if ($null -eq $script:McpListCache) {
                    try { $script:McpListCache = & claude mcp list 2>&1 | Out-String }
                    catch { $script:McpListCache = "" }
                }
                if ($script:McpListCache -match "(?m)^$([regex]::Escape($check.name)):") {
                    $mcpFound = $true
                }
            }

            $passed = $mcpFound
            if (-not $hint -and -not $passed) {
                $hint = "Register '$($check.name)' server in .mcp.json or via 'claude mcp add'"
            }
        }
        elseif ($check.type -eq 'cli_tool') {
            $passed = $null -ne (Get-Command $check.name -ErrorAction SilentlyContinue)
            if (-not $hint -and -not $passed) {
                $hint = "Install '$($check.name)' and ensure it is on PATH"
            }
        }

        if (-not $passed) { $allPassed = $false }

        $results += @{
            type    = $check.type
            name    = $check.name
            passed  = $passed
            message = $check.message
            hint    = if (-not $passed -and $hint) { $hint } else { $null }
        }
    }

    return @{ success = $allPassed; checks = $results }
}

function Start-RoadmapPlanning {
    $botRoot = $script:Config.BotRoot

    # Validate product docs exist
    $productDir = Join-Path $botRoot "workspace\product"
    $requiredDocs = @("mission.md", "tech-stack.md", "entity-model.md")
    $missingDocs = @()
    foreach ($doc in $requiredDocs) {
        $docPath = Join-Path $productDir $doc
        if (-not (Test-Path $docPath)) {
            $missingDocs += $doc
        }
    }

    if ($missingDocs.Count -gt 0) {
        return @{
            _statusCode = 400
            success = $false
            error = "Missing required product docs: $($missingDocs -join ', '). Run the workflow first."
        }
    }

    # Launch via process manager
    $launcherPath = Join-Path $botRoot "core/runtime/launch-process.ps1"
    $launchArgs = @("-File", "`"$launcherPath`"", "-Type", "planning", "-Model", "Sonnet", "-Description", "`"Plan project roadmap`"")
    $startParams = @{ ArgumentList = $launchArgs }
    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
    Start-Process pwsh @startParams | Out-Null
    Write-Status "Roadmap planning launched as tracked process" -Type Info

    return @{
        success = $true
        message = "Roadmap planning initiated via process manager."
    }
}

function Resolve-PhaseStatusFromOutputs {
    param(
        [Parameter(Mandatory)] [object]$Phase,
        [Parameter(Mandatory)] [string]$BotRoot
    )
    $productDir = Join-Path $BotRoot "workspace\product"
    $phaseType = if ($Phase.type) { $Phase.type } else { "llm" }

    # If the phase has a condition, check it first — unmet means it can't have run
    if ($Phase.condition) {
        $cond = $Phase.condition
        if ($cond -match '^file_exists:(.+)$') {
            $condPath = Join-Path $BotRoot $Matches[1]
            if (-not (Test-Path $condPath)) { return "pending" }
        }
    }

    if ($phaseType -eq "interview") {
        $interviewPath = Join-Path $productDir "interview-summary.md"
        if (Test-Path $interviewPath) { return "completed" }
        return "pending"
    }

    if ($phaseType -eq "barrier") {
        # Barrier tasks are considered complete when their dependencies are complete
        # (resolved by the caller via process file tracking)
        return "pending"
    }

    # LLM, script, or task_gen phases: check required_outputs/outputs
    if ($Phase.required_outputs) {
        $allExist = $true
        foreach ($f in $Phase.required_outputs) {
            if (-not (Test-Path (Join-Path $productDir $f))) { $allExist = $false; break }
        }
        if ($allExist) { return "completed" }
        return "pending"
    }

    if ($Phase.required_outputs_dir) {
        $dirPath = Join-Path $BotRoot "workspace\$($Phase.required_outputs_dir)"
        $minCount = if ($Phase.min_output_count) { [int]$Phase.min_output_count } else { 1 }
        $fileCount = if (Test-Path $dirPath) { @(Get-ChildItem $dirPath -Filter "*.json" -File).Count } else { 0 }
        if ($fileCount -ge $minCount) { return "completed" }
        # Tasks may have moved through the pipeline (todo → done)
        if ($Phase.required_outputs_dir -match '^tasks/') {
            $taskBaseDir = Join-Path $BotRoot "workspace\tasks"
            $totalTasks = 0
            foreach ($td in @("todo","analysing","analysed","in-progress","done","skipped","cancelled")) {
                $tdPath = Join-Path $taskBaseDir $td
                if (Test-Path $tdPath) {
                    $totalTasks += @(Get-ChildItem $tdPath -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
                }
            }
            if ($totalTasks -ge $minCount) { return "completed" }
        }
        return "pending"
    }

    # Check outputs (manifest-style field name)
    if ($Phase.outputs) {
        $allExist = $true
        foreach ($f in $Phase.outputs) {
            # Workflow tasks use workspace-relative paths (e.g. workspace/reports/...)
            # Legacy workflow phases use product-dir-relative paths (e.g. mission.md)
            $basePath = if ($f -match '^workspace[/\\]') { $BotRoot } else { $productDir }
            $fullPath = Join-Path $basePath $f
            if (-not (Test-Path $fullPath)) { $allExist = $false; break }
        }
        if ($allExist) { return "completed" }
        return "pending"
    }

    # Check outputs_dir (manifest-style field name)
    if ($Phase.outputs_dir) {
        $dirPath = Join-Path $BotRoot "workspace\$($Phase.outputs_dir)"
        $minCount = if ($Phase.min_output_count) { [int]$Phase.min_output_count } else { 1 }
        $fileCount = if (Test-Path $dirPath) { @(Get-ChildItem $dirPath -Filter "*.json" -File).Count } else { 0 }
        if ($fileCount -ge $minCount) { return "completed" }
        if ($Phase.outputs_dir -match '^tasks/') {
            $taskBaseDir = Join-Path $BotRoot "workspace\tasks"
            $totalTasks = 0
            # Canonical task-pipeline status dirs. Keep in sync with the list
            # in the script-phase probe below and with workflow-manifest.ps1
            # (Clear-WorkspaceTaskDirs) which owns the authoritative enumeration.
            foreach ($td in @('todo','analysing','needs-input','analysed','in-progress','done','skipped','cancelled','split')) {
                $tdPath = Join-Path $taskBaseDir $td
                if (Test-Path $tdPath) {
                    $totalTasks += @(Get-ChildItem $tdPath -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
                }
            }
            if ($totalTasks -ge $minCount) { return "completed" }
        }
        return "pending"
    }

    # No required_outputs defined — assume completed if phase script exists
    if ($Phase.script) {
        # Script-only phases: check commit paths for evidence
        $commitPaths = if ($Phase.commit) { $Phase.commit.paths } else { $Phase.commit_paths }
        if ($commitPaths) {
            foreach ($cp in $commitPaths) {
                $cpPath = Join-Path $BotRoot $cp
                if (-not (Test-Path $cpPath)) { continue }

                # Special-case: a commit path of `workspace/tasks/` (or `tasks/`)
                # means the phase generates task files into the pipeline dirs.
                # The top level of tasks/ has no files — only subdirs — so a
                # flat count always returns 0. Probe the pipeline dirs instead,
                # matching the semantics of the outputs_dir branch above.
                # Keep this list in sync with the outputs_dir fallback above
                # and with workflow-manifest.ps1 (Clear-WorkspaceTaskDirs) which
                # owns the authoritative enumeration — tasks can legitimately
                # sit in any of these statuses (incl. needs-input / split)
                # after generation.
                $normalized = ($cp -replace '\\','/').Trim('/')
                if ($normalized -match '^(workspace/)?tasks/?$') {
                    $taskDirs = @('todo','analysing','needs-input','analysed','in-progress','done','skipped','cancelled','split')
                    $matched = $false
                    foreach ($td in $taskDirs) {
                        $tdPath = Join-Path $cpPath $td
                        if (Test-Path $tdPath) {
                            # Short-circuit: stop at the first match to avoid
                            # enumerating entire pipeline dirs on every UI poll.
                            $firstTaskFile = Get-ChildItem $tdPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
                                Select-Object -First 1
                            if ($null -ne $firstTaskFile) { $matched = $true; break }
                        }
                    }
                    if ($matched) { return "completed" }
                    continue
                }

                # General case: check for any real file under the commit path,
                # ignoring .gitkeep sentinels. Recurse so a commit path that
                # points at a directory-of-directories still registers real
                # committed artifacts underneath, but stop at the first match
                # to avoid materializing the full file list on every UI poll.
                $firstFile = Get-ChildItem $cpPath -File -Recurse -ErrorAction SilentlyContinue |
                             Where-Object { $_.Name -ne '.gitkeep' } |
                             Select-Object -First 1
                if ($firstFile) { return "completed" }
            }
        }
    }

    return "pending"
}

function Resolve-TaskGenChildTasks {
    param(
        [Parameter(Mandatory)] [array]$Phases,
        [Parameter(Mandatory)] [string]$BotRoot,
        [string]$WorkflowName
    )

    $hasTaskGen = $false
    foreach ($p in $Phases) {
        if ($p.type -eq 'task_gen') { $hasTaskGen = $true; break }
    }
    if (-not $hasTaskGen) { return $Phases }

    # Collect all tasks from every status directory
    $taskBaseDir = Join-Path $BotRoot "workspace\tasks"
    $statusDirs = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'skipped', 'cancelled')
    $statusMap = @{
        'todo' = 'todo'; 'analysing' = 'analysing'; 'needs-input' = 'needs-input'
        'analysed' = 'analysed'; 'in-progress' = 'in-progress'; 'done' = 'done'
        'skipped' = 'skipped'; 'cancelled' = 'cancelled'
    }
    $allTasks = [System.Collections.ArrayList]::new()
    foreach ($sd in $statusDirs) {
        $dir = Join-Path $taskBaseDir $sd
        if (-not (Test-Path $dir)) { continue }
        foreach ($f in @(Get-ChildItem -Path $dir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
            try {
                $tc = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
                # Filter by workflow name if available
                if ($WorkflowName -and $tc.workflow -and $tc.workflow -ne $WorkflowName) { continue }
                [void]$allTasks.Add(@{
                    id = $tc.id
                    name = $tc.name
                    status = $statusMap[$sd]
                })
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }
    }

    # Sort: in-progress first, then analysing, then done, then todo, then rest
    $sortOrder = @{ 'in-progress' = 0; 'analysing' = 1; 'needs-input' = 2; 'analysed' = 3; 'todo' = 4; 'done' = 5; 'skipped' = 6; 'cancelled' = 7 }
    $sorted = @($allTasks | Sort-Object { $sortOrder[$_.status] }, { $_.name })

    # Compute summary counts
    $counts = @{ todo = 0; analysing = 0; needs_input = 0; analysed = 0; in_progress = 0; done = 0; skipped = 0; total = 0 }
    foreach ($t in $sorted) {
        $counts['total']++
        switch ($t.status) {
            'todo'        { $counts['todo']++ }
            'analysing'   { $counts['analysing']++ }
            'needs-input' { $counts['needs_input']++ }
            'analysed'    { $counts['analysed']++ }
            'in-progress' { $counts['in_progress']++ }
            'done'        { $counts['done']++ }
            'skipped'     { $counts['skipped']++ }
        }
    }

    # Attach child data to task_gen phases
    $enriched = @()
    foreach ($p in $Phases) {
        if ($p.type -eq 'task_gen' -and $counts['total'] -gt 0) {
            $p['child_tasks'] = $sorted
            $p['child_counts'] = $counts
            # Synthetic status: 'active' if generation done but tasks remain incomplete
            if ($p.status -eq 'completed' -and $counts['done'] -lt $counts['total']) {
                $p['status'] = 'active'
            }
        }
        $enriched += $p
    }
    return $enriched
}

function Get-WorkflowStatus {
    $botRoot = $script:Config.BotRoot
    $controlDir = $script:Config.ControlDir

    # Load manifest helpers
    . "$BotRoot/core/runtime/modules/workflow-manifest.ps1"

    # Try manifest first (tasks array)
    $workflowPhases = @()
    $workflowName = $null
    $manifest = Get-ActiveWorkflowManifest -BotRoot $botRoot
    if ($manifest -and $manifest.tasks -and $manifest.tasks.Count -gt 0) {
        Ensure-ManifestTaskIds -Tasks $manifest.tasks
        $workflowPhases = @($manifest.tasks)
        $workflowName = $manifest.name
    }

    # Legacy settings.workflow.phases fallback removed in PR-3 (engine deletion).
    if ($workflowPhases.Count -eq 0) {
        return @{ status = "not-started"; process_id = $null; phases = @(); resume_from = $null; workflow_name = $workflowName }
    }

    # Find most recent workflow process
    $processesDir = Join-Path $controlDir "processes"
    $latestProc = $null
    if (Test-Path $processesDir) {
        $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($pf in $procFiles) {
            try {
                $pData = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                $isWorkflowRunner = $pData.type -eq 'task-runner' -and $workflowName -and
                                    $pData.workflow_name -eq $workflowName
                if ($isWorkflowRunner) {
                    $latestProc = $pData
                    break
                }
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
        }
    }

    if (-not $latestProc) {
        # No process found — infer from filesystem
        $phases = @($workflowPhases | ForEach-Object {
            $inferredStatus = Resolve-PhaseStatusFromOutputs -Phase $_ -BotRoot $botRoot
            @{
                id = $_.id; name = $_.name
                type = if ($_.type) { $_.type } else { "llm" }
                status = $inferredStatus
            }
        })
        # Sequential consistency: if a later phase completed, earlier ones must have too
        $lastCompletedIdx = -1
        for ($i = 0; $i -lt $phases.Count; $i++) {
            if ($phases[$i].status -eq 'completed') { $lastCompletedIdx = $i }
        }
        for ($i = 0; $i -lt $lastCompletedIdx; $i++) {
            if ($phases[$i].status -in @('pending', 'incomplete')) {
                $phases[$i].status = 'completed'
            }
        }

        $completedCount = @($phases | Where-Object { $_.status -eq 'completed' }).Count
        $overallStatus = if ($completedCount -eq 0) { "not-started" }
                         elseif ($completedCount -eq $phases.Count) { "completed" }
                         else { "incomplete" }
        $resumeFrom = ($phases | Where-Object { $_.status -in @('pending', 'failed', 'incomplete') } | Select-Object -First 1).id

        # Enrich task_gen phases with child task data
        $phases = @(Resolve-TaskGenChildTasks -Phases $phases -BotRoot $botRoot -WorkflowName $workflowName)

        return @{
            status = $overallStatus
            process_id = $null
            phases = $phases
            resume_from = $resumeFrom
            workflow_name = $workflowName
        }
    }

    # Process found — merge settings (canonical) with process-file status
    $procPhaseMap = @{}
    if ($latestProc.phases -and $latestProc.phases.Count -gt 0) {
        foreach ($pp in $latestProc.phases) {
            if ($pp.id) {
                $procPhaseMap[$pp.id] = $pp
            }
        }
    }

    $phases = @($workflowPhases | ForEach-Object {
        $phaseId   = $_.id
        $phaseName = $_.name
        $phaseType = if ($_.type) { $_.type } else { "llm" }
        $procEntry = $procPhaseMap[$phaseId]

        if ($procEntry -and $procEntry.status -eq 'skipped') {
            # Skipped = completed in a prior run — show as completed
            @{ id = $phaseId; name = $phaseName; type = $phaseType; status = 'completed' }
        } elseif ($procEntry -and $procEntry.status -and $procEntry.status -ne 'pending') {
            # Process file has real status (running, completed, failed, etc.) — use it
            @{ id = $phaseId; name = $phaseName; type = $phaseType; status = $procEntry.status }
        } else {
            # Not in process file or still pending — infer from filesystem
            $inferredStatus = Resolve-PhaseStatusFromOutputs -Phase $_ -BotRoot $botRoot
            @{ id = $phaseId; name = $phaseName; type = $phaseType; status = $inferredStatus }
        }
    })

    # Preserve synthetic interview phase (in process file but not in settings)
    if ($procPhaseMap.ContainsKey('interview') -and -not ($workflowPhases | Where-Object { $_.id -eq 'interview' })) {
        $iv = $procPhaseMap['interview']
        $phases = @(@{ id = 'interview'; name = $iv.name; type = 'interview'; status = $iv.status }) + $phases
    }

    # Sequential consistency: if a later phase completed, earlier ones must have too
    $lastCompletedIdx = -1
    for ($i = 0; $i -lt $phases.Count; $i++) {
        if ($phases[$i].status -eq 'completed') { $lastCompletedIdx = $i }
    }
    for ($i = 0; $i -lt $lastCompletedIdx; $i++) {
        if ($phases[$i].status -in @('pending', 'incomplete')) {
            $phases[$i].status = 'completed'
        }
    }

    # Compute overall status
    $completedCount = @($phases | Where-Object { $_.status -eq 'completed' }).Count
    $skippedCount = @($phases | Where-Object { $_.status -eq 'skipped' }).Count
    $runningCount = @($phases | Where-Object { $_.status -eq 'running' }).Count
    $failedCount = @($phases | Where-Object { $_.status -eq 'failed' }).Count

    $overallStatus = if ($runningCount -gt 0) { "running" }
                     elseif ($latestProc.status -eq 'running') { "running" }
                     elseif (($completedCount + $skippedCount) -eq $phases.Count) { "completed" }
                     elseif ($failedCount -gt 0 -or $completedCount -gt 0) { "incomplete" }
                     else { "not-started" }

    $resumeFrom = ($phases | Where-Object { $_.status -in @('pending', 'failed', 'incomplete') } | Select-Object -First 1).id

    # Enrich task_gen phases with child task data
    $phases = @(Resolve-TaskGenChildTasks -Phases $phases -BotRoot $botRoot -WorkflowName $workflowName)

    return @{
        status = $overallStatus
        process_id = $latestProc.id
        phases = $phases
        resume_from = $resumeFrom
        workflow_name = $workflowName
    }
}

Export-ModuleMember -Function @(
    'Initialize-ProductAPI',
    'Get-ProductList',
    'Get-ProductDocument',
    'Get-ProductDocumentRaw',
    'Get-PreflightResults',
    'Start-RoadmapPlanning',
    'Get-WorkflowStatus'
)


