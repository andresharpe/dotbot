<#
.SYNOPSIS
Post-processing script for the task-groups kickstart phase.

.DESCRIPTION
Runs after Claude creates task-groups.json. Injects metadata into the JSON file,
then generates a deterministic roadmap-overview.md with Gantt chart and cost comparison.

Called as a post_script from the kickstart phase pipeline.

.PARAMETER BotRoot
Path to the .bot directory.

.PARAMETER ProductDir
Path to the workspace/product directory.

.PARAMETER Settings
Parsed settings object (used for cost config).

.PARAMETER Model
Claude model name used for metadata.

.PARAMETER ProcessId
Process registry ID for metadata.
#>

param(
    [Parameter(Mandatory)]
    [string]$BotRoot,

    [Parameter(Mandatory)]
    [string]$ProductDir,

    [Parameter(Mandatory)]
    $Settings,

    [Parameter(Mandatory)]
    [string]$Model,

    [string]$ProcessId
)

# Inject metadata into task-groups.json
$groupsPath = Join-Path $ProductDir "task-groups.json"
$groupsJson = Get-Content $groupsPath -Raw | ConvertFrom-Json
$groupsJson | Add-Member -NotePropertyName "generated_at" -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o") -Force
$groupsJson | Add-Member -NotePropertyName "model" -NotePropertyValue $Model -Force
$groupsJson | Add-Member -NotePropertyName "process_id" -NotePropertyValue $ProcessId -Force
$groupsJson | Add-Member -NotePropertyName "generator" -NotePropertyValue "dotbot-kickstart" -Force
$groupsJson | ConvertTo-Json -Depth 10 | Set-Content -Path $groupsPath -Encoding utf8NoBOM

