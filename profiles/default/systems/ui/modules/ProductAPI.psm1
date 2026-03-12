<#
.SYNOPSIS
Product document management API module

.DESCRIPTION
Provides product document listing, retrieval, kickstart (Claude-driven doc creation),
and roadmap planning functionality.
Extracted from server.ps1 for modularity.
#>

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
    $name = $relativePath -replace '\.md$', ''
    $segments = @($name -split '/')

    return [PSCustomObject]@{
        Name = $name
        Filename = $relativePath
        Depth = [Math]::Max(0, $segments.Count - 1)
        BaseName = $File.BaseName
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
    if ($normalizedName.EndsWith('.md', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalizedName = $normalizedName.Substring(0, $normalizedName.Length - 3)
    }

    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        return $null
    }

    $relativePath = ($normalizedName -split '/') -join [System.IO.Path]::DirectorySeparatorChar
    $candidatePath = Join-Path $ProductDir "$relativePath.md"

    try {
        $productDirFull = [System.IO.Path]::GetFullPath($ProductDir)
        $candidateFull = [System.IO.Path]::GetFullPath($candidatePath)
    } catch {
        return $null
    }

    $productPrefix = if ($productDirFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $productDirFull
    } else {
        "$productDirFull$([System.IO.Path]::DirectorySeparatorChar)"
    }

    if ($candidateFull -notlike "$productPrefix*") {
        return $null
    }

    return @{
        Name = $normalizedName
        FullPath = $candidateFull
    }
}

