#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Hard gate — start-from-prompt clarification flow is wired in.
.DESCRIPTION
    Locks in the contract that 01-plan-product asks the user via
    task_mark_needs_input and records decisions, the mission.md template
    no longer contains an Open Questions section, and 01b-generate-decisions
    dedupes against existing decisions.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: start-from-prompt clarification (hard fail)" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$planProduct  = Join-Path $repoRoot 'workflows/start-from-prompt/recipes/prompts/01-plan-product.md'
$genDecisions = Join-Path $repoRoot 'workflows/start-from-prompt/recipes/prompts/01b-generate-decisions.md'

Assert-FileContains -Name '01-plan-product references task_mark_needs_input' `
    -Path $planProduct -Pattern 'task_mark_needs_input'

Assert-FileContains -Name '01-plan-product references decision_create' `
    -Path $planProduct -Pattern 'decision_create'

# Negative: the mission.md template block inside the prompt must not carry
# an Open Questions section. Scoped to just the template — explanatory text
# elsewhere in the prompt may legitimately mention the heading.
$planProductBody = Get-Content $planProduct -Raw
$missionTemplateMatch = [regex]::Match(
    $planProductBody,
    '(?ms)^### 1\.\s+`mission\.md`.*?(?=^### 2\.\s+`tech-stack\.md`)'
)
Assert-True -Name '01-plan-product contains the mission.md template section' `
    -Condition $missionTemplateMatch.Success `
    -Message 'Could not locate the mission.md template section in 01-plan-product.md'

$missionTemplateBody = if ($missionTemplateMatch.Success) { $missionTemplateMatch.Value } else { '' }
Assert-True -Name 'mission.md template has no Open Questions section' `
    -Condition ($missionTemplateBody -notmatch '(?m)^## Open Questions') `
    -Message 'Mission.md template still emits a "## Open Questions" section'

Assert-FileContains -Name '01b-generate-decisions has Step 0.5 listing existing decisions' `
    -Path $genDecisions -Pattern 'Step 0\.5: List Existing Decisions'

Assert-FileContains -Name '01b-generate-decisions invokes decision_list with status accepted' `
    -Path $genDecisions -Pattern 'mcp__dotbot__decision_list\(\{\s*status:\s*"accepted"\s*\}\)'

$results = Get-TestResults
[void](Write-TestSummary -LayerName "Layer 1: start-from-prompt clarification")
if ($results.Failed -gt 0) { exit 1 } else { exit 0 }
