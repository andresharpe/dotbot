function Invoke-TaskGetContext {
    param(
        [hashtable]$Arguments
    )

    # Extract arguments
    $taskId = $Arguments['task_id']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }

    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    $analysedDir = Join-Path $tasksBaseDir "analysed"
    $inProgressDir = Join-Path $tasksBaseDir "in-progress"

    # Find the task file (can be in analysed or in-progress)
    $taskFile = $null
    $currentStatus = $null

    foreach ($searchDir in @($analysedDir, $inProgressDir)) {
        if (Test-Path $searchDir) {
            $files = Get-ChildItem -Path $searchDir -Filter "*.json" -File
            foreach ($file in $files) {
                try {
                    $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                    if ($content.id -eq $taskId) {
                        $taskFile = $file
                        $currentStatus = if ($searchDir -eq $analysedDir) { 'analysed' } else { 'in-progress' }
                        break
                    }
                } catch {
                    # Continue searching
                }
            }
            if ($taskFile) { break }
        }
    }

    if (-not $taskFile) {
        throw "Task with ID '$taskId' not found in analysed or in-progress status"
    }

    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json

    # Check if task has analysis data
    $hasAnalysis = $taskContent.PSObject.Properties['analysis'] -and $taskContent.analysis

    if (-not $hasAnalysis) {
        # Task doesn't have pre-flight analysis - return minimal context
        return @{
            success = $true
            has_analysis = $false
            task_id = $taskId
            task_name = $taskContent.name
            status = $currentStatus
            message = "Task has no pre-flight analysis data. Use standard exploration."
            task = @{
                id = $taskContent.id
                name = $taskContent.name
                description = $taskContent.description
                category = $taskContent.category
                priority = $taskContent.priority
                effort = $taskContent.effort
                acceptance_criteria = $taskContent.acceptance_criteria
                steps = $taskContent.steps
                dependencies = $taskContent.dependencies
                applicable_agents = $taskContent.applicable_agents
                applicable_standards = $taskContent.applicable_standards
                applicable_decisions = $taskContent.applicable_decisions
            }
        }
    }

    # Return full analysis context
    $analysis = $taskContent.analysis

    # Resolve Decision content from applicable_decisions list
    $decisionContent = @()
    $decisionIds = @($taskContent.applicable_decisions | Where-Object { $_ -match '^dec-[a-f0-9]{8}$' })
    if ($decisionIds.Count -gt 0) {
        $decisionsBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\decisions"
        $decisionStatuses = @('accepted', 'proposed', 'deprecated', 'superseded')
        foreach ($decId in $decisionIds) {
            $decFound = $false
            foreach ($statusDir in $decisionStatuses) {
                $dirPath = Join-Path $decisionsBaseDir $statusDir
                if (-not (Test-Path $dirPath)) { continue }
                $files = @(Get-ChildItem -LiteralPath $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -like "$decId-*" -or $_.BaseName -eq "$decId" })
                if ($files.Count -gt 0) {
                    try {
                        $decData = Get-Content -Path $files[0].FullName -Raw | ConvertFrom-Json
                        $decisionContent += @{
                            id                       = $decId
                            title                    = $decData.title
                            status                   = $decData.status
                            context                  = $decData.context
                            decision                 = $decData.decision
                            rationale                = $decData.rationale
                            consequences             = $decData.consequences
                            alternatives_considered  = $decData.alternatives_considered
                        }
                        $decFound = $true
                    } catch { Write-BotLog -Level Debug -Message "Decision operation failed" -Exception $_ }
                    break
                }
            }
            if (-not $decFound) {
                $decisionContent += @{ id = $decId; title = $null; status = 'not-found'; context = $null; decision = $null; rationale = $null; consequences = $null; alternatives_considered = $null }
            }
        }
    }

    return @{
        success = $true
        has_analysis = $true
        task_id = $taskId
        task_name = $taskContent.name
        status = $currentStatus
        message = "Pre-flight analysis available - use packaged context"

        # Core task info
        task = @{
            id = $taskContent.id
            name = $taskContent.name
            description = $taskContent.description
            category = $taskContent.category
            priority = $taskContent.priority
            effort = $taskContent.effort
            acceptance_criteria = $taskContent.acceptance_criteria
            steps = $taskContent.steps
            dependencies = $taskContent.dependencies
            applicable_agents = $taskContent.applicable_agents
            applicable_standards = $taskContent.applicable_standards
            applicable_decisions = $taskContent.applicable_decisions
        }

        # Pre-flight analysis
        analysis = @{
            analysed_at = $analysis.analysed_at
            analysed_by = $analysis.analysed_by
            
            # Entity context
            entities = $analysis.entities
            
            # Files to work with
            files = $analysis.files
            
            # Dependencies checked
            dependencies = $analysis.dependencies
            
            # Standards to follow
            standards = $analysis.standards
            
            # Product context (already extracted)
            product_context = $analysis.product_context
            
            # Implementation guidance
            implementation = $analysis.implementation
            
            # Questions that were resolved
            questions_resolved = $analysis.questions_resolved

            # Applicable Decisions with content
            decisions = $decisionContent
        }
    }
}
