<#
.SYNOPSIS
Expands task groups into detailed tasks by invoking Claude once per group.

.DESCRIPTION
Phase 2b orchestrator. Reads task-groups.json, topologically sorts groups by
dependencies, then expands each group sequentially by invoking Claude with
the 03b-expand-task-group.md template. After all groups are expanded, generates
a roadmap-overview.md summary.

.PARAMETER BotRoot
Path to the .bot directory.

.PARAMETER Model
Claude model name to use (e.g., claude-sonnet-4-6).

.PARAMETER ProcessId
Process registry ID for activity logging.
#>

param(
    [Parameter(Mandatory)]
    [string]$BotRoot,

    # Settings object passed by Invoke-WorkflowProcess (contains execution.model etc.)
    $Settings,

    # Explicit model override — takes precedence over Settings.execution.model
    [string]$Model,

    [string]$ProcessId,

    # When set, look for prompt templates here first (workflow-scoped install)
    [string]$WorkflowDir
)

# Resolve model: explicit param > settings object > fallback
if (-not $Model) {
    if ($Settings -and $Settings.execution -and $Settings.execution.model) {
        $Model = $Settings.execution.model
    } else {
        $Model = 'claude-sonnet-4-6'
    }
}

# --- Setup ---
Import-Module "$BotRoot\systems\runtime\ClaudeCLI\ClaudeCLI.psm1" -Force
Import-Module "$BotRoot\systems\runtime\ProviderCLI\ProviderCLI.psm1" -Force
Import-Module "$BotRoot\systems\runtime\modules\DotBotTheme.psm1" -Force

$productDir = Join-Path $BotRoot "workspace\product"
$todoDir = Join-Path $BotRoot "workspace\tasks\todo"
# Resolve template: workflow-scoped install takes priority, fall back to global prompts dir
$templatePath = $null
if ($WorkflowDir) {
    $candidate = Join-Path $WorkflowDir "recipes\prompts\03b-expand-task-group.md"
    if (Test-Path $candidate) { $templatePath = $candidate }
}
if (-not $templatePath) {
    $templatePath = Join-Path $BotRoot "recipes\prompts\03b-expand-task-group.md"
}
$groupsPath = Join-Path $productDir "task-groups.json"

# Set process ID for activity logging
if ($ProcessId) {
    $env:DOTBOT_PROCESS_ID = $ProcessId
}

# --- Helpers ---

function Write-GroupActivity {
    param([string]$Message)
    try { Write-ActivityLog -Type "text" -Message $Message } catch { Write-BotLog -Level Debug -Message "Logging operation failed" -Exception $_ }
    Write-Status $Message -Type Info
}

function Get-TopologicalOrder {
    param([array]$Groups)

    $sorted = [System.Collections.ArrayList]::new()
    $remaining = [System.Collections.ArrayList]::new()
    foreach ($g in $Groups) { [void]$remaining.Add($g) }
    $resolvedIds = @{}

    $maxIterations = $Groups.Count + 1
    $iteration = 0

    while ($remaining.Count -gt 0) {
        $iteration++
        if ($iteration -gt $maxIterations) {
            throw "Circular dependency detected among groups: $(($remaining | ForEach-Object { $_.id }) -join ', ')"
        }

        $ready = @($remaining | Where-Object {
            $allMet = $true
            if ($_.depends_on) {
                foreach ($dep in $_.depends_on) {
                    if (-not $resolvedIds.ContainsKey($dep)) { $allMet = $false; break }
                }
            }
            $allMet
        })

        if ($ready.Count -eq 0) {
            throw "Circular dependency detected among groups: $(($remaining | ForEach-Object { $_.id }) -join ', ')"
        }

        # Sort ready items by order field for deterministic output
        $ready = $ready | Sort-Object { $_.order }

        foreach ($g in $ready) {
            [void]$sorted.Add($g)
            $resolvedIds[$g.id] = $true
            $remaining.Remove($g) | Out-Null
        }
    }

    return $sorted.ToArray()
}

# --- Main ---

# 1. Read task-groups.json
if (-not (Test-Path $groupsPath)) {
    throw "task-groups.json not found at: $groupsPath"
}

$manifest = Get-Content $groupsPath -Raw | ConvertFrom-Json
$groups = @($manifest.groups)

Write-Header "Task Group Expansion"
Write-GroupActivity "Expanding $($groups.Count) task groups into detailed tasks"

# 2. Read template
if (-not (Test-Path $templatePath)) {
    throw "Template not found: $templatePath"
}
$template = Get-Content $templatePath -Raw

# 3. Topological sort
$sortedGroups = Get-TopologicalOrder -Groups $groups
Write-GroupActivity "Expansion order: $(($sortedGroups | ForEach-Object { $_.name }) -join ' -> ')"

# 4. Expand each group
$groupTaskMap = @{}  # group_id -> array of {id, name}
$totalTasksCreated = 0

