Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/TaskStore.psm1") -Force

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

    # Resolve task across every status where it can carry useful context.
    # analysing: task is being analysed but no analysis payload exists yet — return minimal context.
    # needs-input: task is paused awaiting clarification — context already accumulated.
    # analysed / in-progress: task has its full pre-flight analysis available.
    $searchStatuses = @('analysing', 'needs-input', 'analysed', 'in-progress')
    $found = Find-TaskFileById -TaskId $taskId -SearchStatuses $searchStatuses
    if (-not $found) {
        throw "Task with ID '$taskId' not found in any of: $($searchStatuses -join ', ')"
    }
    $taskContent = $found.Content
    $currentStatus = $found.Status

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

    # Decisions: prefer the analyser's embedded `analysis.decisions` payload
    # when present (richer text — decision, consequences, alternatives_considered
    # already inlined). Fall back to resolving from the task's `applicable_decisions`
    # ID list when the analyser didn't embed them.
    $hasEmbeddedDecisions = $analysis.PSObject.Properties['decisions'] -and `
        $analysis.decisions -and @($analysis.decisions).Count -gt 0
    $decisionContent = @()
    $decisionIds = @($taskContent.applicable_decisions | Where-Object { $_ -match '^dec-[a-f0-9]{8}$' })
    if (-not $hasEmbeddedDecisions -and $decisionIds.Count -gt 0) {
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

            # Verbatim briefing excerpts the analyser embedded for the executor
            # (1-3 line quotes from mission/tech-stack/entity-model/briefing
            # files keyed by file path). Pass-through; null when the analyser
            # did not write this field.
            briefing_excerpts = $analysis.briefing_excerpts

            # Applicable Decisions with content. Embedded payload from the
            # analyser wins when present; otherwise resolved from
            # applicable_decisions IDs above.
            decisions = if ($hasEmbeddedDecisions) { $analysis.decisions } else { $decisionContent }
        }
    }
}
