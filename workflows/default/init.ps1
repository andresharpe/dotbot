#!/usr/bin/env pwsh
# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
<#
.SYNOPSIS
    Initialize IDE integrations by copying agents and skills to .claude/, .codex/, and .gemini/ directories.

.DESCRIPTION
    This script bridges the .bot/ system with AI coding CLIs by copying agent and skill
    definitions from .bot/recipes/ to each provider's IDE directory. For non-Claude providers,
    AGENT.md model fields are rewritten to match the provider's default model.

    Idempotent — can be run repeatedly without issues.

.NOTES
    This script should be run from the project root directory.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Get script and project directories
$BotDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $BotDir
$ProvidersDir = Join-Path $BotDir "settings\providers"

Write-Status "Initializing IDE integrations..."
Write-BlankLine

# Define the provider IDE directories to set up
$providerDirs = @(
    @{ Name = "claude"; Dir = ".claude" }
    @{ Name = "codex";  Dir = ".codex" }
    @{ Name = "gemini"; Dir = ".gemini" }
)

# Load provider configs for model rewriting
$providerConfigs = @{}
if (Test-Path $ProvidersDir) {
    Get-ChildItem $ProvidersDir -Filter "*.json" | ForEach-Object {
        try {
            $config = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $providerConfigs[$config.name] = $config
        } catch {
            Write-DotbotWarning "Failed to load provider config: $($_.Name)"
        }
    }
}

$SourceAgentsDir = Join-Path $BotDir "recipes\agents"
$SourceSkillsDir = Join-Path $BotDir "recipes\skills"

foreach ($provider in $providerDirs) {
    $providerName = $provider.Name
    $ideDir = Join-Path $ProjectRoot $provider.Dir

    # Create IDE directory if it doesn't exist
    if (-not (Test-Path $ideDir)) {
        Write-Status "Creating $($provider.Dir) directory..."
        New-Item -ItemType Directory -Path $ideDir | Out-Null
    }

    # Copy agents
    $DestAgentsDir = Join-Path $ideDir "agents"

    if (Test-Path $SourceAgentsDir) {
        if (Test-Path $DestAgentsDir) {
            Remove-Item -Path $DestAgentsDir -Recurse -Force
        }

        Copy-Item -Path $SourceAgentsDir -Destination $DestAgentsDir -Recurse

        # For non-Claude providers, rewrite AGENT.md model fields
        if ($providerName -ne 'claude' -and $providerConfigs.ContainsKey($providerName)) {
            $config = $providerConfigs[$providerName]
            $defaultModelId = $config.models.($config.default_model).id

            Get-ChildItem -Path $DestAgentsDir -Filter "AGENT.md" -Recurse | ForEach-Object {
                $content = Get-Content $_.FullName -Raw
                $content = $content -replace 'model:\s*claude-[^\r\n]+', "model: $defaultModelId"
                Set-Content -Path $_.FullName -Value $content -Encoding utf8NoBOM -NoNewline
            }
        }

        $AgentCount = (Get-ChildItem -Path $DestAgentsDir -Directory).Count
        Write-Success "+ $($provider.Dir): Copied $AgentCount agent(s)"
    }

    # Copy skills
    $DestSkillsDir = Join-Path $ideDir "skills"

    if (Test-Path $SourceSkillsDir) {
        if (Test-Path $DestSkillsDir) {
            Remove-Item -Path $DestSkillsDir -Recurse -Force
        }

        Copy-Item -Path $SourceSkillsDir -Destination $DestSkillsDir -Recurse

        $SkillCount = (Get-ChildItem -Path $DestSkillsDir -Directory).Count
        Write-Success "+ $($provider.Dir): Copied $SkillCount skill(s)"
    }
}

# ---------------------------------------------------------------------------
# Framework file protection: append brief guidance to the agent-instruction
# files (CLAUDE.md, AGENTS.md, GEMINI.md) so agents are told not to modify
# files under .bot/ except .bot/workspace/. Kept deliberately short per the
# review feedback in andresharpe/dotbot#173 comment 4237794998.
#
# Idempotent: replaces the block between the marker tags if already present,
# otherwise appends it.
# ---------------------------------------------------------------------------
$frameworkProtectionBlock = @'
<!-- dotbot:framework-protection -->
## dotbot framework files (READ-ONLY)

NEVER modify files under `.bot/` except `.bot/workspace/`.

Framework files under `.bot/systems/`, `.bot/hooks/`, `.bot/recipes/`, and `.bot/settings/*.default.json` are managed by dotbot. Direct edits are rejected by a pre-commit hook and detected by verification hooks. To update framework files, run `dotbot init --force`.
<!-- /dotbot:framework-protection -->
'@

# Map each instruction file to the IDE directory it belongs to. Only touch the
# file if either (a) it already exists, or (b) the corresponding IDE directory
# exists (i.e., the provider was set up above). Avoids creating orphan files
# for providers the user hasn't installed.
$agentInstructionFiles = @(
    @{ File = 'CLAUDE.md';  Dir = '.claude' }
    @{ File = 'AGENTS.md';  Dir = '.codex' }
    @{ File = 'GEMINI.md';  Dir = '.gemini' }
)
foreach ($entry in $agentInstructionFiles) {
    $fileName = $entry.File
    $filePath = Join-Path $ProjectRoot $fileName
    $ideDirPath = Join-Path $ProjectRoot $entry.Dir
    if (Test-Path $filePath) {
        $existing = Get-Content $filePath -Raw
        # Look for the marker block; regex uses [regex]::Escape on the opening
        # marker to be safe, and DOTALL-equivalent via (?s) inline flag.
        $pattern = '(?s)<!-- dotbot:framework-protection -->.*?<!-- /dotbot:framework-protection -->'
        if ($existing -match $pattern) {
            # MatchEvaluator avoids having to escape replacement-string metachars
            # ($1, $&, etc.) that might appear inside the block.
            $updated = [regex]::Replace($existing, $pattern, { param($m) $frameworkProtectionBlock })
        } else {
            $separator = if ($existing.EndsWith("`n")) { "`n" } else { "`n`n" }
            $updated = $existing + $separator + $frameworkProtectionBlock + "`n"
        }
        if ($updated -ne $existing) {
            Set-Content -Path $filePath -Value $updated -Encoding utf8NoBOM -NoNewline
            Write-Success "+ Updated $fileName with framework protection block"
        }
    } elseif (Test-Path -LiteralPath $ideDirPath) {
        # Create a minimal file only if the IDE directory exists (provider was set up).
        Set-Content -Path $filePath -Value ($frameworkProtectionBlock + "`n") -Encoding utf8NoBOM -NoNewline
        Write-Success "+ Created $fileName with framework protection block"
    }
}

Write-BlankLine
Write-Success "Initialization complete!"
Write-BlankLine
Write-Status "IDE integrations are now available in:"
foreach ($provider in $providerDirs) {
    $ideDir = Join-Path $ProjectRoot $provider.Dir
    Write-DotbotCommand "$ideDir"
}
Write-BlankLine
Write-DotbotCommand "Agents and skills are ready for Claude, Codex, and Gemini."
Write-BlankLine