foreach ($group in $sortedGroups) {
    Write-Header "Group: $($group.name)"
    Write-GroupActivity "Expanding group: $($group.name) (order $($group.order))"

    # Build dependency task list from prerequisite groups
    $depTasks = @()
    if ($group.depends_on) {
        foreach ($depGroupId in $group.depends_on) {
            if ($groupTaskMap.ContainsKey($depGroupId)) {
                $depTasks += $groupTaskMap[$depGroupId]
            }
        }
    }

    $depTasksJson = if ($depTasks.Count -gt 0) {
        "Tasks from prerequisite groups:`n``````json`n$($depTasks | ConvertTo-Json -Depth 5)`n```````n`nYou may reference these task IDs in the ``dependencies`` array where technically justified."
    } else {
        "No prerequisite tasks. This is a root group with no cross-group dependencies."
    }

    # Build scope list
    $scopeList = if ($group.scope) {
        ($group.scope | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "- (No specific scope items defined)"
    }

    # Build acceptance criteria list
    $acList = if ($group.acceptance_criteria) {
        ($group.acceptance_criteria | ForEach-Object { "- $_" }) -join "`n"
    } else {
        "- (No specific acceptance criteria defined)"
    }

    # Extract priority range
    $priorityMin = if ($group.priority_range -and $group.priority_range.Count -ge 2) { $group.priority_range[0] } else { 1 }
    $priorityMax = if ($group.priority_range -and $group.priority_range.Count -ge 2) { $group.priority_range[1] } else { 100 }

    # Substitute template variables
    $prompt = $template
    $prompt = $prompt -replace '\{\{GROUP_ID\}\}', $group.id
    $prompt = $prompt -replace '\{\{GROUP_NAME\}\}', $group.name
    $prompt = $prompt -replace '\{\{GROUP_DESCRIPTION\}\}', $group.description
    $prompt = $prompt -replace '\{\{GROUP_SCOPE\}\}', $scopeList
    $prompt = $prompt -replace '\{\{GROUP_ACCEPTANCE_CRITERIA\}\}', $acList
    $prompt = $prompt -replace '\{\{PRIORITY_MIN\}\}', $priorityMin
    $prompt = $prompt -replace '\{\{PRIORITY_MAX\}\}', $priorityMax
    $prompt = $prompt -replace '\{\{CATEGORY_HINT\}\}', $group.category_hint
    $prompt = $prompt -replace '\{\{DEPENDENCY_TASKS\}\}', $depTasksJson

    # Snapshot todo directory before expansion
    $beforeFiles = @()
    if (Test-Path $todoDir) {
        $beforeFiles = @(Get-ChildItem -Path $todoDir -Filter "*.json" | ForEach-Object { $_.FullName })
    }

    # Invoke provider to expand this group
    $sessionId = New-ProviderSession
    try {
        Invoke-ProviderStream -Prompt $prompt -Model $Model -SessionId $sessionId -PersistSession:$false
    } catch {
        Write-GroupActivity "Error expanding group $($group.name): $($_.Exception.Message)"
        Write-Status "Failed to expand group: $($group.name)" -Type Error
        continue
    }

    # Discover newly created tasks
    $afterFiles = @()
    if (Test-Path $todoDir) {
        $afterFiles = @(Get-ChildItem -Path $todoDir -Filter "*.json" | ForEach-Object { $_.FullName })
    }
    $newFiles = @($afterFiles | Where-Object { $_ -notin $beforeFiles })

    $newTasks = @()
    foreach ($f in $newFiles) {
        try {
            $taskData = Get-Content $f -Raw | ConvertFrom-Json
            $newTasks += @{ id = $taskData.id; name = $taskData.name }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    $groupTaskMap[$group.id] = $newTasks
    $totalTasksCreated += $newTasks.Count

    Write-GroupActivity "Group '$($group.name)' expanded: $($newTasks.Count) tasks created"

    # Brief pause between groups to avoid rate limits
    if ($group -ne $sortedGroups[-1]) {
        Start-Sleep -Seconds 2
    }
}

# 5. Append expansion results to roadmap-overview.md (generated in Phase 2a)
Write-GroupActivity "Appending expansion results to roadmap overview..."

$overviewPath = Join-Path $productDir "roadmap-overview.md"
$appendLines = [System.Collections.ArrayList]::new()
[void]$appendLines.Add("")
[void]$appendLines.Add("---")
[void]$appendLines.Add("")
[void]$appendLines.Add("## Expansion Results")
[void]$appendLines.Add("")
[void]$appendLines.Add("**Total tasks created:** $totalTasksCreated")
[void]$appendLines.Add("")

foreach ($group in $sortedGroups) {
    $taskCount = if ($groupTaskMap.ContainsKey($group.id)) { $groupTaskMap[$group.id].Count } else { 0 }
    [void]$appendLines.Add("### $($group.order). $($group.name) ($taskCount tasks)")
    [void]$appendLines.Add("")

    if ($groupTaskMap.ContainsKey($group.id)) {
        foreach ($task in $groupTaskMap[$group.id]) {
            [void]$appendLines.Add("  - $($task.name)")
        }
        [void]$appendLines.Add("")
    }
}

[void]$appendLines.Add("## Next Steps")
[void]$appendLines.Add("")
[void]$appendLines.Add("1. Review task list and adjust priorities if needed")
[void]$appendLines.Add("2. Begin implementation with ``task_get_next``")
[void]$appendLines.Add("3. Run analysis loop to prepare tasks for execution")
[void]$appendLines.Add("")

if (Test-Path $overviewPath) {
    $appendLines -join "`n" | Add-Content -Path $overviewPath -Encoding UTF8
} else {
    # Fallback if Phase 2a roadmap wasn't generated
    $appendLines -join "`n" | Set-Content -Path $overviewPath -Encoding UTF8
}
Write-GroupActivity "Expansion results appended to: $overviewPath"

# Final summary
Write-Header "Expansion Complete"
Write-GroupActivity "Task group expansion complete: $totalTasksCreated tasks created across $($sortedGroups.Count) groups"

# Emit a structured phase-completion marker so UI/state code can latch on
# without parsing the free-text Write-GroupActivity message above.
try {
    Write-ActivityLog -Type "phase_complete" -Message "phase=task-group-expansion tasks_created=$totalTasksCreated groups=$($sortedGroups.Count)"
} catch { Write-BotLog -Level Debug -Message "phase_complete marker write failed" -Exception $_ }
