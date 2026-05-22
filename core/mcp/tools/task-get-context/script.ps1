
Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

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
    # Find-TaskFileById returns a hashtable; reach for keys directly so the
    # PSObject.Properties[...] indexing trick (which targets PSCustomObject)
    # doesn't return $null and trip strict mode further down.
    $taskContent = $found.Content
    $currentStatus = $found.Status

    # Check if task has analysis data
    $hasAnalysis = $taskContent -and $taskContent.PSObject.Properties['analysis'] -and $taskContent.analysis

    if (-not $hasAnalysis) {
        # Task doesn't have pre-flight analysis - return minimal context.
        # Project into a hashtable so optional fields don't trip strict 3.0.
        $tc = @{}
        if ($taskContent) {
            foreach ($p in $taskContent.PSObject.Properties) { $tc[$p.Name] = $p.Value }
        }
        return @{
            success = $true
            has_analysis = $false
            task_id = $taskId
            task_name = $tc['name']
            status = $currentStatus
            message = "Task has no pre-flight analysis data. Use standard exploration."
            task = @{
                id = $tc['id']
                name = $tc['name']
                description = $tc['description']
                category = $tc['category']
                priority = $tc['priority']
                effort = $tc['effort']
                acceptance_criteria = $tc['acceptance_criteria']
                steps = $tc['steps']
                dependencies = $tc['dependencies']
                applicable_agents = $tc['applicable_agents']
                applicable_standards = $tc['applicable_standards']
                applicable_decisions = $tc['applicable_decisions']
            }
        }
    }

    # Return full analysis context
    $analysis = $taskContent.analysis

    # Decisions: prefer the analyser's embedded `analysis.decisions` payload
    # when present (richer text — decision, consequences, alternatives_considered
    # already inlined). Fall back to resolving from the task's `applicable_decisions`
    # ID list when the analyser didn't embed them.
    $hasEmbeddedDecisions = $analysis -and $analysis.PSObject.Properties['decisions'] -and `
        $analysis.decisions -and @($analysis.decisions).Count -gt 0
    $decisionContent = @()
    $applicableDecisions = if ($taskContent.PSObject.Properties['applicable_decisions']) {
        $taskContent.applicable_decisions
    } else { @() }
    $decisionIds = @($applicableDecisions | Where-Object { $_ -match '^dec-[a-f0-9]{8}$' })
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

    # Project both PSCustomObjects into hashtables keyed by property name so
    # we can read optional fields without tripping Set-StrictMode -Version 3.0.
    $tc = @{}
    foreach ($p in $taskContent.PSObject.Properties) { $tc[$p.Name] = $p.Value }
    $an = @{}
    foreach ($p in $analysis.PSObject.Properties) { $an[$p.Name] = $p.Value }

    return @{
        success = $true
        has_analysis = $true
        task_id = $taskId
        task_name = $tc['name']
        status = $currentStatus
        message = "Pre-flight analysis available - use packaged context"

        # Core task info
        task = @{
            id = $tc['id']
            name = $tc['name']
            description = $tc['description']
            category = $tc['category']
            priority = $tc['priority']
            effort = $tc['effort']
            acceptance_criteria = $tc['acceptance_criteria']
            steps = $tc['steps']
            dependencies = $tc['dependencies']
            applicable_agents = $tc['applicable_agents']
            applicable_standards = $tc['applicable_standards']
            applicable_decisions = $tc['applicable_decisions']
        }

        # Pre-flight analysis
        analysis = @{
            analysed_at = $an['analysed_at']
            analysed_by = $an['analysed_by']
            entities = $an['entities']
            files = $an['files']
            dependencies = $an['dependencies']
            standards = $an['standards']
            product_context = $an['product_context']
            implementation = $an['implementation']
            questions_resolved = $an['questions_resolved']

            # Verbatim briefing excerpts the analyser embedded for the executor
            # (1-3 line quotes from mission/tech-stack/entity-model/briefing
            # files keyed by file path). Pass-through; null when the analyser
            # did not write this field.
            briefing_excerpts = $an['briefing_excerpts']

            # Applicable Decisions with content. Embedded payload from the
            # analyser wins when present; otherwise resolved from
            # applicable_decisions IDs above.
            decisions = if ($hasEmbeddedDecisions) { $an['decisions'] } else { $decisionContent }
        }
    }
}