function Get-ProductList {
    $botRoot = $script:Config.BotRoot
    $productDir = Join-Path $botRoot "workspace\product"
    $docs = @()

    if (Test-Path $productDir) {
        $mdFiles = @(Get-ChildItem -Path $productDir -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue)

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

        foreach ($file in $mdFiles) {
            if ($null -eq $file) { continue }

            $doc = Resolve-ProductDocumentInfo -File $file -ProductDir $productDir
            $priorityIndex = if ($doc.Depth -eq 0) { $priorityOrder.IndexOf($file.BaseName) } else { -1 }

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
            }
        }
        foreach ($file in $rootFiles) {
            if ($null -eq $file) { continue }
            $docs += @{
                name = $file.Name
                filename = $file.Filename
            }
        }
        foreach ($file in $nestedFiles) {
            if ($null -eq $file) { continue }
            $docs += @{
                name = $file.Name
                filename = $file.Filename
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

    if ($resolvedDoc -and (Test-Path $resolvedDoc.FullPath)) {
        $docContent = Get-Content -Path $resolvedDoc.FullPath -Raw
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

function Get-PreflightResults {
    $botRoot = $script:Config.BotRoot
    $projectRoot = Split-Path -Parent $botRoot

    $settingsFile = Join-Path $botRoot "defaults\settings.default.json"
    if (-not (Test-Path $settingsFile)) {
        return @{ success = $true; checks = @() }
    }

    try {
        $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
        $preflightChecks = @()
        if ($settingsData.kickstart -and $settingsData.kickstart.preflight) {
            $preflightChecks = @($settingsData.kickstart.preflight)
        }
    } catch {
        Write-Verbose "Pre-flight settings parse error: $_"
        return @{ success = $true; checks = @() }
    }

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
                } catch {}
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

function Start-ProductKickstart {
    param(
        [Parameter(Mandatory)] [string]$UserPrompt,
        [array]$Files = @(),
        [bool]$NeedsInterview = $true,
        [bool]$AutoWorkflow = $true,
        [string[]]$SkipPhases = @()
    )
    $botRoot = $script:Config.BotRoot
    $projectRoot = Split-Path -Parent $botRoot

    # Note: Preflight validation is handled by the GET /preflight endpoint.
    # The frontend checks preflight before calling POST, so we skip it here
    # to avoid blocking the HTTP thread with a duplicate `claude mcp list` call.

    # Create briefing directory
    $briefingDir = Join-Path $botRoot "workspace\product\briefing"
    if (-not (Test-Path $briefingDir)) {
        New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null
    }

    # Decode and save files
    $savedFiles = @()
    foreach ($file in $Files) {
        if (-not $file -or -not $file.name -or -not $file.content) { continue }

        try {
            $decoded = [Convert]::FromBase64String($file.content)
            $safeName = $file.name -replace '[^\w\-\.]', '_'
            $filePath = Join-Path $briefingDir $safeName

            [System.IO.File]::WriteAllBytes($filePath, $decoded)
            $savedFiles += $filePath
        } catch {
            foreach ($savedFile in $savedFiles) {
                Remove-Item -LiteralPath $savedFile -Force -ErrorAction SilentlyContinue
            }

            return @{
                _statusCode = 400
                success = $false
                error = "Invalid base64 content for file '$($file.name)'"
            }
        }
    }

    # Launch kickstart as tracked process
    # Write prompt and launcher to .control/launchers/ (gitignored) to avoid
    # absolute paths in committed files triggering the privacy scan
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $launchersDir = Join-Path $script:Config.ControlDir "launchers"
    if (-not (Test-Path $launchersDir)) {
        New-Item -Path $launchersDir -ItemType Directory -Force | Out-Null
    }
    $promptFile = Join-Path $launchersDir "kickstart-prompt.txt"
    $UserPrompt | Set-Content -Path $promptFile -Encoding UTF8 -NoNewline

    $wrapperPath = Join-Path $launchersDir "kickstart-launcher.ps1"
    $interviewLine = if ($NeedsInterview) { " -NeedsInterview" } else { "" }
    $autoWorkflowLine = if ($AutoWorkflow) { " -AutoWorkflow" } else { "" }
    $skipLine = if ($SkipPhases.Count -gt 0) { " -SkipPhases '$($SkipPhases -join ',')'" } else { "" }
    @"
`$prompt = Get-Content -LiteralPath '$promptFile' -Raw
& '$launcherPath' -Type kickstart -Prompt `$prompt -Description 'Kickstart: project setup'$interviewLine$autoWorkflowLine$skipLine
"@ | Set-Content -Path $wrapperPath -Encoding UTF8

    $startParams = @{ ArgumentList = @("-NoProfile", "-File", $wrapperPath); PassThru = $true }
    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
    $proc = Start-Process pwsh @startParams

    # Find process_id by PID
    Start-Sleep -Milliseconds 500
    $processesDir = Join-Path $script:Config.ControlDir "processes"
    $launchedProcId = $null
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw | ConvertFrom-Json
            if ($pData.pid -eq $proc.Id) {
                $launchedProcId = $pData.id
                break
            }
        } catch {}
    }

    Write-Status "Product kickstart launched (PID: $($proc.Id))" -Type Info

    return @{
        success = $true
        process_id = $launchedProcId
        message = "Kickstart initiated. Product documents, task groups, and task expansion will run in a tracked process."
    }
}

function Start-ProductAnalyse {
    param(
        [string]$UserPrompt = "",
        [ValidateSet('Opus', 'Sonnet', 'Haiku')]
        [string]$Model = "Sonnet"
    )
    $botRoot = $script:Config.BotRoot

    # Launch analyse as a tracked process via launch-process.ps1
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $launchArgs = @(
        "-File", "`"$launcherPath`"",
        "-Type", "analyse",
        "-Model", $Model,
        "-Description", "`"Analyse: existing project`""
    )
    if ($UserPrompt) {
        $escapedPrompt = $UserPrompt -replace '"', '\"'
        $launchArgs += @("-Prompt", "`"$escapedPrompt`"")
    }
    $startParams = @{ ArgumentList = $launchArgs }
    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
    Start-Process pwsh @startParams | Out-Null
    Write-Status "Product analyse launched as tracked process" -Type Info

    return @{
        success = $true
        message = "Analyse initiated. Product documents will be generated from your existing codebase."
    }
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
            error = "Missing required product docs: $($missingDocs -join ', '). Run kickstart first."
        }
    }

    # Launch via process manager
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
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

    if ($phaseType -eq "workflow") {
        # Check if tasks remain in active states
        $activeDirs = @("todo", "analysing", "analysed", "in-progress")
        $remaining = 0
        foreach ($dir in $activeDirs) {
            $dirPath = Join-Path $BotRoot "workspace\tasks\$dir"
            if (Test-Path $dirPath) {
                $remaining += @(Get-ChildItem $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
            }
        }
        $donePath = Join-Path $BotRoot "workspace\tasks\done"
        $doneCount = if (Test-Path $donePath) { @(Get-ChildItem $donePath -Filter "*.json" -File -ErrorAction SilentlyContinue).Count } else { 0 }
        if ($doneCount -gt 0 -and $remaining -eq 0) { return "completed" }
        if ($doneCount -gt 0 -or $remaining -gt 0) { return "incomplete" }
        return "pending"
    }

    # LLM or script phases: check required_outputs
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

    # No required_outputs defined — assume completed if phase script exists
    if ($Phase.script) {
        # Script-only phases: check commit_paths for evidence
        if ($Phase.commit_paths) {
            foreach ($cp in $Phase.commit_paths) {
                $cpPath = Join-Path $BotRoot $cp
                if ((Test-Path $cpPath) -and @(Get-ChildItem $cpPath -File -ErrorAction SilentlyContinue).Count -gt 0) {
                    return "completed"
                }
            }
        }
    }

    return "pending"
}

function Get-KickstartStatus {
    $botRoot = $script:Config.BotRoot
    $controlDir = $script:Config.ControlDir

    # Read phase definitions from settings (source of truth)
    $settingsFile = Join-Path $botRoot "defaults\settings.default.json"
    $kickstartPhases = @()
    if (Test-Path $settingsFile) {
        try {
            $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
            if ($settingsData.kickstart -and $settingsData.kickstart.phases) {
                $kickstartPhases = @($settingsData.kickstart.phases)
            }
        } catch {}
    }

    if ($kickstartPhases.Count -eq 0) {
        return @{ status = "not-started"; process_id = $null; phases = @(); resume_from = $null }
    }

    # Find most recent kickstart process
    $processesDir = Join-Path $controlDir "processes"
    $latestProc = $null
    if (Test-Path $processesDir) {
        $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($pf in $procFiles) {
            try {
                $pData = Get-Content $pf.FullName -Raw | ConvertFrom-Json
                if ($pData.type -eq 'kickstart') {
                    $latestProc = $pData
                    break
                }
            } catch {}
        }
    }

    if (-not $latestProc) {
        # No process found — infer from filesystem
        $phases = @($kickstartPhases | ForEach-Object {
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

        return @{
            status = $overallStatus
            process_id = $null
            phases = $phases
            resume_from = $resumeFrom
        }
    }

    # Process found — merge settings (canonical) with process-file status
    $procPhaseMap = @{}
    if ($latestProc.phases -and $latestProc.phases.Count -gt 0) {
        foreach ($pp in $latestProc.phases) {
            $procPhaseMap[$pp.id] = $pp
        }
    }

    $phases = @($kickstartPhases | ForEach-Object {
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
    if ($procPhaseMap.ContainsKey('interview') -and -not ($kickstartPhases | Where-Object { $_.id -eq 'interview' })) {
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

    return @{
        status = $overallStatus
        process_id = $latestProc.id
        phases = $phases
        resume_from = $resumeFrom
    }
}

function Resume-ProductKickstart {
    $botRoot = $script:Config.BotRoot

    # Get current status
    $status = Get-KickstartStatus
    if ($status.status -eq 'completed') {
        return @{ _statusCode = 400; success = $false; error = "Kickstart already completed — nothing to resume" }
    }
    if ($status.status -eq 'running') {
        return @{ _statusCode = 400; success = $false; error = "Kickstart is currently running" }
    }
    if (-not $status.resume_from) {
        return @{ _statusCode = 400; success = $false; error = "No phase to resume from" }
    }

    # Read original prompt (fall back to mission.md if prompt file is missing)
    $launchersDir = Join-Path $script:Config.ControlDir "launchers"
    if (-not (Test-Path $launchersDir)) {
        New-Item -Path $launchersDir -ItemType Directory -Force | Out-Null
    }
    $promptFile = Join-Path $launchersDir "kickstart-prompt.txt"
    if (-not (Test-Path $promptFile)) {
        $missionFile = Join-Path $botRoot "workspace\product\mission.md"
        if (Test-Path $missionFile) {
            $missionContent = Get-Content -LiteralPath $missionFile -Raw
            $missionContent | Set-Content -Path $promptFile -Encoding UTF8 -NoNewline
        } else {
            return @{ _statusCode = 400; success = $false; error = "Cannot resume — no saved prompt or mission document found. Please start a new kickstart." }
        }
    }
    $originalPrompt = Get-Content -LiteralPath $promptFile -Raw

    # Launch resumed kickstart
    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $resumePhase = $status.resume_from

    $wrapperPath = Join-Path $launchersDir "kickstart-resume-launcher.ps1"
    @"
`$prompt = Get-Content -LiteralPath '$promptFile' -Raw
& '$launcherPath' -Type kickstart -Prompt `$prompt -Description 'Kickstart: resume from $resumePhase' -AutoWorkflow -FromPhase '$resumePhase'
"@ | Set-Content -Path $wrapperPath -Encoding UTF8

    $startParams = @{ ArgumentList = @("-NoProfile", "-File", $wrapperPath); PassThru = $true }
    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
    $proc = Start-Process pwsh @startParams

    # Find process_id by PID
    Start-Sleep -Milliseconds 500
    $processesDir = Join-Path $script:Config.ControlDir "processes"
    $launchedProcId = $null
    $procFiles = Get-ChildItem -Path $processesDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    foreach ($pf in $procFiles) {
        try {
            $pData = Get-Content $pf.FullName -Raw | ConvertFrom-Json
            if ($pData.pid -eq $proc.Id) {
                $launchedProcId = $pData.id
                break
            }
        } catch {}
    }

    Write-Status "Kickstart resumed from phase '$resumePhase' (PID: $($proc.Id))" -Type Info

    return @{
        success = $true
        process_id = $launchedProcId
        resume_from = $resumePhase
        message = "Kickstart resumed from phase '$resumePhase'"
    }
}

Export-ModuleMember -Function @(
    'Initialize-ProductAPI',
    'Get-ProductList',
    'Get-ProductDocument',
    'Get-PreflightResults',
    'Start-ProductKickstart',
    'Start-ProductAnalyse',
    'Start-RoadmapPlanning',
    'Get-KickstartStatus',
    'Resume-ProductKickstart'
)