# ===== Generate roadmap-overview.md (deterministic, no LLM) =====
try {
    $costDefaults = @{ hourly_rate = 50; ai_cost_per_task = 0.50; ai_speedup_factor = 10; currency = "USD" }
    $costConfig = if ($Settings.costs) { $Settings.costs } else { $costDefaults }
    $hourlyRate = if ($costConfig.hourly_rate) { [decimal]$costConfig.hourly_rate } else { 50 }
    $aiCostPerTask = if ($costConfig.ai_cost_per_task) { [decimal]$costConfig.ai_cost_per_task } else { 0.50 }
    $aiSpeedupFactor = if ($costConfig.ai_speedup_factor) { [decimal]$costConfig.ai_speedup_factor } else { 10 }
    $currency = if ($costConfig.currency) { $costConfig.currency } else { "USD" }

    $groupsData = Get-Content $groupsPath -Raw | ConvertFrom-Json
    $sortedGroups = $groupsData.groups | Sort-Object { $_.order }

    $totalEffortDays = ($sortedGroups | ForEach-Object { if ($_.effort_days) { $_.effort_days } else { 3 } } | Measure-Object -Sum).Sum
    $totalTasks = ($sortedGroups | ForEach-Object { $_.estimated_task_count } | Measure-Object -Sum).Sum

    $roadmap = [System.Collections.ArrayList]::new()
    [void]$roadmap.Add("---")
    [void]$roadmap.Add("generated_at: `"$((Get-Date).ToUniversalTime().ToString("o"))`"")
    [void]$roadmap.Add("model: `"$Model`"")
    [void]$roadmap.Add("process_id: `"$ProcessId`"")
    [void]$roadmap.Add("phase: `"phase-2b-roadmap`"")
    [void]$roadmap.Add("generator: `"dotbot-kickstart`"")
    [void]$roadmap.Add("---")
    [void]$roadmap.Add("")
    [void]$roadmap.Add("# Roadmap Overview")
    [void]$roadmap.Add("")
    [void]$roadmap.Add("**Project:** $($groupsData.project_name)")
    [void]$roadmap.Add("**Generated:** $(Get-Date -Format 'yyyy-MM-dd')")
    [void]$roadmap.Add("**Groups:** $($sortedGroups.Count) | **Estimated Tasks:** $totalTasks | **Effort:** $totalEffortDays developer-days")
    [void]$roadmap.Add("")

    # Executive summary from mission.md
    $missionPath = Join-Path $ProductDir "mission.md"
    if (Test-Path $missionPath) {
        $missionContent = Get-Content $missionPath -Raw
        if ($missionContent -match '(?ms)## Executive Summary\s*\n(.+?)(?=\n## |\z)') {
            [void]$roadmap.Add("## Executive Summary")
            [void]$roadmap.Add("")
            [void]$roadmap.Add($matches[1].Trim())
            [void]$roadmap.Add("")
        } elseif ($missionContent -match '(?m)^#[^#].*\n+(.+)') {
            [void]$roadmap.Add("## Executive Summary")
            [void]$roadmap.Add("")
            [void]$roadmap.Add($matches[1].Trim())
            [void]$roadmap.Add("")
        }
    }

    # Mermaid gantt chart — AI-assisted timeline
    [void]$roadmap.Add("## Timeline (AI-Assisted)")
    [void]$roadmap.Add("")
    [void]$roadmap.Add('```mermaid')
    [void]$roadmap.Add("gantt")
    [void]$roadmap.Add("    title $($groupsData.project_name) — AI-Assisted Timeline")
    [void]$roadmap.Add("    dateFormat YYYY-MM-DD")
    [void]$roadmap.Add("    axisFormat %b %d")
    [void]$roadmap.Add("")

    $today = Get-Date
    $groupEndDates = @{}

    foreach ($group in $sortedGroups) {
        $effortDays = if ($group.effort_days) { [int]$group.effort_days } else { 3 }
        $aiDays = [math]::Ceiling($effortDays / $aiSpeedupFactor)
        if ($aiDays -lt 1) { $aiDays = 1 }

        # Determine start date based on dependencies
        $startDate = $today
        if ($group.depends_on -and $group.depends_on.Count -gt 0) {
            foreach ($depId in $group.depends_on) {
                if ($groupEndDates.ContainsKey($depId) -and $groupEndDates[$depId] -gt $startDate) {
                    $startDate = $groupEndDates[$depId]
                }
            }
        }

        $endDate = $startDate.AddDays($aiDays)
        $groupEndDates[$group.id] = $endDate

        $startStr = $startDate.ToString("yyyy-MM-dd")
        # Sanitize name for Mermaid (remove special chars)
        $safeName = $group.name -replace '[:#]', ''

        [void]$roadmap.Add("    section $safeName")
        [void]$roadmap.Add("    $safeName :$($group.id), $startStr, ${aiDays}d")
    }

    [void]$roadmap.Add('```')
    [void]$roadmap.Add("")

    # Human vs AI comparison table
    [void]$roadmap.Add("## Human vs AI-Assisted Comparison")
    [void]$roadmap.Add("")
    [void]$roadmap.Add("| Group | Human (days) | AI (days) | Human Cost | AI Cost | Speedup |")
    [void]$roadmap.Add("|-------|-------------|-----------|------------|---------|---------|")

    $totalHumanDays = 0
    $totalAiDays = 0
    $totalHumanCost = [decimal]0
    $totalAiCost = [decimal]0

    foreach ($group in $sortedGroups) {
        $effortDays = if ($group.effort_days) { [int]$group.effort_days } else { 3 }
        $aiDays = [math]::Ceiling($effortDays / $aiSpeedupFactor)
        if ($aiDays -lt 1) { $aiDays = 1 }
        $taskCount = if ($group.estimated_task_count) { [int]$group.estimated_task_count } else { 3 }

        $humanCost = [decimal]($effortDays * 8 * $hourlyRate)
        $aiLaborCost = [decimal]($aiDays * 8 * $hourlyRate)
        $aiApiCost = [decimal]($taskCount * $aiCostPerTask)
        $groupAiCost = $aiLaborCost + $aiApiCost

        $totalHumanDays += $effortDays
        $totalAiDays += $aiDays
        $totalHumanCost += $humanCost
        $totalAiCost += $groupAiCost

        $speedup = if ($aiDays -gt 0) { "{0:N1}x" -f ($effortDays / $aiDays) } else { "N/A" }
        $safeName = $group.name -replace '\|', '/'

        [void]$roadmap.Add("| $safeName | $effortDays | $aiDays | $currency $("{0:N0}" -f $humanCost) | $currency $("{0:N0}" -f $groupAiCost) | $speedup |")
    }

    $totalSpeedup = if ($totalAiDays -gt 0) { "{0:N1}x" -f ($totalHumanDays / $totalAiDays) } else { "N/A" }
    [void]$roadmap.Add("| **Total** | **$totalHumanDays** | **$totalAiDays** | **$currency $("{0:N0}" -f $totalHumanCost)** | **$currency $("{0:N0}" -f $totalAiCost)** | **$totalSpeedup** |")
    [void]$roadmap.Add("")

    $savings = $totalHumanCost - $totalAiCost
    $savingsPercent = if ($totalHumanCost -gt 0) { [math]::Round(($savings / $totalHumanCost) * 100) } else { 0 }
    [void]$roadmap.Add("**Estimated savings:** $currency $("{0:N0}" -f $savings) ($savingsPercent%)")
    [void]$roadmap.Add("")

    # Implementation groups detail
    [void]$roadmap.Add("## Implementation Groups")
    [void]$roadmap.Add("")

    foreach ($group in $sortedGroups) {
        $depStr = if ($group.depends_on -and $group.depends_on.Count -gt 0) {
            " | Depends on: $(($group.depends_on) -join ', ')"
        } else { "" }

        [void]$roadmap.Add("### $($group.order). $($group.name)")
        [void]$roadmap.Add("")
        [void]$roadmap.Add("$($group.description)")
        [void]$roadmap.Add("")
        $effortDays = if ($group.effort_days) { $group.effort_days } else { "?" }
        [void]$roadmap.Add("- **Estimated tasks:** $($group.estimated_task_count) | **Effort:** $effortDays days$depStr")
        [void]$roadmap.Add("")
    }

    $overviewPath = Join-Path $ProductDir "roadmap-overview.md"
    $roadmap -join "`n" | Set-Content -Path $overviewPath -Encoding UTF8
    Write-Status "Roadmap overview generated: $overviewPath" -Type Success
} catch {
    Write-Status "Warning: could not generate roadmap overview: $($_.Exception.Message)" -Type Warn
}
