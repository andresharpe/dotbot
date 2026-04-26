#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: Structure tests for dotbot new user experience.
.DESCRIPTION
    Tests dependencies, global install, project init, and platform functions.
    No AI/Claude dependency required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot
$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 1: Structure Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# ═══════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  DEPENDENCIES" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# PowerShell 7+
Assert-True -Name "PowerShell 7+" `
    -Condition ($PSVersionTable.PSVersion.Major -ge 7) `
    -Message "Current version: $($PSVersionTable.PSVersion)"

# Git available
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
Assert-True -Name "Git is available" -Condition ($null -ne $gitCmd) -Message "git not found on PATH"

# Git version >= 2.15 (worktree support)
if ($gitCmd) {
    $gitVersionOutput = & git --version 2>&1
    $gitVersionMatch = [regex]::Match($gitVersionOutput, '(\d+)\.(\d+)')
    if ($gitVersionMatch.Success) {
        $gitMajor = [int]$gitVersionMatch.Groups[1].Value
        $gitMinor = [int]$gitVersionMatch.Groups[2].Value
        $gitOk = ($gitMajor -gt 2) -or ($gitMajor -eq 2 -and $gitMinor -ge 15)
        Assert-True -Name "Git >= 2.15 (worktree support)" `
            -Condition $gitOk `
            -Message "Git $gitMajor.$gitMinor found, need >= 2.15"
    } else {
        Write-TestResult -Name "Git >= 2.15 (worktree support)" -Status Skip -Message "Could not parse git version"
    }
}

# powershell-yaml module
$yamlModule = Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue
Assert-True -Name "powershell-yaml module installed" `
    -Condition ($null -ne $yamlModule) `
    -Message "Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"

# npx (Node.js) - needed for Context7 and Playwright MCP
$npxCmd = Get-Command npx -ErrorAction SilentlyContinue
Assert-True -Name "npx available (for MCP servers)" `
    -Condition ($null -ne $npxCmd) `
    -Message "npx not found. Install Node.js from https://nodejs.org"

# Optional: Claude CLI
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    Write-TestResult -Name "Claude CLI (optional)" -Status Pass
} else {
    Write-TestResult -Name "Claude CLI (optional)" -Status Skip -Message "Not installed — Layer 4 tests will be skipped"
}

