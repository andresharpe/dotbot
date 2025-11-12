# validate-references.ps1
# Validates that all workflow, agent, and standard references are correct in dotbot

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
$profilePath = Join-Path $repoRoot "profiles\default"

Write-Host "==================================" -ForegroundColor Cyan
Write-Host "dotbot Reference Validation" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
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
            Write-Host "  ✓ " -ForegroundColor Green -NoNewline
            Write-Host $Context
        }
        return $true
    } else {
        $script:issues += "❌ $Context - File not found: $Path"
        Write-Host "  ✗ " -ForegroundColor Red -NoNewline
        Write-Host $Context
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
Write-Host "1. Validating Agents..." -ForegroundColor Yellow

$agentFiles = Get-ChildItem -Path (Join-Path $profilePath "agents") -Filter "*.md"
Write-Host "   Found $($agentFiles.Count) agent files" -ForegroundColor Gray

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
Write-Host "2. Validating Commands..." -ForegroundColor Yellow

$commandFiles = Get-ChildItem -Path (Join-Path $profilePath "commands") -Filter "*.md"
Write-Host "   Found $($commandFiles.Count) command files" -ForegroundColor Gray

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
Write-Host "3. Validating Workflows..." -ForegroundColor Yellow

$workflowFiles = Get-ChildItem -Path (Join-Path $profilePath "workflows") -Filter "*.md" -Recurse
Write-Host "   Found $($workflowFiles.Count) workflow files" -ForegroundColor Gray

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
        $issues += "⚠️ Workflow '$workflowName' doesn't specify an agent"
        Write-Host "  ⚠ Workflow '$workflowName' missing agent reference" -ForegroundColor Yellow
    } elseif ($agentRefs.Count -gt 1) {
        $issues += "⚠️ Workflow '$workflowName' specifies multiple agents"
        Write-Host "  ⚠ Workflow '$workflowName' has multiple agent references" -ForegroundColor Yellow
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
Write-Host "4. Validating README Counts..." -ForegroundColor Yellow

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
    Write-Host "  ✓ Agents count: $actualAgents matches README" -ForegroundColor Green
} else {
    $issues += "❌ README claims $claimedAgents agents, but found $actualAgents"
    Write-Host "  ✗ Agents count: $actualAgents but README claims $claimedAgents" -ForegroundColor Red
}

$checks++
if ($actualCommands -eq $claimedCommands) {
    $passed++
    Write-Host "  ✓ Commands count: $actualCommands matches README" -ForegroundColor Green
} else {
    $issues += "❌ README claims $claimedCommands commands, but found $actualCommands"
    Write-Host "  ✗ Commands count: $actualCommands but README claims $claimedCommands" -ForegroundColor Red
}

$checks++
if ($actualStandards -eq $claimedStandards) {
    $passed++
    Write-Host "  ✓ Standards count: $actualStandards matches README" -ForegroundColor Green
} else {
    $issues += "❌ README claims $claimedStandards standards, but found $actualStandards"
    Write-Host "  ✗ Standards count: $actualStandards but README claims $claimedStandards" -ForegroundColor Red
}

$checks++
if ($actualWorkflows -eq $claimedWorkflows) {
    $passed++
    Write-Host "  ✓ Workflows count: $actualWorkflows matches README" -ForegroundColor Green
} else {
    $issues += "❌ README claims $claimedWorkflows workflows, but found $actualWorkflows"
    Write-Host "  ✗ Workflows count: $actualWorkflows but README claims $claimedWorkflows" -ForegroundColor Red
}

Write-Host ""

# ====================
# Summary
# ====================
Write-Host "==================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total Checks: $checks" -ForegroundColor Gray
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Issues: $($issues.Count)" -ForegroundColor $(if ($issues.Count -eq 0) { "Green" } else { "Red" })
Write-Host ""

if ($issues.Count -gt 0) {
    Write-Host "Issues Found:" -ForegroundColor Red
    Write-Host ""
    foreach ($issue in $issues) {
        Write-Host "  $issue" -ForegroundColor Yellow
    }
    Write-Host ""
    exit 1
} else {
    Write-Host "✅ All references validated successfully!" -ForegroundColor Green
    Write-Host ""
    exit 0
}
