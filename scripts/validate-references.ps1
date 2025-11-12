# validate-references.ps1
# Validates that all workflow, agent, and standard references are correct in dotbot

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$profilePath = Join-Path $repoRoot "profiles\default"

# Import common functions
$commonFunctionsPath = Join-Path $scriptDir "Common-Functions.psm1"
if (Test-Path $commonFunctionsPath) {
    Import-Module $commonFunctionsPath -Force
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    D O T B O T" -ForegroundColor White
Write-Host "    Reference Validation" -ForegroundColor Gray
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""

$issues = @()
$checks = 0
$passed = 0

function Test-FileExists {
    param($Path, $Context)
    
    $script:checks++
    if (Test-Path $Path) {
        $script:passed++
        if ($Verbose) {
            Write-Host "    ✓ " -ForegroundColor Blue -NoNewline
            Write-Host $Context -ForegroundColor Gray
        }
        return $true
    } else {
        $script:issues += "$Context - File not found: $Path"
        Write-Host "    ✗ " -ForegroundColor Red -NoNewline
        Write-Host $Context -ForegroundColor Gray
        return $false
    }
}

function Extract-References {
    param($FilePath, $Pattern)
    
    if (-not (Test-Path $FilePath)) {
        return @()
    }
    
    $content = Get-Content $FilePath -Raw
    $matches = [regex]::Matches($content, $Pattern)
    
    return $matches | ForEach-Object { $_.Groups[1].Value }
}

# =======================
# 1. Validate Agent Files
# =======================
Write-Host ""
Write-Host "  AGENTS" -ForegroundColor White
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$agentFiles = Get-ChildItem -Path (Join-Path $profilePath "agents") -Filter "*.md"
Write-Host "    Found:    $($agentFiles.Count) agent files" -ForegroundColor Gray

foreach ($agent in $agentFiles) {
    $agentName = $agent.BaseName
    
    # Check that agent references workflows
    $workflowRefs = Extract-References $agent.FullName '\.bot/workflows/([^\s\)]+)'
    
    if ($workflowRefs.Count -eq 0 -and $Verbose) {
        Write-Host "  ⚠ Agent $agentName doesn't reference any workflows" -ForegroundColor Yellow
    }
    
    # Check that agent references standards
    $standardRefs = Extract-References $agent.FullName '\.bot/standards/([^\s\)]+)'
    
    if ($standardRefs.Count -eq 0 -and $Verbose) {
        Write-Host "  ⚠ Agent $agentName doesn't reference specific standards (may use wildcards)" -ForegroundColor Yellow
    }
}

Write-Host ""

# ==========================
# 2. Validate Command Files
# ==========================
Write-Host "  COMMANDS" -ForegroundColor White
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$commandFiles = Get-ChildItem -Path (Join-Path $profilePath "commands") -Filter "*.md"
Write-Host "    Found:    $($commandFiles.Count) command files" -ForegroundColor Gray

foreach ($command in $commandFiles) {
    $commandName = $command.BaseName
    
    # Check workflow references
    $workflowRefs = Extract-References $command.FullName '\.bot/workflows/([^\s\)]+\.md)'
    
    foreach ($ref in $workflowRefs) {
        $workflowPath = Join-Path $profilePath "workflows\$ref"
        Test-FileExists $workflowPath "Command '$commandName' → Workflow '$ref'" | Out-Null
    }
    
    # Check standard references
    $standardRefs = Extract-References $command.FullName '\.bot/standards/([^\s\)]+\.md)'
    
    foreach ($ref in $standardRefs) {
        $standardPath = Join-Path $profilePath "standards\$ref"
        Test-FileExists $standardPath "Command '$commandName' → Standard '$ref'" | Out-Null
    }
}

Write-Host ""

# ===========================
# 3. Validate Workflow Files
# ===========================
Write-Host "  WORKFLOWS" -ForegroundColor White
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$workflowFiles = Get-ChildItem -Path (Join-Path $profilePath "workflows") -Filter "*.md" -Recurse
Write-Host "    Found:    $($workflowFiles.Count) workflow files" -ForegroundColor Gray

foreach ($workflow in $workflowFiles) {
    $workflowName = $workflow.BaseName
    
    # Check agent references (should have exactly one)
    $agentPattern = '(?s)\*\*Agent:\*\*\s*@\.bot/agents/([a-zA-Z0-9_-]+\.md)'
    $content = Get-Content $workflow.FullName -Raw
    $match = [regex]::Match($content, $agentPattern)
    if ($match.Success) {
        $agentRefs = @($match.Groups[1].Value)
    } else {
        $agentRefs = @()
    }
    
    if ($agentRefs.Count -eq 0) {
        $issues += "Workflow '$workflowName' doesn't specify an agent"
        Write-Host "    ⚠ Workflow '$workflowName' missing agent reference" -ForegroundColor Yellow
    } elseif ($agentRefs.Count -gt 1) {
        $issues += "Workflow '$workflowName' specifies multiple agents"
        Write-Host "    ⚠ Workflow '$workflowName' has multiple agent references" -ForegroundColor Yellow
    } else {
        $agentPath = Join-Path $profilePath "agents\$($agentRefs[0])"
        Test-FileExists $agentPath "Workflow '$workflowName' → Agent '$($agentRefs[0])'" | Out-Null
    }
    
    # Check standard references
    $standardRefs = Extract-References $workflow.FullName '\.bot/standards/([^\s\*\)]+\.md)'
    
    foreach ($ref in $standardRefs) {
        $standardPath = Join-Path $profilePath "standards\$ref"
        Test-FileExists $standardPath "Workflow '$workflowName' → Standard '$ref'" | Out-Null
    }
}

Write-Host ""

# ==========================
# 4. Validate README Counts
# ==========================
Write-Host "  README COUNTS" -ForegroundColor White
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$readmePath = Join-Path $repoRoot "README.md"
$readmeContent = Get-Content $readmePath -Raw

# Count actual files
$actualAgents = (Get-ChildItem -Path (Join-Path $profilePath "agents") -Filter "*.md").Count
$actualCommands = (Get-ChildItem -Path (Join-Path $profilePath "commands") -Filter "*.md").Count
$actualStandards = (Get-ChildItem -Path (Join-Path $profilePath "standards") -Filter "*.md" -Recurse).Count
$actualWorkflows = (Get-ChildItem -Path (Join-Path $profilePath "workflows") -Filter "*.md" -Recurse).Count

# Extract README claims
if ($readmeContent -match 'Agents \((\d+) total\)') {
    $claimedAgents = [int]$Matches[1]
} else {
    $claimedAgents = -1
}

if ($readmeContent -match 'Commands \((\d+) total\)') {
    $claimedCommands = [int]$Matches[1]
} else {
    $claimedCommands = -1
}

if ($readmeContent -match 'Standards \((\d+) files\)') {
    $claimedStandards = [int]$Matches[1]
} else {
    $claimedStandards = -1
}

if ($readmeContent -match 'Workflows \((\d+) files\)') {
    $claimedWorkflows = [int]$Matches[1]
} else {
    $claimedWorkflows = -1
}

# Validate counts
$checks++
if ($actualAgents -eq $claimedAgents) {
    $passed++
    Write-Host "    Agents:   ✓ $actualAgents (matches README)" -ForegroundColor Gray
} else {
    $issues += "README claims $claimedAgents agents, but found $actualAgents"
    Write-Host "    Agents:   ✗ $actualAgents (README claims $claimedAgents)" -ForegroundColor Red
}

$checks++
if ($actualCommands -eq $claimedCommands) {
    $passed++
    Write-Host "    Commands: ✓ $actualCommands (matches README)" -ForegroundColor Gray
} else {
    $issues += "README claims $claimedCommands commands, but found $actualCommands"
    Write-Host "    Commands: ✗ $actualCommands (README claims $claimedCommands)" -ForegroundColor Red
}

$checks++
if ($actualStandards -eq $claimedStandards) {
    $passed++
    Write-Host "    Standards: ✓ $actualStandards (matches README)" -ForegroundColor Gray
} else {
    $issues += "README claims $claimedStandards standards, but found $actualStandards"
    Write-Host "    Standards: ✗ $actualStandards (README claims $claimedStandards)" -ForegroundColor Red
}

$checks++
if ($actualWorkflows -eq $claimedWorkflows) {
    $passed++
    Write-Host "    Workflows: ✓ $actualWorkflows (matches README)" -ForegroundColor Gray
} else {
    $issues += "README claims $claimedWorkflows workflows, but found $actualWorkflows"
    Write-Host "    Workflows: ✗ $actualWorkflows (README claims $claimedWorkflows)" -ForegroundColor Red
}

Write-Host ""

# ====================
# Summary
# ====================
Write-Host ""
Write-Host "  VALIDATION SUMMARY" -ForegroundColor White
Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Total Checks: $checks" -ForegroundColor Gray
Write-Host "    Passed:       $passed" -ForegroundColor Gray
Write-Host "    Issues:       $($issues.Count)" -ForegroundColor $(if ($issues.Count -eq 0) { "Gray" } else { "Red" })
Write-Host ""

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  ISSUES FOUND" -ForegroundColor Red
    Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    foreach ($issue in $issues) {
        Write-Host "    ✗ $issue" -ForegroundColor Yellow
    }
    Write-Host ""
    exit 1
} else {
    Write-Host "    Status:       ✓ All references validated" -ForegroundColor Gray
    Write-Host ""
    exit 0
}