# Optional: gitleaks
$gitleaksCmd = Get-Command gitleaks -ErrorAction SilentlyContinue
if ($gitleaksCmd) {
    Write-TestResult -Name "gitleaks (optional)" -Status Pass
} else {
    Write-TestResult -Name "gitleaks (optional)" -Status Skip -Message "Not installed — pre-commit hook won't be created"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GLOBAL INSTALL
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GLOBAL INSTALL" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Backup existing dotbot install if present
$hadExistingInstall = Test-Path $dotbotDir
$backupDir = $null
if ($hadExistingInstall) {
    $backupDir = "${dotbotDir}-test-backup"
    if (Test-Path $backupDir) { Remove-Item $backupDir -Recurse -Force }
    Rename-Item -Path $dotbotDir -NewName (Split-Path $backupDir -Leaf)
}

try {
    # Run global install from repo
    $installScript = Join-Path $repoRoot "scripts\install-global.ps1"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $installScript 2>&1 | Out-Null

    Assert-PathExists -Name "~/dotbot directory created" -Path $dotbotDir
    Assert-PathExists -Name "~/dotbot/workflows/default exists" -Path (Join-Path $dotbotDir "workflows\default")
    Assert-PathExists -Name "~/dotbot/scripts exists" -Path (Join-Path $dotbotDir "scripts")

    $binDir = Join-Path $dotbotDir "bin"
    Assert-PathExists -Name "~/dotbot/bin exists" -Path $binDir

    $cliScript = Join-Path $binDir "dotbot.ps1"
    Assert-PathExists -Name "dotbot.ps1 CLI wrapper exists" -Path $cliScript

    # CLI wrapper contains expected commands
    if (Test-Path $cliScript) {
        Assert-FileContains -Name "CLI has 'init' command" -Path $cliScript -Pattern "init"
        Assert-FileContains -Name "CLI has 'profiles' command" -Path $cliScript -Pattern "profiles"
        Assert-FileContains -Name "CLI has 'status' command" -Path $cliScript -Pattern "status"
        Assert-FileContains -Name "CLI has 'help' command" -Path $cliScript -Pattern "help"
        Assert-FileContains -Name "CLI has 'studio' command" -Path $cliScript -Pattern "studio"
    }

    # dotbot status runs without error
    if (Test-Path $cliScript) {
        try {
            $statusOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $cliScript status 2>&1
            Assert-True -Name "dotbot status runs without error" -Condition ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) -Message "Exit code: $LASTEXITCODE`nOutput: $($statusOutput -join "`n")"
        } catch {
            Write-TestResult -Name "dotbot status runs without error" -Status Fail -Message $_.Exception.Message
        }
    }

} finally {
    # Restore original install
    if (Test-Path $dotbotDir) { Remove-Item $dotbotDir -Recurse -Force }
    if ($backupDir -and (Test-Path $backupDir)) {
        Rename-Item -Path $backupDir -NewName (Split-Path $dotbotDir -Leaf)
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROJECT INIT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROJECT INIT" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# dotbot must be installed for init to work — ensure it's present
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "workflows\default")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Project init tests" -Status Skip -Message "dotbot not installed globally — run install.ps1 first"
} else {
    $testProject = New-TestProject
    try {
        # Run init
        Push-Location $testProject
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
        Pop-Location

        $botDir = Join-Path $testProject ".bot"
        Assert-PathExists -Name ".bot directory created" -Path $botDir

        # Task status directories (all 9)
        $taskDirs = @('todo', 'analysing', 'analysed', 'needs-input', 'in-progress', 'done', 'split', 'skipped', 'cancelled')
        foreach ($dir in $taskDirs) {
            Assert-PathExists -Name "Task dir: $dir" -Path (Join-Path $botDir "workspace\tasks\$dir")
        }


        $todoArchiveDirs = @('edited_tasks', 'deleted_tasks')
        foreach ($dir in $todoArchiveDirs) {
            Assert-PathExists -Name "Todo archive dir: $dir" -Path (Join-Path $botDir "workspace\tasks\todo\$dir")
        }
        # System directories
        Assert-PathExists -Name "systems/mcp exists" -Path (Join-Path $botDir "systems\mcp")
        Assert-PathExists -Name "systems/ui exists" -Path (Join-Path $botDir "systems\ui")
        Assert-PathExists -Name "systems/runtime exists" -Path (Join-Path $botDir "systems\runtime")

        # Recipes directories
        Assert-PathExists -Name "recipes/agents exists" -Path (Join-Path $botDir "recipes\agents")
        Assert-PathExists -Name "recipes/skills exists" -Path (Join-Path $botDir "recipes\skills")
        Assert-PathExists -Name "recipes/prompts exists" -Path (Join-Path $botDir "recipes\prompts")

        # Workspace directories
        Assert-PathExists -Name "workspace/sessions exists" -Path (Join-Path $botDir "workspace\sessions")
        Assert-PathExists -Name "workspace/plans exists" -Path (Join-Path $botDir "workspace\plans")
        Assert-PathExists -Name "workspace/product exists" -Path (Join-Path $botDir "workspace\product")

        # Other directories
        Assert-PathExists -Name "hooks directory exists" -Path (Join-Path $botDir "hooks")
        Assert-PathExists -Name "settings directory exists" -Path (Join-Path $botDir "settings")

        # Key files
        Assert-PathExists -Name "go.ps1 exists" -Path (Join-Path $botDir "go.ps1")
        Assert-ValidPowerShell -Name "go.ps1 is valid PowerShell" -Path (Join-Path $botDir "go.ps1")
        Assert-PathExists -Name ".bot/README.md exists" -Path (Join-Path $botDir "README.md")

        # MCP server script
        Assert-PathExists -Name "dotbot-mcp.ps1 exists" -Path (Join-Path $botDir "systems\mcp\dotbot-mcp.ps1")

        # .mcp.json
        $mcpJson = Join-Path $testProject ".mcp.json"
        Assert-PathExists -Name ".mcp.json created" -Path $mcpJson
        Assert-ValidJson -Name ".mcp.json is valid JSON" -Path $mcpJson
        if (Test-Path $mcpJson) {
            $mcpConfig = Get-Content $mcpJson -Raw | ConvertFrom-Json
            Assert-True -Name ".mcp.json has dotbot server" `
                -Condition ($null -ne $mcpConfig.mcpServers.dotbot) `
                -Message "dotbot server entry missing"
            Assert-True -Name ".mcp.json has context7 server" `
                -Condition ($null -ne $mcpConfig.mcpServers.context7) `
                -Message "context7 server entry missing"
            Assert-True -Name ".mcp.json has playwright server" `
                -Condition ($null -ne $mcpConfig.mcpServers.playwright) `
                -Message "playwright server entry missing"
            Assert-True -Name ".mcp.json does not have serena server" `
                -Condition ($null -eq $mcpConfig.mcpServers.serena) `
                -Message "serena should not be included in the default MCP config"
        }

        $projectGitignore = Join-Path $testProject ".gitignore"
        Assert-PathExists -Name ".gitignore created" -Path $projectGitignore
        if (Test-Path $projectGitignore) {
            $projectGitignoreContent = Get-Content $projectGitignore -Raw
            Assert-True -Name ".gitignore does not include .serena/" `
                -Condition ($projectGitignoreContent -notmatch '(?m)^\s*\.serena/?\s*$') `
                -Message ".serena/ should not be auto-added by init"
        }

        # .claude directory (created by init.ps1)
        $claudeDir = Join-Path $testProject ".claude"
        Assert-PathExists -Name ".claude directory created" -Path $claudeDir

        # settings.default.json contains workspace instance GUID
        $settingsDefault = Join-Path $botDir "settings\settings.default.json"
        Assert-PathExists -Name "settings.default.json exists" -Path $settingsDefault
        if (Test-Path $settingsDefault) {
            $settingsJson = Get-Content $settingsDefault -Raw | ConvertFrom-Json
            $parsedInitGuid = [guid]::Empty
            $hasValidInitGuid = $settingsJson.PSObject.Properties['instance_id'] -and [guid]::TryParse("$($settingsJson.instance_id)", [ref]$parsedInitGuid)
            Assert-True -Name "init creates valid settings.instance_id GUID" `
                -Condition $hasValidInitGuid `
                -Message "Expected valid GUID in settings.instance_id"
        }

        # --- Init with -Force (preserves workspace data) ---
        # Reuses the basic project from PROJECT INIT above to avoid a redundant init.
        Write-Host ""
        Write-Host "  INIT -FORCE" -ForegroundColor Cyan
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

        # Create a dummy file in workspace to verify preservation
        $dummyFile = Join-Path $botDir "workspace\tasks\todo\test-task.json"
        @{ id = "test-123"; name = "Dummy task" } | ConvertTo-Json | Set-Content -Path $dummyFile

        # Create a dummy settings file in .control to verify preservation
        $controlDir = Join-Path $botDir ".control"
        if (-not (Test-Path $controlDir)) { New-Item -Path $controlDir -ItemType Directory -Force | Out-Null }
        $dummySettings = Join-Path $controlDir "settings.json"
        @{ anthropic_api_key = "sk-test-dummy" } | ConvertTo-Json | Set-Content -Path $dummySettings

        # Capture instance_id before re-init; it must be preserved on -Force
        $initialInstanceId = $null
        if (Test-Path $settingsDefault) {
            try {
                $settingsBeforeForce = Get-Content $settingsDefault -Raw | ConvertFrom-Json
                if ($settingsBeforeForce.PSObject.Properties['instance_id']) {
                    $initialInstanceId = "$($settingsBeforeForce.instance_id)"
                }
            } catch { Write-Verbose "Failed to parse data: $_" }
        }

        # Re-init with -Force
        Push-Location $testProject
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Force 2>&1 | Out-Null
        Pop-Location

        Assert-PathExists -Name "-Force: .bot still exists" -Path $botDir
        Assert-PathExists -Name "-Force: workspace task preserved" -Path $dummyFile
        Assert-PathExists -Name "-Force: .control/settings.json preserved" -Path $dummySettings
        Assert-PathExists -Name "-Force: system files refreshed" -Path (Join-Path $botDir "systems\mcp\dotbot-mcp.ps1")

        if ($initialInstanceId) {
            $settingsAfterForce = Get-Content $settingsDefault -Raw | ConvertFrom-Json
            Assert-Equal -Name "-Force: preserves existing settings.instance_id" `
                -Expected $initialInstanceId `
                -Actual "$($settingsAfterForce.instance_id)"
        }

    } finally {
        Remove-TestProject -Path $testProject
    }

    # --- Init with -Stack dotnet ---
    Write-Host ""
    Write-Host "  INIT --STACK (single stack)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $dotnetProfile = Join-Path $dotbotDir "stacks\dotnet"
    if (Test-Path $dotnetProfile) {
        $testProject3 = New-TestProject
        try {
            Push-Location $testProject3
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Stack dotnet 2>&1 | Out-Null
            Pop-Location

            $botDir3 = Join-Path $testProject3 ".bot"
            Assert-PathExists -Name "--: .bot created with dotnet profile" -Path $botDir3

            # Check that dotnet-specific files exist (look for any file from the dotnet profile)
            # Exclude on-install.ps1 and manifest.yaml which are intentionally not copied
            $dotnetFiles = Get-ChildItem -Path $dotnetProfile -Recurse -File | Where-Object { $_.Name -ne "on-install.ps1" -and $_.Name -ne "manifest.yaml" }
            if ($dotnetFiles.Count -gt 0) {
                $firstFile = $dotnetFiles[0]
                $relativePath = [System.IO.Path]::GetRelativePath(
                    [System.IO.Path]::GetFullPath($dotnetProfile),
                    [System.IO.Path]::GetFullPath($firstFile.FullName)
                )
                $relativePathKey = $relativePath -replace '\\', '/'
                $expectedPath = Join-Path $botDir3 $relativePath
                Assert-PathExists -Name "--: dotnet overlay file present ($relativePathKey)" -Path $expectedPath
            }

        } finally {
            Remove-TestProject -Path $testProject3
        }
    } else {
        Write-TestResult -Name "-Stack dotnet tests" -Status Skip -Message "dotnet profile not found at $dotnetProfile"
    }

    # --- Init with -Workflow kickstart-via-jira -Stack dotnet-blazor (taxonomy + extends) ---
    Write-Host ""
    Write-Host "  INIT --WORKFLOW + --STACK (with extends)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $kickstartViaJiraProfile = Join-Path $dotbotDir "workflows\kickstart-via-jira"
    $dotnetBlazorProfile = Join-Path $dotbotDir "stacks\dotnet-blazor"
    if ((Test-Path $kickstartViaJiraProfile) -and (Test-Path $dotnetBlazorProfile)) {
        $testProjectCombo = New-TestProject
        try {
            Push-Location $testProjectCombo
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-jira -Stack dotnet-blazor 2>&1 | Out-Null
            Pop-Location

            $botDirCombo = Join-Path $testProjectCombo ".bot"
            Assert-PathExists -Name "Combo: .bot created" -Path $botDirCombo

            # kickstart-via-jira overlay applied (workflow override)
            Assert-PathExists -Name "Combo: kickstart-via-jira 98-analyse-task.md present" `
                -Path (Join-Path $botDirCombo "recipes\prompts\98-analyse-task.md")

            # dotnet auto-included via extends (dotnet-blazor extends dotnet)
            $dotnetSkillCheck = Join-Path $botDirCombo "recipes\skills\entity-design\SKILL.md"
            Assert-PathExists -Name "Combo: dotnet auto-included (entity-design skill)" -Path $dotnetSkillCheck

            # dotnet-blazor overlay applied
            $blazorSkillCheck = Join-Path $botDirCombo "recipes\skills\blazor-component-design\SKILL.md"
            Assert-PathExists -Name "Combo: dotnet-blazor skill present" -Path $blazorSkillCheck

            # Settings: profile should be 'kickstart-via-jira' and stacks should include dotnet + dotnet-blazor
            $settingsCombo = Join-Path $botDirCombo "settings\settings.default.json"
            if (Test-Path $settingsCombo) {
                $sCombo = Get-Content $settingsCombo -Raw | ConvertFrom-Json
                Assert-Equal -Name "Combo: profile is 'kickstart-via-jira'" `
                    -Expected "kickstart-via-jira" -Actual $sCombo.workflow
                Assert-True -Name "Combo: stacks includes 'dotnet'" `
                    -Condition ("dotnet" -in @($sCombo.stacks)) `
                    -Message "Expected 'dotnet' in stacks array, got: $($sCombo.stacks -join ', ')"
                Assert-True -Name "Combo: stacks includes 'dotnet-blazor'" `
                    -Condition ("dotnet-blazor" -in @($sCombo.stacks)) `
                    -Message "Expected 'dotnet-blazor' in stacks array, got: $($sCombo.stacks -join ', ')"
            }

            # profile.yaml should NOT be copied to .bot/
            Assert-PathNotExists -Name "Combo: manifest.yaml not copied" `
                -Path (Join-Path $botDirCombo "manifest.yaml")

        } finally {
            Remove-TestProject -Path $testProjectCombo
        }
    } else {
        Write-TestResult -Name "Combo profile tests" -Status Skip -Message "Required profiles not found"
    }

    # --- Init with -Workflow kickstart-via-jira ---
    Write-Host ""
    Write-Host "  INIT --WORKFLOW kickstart-via-jira" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $kickstartViaJiraProfile = Join-Path $dotbotDir "workflows\kickstart-via-jira"
    if (Test-Path $kickstartViaJiraProfile) {
        $testProject4 = New-TestProject
        try {
            Push-Location $testProject4
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-jira 2>&1 | Out-Null
            Pop-Location

            $botDir4 = Join-Path $testProject4 ".bot"
            Assert-PathExists -Name "-- kickstart-via-jira: .bot created" -Path $botDir4

            # Key overlay files
            Assert-PathExists -Name "-- kickstart-via-jira: 98-analyse-task.md (override)" `
                -Path (Join-Path $botDir4 "recipes\prompts\98-analyse-task.md")
            Assert-PathExists -Name "-- kickstart-via-jira: 00-kickstart-interview.md (override)" `
                -Path (Join-Path $botDir4 "recipes\prompts\00-kickstart-interview.md")
            Assert-PathExists -Name "-- kickstart-via-jira: 04-post-research-review.md (new)" `
                -Path (Join-Path $botDir4 "recipes\prompts\04-post-research-review.md")
            Assert-PathExists -Name "-- kickstart-via-jira: atlassian.md (new research dir)" `
                -Path (Join-Path $botDir4 "recipes\research\atlassian.md")
            Assert-PathExists -Name "-- kickstart-via-jira: repo-clone/script.ps1 (new tool)" `
                -Path (Join-Path $botDir4 "systems\mcp\tools\repo-clone\script.ps1")
            Assert-PathExists -Name "-- kickstart-via-jira: settings.default.json (replacement)" `
                -Path (Join-Path $botDir4 "settings\settings.default.json")

            $mrWorkflow99 = Join-Path $botDir4 "recipes\prompts\99-autonomous-task.md"
            Assert-FileContains -Name "-- multi-repo: workflow 99 uses interpolated bot short ID tag" `
                -Path $mrWorkflow99 `
                -Pattern "\[bot:\{\{INSTANCE_ID_SHORT\}\}\]"

            # on-install.ps1 should NOT be copied to .bot/
            Assert-PathNotExists -Name "-- kickstart-via-jira: on-install.ps1 not copied" `
                -Path (Join-Path $botDir4 "on-install.ps1")

            # Verify hook config merge: 03-research-completeness.ps1 present
            $verifyConfig4 = Join-Path $botDir4 "hooks\verify\config.json"
            Assert-ValidJson -Name "-- kickstart-via-jira: verify config.json is valid JSON" -Path $verifyConfig4
            if (Test-Path $verifyConfig4) {
                $config4 = Get-Content $verifyConfig4 -Raw | ConvertFrom-Json
                $scriptNames4 = $config4.scripts | ForEach-Object { $_.name }
                Assert-True -Name "-- kickstart-via-jira: verify config has 03-research-completeness.ps1" `
                    -Condition ("03-research-completeness.ps1" -in $scriptNames4) `
                    -Message "03-research-completeness.ps1 not found in merged config"
            }

            # Settings validation
            $settingsPath4 = Join-Path $botDir4 "settings\settings.default.json"
            Assert-ValidJson -Name "-- kickstart-via-jira: settings is valid JSON" -Path $settingsPath4
            if (Test-Path $settingsPath4) {
                $settings4 = Get-Content $settingsPath4 -Raw | ConvertFrom-Json

                # task_categories should be merged from workflow.yaml domain section
                Assert-True -Name "-- kickstart-via-jira: task_categories merged from manifest" `
                    -Condition ($settings4.task_categories.Count -ge 5) `
                    -Message "Expected at least 5 categories, got $($settings4.task_categories.Count)"

                if ($settings4.task_categories) {
                    Assert-True -Name "-- kickstart-via-jira: task_categories includes 'research'" `
                        -Condition ('research' -in $settings4.task_categories) `
                        -Message "Expected 'research' in task_categories"
                    Assert-True -Name "-- kickstart-via-jira: task_categories includes 'analysis'" `
                        -Condition ('analysis' -in $settings4.task_categories) `
                        -Message "Expected 'analysis' in task_categories"
                }
            }

            # Sample task JSONs are valid
            $samplesDir4 = Join-Path $botDir4 "workspace\tasks\samples"
            if (Test-Path $samplesDir4) {
                $sampleFiles4 = Get-ChildItem -Path $samplesDir4 -Filter "*.json" -ErrorAction SilentlyContinue
                foreach ($sample in $sampleFiles4) {
                    Assert-ValidJson -Name "-- kickstart-via-jira: sample $($sample.Name) is valid JSON" -Path $sample.FullName
                }
            }

            # All .ps1 files in the profile source are valid PowerShell
            $allPs1Files = Get-ChildItem -Path $kickstartViaJiraProfile -Filter "*.ps1" -Recurse
            foreach ($ps1 in $allPs1Files) {
                $relPath = [System.IO.Path]::GetRelativePath(
                    [System.IO.Path]::GetFullPath($kickstartViaJiraProfile),
                    [System.IO.Path]::GetFullPath($ps1.FullName)
                )
                $relPathKey = $relPath -replace '\\', '/'
                Assert-ValidPowerShell -Name "-- kickstart-via-jira: $relPathKey valid syntax" -Path $ps1.FullName
            }

            # --- Verification Hook: 03-research-completeness.ps1 ---
            # Reuses the kickstart-via-jira project above to avoid a redundant init.
            Write-Host ""
            Write-Host "  VERIFICATION HOOK" -ForegroundColor Cyan
            Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

            $hookScript = Join-Path $dotbotDir "workflows\kickstart-via-jira\hooks\verify\03-research-completeness.ps1"
            $hookCopy = Join-Path $botDir4 "hooks\verify\03-research-completeness.ps1"
            if ((Test-Path $hookScript) -and (Test-Path $hookCopy)) {
                $briefingDir = Join-Path $botDir4 "workspace\product\briefing"
                $productDir = Join-Path $botDir4 "workspace\product"

                # Scenario 1: No artifacts → exit 1 (missing briefing/jira-context.md)
                $result1 = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "
                    `$global:DotbotProjectRoot = '$($testProject4 -replace "'","''")'
                    & '$($hookCopy -replace "'","''")'
                " 2>&1
                $exitCode1 = $LASTEXITCODE
                Assert-Equal -Name "Hook: no artifacts -> exit 1" -Expected 1 -Actual $exitCode1 -Message "Output: $($result1 -join "`n")"

                # Scenario 2: Only jira-context.md → exit 0 with warnings
                New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null
                "# Jira Context" | Set-Content (Join-Path $briefingDir "jira-context.md")

                $result2 = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "
                    `$global:DotbotProjectRoot = '$($testProject4 -replace "'","''")'
                    & '$($hookCopy -replace "'","''")'
                " 2>&1
                $exitCode2 = $LASTEXITCODE
                Assert-Equal -Name "Hook: only jira-context.md -> exit 0" -Expected 0 -Actual $exitCode2 -Message "Output: $($result2 -join "`n")"

                # Scenario 3: All artifacts present → exit 0, success message
                "# Interview" | Set-Content (Join-Path $productDir "interview-summary.md")
                "# Mission" | Set-Content (Join-Path $productDir "mission.md")
                "# Internet" | Set-Content (Join-Path $productDir "research-internet.md")
                "# Documents" | Set-Content (Join-Path $productDir "research-documents.md")
                "# Repos" | Set-Content (Join-Path $productDir "research-repos.md")
                New-Item -Path (Join-Path $briefingDir "repos") -ItemType Directory -Force | Out-Null
                "# Deep dive" | Set-Content (Join-Path $briefingDir "repos\FakeRepo.md")

                $result3 = & pwsh -NoProfile -ExecutionPolicy Bypass -Command "
                    `$global:DotbotProjectRoot = '$($testProject4 -replace "'","''")'
                    & '$($hookCopy -replace "'","''")'
                " 2>&1
                $exitCode3 = $LASTEXITCODE
                Assert-Equal -Name "Hook: all artifacts -> exit 0" -Expected 0 -Actual $exitCode3

                $output3 = $result3 -join "`n"
                Assert-True -Name "Hook: all artifacts -> success message" `
                    -Condition ($output3 -match "All research artifacts present") `
                    -Message "Expected 'All research artifacts present' in output"
            } elseif (-not (Test-Path $hookScript)) {
                Write-TestResult -Name "Verification hook tests" -Status Skip -Message "Hook script not found at $hookScript"
            } else {
                Write-TestResult -Name "Hook tests" -Status Skip -Message "Hook not copied to .bot/"
            }

        } finally {
            Remove-TestProject -Path $testProject4
        }
    } else {
        Write-TestResult -Name "-Workflow kickstart-via-jira tests" -Status Skip -Message "kickstart-via-jira profile not found at $kickstartViaJiraProfile"
    }

    # --- Init with -Workflow kickstart-via-pr ---
    Write-Host ""
    Write-Host "  INIT --WORKFLOW kickstart-via-pr" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $kickstartViaPrProfile = Join-Path $dotbotDir "workflows\kickstart-via-pr"
    Assert-PathExists -Name "-- kickstart-via-pr: source profile exists" -Path $kickstartViaPrProfile
    if (Test-Path $kickstartViaPrProfile) {
        $testProjectPr = New-TestProject
        try {
            Push-Location $testProjectPr
            & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow kickstart-via-pr 2>&1 | Out-Null
            Pop-Location

            $botDirPr = Join-Path $testProjectPr ".bot"
            Assert-PathExists -Name "-- kickstart-via-pr: .bot created" -Path $botDirPr
            Assert-PathExists -Name "-- kickstart-via-pr: .env.local created" -Path (Join-Path $testProjectPr ".env.local")

            # Key overlay files
            Assert-PathExists -Name "-- kickstart-via-pr: 00-kickstart-interview.md present" `
                -Path (Join-Path $botDirPr "recipes\prompts\00-kickstart-interview.md")
            Assert-PathExists -Name "-- kickstart-via-pr: 01-plan-product.md present" `
                -Path (Join-Path $botDirPr "recipes\prompts\01-plan-product.md")
            Assert-PathExists -Name "-- kickstart-via-pr: 02-plan-tasks.md present" `
                -Path (Join-Path $botDirPr "recipes\prompts\02-plan-tasks.md")
            Assert-PathExists -Name "-- kickstart-via-pr: pr-context/script.ps1 present" `
                -Path (Join-Path $botDirPr "systems\mcp\tools\pr-context\script.ps1")
            Assert-PathExists -Name "-- kickstart-via-pr: pr-context/metadata.yaml present" `
                -Path (Join-Path $botDirPr "systems\mcp\tools\pr-context\metadata.yaml")
            Assert-PathExists -Name "-- kickstart-via-pr: settings.default.json present" `
                -Path (Join-Path $botDirPr "settings\settings.default.json")

            # on-install.ps1 should NOT be copied to .bot/
            Assert-PathNotExists -Name "-- kickstart-via-pr: on-install.ps1 not copied" `
                -Path (Join-Path $botDirPr "on-install.ps1")

            # Settings validation
            $settingsPathPr = Join-Path $botDirPr "settings\settings.default.json"
            Assert-ValidJson -Name "-- kickstart-via-pr: settings is valid JSON" -Path $settingsPathPr
            if (Test-Path $settingsPathPr) {
                $settingsPr = Get-Content $settingsPathPr -Raw | ConvertFrom-Json

                Assert-Equal -Name "-- kickstart-via-pr: profile is kickstart-via-pr" `
                    -Expected "kickstart-via-pr" -Actual $settingsPr.workflow

                Assert-True -Name "-- kickstart-via-pr: task_categories has 4 values" `
                    -Condition ($settingsPr.task_categories.Count -eq 4) `
                    -Message "Expected 4 categories, got $($settingsPr.task_categories.Count)"

                # Workflow tasks/phases are now defined in workflow.yaml, not settings
                Assert-PathExists -Name "-- kickstart-via-pr: workflow.yaml present" `
                    -Path (Join-Path $botDirPr "workflow.yaml")
            }

            # All .ps1 files in the profile source are valid PowerShell
            $allPrPs1Files = Get-ChildItem -Path $kickstartViaPrProfile -Filter "*.ps1" -Recurse
            foreach ($ps1 in $allPrPs1Files) {
                $relPath = [System.IO.Path]::GetRelativePath(
                    [System.IO.Path]::GetFullPath($kickstartViaPrProfile),
                    [System.IO.Path]::GetFullPath($ps1.FullName)
                )
                $relPathKey = $relPath -replace '\\', '/'
                Assert-ValidPowerShell -Name "-- kickstart-via-pr: $relPathKey valid syntax" -Path $ps1.FullName
            }

        } finally {
            Remove-TestProject -Path $testProjectPr
        }
    } else {
        Write-TestResult -Name "-Workflow kickstart-via-pr tests" -Status Skip -Message "kickstart-via-pr profile not found at $kickstartViaPrProfile"
    }
    # --- Deprecated alias: -Workflow multi-repo ---
    Write-Host ""
    Write-Host "  INIT DEPRECATED ALIAS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    if (Test-Path $kickstartViaJiraProfile) {
        $testProjectAlias = New-TestProject
        try {
            Push-Location $testProjectAlias
            $aliasOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") -Workflow multi-repo 2>&1
            Pop-Location

            $aliasBotDir = Join-Path $testProjectAlias ".bot"
            Assert-PathExists -Name "-- alias multi-repo: .bot created" -Path $aliasBotDir

            $aliasSettingsPath = Join-Path $aliasBotDir "settings\settings.default.json"
            if (Test-Path $aliasSettingsPath) {
                $aliasSettings = Get-Content $aliasSettingsPath -Raw | ConvertFrom-Json
                Assert-Equal -Name "-- alias multi-repo resolves to kickstart-via-jira" `
                    -Expected "kickstart-via-jira" -Actual $aliasSettings.workflow
            }

            $aliasOutputText = $aliasOutput | Out-String
            Assert-True -Name "-- alias multi-repo shows deprecation warning" `
                -Condition ($aliasOutputText -match "deprecated" -and $aliasOutputText -match "kickstart-via-jira") `
                -Message "Expected deprecation warning for multi-repo alias"
        } finally {
            Remove-TestProject -Path $testProjectAlias
        }
    } else {
        Write-TestResult -Name "-- alias tests" -Status Skip -Message "kickstart-via-jira profile not found at $kickstartViaJiraProfile"
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PLATFORM FUNCTIONS
# ═══════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════
# MANIFEST VALIDATION (manifest.yaml files)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MANIFEST VALIDATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$workflowsSourceDir = Join-Path $repoRoot "workflows"
$stacksSourceDir = Join-Path $repoRoot "stacks"

# Scan non-default workflows and all stacks for manifest.yaml
$manifestDirs = @()
if (Test-Path $workflowsSourceDir) {
    $manifestDirs += Get-ChildItem -Path $workflowsSourceDir -Directory | Where-Object { $_.Name -ne "default" }
}
if (Test-Path $stacksSourceDir) {
    $manifestDirs += Get-ChildItem -Path $stacksSourceDir -Directory
}

foreach ($manifestDir in $manifestDirs) {
    $yamlPath = Join-Path $manifestDir.FullName "manifest.yaml"
    Assert-PathExists -Name "manifest.yaml exists: $($manifestDir.Name)" -Path $yamlPath

    if (Test-Path $yamlPath) {
        $content = Get-Content $yamlPath -Raw
        Assert-True -Name "manifest.yaml has 'name': $($manifestDir.Name)" `
            -Condition ($content -match 'name:\s*\S+') `
            -Message "Missing 'name' field"
        Assert-True -Name "manifest.yaml has 'description': $($manifestDir.Name)" `
            -Condition ($content -match 'description:\s*\S+') `
            -Message "Missing 'description' field"

        # If extends is declared, the parent stack must exist
        if ($content -match 'extends:\s*(\S+)') {
            $parentName = $Matches[1]
            $parentDir = Join-Path $stacksSourceDir $parentName
            Assert-PathExists -Name "extends target exists: $($manifestDir.Name) -> $parentName" -Path $parentDir
        }
    }
}

Write-Host ""

Write-Host "  PLATFORM FUNCTIONS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$platformModule = Join-Path $repoRoot "scripts\Platform-Functions.psm1"
Import-Module $platformModule -Force

# Get-PlatformName returns correct OS
$platformName = Get-PlatformName
$expectedPlatform = if ($IsWindows) { "Windows" } elseif ($IsMacOS) { "macOS" } elseif ($IsLinux) { "Linux" } else { "Unknown" }
Assert-Equal -Name "Get-PlatformName returns '$expectedPlatform'" -Expected $expectedPlatform -Actual $platformName

# Add-ToPath with -DryRun doesn't crash
try {
    Add-ToPath -Directory "/tmp/dotbot-test-path" -DryRun 2>&1 | Out-Null
    Assert-True -Name "Add-ToPath -DryRun doesn't crash" -Condition $true
} catch {
    Write-TestResult -Name "Add-ToPath -DryRun doesn't crash" -Status Fail -Message $_.Exception.Message
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# GLOBAL INITIALIZATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  GLOBAL INITIALIZATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Find all scripts that dot-source MCP tool scripts (scan repo source, not installed copy)
$profilesDir = Join-Path $repoRoot "profiles"
$allScripts = Get-ChildItem -Path $profilesDir -Filter "*.ps1" -Recurse
$toolSourcePattern = '\.\s+.*tools[\\/][^\\/]+[\\/]script\.ps1'
$globalSetPattern = '\$global:DotbotProjectRoot\s*='

foreach ($script in $allScripts) {
    # Skip the tool scripts themselves
    if ($script.FullName -match 'tools[\\/][^\\/]+[\\/]script\.ps1') { continue }

    $content = Get-Content $script.FullName -Raw
    if ($content -match $toolSourcePattern) {
        $setsGlobal = $content -match $globalSetPattern
        $relativePath = [System.IO.Path]::GetRelativePath(
            [System.IO.Path]::GetFullPath($profilesDir),
            [System.IO.Path]::GetFullPath($script.FullName)
        )
        $relativePathKey = $relativePath -replace '\\', '/'
        Assert-True -Name "$relativePathKey sets DotbotProjectRoot" `
            -Condition $setsGlobal `
            -Message "File dot-sources tool scripts but never sets `$global:DotbotProjectRoot"
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROVIDER CONFIG FILES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROVIDER CONFIGS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$providersDir = Join-Path $repoRoot "workflows\default\settings\providers"

foreach ($providerName in @("claude", "codex", "gemini")) {
    $providerFile = Join-Path $providersDir "$providerName.json"
    Assert-True -Name "Provider config exists: $providerName.json" `
        -Condition (Test-Path $providerFile) `
        -Message "Expected $providerFile"

    if (Test-Path $providerFile) {
        $parsed = $null
        try { $parsed = Get-Content $providerFile -Raw | ConvertFrom-Json } catch { Write-Verbose "Settings operation failed: $_" }
        Assert-True -Name "Provider config parses: $providerName.json" `
            -Condition ($null -ne $parsed) `
            -Message "JSON parse failed"

        if ($parsed) {
            Assert-True -Name "Provider $providerName has 'name' field" `
                -Condition ($parsed.name -eq $providerName) `
                -Message "Expected name='$providerName', got '$($parsed.name)'"

            Assert-True -Name "Provider $providerName has 'models'" `
                -Condition ($null -ne $parsed.models) `
                -Message "Missing models object"

            Assert-True -Name "Provider $providerName has 'executable'" `
                -Condition ($null -ne $parsed.executable -and $parsed.executable.Length -gt 0) `
                -Message "Missing executable"

            Assert-True -Name "Provider $providerName has 'stream_parser'" `
                -Condition ($null -ne $parsed.stream_parser) `
                -Message "Missing stream_parser"

            # Permission modes schema validation
            Assert-True -Name "Provider $providerName has 'permission_modes'" `
                -Condition ($null -ne $parsed.permission_modes) `
                -Message "Missing permission_modes object"

            Assert-True -Name "Provider $providerName has 'default_permission_mode'" `
                -Condition ($null -ne $parsed.default_permission_mode -and $parsed.default_permission_mode.Length -gt 0) `
                -Message "Missing or empty default_permission_mode"

            if ($parsed.permission_modes -and $parsed.default_permission_mode) {
                $modeExists = $parsed.permission_modes.PSObject.Properties.Name -contains $parsed.default_permission_mode
                Assert-True -Name "Provider $providerName default_permission_mode references valid mode" `
                    -Condition $modeExists `
                    -Message "default_permission_mode '$($parsed.default_permission_mode)' not in permission_modes"

                foreach ($modeName in $parsed.permission_modes.PSObject.Properties.Name) {
                    $mode = $parsed.permission_modes.$modeName
                    Assert-True -Name "Provider $providerName mode '$modeName' has display_name" `
                        -Condition ($null -ne $mode.display_name -and $mode.display_name.Length -gt 0) `
                        -Message "Missing display_name"

                    Assert-True -Name "Provider $providerName mode '$modeName' has description" `
                        -Condition ($null -ne $mode.description -and $mode.description.Length -gt 0) `
                        -Message "Missing description"

                    Assert-True -Name "Provider $providerName mode '$modeName' has cli_args" `
                        -Condition ($null -ne $mode.cli_args) `
                        -Message "Missing cli_args"
                }
            }

            # Claude-specific: auto mode excludes Haiku
            if ($providerName -eq "claude" -and $parsed.permission_modes -and $parsed.permission_modes.auto) {
                $autoMode = $parsed.permission_modes.auto
                Assert-True -Name "Claude auto mode has restrictions" `
                    -Condition ($null -ne $autoMode.restrictions) `
                    -Message "Missing restrictions on auto mode"

                if ($autoMode.restrictions) {
                    Assert-True -Name "Claude auto mode excludes Haiku" `
                        -Condition ($autoMode.restrictions.excluded_models -contains "Haiku") `
                        -Message "Expected Haiku in excluded_models"
                }
            }
        }
    }
}

# Settings has provider field
$settingsFile = Join-Path $repoRoot "workflows\default\settings\settings.default.json"
if (Test-Path $settingsFile) {
    $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
    Assert-True -Name "settings.default.json has 'provider' field" `
        -Condition ($null -ne $settingsData.provider) `
        -Message "Missing 'provider' top-level field"

    Assert-True -Name "settings.default.json has 'permission_mode' field" `
        -Condition ($settingsData.PSObject.Properties.Name -contains 'permission_mode') `
        -Message "Missing 'permission_mode' top-level field"
}

# ProviderCLI module exists
$providerCliModule = Join-Path $repoRoot "workflows\default\systems\runtime\ProviderCLI\ProviderCLI.psm1"
Assert-True -Name "ProviderCLI.psm1 exists" `
    -Condition (Test-Path $providerCliModule) `
    -Message "Expected $providerCliModule"

# Stream parsers exist
foreach ($parserName in @("Claude", "Codex", "Gemini")) {
    $parserFile = Join-Path $repoRoot "workflows\default\systems\runtime\ProviderCLI\parsers\Parse-${parserName}Stream.ps1"
    Assert-True -Name "Stream parser exists: Parse-${parserName}Stream.ps1" `
        -Condition (Test-Path $parserFile) `
        -Message "Expected $parserFile"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WORKSPACE INSTANCE ID INTEGRATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKSPACE INSTANCE ID" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$defaultSettingsPath = Join-Path $repoRoot "workflows\default\settings\settings.default.json"
$kickstartViaJiraSettingsPath = Join-Path $repoRoot "workflows\kickstart-via-jira\settings\settings.default.json"
$kickstartViaPrSettingsPath = Join-Path $repoRoot "workflows\kickstart-via-pr\settings\settings.default.json"
$stateBuilderPath = Join-Path $repoRoot "workflows\default\systems\ui\modules\StateBuilder.psm1"
$uiIndexPath = Join-Path $repoRoot "workflows\default\systems\ui\static\index.html"
$uiUpdatesPath = Join-Path $repoRoot "workflows\default\systems\ui\static\modules\ui-updates.js"

Assert-FileContains -Name "default settings template has instance_id placeholder" `
    -Path $defaultSettingsPath `
    -Pattern '"instance_id"\s*:\s*null'
Assert-FileContains -Name "kickstart-via-jira settings template has instance_id placeholder" `
    -Path $kickstartViaJiraSettingsPath `
    -Pattern '"instance_id"\s*:\s*null'
Assert-FileContains -Name "kickstart-via-pr settings template has instance_id placeholder" `
    -Path $kickstartViaPrSettingsPath `
    -Pattern '"instance_id"\s*:\s*null'
Assert-FileContains -Name "StateBuilder includes workspace instance_id in state" `
    -Path $stateBuilderPath `
    -Pattern 'instance_id\s*=\s*\$workspaceInstanceId'
Assert-FileContains -Name "UI footer has instance-id field" `
    -Path $uiIndexPath `
    -Pattern 'id="instance-id"'
Assert-FileContains -Name "UI updates bind state instance_id to footer" `
    -Path $uiUpdatesPath `
    -Pattern "setElementText\('instance-id',\s*instanceId\s*\|\|\s*'--'\)"

# ═══════════════════════════════════════════════════════════════════
# PSSCRIPTANALYZER
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PSSCRIPTANALYZER" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$analyzerAvailable = Get-Module PSScriptAnalyzer -ListAvailable
if ($analyzerAvailable) {
    Import-Module PSScriptAnalyzer -Force
    $settingsPath = Join-Path $repoRoot "PSScriptAnalyzerSettings.psd1"
    $scriptsToCheck = @(
        (Join-Path $repoRoot "install.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "launch-process.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "ui" "server.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "modules" "ProcessRegistry.psm1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "modules" "ProcessTypes" "Invoke-PromptProcess.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "modules" "ProcessTypes" "Invoke-KickstartProcess.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "modules" "ProcessTypes" "Invoke-AnalysisProcess.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "modules" "ProcessTypes" "Invoke-ExecutionProcess.ps1"),
        (Join-Path $repoRoot "workflows" "default" "systems" "runtime" "modules" "ProcessTypes" "Invoke-WorkflowProcess.ps1")
    )
    foreach ($scriptFile in $scriptsToCheck) {
        $scriptName = [System.IO.Path]::GetRelativePath($repoRoot, $scriptFile) -replace '\\', '/'
        if (Test-Path $scriptFile) {
            $results = @(Invoke-ScriptAnalyzer -Path $scriptFile -Settings $settingsPath -ErrorAction SilentlyContinue)
            if ($results.Count -eq 0) {
                Write-TestResult -Name "PSScriptAnalyzer: $scriptName" -Status Pass
            } else {
                $issues = ($results | ForEach-Object { "  L$($_.Line): [$($_.RuleName)] $($_.Message)" }) -join "`n"
                Write-TestResult -Name "PSScriptAnalyzer: $scriptName" -Status Fail -Message "$($results.Count) issue(s):`n$issues"
            }
        } else {
            Write-TestResult -Name "PSScriptAnalyzer: $scriptName" -Status Skip -Message "File not found"
        }
    }
} else {
    Write-TestResult -Name "PSScriptAnalyzer checks" -Status Skip -Message "PSScriptAnalyzer module not installed"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# LOGGING HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  LOGGING HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$workflowsDefault = Join-Path $repoRoot "workflows\default"
if (Test-Path $workflowsDefault) {
    $forbiddenPatterns = @(
        @{ Pattern = '\bWrite-Host\b';    Name = 'Write-Host' }
        @{ Pattern = '\bWrite-Verbose\b'; Name = 'Write-Verbose' }
        @{ Pattern = '\bWrite-Warning\b'; Name = 'Write-Warning' }
        @{ Pattern = '\bWrite-Error\b';   Name = 'Write-Error' }
        @{ Pattern = '\bWrite-Debug\b';   Name = 'Write-Debug' }
    )

    # Files that implement logging/theming infrastructure and legitimately use raw output
    # Use forward slashes for cross-platform path matching
    $allowlist = @(
        'systems/runtime/modules/DotBotLog.psm1',
        'systems/runtime/modules/DotBotTheme.psm1'
    )

    # Patterns for files excluded from enforcement (user-facing scripts, manual test scripts)
    # Use forward slashes for cross-platform -like matching
    $excludePatterns = @(
        '*/test.ps1',       # MCP tool manual test scripts
        'hooks/*'           # Hook scripts (user-facing terminal output)
    )

    $violations = @()
    Get-ChildItem -Path $workflowsDefault -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
        # Normalize to forward slashes for cross-platform matching
        $relativePath = $_.FullName.Substring($workflowsDefault.Length + 1).Replace('\', '/')
        if ($relativePath -in $allowlist) { return }
        # Check exclude patterns
        $excluded = $false
        foreach ($ep in $excludePatterns) {
            if ($relativePath -like $ep) { $excluded = $true; break }
        }
        if ($excluded) { return }
        $lines = Get-Content $_.FullName
        for ($lineNum = 0; $lineNum -lt $lines.Count; $lineNum++) {
            $line = $lines[$lineNum]
            # Skip comment-only lines
            if ($line.TrimStart() -match '^\s*#') { continue }
            foreach ($fp in $forbiddenPatterns) {
                if ($line -match $fp.Pattern) {
                    $violations += "$relativePath`:$($lineNum + 1) uses $($fp.Name)"
                }
            }
        }
    }

    if ($violations.Count -eq 0) {
        Write-TestResult -Name "No raw Write-* calls in workflows/default (except allowlist)" -Status Pass
    } else {
        $sample = ($violations | Select-Object -First 15) -join "`n  "
        $extra = if ($violations.Count -gt 15) { "`n  ... and $($violations.Count - 15) more" } else { "" }
        Write-TestResult -Name "No raw Write-* calls in workflows/default (except allowlist)" -Status Fail `
            -Message "Found $($violations.Count) violation(s):`n  $sample$extra"
    }
} else {
    Write-TestResult -Name "Logging hygiene" -Status Skip -Message "workflows/default not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CROSS-PLATFORM HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CROSS-PLATFORM HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $workflowsDefault) {
    # Windows-only patterns that must not appear outside of $IsWindows guards
    $windowsOnlyPatterns = @(
        @{ Pattern = '\$env:USERPROFILE\b';                          Name = '$env:USERPROFILE (use $HOME)' }
        @{ Pattern = '\$env:APPDATA\b';                              Name = '$env:APPDATA (use cross-platform path)' }
        @{ Pattern = '\$env:TEMP\b|\$env:TMP\b';                    Name = '$env:TEMP/$env:TMP (use [IO.Path]::GetTempPath())' }
        @{ Pattern = '\$env:COMPUTERNAME\b';                         Name = '$env:COMPUTERNAME (use [Net.Dns]::GetHostName())' }
        @{ Pattern = '\$env:USERDOMAIN\b';                           Name = '$env:USERDOMAIN (use [Environment]::UserDomainName)' }
        @{ Pattern = '\$env:USERNAME\b';                             Name = '$env:USERNAME (use [Environment]::UserName)' }
        @{ Pattern = 'WindowsIdentity\]::GetCurrent\(\)';            Name = '[WindowsIdentity]::GetCurrent() without platform guard' }
        @{ Pattern = 'Get-NetIPAddress\b';                           Name = 'Get-NetIPAddress (not available on Linux)' }
        @{ Pattern = 'Get-WmiObject\b';                              Name = 'Get-WmiObject (use Get-CimInstance with platform guard)' }
        @{ Pattern = '"pwsh\.exe"';                                  Name = '"pwsh.exe" (use "pwsh" for cross-platform)' }
        @{ Pattern = '& claude\.exe\b';                              Name = '"& claude.exe" (use "& claude" for cross-platform)' }
    )

    $cpViolations = @()
    Get-ChildItem -Path $workflowsDefault -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
        $relativePath = $_.FullName.Substring($workflowsDefault.Length + 1).Replace('\', '/')
        $lines = Get-Content $_.FullName
        $inIsWindowsBlock = $false
        $isWindowsBlockDepth = 0
        for ($lineNum = 0; $lineNum -lt $lines.Count; $lineNum++) {
            $line = $lines[$lineNum]
            # Skip comment-only lines
            if ($line.TrimStart() -match '^\s*#') { continue }

            if ($inIsWindowsBlock) {
                $isWindowsBlockDepth += ([regex]::Matches($line, '\{')).Count
                $isWindowsBlockDepth -= ([regex]::Matches($line, '\}')).Count
                if ($isWindowsBlockDepth -le 0) {
                    $inIsWindowsBlock = $false
                    $isWindowsBlockDepth = 0
                }
                continue
            }

            if ($line -match '^\s*(if|elseif)\b[^{]*\$IsWindows\b[^{]*\{') {
                $isWindowsBlockDepth = ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
                if ($isWindowsBlockDepth -gt 0) {
                    $inIsWindowsBlock = $true
                }
                continue
            }

            foreach ($wp in $windowsOnlyPatterns) {
                if ($line -match $wp.Pattern) {
                    $cpViolations += "$relativePath`:$($lineNum + 1) uses $($wp.Name)"
                }
            }
        }
    }

    if ($cpViolations.Count -eq 0) {
        Write-TestResult -Name "No Windows-only APIs in workflows/default (outside platform guards)" -Status Pass
    } else {
        $sample = ($cpViolations | Select-Object -First 15) -join "`n  "
        $extra = if ($cpViolations.Count -gt 15) { "`n  ... and $($cpViolations.Count - 15) more" } else { "" }
        Write-TestResult -Name "No Windows-only APIs in workflows/default (outside platform guards)" -Status Fail `
            -Message "Found $($cpViolations.Count) violation(s):`n  $sample$extra"
    }
} else {
    Write-TestResult -Name "Cross-platform hygiene" -Status Skip -Message "workflows/default not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# STUDIO NAMING HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  STUDIO NAMING" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$studioDir = Join-Path $repoRoot "studio-ui"
Assert-PathExists -Name "studio-ui/ directory exists" -Path $studioDir

if (Test-Path $studioDir) {
    # Key runtime files exist with new names
    Assert-PathExists -Name "StudioAPI.psm1 exists" -Path (Join-Path $studioDir "StudioAPI.psm1")
    Assert-PathExists -Name "server.ps1 exists" -Path (Join-Path $studioDir "server.ps1")

    # Old names must not exist
    Assert-PathNotExists -Name "WorkflowEditorAPI.psm1 must not exist" -Path (Join-Path $studioDir "WorkflowEditorAPI.psm1")

    # No stale workflow-editor references in runtime files
    $studioRuntimeFiles = @(
        (Join-Path $studioDir "StudioAPI.psm1"),
        (Join-Path $studioDir "server.ps1"),
        (Join-Path $studioDir "go.ps1")
    )
    foreach ($rtFile in $studioRuntimeFiles) {
        if (Test-Path $rtFile) {
            $rtContent = Get-Content $rtFile -Raw
            $rtRelPath = [System.IO.Path]::GetRelativePath($repoRoot, $rtFile) -replace '\\', '/'
            Assert-True -Name "No stale 'workflow-editor' in $rtRelPath" `
                -Condition (-not ($rtContent -match 'workflow-editor')) `
                -Message "Found 'workflow-editor' reference — should be 'studio-ui' or 'studio'"
            Assert-True -Name "No stale 'WorkflowEditorAPI' in $rtRelPath" `
                -Condition (-not ($rtContent -match 'WorkflowEditorAPI')) `
                -Message "Found 'WorkflowEditorAPI' reference — should be 'StudioAPI'"
            Assert-True -Name "No stale '.editor-port' in $rtRelPath" `
                -Condition (-not ($rtContent -match '\.editor-port')) `
                -Message "Found '.editor-port' reference — should be '.studio-port'"
        }
    }

    # API namespace is /api/studio (not /api/workflow-editor)
    $apiModule = Join-Path $studioDir "StudioAPI.psm1"
    if (Test-Path $apiModule) {
        Assert-FileContains -Name "StudioAPI uses /api/studio namespace" -Path $apiModule -Pattern "/api/studio"
    }

    # Installer references studio-ui (not workflow-editor)
    $installerPath = Join-Path $repoRoot "scripts\install-global.ps1"
    if (Test-Path $installerPath) {
        Assert-FileContains -Name "Installer references studio-ui" -Path $installerPath -Pattern "studio-ui"
        Assert-True -Name "Installer has no workflow-editor references" `
            -Condition (-not ((Get-Content $installerPath -Raw) -match 'workflow-editor')) `
            -Message "Found stale 'workflow-editor' in install-global.ps1"
    }

    # .gitignore references studio-ui (not workflow-editor)
    $gitignorePath = Join-Path $repoRoot ".gitignore"
    if (Test-Path $gitignorePath) {
        Assert-FileContains -Name ".gitignore references studio-ui/static" -Path $gitignorePath -Pattern "studio-ui/static"
        Assert-True -Name ".gitignore has no workflow-editor references" `
            -Condition (-not ((Get-Content $gitignorePath -Raw) -match 'workflow-editor')) `
            -Message "Found stale 'workflow-editor' in .gitignore"
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# INSTALL/CLI THEME HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  INSTALL SCRIPT THEME HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Scans scripts/*.ps1 and install.ps1 for banned output patterns.
# All terminal output must use theme helpers from Platform-Functions.psm1.
# See CLAUDE.md "Terminal Output Rules" for the full policy.

$themeTargetFiles = @()
# Root install script
$rootInstall = Join-Path $repoRoot "install.ps1"
if (Test-Path $rootInstall) { $themeTargetFiles += $rootInstall }
# All scripts/*.ps1
$scriptsDir = Join-Path $repoRoot "scripts"
if (Test-Path $scriptsDir) {
    $themeTargetFiles += @(Get-ChildItem -Path $scriptsDir -Filter "*.ps1" -File)
    $themeTargetFiles += @(Get-ChildItem -Path $scriptsDir -Filter "*.psm1" -File)
}

# Files that are exempt because they define the theme infrastructure
$themeExemptFiles = @(
    'Platform-Functions.psm1'
)

$themeForbiddenPatterns = @(
    @{ Pattern = '(?<!\$_\.)\bWrite-Host\b';   Name = 'Write-Host' }
    @{ Pattern = '\bWrite-Verbose\b';           Name = 'Write-Verbose' }
    @{ Pattern = '\bWrite-Warning\b';           Name = 'Write-Warning' }
)

$themeViolations = @()
foreach ($file in $themeTargetFiles) {
    $fileName = if ($file -is [System.IO.FileInfo]) { $file.Name } else { Split-Path $file -Leaf }
    $filePath = if ($file -is [System.IO.FileInfo]) { $file.FullName } else { $file }
    if ($fileName -in $themeExemptFiles) { continue }

    $lines = Get-Content $filePath
    for ($lineNum = 0; $lineNum -lt $lines.Count; $lineNum++) {
        $line = $lines[$lineNum]
        # Skip comment-only lines
        if ($line.TrimStart() -match '^\s*#') { continue }
        # Skip lines that reference Write-Host/Verbose/Warning as string literals
        # (e.g. in regex matches, string comparisons, or log messages)
        $trimmed = $line.TrimStart()
        if ($trimmed -match "^if\s*\(\s*\$" -and $line -match '-match.*Write-') { continue }
        if ($trimmed -match '^\$.*\+=.*Write-' -and $trimmed -notmatch '^\s*Write-') { continue }
        if ($trimmed -match 'Write-Check.*Write-Host') { continue }
        foreach ($fp in $themeForbiddenPatterns) {
            if ($line -match $fp.Pattern) {
                $themeViolations += "${fileName}:$($lineNum + 1) uses $($fp.Name)"
            }
        }
    }
}

if ($themeViolations.Count -eq 0) {
    Write-TestResult -Name "No raw Write-Host/Verbose/Warning in scripts/ or install.ps1 (theme hygiene)" -Status Pass
} else {
    $sample = ($themeViolations | Select-Object -First 15) -join "`n  "
    $extra = if ($themeViolations.Count -gt 15) { "`n  ... and $($themeViolations.Count - 15) more" } else { "" }
    Write-TestResult -Name "No raw Write-Host/Verbose/Warning in scripts/ or install.ps1 (theme hygiene)" -Status Fail `
        -Message "Found $($themeViolations.Count) violation(s). Use theme helpers from Platform-Functions.psm1 (see CLAUDE.md).`n  $sample$extra"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CULTURE-INVARIANT CASING HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CULTURE-INVARIANT CASING HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Scans workflows/ for bare .ToLower() / .ToUpper() calls. Culture-dependent
# casing breaks on Turkish/Azerbaijani locales where "i".ToUpper() returns "İ"
# (U+0130) instead of "I", causing MCP function dispatch to fail and slug
# filenames to contain non-ASCII characters. See issue #280.
#
# Use .ToLowerInvariant() / .ToUpperInvariant() for identifiers, slugs,
# filenames, dispatcher lookups, and any ASCII key matching. Exempt files
# are those that legitimately display user-provided text, where locale
# casing is arguably correct.

$workflowsDir = Join-Path $repoRoot "workflows"
$invariantTargetFiles = @()
if (Test-Path $workflowsDir) {
    $invariantTargetFiles += @(Get-ChildItem -Path $workflowsDir -Recurse -Include "*.ps1", "*.psm1" -File)
}

# Exempt: files that format user-provided display text where locale casing
# is arguably correct (not identifiers, not persisted to disk, not dispatched).
$invariantExemptPaths = @(
    'DotBotTheme.psm1'  # Write-Header letter-spacing formatter; takes user titles
)

$invariantForbiddenPatterns = @(
    @{ Pattern = '\.ToLower\(\)';  Name = '.ToLower()';  Fix = '.ToLowerInvariant()' }
    @{ Pattern = '\.ToUpper\(\)';  Name = '.ToUpper()';  Fix = '.ToUpperInvariant()' }
)

$invariantViolations = @()
foreach ($file in $invariantTargetFiles) {
    if ($file.Name -in $invariantExemptPaths) { continue }

    $lines = Get-Content $file.FullName
    for ($lineNum = 0; $lineNum -lt $lines.Count; $lineNum++) {
        $line = $lines[$lineNum]
        if ($line.TrimStart() -match '^\s*#') { continue }
        foreach ($fp in $invariantForbiddenPatterns) {
            if ($line -match $fp.Pattern) {
                $relPath = $file.FullName.Substring($repoRoot.Length + 1)
                $invariantViolations += "${relPath}:$($lineNum + 1) uses $($fp.Name) — use $($fp.Fix)"
            }
        }
    }
}

if ($invariantViolations.Count -eq 0) {
    Write-TestResult -Name "No bare .ToLower()/.ToUpper() in workflows/ (locale-safe dispatch/slugs)" -Status Pass
} else {
    $sample = ($invariantViolations | Select-Object -First 15) -join "`n  "
    $extra = if ($invariantViolations.Count -gt 15) { "`n  ... and $($invariantViolations.Count - 15) more" } else { "" }
    Write-TestResult -Name "No bare .ToLower()/.ToUpper() in workflows/ (locale-safe dispatch/slugs)" -Status Fail `
        -Message "Found $($invariantViolations.Count) violation(s). Use .ToLowerInvariant()/.ToUpperInvariant() for identifiers, slugs, and dispatch lookups. See issue #280.`n  $sample$extra"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# FRAMEWORK FILE PROTECTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FRAMEWORK FILE PROTECTION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$frameworkIntegrityModule = Join-Path $repoRoot "workflows" "default" "systems" "mcp" "modules" "FrameworkIntegrity.psm1"
Assert-PathExists -Name "FrameworkIntegrity.psm1 module exists" -Path $frameworkIntegrityModule
Assert-ValidPowerShell -Name "FrameworkIntegrity.psm1 is valid PowerShell" -Path $frameworkIntegrityModule
if (Test-Path $frameworkIntegrityModule) {
    Assert-FileContains -Name "FrameworkIntegrity exports Test-FrameworkIntegrity" `
        -Path $frameworkIntegrityModule -Pattern 'Test-FrameworkIntegrity'
    Assert-FileContains -Name "FrameworkIntegrity exports Test-FrameworkTracked (gitignore guard)" `
        -Path $frameworkIntegrityModule -Pattern 'Test-FrameworkTracked'
    Assert-FileContains -Name "FrameworkIntegrity uses git check-ignore" `
        -Path $frameworkIntegrityModule -Pattern 'git check-ignore'
}

$frameworkIntegrityHook = Join-Path $repoRoot "workflows" "default" "hooks" "verify" "04-framework-integrity.ps1"
Assert-PathExists -Name "04-framework-integrity.ps1 verify hook exists" -Path $frameworkIntegrityHook
Assert-ValidPowerShell -Name "04-framework-integrity.ps1 is valid PowerShell" -Path $frameworkIntegrityHook
if (Test-Path $frameworkIntegrityHook) {
    Assert-FileContains -Name "04-framework-integrity imports FrameworkIntegrity module" `
        -Path $frameworkIntegrityHook -Pattern 'FrameworkIntegrity\.psm1'
}

$verifyConfig = Join-Path $repoRoot "workflows" "default" "hooks" "verify" "config.json"
Assert-PathExists -Name "verify/config.json exists" -Path $verifyConfig
Assert-ValidJson -Name "verify/config.json is valid JSON" -Path $verifyConfig
if (Test-Path $verifyConfig) {
    $cfg = Get-Content $verifyConfig -Raw | ConvertFrom-Json
    $entry = $cfg.scripts | Where-Object { $_.name -eq '04-framework-integrity.ps1' }
    Assert-True -Name "config.json registers 04-framework-integrity.ps1" `
        -Condition ($null -ne $entry) `
        -Message "Entry for 04-framework-integrity.ps1 missing from config.json"
    if ($entry) {
        Assert-True -Name "04-framework-integrity.ps1 marked required=true" `
            -Condition ($entry.required -eq $true) `
            -Message "Expected required=true"
        Assert-True -Name "04-framework-integrity.ps1 marked core=true" `
            -Condition ($entry.core -eq $true) `
            -Message "Expected core=true"
    }
}

$taskAnalysing = Join-Path $repoRoot "workflows" "default" "systems" "mcp" "tools" "task-mark-analysing" "script.ps1"
Assert-PathExists -Name "task-mark-analysing/script.ps1 exists" -Path $taskAnalysing
if (Test-Path $taskAnalysing) {
    Assert-FileContains -Name "task-mark-analysing imports FrameworkIntegrity module" `
        -Path $taskAnalysing -Pattern 'FrameworkIntegrity\.psm1'
    Assert-FileContains -Name "task-mark-analysing uses Invoke-FrameworkIntegrityGate" `
        -Path $taskAnalysing -Pattern 'Invoke-FrameworkIntegrityGate'
}

$taskInProgress = Join-Path $repoRoot "workflows" "default" "systems" "mcp" "tools" "task-mark-in-progress" "script.ps1"
Assert-PathExists -Name "task-mark-in-progress/script.ps1 exists" -Path $taskInProgress
if (Test-Path $taskInProgress) {
    Assert-FileContains -Name "task-mark-in-progress imports FrameworkIntegrity module" `
        -Path $taskInProgress -Pattern 'FrameworkIntegrity\.psm1'
    Assert-FileContains -Name "task-mark-in-progress uses Invoke-FrameworkIntegrityGate" `
        -Path $taskInProgress -Pattern 'Invoke-FrameworkIntegrityGate'
}

$initProject = Join-Path $repoRoot "scripts" "init-project.ps1"
if (Test-Path $initProject) {
    Assert-FileContains -Name "pre-commit hook template has framework-file protection section" `
        -Path $initProject -Pattern 'dotbot framework file protection'
    Assert-FileContains -Name "pre-commit hook template honors DOTBOT_FORCE_COMMIT escape" `
        -Path $initProject -Pattern 'DOTBOT_FORCE_COMMIT'
    Assert-FileContains -Name "init warns when .bot/ is gitignored" `
        -Path $initProject -Pattern 'gitignored.*tracked|tracked in git'
    Assert-FileContains -Name "pre-commit hook protects .bot/.manifest.json" `
        -Path $initProject -Pattern '\.bot/\.manifest\.json'
    Assert-FileContains -Name "init-project generates framework manifest" `
        -Path $initProject -Pattern 'New-DotbotManifest|New-FrameworkManifest'
    Assert-FileContains -Name "init-project defines UserPaths parameter for manifest" `
        -Path $initProject -Pattern 'UserPaths'
}

# Manifest module (ships with the default workflow alongside FrameworkIntegrity.psm1)
$manifestModule = Join-Path $repoRoot "workflows" "default" "systems" "mcp" "modules" "Manifest.psm1"
Assert-PathExists -Name "Manifest.psm1 module exists" -Path $manifestModule
Assert-ValidPowerShell -Name "Manifest.psm1 is valid PowerShell" -Path $manifestModule
if (Test-Path $manifestModule) {
    Assert-FileContains -Name "Manifest.psm1 exports New-DotbotManifest" `
        -Path $manifestModule -Pattern 'New-DotbotManifest'
    Assert-FileContains -Name "Manifest.psm1 exports Test-DotbotManifest" `
        -Path $manifestModule -Pattern 'Test-DotbotManifest'
    Assert-FileContains -Name "Manifest.psm1 writes to .bot/.manifest.json" `
        -Path $manifestModule -Pattern '\.manifest\.json'
    Assert-FileContains -Name "Manifest.psm1 uses SHA256 hashing" `
        -Path $manifestModule -Pattern 'SHA256'
}

# FrameworkIntegrity uses the manifest stage and exports the gate helper
if (Test-Path $frameworkIntegrityModule) {
    Assert-FileContains -Name "FrameworkIntegrity calls Test-DotbotManifest" `
        -Path $frameworkIntegrityModule -Pattern 'Test-DotbotManifest'
    Assert-FileContains -Name "FrameworkIntegrity handles missing-manifest reason" `
        -Path $frameworkIntegrityModule -Pattern "missing-manifest"
    Assert-FileContains -Name "FrameworkIntegrity exports Invoke-FrameworkIntegrityGate" `
        -Path $frameworkIntegrityModule -Pattern 'Invoke-FrameworkIntegrityGate'
}

# Agent-instruction file marker block written by workflows/default/init.ps1
$workflowInit = Join-Path $repoRoot "workflows" "default" "init.ps1"
if (Test-Path $workflowInit) {
    Assert-FileContains -Name "workflows/default/init.ps1 writes framework-protection marker" `
        -Path $workflowInit -Pattern 'dotbot:framework-protection'
    Assert-FileContains -Name "workflows/default/init.ps1 covers CLAUDE.md" `
        -Path $workflowInit -Pattern 'CLAUDE\.md'
    Assert-FileContains -Name "workflows/default/init.ps1 covers AGENTS.md (Codex)" `
        -Path $workflowInit -Pattern 'AGENTS\.md'
    Assert-FileContains -Name "workflows/default/init.ps1 covers GEMINI.md (Gemini)" `
        -Path $workflowInit -Pattern 'GEMINI\.md'
}

# DO NOT MODIFY headers on key framework files
$headerBannerPattern = 'FRAMEWORK FILE.*DO NOT MODIFY'
$bannerTargets = @(
    'workflows\default\go.ps1',
    'workflows\default\init.ps1',
    'workflows\default\systems\mcp\dotbot-mcp.ps1',
    'workflows\default\hooks\verify\00-privacy-scan.ps1',
    'workflows\default\hooks\verify\01-git-clean.ps1',
    'workflows\default\hooks\verify\02-git-pushed.ps1',
    'workflows\default\hooks\verify\03-check-md-refs.ps1',
    'workflows\default\hooks\verify\04-framework-integrity.ps1',
    'workflows\default\hooks\scripts\commit-bot-state.ps1',
    'workflows\default\hooks\scripts\steering.ps1',
    'workflows\default\hooks\dev\Start-Dev.ps1',
    'workflows\default\hooks\dev\Stop-Dev.ps1',
    'workflows\default\workflow.yaml',
    'workflows\default\recipes\agents\implementer\AGENT.md',
    'workflows\default\recipes\agents\planner\AGENT.md',
    'workflows\default\recipes\agents\reviewer\AGENT.md',
    'workflows\default\recipes\agents\tester\AGENT.md'
)
foreach ($rel in $bannerTargets) {
    $abs = Join-Path $repoRoot $rel
    if (Test-Path $abs) {
        Assert-FileContains -Name "DO NOT MODIFY banner: $rel" `
            -Path $abs -Pattern $headerBannerPattern
    } else {
        Write-TestResult -Name "DO NOT MODIFY banner: $rel" -Status Skip -Message "File not found"
    }
}

$readme = Join-Path $repoRoot "README.md"
if (Test-Path $readme) {
    Assert-FileContains -Name "README documents .bot/ must be tracked" `
        -Path $readme -Pattern 'Keep.*\.bot/.*tracked'
    Assert-FileContains -Name "README mentions .bot/.manifest.json" `
        -Path $readme -Pattern '\.manifest\.json'
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Structure"

if (-not $allPassed) {
    exit 1
}
