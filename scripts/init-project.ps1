#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initialize .bot in the current project

.DESCRIPTION
    Copies the default .bot structure to the current project directory.
    Optionally installs a profile for tech-specific features.
    Checks for required dependencies (git is required; others warn-only).
    Creates .mcp.json with dotbot, Context7, and Playwright MCP servers.
    Installs gitleaks pre-commit hook if gitleaks is available.

.PARAMETER Profile
    Profile to install (e.g., 'dotnet'). Can be specified multiple times.

.PARAMETER Force
    Overwrite existing .bot system files (preserves workspace data).

.PARAMETER DryRun
    Preview changes without applying.

.EXAMPLE
    init-project.ps1
    Installs base default only.

.EXAMPLE
    init-project.ps1 -Profile dotnet
    Installs base default + dotnet profile.
#>

[CmdletBinding()]
param(
    [string[]]$Profile,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$DotbotBase = Join-Path $HOME "dotbot"
$DefaultDir = Join-Path $DotbotBase "profiles\default"
$ProjectDir = Get-Location
$BotDir = Join-Path $ProjectDir ".bot"

# Import platform functions
Import-Module (Join-Path $DotbotBase "scripts\Platform-Functions.psm1") -Force

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "    D O T B O T   v3" -ForegroundColor Blue
Write-Host "    Project Initialization" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

# ---------------------------------------------------------------------------
# Dependency check (git required; others warn-only)
# ---------------------------------------------------------------------------
Write-Host "  DEPENDENCY CHECK" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

$depWarnings = 0

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Success "PowerShell 7+ ($($PSVersionTable.PSVersion))"
} else {
    Write-DotbotWarning "PowerShell 7+ is required (current: $($PSVersionTable.PSVersion))"
    Write-Host "    Download from: https://aka.ms/powershell" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Success "Git"
} else {
    Write-DotbotError "Git is required but not installed"
    Write-Host "    Download from: https://git-scm.com/downloads" -ForegroundColor Cyan
    exit 1
}

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Success "Claude CLI"
} else {
    Write-DotbotWarning "Claude CLI is not installed"
    Write-Host "    Install: npm install -g @anthropic-ai/claude-code" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Success "Codex CLI"
} else {
    Write-DotbotWarning "Codex CLI is not installed"
    Write-Host "    Install: npm install -g @openai/codex" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command gemini -ErrorAction SilentlyContinue) {
    Write-Success "Gemini CLI"
} else {
    Write-DotbotWarning "Gemini CLI is not installed"
    Write-Host "    Install: npm install -g @anthropic-ai/gemini-code" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command npx -ErrorAction SilentlyContinue) {
    Write-Success "Node.js / npx (for Context7 and Playwright MCP)"
} else {
    Write-DotbotWarning "Node.js / npx is not installed (needed for MCP servers)"
    Write-Host "    Download from: https://nodejs.org" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command uvx -ErrorAction SilentlyContinue) {
    Write-Success "uv / uvx (for Serena MCP)"
} else {
    Write-DotbotWarning "uv / uvx is not installed (needed for Serena MCP)"
    Write-Host "    Install: pip install uv  (or see https://docs.astral.sh/uv/)" -ForegroundColor Cyan
    $depWarnings++
}

if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
    Write-Success "gitleaks"
} else {
    Write-DotbotWarning "gitleaks is not installed (secret scanning)"
    Write-Host "    Install: winget install Gitleaks.Gitleaks" -ForegroundColor Cyan
    $depWarnings++
}

if ($depWarnings -gt 0) {
    Write-Host ""
    Write-DotbotWarning "$depWarnings missing dependency/dependencies -- continuing anyway"
}
Write-Host ""

# Ensure project is a git repository
$gitDir = Join-Path $ProjectDir ".git"
if (-not (Test-Path $gitDir)) {
    Write-Status "No .git directory found -- initializing git repository"
    & git init $ProjectDir
    Write-Success "Initialized git repository"
}

