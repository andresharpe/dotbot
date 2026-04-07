#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Structure tests for the dotbot-code-review skill.
.DESCRIPTION
    Validates that the dotbot-code-review SKILL.md is properly installed,
    has valid frontmatter, contains all required sections, and includes
    PR comment posting with line-level specifics and prior agent review.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot
$skillDir = Join-Path $repoRoot ".claude\skills\dotbot-code-review"
$skillFile = Join-Path $skillDir "SKILL.md"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Skill: dotbot-code-review Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# SKILL FILE STRUCTURE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  SKILL FILE STRUCTURE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

Assert-PathExists -Name "Skill directory exists" -Path $skillDir
Assert-PathExists -Name "SKILL.md exists" -Path $skillFile

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# FRONTMATTER VALIDATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FRONTMATTER VALIDATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $skillFile) {
    $content = Get-Content $skillFile -Raw

    # Check YAML frontmatter delimiters
    Assert-True -Name "Has YAML frontmatter opening delimiter" `
        -Condition ($content -match '^---\s*\r?\n') `
        -Message "SKILL.md must start with '---' YAML frontmatter delimiter"

    # Extract frontmatter
    $frontmatterMatch = [regex]::Match($content, '(?s)^---\s*\r?\n(.+?)\r?\n---')
    Assert-True -Name "Has YAML frontmatter closing delimiter" `
        -Condition $frontmatterMatch.Success `
        -Message "SKILL.md must have closing '---' YAML frontmatter delimiter"

    if ($frontmatterMatch.Success) {
        $frontmatter = $frontmatterMatch.Groups[1].Value

        # Required fields
        Assert-True -Name "Frontmatter has 'name' field" `
            -Condition ($frontmatter -match 'name:\s*\S+') `
            -Message "Missing 'name' field in frontmatter"

        Assert-True -Name "Frontmatter has 'description' field" `
            -Condition ($frontmatter -match 'description:\s*\S+') `
            -Message "Missing 'description' field in frontmatter"

        # Name matches expected value
        Assert-True -Name "Skill name is 'dotbot-code-review'" `
            -Condition ($frontmatter -match 'name:\s*dotbot-code-review') `
            -Message "Expected name 'dotbot-code-review' in frontmatter"
    }

    # Model requirement
    Assert-True -Name "Specifies required model section" `
        -Condition ($content -match '## Required model') `
        -Message "Must have a '## Required model' section"

    Assert-True -Name "Requires Claude Opus 4" `
        -Condition ($content -match 'Claude Opus 4' -and $content -match 'claude-opus-4') `
        -Message "Must require Claude Opus 4 as the model"

    Assert-True -Name "Warns against downgraded models" `
        -Condition ($content -match 'Sonnet' -and $content -match 'Haiku') `
        -Message "Must warn against running with Sonnet or Haiku"
} else {
    Write-TestResult -Name "Frontmatter tests" -Status Skip -Message "SKILL.md not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CONTENT COMPLETENESS — PROCEDURE STEPS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CONTENT COMPLETENESS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $skillFile) {
    $content = Get-Content $skillFile -Raw

    # All procedure steps present
    $steps = @(
        @{ Name = "Step 1 — Locate conventions";                   Pattern = "Step 1 .* Locate conventions" }
        @{ Name = "Step 1b — Review existing automated PR comments"; Pattern = "Step 1b .* Review existing automated PR comments" }
        @{ Name = "Step 2 — Launch 5 parallel review agents";      Pattern = "Step 2 .* Launch 5 parallel review agents" }
        @{ Name = "Step 3 — Validate every issue";                 Pattern = "Step 3 .* Validate every issue" }
        @{ Name = "Step 4 — Confidence scoring";                   Pattern = "Step 4 .* Confidence scoring" }
        @{ Name = "Step 5 — Output";                               Pattern = "Step 5 .* Output" }
        @{ Name = "Step 6 — Post review comments to GitHub PR";    Pattern = "Step 6 .* Post review comments" }
    )

    foreach ($step in $steps) {
        Assert-True -Name "Has $($step.Name)" `
            -Condition ($content -match $step.Pattern) `
            -Message "Missing procedure step: $($step.Name)"
    }

    # All 5 agents described
    $agents = @(
        @{ Name = "Agent 1 — Convention compliance (A)"; Pattern = "Agent 1 .* Convention compliance \(A\)" }
        @{ Name = "Agent 2 — Convention compliance (B)"; Pattern = "Agent 2 .* Convention compliance \(B\)" }
        @{ Name = "Agent 3 — Bug hunter";                Pattern = "Agent 3 .* Bug hunter" }
        @{ Name = "Agent 4 — DOTBOT security";           Pattern = "Agent 4 .* DOTBOT security" }
        @{ Name = "Agent 5 — Architecture";              Pattern = "Agent 5 .* Architecture" }
    )

    foreach ($agent in $agents) {
        Assert-True -Name "Has $($agent.Name)" `
            -Condition ($content -match $agent.Pattern) `
            -Message "Missing agent definition: $($agent.Name)"
    }

    # Hard rules section
    Assert-True -Name "Has 'Hard rules' section" `
        -Condition ($content -match '## Hard rules') `
        -Message "Missing '## Hard rules' section"

    # Severity levels defined
    foreach ($severity in @('BLOCKER', 'MAJOR', 'MINOR', 'NIT')) {
        Assert-True -Name "Defines severity level: $severity" `
            -Condition ($content -match "``$severity``") `
            -Message "Missing severity level definition: $severity"
    }

    # Verdict options
    foreach ($verdict in @('ship', 'fix majors first', 'needs rework')) {
        Assert-True -Name "Defines verdict: $verdict" `
            -Condition ($content -match [regex]::Escape($verdict)) `
            -Message "Missing verdict option: $verdict"
    }

    # Test coverage enforcement
    Assert-True -Name "Enforces test coverage for PR changes" `
        -Condition ($content -match 'test coverage' -and $content -match 'must.*include.*tests') `
        -Message "Must require PRs to include tests for changed/added functionality"

    Assert-True -Name "Checks for corresponding test files in diff" `
        -Condition ($content -match 'test file' -and $content -match 'tests/' ) `
        -Message "Must check whether the diff includes changes to corresponding test files"

    Assert-True -Name "Flags missing tests as MAJOR severity" `
        -Condition ($content -match '\[MAJOR\].*test' -or $content -match 'MAJOR.*without.*test') `
        -Message "Missing test coverage should be flagged as MAJOR severity"

    Assert-True -Name "Has exceptions for non-functional changes" `
        -Condition ($content -match 'documentation changes' -or $content -match 'Pure documentation') `
        -Message "Must exempt pure documentation/config changes from test requirement"

    # Verify key exemptions are comprehensive
    $exemptions = @(
        @{ Name = "SKILL.md files";     Pattern = "SKILL\.md" }
        @{ Name = "CI/CD pipelines";    Pattern = "CI/CD|github/workflows" }
        @{ Name = "Editor/env configs"; Pattern = "\.gitignore|\.editorconfig" }
        @{ Name = "Style-only changes"; Pattern = "CSS|SCSS|style-only" }
        @{ Name = "Comment-only changes"; Pattern = "Comment-only" }
        @{ Name = "Dependency bumps";   Pattern = "version bump|Dependency" }
    )

    foreach ($exemption in $exemptions) {
        Assert-True -Name "Test exemption covers $($exemption.Name)" `
            -Condition ($content -match $exemption.Pattern) `
            -Message "Test coverage exceptions must include $($exemption.Name)"
    }

} else {
    Write-TestResult -Name "Content completeness tests" -Status Skip -Message "SKILL.md not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PR COMMENT SPECIFICS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PR COMMENT SPECIFICS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $skillFile) {
    $content = Get-Content $skillFile -Raw

    # Uses gh api for line-level comments
    Assert-True -Name "Uses 'gh api' for PR review posting" `
        -Condition ($content -match 'gh api') `
        -Message "Skill must use 'gh api' for posting line-level review comments"

    # References the pulls reviews endpoint
    Assert-True -Name "References pulls/{pr}/reviews API endpoint" `
        -Condition ($content -match 'pulls/.*reviews') `
        -Message "Must reference the GitHub pulls reviews API endpoint"

    # Uses gh pr review for verdict
    Assert-True -Name "References 'gh pr review' or review event types" `
        -Condition ($content -match 'gh pr review' -or $content -match 'APPROVE' -or $content -match 'REQUEST_CHANGES') `
        -Message "Must reference gh pr review or GitHub review event types"

    # Contains suggestion block syntax
    Assert-True -Name "Contains 'suggestion' code block syntax" `
        -Condition ($content -match '``suggestion') `
        -Message "Must include GitHub suggestion block syntax for Apply Suggestion support"

    # Line-level comment fields
    Assert-True -Name "References 'start_line' field for multi-line comments" `
        -Condition ($content -match 'start_line') `
        -Message "Must reference 'start_line' for multi-line PR comment placement"

    Assert-True -Name "References 'path' field for file targeting" `
        -Condition ($content -match '"path"') `
        -Message "Must reference 'path' field for targeting comments to specific files"

    Assert-True -Name "References 'side' field for diff side" `
        -Condition ($content -match '"side"') `
        -Message "Must reference 'side' field (LEFT/RIGHT) for diff comment placement"

    # Full SHA requirement
    Assert-True -Name "Requires full SHA for commit references" `
        -Condition ($content -match 'Full SHA' -or $content -match 'git rev-parse HEAD') `
        -Message "Must require full SHA for GitHub markdown link rendering"

    # Fallback mechanism
    Assert-True -Name "Has fallback for API failure" `
        -Condition ($content -match 'Fallback' -and $content -match 'gh pr comment') `
        -Message "Must include fallback to 'gh pr comment' when API posting fails"

} else {
    Write-TestResult -Name "PR comment tests" -Status Skip -Message "SKILL.md not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PRIOR AGENT REVIEW
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PRIOR AGENT REVIEW" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $skillFile) {
    $content = Get-Content $skillFile -Raw

    # Bot detection pattern
    Assert-True -Name "References [bot] suffix for automated reviewer detection" `
        -Condition ($content -match '\[bot\]') `
        -Message "Must reference [bot] login suffix to identify automated reviewers"

    # Known bot names
    $knownBots = @('copilot', 'codex', 'coderabbitai', 'github-actions')
    foreach ($bot in $knownBots) {
        Assert-True -Name "Lists known bot: $bot" `
            -Condition ($content -match [regex]::Escape($bot)) `
            -Message "Should list '$bot' as a known automated reviewer"
    }

    # Fetches existing comments
    Assert-True -Name "Fetches existing PR comments via API" `
        -Condition ($content -match 'pulls/.*comments.*--paginate' -or $content -match 'gh api.*pulls.*comments') `
        -Message "Must fetch existing PR review comments"

    # Resolution status
    Assert-True -Name "Checks comment resolution status (isResolved)" `
        -Condition ($content -match 'isResolved' -or $content -match 'reviewThreads') `
        -Message "Must check whether prior comments are resolved"

    # Prior Agent Review Summary in output
    Assert-True -Name "Includes 'Prior Agent Review Summary' in output" `
        -Condition ($content -match 'Prior Agent Review Summary') `
        -Message "Output must include a Prior Agent Review Summary section"

    # Non-duplication rule
    Assert-True -Name "Has non-duplication rule for prior findings" `
        -Condition ($content -match 'Not duplicate' -or $content -match 'Never duplicate') `
        -Message "Must instruct agents not to duplicate issues already flagged by prior reviewers"

    # Confirm/dispute mechanism
    Assert-True -Name "Agents can confirm or dispute prior findings" `
        -Condition ($content -match 'Confirm or dispute' -or $content -match 'Confirming.*finding') `
        -Message "Agents must be able to confirm or dispute prior automated review findings"

} else {
    Write-TestResult -Name "Prior agent review tests" -Status Skip -Message "SKILL.md not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# OUTPUT FORMAT — LINE REFERENCES & CODE EXAMPLES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  OUTPUT FORMAT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $skillFile) {
    $content = Get-Content $skillFile -Raw

    # Requires line ranges in findings
    Assert-True -Name "Output format includes file:line range pattern" `
        -Condition ($content -match 'path/to/file.*:L\d+-L\d+' -or $content -match 'file\.cs:L\d+-L\d+') `
        -Message "Finding format must include file path with line range (e.g. file.cs:L42-L48)"

    # Requires current code snippet
    Assert-True -Name "Output format includes current code snippet" `
        -Condition ($content -match 'Current code') `
        -Message "Finding format must include a snippet of the current code"

    # Requires suggested fix
    Assert-True -Name "Output format includes suggested fix" `
        -Condition ($content -match 'Suggested fix') `
        -Message "Finding format must include a concrete suggested fix"

    # Max lines rule
    Assert-True -Name "Limits quoted source lines per finding" `
        -Condition ($content -match '\d+ lines') `
        -Message "Must specify a maximum number of source lines to quote per finding"

    # Minimal change rule
    Assert-True -Name "Requires minimal fix (not wholesale rewrite)" `
        -Condition ($content -match 'minimal' -or $content -match 'Never rewrite.*wholesale') `
        -Message "Must instruct to show minimal fix, not rewrite entire sections"

} else {
    Write-TestResult -Name "Output format tests" -Status Skip -Message "SKILL.md not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# POWERSHELL COMPATIBILITY
# ═══════════════════════════════════════════════════════════════════

Write-Host "  POWERSHELL COMPATIBILITY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $skillFile) {
    $content = Get-Content $skillFile -Raw

    # Uses pwsh for command examples (not bash-only)
    Assert-True -Name "Uses pwsh code blocks for PowerShell examples" `
        -Condition ($content -match '```pwsh') `
        -Message "PowerShell command examples should use ```pwsh code fence"

    # Uses PowerShell-native constructs
    Assert-True -Name "Uses ConvertTo-Json for JSON construction" `
        -Condition ($content -match 'ConvertTo-Json') `
        -Message "Should use PowerShell-native ConvertTo-Json for building payloads"

    Assert-True -Name "Uses ConvertFrom-Json for parsing API responses" `
        -Condition ($content -match 'ConvertFrom-Json') `
        -Message "Should use PowerShell-native ConvertFrom-Json for parsing responses"

} else {
    Write-TestResult -Name "PowerShell compatibility tests" -Status Skip -Message "SKILL.md not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Skill: dotbot-code-review"

if (-not $allPassed) {
    exit 1
}