# Check if default exists
if (-not (Test-Path $DefaultDir)) {
    Write-DotbotError "Default directory not found: $DefaultDir"
    Write-Host "  Run 'dotbot update' to repair installation" -ForegroundColor Yellow
    exit 1
}

# Check if .bot already exists
if ((Test-Path $BotDir) -and -not $Force) {
    Write-DotbotWarning ".bot directory already exists"
    Write-Host "  Use -Force to overwrite" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Status "Initializing .bot in: $ProjectDir"

if ($DryRun) {
    Write-Host "  Would copy default from: $DefaultDir" -ForegroundColor Yellow
    Write-Host "  Would copy to: $BotDir" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Handle existing .bot with -Force (preserve workspace data)
# ---------------------------------------------------------------------------
if ((Test-Path $BotDir) -and $Force) {
    Write-Status "Updating .bot system files (preserving workspace data)"
    # Remove only system/config directories and root files -- never workspace/
    $systemDirs = @("systems", "prompts", "hooks", "defaults", ".control")
    foreach ($dir in $systemDirs) {
        $dirPath = Join-Path $BotDir $dir
        if (Test-Path $dirPath) {
            Remove-Item -Path $dirPath -Recurse -Force
        }
    }
    $rootFiles = @("go.ps1", "init.ps1", "README.md", ".gitignore")
    foreach ($file in $rootFiles) {
        $filePath = Join-Path $BotDir $file
        if (Test-Path $filePath) {
            Remove-Item -Path $filePath -Force
        }
    }
}

# Copy default to .bot
Write-Status "Copying default files"
if (Test-Path $BotDir) {
    # .bot exists (Force path) -- copy contents on top, preserving workspace
    Copy-Item -Path (Join-Path $DefaultDir "*") -Destination $BotDir -Recurse -Force
} else {
    Copy-Item -Path $DefaultDir -Destination $BotDir -Recurse -Force
}

# Create empty workspace directories
$workspaceDirs = @(
    "workspace\tasks\todo",
    "workspace\tasks\analysing",
    "workspace\tasks\analysed",
    "workspace\tasks\needs-input",
    "workspace\tasks\in-progress",
    "workspace\tasks\done",
    "workspace\tasks\split",
    "workspace\tasks\skipped",
    "workspace\tasks\cancelled",
    "workspace\sessions",
    "workspace\sessions\runs",
    "workspace\sessions\history",
    "workspace\plans",
    "workspace\product",
    "workspace\feedback\pending",
    "workspace\feedback\applied",
    "workspace\feedback\archived"
)

foreach ($dir in $workspaceDirs) {
    $fullPath = Join-Path $BotDir $dir
    if (-not (Test-Path $fullPath)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
    }
    # Add .gitkeep to empty directories
    $gitkeep = Join-Path $fullPath ".gitkeep"
    if (-not (Test-Path $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep -Force | Out-Null
    }
}

Write-Success "Created .bot directory structure"

# Install profiles if specified
$ProfilesDir = Join-Path $DotbotBase "profiles"
if ($Profile -and $Profile.Count -gt 0) {
    foreach ($profileName in $Profile) {
        $profileDir = Join-Path $ProfilesDir $profileName
        
        if (-not (Test-Path $profileDir)) {
            Write-DotbotWarning "Profile not found: $profileName"
            Write-Host "  Available profiles:" -ForegroundColor Yellow
            Get-ChildItem -Path $ProfilesDir -Directory | ForEach-Object { Write-Host "    - $($_.Name)" }
            continue
        }
        
        Write-Status "Installing profile: $profileName"
        
        # Copy profile files (overlay on top of default)
        Get-ChildItem -Path $profileDir -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($profileDir.Length + 1)
            $destPath = Join-Path $BotDir $relativePath
            $destDir = Split-Path $destPath -Parent
            
            # Skip profile-init.ps1 (runs at init time, not copied to .bot/)
            if ($relativePath -eq "profile-init.ps1") { return }

            # Handle config.json merging for hooks/verify
            if ($relativePath -eq "hooks\verify\config.json") {
                $baseConfigPath = Join-Path $BotDir "hooks\verify\config.json"
                if (Test-Path $baseConfigPath) {
                    # Merge scripts arrays
                    $baseConfig = Get-Content $baseConfigPath -Raw | ConvertFrom-Json
                    $profileConfig = Get-Content $_.FullName -Raw | ConvertFrom-Json
                    
                    # Add profile scripts to base scripts (dedup by name)
                    $existingNames = @{}
                    foreach ($s in @($baseConfig.scripts)) { $existingNames[$s.name] = $true }
                    $mergedScripts = @($baseConfig.scripts)
                    foreach ($s in @($profileConfig.scripts)) {
                        if (-not $existingNames.ContainsKey($s.name)) {
                            $mergedScripts += $s
                        }
                    }
                    $baseConfig.scripts = $mergedScripts
                    
                    $baseConfig | ConvertTo-Json -Depth 10 | Set-Content $baseConfigPath
                    Write-Host "    Merged: $relativePath" -ForegroundColor Gray
                    return
                }
            }
            
            # Create directory if needed
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            
            # Copy file
            Copy-Item -Path $_.FullName -Destination $destPath -Force
            Write-Host "    Copied: $relativePath" -ForegroundColor Gray
        }
        
        Write-Success "Installed profile: $profileName"

        # Run profile init script if present
        $profileInitScript = Join-Path $profileDir "profile-init.ps1"
        if (Test-Path $profileInitScript) {
            Write-Status "Running $profileName init script"
            & $profileInitScript
        }
    }
}

# Run .bot/init.ps1 to set up .claude integration
$initScript = Join-Path $BotDir "init.ps1"
if (Test-Path $initScript) {
    Write-Status "Setting up Claude Code integration"
    & $initScript
}

# ---------------------------------------------------------------------------
# Create .mcp.json with MCP server configuration
# ---------------------------------------------------------------------------
$mcpJsonPath = Join-Path $ProjectDir ".mcp.json"
if (Test-Path $mcpJsonPath) {
    Write-DotbotWarning ".mcp.json already exists -- skipping"
} else {
    Write-Status "Creating .mcp.json (dotbot + Context7 + Playwright + Serena)"

    # Playwright MCP output goes to OS temp dir to avoid polluting the project
    $projectName = Split-Path $ProjectDir -Leaf
    $pwOutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot" "playwright-mcp" $projectName

    # On Windows, npx must be invoked via 'cmd /c' for stdio MCP servers
    if ($IsWindows) {
        $npxCommand = "cmd"
        $npxContext7Args = @("/c", "npx", "-y", "@upstash/context7-mcp@latest")
        $npxPlaywrightArgs = @("/c", "npx", "-y", "@playwright/mcp@latest", "--output-dir", $pwOutputDir)
    } else {
        $npxCommand = "npx"
        $npxContext7Args = @("-y", "@upstash/context7-mcp@latest")
        $npxPlaywrightArgs = @("-y", "@playwright/mcp@latest", "--output-dir", $pwOutputDir)
    }

    $mcpConfig = @{
        mcpServers = [ordered]@{
            dotbot = [ordered]@{
                type    = "stdio"
                command = "pwsh"
                args    = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ".bot\systems\mcp\dotbot-mcp.ps1")
                env     = @{}
            }
            context7 = [ordered]@{
                type    = "stdio"
                command = $npxCommand
                args    = $npxContext7Args
                env     = @{}
            }
            playwright = [ordered]@{
                type    = "stdio"
                command = $npxCommand
                args    = $npxPlaywrightArgs
                env     = @{}
            }
            serena = [ordered]@{
                type    = "stdio"
                command = "uvx"
                args    = @("--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server")
                env     = @{}
            }
        }
    }
    $mcpConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $mcpJsonPath -Encoding UTF8
    Write-Success "Created .mcp.json"
}

# ---------------------------------------------------------------------------
# Set up MCP for Codex and Gemini CLIs (if installed)
# ---------------------------------------------------------------------------
$mcpServerScript = ".bot\systems\mcp\dotbot-mcp.ps1"

if (Get-Command codex -ErrorAction SilentlyContinue) {
    Write-Status "Registering dotbot MCP server with Codex CLI..."
    try {
        Push-Location $ProjectDir
        codex mcp add dotbot -- pwsh -NoProfile -ExecutionPolicy Bypass -File $mcpServerScript 2>$null
        Write-Success "Codex MCP server registered"
    } catch {
        Write-DotbotWarning "Failed to register Codex MCP server: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  - Codex CLI not found, skipping MCP registration" -ForegroundColor DarkGray
}

if (Get-Command gemini -ErrorAction SilentlyContinue) {
    Write-Status "Registering dotbot MCP server with Gemini CLI..."
    try {
        Push-Location $ProjectDir
        gemini mcp add dotbot -- pwsh -NoProfile -ExecutionPolicy Bypass -File $mcpServerScript 2>$null
        Write-Success "Gemini MCP server registered"
    } catch {
        Write-DotbotWarning "Failed to register Gemini MCP server: $($_.Exception.Message)"
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  - Gemini CLI not found, skipping MCP registration" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Ensure common patterns are gitignored in the project root
# ---------------------------------------------------------------------------
$projectGitignore = Join-Path $ProjectDir ".gitignore"
$requiredIgnores = @(
    ".serena/"
    ".codex/"
    ".gemini/"
    "node_modules/"
    "test-results/"
    "playwright-report/"
    ".vscode/mcp.json"
    ".idea"
    ".DS_Store"
    ".env"
    "sessions/"
)

$existingContent = ""
if (Test-Path $projectGitignore) {
    $existingContent = Get-Content $projectGitignore -Raw
}

$entriesToAdd = @()
foreach ($pattern in $requiredIgnores) {
    $escaped = [regex]::Escape($pattern.TrimEnd('/'))
    if ($existingContent -notmatch "(?m)^\s*$escaped/?(\s|$)") {
        $entriesToAdd += $pattern
    }
}

if ($entriesToAdd.Count -gt 0) {
    $block = "`n# dotbot defaults (auto-added by dotbot init)`n"
    foreach ($pattern in $entriesToAdd) {
        $block += "$pattern`n"
    }
    Add-Content -Path $projectGitignore -Value $block -Encoding UTF8
    Write-Success "Added $($entriesToAdd.Count) entries to .gitignore"
} else {
    Write-Host "  ✓ .gitignore already covers dotbot defaults" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Install pre-commit hook (gitleaks + dotbot privacy scan)
# ---------------------------------------------------------------------------
$hooksDir = Join-Path $gitDir "hooks"
$preCommitPath = Join-Path $hooksDir "pre-commit"

# Determine if an existing hook is ours (dotbot-managed) or user-created
$existingHookIsOurs = $false
if (Test-Path $preCommitPath) {
    $existingContent = Get-Content $preCommitPath -Raw -ErrorAction SilentlyContinue
    if ($existingContent -and $existingContent -match '# dotbot:') {
        $existingHookIsOurs = $true
    }
}

if ((Test-Path $preCommitPath) -and -not $existingHookIsOurs) {
    Write-DotbotWarning "pre-commit hook already exists (not dotbot-managed) -- skipping"
} else {
    Write-Status "Installing pre-commit hook"
    if (-not (Test-Path $hooksDir)) {
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    }

    # --- Gitleaks section (conditional on availability) ---
    $gitleaksSection = ""
    if (Get-Command gitleaks -ErrorAction SilentlyContinue) {
        # On Windows, Git Bash cannot execute WinGet app execution aliases (reparse
        # points).  Resolve the real binary path so the hook calls it directly.
        $gitleaksCmd = "gitleaks"
        if ($IsWindows) {
            $resolved = Get-Command gitleaks -ErrorAction SilentlyContinue
            if ($resolved) {
                $target = (Get-Item $resolved.Source -ErrorAction SilentlyContinue).Target
                if ($target) {
                    $gitleaksCmd = $target -replace '\\', '/'
                } else {
                    $gitleaksCmd = ($resolved.Source) -replace '\\', '/'
                }
            }
        }
        $gitleaksSection = @"

# --- gitleaks ---
"$gitleaksCmd" git --pre-commit --staged || exit `$?
"@
    }

    # --- Resolve pwsh path for Git Bash on Windows ---
    $pwshCmd = "pwsh"
    if ($IsWindows) {
        $resolvedPwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($resolvedPwsh) {
            $target = (Get-Item $resolvedPwsh.Source -ErrorAction SilentlyContinue).Target
            if ($target) {
                $pwshCmd = $target -replace '\\', '/'
            } else {
                $pwshCmd = ($resolvedPwsh.Source) -replace '\\', '/'
            }
        }
    }

    $hookContent = @"
#!/bin/sh
# dotbot: pre-commit hook (gitleaks + privacy scan)
# Auto-generated by dotbot init — do not edit manually.
$gitleaksSection
# --- dotbot privacy scan ---
"$pwshCmd" -NoProfile -ExecutionPolicy Bypass -Command "
  `$r = & '.bot/hooks/verify/00-privacy-scan.ps1' -StagedOnly | ConvertFrom-Json;
  if (-not `$r.success) { exit 1 }"
"@
    Set-Content -Path $preCommitPath -Value $hookContent -Encoding UTF8 -NoNewline
    # Make executable on non-Windows platforms
    if (-not $IsWindows) {
        & chmod +x $preCommitPath 2>$null
    }
    Write-Success "Installed pre-commit hook"
}

# ---------------------------------------------------------------------------
# Create initial commit so worktrees can branch from it later
# ---------------------------------------------------------------------------
$hasCommits = git -C $ProjectDir rev-parse HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Creating initial commit..." -ForegroundColor DarkGray
    git -C $ProjectDir add .bot/ 2>$null
    if (Test-Path (Join-Path $ProjectDir ".mcp.json")) {
        git -C $ProjectDir add .mcp.json 2>$null
    }
    git -C $ProjectDir commit --quiet -m "chore: initialize dotbot" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Initial commit created"
    }
}

# ---------------------------------------------------------------------------
# Show completion message
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  ✓ Project Initialized!" -ForegroundColor Green
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  WHAT'S INSTALLED" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    .bot/systems/mcp/    " -NoNewline -ForegroundColor Yellow
Write-Host "MCP server for task management" -ForegroundColor White
Write-Host "    .bot/systems/ui/     " -NoNewline -ForegroundColor Yellow
Write-Host "Web UI server (default port 8686)" -ForegroundColor White
Write-Host "    .bot/systems/runtime/" -NoNewline -ForegroundColor Yellow
Write-Host "Autonomous loop for Claude CLI" -ForegroundColor White
Write-Host "    .bot/prompts/        " -NoNewline -ForegroundColor Yellow
Write-Host "Agents, skills, workflows" -ForegroundColor White
if ($Profile -and $Profile.Count -gt 0) {
    Write-Host ""
    Write-Host "  PROFILES INSTALLED" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    foreach ($p in $Profile) {
        Write-Host "    $p" -ForegroundColor Cyan
    }
}
Write-Host ""
Write-Host "  GET STARTED" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    .bot\go.ps1" -ForegroundColor White
Write-Host ""
Write-Host "  NEXT STEPS" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    1. Start the UI:     " -NoNewline -ForegroundColor Yellow
Write-Host ".bot\go.ps1" -ForegroundColor White
Write-Host "    2. View docs:        " -NoNewline -ForegroundColor Yellow
Write-Host ".bot\README.md" -ForegroundColor White
Write-Host ""
