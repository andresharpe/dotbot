#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 2: Component tests for dotbot MCP tools and modules.
.DESCRIPTION
    Tests MCP server boot, task lifecycle, validation, session tracking,
    and activity logging. No AI/Claude dependency required.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 2: Component Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "dotbot not installed globally — set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 2: Components"
    exit 1
}

# Create a test project with .bot pre-populated from the default golden snapshot
$layer2Proj = New-TestProjectFromGolden -Flavor 'default'
$testProject = $layer2Proj.ProjectRoot
$botDir = $layer2Proj.BotDir

# Strip verify config to only include scripts that actually exist in the test project
$verifyConfigPath = Join-Path $botDir "hooks\verify\config.json"
if (Test-Path $verifyConfigPath) {
    try {
        $verifyConfig = Get-Content $verifyConfigPath -Raw | ConvertFrom-Json
        $verifyDir = Join-Path $botDir "hooks\verify"
        $existingScripts = @()
        foreach ($script in $verifyConfig.scripts) {
            if (Test-Path (Join-Path $verifyDir $script)) {
                $existingScripts += $script
            }
        }
        $verifyConfig.scripts = $existingScripts
        $verifyConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $verifyConfigPath -Encoding UTF8
    } catch { Write-Verbose "Failed to write file: $_" }
}

if (-not (Test-Path $botDir)) {
    Write-TestResult -Name "Layer 2 prerequisites" -Status Fail -Message "Failed to initialize .bot in test project"
    Remove-TestProject -Path $testProject
    Write-TestSummary -LayerName "Layer 2: Components"
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# WORKSPACE INSTANCE ID
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKSPACE INSTANCE ID" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$settingsPath = Join-Path $botDir "settings\settings.default.json"
Assert-PathExists -Name "settings.default.json exists" -Path $settingsPath
if (Test-Path $settingsPath) {
    $settingsJson = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $parsedGuid = [guid]::Empty
    $hasInitGuid = $settingsJson.PSObject.Properties['instance_id'] -and [guid]::TryParse("$($settingsJson.instance_id)", [ref]$parsedGuid)
    Assert-True -Name "settings.instance_id is valid after init" `
        -Condition $hasInitGuid `
        -Message "Expected a valid GUID in settings.instance_id"
}

$instanceIdModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Core/Dotbot.Core.psm1"
if (Test-Path $instanceIdModule) {
    Import-Module $instanceIdModule -Force

    $previousDotbotHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
    try {
        $isolatedDotbotHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-home-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $isolatedDotbotHome, 'Process')
        Assert-Equal -Name "DOTBOT_HOME overrides Get-DotbotInstallPath" `
            -Expected ([System.IO.Path]::GetFullPath($isolatedDotbotHome)) `
            -Actual (Get-DotbotInstallPath)

        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', '~/dotbot-home-probe', 'Process')
        Assert-Equal -Name "DOTBOT_HOME supports tilde expansion" `
            -Expected ([System.IO.Path]::GetFullPath((Join-Path $HOME 'dotbot-home-probe'))) `
            -Actual (Get-DotbotInstallPath)
    } finally {
        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $previousDotbotHome, 'Process')
        if ($isolatedDotbotHome -and (Test-Path $isolatedDotbotHome)) {
            Remove-Item $isolatedDotbotHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Simulate legacy project: remove instance_id then ensure it is recreated and persisted
    $legacySettings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    [void]$legacySettings.PSObject.Properties.Remove('instance_id')
    $legacySettings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath

    $generatedInstanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
    $generatedGuid = [guid]::Empty
    Assert-True -Name "legacy settings missing instance_id gets backfilled" `
        -Condition ([guid]::TryParse("$generatedInstanceId", [ref]$generatedGuid)) `
        -Message "Expected Get-OrCreateWorkspaceInstanceId to create a valid GUID"

    $settingsAfterBackfill = Get-Content $settingsPath -Raw | ConvertFrom-Json
    Assert-Equal -Name "backfilled instance_id is persisted to settings" `
        -Expected "$generatedGuid" `
        -Actual "$($settingsAfterBackfill.instance_id)"

    $sameInstanceId = Get-OrCreateWorkspaceInstanceId -SettingsPath $settingsPath
    Assert-Equal -Name "Get-OrCreateWorkspaceInstanceId is stable when already set" `
        -Expected "$generatedGuid" `
        -Actual "$sameInstanceId"
} else {
    Write-TestResult -Name "Dotbot.Core module exists" -Status Fail -Message "Module not found at $instanceIdModule"
}

$worktreeManagerModule = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1"
if (Test-Path $worktreeManagerModule) {
    Import-Module $worktreeManagerModule -Force
    $repoWorktreeManagerModule = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1"
    $worktreeManagerSrc = Get-Content $repoWorktreeManagerModule -Raw

    Assert-True -Name "Complete-TaskWorktree replays task branch patch instead of squash merge" `
        -Condition (($worktreeManagerSrc -match 'function\s+Apply-TaskBranchPatch') -and ($worktreeManagerSrc -notmatch 'merge\s+--squash')) `
        -Message "Task integration must exclude shared worktree links instead of squash-merging them"
    Assert-True -Name "Task branch patch excludes shared runtime links" `
        -Condition (($worktreeManagerSrc -match [regex]::Escape(':(exclude).bot/.control')) -and
                    ($worktreeManagerSrc -match [regex]::Escape(':(exclude).bot/workspace/tasks')) -and
                    ($worktreeManagerSrc -notmatch [regex]::Escape(':(exclude).bot/workspace/product'))) `
        -Message "Patch replay must exclude shared runtime state while allowing product artifacts through"
    Assert-True -Name "Complete-TaskWorktree commits shared task and decision state separately" `
        -Condition (($worktreeManagerSrc -match [regex]::Escape('.bot/workspace/tasks/')) -and
                    ($worktreeManagerSrc -match [regex]::Escape('.bot/workspace/decisions/')) -and
                    ($worktreeManagerSrc -notmatch 'git -C \$ProjectRoot add \.bot/workspace/tasks/ \.bot/workspace/product/')) `
        -Message "Product workspace writes must come from task branch patch replay, not live shared checkout"
    Assert-True -Name "Apply-TaskBranchPatch guards untracked ignored additions" `
        -Condition (($worktreeManagerSrc -match 'diff\s+--name-status') -and
                    ($worktreeManagerSrc -match 'hash-object\s+--no-filters') -and
                    ($worktreeManagerSrc -match 'Untracked file would be overwritten by task branch')) `
        -Message "Ignored local files such as .codex/config.toml must not make patch replay fail opaquely or overwrite divergent content"
    Assert-True -Name "Apply-TaskBranchPatch surfaces conflict_files + 'rebase_conflict' kind on 3-way apply failure" `
        -Condition (($worktreeManagerSrc -match 'diff\s+--name-only\s+--diff-filter=U') -and
                    ($worktreeManagerSrc -match "failure_kind\s*=\s*if\s*\(\s*\`$conflictFiles\.Count\s*-gt\s*0\s*\)\s*\{\s*'rebase_conflict'") -and
                    ($worktreeManagerSrc -match "Merge conflict during squash-merge")) `
        -Message "An add/add conflict on a single file (e.g. .gitignore) must reach the operator as a 'rebase_conflict' pending_question naming the file, not a generic 'merge_command_failed' with empty conflict_files. See botdot task d954f7e7 incident on 2026-05-14."

    # ───────────────────────────────────────────────────────────────────────
    # End-to-end: Apply-TaskBranchPatch on a real two-branch fixture with
    # add/add conflict. Pins the diagnostic contract behaviourally — the
    # source-level pin above only catches grep-detectable regressions.
    # ───────────────────────────────────────────────────────────────────────
    $conflictTmp = Join-Path ([IO.Path]::GetTempPath()) ('dotbot-conflict-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $conflictTmp -Force | Out-Null
    try {
        Push-Location $conflictTmp
        try {
            & git init --quiet 2>$null
            & git config user.email 'test@example.com' 2>$null
            & git config user.name 'Test' 2>$null
            & git checkout -b main --quiet 2>$null
            'base' | Set-Content -Path (Join-Path $conflictTmp 'README.md') -NoNewline
            & git add README.md 2>$null
            & git commit -m 'base' --quiet 2>$null
            & git checkout -b 'task/conflict-fixture' --quiet 2>$null
            ".codex/`n.antigravity/`n" | Set-Content -Path (Join-Path $conflictTmp '.gitignore') -NoNewline
            & git add .gitignore 2>$null
            & git commit -m 'task: gitignore (3 lines)' --quiet 2>$null
            & git checkout main --quiet 2>$null
            ".codex/`n.antigravity/`nnode_modules/`n.idea`n.env`n" | Set-Content -Path (Join-Path $conflictTmp '.gitignore') -NoNewline
            & git add .gitignore 2>$null
            & git commit -m 'main: gitignore (superset)' --quiet 2>$null
        } finally {
            Pop-Location
        }

        # Reach the non-exported function via the module's internal scope.
        $applyFn = (Get-Module Dotbot.Worktree).Invoke({ Get-Command Apply-TaskBranchPatch })
        $applyResult = & $applyFn -ProjectRoot $conflictTmp -BaseBranch 'main' -BranchName 'task/conflict-fixture'

        Assert-True -Name "Apply-TaskBranchPatch returns success=`$false on add/add conflict" `
            -Condition ($applyResult.success -eq $false) `
            -Message "Expected success=false, got: $($applyResult | ConvertTo-Json -Compress)"
        Assert-Equal -Name "Apply-TaskBranchPatch classifies add/add as 'rebase_conflict'" `
            -Expected 'rebase_conflict' -Actual $applyResult.failure_kind
        Assert-True -Name "Apply-TaskBranchPatch surfaces .gitignore in conflict_files" `
            -Condition (@($applyResult.conflict_files) -contains '.gitignore') `
            -Message "Expected conflict_files to contain '.gitignore', got: $($applyResult.conflict_files -join ', ')"
    } finally {
        # Best-effort cleanup; git may hold handles briefly on Windows.
        Remove-Item -Path $conflictTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ───────────────────────────────────────────────────────────────────────
    # Write-TaskFileRawAtomic: byte-fidelity round-trip. Backup-restore in
    # Complete-TaskWorktree relies on the raw helper preserving the exact
    # JSON bytes (including any trailing newline / lack thereof) that
    # Get-Content -Raw captured pre-merge.
    # ───────────────────────────────────────────────────────────────────────
    $taskFileModule = Join-Path $botDir "src/mcp/modules/TaskFile.psm1"
    if (Test-Path $taskFileModule) {
        Import-Module $taskFileModule -Force -DisableNameChecking
        $rawTmpDir = Join-Path ([IO.Path]::GetTempPath()) ('dotbot-rawatomic-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $rawTmpDir -Force | Out-Null
        try {
            $rawPath = Join-Path $rawTmpDir 'sample.json'
            # Embedded newline + no trailing newline — the literal `Get-Content -Raw`
            # shape used by the worktree backup map.
            $sampleJson = "{`n  `"id`": `"raw-test-001`",`n  `"name`": `"raw fidelity`"`n}"
            Write-TaskFileRawAtomic -Path $rawPath -RawContent $sampleJson -TaskId 'raw-test-001'

            Assert-True -Name "Write-TaskFileRawAtomic produces a file at the target path" `
                -Condition (Test-Path -LiteralPath $rawPath) `
                -Message "Expected $rawPath to exist after Write-TaskFileRawAtomic"
            $roundTrip = Get-Content -LiteralPath $rawPath -Raw
            Assert-Equal -Name "Write-TaskFileRawAtomic round-trips bytes verbatim (-NoNewline)" `
                -Expected $sampleJson -Actual $roundTrip
            # Tmp sidecar must be cleaned up — a leftover `.sample.json.tmp.*` would
            # mean a partial write that the rename failed to consume.
            $strays = Get-ChildItem -LiteralPath $rawTmpDir -Filter '.sample.json.tmp.*' -Force -ErrorAction SilentlyContinue
            Assert-True -Name "Write-TaskFileRawAtomic leaves no temp sidecar on success" `
                -Condition (@($strays).Count -eq 0) `
                -Message "Found leftover temp file(s): $($strays.Name -join ', ')"
        } finally {
            Remove-Item -Path $rawTmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-TestResult -Name "TaskFile.psm1 module exists for raw round-trip test" -Status Fail -Message "Module not found at $taskFileModule"
    }

    # Phase 4 init no longer mutates the project .gitignore, so the test
    # must seed both rules itself.
    Add-Content -Path (Join-Path $testProject ".gitignore") -Value ".idea/`n.env"
    $noiseCacheDir = Join-Path $testProject ".idea\cache"
    New-Item -Path $noiseCacheDir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $noiseCacheDir "index.json") -Value '{"cache":true}'
    Set-Content -Path (Join-Path $testProject ".env") -Value "DOTBOT_TEST=1"

    $gitignoredCopyPaths = @(Get-GitignoredCopyPaths -ProjectRoot $testProject)

    Assert-True -Name "Get-GitignoredCopyPaths keeps ignored env files" `
        -Condition ($gitignoredCopyPaths -contains ".env") `
        -Message "Expected .env to be copied into worktrees"
    Assert-True -Name "Get-GitignoredCopyPaths excludes noise dir caches" `
        -Condition (-not ($gitignoredCopyPaths -contains ".idea/cache/index.json")) `
        -Message "Noise directory cache contents should stay excluded from worktree copies"

    # Regression guard for #317: New-TaskWorktree must always fork task branches
    # from the canonical integration branch (main/master), never from whatever
    # HEAD happens to be checked out. Resolve-MainBranch is the choke point —
    # it must look up branches by explicit name and never read HEAD.
    $resolveMainRepo = New-TestProject -Prefix 'dotbot-test-resolve-main'
    try {
        Push-Location $resolveMainRepo
        & git branch -M main 2>&1 | Out-Null
        & git checkout -b feature/scratch-branch --quiet 2>&1 | Out-Null
        "scratch" | Set-Content -Path (Join-Path $resolveMainRepo "scratch.txt")
        & git add scratch.txt 2>&1 | Out-Null
        & git commit -m "Scratch commit on feature branch only" --quiet 2>&1 | Out-Null
        $headBranch = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim()
        Pop-Location

        Assert-Equal -Name "Regression #317 precondition: HEAD is on feature branch" `
            -Expected "feature/scratch-branch" `
            -Actual $headBranch

        $resolvedBase = Resolve-MainBranch -ProjectRoot $resolveMainRepo
        Assert-Equal -Name "Resolve-MainBranch returns 'main' when HEAD is on a non-main branch (#317 regression)" `
            -Expected "main" `
            -Actual $resolvedBase
        Assert-True -Name "Resolve-MainBranch never returns the checked-out feature branch (#317 regression)" `
            -Condition ($resolvedBase -ne 'feature/scratch-branch') `
            -Message "Resolve-MainBranch returned the feature branch — it must look up main/master by name, not read HEAD"

        # When neither main nor master exists, Resolve-MainBranch must return $null
        # rather than fall back to HEAD.
        Push-Location $resolveMainRepo
        & git branch -m main legacy-trunk 2>&1 | Out-Null
        Pop-Location
        $missingBase = Resolve-MainBranch -ProjectRoot $resolveMainRepo
        Assert-True -Name "Resolve-MainBranch returns null when neither main nor master exists" `
            -Condition ($null -eq $missingBase) `
            -Message "Expected null when no main/master branch exists, got '$missingBase'"
    } finally {
        Remove-TestProject -Path $resolveMainRepo
    }

    Assert-True -Name "Dotbot.Worktree has no Get-BaseBranch function (replaced by Resolve-MainBranch for #317)" `
        -Condition (-not (Select-String -Path $worktreeManagerModule -Pattern 'function Get-BaseBranch' -Quiet)) `
        -Message "Get-BaseBranch read HEAD and caused #317 — it must remain deleted"

    # End-to-end regression for #317: drive New-TaskWorktree through its real code
    # path (the same call site fixed in commit c491166). The unit test above pins
    # Resolve-MainBranch's contract; this test pins the integration — that the
    # task worktree's HEAD ends up at main's tip even when the source repo's HEAD
    # is on an unrelated feature branch with its own commits.
    $e2eProj = New-TestProjectFromGolden -Flavor 'default' -Prefix 'dotbot-test-worktree-fork'
    $e2eRoot = $e2eProj.ProjectRoot
    $e2eBot  = $e2eProj.BotDir
    $e2eResult = $null
    $e2eGlobalSuffix = [guid]::NewGuid().ToString('N').Substring(0,8)
    $e2eGlobalAgentName = "global-agent-$e2eGlobalSuffix"
    $e2eGlobalSkillName = "global-skill-$e2eGlobalSuffix"
    $e2eGlobalPromptName = "global-prompt-$e2eGlobalSuffix.md"
    $e2eProjectSkillName = "project-skill-$e2eGlobalSuffix"
    $e2eUserContentRoot = Join-Path $dotbotDir "content"
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $e2eUserContentRoot "agents/$e2eGlobalAgentName") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $e2eUserContentRoot "skills/$e2eGlobalSkillName") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $e2eUserContentRoot "prompts") | Out-Null
        "# Global Agent" | Set-Content -Path (Join-Path $e2eUserContentRoot "agents/$e2eGlobalAgentName/AGENT.md") -Encoding UTF8
        "# Global Skill" | Set-Content -Path (Join-Path $e2eUserContentRoot "skills/$e2eGlobalSkillName/SKILL.md") -Encoding UTF8
        "# Global Prompt" | Set-Content -Path (Join-Path $e2eUserContentRoot "prompts/$e2eGlobalPromptName") -Encoding UTF8
        New-Item -ItemType Directory -Force -Path (Join-Path $e2eBot "content/skills/$e2eProjectSkillName") | Out-Null
        "# Project Skill" | Set-Content -Path (Join-Path $e2eBot "content/skills/$e2eProjectSkillName/SKILL.md") -Encoding UTF8

        Push-Location $e2eRoot
        & git branch -M main 2>&1 | Out-Null
        & git checkout -b feature/scratch-branch --quiet 2>&1 | Out-Null
        "feature-only" | Set-Content -Path (Join-Path $e2eRoot "scratch-feature-only.txt")
        & git add scratch-feature-only.txt 2>&1 | Out-Null
        & git commit -m "Commit only on feature branch" --quiet 2>&1 | Out-Null
        $mainSha = (& git rev-parse main 2>$null).Trim()
        $featureSha = (& git rev-parse HEAD 2>$null).Trim()
        Pop-Location

        Assert-True -Name "E2E #317 precondition: main and feature SHAs differ" `
            -Condition ($mainSha -and $featureSha -and ($mainSha -ne $featureSha)) `
            -Message "Test setup did not diverge feature from main"

        $e2eTaskId = "deadbeef-1234-5678-9012-abcdef012345"
        $e2eResult = New-TaskWorktree -TaskId $e2eTaskId -TaskName "regression-317" `
                                      -ProjectRoot $e2eRoot -BotRoot $e2eBot

        Assert-True -Name "E2E #317: New-TaskWorktree returns success" `
            -Condition ($null -ne $e2eResult -and $e2eResult.success -eq $true) `
            -Message "Expected New-TaskWorktree.success=true, got: $($e2eResult | ConvertTo-Json -Compress)"

        if ($e2eResult -and $e2eResult.success -and $e2eResult.worktree_path -and (Test-Path $e2eResult.worktree_path)) {
            $wtSha = (& git -C $e2eResult.worktree_path rev-parse HEAD 2>$null).Trim()
            Assert-Equal -Name "E2E #317: task worktree HEAD == main's tip (forked from main)" `
                -Expected $mainSha -Actual $wtSha
            Assert-True -Name "E2E #317: feature-only file absent in task worktree" `
                -Condition (-not (Test-Path (Join-Path $e2eResult.worktree_path "scratch-feature-only.txt"))) `
                -Message "Worktree contains feature-branch-only file → task branch forked from feature, not main"
            $productPath = Join-Path $e2eResult.worktree_path ".bot/workspace/product"
            $productItem = Get-Item -LiteralPath $productPath -Force -ErrorAction SilentlyContinue
            Assert-True -Name "E2E: task worktree product workspace is branch-local" `
                -Condition ($productItem -and -not (($productItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $productItem.LinkType)) `
                -Message "Product workspace must be a real directory so task outputs stay isolated"
            "branch-local product artifact" | Set-Content -Path (Join-Path $productPath "isolation-check.md") -Encoding UTF8
            & git -C $e2eResult.worktree_path add .bot/workspace/product/isolation-check.md 2>&1 | Out-Null
            Assert-Equal -Name "E2E: git can stage product artifact from task worktree" `
                -Expected 0 -Actual $LASTEXITCODE

            $worktreeMcpPath = Join-Path $e2eResult.worktree_path ".mcp.json"
            $worktreeCodexConfig = Join-Path $e2eResult.worktree_path ".codex/config.toml"
            $worktreeAntigravityMcp = Join-Path $e2eResult.worktree_path ".agents/mcp_config.json"
            Assert-PathExists -Name "E2E: task worktree gets .mcp.json" -Path $worktreeMcpPath
            Assert-PathExists -Name "E2E: task worktree gets Claude agents" -Path (Join-Path $e2eResult.worktree_path ".claude/agents/implementer/AGENT.md")
            Assert-PathExists -Name "E2E: task worktree gets Codex MCP config" -Path $worktreeCodexConfig
            Assert-PathExists -Name "E2E: task worktree gets Antigravity MCP config" -Path $worktreeAntigravityMcp
            Assert-PathExists -Name "E2E: task worktree gets Antigravity skills" -Path (Join-Path $e2eResult.worktree_path ".agents/skills/status/SKILL.md")
            Assert-PathNotExists -Name "E2E: task worktree does not create legacy Gemini directory" -Path (Join-Path $e2eResult.worktree_path ".gemini")
            Assert-PathExists -Name "E2E: task worktree gets framework prompt content" -Path (Join-Path $e2eResult.worktree_path ".bot/content/prompts/100-single-session-task.md")
            Assert-PathExists -Name "E2E: task worktree gets DOTBOT_HOME agent content" -Path (Join-Path $e2eResult.worktree_path ".bot/content/agents/$e2eGlobalAgentName/AGENT.md")
            Assert-PathExists -Name "E2E: task worktree gets DOTBOT_HOME prompt content" -Path (Join-Path $e2eResult.worktree_path ".bot/content/prompts/$e2eGlobalPromptName")
            Assert-PathExists -Name "E2E: task worktree gets project skill content" -Path (Join-Path $e2eResult.worktree_path ".bot/content/skills/$e2eProjectSkillName/SKILL.md")
            Assert-PathExists -Name "E2E: provider agents include DOTBOT_HOME agent" -Path (Join-Path $e2eResult.worktree_path ".claude/agents/$e2eGlobalAgentName/AGENT.md")
            Assert-PathExists -Name "E2E: provider skills include DOTBOT_HOME skill" -Path (Join-Path $e2eResult.worktree_path ".codex/skills/$e2eGlobalSkillName/SKILL.md")
            Assert-PathExists -Name "E2E: Antigravity includes DOTBOT_HOME skill" -Path (Join-Path $e2eResult.worktree_path ".agents/skills/$e2eGlobalSkillName/SKILL.md")
            Assert-PathExists -Name "E2E: Claude provider includes project skill" -Path (Join-Path $e2eResult.worktree_path ".claude/skills/$e2eProjectSkillName/SKILL.md")
            Assert-PathExists -Name "E2E: Codex provider includes project skill" -Path (Join-Path $e2eResult.worktree_path ".codex/skills/$e2eProjectSkillName/SKILL.md")
            Assert-PathExists -Name "E2E: Antigravity includes project skill" -Path (Join-Path $e2eResult.worktree_path ".agents/skills/$e2eProjectSkillName/SKILL.md")
            Assert-PathExists -Name "E2E: task worktree gets framework hooks" -Path (Join-Path $e2eResult.worktree_path ".bot/hooks/scripts/commit-bot-state.ps1")

            $mcpData = Get-Content -LiteralPath $worktreeMcpPath -Raw | ConvertFrom-Json
            Assert-Equal -Name "E2E: worktree MCP points at worktree project root" `
                -Expected $e2eResult.worktree_path -Actual $mcpData.mcpServers.dotbot.env.DOTBOT_PROJECT_ROOT
            Assert-Equal -Name "E2E: worktree MCP records DOTBOT_HOME" `
                -Expected $dotbotDir -Actual $mcpData.mcpServers.dotbot.env.DOTBOT_HOME

            $antigravityMcpData = Get-Content -LiteralPath $worktreeAntigravityMcp -Raw | ConvertFrom-Json
            Assert-Equal -Name "E2E: Antigravity MCP points at worktree project root" `
                -Expected $e2eResult.worktree_path -Actual $antigravityMcpData.mcpServers.dotbot.env.DOTBOT_PROJECT_ROOT
            Assert-Equal -Name "E2E: Antigravity MCP records DOTBOT_HOME" `
                -Expected $dotbotDir -Actual $antigravityMcpData.mcpServers.dotbot.env.DOTBOT_HOME

            $generatedStatus = @(git -C $e2eResult.worktree_path status --porcelain -- .mcp.json .claude .codex .agents .gemini .bot/content .bot/hooks .bot/settings 2>$null)
            Assert-True -Name "E2E: generated provider/MCP files are locally ignored" `
                -Condition ($generatedStatus.Count -eq 0) `
                -Message "Generated files should not appear in git status: $($generatedStatus -join '; ')"

            Assert-PathNotExists -Name "E2E: main checkout still has no .mcp.json" -Path (Join-Path $e2eRoot ".mcp.json")
            Assert-PathNotExists -Name "E2E: main checkout still has no .claude/" -Path (Join-Path $e2eRoot ".claude")
        }
    } finally {
        if ($e2eResult -and $e2eResult.worktree_path -and (Test-Path $e2eResult.worktree_path)) {
            & git -C $e2eRoot worktree remove -f $e2eResult.worktree_path 2>&1 | Out-Null
        }
        if ($e2eResult -and $e2eResult.branch_name) {
            & git -C $e2eRoot branch -D $e2eResult.branch_name 2>&1 | Out-Null
        }
        Remove-Item -LiteralPath (Join-Path $e2eUserContentRoot "agents/$e2eGlobalAgentName") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $e2eUserContentRoot "skills/$e2eGlobalSkillName") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $e2eUserContentRoot "prompts/$e2eGlobalPromptName") -Force -ErrorAction SilentlyContinue
        Remove-TestProject -Path $e2eRoot
    }

    # Regression: Complete-TaskWorktree must preserve canonical task state
    # written through the shared .bot/workspace/tasks junction, even when the
    # project checkout is detached before merge.
    $completeProj = New-TestProjectFromGolden -Flavor 'default' -Prefix 'dotbot-test-complete-canonical'
    $completeRoot = $completeProj.ProjectRoot
    $completeBot = $completeProj.BotDir
    $completeResult = $null
    try {
        Push-Location $completeRoot
        & git branch -M main 2>&1 | Out-Null
        Pop-Location

        $completeTaskId = "t_doneui1"
        $completeResult = New-TaskWorktree -TaskId $completeTaskId -TaskName "canonical done survives completion" `
                                           -ProjectRoot $completeRoot -BotRoot $completeBot

        Assert-True -Name "Complete regression: New-TaskWorktree returns success" `
            -Condition ($completeResult -and $completeResult.success -eq $true) `
            -Message "Expected New-TaskWorktree success, got: $($completeResult | ConvertTo-Json -Compress)"

        if ($completeResult -and $completeResult.success -and (Test-Path $completeResult.worktree_path)) {
            $runDir = Join-Path $completeBot "workspace/tasks/workflow-runs/2026-05-28-start-from-prompt-done"
            New-Item -ItemType Directory -Force -Path $runDir | Out-Null
            @{
                id = "wr_doneui1"
                workflow = "start-from-prompt"
                status = "running"
            } | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $runDir "run.json") -Encoding UTF8
            @{
                id = $completeTaskId
                name = "Canonical done survives completion"
                status = "done"
                completed_at = "2026-05-28T11:30:00Z"
                provenance = @{
                    workflow = "start-from-prompt"
                    run_id = "wr_doneui1"
                    definition_name = "Canonical done survives completion"
                    expanded_by = $null
                }
                extensions = @{
                    runner = @{
                        commit_sha = "abc123"
                    }
                }
            } | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $runDir "$completeTaskId.json") -Encoding UTF8

            $artifactPath = Join-Path $completeResult.worktree_path "completion-artifact.txt"
            "worktree artifact" | Set-Content -Path $artifactPath -Encoding UTF8

            & git -C $completeRoot checkout --detach main --quiet 2>&1 | Out-Null
            Assert-Equal -Name "Complete regression precondition: project checkout is detached" `
                -Expected "HEAD" `
                -Actual ((& git -C $completeRoot rev-parse --abbrev-ref HEAD 2>$null).Trim())

            $completeMerge = Complete-TaskWorktree -TaskId $completeTaskId -ProjectRoot $completeRoot -BotRoot $completeBot
            Assert-True -Name "Complete regression: Complete-TaskWorktree succeeds from detached HEAD" `
                -Condition ($completeMerge.success -eq $true) `
                -Message "Expected success, got: $($completeMerge | ConvertTo-Json -Depth 10 -Compress)"

            $restoredTaskPath = Join-Path $runDir "$completeTaskId.json"
            Assert-PathExists -Name "Complete regression: canonical done task file survives" -Path $restoredTaskPath
            $restoredTask = Get-Content -LiteralPath $restoredTaskPath -Raw | ConvertFrom-Json
            Assert-Equal -Name "Complete regression: canonical task status remains done" `
                -Expected "done" `
                -Actual "$($restoredTask.status)"
            Assert-Equal -Name "Complete regression: project checkout returns to main" `
                -Expected "main" `
                -Actual ((& git -C $completeRoot rev-parse --abbrev-ref HEAD 2>$null).Trim())
            Assert-PathExists -Name "Complete regression: task artifact merged to main" `
                -Path (Join-Path $completeRoot "completion-artifact.txt")
        }
    } finally {
        if ($completeResult -and $completeResult.worktree_path -and (Test-Path $completeResult.worktree_path)) {
            & git -C $completeRoot worktree remove -f $completeResult.worktree_path 2>&1 | Out-Null
        }
        if ($completeResult -and $completeResult.branch_name) {
            & git -C $completeRoot branch -D $completeResult.branch_name 2>&1 | Out-Null
        }
        Remove-TestProject -Path $completeRoot
    }
} else {
    Write-TestResult -Name "Dotbot.Worktree module exists" -Status Fail -Message "Module not found at $worktreeManagerModule"
}

$promptBuilderScript = Join-Path $botDir "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1"
if (Test-Path $promptBuilderScript) {
    Import-Module $promptBuilderScript -Force -DisableNameChecking
    $promptTask = [PSCustomObject]@{
        id = "7b012fb8-d6fa-45e8-b89e-062b4bcb16ae"
        name = "Prompt Builder Test"
        category = "feature"
        priority = 10
        description = "Validate short ID interpolation"
        applicable_standards = @()
        applicable_agents = @()
        acceptance_criteria = @()
        steps = @()
        questions_resolved = @()
    }

    $promptTemplate = "[task:{{TASK_ID_SHORT}}] [bot:{{INSTANCE_ID_SHORT}}] [bot-full:{{INSTANCE_ID}}]"
    $promptResult = Build-TaskPrompt -PromptTemplate $promptTemplate -Task $promptTask -SessionId "sess-1" -InstanceId "A1B2C3D4-1111-2222-3333-444455556666"

    Assert-True -Name "Build-TaskPrompt replaces TASK_ID_SHORT" `
        -Condition ($promptResult -match '\[task:7b012fb8\]') `
        -Message "Expected [task:7b012fb8] in prompt output"
    Assert-True -Name "Build-TaskPrompt replaces INSTANCE_ID_SHORT" `
        -Condition ($promptResult -match '\[bot:a1b2c3d4\]') `
        -Message "Expected [bot:a1b2c3d4] in prompt output"
    Assert-True -Name "Build-TaskPrompt keeps full INSTANCE_ID available" `
        -Condition ($promptResult -match '\[bot-full:A1B2C3D4-1111-2222-3333-444455556666\]') `
        -Message "Expected full INSTANCE_ID replacement"
} else {
    Write-TestResult -Name "Dotbot.Task module exists" -Status Fail -Message "Module not found at $promptBuilderScript"
}

$extractCommitInfoScript = Join-Path $botDir "src/mcp/modules/Extract-CommitInfo.ps1"
if (Test-Path $extractCommitInfoScript) {
    . $extractCommitInfoScript

    $parserTaskShort = "feedc0de"
    Push-Location $testProject
    try {
        "short" | Set-Content -Path (Join-Path $testProject "parser-short.txt")
        & git add parser-short.txt 2>&1 | Out-Null
        & git commit -m "Parser short tag test" -m "[task:$parserTaskShort]" -m "[bot:a1b2c3d4]" --quiet 2>&1 | Out-Null

        "full" | Set-Content -Path (Join-Path $testProject "parser-full.txt")
        & git add parser-full.txt 2>&1 | Out-Null
        & git commit -m "Parser full tag test" -m "[task:$parserTaskShort]" -m "[bot:a1b2c3d4-1111-2222-3333-444455556666]" --quiet 2>&1 | Out-Null
    } finally {
        Pop-Location
    }

    $commitInfo = Get-TaskCommitInfo -TaskId $parserTaskShort -ProjectRoot $testProject -MaxCommits 20
    $shortTagCommit = @($commitInfo | Where-Object { $_.commit_subject -eq "Parser short tag test" }) | Select-Object -First 1
    $fullTagCommit = @($commitInfo | Where-Object { $_.commit_subject -eq "Parser full tag test" }) | Select-Object -First 1

    Assert-True -Name "Get-TaskCommitInfo finds short [bot:XXXXXXXX] tags" `
        -Condition ($null -ne $shortTagCommit -and $shortTagCommit.workspace_short_id -eq "a1b2c3d4") `
        -Message "Expected workspace_short_id a1b2c3d4 from short bot tag"
    Assert-True -Name "Get-TaskCommitInfo derives short ID from full bot GUID tag" `
        -Condition ($null -ne $fullTagCommit -and $fullTagCommit.workspace_short_id -eq "a1b2c3d4") `
        -Message "Expected workspace_short_id a1b2c3d4 from full GUID bot tag"
} else {
    Write-TestResult -Name "Extract-CommitInfo module exists" -Status Fail -Message "Module not found at $extractCommitInfoScript"
}

Write-Host ""

# PROCESS STATUS SANITIZATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROCESS STATUS SANITIZATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$fileWatcherModule = Join-Path $botDir "src/ui/modules/FileWatcher.psm1"
$controlApiModule = Join-Path $botDir "src/ui/modules/ControlAPI.psm1"
$processApiModule = Join-Path $botDir "src/ui/modules/ProcessAPI.psm1"
$stateBuilderModule = Join-Path $botDir "src/ui/modules/StateBuilder.psm1"
$steeringHeartbeatScript = Join-Path $botDir "src/mcp/tools/steering-heartbeat/script.ps1"
$dotBotLogModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Logging/Dotbot.Logging.psd1"
$consoleSanitizerModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Core/Dotbot.Core.psm1"
$testControlDir = Join-Path $botDir ".control"
$testProcessesDir = Join-Path $testControlDir "processes"
$testLogsDir = Join-Path $testControlDir "logs"

if ((Test-Path $fileWatcherModule) -and (Test-Path $controlApiModule) -and (Test-Path $processApiModule) -and (Test-Path $stateBuilderModule) -and (Test-Path $steeringHeartbeatScript) -and (Test-Path $dotBotLogModule) -and (Test-Path $consoleSanitizerModule)) {
    Import-Module $consoleSanitizerModule -Force
    Import-Module $dotBotLogModule -Force
    Import-Module $fileWatcherModule -Force
    Import-Module $controlApiModule -Force
    Import-Module $processApiModule -Force
    Import-Module $stateBuilderModule -Force
    $global:DotbotProjectRoot = $testProject
    . $steeringHeartbeatScript

    if (-not (Test-Path $testLogsDir)) {
        New-Item -Path $testLogsDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $testProcessesDir)) {
        New-Item -Path $testProcessesDir -ItemType Directory -Force | Out-Null
    }
    Initialize-DotbotLog -LogDir $testLogsDir -ControlDir $testControlDir -ProjectRoot $testProject
    Initialize-FileWatchers -BotRoot $botDir
    Initialize-ControlAPI -ControlDir $testControlDir -ProcessesDir $testProcessesDir -BotRoot $botDir
    Initialize-ProcessAPI -ProcessesDir $testProcessesDir -BotRoot $botDir -ControlDir $testControlDir
    Initialize-StateBuilder -BotRoot $botDir -ControlDir $testControlDir -ProcessesDir $testProcessesDir

    # Steering heartbeat resolves .control via Get-DotbotProjectBotPath (cwd-walked),
    # so cd into the test project for the duration of the section.
    Push-Location $testProject

    $testProcId = "proc-ansi-sanitize"
    $testProcFile = Join-Path $testProcessesDir "$testProcId.json"
    $testActivityFile = Join-Path $testProcessesDir "$testProcId.activity.jsonl"
    $globalActivityFile = Join-Path $testControlDir "activity.jsonl"
    $esc = [char]27

    try {
        @{
            id = $testProcId
            type = "execution"
            status = "running"
            pid = $PID
            started_at = (Get-Date).ToUniversalTime().ToString("o")
            last_heartbeat = (Get-Date).ToUniversalTime().ToString("o")
            last_whisper_index = 0
            heartbeat_status = $null
            heartbeat_next_action = $null
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $heartbeatResult = Invoke-SteeringHeartbeat -Arguments @{
            session_id = "test-session-ansi"
            process_id = $testProcId
            status = "${esc}[38;2;56;52;44mIdle${esc}[0m"
            next_action = "${esc}[38;2;112;104;92mWait${esc}[0m"
        }

        Assert-True -Name "steering_heartbeat accepts ANSI-bearing status text" `
            -Condition ($heartbeatResult.success -eq $true) `
            -Message "Expected heartbeat tool to succeed"

        $storedProc = Get-Content $testProcFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "steering_heartbeat strips ANSI from stored heartbeat_status" `
            -Expected "Idle" `
            -Actual $storedProc.heartbeat_status
        Assert-Equal -Name "steering_heartbeat strips ANSI from stored heartbeat_next_action" `
            -Expected "Wait" `
            -Actual $storedProc.heartbeat_next_action
        Assert-Equal -Name "Console sanitizer preserves plain bracketed text" `
            -Expected "[1]" `
            -Actual (ConvertTo-SanitizedConsoleText "[1]")
        Assert-Equal -Name "Console sanitizer preserves bracketed words" `
            -Expected "[workflow] phase 1" `
            -Actual (ConvertTo-SanitizedConsoleText "[workflow] phase 1")
        Assert-True -Name "Console sanitizer strips parameterless orphaned reset fragment" `
            -Condition ($null -eq (ConvertTo-SanitizedConsoleText "[m")) `
            -Message "Expected parameterless reset fragment to be removed"

        $heartbeatBlankResult = Invoke-SteeringHeartbeat -Arguments @{
            session_id = "test-session-ansi"
            process_id = $testProcId
            status = "${esc}[0m"
            next_action = "${esc}[0m"
        }

        Assert-True -Name "steering_heartbeat accepts control-only heartbeat updates" `
            -Condition ($heartbeatBlankResult.success -eq $true) `
            -Message "Expected heartbeat tool to succeed"

        $storedProc = Get-Content $testProcFile -Raw | ConvertFrom-Json
        Assert-True -Name "steering_heartbeat normalizes empty heartbeat_status to null" `
            -Condition ($null -eq $storedProc.heartbeat_status) `
            -Message "Expected heartbeat_status to be null after sanitization"
        Assert-True -Name "steering_heartbeat normalizes empty heartbeat_next_action to null" `
            -Condition ($null -eq $storedProc.heartbeat_next_action) `
            -Message "Expected heartbeat_next_action to be null after sanitization"

        $storedProc.heartbeat_status = "[38;2;56;52;44mIdle[0m"
        $storedProc.heartbeat_next_action = "[38;2;112;104;92mWait[0m"
        $storedProc | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $listedProc = @((Get-ProcessList).processes | Where-Object { $_.id -eq $testProcId }) | Select-Object -First 1
        Assert-Equal -Name "Get-ProcessList strips orphaned ANSI fragments from heartbeat_status" `
            -Expected "Idle" `
            -Actual $listedProc.heartbeat_status
        Assert-Equal -Name "Get-ProcessList strips orphaned ANSI fragments from heartbeat_next_action" `
            -Expected "Wait" `
            -Actual $listedProc.heartbeat_next_action

        Clear-StateCache
        $state = Get-BotState
        Assert-Equal -Name "Get-BotState exposes sanitized execution status" `
            -Expected "Idle" `
            -Actual $state.instances.execution.status
        Assert-Equal -Name "Get-BotState exposes sanitized execution next_action" `
            -Expected "Wait" `
            -Actual $state.instances.execution.next_action

        $storedProc.heartbeat_status = "[0m"
        $storedProc.heartbeat_next_action = "[0m"
        $storedProc | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $listedProc = @((Get-ProcessList).processes | Where-Object { $_.id -eq $testProcId }) | Select-Object -First 1
        Assert-True -Name "Get-ProcessList normalizes empty heartbeat_status to null" `
            -Condition ($null -eq $listedProc.heartbeat_status) `
            -Message "Expected heartbeat_status to be null after sanitization"
        Assert-True -Name "Get-ProcessList normalizes empty heartbeat_next_action to null" `
            -Condition ($null -eq $listedProc.heartbeat_next_action) `
            -Message "Expected heartbeat_next_action to be null after sanitization"

        Clear-StateCache
        $state = Get-BotState
        Assert-True -Name "Get-BotState normalizes empty execution status to null" `
            -Condition ($null -eq $state.instances.execution.status) `
            -Message "Expected execution status to be null after sanitization"
        Assert-True -Name "Get-BotState normalizes empty execution next_action to null" `
            -Condition ($null -eq $state.instances.execution.next_action) `
            -Message "Expected execution next_action to be null after sanitization"

        $storedProc.status = "running"
        $storedProc.pid = 999999
        $storedProc | Add-Member -NotePropertyName failed_at -NotePropertyValue $null -Force
        $storedProc | Add-Member -NotePropertyName error -NotePropertyValue $null -Force
        $storedProc.heartbeat_status = "[38;2;56;52;44mIdle[0m"
        $storedProc.heartbeat_next_action = "[0m"
        $storedProc | ConvertTo-Json -Depth 10 | Set-Content -Path $testProcFile -Encoding utf8NoBOM

        $listedProc = @((Get-ProcessList).processes | Where-Object { $_.id -eq $testProcId }) | Select-Object -First 1
        $rewrittenProc = Get-Content $testProcFile -Raw | ConvertFrom-Json
        Assert-Equal -Name "dead PID rewrite persists sanitized heartbeat_status" `
            -Expected "Idle" `
            -Actual $rewrittenProc.heartbeat_status
        Assert-True -Name "dead PID rewrite persists null heartbeat_next_action" `
            -Condition ($null -eq $rewrittenProc.heartbeat_next_action) `
            -Message "Expected heartbeat_next_action to be null after dead PID rewrite"
        Assert-Equal -Name "dead PID rewrite returns stopped process" `
            -Expected "stopped" `
            -Actual $listedProc.status

        $oldStoppedProcId = "proc-old-stopped"
        $oldStoppedProcFile = Join-Path $testProcessesDir "$oldStoppedProcId.json"
        $oldStoppedActivityFile = Join-Path $testProcessesDir "$oldStoppedProcId.activity.jsonl"
        @{
            id = $oldStoppedProcId
            type = "task-runner"
            status = "stopped"
            pid = 999998
            started_at = (Get-Date).ToUniversalTime().AddHours(-2).ToString("o")
            failed_at = (Get-Date).ToUniversalTime().AddHours(-2).ToString("o")
            last_heartbeat = (Get-Date).ToUniversalTime().AddHours(-2).ToString("o")
            last_whisper_index = 0
            heartbeat_status = "Stopped after diagnostic failure"
            heartbeat_next_action = $null
            error = "preserve me"
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $oldStoppedProcFile -Encoding utf8NoBOM
        '{"timestamp":"2026-05-28T00:00:00Z","type":"text","message":"diagnostic trail"}' |
            Set-Content -Path $oldStoppedActivityFile -Encoding utf8NoBOM

        $oldStoppedListed = @((Get-ProcessList).processes | Where-Object { $_.id -eq $oldStoppedProcId }) | Select-Object -First 1
        Assert-True -Name "Get-ProcessList preserves old stopped process records" `
            -Condition ($null -ne $oldStoppedListed -and (Test-Path $oldStoppedProcFile)) `
            -Message "Stopped processes should remain visible for diagnosis instead of being pruned by the list endpoint"
        Assert-PathExists -Name "Get-ProcessList preserves old stopped activity log" `
            -Path $oldStoppedActivityFile

        @(
            (@{
                timestamp = (Get-Date).ToUniversalTime().ToString("o")
                type = "text"
                message = "[38;2;56;52;44m[12:28:39][0m [38;2;112;104;92mGET[0m [workflow]"
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $testActivityFile -Encoding utf8NoBOM

        $outputData = Get-ProcessOutput -ProcessId $testProcId -Position 0 -Tail 50
        Assert-Equal -Name "Get-ProcessOutput strips ANSI fragments from activity messages" `
            -Expected "[12:28:39] GET [workflow]" `
            -Actual $outputData.events[0].message

        @(
            (@{
                timestamp = (Get-Date).ToUniversalTime().ToString("o")
                type = "text"
                message = "[38;2;56;52;44m[12:28:39][0m [38;2;112;104;92mGET[0m [workflow]"
            } | ConvertTo-Json -Compress)
        ) | Set-Content -Path $globalActivityFile -Encoding utf8NoBOM

        $activityTail = Get-ActivityTail -Position 0 -TailLines 50
        Assert-Equal -Name "Get-ActivityTail strips ANSI fragments from global activity messages" `
            -Expected "[12:28:39] GET [workflow]" `
            -Actual $activityTail.events[0].message
    } finally {
        if (Test-Path $testProcFile) {
            Remove-Item $testProcFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $testActivityFile) {
            Remove-Item $testActivityFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $globalActivityFile) {
            Remove-Item $globalActivityFile -Force -ErrorAction SilentlyContinue
        }
        Pop-Location
    }
} else {
    Write-TestResult -Name "Process status sanitization test modules exist" -Status Fail -Message "One or more UI/process modules were not found in $botDir"
}

# Commit any framework file changes made by the tests above (e.g. config.json
# stripping, settings backfill) so the integrity gate sees a clean state.
Push-Location $testProject
$manifestModule = Join-Path $botDir "src/mcp/modules/FrameworkIntegrity.psm1"
if (Test-Path $manifestModule) {
    Import-Module $manifestModule -Force
    $frameworkPaths = Get-FrameworkProtectedPaths
    # Manifest.psm1 is a sibling of FrameworkIntegrity.psm1 in both source and target.
    $manifestMod = Join-Path (Split-Path $manifestModule) "Manifest.psm1"
    if (Test-Path $manifestMod) {
        Import-Module $manifestMod -Force
        $null = New-DotbotManifest -ProjectRoot $testProject -ProtectedPaths $frameworkPaths -Generator 'test-setup'
    }
}
& git add -A 2>&1 | Out-Null
$env:DOTBOT_FORCE_COMMIT = "1"
& git commit -m "test: sync framework state" --quiet 2>&1 | Out-Null
$env:DOTBOT_FORCE_COMMIT = $null
Pop-Location

Write-Host ""

# MCP SERVER BOOT
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MCP SERVER" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$mcpProcess = $null
$requestId = 0

try {
    $mcpProcess = Start-McpServer -BotDir $botDir
    Assert-True -Name "MCP server starts" -Condition (-not $mcpProcess.HasExited) -Message "Server process exited immediately"

    # Initialize
    $initResponse = Send-McpInitialize -Process $mcpProcess
    Assert-True -Name "MCP initialize responds" `
        -Condition ($null -ne $initResponse) `
        -Message "No response from initialize"

    if ($initResponse) {
        Assert-True -Name "MCP returns protocol version" `
            -Condition ($null -ne $initResponse.result.protocolVersion) `
            -Message "Missing protocolVersion in response"

        Assert-True -Name "MCP returns server info" `
            -Condition ($null -ne $initResponse.result.serverInfo) `
            -Message "Missing serverInfo in response"
    }

    # List tools
    $requestId++
    $listResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/list'
        params  = @{}
    }

    Assert-True -Name "MCP tools/list responds" `
        -Condition ($null -ne $listResponse) `
        -Message "No response from tools/list"

    if ($listResponse -and $listResponse.result) {
        $toolCount = $listResponse.result.tools.Count
        Assert-True -Name "MCP has tools loaded (found $toolCount)" `
            -Condition ($toolCount -gt 0) `
            -Message "No tools loaded"

        # Check key tools exist. collapsed the per-status task-mark-*
        # tools into task_set_status, removed task_get_stats and
        # task_create_bulk, and added task_get + task_update + the workflow_*
        # trio. The HTTP-boundary coverage for the new tools lives in
        # Test-McpSurface.ps1; here we only assert that the MCP server
        # registers them.
        $toolNames = $listResponse.result.tools | ForEach-Object { $_.name }
        $expectedTools = @(
            'task_create', 'task_get', 'task_list', 'task_update',
            'task_set_status', 'task_get_next', 'task_get_context',
            'workflow_start', 'workflow_get', 'workflow_list',
            'session_initialize',
            'decision_create', 'decision_get', 'decision_list', 'decision_update',
            'decision_mark_accepted', 'decision_mark_deprecated', 'decision_mark_superseded'
        )
        foreach ($tool in $expectedTools) {
            Assert-True -Name "Tool '$tool' registered" `
                -Condition ($tool -in $toolNames) `
                -Message "Tool not found in tools/list"
        }
    }

    Write-Host ""

    # TASK LIFECYCLE / VALIDATION / TYPES / STATS sections
    # removed — they exercised task-mark-*, task-create-bulk, and
    # task-get-stats (now gone) and the in-process MCP modules that
    # backed them. The new MCP surface is covered by Test-McpSurface;
    # will land an end-to-end replacement against the runtime.
    # ═══════════════════════════════════════════════════════════════════
    # DECISION LIFECYCLE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  DECISION LIFECYCLE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Create a decision
    $requestId++
    $decCreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_create'
            arguments = @{
                title   = 'Use PowerShell for MCP Server'
                context = 'We need a language for the MCP server implementation'
                decision = 'Use PowerShell 7+ as the sole implementation language'
                type    = 'architecture'
                impact  = 'high'
                consequences = 'Limited to PowerShell ecosystem'
            }
        }
    }

    Assert-True -Name "decision_create responds" `
        -Condition ($null -ne $decCreateResponse) `
        -Message "No response"

    $decId = $null
    if ($decCreateResponse -and $decCreateResponse.result) {
        $decText = $decCreateResponse.result.content[0].text
        $decObj = $decText | ConvertFrom-Json
        Assert-True -Name "decision_create returns success" `
            -Condition ($decObj.success -eq $true) `
            -Message "success was not true: $decText"
        $decId = $decObj.decision_id
        Assert-True -Name "decision_create returns decision_id" `
            -Condition ($null -ne $decId -and $decId.Length -gt 0) `
            -Message "No decision_id in response"
    }

    # Verify decision file exists in proposed/
    if ($decId) {
        $proposedDir = Join-Path $botDir "workspace\decisions\proposed"
        $proposedFiles = Get-ChildItem -Path $proposedDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file created in proposed/" `
            -Condition ($proposedFiles.Count -gt 0) `
            -Message "No .json files found in proposed/"
    }

    # List decisions
    $requestId++
    $decListResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_list'
            arguments = @{}
        }
    }

    Assert-True -Name "decision_list responds" `
        -Condition ($null -ne $decListResponse) `
        -Message "No response"

    if ($decListResponse -and $decListResponse.result) {
        $decListText = $decListResponse.result.content[0].text
        $decListObj = $decListText | ConvertFrom-Json
        $decCount = if ($decListObj.decisions) { $decListObj.decisions.Count } else { 0 }
        Assert-True -Name "decision_list shows created decision" `
            -Condition ($decListObj.success -eq $true -and $decCount -gt 0) `
            -Message "No decisions found: $decListText"
    }

    # Get decision
    if ($decId) {
        $requestId++
        $decGetResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_get'
                arguments = @{ decision_id = $decId }
            }
        }

        Assert-True -Name "decision_get responds" `
            -Condition ($null -ne $decGetResponse) `
            -Message "No response"

        if ($decGetResponse -and $decGetResponse.result) {
            $decGetText = $decGetResponse.result.content[0].text
            $decGetObj = $decGetText | ConvertFrom-Json
            Assert-True -Name "decision_get returns success" `
                -Condition ($decGetObj.success -eq $true) `
                -Message "Failed: $decGetText"
            Assert-True -Name "decision_get returns correct title" `
                -Condition ($decGetObj.title -eq 'Use PowerShell for MCP Server') `
                -Message "Wrong title: $($decGetObj.title)"
        }
    }

    # Update decision
    if ($decId) {
        $requestId++
        $decUpdateResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_update'
                arguments = @{
                    decision_id = $decId
                    consequences = 'Limited to PowerShell ecosystem but mitigated by cross-platform pwsh'
                }
            }
        }

        Assert-True -Name "decision_update responds" `
            -Condition ($null -ne $decUpdateResponse) `
            -Message "No response"

        if ($decUpdateResponse -and $decUpdateResponse.result) {
            $decUpdateText = $decUpdateResponse.result.content[0].text
            $decUpdateObj = $decUpdateText | ConvertFrom-Json
            Assert-True -Name "decision_update succeeds" `
                -Condition ($decUpdateObj.success -eq $true) `
                -Message "Failed: $decUpdateText"
        }
    }

    # Mark accepted
    if ($decId) {
        $requestId++
        $decAcceptResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_mark_accepted'
                arguments = @{ decision_id = $decId }
            }
        }

        Assert-True -Name "decision_mark_accepted responds" `
            -Condition ($null -ne $decAcceptResponse) `
            -Message "No response"

        if ($decAcceptResponse -and $decAcceptResponse.result) {
            $decAcceptText = $decAcceptResponse.result.content[0].text
            $decAcceptObj = $decAcceptText | ConvertFrom-Json
            Assert-True -Name "decision_mark_accepted succeeds" `
                -Condition ($decAcceptObj.success -eq $true) `
                -Message "Failed: $decAcceptText"
        }

        # Verify file moved to accepted/
        $acceptedDir = Join-Path $botDir "workspace\decisions\accepted"
        $acceptedFiles = Get-ChildItem -Path $acceptedDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file moved to accepted/" `
            -Condition ($acceptedFiles.Count -gt 0) `
            -Message "No .json files found in accepted/"
    }

    # Create a second decision to test superseded
    $requestId++
    $dec2CreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_create'
            arguments = @{
                title    = 'Switch to TypeScript for MCP'
                context  = 'Performance concerns with PowerShell approach'
                decision = 'Migrate MCP server to TypeScript'
                status   = 'accepted'
            }
        }
    }

    $dec2Id = $null
    if ($dec2CreateResponse -and $dec2CreateResponse.result) {
        $dec2Text = $dec2CreateResponse.result.content[0].text
        $dec2Obj = $dec2Text | ConvertFrom-Json
        $dec2Id = $dec2Obj.decision_id
    }

    # Mark first decision as superseded by second
    if ($decId -and $dec2Id) {
        $requestId++
        $decSuperResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_mark_superseded'
                arguments = @{
                    decision_id   = $decId
                    superseded_by = $dec2Id
                }
            }
        }

        Assert-True -Name "decision_mark_superseded responds" `
            -Condition ($null -ne $decSuperResponse) `
            -Message "No response"

        if ($decSuperResponse -and $decSuperResponse.result) {
            $decSuperText = $decSuperResponse.result.content[0].text
            $decSuperObj = $decSuperText | ConvertFrom-Json
            Assert-True -Name "decision_mark_superseded succeeds" `
                -Condition ($decSuperObj.success -eq $true) `
                -Message "Failed: $decSuperText"
        }

        # Verify file moved to superseded/
        $supersededDir = Join-Path $botDir "workspace\decisions\superseded"
        $supersededFiles = Get-ChildItem -Path $supersededDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file moved to superseded/" `
            -Condition ($supersededFiles.Count -gt 0) `
            -Message "No .json files found in superseded/"
    }

    # Create a third decision to test deprecated
    $requestId++
    $dec3CreateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_create'
            arguments = @{
                title    = 'Use Redis for Caching'
                context  = 'Need caching layer for performance'
                decision = 'Use Redis as the caching backend'
                status   = 'accepted'
            }
        }
    }

    $dec3Id = $null
    if ($dec3CreateResponse -and $dec3CreateResponse.result) {
        $dec3Text = $dec3CreateResponse.result.content[0].text
        $dec3Obj = $dec3Text | ConvertFrom-Json
        $dec3Id = $dec3Obj.decision_id
    }

    # Mark deprecated
    if ($dec3Id) {
        $requestId++
        $decDepResponse = Send-McpRequest -Process $mcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $requestId
            method  = 'tools/call'
            params  = @{
                name      = 'decision_mark_deprecated'
                arguments = @{
                    decision_id = $dec3Id
                    reason = 'Caching no longer needed after architecture simplification'
                }
            }
        }

        Assert-True -Name "decision_mark_deprecated responds" `
            -Condition ($null -ne $decDepResponse) `
            -Message "No response"

        if ($decDepResponse -and $decDepResponse.result) {
            $decDepText = $decDepResponse.result.content[0].text
            $decDepObj = $decDepText | ConvertFrom-Json
            Assert-True -Name "decision_mark_deprecated succeeds" `
                -Condition ($decDepObj.success -eq $true) `
                -Message "Failed: $decDepText"
        }

        # Verify file moved to deprecated/
        $deprecatedDir = Join-Path $botDir "workspace\decisions\deprecated"
        $deprecatedFiles = Get-ChildItem -Path $deprecatedDir -Filter "*.json" -ErrorAction SilentlyContinue
        Assert-True -Name "Decision file moved to deprecated/" `
            -Condition ($deprecatedFiles.Count -gt 0) `
            -Message "No .json files found in deprecated/"
    }

    # List with status filter
    $requestId++
    $decListFilteredResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'decision_list'
            arguments = @{ status = 'accepted' }
        }
    }

    Assert-True -Name "decision_list with status filter responds" `
        -Condition ($null -ne $decListFilteredResponse) `
        -Message "No response"

    if ($decListFilteredResponse -and $decListFilteredResponse.result) {
        $decFilterText = $decListFilteredResponse.result.content[0].text
        $decFilterObj = $decFilterText | ConvertFrom-Json
        Assert-True -Name "decision_list filters by status" `
            -Condition ($decFilterObj.success -eq $true) `
            -Message "Failed: $decFilterText"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # SESSION LIFECYCLE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  SESSION LIFECYCLE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Initialize session
    $requestId++
    $sessionInitResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'session_initialize'
            arguments = @{}
        }
    }

    Assert-True -Name "session_initialize responds" `
        -Condition ($null -ne $sessionInitResponse) `
        -Message "No response"

    # Get session state
    $requestId++
    $sessionStateResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'session_get_state'
            arguments = @{}
        }
    }

    Assert-True -Name "session_get_state responds" `
        -Condition ($null -ne $sessionStateResponse) `
        -Message "No response"

    # Get session stats
    $requestId++
    $sessionStatsResponse = Send-McpRequest -Process $mcpProcess -Request @{
        jsonrpc = '2.0'
        id      = $requestId
        method  = 'tools/call'
        params  = @{
            name      = 'session_get_stats'
            arguments = @{}
        }
    }

    Assert-True -Name "session_get_stats responds" `
        -Condition ($null -ne $sessionStatsResponse) `
        -Message "No response"

    Write-Host ""

    # TASK_GET_NEXT / TASK_MARK_ANALYSING / TASK_MARK_ANALYSED /
    # TASK_GET_CONTEXT / FULL WORKFLOW LIFECYCLE sections removed —
    # they exercised the per-status task-mark-* tools and end-to-end
    # via in-process MCP modules. Both layers are now runtime-owned
    #. HTTP-boundary coverage lives in Test-McpSurface;
    # will land an end-to-end replacement against the runtime.

} catch {
    Write-TestResult -Name "MCP server tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
} finally {
    if ($mcpProcess) {
        Stop-McpServer -Process $mcpProcess
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# Dotbot.Harness MODULE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  Dotbot.Harness MODULE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Test that Dotbot.Harness module loads (use dotbotDir which points to installed profiles)
$harnessPath = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psd1"
$harnessLoaded = $false
try {
    Import-Module $harnessPath -Force -ErrorAction Stop
    $harnessLoaded = $true
} catch { Write-Verbose "Non-critical operation failed: $_" }

Assert-True -Name "Dotbot.Harness module loads" `
    -Condition $harnessLoaded `
    -Message "Failed to import Dotbot.Harness module"

if ($harnessLoaded) {
    # Adapters registered correctly (plugin architecture smoke test)
    $registered = Get-RegisteredHarnessAdapters
    Assert-True -Name "ClaudeCode adapter registered" `
        -Condition ($registered -contains 'ClaudeCode') `
        -Message "Adapters registered: $($registered -join ', ')"
    Assert-True -Name "Codex adapter registered" `
        -Condition ($registered -contains 'Codex') `
        -Message "Adapters registered: $($registered -join ', ')"
    Assert-True -Name "Antigravity adapter registered" `
        -Condition ($registered -contains 'Antigravity') `
        -Message "Adapters registered: $($registered -join ', ')"
    Assert-True -Name "OpenCode adapter registered" `
        -Condition ($registered -contains 'OpenCode') `
        -Message "Adapters registered: $($registered -join ', ')"

    # Test Get-HarnessConfig for Claude (default)
    $claudeConfig = $null
    try { $claudeConfig = Get-HarnessConfig -Name "claude" } catch { Write-Verbose "Settings operation failed: $_" }
    Assert-True -Name "Get-HarnessConfig loads claude config" `
        -Condition ($null -ne $claudeConfig -and $claudeConfig.name -eq "claude") `
        -Message "Expected claude config"

    # Test Get-HarnessConfig surfaces adapter field
    Assert-True -Name "Claude config has adapter='ClaudeCode'" `
        -Condition ($null -ne $claudeConfig -and $claudeConfig.adapter -eq 'ClaudeCode') `
        -Message "Expected adapter=ClaudeCode, got '$($claudeConfig.adapter)'"

    $openCodeConfig = $null
    try { $openCodeConfig = Get-HarnessConfig -Name "opencode" } catch { Write-Verbose "Settings operation failed: $_" }
    Assert-True -Name "Get-HarnessConfig loads opencode config" `
        -Condition ($null -ne $openCodeConfig -and $openCodeConfig.adapter -eq "OpenCode") `
        -Message "Expected OpenCode adapter config"

    # Test Get-HarnessModels
    $models = $null
    try { $models = Get-HarnessModels -HarnessName "claude" } catch { Write-Verbose "Settings operation failed: $_" }
    Assert-True -Name "Get-HarnessModels returns three canonical tiers" `
        -Condition ($null -ne $models -and $models.Count -eq 3 -and (@($models.Tier) -contains "fast") -and (@($models.Tier) -contains "balanced") -and (@($models.Tier) -contains "best")) `
        -Message "Expected fast, balanced, best model tiers"

    # Test model tier resolution
    $resolvedTier = $null
    try { $resolvedTier = Resolve-HarnessModelTier -Model "best" -HarnessName "claude" } catch { Write-Verbose "Non-critical operation failed: $_" }
    Assert-True -Name "Resolve-HarnessModelTier accepts best" `
        -Condition ($resolvedTier -eq "best") `
        -Message "Expected best, got $resolvedTier"

    $resolvedId = $null
    try { $resolvedId = Resolve-HarnessModelId -ModelAlias "best" -HarnessName "claude" } catch { Write-Verbose "Non-critical operation failed: $_" }
    Assert-True -Name "Resolve-HarnessModelId maps best to provider id" `
        -Condition (-not [string]::IsNullOrWhiteSpace($resolvedId)) `
        -Message "Expected non-empty provider model id"

    foreach ($harnessName in @("claude", "codex", "antigravity", "opencode")) {
        foreach ($tier in @("fast", "balanced", "best")) {
            $modelId = $null
            try { $modelId = Resolve-HarnessModelId -ModelAlias $tier -HarnessName $harnessName } catch { Write-Verbose "Non-critical operation failed: $_" }
            Assert-True -Name "$harnessName $tier tier resolves to adapter-owned model id" `
                -Condition (-not [string]::IsNullOrWhiteSpace($modelId)) `
                -Message "Expected non-empty provider model id"
        }
    }

    $invalidModelError = $false
    try { Resolve-HarnessModelTier -Model "not-a-tier" -HarnessName "codex" | Out-Null } catch { $invalidModelError = $true }
    Assert-True -Name "Resolve-HarnessModelTier rejects unknown models" `
        -Condition $invalidModelError `
        -Message "Should throw for invalid model tier"

    # Test New-HarnessSession for Claude (returns GUID)
    $claudeSession = $null
    try { $claudeSession = New-HarnessSession -HarnessName "claude" } catch { Write-Verbose "Session operation failed: $_" }
    Assert-True -Name "New-HarnessSession returns GUID for Claude" `
        -Condition ($null -ne $claudeSession -and $claudeSession -match '^[0-9a-f]{8}-') `
        -Message "Expected GUID, got $claudeSession"

    # Test New-HarnessSession for Codex (returns null — no session support)
    $codexSession = "not-null"
    try { $codexSession = New-HarnessSession -HarnessName "codex" } catch { Write-Verbose "Session operation failed: $_" }
    Assert-True -Name "New-HarnessSession returns null for Codex" `
        -Condition ($null -eq $codexSession) `
        -Message "Expected null, got $codexSession"

    # ─────────────────────────────────────────────
    # PERMISSION MODE TESTS
    # ─────────────────────────────────────────────

    Write-Host ""
    Write-Host "  PERMISSION MODE TESTS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Test harness config has permission_modes
    if ($claudeConfig) {
        Assert-True -Name "Claude config has permission_modes" `
            -Condition ($null -ne $claudeConfig.permission_modes) `
            -Message "Missing permission_modes on loaded config"

        Assert-True -Name "Claude config has default_permission_mode" `
            -Condition ($null -ne $claudeConfig.default_permission_mode) `
            -Message "Missing default_permission_mode"

        Assert-True -Name "Claude default_permission_mode is bypassPermissions" `
            -Condition ($claudeConfig.default_permission_mode -eq "bypassPermissions") `
            -Message "Expected bypassPermissions, got $($claudeConfig.default_permission_mode)"
    }

    # Test Build-HarnessCliArgs with default permission mode (no PermissionMode param)
    if ($claudeConfig) {
        $defaultArgs = $null
        try {
            $testModelId = Resolve-HarnessModelId -ModelAlias "best" -HarnessName "claude"
            $defaultArgs = Build-HarnessCliArgs -Config $claudeConfig -Prompt "test" -ModelId $testModelId -Streaming $false
        } catch { Write-Verbose "Build args failed: $_" }
        Assert-True -Name "Build-HarnessCliArgs returns args without PermissionMode" `
            -Condition ($null -ne $defaultArgs -and $defaultArgs.Count -gt 0) `
            -Message "Expected non-empty args array"

        if ($defaultArgs) {
            $hasBypass = $defaultArgs -contains "--dangerously-skip-permissions"
            Assert-True -Name "Default permission mode uses --dangerously-skip-permissions" `
                -Condition $hasBypass `
                -Message "Expected --dangerously-skip-permissions in args: $($defaultArgs -join ' ')"
        }
    }

    # Test Build-HarnessCliArgs with explicit auto permission mode
    if ($claudeConfig) {
        $autoArgs = $null
        try {
            $testModelId = Resolve-HarnessModelId -ModelAlias "best" -HarnessName "claude"
            $autoArgs = Build-HarnessCliArgs -Config $claudeConfig -Prompt "test" -ModelId $testModelId -Streaming $false -PermissionMode "auto"
        } catch { Write-Verbose "Build args failed: $_" }
        Assert-True -Name "Build-HarnessCliArgs returns args with auto mode" `
            -Condition ($null -ne $autoArgs -and $autoArgs.Count -gt 0) `
            -Message "Expected non-empty args array"

        if ($autoArgs) {
            $hasPermMode = ($autoArgs -contains "--permission-mode")
            $hasAuto = ($autoArgs -contains "auto")
            Assert-True -Name "Auto permission mode uses --permission-mode auto" `
                -Condition ($hasPermMode -and $hasAuto) `
                -Message "Expected --permission-mode auto in args: $($autoArgs -join ' ')"

            $noBypass = -not ($autoArgs -contains "--dangerously-skip-permissions")
            Assert-True -Name "Auto permission mode does not include bypass flag" `
                -Condition $noBypass `
                -Message "Should not contain --dangerously-skip-permissions with auto mode"
        }
    }

    # Test Build-HarnessCliArgs with explicit bypassPermissions mode
    if ($claudeConfig) {
        $bypassArgs = $null
        try {
            $testModelId = Resolve-HarnessModelId -ModelAlias "best" -HarnessName "claude"
            $bypassArgs = Build-HarnessCliArgs -Config $claudeConfig -Prompt "test" -ModelId $testModelId -Streaming $false -PermissionMode "bypassPermissions"
        } catch { Write-Verbose "Build args failed: $_" }

        if ($bypassArgs) {
            $hasBypass = $bypassArgs -contains "--dangerously-skip-permissions"
            Assert-True -Name "bypassPermissions mode uses --dangerously-skip-permissions" `
                -Condition $hasBypass `
                -Message "Expected bypass flag in args: $($bypassArgs -join ' ')"
        }
    }

    # Test Build-HarnessCliArgs rejects invalid permission modes
    if ($claudeConfig) {
        $invalidModeRejected = $false
        try {
            $testModelId = Resolve-HarnessModelId -ModelAlias "best" -HarnessName "claude"
            Build-HarnessCliArgs -Config $claudeConfig -Prompt "test" -ModelId $testModelId -Streaming $false -PermissionMode "not-a-mode" | Out-Null
        } catch { $invalidModeRejected = $true }
        Assert-True -Name "Build-HarnessCliArgs rejects invalid permission modes" `
            -Condition $invalidModeRejected `
            -Message "Expected invalid permission mode to throw"
    }

    # Test Build-HarnessCliArgs for Codex with full-auto mode
    $codexConfig = $null
    try { $codexConfig = Get-HarnessConfig -Name "codex" } catch { Write-Verbose "Config load failed: $_" }
    if ($codexConfig -and $codexConfig.permission_modes) {
        $codexAutoArgs = $null
        try {
            $testModelId = Resolve-HarnessModelId -ModelAlias "best" -HarnessName "codex"
            $codexAutoArgs = Build-HarnessCliArgs -Config $codexConfig -Prompt "test" -ModelId $testModelId -Streaming $false -PermissionMode "full-auto"
        } catch { Write-Verbose "Build args failed: $_" }

        if ($codexAutoArgs) {
            $hasFullAuto = $codexAutoArgs -contains "--full-auto"
            Assert-True -Name "Codex full-auto mode uses --full-auto" `
                -Condition $hasFullAuto `
                -Message "Expected --full-auto in args: $($codexAutoArgs -join ' ')"

            Assert-True -Name "Codex prompt is not embedded in CLI args" `
                -Condition (-not ($codexAutoArgs -contains "test")) `
                -Message "Codex should read the prompt from stdin: $($codexAutoArgs -join ' ')"
        }
    }

    # Test Build-HarnessCliArgs for Antigravity with auto_edit mode
    $antigravityConfig = $null
    try { $antigravityConfig = Get-HarnessConfig -Name "antigravity" } catch { Write-Verbose "Config load failed: $_" }
    if ($antigravityConfig -and $antigravityConfig.permission_modes) {
        $antigravityEditArgs = $null
        try {
            $testModelId = Resolve-HarnessModelId -ModelAlias "balanced" -HarnessName "antigravity"
            $antigravityEditArgs = Build-HarnessCliArgs -Config $antigravityConfig -Prompt "test" -ModelId $testModelId -Streaming $false -PermissionMode "auto_edit"
        } catch { Write-Verbose "Build args failed: $_" }

        if ($antigravityEditArgs) {
            $hasApproval = $antigravityEditArgs -contains "--approval-mode"
            $hasAutoEdit = $antigravityEditArgs -contains "auto_edit"
            Assert-True -Name "Antigravity auto_edit mode uses --approval-mode auto_edit" `
                -Condition ($hasApproval -and $hasAutoEdit) `
                -Message "Expected --approval-mode auto_edit in args: $($antigravityEditArgs -join ' ')"

            # Antigravity now delivers prompt via stdin (prompt_flag=null) to
            # avoid the Windows CreateProcess command-line length limit.
            $hasPromptFlag = $antigravityEditArgs -contains "-p"
            $hasPromptValue = $antigravityEditArgs -contains "test"
            Assert-True -Name "Antigravity prompt is delivered via stdin, not -p" `
                -Condition (-not $hasPromptFlag -and -not $hasPromptValue) `
                -Message "Did not expect -p/prompt in args: $($antigravityEditArgs -join ' ')"
        }
    }

    # Test Build-HarnessCliArgs for OpenCode with worktree cwd forwarding
    $openCodeConfig = $null
    try { $openCodeConfig = Get-HarnessConfig -Name "opencode" } catch { Write-Verbose "Config load failed: $_" }
    if ($openCodeConfig -and $openCodeConfig.permission_modes) {
        $openCodeArgs = $null
        $worktreeDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-opencode-worktree"
        try {
            $openCodeArgs = Build-HarnessCliArgs -Config $openCodeConfig -Prompt "test" -ModelId $openCodeConfig.models.($openCodeConfig.default_model).id -Streaming $true -PermissionMode "bypass" -WorkingDirectory $worktreeDir
        } catch { Write-Verbose "Build args failed: $_" }

        if ($openCodeArgs) {
            Assert-True -Name "OpenCode worktree cwd uses --dir" `
                -Condition (($openCodeArgs -contains "--dir") -and ($openCodeArgs -contains $worktreeDir)) `
                -Message "Expected --dir $worktreeDir in args: $($openCodeArgs -join ' ')"

            Assert-True -Name "OpenCode prompt remains positional in adapter" `
                -Condition (-not ($openCodeArgs -contains "test")) `
                -Message "Build-HarnessCliArgs should not embed OpenCode prompt: $($openCodeArgs -join ' ')"
        }
    }

    # Config without permission_modes must not infer stale cli_args permissions
    $strictConfig = @{
        name = "test-harness"
        executable = "test"
        cli_args = @{
            model = "--model"
            permissions_bypass = "--stale-bypass-flag"
        }
    } | ConvertTo-Json -Depth 5 | ConvertFrom-Json

    $strictError = $false
    try {
        Build-HarnessCliArgs -Config $strictConfig -Prompt "test" -ModelId "test" -Streaming $false | Out-Null
    } catch { $strictError = $true }

    Assert-True -Name "Build-HarnessCliArgs requires permission_modes" `
        -Condition $strictError `
        -Message "Expected config without permission_modes to throw"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# NOTIFICATION CLIENT MODULE TESTS
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- NotificationClient Module ---" -ForegroundColor Cyan

$notifModule = Join-Path $botDir "src/mcp/modules/NotificationClient.psm1"

if (Test-Path $notifModule) {
    Import-Module $notifModule -Force

    # Test Get-NotificationSettings returns defaults when disabled
    $settings = Get-NotificationSettings -BotRoot $botDir
    Assert-True -Name "Get-NotificationSettings returns disabled by default" `
        -Condition ($settings.enabled -eq $false) `
        -Message "Expected enabled=false, got $($settings.enabled)"

    Assert-True -Name "Get-NotificationSettings returns default channel" `
        -Condition ($settings.channel -eq "teams") `
        -Message "Expected channel=teams, got $($settings.channel)"

    Assert-True -Name "Get-NotificationSettings returns default poll interval" `
        -Condition ($settings.poll_interval_seconds -eq 30) `
        -Message "Expected 30, got $($settings.poll_interval_seconds)"


    $parsedNotifGuid = [guid]::Empty
    Assert-True -Name "Get-NotificationSettings includes workspace instance_id" `
        -Condition ([guid]::TryParse("$($settings.instance_id)", [ref]$parsedNotifGuid)) `
        -Message "Expected settings.instance_id to be a valid GUID"
    # Test Test-NotificationServer returns false when no server configured
    $reachable = Test-NotificationServer -Settings $settings
    Assert-True -Name "Test-NotificationServer returns false when no URL" `
        -Condition ($reachable -eq $false) `
        -Message "Expected false with no server URL"

    # Test Send-TaskNotification no-ops when disabled
    $mockTask = [PSCustomObject]@{ id = "test123"; name = "Test task" }
    $mockQuestion = [PSCustomObject]@{
        id = "q1"
        question = "Which database?"
        context = "We need a DB"
        options = @(
            [PSCustomObject]@{ key = "A"; label = "PostgreSQL"; rationale = "Mature" },
            [PSCustomObject]@{ key = "B"; label = "SQLite"; rationale = "Simple" }
        )
        recommendation = "A"
    }
    $sendResult = Send-TaskNotification -TaskContent $mockTask -PendingQuestion $mockQuestion -Settings $settings
    Assert-True -Name "Send-TaskNotification returns not-configured when disabled" `
        -Condition ($sendResult.success -eq $false) `
        -Message "Expected success=false"

    # Test Get-TaskNotificationResponse returns null when disabled
    $mockNotification = [PSCustomObject]@{ question_id = "q1"; instance_id = "inst1" }
    $pollResult = Get-TaskNotificationResponse -Notification $mockNotification -Settings $settings
    Assert-True -Name "Get-TaskNotificationResponse returns null when disabled" `
        -Condition ($null -eq $pollResult) `
        -Message "Expected null"

    # ── Send-SplitProposalNotification tests ─────────────────────────
    $mockSplitTask = [PSCustomObject]@{ id = "split-test-1"; name = "Refactor auth" }
    $mockSplitProposal = [PSCustomObject]@{
        reason = "Task is too large"
        proposed_at = "2026-01-15T10:00:00Z"
        sub_tasks = @(
            [PSCustomObject]@{ name = "Extract middleware"; effort = "S"; description = "Pull out auth middleware" },
            [PSCustomObject]@{ name = "Add token rotation"; effort = "M"; description = "Implement refresh tokens" }
        )
    }

    $splitResult = Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $mockSplitProposal -Settings $settings
    Assert-True -Name "Send-SplitProposalNotification returns not-configured when disabled" `
        -Condition ($splitResult.success -eq $false) `
        -Message "Expected success=false, got $($splitResult.success)"

    # Test empty sub_tasks guard
    $emptySplitProposal = [PSCustomObject]@{
        reason = "Should fail"
        proposed_at = "2026-01-15T10:00:00Z"
        sub_tasks = @()
    }
    $emptyResult = Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $emptySplitProposal -Settings $settings
    Assert-True -Name "Send-SplitProposalNotification rejects empty sub_tasks" `
        -Condition ($emptyResult.success -eq $false -and $emptyResult.reason -match "no sub-tasks") `
        -Message "Expected failure with 'no sub-tasks' reason, got: $($emptyResult.reason)"

    # Test missing proposed_at guard
    $noPropAtProposal = [PSCustomObject]@{
        reason = "Should fail"
        sub_tasks = @(
            [PSCustomObject]@{ name = "Some task"; effort = "S" }
        )
    }
    $noPropAtResult = Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $noPropAtProposal -Settings $settings
    Assert-True -Name "Send-SplitProposalNotification rejects missing proposed_at" `
        -Condition ($noPropAtResult.success -eq $false -and $noPropAtResult.reason -match "proposed_at") `
        -Message "Expected failure with 'proposed_at' reason, got: $($noPropAtResult.reason)"

    # Test template structure with enabled settings (mock REST to verify shape)
    $enabledSettings = [PSCustomObject]@{
        enabled = $true; server_url = "http://localhost:9999"; api_key = "test-key"
        channel = "teams"; recipients = @("user@example.com")
        project_name = "test-proj"; project_description = "desc"; instance_id = ""
    }
    $templateCapture = $null
    function global:Invoke-RestMethod {
        param([string]$Method = 'Get', [string]$Uri, [string]$Body, $Headers, $ContentType, $TimeoutSec)
        if ($Uri -match '/api/templates$') {
            $global:templateCapture = $Body | ConvertFrom-Json
            return @{}
        }
        if ($Uri -match '/api/instances$') {
            return @{}
        }
        throw "Unexpected URI: $Uri"
    }
    $splitTemplateResult = try {
        Send-SplitProposalNotification -TaskContent $mockSplitTask -SplitProposal $mockSplitProposal -Settings $enabledSettings
    } finally {
        Remove-Item -Path 'function:global:Invoke-RestMethod' -ErrorAction SilentlyContinue
    }
    $templateCapture = $global:templateCapture
    Assert-True -Name "Send-SplitProposalNotification returns success with mock server" `
        -Condition ($splitTemplateResult.success -eq $true) `
        -Message "Expected success=true, got: $($splitTemplateResult | ConvertTo-Json -Depth 5)"

    if ($templateCapture) {
        Assert-True -Name "Split template title contains task name" `
            -Condition ($templateCapture.title -match "Refactor auth") `
            -Message "Expected title to contain task name, got: $($templateCapture.title)"

        Assert-True -Name "Split template has 2 options (Approve/Reject)" `
            -Condition ($templateCapture.options.Count -eq 2) `
            -Message "Expected 2 options, got $($templateCapture.options.Count)"

        $optionKeys = @($templateCapture.options | ForEach-Object { $_.key })
        Assert-True -Name "Split template options are 'approve' and 'reject'" `
            -Condition ($optionKeys -contains 'approve' -and $optionKeys -contains 'reject') `
            -Message "Expected approve/reject keys, got: $($optionKeys -join ', ')"

        Assert-True -Name "Split template context contains reason" `
            -Condition ($templateCapture.context -match "too large") `
            -Message "Expected context to contain reason"

        Assert-True -Name "Split template context contains sub-task names" `
            -Condition ($templateCapture.context -match "Extract middleware" -and $templateCapture.context -match "Add token rotation") `
            -Message "Expected context to list sub-tasks"

        Assert-True -Name "Split template has questionId (deterministic GUID)" `
            -Condition ($null -ne $templateCapture.questionId -and $templateCapture.questionId.Length -eq 36) `
            -Message "Expected 36-char GUID questionId, got: $($templateCapture.questionId)"

        Assert-True -Name "Split template disables free-text (Approve/Reject binary)" `
            -Condition ($templateCapture.responseSettings.allowFreeText -eq $false) `
            -Message "Expected allowFreeText=false for split proposal, got: $($templateCapture.responseSettings.allowFreeText)"
    }
} else {
    Write-TestResult -Name "NotificationClient module exists" -Status Fail -Message "Module not found at $notifModule"
}

# ═══════════════════════════════════════════════════════════════════
# SETTINGS LOADER MODULE TESTS (three-tier resolution)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Dotbot.Settings Module ---" -ForegroundColor Cyan

$settingsLoaderModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Settings/Dotbot.Settings.psd1"

if (Test-Path $settingsLoaderModule) {
    Import-Module $settingsLoaderModule -Force -DisableNameChecking

    # Fresh isolated .bot fixture so we control every layer explicitly.
    $loaderFixture = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-loader-$([guid]::NewGuid().ToString().Substring(0,8))"
    $loaderBotDir = Join-Path $loaderFixture ".bot"
    $loaderControlDir = Join-Path $loaderBotDir ".control"
    New-Item -ItemType Directory -Path $loaderControlDir -Force | Out-Null

    # Isolate every layer so tests never touch the real machine home or framework.
    $loaderPreviousDotbotHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
    $loaderPreviousXdg        = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
    $loaderPreviousAppData    = [Environment]::GetEnvironmentVariable('APPDATA')
    $loaderDotbotHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-loader-home-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $loaderUserHome   = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-loader-user-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    # Layer 1 source — framework defaults under <DOTBOT_HOME>/content/settings/.
    $loaderFrameworkSettingsDir = Join-Path $loaderDotbotHome 'content/settings'
    New-Item -ItemType Directory -Path $loaderFrameworkSettingsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $loaderUserHome -Force | Out-Null
    [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $loaderDotbotHome, 'Process')
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $loaderUserHome, 'Process')
    [Environment]::SetEnvironmentVariable('APPDATA', $loaderUserHome, 'Process')
    Invoke-DotbotUserSettingsMigration -Force | Out-Null
    $loaderUserSettings = Get-DotbotUserSettingsPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $loaderUserSettings) -Force | Out-Null

    try {
        # --- Defaults-only: values come straight from <DOTBOT_HOME>/content/settings/settings.default.json ---
        @'
{
  "provider": "claude",
  "mothership": {
    "enabled": false,
    "server_url": "https://default.example.com",
    "api_key": ""
  }
}
'@ | Set-Content (Join-Path $loaderFrameworkSettingsDir "settings.default.json")

        if (Test-Path $loaderUserSettings) { Remove-Item $loaderUserSettings -Force }

        $defaultsOnly = Get-MergedSettings -BotRoot $loaderBotDir
        Assert-Equal -Name "Dotbot.Settings: defaults-only returns server_url from settings.default.json" `
            -Expected "https://default.example.com" -Actual $defaultsOnly.mothership.server_url
        Assert-Equal -Name "Dotbot.Settings: defaults-only returns provider" `
            -Expected "claude" -Actual $defaultsOnly.provider

        # --- user-settings.json layered on top of defaults ---
        @'
{
  "mothership": {
    "server_url": "https://from-user.example.com",
    "api_key": "user-key"
  }
}
'@ | Set-Content $loaderUserSettings

        $withUser = Get-MergedSettings -BotRoot $loaderBotDir
        Assert-Equal -Name "Dotbot.Settings: user-settings.json overrides server_url" `
            -Expected "https://from-user.example.com" -Actual $withUser.mothership.server_url
        Assert-Equal -Name "Dotbot.Settings: user-settings.json supplies api_key" `
            -Expected "user-key" -Actual $withUser.mothership.api_key
        Assert-Equal -Name "Dotbot.Settings: untouched keys survive the merge" `
            -Expected "claude" -Actual $withUser.provider

        # --- .control/settings.json wins over user-settings.json ---
        @'
{
  "mothership": {
    "server_url": "https://from-control.example.com"
  }
}
'@ | Set-Content (Join-Path $loaderControlDir "settings.json")

        $withControl = Get-MergedSettings -BotRoot $loaderBotDir
        Assert-Equal -Name "Dotbot.Settings: .control wins over user-settings" `
            -Expected "https://from-control.example.com" -Actual $withControl.mothership.server_url
        Assert-Equal -Name "Dotbot.Settings: .control leaves api_key from user-settings intact" `
            -Expected "user-key" -Actual $withControl.mothership.api_key

        # --- Missing layers are silent no-ops ---
        Remove-Item $loaderUserSettings -Force
        Remove-Item (Join-Path $loaderControlDir "settings.json") -Force

        $missingLayers = Get-MergedSettings -BotRoot $loaderBotDir
        Assert-Equal -Name "Dotbot.Settings: falls back to defaults when upper layers absent" `
            -Expected "https://default.example.com" -Actual $missingLayers.mothership.server_url

        # --- Malformed JSON in a layer does not throw ---
        "{ not valid json !!!" | Set-Content $loaderUserSettings
        $malformedResult = Get-MergedSettings -BotRoot $loaderBotDir
        Assert-True -Name "Dotbot.Settings: malformed user-settings does not break resolution" `
            -Condition ($null -ne $malformedResult) `
            -Message "Get-MergedSettings returned null when user-settings.json was malformed"
        Assert-Equal -Name "Dotbot.Settings: malformed layer falls through to defaults" `
            -Expected "https://default.example.com" -Actual $malformedResult.mothership.server_url

        # --- Deep merge: partial section in a higher layer does not erase sibling keys ---
        @'
{
  "mothership": {
    "api_key": "only-api-key-from-user"
  }
}
'@ | Set-Content $loaderUserSettings

        $deepMerged = Get-MergedSettings -BotRoot $loaderBotDir
        Assert-Equal -Name "Dotbot.Settings: deep merge preserves sibling keys in a partial override" `
            -Expected "https://default.example.com" -Actual $deepMerged.mothership.server_url
        Assert-Equal -Name "Dotbot.Settings: deep merge applies the overridden sibling" `
            -Expected "only-api-key-from-user" -Actual $deepMerged.mothership.api_key
    } finally {
        if (Test-Path $loaderUserSettings) { Remove-Item $loaderUserSettings -Force }
        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $loaderPreviousDotbotHome, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $loaderPreviousXdg, 'Process')
        [Environment]::SetEnvironmentVariable('APPDATA', $loaderPreviousAppData, 'Process')
        Remove-Item $loaderDotbotHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $loaderUserHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $loaderFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-TestResult -Name "Dotbot.Settings module exists" -Status Fail -Message "Module not found at $settingsLoaderModule"
}

# ═══════════════════════════════════════════════════════════════════
# USER-SETTINGS LOCATION — Phase 3
# Get-DotbotUserSettingsPath must resolve under XDG_CONFIG_HOME / APPDATA
# (not under DOTBOT_HOME), and Get-MergedSettings must read from that path.
# Migration: legacy <DOTBOT_HOME>/user-settings.json moves to the new path
# only when the destination is absent; second invocation is a no-op.
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- User-settings location (Phase 3) ---" -ForegroundColor Cyan

if (Test-Path $settingsLoaderModule) {
    $coreModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Core/Dotbot.Core.psd1"
    Import-Module $coreModule -Force -DisableNameChecking -Global | Out-Null
    Import-Module $settingsLoaderModule -Force -DisableNameChecking -Global | Out-Null

    $userSettingsFixture = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-userpath-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $userSettingsBotDir = Join-Path $userSettingsFixture ".bot"
    $userSettingsUserHome = Join-Path $userSettingsFixture "user-home"
    $userSettingsDotbotHome = Join-Path $userSettingsFixture "dotbot-home"
    # Framework defaults under <DOTBOT_HOME>/content/settings/ (Phase 4 layer 1 source).
    $userSettingsFrameworkSettingsDir = Join-Path $userSettingsDotbotHome 'content/settings'
    New-Item -ItemType Directory -Path $userSettingsBotDir -Force | Out-Null
    New-Item -ItemType Directory -Path $userSettingsUserHome -Force | Out-Null
    New-Item -ItemType Directory -Path $userSettingsFrameworkSettingsDir -Force | Out-Null

    $prevDotbotHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
    $prevXdg        = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
    $prevAppData    = [Environment]::GetEnvironmentVariable('APPDATA')

    try {
        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $userSettingsDotbotHome, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $userSettingsUserHome, 'Process')
        [Environment]::SetEnvironmentVariable('APPDATA', $userSettingsUserHome, 'Process')

        # --- Path resolution: new path is rooted in XDG/APPDATA, not DOTBOT_HOME ---
        $resolvedPath = Get-DotbotUserSettingsPath
        $expectedDir  = Join-Path $userSettingsUserHome 'dotbot'
        Assert-True -Name "Get-DotbotUserSettingsPath ends with user-settings.json" `
            -Condition ($resolvedPath -like '*user-settings.json') `
            -Message "Expected path to end with user-settings.json, got: $resolvedPath"
        Assert-True -Name "Get-DotbotUserSettingsPath rooted under XDG_CONFIG_HOME/APPDATA" `
            -Condition ($resolvedPath -like (Join-Path $expectedDir '*')) `
            -Message "Expected path under $expectedDir, got: $resolvedPath"
        Assert-True -Name "Get-DotbotUserSettingsPath not under DOTBOT_HOME" `
            -Condition (-not ($resolvedPath -like (Join-Path $userSettingsDotbotHome '*'))) `
            -Message "User-settings path leaked into DOTBOT_HOME: $resolvedPath"

        # --- Round-trip: write to the new path, Get-MergedSettings reads it ---
        New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedPath) -Force | Out-Null
        @'
{
  "provider": "claude",
  "mothership": { "server_url": "https://default.example.com" }
}
'@ | Set-Content (Join-Path $userSettingsFrameworkSettingsDir "settings.default.json")
        @'
{
  "mothership": { "api_key": "round-trip-key", "server_url": "https://round-trip.example.com" }
}
'@ | Set-Content $resolvedPath

        Invoke-DotbotUserSettingsMigration -Force | Out-Null
        $merged = Get-MergedSettings -BotRoot $userSettingsBotDir
        Assert-Equal -Name "round-trip: new-path user-settings.json supplies api_key" `
            -Expected "round-trip-key" -Actual $merged.mothership.api_key
        Assert-Equal -Name "round-trip: new-path user-settings.json overrides server_url" `
            -Expected "https://round-trip.example.com" -Actual $merged.mothership.server_url

        # --- Migration: legacy <DOTBOT_HOME>/user-settings.json moves to new path ---
        Remove-Item $resolvedPath -Force
        $legacyPath = Join-Path $userSettingsDotbotHome 'user-settings.json'
        @'
{
  "mothership": { "api_key": "from-legacy-location" }
}
'@ | Set-Content $legacyPath

        Invoke-DotbotUserSettingsMigration -Force | Out-Null
        Assert-True -Name "migration: legacy file moved to new path" `
            -Condition (Test-Path $resolvedPath) `
            -Message "Expected user-settings.json at $resolvedPath after migration"
        Assert-True -Name "migration: legacy file removed after move" `
            -Condition (-not (Test-Path $legacyPath)) `
            -Message "Legacy user-settings.json still present at $legacyPath after migration"
        $migratedContent = Get-Content $resolvedPath -Raw | ConvertFrom-Json
        Assert-Equal -Name "migration: content preserved" `
            -Expected "from-legacy-location" -Actual $migratedContent.mothership.api_key

        # --- Migration safety: never overwrites an existing target ---
        @'
{
  "mothership": { "api_key": "existing-target-wins" }
}
'@ | Set-Content $legacyPath
        @'
{
  "mothership": { "api_key": "preserved-target" }
}
'@ | Set-Content $resolvedPath

        Invoke-DotbotUserSettingsMigration -Force | Out-Null
        $afterCollision = Get-Content $resolvedPath -Raw | ConvertFrom-Json
        Assert-Equal -Name "migration: existing target is preserved on collision" `
            -Expected "preserved-target" -Actual $afterCollision.mothership.api_key
        Assert-True -Name "migration: legacy file untouched on collision" `
            -Condition (Test-Path $legacyPath) `
            -Message "Legacy file should remain when target already exists, but was removed"

        # --- Idempotency: first call moves the file, second call is a flag-guarded no-op ---
        Remove-Item $resolvedPath -Force -ErrorAction SilentlyContinue
        Remove-Item $legacyPath -Force -ErrorAction SilentlyContinue
        @'
{
  "mothership": { "api_key": "first-run" }
}
'@ | Set-Content $legacyPath

        Invoke-DotbotUserSettingsMigration -Force | Out-Null  # Reset flag, then run once
        Assert-True -Name "idempotency: first invocation moves the file" `
            -Condition ((Test-Path $resolvedPath) -and -not (Test-Path $legacyPath)) `
            -Message "First migration should have moved legacy -> new"
        $firstRunMtime = (Get-Item $resolvedPath).LastWriteTimeUtc

        # Simulate a leftover legacy file appearing after the first run completes.
        # Without -Force the second call must be a no-op because the in-process
        # flag is set, leaving both the new file and the leftover untouched.
        @'
{
  "mothership": { "api_key": "should-not-be-migrated" }
}
'@ | Set-Content $legacyPath
        $leftoverHashBefore = (Get-FileHash $legacyPath -Algorithm SHA256).Hash

        Invoke-DotbotUserSettingsMigration | Out-Null  # No -Force: flag should short-circuit
        Assert-True -Name "idempotency: second invocation does not touch new path" `
            -Condition ((Get-Item $resolvedPath).LastWriteTimeUtc -eq $firstRunMtime) `
            -Message "Second migration mutated the new path despite the flag guard"
        Assert-True -Name "idempotency: second invocation leaves leftover legacy file alone" `
            -Condition ((Test-Path $legacyPath) -and ((Get-FileHash $legacyPath -Algorithm SHA256).Hash -eq $leftoverHashBefore)) `
            -Message "Second migration moved or mutated the leftover legacy file"
        $stillFirstRun = Get-Content $resolvedPath -Raw | ConvertFrom-Json
        Assert-Equal -Name "idempotency: new path content unchanged by second call" `
            -Expected "first-run" -Actual $stillFirstRun.mothership.api_key
    } finally {
        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $prevDotbotHome, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $prevXdg, 'Process')
        [Environment]::SetEnvironmentVariable('APPDATA', $prevAppData, 'Process')
        Remove-Item $userSettingsFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════
# SETTINGS API WRITERS — issue #309 regression
# UI Set-* writers must NOT touch settings.default.json (framework-protected).
# Writes go to .control/settings.json (gitignored overrides).
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- SettingsAPI Writers (issue #309) ---" -ForegroundColor Cyan

$settingsApiModule = Join-Path $botDir "src/ui/modules/SettingsAPI.psm1"

if (Test-Path $settingsApiModule) {
    # Need Dotbot.Logging for Write-BotLog/Write-Status used inside SettingsAPI.
    $logModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Logging/Dotbot.Logging.psd1"
    if (Test-Path $logModule) { Import-Module $logModule -Force -DisableNameChecking -Global }
    $themeModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1"
    if (Test-Path $themeModule) { Import-Module $themeModule -Force -DisableNameChecking -Global }
    Import-Module $settingsApiModule -Force -DisableNameChecking

    $apiFixture = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-api-$([guid]::NewGuid().ToString().Substring(0,8))"
    $apiBotDir = Join-Path $apiFixture ".bot"
    $apiSettingsDir = Join-Path $apiBotDir "settings"
    $apiControlDir = Join-Path $apiBotDir ".control"
    $apiProvidersDir = Join-Path $apiSettingsDir "providers"
    $apiStaticRoot = Join-Path $apiBotDir "ui/static"
    New-Item -ItemType Directory -Path $apiSettingsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $apiControlDir -Force | Out-Null
    New-Item -ItemType Directory -Path $apiProvidersDir -Force | Out-Null
    New-Item -ItemType Directory -Path $apiStaticRoot -Force | Out-Null

    # Isolate the user-settings layer so UI writer tests never touch the real machine home.
    $apiPreviousDotbotHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
    $apiPreviousXdg        = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
    $apiPreviousAppData    = [Environment]::GetEnvironmentVariable('APPDATA')
    $apiDotbotHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-api-home-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $apiUserHome   = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-api-user-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $apiDotbotHome -Force | Out-Null
    New-Item -ItemType Directory -Path $apiUserHome -Force | Out-Null
    [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $apiDotbotHome, 'Process')
    [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $apiUserHome, 'Process')
    [Environment]::SetEnvironmentVariable('APPDATA', $apiUserHome, 'Process')
    Invoke-DotbotUserSettingsMigration -Force | Out-Null
    $apiUserSettings = Get-DotbotUserSettingsPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $apiUserSettings) -Force | Out-Null

    try {
        # Seed shipped defaults — values that should NEVER be mutated by the UI writers.
        $defaults = @{
            provider = "claude"
            analysis = @{ auto_approve_splits = $false; split_threshold_effort = "XL"; question_timeout_hours = $null; mode = "on-demand" }
            costs    = @{ hourly_rate = 50; ai_speedup_factor = 10; currency = "USD" }
            editor   = @{ name = "off"; custom_command = "" }
            mothership = @{ enabled = $false; server_url = ""; api_key = ""; channel = "teams"; recipients = @(); project_name = ""; project_description = ""; poll_interval_seconds = 30; sync_tasks = $true; sync_questions = $true }
        }
        $defaultsFile = Join-Path $apiSettingsDir "settings.default.json"
        $defaults | ConvertTo-Json -Depth 10 | Set-Content $defaultsFile -Force
        $defaultsHashBefore = (Get-FileHash $defaultsFile -Algorithm SHA256).Hash

        # Stub claude provider so Set-ActiveProvider validation passes.
        @{ name = "claude"; display_name = "Claude"; executable = "claude"; models = @{} } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $apiProvidersDir "claude.json") -Force

        if (Test-Path $apiUserSettings) { Remove-Item $apiUserSettings -Force }

        Initialize-SettingsAPI -ControlDir $apiControlDir -BotRoot $apiBotDir -StaticRoot $apiStaticRoot

        $overridesFile = Join-Path $apiControlDir "settings.json"

        function Get-OverridesJson { Get-Content $overridesFile -Raw | ConvertFrom-Json }

        # --- Set-AnalysisConfig ---
        $r = Set-AnalysisConfig -Body ([PSCustomObject]@{ auto_approve_splits = $true; mode = "auto" })
        Assert-True -Name "#309: Set-AnalysisConfig success" -Condition ($r.success -eq $true)
        Assert-Equal -Name "#309: AnalysisConfig writes to .control overrides" -Expected $true -Actual ((Get-OverridesJson).analysis.auto_approve_splits)
        Assert-Equal -Name "#309: AnalysisConfig mode persisted" -Expected "auto" -Actual ((Get-OverridesJson).analysis.mode)
        Assert-Equal -Name "#309: AnalysisConfig merged read returns override" -Expected $true -Actual (Get-AnalysisConfig).auto_approve_splits

        # --- Set-CostConfig ---
        $r = Set-CostConfig -Body ([PSCustomObject]@{ hourly_rate = 99; currency = "EUR" })
        Assert-True -Name "#309: Set-CostConfig success" -Condition ($r.success -eq $true)
        Assert-Equal -Name "#309: CostConfig writes to .control overrides" -Expected 99 -Actual ([int](Get-OverridesJson).costs.hourly_rate)
        Assert-Equal -Name "#309: CostConfig currency persisted" -Expected "EUR" -Actual (Get-OverridesJson).costs.currency

        # --- Set-EditorConfig ---
        $r = Set-EditorConfig -Body ([PSCustomObject]@{ name = "custom"; custom_command = "vi {path}" })
        Assert-True -Name "#309: Set-EditorConfig success" -Condition ($r.success -eq $true)
        Assert-Equal -Name "#309: EditorConfig writes to .control overrides" -Expected "custom" -Actual (Get-OverridesJson).editor.name
        Assert-Equal -Name "#309: EditorConfig custom_command persisted" -Expected "vi {path}" -Actual (Get-OverridesJson).editor.custom_command

        # --- Set-ActiveProvider (top-level scalar) ---
        $r = Set-ActiveProvider -Body ([PSCustomObject]@{ provider = "claude" })
        Assert-Equal -Name "#309: ActiveProvider writes to .control overrides" -Expected "claude" -Actual (Get-OverridesJson).provider

        # --- Set-MothershipConfig (mix of non-secret + secret) ---
        $r = Set-MothershipConfig -Body ([PSCustomObject]@{
            enabled = $true
            server_url = "http://localhost:5048"
            channel = "slack"
            recipients = @("U123","U456")
            project_name = "demo"
            api_key = "secret-key-xyz"
        })
        Assert-True -Name "#309: Set-MothershipConfig success" -Condition ($r.success -eq $true)
        $ov = Get-OverridesJson
        Assert-Equal -Name "#309: Mothership.enabled in .control" -Expected $true -Actual $ov.mothership.enabled
        Assert-Equal -Name "#309: Mothership.channel=slack in .control" -Expected "slack" -Actual $ov.mothership.channel
        Assert-Equal -Name "#309: Mothership.api_key co-located in .control" -Expected "secret-key-xyz" -Actual $ov.mothership.api_key
        Assert-Equal -Name "#309: Mothership.server_url in .control" -Expected "http://localhost:5048" -Actual $ov.mothership.server_url
        Assert-Equal -Name "#309: Mothership.recipients length" -Expected 2 -Actual @($ov.mothership.recipients).Count

        # Regression: recipients must REPLACE, not concat+dedup (issue #309 follow-up).
        $r = Set-MothershipConfig -Body ([PSCustomObject]@{ recipients = @("U123") })
        $ov = Get-OverridesJson
        Assert-Equal -Name "#309: Mothership.recipients shrinks on replace" -Expected 1 -Actual @($ov.mothership.recipients).Count
        Assert-Equal -Name "#309: Mothership.recipients keeps remaining" -Expected "U123" -Actual @($ov.mothership.recipients)[0]

        # Regression: empty recipients clears the list.
        $r = Set-MothershipConfig -Body ([PSCustomObject]@{ recipients = @() })
        $ov = Get-OverridesJson
        Assert-Equal -Name "#309: Mothership.recipients can clear to empty" -Expected 0 -Actual @($ov.mothership.recipients).Count

        # Restore recipients for downstream merged-read assertions.
        $null = Set-MothershipConfig -Body ([PSCustomObject]@{ recipients = @("U123","U456") })

        # --- The critical assertion: settings.default.json bytes UNCHANGED ---
        $defaultsHashAfter = (Get-FileHash $defaultsFile -Algorithm SHA256).Hash
        Assert-Equal -Name "#309: settings.default.json untouched by ALL UI writers" -Expected $defaultsHashBefore -Actual $defaultsHashAfter

        # --- Merged read returns override values, defaults survive elsewhere ---
        $merged = Get-MothershipConfig
        Assert-Equal -Name "#309: Get-MothershipConfig returns merged enabled=true" -Expected $true -Actual $merged.enabled
        Assert-Equal -Name "#309: Get-MothershipConfig returns merged channel=slack" -Expected "slack" -Actual $merged.channel
        Assert-True -Name "#309: Get-MothershipConfig api_key_set" -Condition ($merged.api_key_set -eq $true)
    } finally {
        if (Test-Path $apiUserSettings) { Remove-Item $apiUserSettings -Force }
        [Environment]::SetEnvironmentVariable('DOTBOT_HOME', $apiPreviousDotbotHome, 'Process')
        [Environment]::SetEnvironmentVariable('XDG_CONFIG_HOME', $apiPreviousXdg, 'Process')
        [Environment]::SetEnvironmentVariable('APPDATA', $apiPreviousAppData, 'Process')
        Remove-Item $apiDotbotHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $apiUserHome -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $apiFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-TestResult -Name "SettingsAPI module exists" -Status Fail -Message "Module not found at $settingsApiModule"
}

# ═══════════════════════════════════════════════════════════════════
# MERGE FAILURE ESCALATION MODULE TESTS (issue #224)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Dotbot.Task Module ---" -ForegroundColor Cyan

$mergeEscModule = Join-Path $botDir "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1"

if (Test-Path $mergeEscModule) {
    Import-Module $mergeEscModule -Force

    # Ensure the helper is exported
    $cmd = Get-Command Move-TaskToMergeFailureNeedsInput -ErrorAction SilentlyContinue
    Assert-True -Name "Move-TaskToMergeFailureNeedsInput is exported" `
        -Condition ($null -ne $cmd) `
        -Message "Expected exported function"

    # Build an isolated workspace with a fake done/ task
    $mceWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-mce-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    $mceDone = Join-Path $mceWorkspace "done"
    $mceNeedsInput = Join-Path $mceWorkspace "needs-input"
    New-Item -ItemType Directory -Force -Path $mceDone | Out-Null

    $fakeTaskId = "abc12345"
    # Seed an open execution session on the task so the session-close path is
    # actually exercised. The runtime parent nulls $env:CLAUDE_SESSION_ID before
    # the squash-merge step, so the helper must source the session id from
    # $taskContent.execution_sessions, NOT from the env var.
    $fakeTaskJson = @{
        id                 = $fakeTaskId
        name               = "Fake merge-conflict task"
        status             = "done"
        created_at         = "2026-04-11T00:00:00.0000000Z"
        updated_at         = "2026-04-11T00:00:00.0000000Z"
        execution_sessions = @(
            @{ id = "exec-session-1"; started_at = "2026-04-11T00:00:01Z"; ended_at = $null }
        )
    } | ConvertTo-Json -Depth 10
    $fakeTaskFile = Join-Path $mceDone "$fakeTaskId.json"
    Set-Content -Path $fakeTaskFile -Value $fakeTaskJson -Encoding UTF8

    # NB: PSCustomObject branch of conflict_files extraction is defensive only —
    # Complete-TaskWorktree returns a [hashtable] in production (WorktreeManager.psm1
    # 652/707/747/771/816/909/917). The hashtable regression test below is the one
    # that pins production behaviour.
    $fakeMergeResult = [PSCustomObject]@{
        success        = $false
        message        = "conflict in 2 files"
        conflict_files = @("src/foo.cs", "src/bar.cs")
    }
    $fakeWorktreePath = "C:\worktrees\dotbot\task-$fakeTaskId-fake"

    # Point DotbotProjectRoot at the isolated temp workspace that has no `.bot/` —
    # `Test-Path` on NotificationClient.psm1 fails, so the notification branch short-circuits
    # to notified=$false deterministically, regardless of the developer's $testProject config.
    # NB: we pass `-BotRoot $mceBotRoot` explicitly to mirror how the runtime wires the helper
    # (Invoke-WorkflowProcess / Invoke-ExecutionProcess pass the `.bot` directory, NOT the
    # project root). This pins the regression: if the helper ever treats `$BotRoot` as a
    # project root again and appends `.bot`, these tests fail instead of passing vacuously.
    $mceBotRoot = Join-Path $mceWorkspace ".bot"
    $savedDotbotRoot = $global:DotbotProjectRoot
    $savedSessionEnv = $env:CLAUDE_SESSION_ID
    $global:DotbotProjectRoot = $mceWorkspace
    $env:CLAUDE_SESSION_ID = $null

    try {
        $result = Move-TaskToMergeFailureNeedsInput `
            -TaskId $fakeTaskId `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot

        Assert-True -Name "Move-TaskToMergeFailureNeedsInput returns success" `
            -Condition ($result.success -eq $true) `
            -Message "Expected success=true"

        Assert-True -Name "Task file moved out of done/" `
            -Condition (-not (Test-Path $fakeTaskFile)) `
            -Message "Original file still exists in done/"

        $newPath = Join-Path $mceNeedsInput "$fakeTaskId.json"
        Assert-True -Name "Task file created in needs-input/" `
            -Condition (Test-Path $newPath) `
            -Message "Expected file at $newPath"

        if (Test-Path $newPath) {
            $moved = Get-Content $newPath -Raw | ConvertFrom-Json

            Assert-True -Name "Status transitioned to needs-input" `
                -Condition ($moved.status -eq "needs-input") `
                -Message "Expected status=needs-input, got $($moved.status)"

            Assert-True -Name "pending_question.id is merge-conflict" `
                -Condition ($moved.pending_question.id -eq "merge-conflict") `
                -Message "Expected id=merge-conflict"

            Assert-True -Name "pending_question has 3 options (A/B/C)" `
                -Condition (@($moved.pending_question.options).Count -eq 3) `
                -Message "Expected 3 options, got $(@($moved.pending_question.options).Count)"

            $keys = @($moved.pending_question.options | ForEach-Object { $_.key }) -join ","
            Assert-True -Name "pending_question option keys are A,B,C" `
                -Condition ($keys -eq "A,B,C") `
                -Message "Expected A,B,C, got $keys"

            Assert-True -Name "pending_question recommendation is A" `
                -Condition ($moved.pending_question.recommendation -eq "A") `
                -Message "Expected recommendation=A"

            Assert-True -Name "pending_question context includes conflict files" `
                -Condition ($moved.pending_question.context -match "src/foo\.cs" -and $moved.pending_question.context -match "src/bar\.cs") `
                -Message "Expected conflict file names in context"

            Assert-True -Name "pending_question context includes worktree path" `
                -Condition ($moved.pending_question.context -match [regex]::Escape($fakeWorktreePath)) `
                -Message "Expected worktree path in context"
        }

        # Dotbot.Notification is always loaded by Dotbot.Task, so the helper
        # always reaches Get-NotificationSettings. With no settings file under
        # $mceBotRoot the merged settings default to enabled=$false, so the
        # helper short-circuits with notified=$false / silent=$true and the
        # reason names the explicit opt-out instead of a missing module.
        Assert-True -Name "Escalation reports notified=false when notifications disabled" `
            -Condition ($result.notified -eq $false) `
            -Message "Expected notified=false when project hasn't opted in"

        Assert-True -Name "Escalation reason is 'Notifications disabled'" `
            -Condition ($result.notification_reason -eq "Notifications disabled") `
            -Message "Expected reason='Notifications disabled', got '$($result.notification_reason)'"

        # notification_silent must be $true for a project that hasn't opted in,
        # so the wrapper's call sites stay quiet on every escalation.
        Assert-True -Name "Escalation reports notification_silent=true when disabled" `
            -Condition ($result.notification_silent -eq $true) `
            -Message "Expected notification_silent=true (project never opted in)"

        # Session-close: when SessionTracking.psm1 is unavailable under the temp
        # workspace, the helper must NOT throw and must still complete the file
        # move. The execution_sessions array must therefore survive untouched
        # (still exists, still has the open entry) — the close-with-module branch
        # is exercised explicitly in the notified=$true block below by stubbing
        # SessionTracking alongside NotificationClient.
        if (Test-Path $newPath) {
            $movedNoSession = Get-Content $newPath -Raw | ConvertFrom-Json
            Assert-True -Name "Session-close: helper survives missing SessionTracking module" `
                -Condition ($movedNoSession.execution_sessions -and @($movedNoSession.execution_sessions).Count -eq 1) `
                -Message "Expected execution_sessions to survive helper run"
        }

        # Missing-task case: calling again with a task id that is no longer in done/
        $missingResult = Move-TaskToMergeFailureNeedsInput `
            -TaskId "does-not-exist" `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot
        Assert-True -Name "Missing task returns success=false" `
            -Condition ($missingResult.success -eq $false) `
            -Message "Expected success=false when task file not found in done/"

        Assert-True -Name "Missing task: notification_reason names all three search dirs" `
            -Condition ($missingResult.notification_reason -match 'done/' -and `
                        $missingResult.notification_reason -match 'in-progress/' -and `
                        $missingResult.notification_reason -match 'needs-input/') `
            -Message "Expected notification_reason to mention done/, in-progress/, and needs-input/, got: $($missingResult.notification_reason)"

        # --- Widened lookup: task found in in-progress/ ---
        # The escalation helper historically only searched done/. A task that is
        # still in in-progress/ when a merge-conflict is escalated (e.g. an
        # upstream caller mis-classifies state) was reported as "not found in
        # done/" and the runner emitted a misleading log line. The helper now
        # searches done/, in-progress/, and needs-input/ in order.
        $mceInProgress = Join-Path $mceWorkspace "in-progress"
        New-Item -ItemType Directory -Force -Path $mceInProgress | Out-Null

        $fakeTaskIdIp = "inprog01"
        $fakeTaskJsonIp = @{
            id         = $fakeTaskIdIp
            name       = "Fake in-progress task"
            status     = "in-progress"
            created_at = "2026-04-29T00:00:00.0000000Z"
            updated_at = "2026-04-29T00:00:00.0000000Z"
        } | ConvertTo-Json -Depth 10
        $fakeTaskFileIp = Join-Path $mceInProgress "$fakeTaskIdIp.json"
        Set-Content -Path $fakeTaskFileIp -Value $fakeTaskJsonIp -Encoding UTF8

        $resultIp = Move-TaskToMergeFailureNeedsInput `
            -TaskId $fakeTaskIdIp `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot

        Assert-True -Name "in-progress source: escalation succeeds" `
            -Condition ($resultIp.success -eq $true) `
            -Message "Expected success=true when task is in in-progress/"
        Assert-Equal -Name "in-progress source: source_status='in-progress'" `
            -Expected 'in-progress' -Actual $resultIp.source_status
        Assert-PathNotExists -Name "in-progress source: original file deleted" `
            -Path $fakeTaskFileIp
        Assert-PathExists -Name "in-progress source: task file landed in needs-input/" `
            -Path (Join-Path $mceNeedsInput "$fakeTaskIdIp.json")

        # --- Widened lookup: task already in needs-input/ (idempotent) ---
        $fakeTaskIdNi = "needsin01"
        $fakeTaskJsonNi = @{
            id         = $fakeTaskIdNi
            name       = "Fake already-paused task"
            status     = "needs-input"
            created_at = "2026-04-29T00:00:00.0000000Z"
            updated_at = "2026-04-29T00:00:00.0000000Z"
        } | ConvertTo-Json -Depth 10
        $fakeTaskFileNi = Join-Path $mceNeedsInput "$fakeTaskIdNi.json"
        Set-Content -Path $fakeTaskFileNi -Value $fakeTaskJsonNi -Encoding UTF8

        $resultNi = Move-TaskToMergeFailureNeedsInput `
            -TaskId $fakeTaskIdNi `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot

        Assert-True -Name "needs-input source: escalation succeeds idempotently" `
            -Condition ($resultNi.success -eq $true) `
            -Message "Expected success=true when task is already in needs-input/"
        Assert-Equal -Name "needs-input source: source_status='needs-input'" `
            -Expected 'needs-input' -Actual $resultNi.source_status
        Assert-PathExists -Name "needs-input source: task file stayed in needs-input/" `
            -Path $fakeTaskFileNi
        $reloadedNi = Get-Content $fakeTaskFileNi -Raw | ConvertFrom-Json
        Assert-True -Name "needs-input source: pending_question populated in place" `
            -Condition ($reloadedNi.pending_question -and $reloadedNi.pending_question.id -eq 'merge-conflict') `
            -Message "Expected pending_question.id='merge-conflict' written in place"

        # --- Regression: hashtable shape (matches Complete-TaskWorktree's real return) ---
        # Previously the helper probed $MergeResult.PSObject.Properties['conflict_files'],
        # which is $null for [hashtable], so conflict_files were silently dropped from the
        # pending_question context and from the Teams card. (issue #224 review defect #2)
        $fakeTaskId2 = "hash1234"
        $fakeTaskJson2 = @{
            id         = $fakeTaskId2
            name       = "Fake hashtable merge-conflict task"
            status     = "done"
            created_at = "2026-04-11T00:00:00.0000000Z"
            updated_at = "2026-04-11T00:00:00.0000000Z"
        } | ConvertTo-Json -Depth 10
        $fakeTaskFile2 = Join-Path $mceDone "$fakeTaskId2.json"
        Set-Content -Path $fakeTaskFile2 -Value $fakeTaskJson2 -Encoding UTF8

        $fakeMergeResultHashtable = @{
            success        = $false
            message        = "conflict in 2 files"
            conflict_files = @("src/hash-foo.cs", "src/hash-bar.cs")
        }
        $fakeWorktreePath2 = "C:\worktrees\dotbot\task-$fakeTaskId2-fake"

        $resultHash = Move-TaskToMergeFailureNeedsInput `
            -TaskId $fakeTaskId2 `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResultHashtable `
            -WorktreePath $fakeWorktreePath2 `
            -BotRoot $mceBotRoot

        Assert-True -Name "Hashtable MergeResult: escalation returns success" `
            -Condition ($resultHash.success -eq $true) `
            -Message "Expected success=true for hashtable shape"

        $newPath2 = Join-Path $mceNeedsInput "$fakeTaskId2.json"
        if (Test-Path $newPath2) {
            $movedHash = Get-Content $newPath2 -Raw | ConvertFrom-Json
            Assert-True -Name "Hashtable MergeResult: context includes both conflict files" `
                -Condition ($movedHash.pending_question.context -match "src/hash-foo\.cs" -and $movedHash.pending_question.context -match "src/hash-bar\.cs") `
                -Message "Expected hashtable conflict_files to appear in pending_question.context (regression for issue #224 review defect #2)"
        } else {
            Write-TestResult -Name "Hashtable MergeResult: task file created in needs-input/" -Status Fail -Message "Expected file at $newPath2"
        }

        # --- notified=$true path: override the globally-loaded notification
        # surface with deterministic stubs. Dotbot.Task imports Dotbot.Notification
        # via Import-Module -Global, so the runtime functions live in the global
        # session-state function table. Redefining them in `function global:` scope
        # overwrites those entries for the duration of this block; the finally
        # block re-imports Dotbot.Notification with -Force to restore the real
        # ones. (We leave Dotbot.SessionTracking's Close-SessionOnTask intact —
        # its real implementation matches the previous stub's behaviour and
        # already stamps ended_at on the matching session.)
        function global:Get-NotificationSettings {
            param([string]$BotRoot)
            return [pscustomobject]@{ enabled = $true; instance_id = 'i-test' }
        }
        function global:Send-TaskNotification {
            param($TaskContent, $PendingQuestion, $Settings)
            return @{
                success     = $true
                question_id = 'q-test'
                instance_id = 'i-test'
                channel     = 'teams'
                project_id  = 'p-test'
            }
        }

        # Seed the task with an open execution session so Close-SessionOnTask has
        # a target. Note: NO $env:CLAUDE_SESSION_ID — the helper must source the
        # session id from execution_sessions only.
        $fakeTaskId3 = "notif001"
        $fakeTaskJson3 = @{
            id                 = $fakeTaskId3
            name               = "Fake notify merge-conflict task"
            status             = "done"
            created_at         = "2026-04-11T00:00:00Z"
            updated_at         = "2026-04-11T00:00:00Z"
            execution_sessions = @(
                @{ id = "exec-notif-001"; started_at = "2026-04-11T00:00:01Z"; ended_at = $null }
            )
        } | ConvertTo-Json -Depth 10
        $fakeTaskFile3 = Join-Path $mceDone "$fakeTaskId3.json"
        Set-Content -Path $fakeTaskFile3 -Value $fakeTaskJson3 -Encoding UTF8

        # Env var already nulled and captured by the outer block — do not re-capture
        # here or the finally would wipe the developer's real shell var.

        $resultNotif = Move-TaskToMergeFailureNeedsInput `
            -TaskId $fakeTaskId3 `
            -TasksBaseDir $mceWorkspace `
            -MergeResult $fakeMergeResult `
            -WorktreePath $fakeWorktreePath `
            -BotRoot $mceBotRoot

        Assert-True -Name "Notified path: escalation returns success" `
            -Condition ($resultNotif.success -eq $true) `
            -Message "Expected success=true"

        Assert-True -Name "Notified path: notified=true" `
            -Condition ($resultNotif.notified -eq $true) `
            -Message "Expected notified=true when NotificationClient stub returns success"

        Assert-True -Name "Notified path: reason is 'Notification dispatched'" `
            -Condition ($resultNotif.notification_reason -eq "Notification dispatched") `
            -Message "Expected notification_reason='Notification dispatched', got '$($resultNotif.notification_reason)'"

        $newPath3 = Join-Path $mceNeedsInput "$fakeTaskId3.json"
        if (Test-Path $newPath3) {
            $movedNotif = Get-Content $newPath3 -Raw | ConvertFrom-Json

            Assert-True -Name "Notified path: notification.question_id persisted" `
                -Condition ($movedNotif.notification.question_id -eq "q-test") `
                -Message "Expected notification.question_id='q-test'"

            Assert-True -Name "Notified path: notification.channel persisted" `
                -Condition ($movedNotif.notification.channel -eq "teams") `
                -Message "Expected notification.channel='teams'"

            Assert-True -Name "Notified path: notification.instance_id persisted" `
                -Condition ($movedNotif.notification.instance_id -eq "i-test") `
                -Message "Expected notification.instance_id='i-test'"

            # Timestamp format guard for review defect #2 — second-precision, trailing Z.
            # NB: ConvertFrom-Json auto-coerces ISO 8601 strings to [datetime], which then
            # round-trips through local culture and breaks the regex. Pin the *on-disk*
            # serialised form by grepping the raw JSON text instead.
            $rawNotifJson = Get-Content $newPath3 -Raw
            $tsPattern = '"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
            Assert-True -Name "Notified path: notification.sent_at is second-precision (on disk)" `
                -Condition ($rawNotifJson -match "(?s)`"sent_at`"\s*:\s*$tsPattern") `
                -Message "Expected sent_at to be serialised as second-precision UTC string"

            Assert-True -Name "Notified path: pending_question.asked_at is second-precision (on disk)" `
                -Condition ($rawNotifJson -match "(?s)`"asked_at`"\s*:\s*$tsPattern") `
                -Message "Expected asked_at to be serialised as second-precision UTC string"

            # Session-close: helper must have stamped ended_at on the open
            # execution_sessions entry by sourcing its id from the task content
            # (NOT from $env:CLAUDE_SESSION_ID, which is empty in this test).
            $execSessions = @($movedNotif.execution_sessions)
            Assert-True -Name "Session-close: execution_sessions still has 1 entry" `
                -Condition ($execSessions.Count -eq 1) `
                -Message "Expected single execution session entry"

            if ($execSessions.Count -eq 1) {
                Assert-True -Name "Session-close: ended_at populated on previously-open session" `
                    -Condition ($null -ne $execSessions[0].ended_at -and "$($execSessions[0].ended_at)") `
                    -Message "Expected ended_at to be set after escalation; got '$($execSessions[0].ended_at)'"

                Assert-True -Name "Session-close: id matches the seeded open session" `
                    -Condition ($execSessions[0].id -eq "exec-notif-001") `
                    -Message "Expected id=exec-notif-001, got '$($execSessions[0].id)'"
            }
        } else {
            Write-TestResult -Name "Notified path: task file created in needs-input/" -Status Fail -Message "Expected file at $newPath3"
        }

    } finally {
        # Drop the global function overrides and re-import the real
        # Dotbot.Notification module so later tests see the real functions.
        # Must run in finally: $ErrorActionPreference=Stop means any assertion
        # failure above would otherwise skip cleanup and leave the stubs in
        # place for subsequent tests.
        Remove-Item function:global:Get-NotificationSettings -ErrorAction SilentlyContinue
        Remove-Item function:global:Send-TaskNotification -ErrorAction SilentlyContinue
        $realNotifModule = Join-Path $botDir 'src/runtime/Modules/Dotbot.Notification/Dotbot.Notification.psd1'
        if (Test-Path $realNotifModule) {
            Import-Module $realNotifModule -DisableNameChecking -Global -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $savedSessionEnv) { $env:CLAUDE_SESSION_ID = $savedSessionEnv } else { Remove-Item Env:CLAUDE_SESSION_ID -ErrorAction SilentlyContinue }
        $global:DotbotProjectRoot = $savedDotbotRoot
        Remove-Item -Path $mceWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # FAILURE-KIND DISPATCH (kind-aware pending_question)
    # ═══════════════════════════════════════════════════════════════════
    # Regression for the "Conflict details: (none reported)" bug: when
    # Complete-TaskWorktree fails for non-conflict reasons (commit hook
    # rejection, missing branch, exception during merge, generic git error),
    # the escalation must surface the real failure_kind/message/detail in
    # pending_question.context instead of pretending it was a merge conflict.

    Write-Host ""
    Write-Host "  FAILURE-KIND DISPATCH" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # New-MergeFailurePendingQuestion is the single source of truth for the
    # kind → template mapping. Test it directly: cheap, deterministic, no FS I/O.
    $kindCases = @(
        @{ Kind = 'rebase_conflict';      ExpectedId = 'merge-conflict';   ExpectedOptionCount = 3 }
        @{ Kind = 'branch_missing';       ExpectedId = 'branch-missing';   ExpectedOptionCount = 2 }
        @{ Kind = 'merge_command_failed'; ExpectedId = 'merge-failed';     ExpectedOptionCount = 3 }
        @{ Kind = 'commit_failed';        ExpectedId = 'commit-failed';    ExpectedOptionCount = 2 }
        @{ Kind = 'exception';            ExpectedId = 'merge-error';      ExpectedOptionCount = 2 }
        @{ Kind = 'unknown';              ExpectedId = 'merge-error';      ExpectedOptionCount = 2 }
    )
    $fakeWt = "C:\worktrees\dotbot\task-kind-test"
    foreach ($case in $kindCases) {
        $kind = $case.Kind
        $pq = New-MergeFailurePendingQuestion `
            -FailureKind $kind `
            -Message "message-for-$kind" `
            -FailureDetail "detail-for-$kind" `
            -ConflictFiles @("src/foo.cs","src/bar.cs") `
            -WorktreePath $fakeWt

        Assert-Equal -Name "Kind dispatch ($kind): pending_question.id" `
            -Expected $case.ExpectedId -Actual $pq.id

        Assert-True -Name "Kind dispatch ($kind): has $($case.ExpectedOptionCount) options" `
            -Condition (@($pq.options).Count -eq $case.ExpectedOptionCount) `
            -Message "Expected $($case.ExpectedOptionCount) options, got $(@($pq.options).Count)"

        Assert-Equal -Name "Kind dispatch ($kind): recommendation is A" `
            -Expected "A" -Actual $pq.recommendation

        Assert-True -Name "Kind dispatch ($kind): context contains worktree path" `
            -Condition ($pq.context -match [regex]::Escape($fakeWt)) `
            -Message "Expected worktree path in context, got: $($pq.context)"

        # rebase_conflict puts file names in context (canonical "conflict files"
        # phrasing). All other kinds put the message + failure_detail in context
        # so the operator sees git output / exception text.
        if ($kind -eq 'rebase_conflict') {
            Assert-True -Name "Kind dispatch ($kind): context lists conflict files" `
                -Condition ($pq.context -match 'src/foo\.cs' -and $pq.context -match 'src/bar\.cs') `
                -Message "Expected conflict files in context"
        } else {
            Assert-True -Name "Kind dispatch ($kind): context includes message" `
                -Condition ($pq.context -match "message-for-$kind") `
                -Message "Expected message in context"
            Assert-True -Name "Kind dispatch ($kind): context includes failure_detail" `
                -Condition ($pq.context -match "detail-for-$kind") `
                -Message "Expected failure_detail in context"
        }
    }

    # End-to-end through Move-TaskToMergeFailureNeedsInput with each kind: the
    # written pending_question must match the kind. Pin the regression that the
    # function lookup respects MergeResult.failure_kind even when conflict_files
    # is also present (production hashtable shape).
    $kdWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-kd-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    $kdNeedsInput = Join-Path $kdWorkspace "needs-input"
    $kdDone = Join-Path $kdWorkspace "done"
    New-Item -ItemType Directory -Force -Path $kdDone | Out-Null
    $kdBotRoot = Join-Path $kdWorkspace ".bot"
    $kdSavedRoot = $global:DotbotProjectRoot
    $global:DotbotProjectRoot = $kdWorkspace
    try {
        $endToEndCases = @(
            @{ Kind = 'commit_failed';        ExpectedId = 'commit-failed';   Message = 'pre-commit hook rejected secrets'; Detail = 'gitleaks: 1 leak detected in .env.local' }
            @{ Kind = 'merge_command_failed'; ExpectedId = 'merge-failed';    Message = 'Squash merge failed: fatal: refusing to merge unrelated histories'; Detail = 'fatal: refusing to merge unrelated histories' }
            @{ Kind = 'branch_missing';       ExpectedId = 'branch-missing';  Message = 'Branch task/123-foo no longer exists'; Detail = 'Expected branch: task/123-foo' }
            @{ Kind = 'exception';            ExpectedId = 'merge-error';     Message = 'Error during merge: cannot find path'; Detail = 'Stack at line 42' }
        )
        foreach ($case in $endToEndCases) {
            $kindTaskId = "kd$($case.Kind.Substring(0,6))"
            $kindTaskJson = @{
                id = $kindTaskId
                name = "Task for $($case.Kind)"
                status = "done"
                created_at = "2026-05-13T00:00:00Z"
                updated_at = "2026-05-13T00:00:00Z"
            } | ConvertTo-Json -Depth 5
            $kindTaskFile = Join-Path $kdDone "$kindTaskId.json"
            Set-Content -Path $kindTaskFile -Value $kindTaskJson -Encoding UTF8

            $kindMr = @{
                success        = $false
                message        = $case.Message
                conflict_files = @()
                failure_kind   = $case.Kind
                failure_detail = $case.Detail
            }
            $kindResult = Move-TaskToMergeFailureNeedsInput `
                -TaskId $kindTaskId `
                -TasksBaseDir $kdWorkspace `
                -MergeResult $kindMr `
                -WorktreePath "/tmp/worktree-$kindTaskId" `
                -BotRoot $kdBotRoot

            Assert-True -Name "End-to-end ($($case.Kind)): escalation succeeds" `
                -Condition ($kindResult.success -eq $true) `
                -Message "Expected success=true, reason=$($kindResult.notification_reason)"

            Assert-Equal -Name "End-to-end ($($case.Kind)): result.failure_kind echoed" `
                -Expected $case.Kind -Actual $kindResult.failure_kind

            $kindLanded = Join-Path $kdNeedsInput "$kindTaskId.json"
            if (Test-Path $kindLanded) {
                $kindMoved = Get-Content $kindLanded -Raw | ConvertFrom-Json
                Assert-Equal -Name "End-to-end ($($case.Kind)): pending_question.id correct" `
                    -Expected $case.ExpectedId -Actual $kindMoved.pending_question.id
                Assert-True -Name "End-to-end ($($case.Kind)): pending_question.context surfaces message" `
                    -Condition ($kindMoved.pending_question.context -match [regex]::Escape($case.Message)) `
                    -Message "Expected message '$($case.Message)' in context, got: $($kindMoved.pending_question.context)"
                Assert-True -Name "End-to-end ($($case.Kind)): pending_question.context surfaces detail" `
                    -Condition ($kindMoved.pending_question.context -match [regex]::Escape($case.Detail)) `
                    -Message "Expected detail '$($case.Detail)' in context, got: $($kindMoved.pending_question.context)"
            } else {
                Write-TestResult -Name "End-to-end ($($case.Kind)): file landed in needs-input/" -Status Fail -Message "Expected $kindLanded"
            }
        }

        # Pin the back-compat fallback: a MergeResult without failure_kind but
        # with non-empty conflict_files is still treated as rebase_conflict so
        # older test fixtures and external callers keep working.
        $bcTaskId = "bc012345"
        Set-Content -Path (Join-Path $kdDone "$bcTaskId.json") -Encoding UTF8 -Value (@{
            id = $bcTaskId; name = "back-compat task"; status = "done"
            created_at = "2026-05-13T00:00:00Z"; updated_at = "2026-05-13T00:00:00Z"
        } | ConvertTo-Json -Depth 5)
        $bcResult = Move-TaskToMergeFailureNeedsInput `
            -TaskId $bcTaskId `
            -TasksBaseDir $kdWorkspace `
            -MergeResult @{ success = $false; message = "two conflicts"; conflict_files = @("a.cs","b.cs") } `
            -WorktreePath "/tmp/bc-worktree" `
            -BotRoot $kdBotRoot
        Assert-Equal -Name "Back-compat: missing failure_kind + conflict_files infers rebase_conflict" `
            -Expected 'rebase_conflict' -Actual $bcResult.failure_kind
    } finally {
        $global:DotbotProjectRoot = $kdSavedRoot
        Remove-Item -Path $kdWorkspace -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-TestResult -Name "Dotbot.Task module exists" -Status Fail -Message "Module not found at $mergeEscModule"
}

# ═══════════════════════════════════════════════════════════════════
# NEEDS-REVIEW TRANSITIONS (#104)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- needs-review transitions ---" -ForegroundColor Cyan

if (Test-Path $mergeEscModule) {
    # Module already imported by the section above. Use the exported helpers
    # directly so this test catches regressions in either Get-TaskStatuses or
    # the closed transition table — both are load-bearing for the
    # task_mark_needs_review / task_submit_review MCP tools.

    $statuses = Get-TaskStatuses
    Assert-True -Name "Get-TaskStatuses includes 'needs-review'" `
        -Condition ($statuses -contains 'needs-review') `
        -Message "Expected 'needs-review' in canonical status list. Got: $($statuses -join ', ')"

    Assert-True -Name "Transition in-progress -> needs-review is allowed" `
        -Condition (Test-TaskTransition -From 'in-progress' -To 'needs-review') `
        -Message "Agents call task_mark_needs_review from in-progress; the edge must be in the closed table."

    Assert-True -Name "Transition needs-review -> done is allowed (approve path)" `
        -Condition (Test-TaskTransition -From 'needs-review' -To 'done') `
        -Message "task_submit_review approve path needs the edge so the enter-done hook fires verify."

    Assert-True -Name "Transition needs-review -> todo is allowed (reject path)" `
        -Condition (Test-TaskTransition -From 'needs-review' -To 'todo') `
        -Message "task_submit_review reject path returns the task to todo for rework."

    Assert-True -Name "Transition todo -> needs-review is rejected" `
        -Condition (-not (Test-TaskTransition -From 'todo' -To 'needs-review')) `
        -Message "Only in-progress is allowed to park for review."

    Assert-True -Name "Transition done -> needs-review is rejected" `
        -Condition (-not (Test-TaskTransition -From 'done' -To 'needs-review')) `
        -Message "Re-parking a done task would skip the recovery flow; must be rejected."
} else {
    Write-TestResult -Name "needs-review transitions" -Status Skip -Message "Dotbot.Task module not available"
}

# ═══════════════════════════════════════════════════════════════════
# NOTIFICATION POLLER MODULE TESTS
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- NotificationPoller Module ---" -ForegroundColor Cyan

$pollerModule = Join-Path $botDir "src/ui/modules/NotificationPoller.psm1"

if (Test-Path $pollerModule) {
    Import-Module $pollerModule -Force

    # Test Initialize-NotificationPoller does not throw when disabled
    $pollerError = $false
    try {
        Initialize-NotificationPoller -BotRoot $botDir
    } catch {
        $pollerError = $true
    }
    Assert-True -Name "Initialize-NotificationPoller no-op when disabled" `
        -Condition (-not $pollerError) `
        -Message "Should not throw when notifications disabled"

    # Test Invoke-NotificationPollTick does not throw with empty needs-input
    $pollTickError = $false
    try {
        Invoke-NotificationPollTick
    } catch {
        $pollTickError = $true
    }
    Assert-True -Name "Invoke-NotificationPollTick no-op when no tasks" `
        -Condition (-not $pollTickError) `
        -Message "Should not throw with empty needs-input"

    # ── Invoke-SplitTransitionFromNotification tests ─────────────────
    $needsInputDir = Join-Path $botDir "workspace" "tasks" "needs-input"
    $todoDir       = Join-Path $botDir "workspace" "tasks" "todo"
    if (-not (Test-Path $needsInputDir)) {
        New-Item -ItemType Directory -Force -Path $needsInputDir | Out-Null
    }
    if (-not (Test-Path $todoDir)) {
        New-Item -ItemType Directory -Force -Path $todoDir | Out-Null
    }

    # --- Reject path test ---
    $rejectTask = [PSCustomObject]@{
        id = "split-reject-test"
        name = "Task to reject"
        status = "needs-input"
        split_proposal = [PSCustomObject]@{
            reason = "Too big"
            sub_tasks = @([PSCustomObject]@{ name = "Sub A" })
            proposed_at = "2026-01-15T10:00:00Z"
        }
        notification = [PSCustomObject]@{
            question_id = "q-reject"; instance_id = "i-reject"; channel = "teams"; project_id = "proj1"
        }
        updated_at = "2026-01-15T10:00:00Z"
    }
    $rejectFile = Join-Path $needsInputDir "split-reject-test.json"
    $rejectTask | ConvertTo-Json -Depth 20 | Set-Content -Path $rejectFile -Encoding UTF8
    $rejectFileInfo = Get-Item $rejectFile

    $rejectError = $false
    try {
        Invoke-SplitTransitionFromNotification -TaskFile $rejectFileInfo -TaskContent $rejectTask `
            -AnswerKey 'reject' -BotRoot $botDir
    } catch {
        $rejectError = $true
    }
    Assert-True -Name "Invoke-SplitTransitionFromNotification reject does not throw" `
        -Condition (-not $rejectError) `
        -Message "Reject path threw an error"

    Assert-PathNotExists -Name "Reject: task removed from needs-input" -Path $rejectFile

    $rejectedFile = Join-Path $todoDir "split-reject-test.json"
    Assert-PathExists -Name "Reject: task requeued to todo" -Path $rejectedFile

    if (Test-Path $rejectedFile) {
        $rejectedContent = Get-Content -Path $rejectedFile -Raw | ConvertFrom-Json
        Assert-True -Name "Reject: split_proposal.status is 'rejected'" `
            -Condition ($rejectedContent.split_proposal.status -eq 'rejected') `
            -Message "Expected 'rejected', got '$($rejectedContent.split_proposal.status)'"
        Assert-True -Name "Reject: split_proposal.answered_via is 'notification'" `
            -Condition ($rejectedContent.split_proposal.answered_via -eq 'notification') `
            -Message "Expected 'notification', got '$($rejectedContent.split_proposal.answered_via)'"
        Assert-True -Name "Reject: notification metadata cleared" `
            -Condition ($null -eq $rejectedContent.notification) `
            -Message "Expected notification=null"
        Assert-True -Name "Reject: task status is 'todo'" `
            -Condition ($rejectedContent.status -eq 'todo') `
            -Message "Expected 'todo', got '$($rejectedContent.status)'"
        # Cleanup
        Remove-Item -Path $rejectedFile -Force -ErrorAction SilentlyContinue
    }

    # --- Invalid key test (no-op) ---
    $invalidKeyTask = [PSCustomObject]@{
        id = "split-invalid-test"
        name = "Task with bad key"
        status = "needs-input"
        split_proposal = [PSCustomObject]@{
            reason = "Reason"; sub_tasks = @([PSCustomObject]@{ name = "Sub" })
            proposed_at = "2026-01-15T10:00:00Z"
        }
        notification = [PSCustomObject]@{
            question_id = "q-inv"; instance_id = "i-inv"; channel = "teams"; project_id = "proj1"
        }
        updated_at = "2026-01-15T10:00:00Z"
    }
    $invalidFile = Join-Path $needsInputDir "split-invalid-test.json"
    $invalidKeyTask | ConvertTo-Json -Depth 20 | Set-Content -Path $invalidFile -Encoding UTF8
    $invalidFileInfo = Get-Item $invalidFile

    $invalidError = $false
    try {
        Invoke-SplitTransitionFromNotification -TaskFile $invalidFileInfo -TaskContent $invalidKeyTask `
            -AnswerKey 'maybe' -BotRoot $botDir
    } catch {
        $invalidError = $true
    }
    Assert-True -Name "Invoke-SplitTransitionFromNotification ignores invalid key" `
        -Condition (-not $invalidError) `
        -Message "Invalid key should not throw"

    Assert-PathExists -Name "Invalid key: task stays in needs-input" -Path $invalidFile

    if (Test-Path $invalidFile) {
        $invalidContent = Get-Content -Path $invalidFile -Raw | ConvertFrom-Json
        Assert-True -Name "Invalid key: notification metadata cleared (prevents poll loop)" `
            -Condition ($null -eq $invalidContent.notification) `
            -Message "Expected notification=null after invalid-key ignore"
        Assert-True -Name "Invalid key: split_proposal preserved" `
            -Condition ($null -ne $invalidContent.split_proposal -and $invalidContent.split_proposal.reason -eq 'Reason') `
            -Message "Expected split_proposal preserved"
    }
    # Cleanup
    Remove-Item -Path $invalidFile -Force -ErrorAction SilentlyContinue
} else {
    Write-TestResult -Name "NotificationPoller module exists" -Status Fail -Message "Module not found at $pollerModule"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# start-from-jira PROFILE: TOOL REGISTRATION & CATEGORIES
# ═══════════════════════════════════════════════════════════════════

Write-Host "  start-from-jira TOOL REGISTRATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$startFromJiraProfile = Join-Path $dotbotDir "workflows\start-from-jira"
if (Test-Path $startFromJiraProfile) {
    $mrProj = New-TestProjectFromGolden -Flavor 'start-from-jira'
    $mrTestProject = $mrProj.ProjectRoot
    $mrBotDir = $mrProj.BotDir

    # Strip verify config to only include scripts that actually exist in the test project
    $mrVerifyConfig = Join-Path $mrBotDir "hooks\verify\config.json"
    if (Test-Path $mrVerifyConfig) {
        try {
            $vc = Get-Content $mrVerifyConfig -Raw | ConvertFrom-Json
            $vd = Join-Path $mrBotDir "hooks\verify"
            $existing = @()
            foreach ($s in $vc.scripts) {
                if (Test-Path (Join-Path $vd $s.name)) { $existing += $s }
            }
            $vc.scripts = $existing
            $vc | ConvertTo-Json -Depth 5 | Set-Content -Path $mrVerifyConfig -Encoding UTF8
        } catch { Write-Verbose "Failed to parse data: $_" }
    }

    $mrMcpProcess = $null
    $mrRequestId = 0

    try {
        $mrMcpProcess = Start-McpServer -BotDir $mrBotDir
        Assert-True -Name "start-from-jira MCP server starts" `
            -Condition (-not $mrMcpProcess.HasExited) `
            -Message "Server process exited immediately"

        $mrInitResponse = Send-McpInitialize -Process $mrMcpProcess
        Assert-True -Name "start-from-jira MCP initialize responds" `
            -Condition ($null -ne $mrInitResponse) `
            -Message "No response"

        # List tools
        $mrRequestId++
        $mrListResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/list'
            params  = @{}
        }

        Assert-True -Name "start-from-jira tools/list responds" `
            -Condition ($null -ne $mrListResponse) `
            -Message "No response"

        if ($mrListResponse -and $mrListResponse.result) {
            $mrToolNames = $mrListResponse.result.tools | ForEach-Object { $_.name }

            # Check the 3 new tools are registered
            foreach ($toolName in @('repo_clone', 'repo_list', 'research_status')) {
                Assert-True -Name "start-from-jira tool '$toolName' registered" `
                    -Condition ($toolName -in $mrToolNames) `
                    -Message "Tool not found in tools/list"
            }

            # Check inputSchema is present for each new tool
            foreach ($toolName in @('repo_clone', 'repo_list', 'research_status')) {
                $toolDef = $mrListResponse.result.tools | Where-Object { $_.name -eq $toolName }
                Assert-True -Name "start-from-jira tool '$toolName' has inputSchema" `
                    -Condition ($null -ne $toolDef.inputSchema) `
                    -Message "inputSchema missing"
            }
        }

        Write-Host ""
        Write-Host "  start-from-jira CATEGORIES" -ForegroundColor Cyan
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

        # Test task_create with start-from-jira category "research"
        $mrRequestId++
        $researchResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'Test Research Task'
                    description = 'Integration test for research category'
                    category    = 'research'
                    priority    = 10
                    effort      = 'S'
                }
            }
        }

        if ($researchResponse -and $researchResponse.result) {
            $researchText = $researchResponse.result.content[0].text
            $researchObj = $researchText | ConvertFrom-Json
            Assert-True -Name "task_create with category 'research' succeeds" `
                -Condition ($researchObj.success -eq $true) `
                -Message "Failed: $researchText"
        } else {
            Assert-True -Name "task_create with category 'research' succeeds" `
                -Condition ($false) `
                -Message "Error or no response: $($researchResponse | ConvertTo-Json -Compress -Depth 3)"
        }

        # Test task_create with start-from-jira category "analysis"
        $mrRequestId++
        $analysisResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'Test Analysis Task'
                    description = 'Integration test for analysis category'
                    category    = 'analysis'
                    priority    = 10
                    effort      = 'S'
                }
            }
        }

        if ($analysisResponse -and $analysisResponse.result) {
            $analysisText = $analysisResponse.result.content[0].text
            $analysisObj = $analysisText | ConvertFrom-Json
            Assert-True -Name "task_create with category 'analysis' succeeds" `
                -Condition ($analysisObj.success -eq $true) `
                -Message "Failed: $analysisText"
        } else {
            Assert-True -Name "task_create with category 'analysis' succeeds" `
                -Condition ($false) `
                -Message "Error or no response: $($analysisResponse | ConvertTo-Json -Compress -Depth 3)"
        }

        # Test task_create with working_dir → field persists in task JSON
        $mrRequestId++
        $wdResponse = Send-McpRequest -Process $mrMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $mrRequestId
            method  = 'tools/call'
            params  = @{
                name      = 'task_create'
                arguments = @{
                    name        = 'Test Working Dir Task'
                    description = 'Integration test for working_dir field'
                    category    = 'research'
                    priority    = 10
                    effort      = 'S'
                    working_dir = 'repos/FakeRepo'
                }
            }
        }

        if ($wdResponse -and $wdResponse.result) {
            $wdText = $wdResponse.result.content[0].text
            $wdObj = $wdText | ConvertFrom-Json
            Assert-True -Name "task_create with working_dir succeeds" `
                -Condition ($wdObj.success -eq $true) `
                -Message "Failed: $wdText"

            # Read the task file to verify working_dir persists
            if ($wdObj.file_path -and (Test-Path $wdObj.file_path)) {
                $taskContent = Get-Content $wdObj.file_path -Raw | ConvertFrom-Json
                Assert-Equal -Name "working_dir persists in task JSON" `
                    -Expected "repos/FakeRepo" `
                    -Actual $taskContent.working_dir
            }
        } else {
            Assert-True -Name "task_create with working_dir succeeds" `
                -Condition ($false) `
                -Message "Error or no response"
        }

    } catch {
        Write-TestResult -Name "start-from-jira MCP tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
    } finally {
        if ($mrMcpProcess) {
            Stop-McpServer -Process $mrMcpProcess
        }
        Remove-TestProject -Path $mrTestProject
    }
} else {
    Write-TestResult -Name "start-from-jira tool registration" -Status Skip -Message "start-from-jira profile not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# start-from-pr PROFILE: TOOL REGISTRATION & DIRECT TOOL TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  start-from-pr TOOL REGISTRATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$startFromPrProfile = Join-Path $dotbotDir "content\workflows\start-from-pr"
Assert-PathExists -Name "start-from-pr profile source exists" -Path $startFromPrProfile
if (Test-Path $startFromPrProfile) {
    $prProj = New-TestProjectFromGolden -Flavor 'start-from-pr'
    $prTestProject = $prProj.ProjectRoot
    $prBotDir = $prProj.BotDir

    $prVerifyConfig = Join-Path $prBotDir "hooks\verify\config.json"
    if (Test-Path $prVerifyConfig) {
        try {
            $vc = Get-Content $prVerifyConfig -Raw | ConvertFrom-Json
            $vd = Join-Path $prBotDir "hooks\verify"
            $existing = @()
            foreach ($s in $vc.scripts) {
                if (Test-Path (Join-Path $vd $s)) { $existing += $s }
            }
            $vc.scripts = $existing
            $vc | ConvertTo-Json -Depth 5 | Set-Content -Path $prVerifyConfig -Encoding UTF8
        } catch { Write-Verbose "Failed to parse data: $_" }
    }

    $prMcpProcess = $null
    $prRequestId = 0

    try {
        $prMcpProcess = Start-McpServer -BotDir $prBotDir
        Assert-True -Name "start-from-pr MCP server starts" `
            -Condition (-not $prMcpProcess.HasExited) `
            -Message "Server process exited immediately"

        $prInitResponse = Send-McpInitialize -Process $prMcpProcess
        Assert-True -Name "start-from-pr MCP initialize responds" `
            -Condition ($null -ne $prInitResponse) `
            -Message "No response"

        $prRequestId++
        $prListResponse = Send-McpRequest -Process $prMcpProcess -Request @{
            jsonrpc = '2.0'
            id      = $prRequestId
            method  = 'tools/list'
            params  = @{}
        }

        Assert-True -Name "start-from-pr tools/list responds" `
            -Condition ($null -ne $prListResponse) `
            -Message "No response"

        if ($prListResponse -and $prListResponse.result) {
            $prToolNames = $prListResponse.result.tools | ForEach-Object { $_.name }
            Assert-True -Name "start-from-pr tool 'pr_context' registered" `
                -Condition ('pr_context' -in $prToolNames) `
                -Message "Tool not found in tools/list"

            $prToolDef = $prListResponse.result.tools | Where-Object { $_.name -eq 'pr_context' }
            Assert-True -Name "start-from-pr tool 'pr_context' has inputSchema" `
                -Condition ($null -ne $prToolDef.inputSchema) `
                -Message "inputSchema missing"
        }

        # task_create now flows through the per-project runtime
        #, so a smoke test through the MCP transport can't run here
        # without a live runtime process. The "analysis" category lint
        # is covered by start-from-pr's own profile tests; an end-to-end
        # task_create exercise lands in 's Test-Workflow*Integration.
    } catch {
        Write-TestResult -Name "start-from-pr MCP tests" -Status Fail -Message "Exception: $($_.Exception.Message)"
    } finally {
        if ($prMcpProcess) {
            Stop-McpServer -Process $prMcpProcess
        }
        Remove-TestProject -Path $prTestProject
    }

    Write-Host ""
    Write-Host "  start-from-pr DIRECT TOOL TESTS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $prContextScript = Join-Path $startFromPrProfile "systems/mcp/tools/pr-context/script.ps1"
    if (Test-Path $prContextScript) {
        . $prContextScript

        $directTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-pr-context-" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $directTestRoot -ItemType Directory -Force | Out-Null
        $global:DotbotProjectRoot = $directTestRoot
        Set-Content -Path (Join-Path $directTestRoot ".env.local") -Value "AZURE_DEVOPS_PAT=test-pat`nGITHUB_TOKEN=test-gh" -Encoding UTF8

        $savedGithubToken = $env:GITHUB_TOKEN
        $savedGhToken = $env:GH_TOKEN
        $savedAdoPat = $env:AZURE_DEVOPS_PAT

        try {
            $githubResult = & {
                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/pulls/42') {
                        return [pscustomobject]@{
                            number = 42
                            title = 'Add billing validation'
                            body = "Implements billing validation.`n`nFixes #123"
                            html_url = 'https://github.com/acme/widgets/pull/42'
                            state = 'open'
                            user = [pscustomobject]@{ login = 'octocat' }
                            head = [pscustomobject]@{ ref = 'feature/billing-validation' }
                            base = [pscustomobject]@{ ref = 'main' }
                        }
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/pulls/42/files?per_page=100&page=1') {
                        $pageFiles = [System.Collections.ArrayList]::new()
                        for ($index = 1; $index -le 100; $index++) {
                            [void]$pageFiles.Add([pscustomobject]@{
                                filename = ('src/File{0:D3}.cs' -f $index)
                                status = 'modified'
                            })
                        }

                        return @($pageFiles)
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/pulls/42/files?per_page=100&page=2') {
                        return @(
                            [pscustomobject]@{ filename = 'docs/billing.md'; status = 'modified' }
                        )
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/issues/123') {
                        return [pscustomobject]@{
                            number = 123
                            title = 'Billing validation rules'
                            state = 'open'
                            html_url = 'https://github.com/acme/widgets/issues/123'
                        }
                    }

                    throw "Unexpected GitHub URI: $Uri"
                }

                Invoke-PrContext -Arguments @{ pr_url = 'https://github.com/acme/widgets/pull/42' }
            }

            Assert-Equal -Name "Invoke-PrContext GitHub URL: provider" -Expected 'github' -Actual $githubResult.provider
            Assert-Equal -Name "Invoke-PrContext GitHub URL: title" -Expected 'Add billing validation' -Actual $githubResult.title
            Assert-Equal -Name "Invoke-PrContext GitHub URL: linked issue count" -Expected 1 -Actual @($githubResult.linked_issues).Count
            Assert-Equal -Name "Invoke-PrContext GitHub URL: changed file count" -Expected 101 -Actual @($githubResult.changed_files).Count
            Assert-Equal -Name "Invoke-PrContext GitHub URL: first changed file path" -Expected 'src/File001.cs' -Actual $githubResult.changed_files[0].path
            Assert-Equal -Name "Invoke-PrContext GitHub URL: paginated file path included" -Expected 'docs/billing.md' -Actual $githubResult.changed_files[100].path

            $githubAutoResult = & {
                function git {
                    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
                    $joined = $Arguments -join ' '
                    switch ($joined) {
                        'remote get-url origin' { return 'https://github.com/acme/service.api.git' }
                        'branch --show-current' { return 'feature/billing-validation' }
                        default { throw "Unexpected git invocation: $joined" }
                    }
                }

                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -like 'https://api.github.com/repos/acme/service.api/pulls?*head=acme:feature/billing-validation*state=open*') {
                        return @(
                            [pscustomobject]@{
                                number = 77
                                title = 'Auto-detected PR'
                                body = 'Detect current branch PR'
                                html_url = 'https://github.com/acme/service.api/pull/77'
                                state = 'open'
                                user = [pscustomobject]@{ login = 'octocat' }
                                head = [pscustomobject]@{ ref = 'feature/billing-validation' }
                                base = [pscustomobject]@{ ref = 'main' }
                            }
                        )
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/service.api/pulls/77/files?per_page=100&page=1') {
                        return @([pscustomobject]@{ filename = 'src/AutoDetected.cs'; status = 'modified' })
                    }

                    throw "Unexpected GitHub auto-detect URI: $Uri"
                }

                Invoke-PrContext -Arguments @{}
            }

            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: URL" -Expected 'https://github.com/acme/service.api/pull/77' -Actual $githubAutoResult.pr_url
            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: source branch" -Expected 'feature/billing-validation' -Actual $githubAutoResult.source_branch
            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: repository" -Expected 'acme/service.api' -Actual $githubAutoResult.repository
            Assert-Equal -Name "Invoke-PrContext GitHub auto-detect: changed file count" -Expected 1 -Actual @($githubAutoResult.changed_files).Count

            $githubCrossRepoIssues = & {
                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -eq 'https://api.github.com/repos/other-org/other-repo/issues/456') {
                        return [pscustomobject]@{
                            number = 456
                            title = 'Cross-repo issue'
                            state = 'open'
                            html_url = 'https://github.com/other-org/other-repo/issues/456'
                        }
                    }

                    if ($Uri -eq 'https://api.github.com/repos/acme/widgets/issues/123') {
                        return [pscustomobject]@{
                            number = 123
                            title = 'Local repo issue'
                            state = 'open'
                            html_url = 'https://github.com/acme/widgets/issues/123'
                        }
                    }

                    throw "Unexpected GitHub linked issue URI: $Uri"
                }

                Get-GitHubLinkedIssues -Owner 'acme' -Repo 'widgets' -Texts @('See other-org/other-repo#456 and #123')
            }

            Assert-Equal -Name "Get-GitHubLinkedIssues cross-repo count" -Expected 2 -Actual @($githubCrossRepoIssues).Count
            Assert-Equal -Name "Get-GitHubLinkedIssues cross-repo first key" -Expected 'other-org/other-repo#456' -Actual $githubCrossRepoIssues[0].key
            Assert-Equal -Name "Get-GitHubLinkedIssues cross-repo second key" -Expected '#123' -Actual $githubCrossRepoIssues[1].key

            $adoResult = & {
                function Invoke-RestMethod {
                    param(
                        [string]$Method = 'Get',
                        [string]$Uri,
                        $Headers
                    )

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99?api-version=7.1') {
                        return [pscustomobject]@{
                            pullRequestId = 99
                            title = 'Storefront tax alignment'
                            description = 'Align tax calculation with PRD.'
                            status = 'active'
                            createdBy = [pscustomobject]@{ displayName = 'Ada Lovelace' }
                            sourceRefName = 'refs/heads/feature/tax-alignment'
                            targetRefName = 'refs/heads/main'
                            repository = [pscustomobject]@{
                                name = 'Storefront'
                                webUrl = 'https://dev.azure.com/contoso/Commerce/_git/Storefront'
                            }
                            url = 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99'
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/workitems?api-version=7.1') {
                        return [pscustomobject]@{
                            value = @(
                                [pscustomobject]@{ id = '456'; url = 'https://dev.azure.com/contoso/Commerce/_apis/wit/workItems/456' }
                            )
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/wit/workItems/456?api-version=7.1') {
                        return [pscustomobject]@{
                            id = 456
                            fields = [pscustomobject]@{
                                'System.Title' = 'Tax rules rollout'
                                'System.State' = 'Active'
                                'System.WorkItemType' = 'User Story'
                            }
                            _links = [pscustomobject]@{
                                html = [pscustomobject]@{ href = 'https://dev.azure.com/contoso/Commerce/_workitems/edit/456' }
                            }
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/iterations?api-version=7.1') {
                        return [pscustomobject]@{
                            value = @(
                                [pscustomobject]@{ id = 1 },
                                [pscustomobject]@{ id = 3 }
                            )
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/iterations/3/changes?$compareTo=0&$top=2000&$skip=0&api-version=7.1') {
                        return [pscustomobject]@{
                            changeEntries = @(
                                [pscustomobject]@{
                                    changeType = 'edit'
                                    item = [pscustomobject]@{ path = '/src/TaxService.cs' }
                                },
                                [pscustomobject]@{
                                    changeType = 'add'
                                    item = [pscustomobject]@{ path = '/tests/TaxServiceTests.cs' }
                                }
                            )
                            nextSkip = 2
                            nextTop = 2000
                        }
                    }

                    if ($Uri -eq 'https://dev.azure.com/contoso/Commerce/_apis/git/repositories/Storefront/pullRequests/99/iterations/3/changes?$compareTo=0&$top=2000&$skip=2&api-version=7.1') {
                        return [pscustomobject]@{
                            changeEntries = @(
                                [pscustomobject]@{
                                    changeType = 'rename'
                                    item = [pscustomobject]@{ path = '/docs/TaxGuide.md' }
                                }
                            )
                            nextSkip = 0
                            nextTop = 0
                        }
                    }

                    throw "Unexpected ADO URI: $Uri"
                }

                Invoke-PrContext -Arguments @{ pr_url = 'https://dev.azure.com/contoso/Commerce/_git/Storefront/pullrequest/99?path=/src/TaxService.cs&_a=overview' }
            }

            Assert-Equal -Name "Invoke-PrContext ADO URL: provider" -Expected 'azure-devops' -Actual $adoResult.provider
            Assert-Equal -Name "Invoke-PrContext ADO URL: title" -Expected 'Storefront tax alignment' -Actual $adoResult.title
            Assert-Equal -Name "Invoke-PrContext ADO URL: resolved URL" -Expected 'https://dev.azure.com/contoso/Commerce/_git/Storefront/pullrequest/99?path=/src/TaxService.cs&_a=overview' -Actual $adoResult.pr_url
            Assert-Equal -Name "Invoke-PrContext ADO URL: linked issue count" -Expected 1 -Actual @($adoResult.linked_issues).Count
            Assert-Equal -Name "Invoke-PrContext ADO URL: changed file count" -Expected 3 -Actual @($adoResult.changed_files).Count
            Assert-Equal -Name "Invoke-PrContext ADO URL: first changed file path" -Expected '/src/TaxService.cs' -Actual $adoResult.changed_files[0].path
            Assert-Equal -Name "Invoke-PrContext ADO URL: cumulative change path included" -Expected '/docs/TaxGuide.md' -Actual $adoResult.changed_files[2].path

            $gitHubRemoteInfo = Convert-RemoteToGitHubInfo -RemoteUrl 'https://github.com/acme/service.api.git'
            Assert-Equal -Name "Convert-RemoteToGitHubInfo accepts dotted repo names" -Expected 'service.api' -Actual $gitHubRemoteInfo.repo

            $adoRemoteInfo = Convert-RemoteToAdoInfo -RemoteUrl 'https://dev.azure.com/contoso/Commerce/_git/Storefront.Core.git'
            Assert-Equal -Name "Convert-RemoteToAdoInfo accepts dotted repo names" -Expected 'Storefront.Core' -Actual $adoRemoteInfo.repo
        } finally {
            $env:GITHUB_TOKEN = $savedGithubToken
            $env:GH_TOKEN = $savedGhToken
            $env:AZURE_DEVOPS_PAT = $savedAdoPat
            if (Test-Path $directTestRoot) {
                Remove-Item $directTestRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-TestResult -Name "start-from-pr direct tool tests" -Status Fail -Message "Tool script not found at $prContextScript"
    }
} else {
    Write-TestResult -Name "start-from-pr tool registration" -Status Skip -Message "start-from-pr profile not found"
}

Write-Host ""
Write-Host "  PRODUCT API DIRECT TESTS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$repoRoot = Split-Path $PSScriptRoot -Parent
$productApiModule = Join-Path $repoRoot "src/ui/modules/ProductAPI.psm1"
if (Test-Path $productApiModule) {
    Import-Module $productApiModule -Force

    $productApiTestProject = New-TestProject
    try {
        $productBotRoot = Join-Path $productApiTestProject ".bot"
        $productDir = Join-Path $productBotRoot "workspace\product"
        $briefingDir = Join-Path $productDir "briefing"
        $controlDir = Join-Path $productBotRoot ".control"

        New-Item -Path $briefingDir -ItemType Directory -Force | Out-Null
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null

        Set-Content -Path (Join-Path $productDir "mission.md") -Value "# Mission" -Encoding UTF8
        Set-Content -Path (Join-Path $productDir "roadmap-overview.md") -Value "# Roadmap" -Encoding UTF8
        Set-Content -Path (Join-Path $productDir "interview-summary.md") -Value "# Interview Summary" -Encoding UTF8
        Set-Content -Path (Join-Path $briefingDir "pr-context.md") -Value "# Pull Request Context" -Encoding UTF8
        # JSON files for type/resolution tests
        Set-Content -Path (Join-Path $productDir "config.json") -Value '{"key":"value"}' -Encoding UTF8
        Set-Content -Path (Join-Path $productDir "mission.json") -Value '{"title":"Mission JSON"}' -Encoding UTF8
        # Image files for type tests
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "logo.png"), [byte[]](0x89, 0x50, 0x4E, 0x47))
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "screenshot.jpg"), [byte[]](0xFF, 0xD8, 0xFF, 0xE0))
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "animation.gif"), [byte[]](0x47, 0x49, 0x46, 0x38))
        Set-Content -Path (Join-Path $productDir "diagram.svg") -Value '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>' -Encoding UTF8
        # Text file for txt type tests
        Set-Content -Path (Join-Path $productDir "notes.txt") -Value "Plain text content with <html> special chars" -Encoding UTF8
        # True binary file for binary type tests
        [System.IO.File]::WriteAllBytes((Join-Path $productDir "document.pdf"), [byte[]](0x25, 0x50, 0x44, 0x46))
        # .gitkeep should be excluded
        Set-Content -Path (Join-Path $briefingDir ".gitkeep") -Value "" -Encoding UTF8

        Initialize-ProductAPI -BotRoot $productBotRoot -ControlDir $controlDir

        $docs = @((Get-ProductList).docs)
        Assert-Equal -Name "ProductAPI lists nested product docs" `
            -Expected 12 `
            -Actual $docs.Count
        Assert-Equal -Name "ProductAPI keeps mission first in priority order" `
            -Expected "mission" `
            -Actual $docs[0].name
        Assert-True -Name "ProductAPI includes briefing/pr-context in list" `
            -Condition ($docs.name -contains "briefing/pr-context") `
            -Message "Nested briefing document missing from product list"
        Assert-True -Name "ProductAPI surfaces relative filename for briefing docs" `
            -Condition ($docs.filename -contains "briefing/pr-context.md") `
            -Message "Expected relative filename briefing/pr-context.md"

        $briefingDoc = Get-ProductDocument -Name "briefing/pr-context"
        Assert-True -Name "ProductAPI loads nested briefing doc by relative name" `
            -Condition ($briefingDoc.success -eq $true -and $briefingDoc.content -match 'Pull Request Context') `
            -Message "Nested briefing doc could not be loaded"

        $encodedBriefingDoc = Get-ProductDocument -Name "briefing%2Fpr-context"
        Assert-True -Name "ProductAPI loads nested briefing doc by encoded route name" `
            -Condition ($encodedBriefingDoc.success -eq $true -and $encodedBriefingDoc.name -eq 'briefing/pr-context') `
            -Message "Encoded nested route name did not resolve"

        $traversalDoc = Get-ProductDocument -Name "../secrets"
        Assert-True -Name "ProductAPI blocks path traversal outside workspace/product" `
            -Condition ($traversalDoc.success -eq $false -and $traversalDoc._statusCode -eq 404) `
            -Message "Path traversal should return not found"

        # Metadata field tests (type, size, depth)
        $logoPng = $docs | Where-Object { $_.name -eq 'logo.png' }
        Assert-True -Name "ProductAPI includes image files in list" `
            -Condition ($null -ne $logoPng) `
            -Message "Image file logo.png missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .png files" `
            -Expected "image" `
            -Actual $logoPng.type
        Assert-True -Name "ProductAPI returns size field for image files" `
            -Condition ($logoPng.size -gt 0) `
            -Message "Expected non-zero size for logo.png"
        Assert-Equal -Name "ProductAPI returns depth=0 for root files" `
            -Expected 0 `
            -Actual $logoPng.depth
        $missionDoc = $docs | Where-Object { $_.name -eq 'mission' }
        Assert-Equal -Name "ProductAPI returns type=md for markdown files" `
            -Expected "md" `
            -Actual $missionDoc.type
        $briefingPrContext = $docs | Where-Object { $_.name -eq 'briefing/pr-context' }
        Assert-Equal -Name "ProductAPI returns depth=1 for nested files" `
            -Expected 1 `
            -Actual $briefingPrContext.depth
        Assert-True -Name "ProductAPI excludes .gitkeep files" `
            -Condition (-not ($docs.filename -contains 'briefing/.gitkeep')) `
            -Message ".gitkeep should be excluded from product list"

        # JSON document support tests
        $configJson = $docs | Where-Object { $_.name -eq 'config.json' }
        Assert-True -Name "ProductAPI includes JSON files in list" `
            -Condition ($null -ne $configJson) `
            -Message "JSON file config.json missing from product list"
        Assert-Equal -Name "ProductAPI returns type=json for JSON files" `
            -Expected "json" `
            -Actual $configJson.type
        Assert-Equal -Name "ProductAPI retains .json extension in name" `
            -Expected "config.json" `
            -Actual $configJson.name

        $jsonDoc = Get-ProductDocument -Name "config.json"
        Assert-True -Name "ProductAPI loads JSON doc by name" `
            -Condition ($jsonDoc.success -eq $true -and $jsonDoc.content -match 'key') `
            -Message "JSON doc config.json could not be loaded"

        # .md takes priority over .json when both exist (mission.md + mission.json)
        $missionResolved = Get-ProductDocument -Name "mission"
        Assert-True -Name "ProductAPI resolves .md over .json when both exist" `
            -Condition ($missionResolved.success -eq $true -and $missionResolved.content -match 'Mission') `
            -Message "Expected mission.md content when requesting by base name"

        # Explicit .json route loads JSON even when .md exists
        $missionJsonDoc = Get-ProductDocument -Name "mission.json"
        Assert-True -Name "ProductAPI loads explicit .json route when .md also exists" `
            -Condition ($missionJsonDoc.success -eq $true -and $missionJsonDoc.content -match 'Mission JSON') `
            -Message "Expected mission.json content when requested explicitly"

        # ── Text file (.txt) support tests ──

        $notesTxt = $docs | Where-Object { $_.name -eq 'notes.txt' }
        Assert-True -Name "ProductAPI includes .txt files in list" `
            -Condition ($null -ne $notesTxt) `
            -Message "Text file notes.txt missing from product list"
        Assert-Equal -Name "ProductAPI returns type=txt for .txt files" `
            -Expected "txt" `
            -Actual $notesTxt.type
        Assert-Equal -Name "ProductAPI retains .txt extension in name" `
            -Expected "notes.txt" `
            -Actual $notesTxt.name

        $txtDoc = Get-ProductDocument -Name "notes.txt"
        Assert-True -Name "ProductAPI loads .txt doc by name" `
            -Condition ($txtDoc.success -eq $true -and $txtDoc.content -match 'Plain text content') `
            -Message "Text doc notes.txt could not be loaded"

        # ── Image file type detection tests ──

        $screenshotJpg = $docs | Where-Object { $_.name -eq 'screenshot.jpg' }
        Assert-True -Name "ProductAPI includes .jpg files in list" `
            -Condition ($null -ne $screenshotJpg) `
            -Message "Image file screenshot.jpg missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .jpg files" `
            -Expected "image" `
            -Actual $screenshotJpg.type

        $animationGif = $docs | Where-Object { $_.name -eq 'animation.gif' }
        Assert-True -Name "ProductAPI includes .gif files in list" `
            -Condition ($null -ne $animationGif) `
            -Message "Image file animation.gif missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .gif files" `
            -Expected "image" `
            -Actual $animationGif.type

        $diagramSvg = $docs | Where-Object { $_.name -eq 'diagram.svg' }
        Assert-True -Name "ProductAPI includes .svg files in list" `
            -Condition ($null -ne $diagramSvg) `
            -Message "Image file diagram.svg missing from product list"
        Assert-Equal -Name "ProductAPI returns type=image for .svg files" `
            -Expected "image" `
            -Actual $diagramSvg.type

        Assert-Equal -Name "ProductAPI retains image extension in name" `
            -Expected "screenshot.jpg" `
            -Actual $screenshotJpg.name

        # ── True binary files still classified as binary ──

        $documentPdf = $docs | Where-Object { $_.name -eq 'document.pdf' }
        Assert-True -Name "ProductAPI includes true binary files in list" `
            -Condition ($null -ne $documentPdf) `
            -Message "Binary file document.pdf missing from product list"
        Assert-Equal -Name "ProductAPI returns type=binary for unknown extensions" `
            -Expected "binary" `
            -Actual $documentPdf.type

        # ── Get-ProductDocumentRaw tests ──

        $rawPng = Get-ProductDocumentRaw -Name "logo.png"
        Assert-True -Name "ProductDocumentRaw finds .png file" `
            -Condition ($rawPng.Found -eq $true) `
            -Message "Get-ProductDocumentRaw did not find logo.png"
        Assert-Equal -Name "ProductDocumentRaw returns image/png MIME type" `
            -Expected "image/png" `
            -Actual $rawPng.MimeType
        Assert-True -Name "ProductDocumentRaw returns binary data for .png" `
            -Condition ($null -ne $rawPng.BinaryData -and $rawPng.BinaryData.Length -gt 0) `
            -Message "Expected non-empty BinaryData for logo.png"

        $rawJpg = Get-ProductDocumentRaw -Name "screenshot.jpg"
        Assert-Equal -Name "ProductDocumentRaw returns image/jpeg MIME type for .jpg" `
            -Expected "image/jpeg" `
            -Actual $rawJpg.MimeType
        Assert-True -Name "ProductDocumentRaw returns binary data for .jpg" `
            -Condition ($null -ne $rawJpg.BinaryData -and $rawJpg.BinaryData.Length -gt 0) `
            -Message "Expected non-empty BinaryData for screenshot.jpg"

        $rawGif = Get-ProductDocumentRaw -Name "animation.gif"
        Assert-Equal -Name "ProductDocumentRaw returns image/gif MIME type" `
            -Expected "image/gif" `
            -Actual $rawGif.MimeType

        $rawSvg = Get-ProductDocumentRaw -Name "diagram.svg"
        Assert-True -Name "ProductDocumentRaw finds .svg file" `
            -Condition ($rawSvg.Found -eq $true) `
            -Message "Get-ProductDocumentRaw did not find diagram.svg"
        Assert-Equal -Name "ProductDocumentRaw returns image/svg+xml MIME type" `
            -Expected "image/svg+xml" `
            -Actual $rawSvg.MimeType
        Assert-True -Name "ProductDocumentRaw returns text content for .svg (not binary)" `
            -Condition ($null -ne $rawSvg.TextContent -and $rawSvg.TextContent -match '<svg') `
            -Message "Expected SVG text content, not binary data"
        Assert-True -Name "ProductDocumentRaw does not return binary data for .svg" `
            -Condition ($null -eq $rawSvg.BinaryData) `
            -Message "SVG should use TextContent, not BinaryData"

        $rawTxt = Get-ProductDocumentRaw -Name "notes.txt"
        Assert-True -Name "ProductDocumentRaw finds .txt file" `
            -Condition ($rawTxt.Found -eq $true) `
            -Message "Get-ProductDocumentRaw did not find notes.txt"
        Assert-Equal -Name "ProductDocumentRaw returns text/plain MIME type for .txt" `
            -Expected "text/plain; charset=utf-8" `
            -Actual $rawTxt.MimeType
        Assert-True -Name "ProductDocumentRaw returns text content for .txt" `
            -Condition ($null -ne $rawTxt.TextContent -and $rawTxt.TextContent -match 'Plain text content') `
            -Message "Expected text content for notes.txt"

        $rawMissing = Get-ProductDocumentRaw -Name "nonexistent.png"
        Assert-True -Name "ProductDocumentRaw returns Found=false for missing file" `
            -Condition ($rawMissing.Found -eq $false) `
            -Message "Expected Found=false for nonexistent file"

        $rawTraversal = Get-ProductDocumentRaw -Name "../secrets.png"
        Assert-True -Name "ProductDocumentRaw blocks path traversal" `
            -Condition ($rawTraversal.Found -eq $false) `
            -Message "Path traversal should return not found"

        # ═════════════════════════════════════════════════════════════════
        # Get-WorkflowStatus — script-phase probe + process-type filter
        # Regression tests for #244: Overview stuck on Task Group Expansion
        # ═════════════════════════════════════════════════════════════════

        # Set up a fresh, isolated workspace for workflow status tests so
        # state doesn't leak into the doc tests above.
        $workflowTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-workflow-status-$([guid]::NewGuid().ToString().Substring(0,8))"
        $workflowBotRoot  = Join-Path $workflowTestRoot ".bot"

        # Discover-Workflows now consults <DOTBOT_HOME>/content/workflows/ as
        # the framework tier. The user's installed dotbot ships many workflows
        # which would shadow this test's project-tier 'test-flow' under the
        # alphabetic-first fallback. Point DOTBOT_HOME at an empty path so the
        # framework tier resolves to nothing and the test remains hermetic.
        $savedDotbotHomeWorkflowStatus = $env:DOTBOT_HOME
        $env:DOTBOT_HOME = Join-Path $workflowTestRoot "no-framework"
        $workflowControl  = Join-Path $workflowBotRoot ".control"
        $workflowSettings = Join-Path $workflowBotRoot "settings"
        $workflowTasksDir = Join-Path $workflowBotRoot "workspace\tasks"
        $workflowProductDir = Join-Path $workflowBotRoot "workspace\product"
        $workflowDecisionsDir = Join-Path $workflowBotRoot "workspace\decisions"

        foreach ($d in @($workflowControl, (Join-Path $workflowControl 'processes'), $workflowSettings, $workflowProductDir, $workflowDecisionsDir)) {
            New-Item -Path $d -ItemType Directory -Force | Out-Null
        }
        # Create the full canonical task pipeline dir set (matches
        # WorkflowManifest.psm1 Clear-WorkspaceTaskDirs).
        foreach ($td in @('todo','needs-input','in-progress','done','skipped','cancelled','split')) {
            New-Item -Path (Join-Path $workflowTasksDir $td) -ItemType Directory -Force | Out-Null
        }

        # Mark the first three phases complete via disk artifacts
        Set-Content -Path (Join-Path $workflowProductDir 'mission.md') -Value '# Mission' -Encoding UTF8
        Set-Content -Path (Join-Path $workflowProductDir 'tech-stack.md') -Value '# Tech' -Encoding UTF8
        Set-Content -Path (Join-Path $workflowProductDir 'entity-model.md') -Value '# Entities' -Encoding UTF8
        Set-Content -Path (Join-Path $workflowProductDir 'task-groups.json') -Value '{"groups":[]}' -Encoding UTF8
        Set-Content -Path (Join-Path $workflowDecisionsDir 'dec-0001.md') -Value '# Decision 1' -Encoding UTF8

        # PR-3 deletion removed the legacy settings.workflow.phases fallback
        # in Get-WorkflowStatus. Tests now go through Get-ActiveWorkflowManifest,
        # which requires a workflow.json.
        $workflowManifestDir = Join-Path $workflowBotRoot "content" "workflows" "test-flow"
        New-Item -Path $workflowManifestDir -ItemType Directory -Force | Out-Null
        $workflowManifestJson = @'
{
  "name": "test-flow",
  "version": "1.0",
  "description": "Test manifest for Get-WorkflowStatus integration",
  "tasks": [
    {
      "name": "Product Documents",
      "id": "product-documents",
      "type": "prompt",
      "outputs": ["mission.md", "tech-stack.md", "entity-model.md"]
    },
    {
      "name": "Generate Decisions",
      "id": "generate-decisions",
      "type": "prompt",
      "outputs_dir": "decisions",
      "min_output_count": 1
    },
    {
      "name": "Task Groups",
      "id": "task-groups",
      "type": "prompt",
      "outputs": ["task-groups.json"]
    },
    {
      "name": "Task Group Expansion",
      "id": "task-group-expansion",
      "type": "script",
      "script": "Expand-TaskGroups.ps1",
      "outputs_dir": "tasks/todo",
      "min_output_count": 1,
      "commit": {
        "paths": ["workspace/tasks/"]
      }
    }
  ]
}
'@
        Set-Content -Path (Join-Path $workflowManifestDir 'workflow.json') -Value $workflowManifestJson -Encoding UTF8
        Set-Content -Path (Join-Path $workflowSettings 'settings.default.json') -Value '{}' -Encoding UTF8

        # Get-WorkflowStatus imports $BotRoot/src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1
        # and that module imports ManifestCondition.psm1 from the same directory.
        # Copy both helpers (plus their manifests) into the test bot root so the
        # integration test can run.
        $runtimeModulesDir = Join-Path $workflowBotRoot "src/runtime/Modules"
        New-Item -Path $runtimeModulesDir -ItemType Directory -Force | Out-Null
        $repoRootForTest = Split-Path $PSScriptRoot -Parent
        $realRuntimeModules = Join-Path $repoRootForTest "src/runtime/Modules"
        foreach ($leaf in @('WorkflowManifest.psm1','WorkflowManifest.psd1','ManifestCondition.psm1','ManifestCondition.psd1')) {
            $src = Join-Path $realRuntimeModules $leaf
            if (Test-Path $src) { Copy-Item -Path $src -Destination $runtimeModulesDir -Force }
        }

        # Re-initialize ProductAPI against the isolated workflow test root
        Initialize-ProductAPI -BotRoot $workflowBotRoot -ControlDir $workflowControl

        # Helper: invoke the module-private Resolve-PhaseStatusFromOutputs
        # directly. It's not exported so we use module-scope invocation.
        $productApiModuleObj = Get-Module ProductAPI
        $resolvePhaseStatus = {
            param($Phase, $BotRoot)
            Resolve-PhaseStatusFromOutputs -Phase $Phase -BotRoot $BotRoot
        }

        # ── Defect 2: script-phase probe (Resolve-PhaseStatusFromOutputs) ──

        $scriptPhaseCommitTasks = [pscustomobject]@{
            id = 'task-group-expansion'
            name = 'Task Group Expansion'
            type = 'script'
            script = 'Expand-TaskGroups.ps1'
            commit = [pscustomobject]@{ paths = @('workspace/tasks/') }
        }

        # Case A: entirely empty pipeline dirs → pending (was: pending — same)
        $statusEmpty = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: empty tasks/ → pending" `
            -Expected "pending" -Actual $statusEmpty

        # Case B: a task file in tasks/todo/ → completed
        # (This is the #244 bug: before the fix, returned "pending" because
        # Get-ChildItem -File on the tasks/ parent had no top-level files.)
        Set-Content -Path (Join-Path $workflowTasksDir 'todo/expanded-task-1.json') `
            -Value '{"id":"t1","name":"test"}' -Encoding UTF8
        $statusWithTodo = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/todo/ → completed (#244 regression)" `
            -Expected "completed" -Actual $statusWithTodo

        # Case C: task only in tasks/done/ (workflow task moved through pipeline) → completed
        Remove-Item (Join-Path $workflowTasksDir 'todo/expanded-task-1.json') -Force
        Set-Content -Path (Join-Path $workflowTasksDir 'done/expanded-task-1.json') `
            -Value '{"id":"t1","name":"test"}' -Encoding UTF8
        $statusWithDone = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/done/ → completed" `
            -Expected "completed" -Actual $statusWithDone
        Remove-Item (Join-Path $workflowTasksDir 'done/expanded-task-1.json') -Force

        # Case C2: task only in tasks/skipped/ → completed (pipeline-dir list
        # must stay aligned with the outputs_dir branch, which also counts
        # skipped + cancelled as evidence the phase ran).
        Set-Content -Path (Join-Path $workflowTasksDir 'skipped/expanded-task-s.json') `
            -Value '{"id":"ts","name":"skipped"}' -Encoding UTF8
        $statusWithSkipped = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/skipped/ → completed" `
            -Expected "completed" -Actual $statusWithSkipped
        Remove-Item (Join-Path $workflowTasksDir 'skipped/expanded-task-s.json') -Force

        # Case C3: task only in tasks/cancelled/ → completed
        Set-Content -Path (Join-Path $workflowTasksDir 'cancelled/expanded-task-c.json') `
            -Value '{"id":"tc","name":"cancelled"}' -Encoding UTF8
        $statusWithCancelled = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/cancelled/ → completed" `
            -Expected "completed" -Actual $statusWithCancelled
        Remove-Item (Join-Path $workflowTasksDir 'cancelled/expanded-task-c.json') -Force

        # Case C4: task only in tasks/needs-input/ → completed
        # (Split/needs-input are legitimate pipeline statuses per
        # WorkflowManifest.psm1 Clear-WorkspaceTaskDirs — must be recognized.)
        Set-Content -Path (Join-Path $workflowTasksDir 'needs-input/expanded-task-n.json') `
            -Value '{"id":"tn","name":"needs-input"}' -Encoding UTF8
        $statusWithNeedsInput = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/needs-input/ → completed" `
            -Expected "completed" -Actual $statusWithNeedsInput
        Remove-Item (Join-Path $workflowTasksDir 'needs-input/expanded-task-n.json') -Force

        # Case C5: task only in tasks/split/ → completed
        Set-Content -Path (Join-Path $workflowTasksDir 'split/expanded-task-sp.json') `
            -Value '{"id":"tsp","name":"split"}' -Encoding UTF8
        $statusWithSplit = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: task in tasks/split/ → completed" `
            -Expected "completed" -Actual $statusWithSplit
        Remove-Item (Join-Path $workflowTasksDir 'split/expanded-task-sp.json') -Force

        # Case D: only .gitkeep sentinels in pipeline dirs → pending
        # (Sentinels must not trip the probe — that would mask a never-ran state.)
        Set-Content -Path (Join-Path $workflowTasksDir 'todo/.gitkeep') -Value '' -Encoding UTF8
        Set-Content -Path (Join-Path $workflowTasksDir 'done/.gitkeep') -Value '' -Encoding UTF8
        $statusOnlyGitkeep = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCommitTasks $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: only .gitkeep sentinels → pending" `
            -Expected "pending" -Actual $statusOnlyGitkeep
        Remove-Item (Join-Path $workflowTasksDir 'todo/.gitkeep') -Force
        Remove-Item (Join-Path $workflowTasksDir 'done/.gitkeep') -Force

        # Case E: general recursive case — a non-tasks commit path with
        # committed files nested two levels deep. The old probe used a flat
        # file count on the top-level dir and would have missed these.
        $customDir = Join-Path $workflowBotRoot 'workspace\custom\nested\deep'
        New-Item -Path $customDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $customDir 'artifact.txt') -Value 'hello' -Encoding UTF8
        $scriptPhaseCustom = [pscustomobject]@{
            id = 'custom-phase'
            name = 'Custom Phase'
            type = 'script'
            script = 'custom.ps1'
            commit = [pscustomobject]@{ paths = @('workspace/custom/') }
        }
        $statusRecursive = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCustom $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: nested artifacts → completed (recursive general case)" `
            -Expected "completed" -Actual $statusRecursive

        # Case F: general recursive case with only .gitkeep → pending
        Remove-Item (Join-Path $customDir 'artifact.txt') -Force
        Set-Content -Path (Join-Path $customDir '.gitkeep') -Value '' -Encoding UTF8
        $statusRecursiveGitkeep = & $productApiModuleObj $resolvePhaseStatus $scriptPhaseCustom $workflowBotRoot
        Assert-Equal -Name "Resolve-PhaseStatusFromOutputs: nested .gitkeep only → pending" `
            -Expected "pending" -Actual $statusRecursiveGitkeep

        # ── Integration: Get-WorkflowStatus full-stack ──

        # With a real task file and no process record, all four phases should
        # report completed via filesystem inference (P1 + P3 working end-to-end).
        Set-Content -Path (Join-Path $workflowTasksDir 'todo/expanded-task-1.json') `
            -Value '{"id":"t1","name":"test"}' -Encoding UTF8

        $procDir = Join-Path $workflowControl 'processes'

        $statusNoProc = Get-WorkflowStatus
        Assert-Equal -Name "Get-WorkflowStatus: overall status with 4 complete phases (no proc)" `
            -Expected "completed" -Actual $statusNoProc.status
        $expansionPhase = $statusNoProc.phases | Where-Object { $_.id -eq 'task-group-expansion' }
        Assert-Equal -Name "Get-WorkflowStatus: expansion phase completed via filesystem inference" `
            -Expected "completed" -Actual $expansionPhase.status
        Assert-True -Name "Get-WorkflowStatus: resume_from is null when all phases complete" `
            -Condition ([string]::IsNullOrEmpty($statusNoProc.resume_from)) `
            -Message "Expected resume_from null/empty, got '$($statusNoProc.resume_from)'"

        # ── Defect 1: process-type filter (P2) ──
        # P2 positive: task-runner process with matching workflow_name IS picked up.
        $matchingProc = @{
            id = 'proc-test-match'
            type = 'task-runner'
            workflow_name = 'test-flow'
            status = 'completed'
            phases = @()
        } | ConvertTo-Json -Depth 4
        Set-Content -Path (Join-Path $procDir 'proc-test-match.json') -Value $matchingProc -Encoding UTF8
        $statusMatch = Get-WorkflowStatus
        Assert-Equal -Name "Get-WorkflowStatus P2: task-runner proc with matching workflow_name → process_id populated" `
            -Expected 'proc-test-match' -Actual $statusMatch.process_id
        Assert-Equal -Name "Get-WorkflowStatus P2: workflow_name surfaced in response" `
            -Expected 'test-flow' -Actual $statusMatch.workflow_name
        Remove-Item (Join-Path $procDir 'proc-test-match.json') -Force

        # P2 regression: task-runner process with DIFFERENT workflow_name is ignored
        $otherProc = @{
            id = 'proc-test-other'
            type = 'task-runner'
            workflow_name = 'some-other-workflow'
            status = 'completed'
            phases = @()
        } | ConvertTo-Json -Depth 4
        Set-Content -Path (Join-Path $procDir 'proc-test-other.json') -Value $otherProc -Encoding UTF8
        $statusOther = Get-WorkflowStatus
        Assert-True -Name "Get-WorkflowStatus P2: task-runner proc with non-matching workflow_name → process_id null" `
            -Condition ([string]::IsNullOrEmpty($statusOther.process_id)) `
            -Message "Expected null process_id, got '$($statusOther.process_id)'"
        Remove-Item (Join-Path $procDir 'proc-test-other.json') -Force

        # Cleanup isolated workflow test root
        if (Test-Path $workflowTestRoot) {
            Remove-Item $workflowTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-TestProject -Path $productApiTestProject
        Remove-Module ProductAPI -ErrorAction SilentlyContinue
        if ($workflowTestRoot -and (Test-Path $workflowTestRoot)) {
            Remove-Item $workflowTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Get-Variable -Name savedDotbotHomeWorkflowStatus -ErrorAction SilentlyContinue) {
            if ($null -ne $savedDotbotHomeWorkflowStatus -and $savedDotbotHomeWorkflowStatus -ne '') {
                $env:DOTBOT_HOME = $savedDotbotHomeWorkflowStatus
            } elseif (Test-Path Env:DOTBOT_HOME) {
                Remove-Item Env:DOTBOT_HOME
            }
        }
    }
} else {
    Write-TestResult -Name "ProductAPI direct tests" -Status Skip -Message "Module not found at $productApiModule"
}
# ═══════════════════════════════════════════════════════════════════
# Dotbot.Logging MODULE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  Dotbot.Logging MODULE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$dotBotLogModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Logging/Dotbot.Logging.psd1"
if (Test-Path $dotBotLogModule) {
    # Use a dedicated temp directory for Dotbot.Logging tests
    $logTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-log-test-$([guid]::NewGuid().ToString().Substring(0,6))"
    $logTestControlDir = Join-Path $logTestDir ".control"
    $logTestLogsDir = Join-Path $logTestControlDir "logs"
    $logTestProcessesDir = Join-Path $logTestControlDir "processes"
    New-Item -Path $logTestProcessesDir -ItemType Directory -Force | Out-Null

    try {
        # Import module fresh
        Import-Module $dotBotLogModule -Force -DisableNameChecking

        # Test 1: Initialize-DotbotLog creates logs directory
        Initialize-DotbotLog -LogDir $logTestLogsDir -ControlDir $logTestControlDir -ProjectRoot $logTestDir
        Assert-True -Name "Dotbot.Logging: Initialize creates logs directory" `
            -Condition (Test-Path $logTestLogsDir) `
            -Message "Logs directory not created at $logTestLogsDir"

        # Test 2: Write-BotLog writes JSONL to log file
        Write-BotLog -Level Info -Message "Test log entry"
        $dateStamp = Get-Date -Format 'yyyy-MM-dd'
        $logFile = Join-Path $logTestLogsDir "dotbot-$dateStamp.jsonl"
        Assert-True -Name "Dotbot.Logging: Write-BotLog creates log file" `
            -Condition (Test-Path $logFile) `
            -Message "Log file not created at $logFile"

        # Test 3: Log file contains valid JSONL with correct schema
        $logLines = @(Get-Content $logFile)
        $lastLine = $logLines[-1] | ConvertFrom-Json
        $hasRequiredFields = ($null -ne $lastLine.ts) -and ($lastLine.level -eq 'Info') -and ($lastLine.msg -eq 'Test log entry') -and ($null -ne $lastLine.pid)
        Assert-True -Name "Dotbot.Logging: JSONL entry has correct schema (ts, level, msg, pid)" `
            -Condition $hasRequiredFields `
            -Message "Missing fields. Got: $($logLines[-1])"

        # Test 4: Level filtering — Debug below file_level=Warn should not write
        Initialize-DotbotLog -LogDir $logTestLogsDir -ControlDir $logTestControlDir -ProjectRoot $logTestDir -FileLevel Warn -ConsoleEnabled $false
        $lineCountBefore = (Get-Content $logFile).Count
        Write-BotLog -Level Debug -Message "Should be filtered out"
        $lineCountAfter = (Get-Content $logFile).Count
        Assert-True -Name "Dotbot.Logging: Debug filtered when FileLevel=Warn" `
            -Condition ($lineCountAfter -eq $lineCountBefore) `
            -Message "Expected $lineCountBefore lines, got $lineCountAfter"

        # Test 5: Activity.jsonl integration — Info+ events go to activity.jsonl
        Initialize-DotbotLog -LogDir $logTestLogsDir -ControlDir $logTestControlDir -ProjectRoot $logTestDir -ConsoleEnabled $false
        Write-BotLog -Level Info -Message "Activity test"
        $activityFile = Join-Path $logTestControlDir "activity.jsonl"
        Assert-True -Name "Dotbot.Logging: Info writes to activity.jsonl" `
            -Condition (Test-Path $activityFile) `
            -Message "activity.jsonl not created"

        if (Test-Path $activityFile) {
            $actLines = Get-Content $activityFile
            $actEntry = $actLines[-1] | ConvertFrom-Json
            $actOk = ($null -ne $actEntry.timestamp) -and ($actEntry.type -eq 'info') -and ($actEntry.message -eq 'Activity test')
            Assert-True -Name "Dotbot.Logging: activity.jsonl entry has correct schema" `
                -Condition $actOk `
                -Message "Bad activity entry: $($actLines[-1])"
        }

        # Test 6: Per-process activity log
        $testProcId = "proc-test01"
        $env:DOTBOT_PROCESS_ID = $testProcId
        Write-BotLog -Level Info -Message "Process activity test"
        $procLogFile = Join-Path $logTestProcessesDir "$testProcId.activity.jsonl"
        Assert-True -Name "Dotbot.Logging: Per-process activity log created" `
            -Condition (Test-Path $procLogFile) `
            -Message "Process activity log not created at $procLogFile"
        $env:DOTBOT_PROCESS_ID = $null

        # Test 7: Exception logging populates error and stack fields
        try { throw "Test exception for logging" } catch { $testException = $_ }
        Write-BotLog -Level Error -Message "Exception test" -Exception $testException
        $logLines = @(Get-Content $logFile)
        $errEntry = $logLines[-1] | ConvertFrom-Json
        Assert-True -Name "Dotbot.Logging: Exception populates error field" `
            -Condition ($errEntry.error -eq 'Test exception for logging') `
            -Message "Error field: $($errEntry.error)"

        # Test 8: Rotate-DotbotLog removes old files
        $oldLogFile = Join-Path $logTestLogsDir "dotbot-2020-01-01.jsonl"
        "old log entry" | Set-Content $oldLogFile
        (Get-Item $oldLogFile).LastWriteTime = (Get-Date).AddDays(-30)
        Rotate-DotbotLog
        Assert-True -Name "Dotbot.Logging: Rotation removes old log files" `
            -Condition (-not (Test-Path $oldLogFile)) `
            -Message "Old log file still exists"

        # Test 9: Write-Diag delegates to Write-BotLog (Debug level)
        $lineCountBefore = (Get-Content $logFile).Count
        Write-Diag "Diag test message"
        $lineCountAfter = (Get-Content $logFile).Count
        Assert-True -Name "Dotbot.Logging: Write-Diag writes to log file" `
            -Condition ($lineCountAfter -gt $lineCountBefore) `
            -Message "Write-Diag did not produce a log entry"

        if ($lineCountAfter -gt $lineCountBefore) {
            $diagEntry = @(Get-Content $logFile)[-1] | ConvertFrom-Json
            Assert-True -Name "Dotbot.Logging: Write-Diag uses Debug level" `
                -Condition ($diagEntry.level -eq 'Debug') `
                -Message "Expected Debug level, got $($diagEntry.level)"
        }

        # Test 10: Correlation ID included in log entries
        $env:DOTBOT_CORRELATION_ID = "corr-test1234"
        Write-BotLog -Level Info -Message "Correlation test"
        $corrEntry = @(Get-Content $logFile)[-1] | ConvertFrom-Json
        Assert-True -Name "Dotbot.Logging: Correlation ID included in log entry" `
            -Condition ($corrEntry.correlation_id -eq 'corr-test1234') `
            -Message "Expected corr-test1234, got $($corrEntry.correlation_id)"
        $env:DOTBOT_CORRELATION_ID = $null

    } finally {
        # Cleanup
        Remove-Module Dotbot.Logging -ErrorAction SilentlyContinue
        $env:DOTBOT_PROCESS_ID = $null
        $env:DOTBOT_CORRELATION_ID = $null
        if (Test-Path $logTestDir) { Remove-Item $logTestDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-TestResult -Name "Dotbot.Logging module tests" -Status Skip -Message "Module not found at $dotBotLogModule"
}

# ═══════════════════════════════════════════════════════════════════
# FRAMEWORK INTEGRITY — BEHAVIORAL TESTS
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FRAMEWORK INTEGRITY" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$repoRoot = Get-RepoRoot
$manifestModule = Join-Path $dotbotDir "src" "mcp" "modules" "Manifest.psm1"
$frameworkIntegrityModule = Join-Path $dotbotDir "src" "mcp" "modules" "FrameworkIntegrity.psm1"

if ((Test-Path $manifestModule) -and (Test-Path $frameworkIntegrityModule)) {
    Import-Module $manifestModule -Force
    Import-Module $frameworkIntegrityModule -Force

    # Build a minimal mock .bot/ in a temp directory with git
    $fiTestDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-fi-test-$(Get-Random)"
    New-Item -ItemType Directory -Path $fiTestDir -Force | Out-Null
    Push-Location $fiTestDir
    try {
        & git init --quiet 2>$null
        & git config user.email "test@test.com" 2>$null
        & git config user.name "Test" 2>$null

        # Fixture: dotbot-mcp.ps1 is the sentinel Test-FrameworkIntegrity probes
        # for pre-first-commit detection; .bot/go.ps1 is the tampering target.
        $protectedPaths = Get-FrameworkProtectedPaths
        New-Item -ItemType Directory -Path (Join-Path $fiTestDir ".bot/src/mcp") -Force | Out-Null
        Set-Content -Path (Join-Path $fiTestDir ".bot/src/mcp/dotbot-mcp.ps1") -Value "# mcp server" -Encoding UTF8
        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# go" -Encoding UTF8

        # ── New-DotbotManifest: generates valid JSON with correct hashes ──

        $mfPath = New-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths -Generator 'test'
        Assert-True -Name "New-DotbotManifest returns manifest path" `
            -Condition ($null -ne $mfPath -and (Test-Path $mfPath)) `
            -Message "Expected a valid file path, got $mfPath"

        $mfJson = $null
        try { $mfJson = Get-Content $mfPath -Raw | ConvertFrom-Json } catch {}
        Assert-True -Name "New-DotbotManifest produces valid JSON" `
            -Condition ($null -ne $mfJson) `
            -Message "Manifest file is not valid JSON"

        Assert-True -Name "Manifest has version field" `
            -Condition ($mfJson.version -eq 1) `
            -Message "Expected version=1, got $($mfJson.version)"
        Assert-True -Name "Manifest has generator field" `
            -Condition ($mfJson.generator -eq 'test') `
            -Message "Expected generator=test, got $($mfJson.generator)"
        Assert-True -Name "Manifest has files object" `
            -Condition ($null -ne $mfJson.files) `
            -Message "Missing files object"
        Assert-True -Name "Manifest has user_paths array" `
            -Condition ($null -ne $mfJson.user_paths) `
            -Message "Missing user_paths field"

        # Verify manifest hash matches Get-FrameworkContentHash (content hash,
        # not raw SHA256 — the manifest normalises CR bytes so CRLF/LF line-ending
        # drift between init and clone does not trigger a false tamper report).
        $goHash = Get-FrameworkContentHash -Path (Join-Path $fiTestDir ".bot/go.ps1")
        $manifestGoHash = $mfJson.files.'.bot/go.ps1'.sha256
        Assert-True -Name "Manifest hash matches Get-FrameworkContentHash" `
            -Condition ($manifestGoHash -eq $goHash) `
            -Message "Expected $goHash, got $manifestGoHash"

        # Verify both files are in the manifest
        $fileKeys = @($mfJson.files.PSObject.Properties.Name)
        Assert-True -Name "Manifest contains both protected files" `
            -Condition ($fileKeys.Count -eq 2) `
            -Message "Expected 2 files, got $($fileKeys.Count): $($fileKeys -join ', ')"

        # ── Test-DotbotManifest: clean state ──

        $cleanResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest clean: success=true" `
            -Condition ($cleanResult.success -eq $true) `
            -Message "Expected success, got reason=$($cleanResult.reason)"
        Assert-True -Name "Test-DotbotManifest clean: reason=clean" `
            -Condition ($cleanResult.reason -eq 'clean') `
            -Message "Expected reason=clean, got $($cleanResult.reason)"

        # ── Test-DotbotManifest: tampered file ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# TAMPERED" -Encoding UTF8
        $tamperResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest tampered: success=false" `
            -Condition ($tamperResult.success -eq $false) `
            -Message "Expected failure for tampered file"
        Assert-True -Name "Test-DotbotManifest tampered: reason=tampered" `
            -Condition ($tamperResult.reason -eq 'tampered') `
            -Message "Expected reason=tampered, got $($tamperResult.reason)"
        Assert-True -Name "Test-DotbotManifest tampered: flags correct file" `
            -Condition ($tamperResult.files -contains '.bot/go.ps1') `
            -Message "Expected .bot/go.ps1 in files, got $($tamperResult.files -join ', ')"
        # Restore
        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# go" -Encoding UTF8

        # ── Test-DotbotManifest: added file ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/src/extra.ps1") -Value "# extra" -Encoding UTF8
        $addResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest added: success=false" `
            -Condition ($addResult.success -eq $false) `
            -Message "Expected failure for added file"
        Assert-True -Name "Test-DotbotManifest added: flags the new file" `
            -Condition ($addResult.files -contains '.bot/src/extra.ps1') `
            -Message "Expected .bot/src/extra.ps1 in files, got $($addResult.files -join ', ')"
        Remove-Item (Join-Path $fiTestDir ".bot/src/extra.ps1") -Force

        # ── Test-DotbotManifest: deleted file ──

        Rename-Item (Join-Path $fiTestDir ".bot/go.ps1") (Join-Path $fiTestDir ".bot/go.ps1.bak")
        $delResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest deleted: success=false" `
            -Condition ($delResult.success -eq $false) `
            -Message "Expected failure for deleted file"
        Assert-True -Name "Test-DotbotManifest deleted: flags missing file" `
            -Condition ($delResult.files -contains '.bot/go.ps1') `
            -Message "Expected .bot/go.ps1 in files, got $($delResult.files -join ', ')"
        Rename-Item (Join-Path $fiTestDir ".bot/go.ps1.bak") (Join-Path $fiTestDir ".bot/go.ps1")

        # ── Test-DotbotManifest: missing manifest ──

        $savedManifest = Get-Content $mfPath -Raw
        Remove-Item $mfPath -Force
        $missingResult = Test-DotbotManifest -ProjectRoot $fiTestDir -ProtectedPaths $protectedPaths
        Assert-True -Name "Test-DotbotManifest missing-manifest: reason=missing-manifest" `
            -Condition ($missingResult.reason -eq 'missing-manifest') `
            -Message "Expected reason=missing-manifest, got $($missingResult.reason)"
        # Restore
        [System.IO.File]::WriteAllText($mfPath, $savedManifest, [System.Text.UTF8Encoding]::new($false))

        # ── Test-FrameworkIntegrity: pre-first-commit (no git history) ──

        $preCommitResult = Test-FrameworkIntegrity
        Assert-True -Name "Test-FrameworkIntegrity pre-first-commit: success=true" `
            -Condition ($preCommitResult.success -eq $true) `
            -Message "Expected success for pre-first-commit, got reason=$($preCommitResult.reason)"
        Assert-True -Name "Test-FrameworkIntegrity pre-first-commit: reason=pre-first-commit" `
            -Condition ($preCommitResult.reason -eq 'pre-first-commit') `
            -Message "Expected reason=pre-first-commit, got $($preCommitResult.reason)"

        # ── Test-FrameworkIntegrity: clean (after commit) ──

        & git add -A 2>$null
        & git commit -m "init" --quiet 2>$null
        $cleanInteg = Test-FrameworkIntegrity
        Assert-True -Name "Test-FrameworkIntegrity clean: success=true" `
            -Condition ($cleanInteg.success -eq $true) `
            -Message "Expected success, got reason=$($cleanInteg.reason) message=$($cleanInteg.message)"
        Assert-True -Name "Test-FrameworkIntegrity clean: reason=clean" `
            -Condition ($cleanInteg.reason -eq 'clean') `
            -Message "Expected reason=clean, got $($cleanInteg.reason)"

        # ── Test-FrameworkIntegrity: tampered (uncommitted edit) ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# TAMPERED" -Encoding UTF8
        $tamperedInteg = Test-FrameworkIntegrity
        Assert-True -Name "Test-FrameworkIntegrity tampered: success=false" `
            -Condition ($tamperedInteg.success -eq $false) `
            -Message "Expected failure for tampered file"
        Assert-True -Name "Test-FrameworkIntegrity tampered: reason=tampered" `
            -Condition ($tamperedInteg.reason -eq 'tampered') `
            -Message "Expected reason=tampered, got $($tamperedInteg.reason)"
        & git checkout -- ".bot/go.ps1" 2>$null

        # ── Invoke-FrameworkIntegrityGate: passes on clean ──

        $gateClean = Invoke-FrameworkIntegrityGate -ProjectRoot $fiTestDir
        Assert-True -Name "Invoke-FrameworkIntegrityGate clean: returns null" `
            -Condition ($null -eq $gateClean) `
            -Message "Expected null for clean state, got $($gateClean | ConvertTo-Json -Compress)"

        # ── Invoke-FrameworkIntegrityGate: blocks on tampered ──

        Set-Content -Path (Join-Path $fiTestDir ".bot/go.ps1") -Value "# TAMPERED" -Encoding UTF8
        $gateBlocked = Invoke-FrameworkIntegrityGate -ProjectRoot $fiTestDir -TaskId 'test-123'
        Assert-True -Name "Invoke-FrameworkIntegrityGate tampered: returns hashtable" `
            -Condition ($null -ne $gateBlocked) `
            -Message "Expected a blocking hashtable for tampered state"
        Assert-True -Name "Invoke-FrameworkIntegrityGate tampered: success=false" `
            -Condition ($gateBlocked.success -eq $false) `
            -Message "Expected success=false"
        Assert-True -Name "Invoke-FrameworkIntegrityGate tampered: includes task_id" `
            -Condition ($gateBlocked.task_id -eq 'test-123') `
            -Message "Expected task_id=test-123, got $($gateBlocked.task_id)"

    } finally {
        Pop-Location
        if (Test-Path $fiTestDir) { Remove-Item $fiTestDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-TestResult -Name "Framework integrity tests" -Status Skip -Message "Manifest.psm1 or FrameworkIntegrity.psm1 not found"
}

# ═══════════════════════════════════════════════════════════════════
# INBOX WATCHER MODULE TESTS
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- InboxWatcher Module ---" -ForegroundColor Cyan

$inboxWatcherModule = Join-Path $botDir "src/ui/modules/InboxWatcher.psm1"

if (Test-Path $inboxWatcherModule) {
    # Dotbot.Logging may have been removed by the preceding Dotbot.Logging test section — re-import it
    if (-not (Get-Module Dotbot.Logging)) {
        if (Test-Path $dotBotLogModule) { Import-Module $dotBotLogModule -Force }
    }

    $inboxTestRoot = Join-Path ([IO.Path]::GetTempPath()) "inbox-watcher-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        # ── Scaffolding ──────────────────────────────────────────────────
        $inboxBotRoot  = Join-Path $inboxTestRoot ".bot"
        $settingsDir   = Join-Path $inboxBotRoot "settings"
        $controlDir    = Join-Path $inboxBotRoot ".control"
        $inboxFolder   = Join-Path $inboxBotRoot "workspace" "inbox"
        $logPath       = Join-Path $controlDir "logs" "inbox-watcher.log"

        foreach ($dir in @($settingsDir, $controlDir, $inboxFolder)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $defaultSettingsPath  = Join-Path $settingsDir "settings.default.json"
        $overrideSettingsPath = Join-Path $controlDir "settings.json"

        # Phase 4 sources Layer 1 from <DOTBOT_HOME>/content/settings/, not
        # <BotRoot>/settings/. Writing through the .control overrides layer
        # keeps the per-test config injection working without depending on
        # the layer 1 location.
        function Write-InboxSettings {
            param([object]$Config)
            $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $overrideSettingsPath -Encoding UTF8
        }

        function Reset-InboxWatcher {
            try { Stop-InboxWatcher } catch {}
            Remove-Module InboxWatcher -ErrorAction SilentlyContinue
            Import-Module $inboxWatcherModule -Force
        }

        # Test 1. Config guard-rails — missing file, disabled, empty watchers, malformed JSON ─
        # None of these reach initialization so $Initialized never flips; one Reset at the end suffices.
        Import-Module $inboxWatcherModule -Force

        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op when settings file is missing" -Condition (-not $threw)

        Write-InboxSettings @{ file_listener = @{ enabled = $false; watchers = @() } }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op when file_listener is disabled" -Condition (-not $threw)

        Write-InboxSettings @{ file_listener = @{ enabled = $true; watchers = @() } }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op when watchers list is empty" -Condition (-not $threw)

        "{ not valid json" | Set-Content -LiteralPath $defaultSettingsPath -Encoding UTF8
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Guard-rail: no-op on malformed settings JSON" -Condition (-not $threw)

        Reset-InboxWatcher

        # Test 2. Override resilience — invalid override falls back; valid override replaces defaults ─
        Write-InboxSettings @{ file_listener = @{ enabled = $false; watchers = @() } }
        "{ bad" | Set-Content -LiteralPath $overrideSettingsPath -Encoding UTF8
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Override: invalid .control/settings.json falls back to defaults without throw" `
            -Condition (-not $threw)
        Remove-Item -LiteralPath $overrideSettingsPath -ErrorAction SilentlyContinue
        Reset-InboxWatcher

        Write-InboxSettings @{ file_listener = @{ enabled = $false; watchers = @() } }
        @{ file_listener = @{ enabled = $true; watchers = @() } } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $overrideSettingsPath -Encoding UTF8
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Override: valid .control/settings.json overrides disabled default without throw" `
            -Condition (-not $threw)
        Remove-Item -LiteralPath $overrideSettingsPath -ErrorAction SilentlyContinue
        Reset-InboxWatcher

        # Test 3. Path security — rooted path and path traversal both rejected silently ─────────
        $rootedPath = if ($IsWindows) { 'C:\Windows' } else { '/etc' }
        Write-InboxSettings @{
            file_listener = @{
                enabled  = $true
                watchers = @(
                    @{ folder = $rootedPath; events = @('created') }
                    @{ folder = '../../etc'; events = @('created') }
                )
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Security: rooted path and path-traversal folder both rejected without throw" `
            -Condition (-not $threw)
        Reset-InboxWatcher

        # Test 4. Folder & event validation — nonexistent folder skipped; unknown event warned ──
        Write-InboxSettings @{
            file_listener = @{
                enabled  = $true
                watchers = @(
                    @{ folder = 'does-not-exist'; events = @('created') }
                    @{ folder = 'inbox';          events = @('create')  }   # typo: 'create' not 'created'
                )
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Validation: nonexistent folder and unknown event type both skip without throw" `
            -Condition (-not $threw)
        Reset-InboxWatcher

        # Test 5. Config defaults — non-numeric max_concurrent and coalesce_window fall back ─────
        Write-InboxSettings @{
            file_listener = @{
                enabled                 = $true
                max_concurrent          = "bad"
                coalesce_window_seconds = "bad"
                watchers                = @(@{ folder = 'inbox'; events = @('created') })
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Defaults: non-numeric max_concurrent and coalesce_window fall back without throw" `
            -Condition (-not $threw)
        Reset-InboxWatcher

        # Test 6. Worker startup — valid config spawns worker, creates log, writes startup entry ─
        if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
        Write-InboxSettings @{
            file_listener = @{
                enabled  = $true
                watchers = @(@{ folder = 'inbox'; events = @('created') })
            }
        }
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Startup: worker starts for valid config without throw" -Condition (-not $threw)

        Start-Sleep -Milliseconds 600   # let worker runspace write its startup log entry
        Assert-True -Name "Startup: log file created by worker runspace" `
            -Condition (Test-Path -LiteralPath $logPath)
        if (Test-Path -LiteralPath $logPath) {
            $startupLog = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
            Assert-True -Name "Startup: log contains 'Worker started' message" `
                -Condition ($startupLog -match 'Worker started') `
                -Message "Expected 'Worker started' in log"
        }

        # Test 7. Lifecycle — re-entrancy guard, stop cleans up, re-init after stop ─────────────
        # Continues with the running worker from Test 6; no reset needed.
        $linesBefore = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue).Count
        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Start-Sleep -Milliseconds 300
        $linesAfter = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue).Count
        Assert-True -Name "Lifecycle: re-entrancy guard — second init spawns no additional workers" `
            -Condition ($linesAfter -eq $linesBefore) `
            -Message "Log grew after 2nd init: before=$linesBefore after=$linesAfter"

        $threw = $false
        try { Stop-InboxWatcher } catch { $threw = $true }
        Assert-True -Name "Lifecycle: Stop-InboxWatcher cleans up without throw" -Condition (-not $threw)

        $threw = $false
        try { Initialize-InboxWatcher -BotRoot $inboxBotRoot } catch { $threw = $true }
        Assert-True -Name "Lifecycle: re-init after stop succeeds (Initialized flag reset)" -Condition (-not $threw)
        Stop-InboxWatcher

        # ═══════════════════════════════════════════════════════════════
        # Behavioral tests — stub launcher satisfies the Test-Path guard
        # without needing a real dotbot install.
        # ═══════════════════════════════════════════════════════════════
        $stubLauncherDir = Join-Path $inboxBotRoot "src" "runtime" "Scripts"
        $null = New-Item -ItemType Directory -Force -Path $stubLauncherDir
        "# test stub — exits immediately" |
            Set-Content -LiteralPath (Join-Path $stubLauncherDir "Invoke-DotbotProcess.ps1") -Encoding UTF8

        $launchersDir = Join-Path $controlDir "launchers"

        function Get-NewLog {
            param([int]$After = 0)
            if (-not (Test-Path -LiteralPath $logPath)) { return '' }
            $lines = Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue
            if ($null -eq $lines -or $After -ge $lines.Count) { return '' }
            ($lines[$After..($lines.Count - 1)]) -join "`n"
        }
        function Get-LogLineCount {
            if (-not (Test-Path -LiteralPath $logPath)) { return 0 }
            @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue).Count
        }

        $behavSettings = @{
            file_listener = @{
                enabled                 = $true
                coalesce_window_seconds = 1
                watchers                = @(@{ folder = 'inbox'; events = @('created') })
            }
        }

        # Test 8. File detection + launcher creation ──────────────────────────────────────────
        # Worst-case timing: 2s WaitForChanged timeout + 1s coalesce + 2s next timeout + 2s buffer = 7s
        Write-InboxSettings $behavSettings
        Reset-InboxWatcher
        Initialize-InboxWatcher -BotRoot $inboxBotRoot
        Start-Sleep -Milliseconds 600   # let runspace reach WaitForChanged before dropping file
        $mark8 = Get-LogLineCount

        'hello' | Set-Content -LiteralPath (Join-Path $inboxFolder "detect-test.txt") -Encoding UTF8
        Start-Sleep -Seconds 7

        $log8 = Get-NewLog -After $mark8
        Assert-True -Name "Detection: worker detects and queues a newly created file" `
            -Condition ($log8 -match 'Queued.*detect-test\.txt') `
            -Message "Expected 'Queued.*detect-test.txt'; log: $log8"
        Assert-True -Name "Detection: task-creation launched after coalesce window" `
            -Condition ($log8 -match 'Launched:') `
            -Message "Expected 'Launched:' in log; got: $log8"
        $launchers8 = @(Get-ChildItem -Path $launchersDir -Filter "inbox-launcher-*.ps1" -File -ErrorAction SilentlyContinue)
        Assert-True -Name "Detection: inbox-launcher-*.ps1 wrapper created in .control/launchers/" `
            -Condition ($launchers8.Count -gt 0) `
            -Message "Expected inbox-launcher-*.ps1 in $launchersDir"
        if ($launchers8.Count -gt 0) {
            $wc8 = Get-Content -LiteralPath $launchers8[0].FullName -Raw -ErrorAction SilentlyContinue
            Assert-True -Name "Detection: launcher wrapper invokes Invoke-DotbotProcess.ps1 with -Type task-creation" `
                -Condition ($wc8 -match 'Invoke-DotbotProcess\.ps1' -and $wc8 -match 'task-creation') `
                -Message "Wrapper missing Invoke-DotbotProcess.ps1 or task-creation; content: $wc8"
        }
        Stop-InboxWatcher
        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # Test 9. Debounce + coalescing — shared watcher, two sequential sub-scenarios ──────────
        Write-InboxSettings @{
            file_listener = @{
                enabled                 = $true
                coalesce_window_seconds = 1
                watchers                = @(@{ folder = 'inbox'; events = @('created', 'updated') })
            }
        }
        Reset-InboxWatcher
        Initialize-InboxWatcher -BotRoot $inboxBotRoot
        Start-Sleep -Milliseconds 600

        # Sub-case A: same file touched twice within 5 s → only one Queued entry (debounced)
        $mark9a = Get-LogLineCount
        $debounceFile = Join-Path $inboxFolder "dedup.txt"
        'v1' | Set-Content -LiteralPath $debounceFile -Encoding UTF8    # first event — queued
        Start-Sleep -Milliseconds 800                                    # well within 5 s debounce window
        'v2' | Set-Content -LiteralPath $debounceFile -Encoding UTF8    # second event — debounced
        Start-Sleep -Seconds 7
        $log9a = Get-NewLog -After $mark9a
        Assert-True -Name "Debounce: same file touched twice within 5 s produces only one Queued entry" `
            -Condition (([regex]::Matches($log9a, 'Queued.*dedup\.txt')).Count -eq 1) `
            -Message "Expected 1 Queued entry for dedup.txt; log: $log9a"

        # Sub-case B: three files in quick succession → single batch launch for all three
        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $mark9b = Get-LogLineCount
        'a' | Set-Content -LiteralPath (Join-Path $inboxFolder "batch-a.txt") -Encoding UTF8
        Start-Sleep -Milliseconds 200
        'b' | Set-Content -LiteralPath (Join-Path $inboxFolder "batch-b.txt") -Encoding UTF8
        Start-Sleep -Milliseconds 200
        'c' | Set-Content -LiteralPath (Join-Path $inboxFolder "batch-c.txt") -Encoding UTF8
        Start-Sleep -Seconds 7
        $log9b = Get-NewLog -After $mark9b
        Assert-True -Name "Coalescing: three quick files trigger a single batch launch" `
            -Condition (([regex]::Matches($log9b, 'Launching task-creation')).Count -eq 1) `
            -Message "Expected 1 batch launch; log: $log9b"
        Assert-True -Name "Coalescing: batch launch reports all three files" `
            -Condition ($log9b -match 'Launching task-creation for 3 file') `
            -Message "Expected 'for 3 file' in launch log; got: $log9b"

        Stop-InboxWatcher
        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # Test 10. Filename sanitization + stop boundary ──────────────────────────────────────
        Write-InboxSettings $behavSettings
        Reset-InboxWatcher
        Initialize-InboxWatcher -BotRoot $inboxBotRoot
        Start-Sleep -Milliseconds 600

        # Sub-case A: backtick and dollar in filename are replaced with underscore in wrapper
        $mark10a = Get-LogLineCount
        $unsafeFile = Join-Path $inboxFolder 'test`$name.txt'
        'payload' | Set-Content -LiteralPath $unsafeFile -Encoding UTF8
        Start-Sleep -Seconds 7
        $log10a = Get-NewLog -After $mark10a
        Assert-True -Name "Sanitization: file with backtick and dollar is detected and queued" `
            -Condition ($log10a -match 'Queued') `
            -Message "Expected file to be detected; log: $log10a"
        $wrappers10 = @(Get-ChildItem -Path $launchersDir -Filter "inbox-launcher-*.ps1" -File -ErrorAction SilentlyContinue)
        if ($wrappers10.Count -gt 0) {
            $wc10 = Get-Content -LiteralPath $wrappers10[0].FullName -Raw -ErrorAction SilentlyContinue
            Assert-True -Name "Sanitization: wrapper replaces backtick and dollar with underscore" `
                -Condition ($wc10 -match 'test__name\.txt') `
                -Message "Expected 'test__name.txt' in wrapper; got: $wc10"
        } else {
            Write-TestResult -Name "Sanitization: wrapper replaces backtick and dollar with underscore" `
                -Status Skip -Message "No launcher wrapper found (file detection may have failed)"
        }

        # Sub-case B: no worker activity after Stop-InboxWatcher
        Stop-InboxWatcher
        Start-Sleep -Milliseconds 400   # let runspace fully exit
        $mark10b = Get-LogLineCount
        'payload' | Set-Content -LiteralPath (Join-Path $inboxFolder "after-stop.txt") -Encoding UTF8
        Start-Sleep -Seconds 6
        $log10b = Get-NewLog -After $mark10b
        Assert-True -Name "Stop boundary: no file events logged after Stop-InboxWatcher" `
            -Condition (-not ($log10b -match 'Queued|Launching')) `
            -Message "Worker still active after stop; new log: $log10b"

        Get-ChildItem -Path $launchersDir -Filter "inbox-*" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

    } finally {
        try { Stop-InboxWatcher } catch {}
        Remove-Module InboxWatcher -ErrorAction SilentlyContinue
        if ($inboxTestRoot -and (Test-Path $inboxTestRoot)) {
            Remove-Item $inboxTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} else {
    Write-TestResult -Name "InboxWatcher module exists" -Status Skip -Message "Module not found at $inboxWatcherModule"
}

# ═══════════════════════════════════════════════════════════════════
# --- Test-TaskIsMandatory (#213 mandatory halt) ---
# ═══════════════════════════════════════════════════════════════════

$workflowProcessScript = Join-Path $dotbotDir "src/runtime/Scripts/Invoke-WorkflowProcess.ps1"
if (Test-Path $workflowProcessScript) {
    # Extract Test-TaskIsMandatory via AST so we test the real function without running the full script
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($workflowProcessScript, [ref]$null, [ref]$null)
    $funcAst = $ast.FindAll({
        $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $args[0].Name -eq 'Test-TaskIsMandatory'
    }, $false) | Select-Object -First 1

    if ($funcAst) {
        Invoke-Expression $funcAst.Extent.Text

        # PSCustomObject: no optional property → mandatory
        $taskNoOptional = [PSCustomObject]@{ name = 'task-a' }
        Assert-True -Name "Test-TaskIsMandatory: missing optional → mandatory" `
            -Condition (Test-TaskIsMandatory $taskNoOptional) `
            -Message "Task without optional field should be treated as mandatory"

        # PSCustomObject: optional=$false → mandatory
        $taskOptionalFalse = [PSCustomObject]@{ name = 'task-b'; optional = $false }
        Assert-True -Name "Test-TaskIsMandatory: optional=false → mandatory" `
            -Condition (Test-TaskIsMandatory $taskOptionalFalse) `
            -Message "Task with optional=false should be treated as mandatory"

        # PSCustomObject: optional=$true → not mandatory
        $taskOptionalTrue = [PSCustomObject]@{ name = 'task-c'; optional = $true }
        Assert-True -Name "Test-TaskIsMandatory: optional=true → not mandatory" `
            -Condition (-not (Test-TaskIsMandatory $taskOptionalTrue)) `
            -Message "Task with optional=true should NOT be treated as mandatory"

        # Hashtable (IDictionary): optional=$true → not mandatory
        $dictTask = @{ name = 'task-d'; optional = $true }
        Assert-True -Name "Test-TaskIsMandatory: hashtable optional=true → not mandatory" `
            -Condition (-not (Test-TaskIsMandatory $dictTask)) `
            -Message "Hashtable task with optional=true should NOT be treated as mandatory"

        # Hashtable: optional missing → mandatory
        $dictTaskNoOpt = @{ name = 'task-e' }
        Assert-True -Name "Test-TaskIsMandatory: hashtable no optional → mandatory" `
            -Condition (Test-TaskIsMandatory $dictTaskNoOpt) `
            -Message "Hashtable task without optional should be treated as mandatory"
    } else {
        Write-TestResult -Name "Test-TaskIsMandatory function extraction" -Status Fail -Message "Function not found in $workflowProcessScript"
    }
} else {
    Write-TestResult -Name "Test-TaskIsMandatory tests" -Status Skip -Message "Invoke-WorkflowProcess.ps1 not found"
}

# New-WorkflowTask: tasks land under workflow-runs/<dir>/t_<id>.json with
# 'optional' under extensions.workflow (closed schema keeps the top level
# constrained). Initialize-WorkflowRun mints the run first.
$workflowManifestScript = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Workflow/Dotbot.Workflow.psd1"
if (Test-Path $workflowManifestScript) {
    $manifestTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-manifest-test-$(Get-Random)"
    New-Item -Path (Join-Path $manifestTmpDir "workspace\tasks") -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $manifestTmpDir ".control") -ItemType Directory -Force | Out-Null
    try {
        # Import both manifests so nested-module functions (New-WorkflowRunId,
        # New-TaskInstance, etc. from Dotbot.Task) are visible to
        # Initialize-WorkflowRun's call sites.
        $taskManifest = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Task/Dotbot.Task.psd1"
        Import-Module $taskManifest -Force -DisableNameChecking -Global
        Import-Module $workflowManifestScript -Force -DisableNameChecking -Global
        $run = Initialize-WorkflowRun -BotRoot $manifestTmpDir -WorkflowName 'test-wf' -StartedBy 'test:components'

        $optionalTask = @{ name = 'optional-step'; type = 'script'; script = 'scripts/foo.ps1'; optional = $true }
        $r1 = New-WorkflowTask -Run $run -TaskDef $optionalTask
        $taskJson = Get-Content -Path $r1.file_path -Raw | ConvertFrom-Json
        Assert-True -Name "New-WorkflowTask: optional=true lands under extensions.workflow.optional" `
            -Condition ($taskJson.extensions.workflow.optional -eq $true) `
            -Message "optional=true should land in extensions.workflow"

        $mandatoryTask = @{ name = 'mandatory-step'; type = 'script'; script = 'scripts/bar.ps1' }
        $r2 = New-WorkflowTask -Run $run -TaskDef $mandatoryTask
        $taskJson2 = Get-Content -Path $r2.file_path -Raw | ConvertFrom-Json
        $hasOptional = ($taskJson2.extensions -and $taskJson2.extensions.workflow -and `
                        $taskJson2.extensions.workflow.PSObject.Properties['optional'])
        Assert-True -Name "New-WorkflowTask: optional absent when not declared" `
            -Condition (-not $hasOptional) `
            -Message "optional should not be present when not declared"
    } catch {
        Write-TestResult -Name "New-WorkflowTask optional propagation" -Status Fail -Message $_.Exception.Message
    } finally {
        if (Test-Path $manifestTmpDir) { Remove-Item $manifestTmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-TestResult -Name "New-WorkflowTask optional propagation" -Status Skip -Message "WorkflowManifest.psm1 not found"
}

# Get-RecipeFolders recursive discovery (issue #406)
# Registry-installed workflows can layer skill folders nested several levels
# deep under recipes/skills/. The /api/workflows/installed enumeration must
# surface every leaf folder containing the marker file, not only top-level
# children, and must not surface bare intermediate folders.
if (Test-Path $workflowManifestScript) {
    $recipesTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-recipes-test-$(Get-Random)"
    $skillsRoot = Join-Path $recipesTmpDir "recipes\skills"
    try {
        New-Item -Path $skillsRoot -ItemType Directory -Force | Out-Null

        # Flat skills (top-level)
        New-Item -Path (Join-Path $skillsRoot "default-skill-a") -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $skillsRoot "default-skill-a\SKILL.md") -Value "# A" -Encoding UTF8
        New-Item -Path (Join-Path $skillsRoot "default-skill-b") -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $skillsRoot "default-skill-b\SKILL.md") -Value "# B" -Encoding UTF8

        # Nested skills under an intermediate folder with no SKILL.md of its own
        $nest1 = Join-Path $skillsRoot "overrides\group-1\phase-x"
        $nest2 = Join-Path $skillsRoot "overrides\group-1\phase-y"
        $nest3 = Join-Path $skillsRoot "overrides\group-2\phase-x"
        New-Item -Path $nest1 -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $nest1 "SKILL.md") -Value "# x" -Encoding UTF8
        New-Item -Path $nest2 -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $nest2 "SKILL.md") -Value "# y" -Encoding UTF8
        New-Item -Path $nest3 -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $nest3 "SKILL.md") -Value "# x2" -Encoding UTF8

        # Folder without a SKILL.md (must be filtered out)
        New-Item -Path (Join-Path $skillsRoot "not-a-skill") -ItemType Directory -Force | Out-Null

        Import-Module $workflowManifestScript -Force -DisableNameChecking
        $found = Get-RecipeFolders -BaseDir $skillsRoot -MarkerFile "SKILL.md"

        Assert-True -Name "Get-RecipeFolders surfaces top-level skills" `
            -Condition (($found -contains 'default-skill-a') -and ($found -contains 'default-skill-b')) `
            -Message "Expected default-skill-a and default-skill-b in results"

        Assert-True -Name "Get-RecipeFolders surfaces nested skills with forward-slash paths" `
            -Condition (($found -contains 'overrides/group-1/phase-x') -and ($found -contains 'overrides/group-1/phase-y') -and ($found -contains 'overrides/group-2/phase-x')) `
            -Message "Expected nested overrides/group-N/phase-X entries with forward slashes"

        Assert-True -Name "Get-RecipeFolders excludes intermediate folders without marker" `
            -Condition (($found -notcontains 'overrides') -and ($found -notcontains 'overrides/group-1') -and ($found -notcontains 'overrides/group-2')) `
            -Message "Bare intermediate folders should not be surfaced"

        Assert-True -Name "Get-RecipeFolders excludes folders missing the marker file" `
            -Condition ($found -notcontains 'not-a-skill') `
            -Message "Folder without SKILL.md must be omitted"

        # MaxDepth cap: a marker placed deeper than the cap must be ignored.
        $deep = Join-Path $skillsRoot "a\b\c\d\e"
        New-Item -Path $deep -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $deep "SKILL.md") -Value "# deep" -Encoding UTF8
        $capped = Get-RecipeFolders -BaseDir $skillsRoot -MarkerFile "SKILL.md" -MaxDepth 2
        Assert-True -Name "Get-RecipeFolders respects MaxDepth" `
            -Condition ($capped -notcontains 'a/b/c/d/e') `
            -Message "Marker beyond MaxDepth should not be surfaced"

        # Missing base dir returns an empty array, not a crash.
        $missing = Get-RecipeFolders -BaseDir (Join-Path $recipesTmpDir "no-such-dir") -MarkerFile "SKILL.md"
        Assert-True -Name "Get-RecipeFolders returns empty for missing base dir" `
            -Condition (@($missing).Count -eq 0) `
            -Message "Missing base dir should yield an empty array"
    } catch {
        Write-TestResult -Name "Get-RecipeFolders recursive discovery" -Status Fail -Message $_.Exception.Message
    } finally {
        if (Test-Path $recipesTmpDir) { Remove-Item $recipesTmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-TestResult -Name "Get-RecipeFolders recursive discovery" -Status Skip -Message "WorkflowManifest.psm1 not found"
}

# ═══════════════════════════════════════════════════════════════════
# Dotbot.Theme — animation/step/progress/grid (Theme.Animation.ps1)
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Dotbot.Theme animation helpers ---" -ForegroundColor Cyan

$animThemePath = Join-Path $botDir "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1"
if (Test-Path $animThemePath) {
    Import-Module $animThemePath -Force -DisableNameChecking -Global

    $expectedExports = @(
        'Format-Phosphor'
        'Get-DotbotSpinner'
        'Set-DotbotSpinner'
        'Get-DotbotBullet'
        'Set-DotbotBullet'
        'Write-Step'
        'Complete-Section'
        'Write-Shimmer'
        'Invoke-PhosphorJob'
        'Write-DotbotProgress'
        'Invoke-DotbotProgress'
        'Write-Grid'
        'Invoke-PhosphorScript'
    )
    $exported = (Get-Module Dotbot.Theme).ExportedCommands.Keys
    foreach ($name in $expectedExports) {
        Assert-True -Name "Dotbot.Theme exports $name" -Condition ($exported -contains $name) `
            -Message "Expected $name in exports"
    }

    # Format-Phosphor produces ANSI-colored text
    $fp = Format-Phosphor 'hello' 'Success'
    Assert-True -Name "Format-Phosphor wraps in ANSI" -Condition ($fp -match "`e\[38;2;\d+;\d+;\d+m") `
        -Message "Output: $fp"
    Assert-True -Name "Format-Phosphor preserves inner text" -Condition ($fp -like '*hello*') `
        -Message "Output: $fp"

    # Spinner / bullet enumeration
    $spinners = Get-DotbotSpinner
    Assert-True -Name "Get-DotbotSpinner returns multiple styles" -Condition (@($spinners).Count -ge 10) `
        -Message "Count: $(@($spinners).Count)"
    Assert-True -Name "Get-DotbotSpinner includes bars style" `
        -Condition (@($spinners.Id) -contains 'bars')

    $bullets = Get-DotbotBullet
    Assert-True -Name "Get-DotbotBullet returns multiple sets" -Condition (@($bullets).Count -ge 5) `
        -Message "Count: $(@($bullets).Count)"
    Assert-True -Name "Get-DotbotBullet includes scope set" `
        -Condition (@($bullets.Id) -contains 'scope')

    # Set-DotbotSpinner falls back gracefully for unknown names
    Set-DotbotSpinner 'this-style-does-not-exist'
    Set-DotbotSpinner 'braille'  # restore to a known style
    Assert-True -Name "Set-DotbotSpinner survives unknown style" -Condition $true

    # Invoke-PhosphorJob returns the scriptblock result
    $jobResult = Invoke-PhosphorJob 'unit test job' { 7 * 6 }
    Assert-Equal -Name "Invoke-PhosphorJob returns scriptblock value" -Expected 42 -Actual $jobResult

    # -Variables seeds the runspace before the scriptblock runs. Caller-scope
    # variables aren't visible inside the runspace, so this is the supported
    # way to pass closure data.
    $jobVarResult = Invoke-PhosphorJob 'job with vars' -Variables @{ A = 3; B = 4 } {
        $A * $A + $B * $B
    }
    Assert-Equal -Name "Invoke-PhosphorJob -Variables seeds runspace state" -Expected 25 -Actual $jobVarResult

    # Invoke-PhosphorScript restores cursor visibility + ProgressPreference
    $savedProgress = $global:ProgressPreference
    Invoke-PhosphorScript { }
    Assert-Equal -Name "Invoke-PhosphorScript restores ProgressPreference" `
        -Expected $savedProgress -Actual $global:ProgressPreference

    # Invoke-PhosphorScript restores it even when the body throws
    try {
        Invoke-PhosphorScript { throw 'boom' }
    } catch { }
    Assert-Equal -Name "Invoke-PhosphorScript restores ProgressPreference after throw" `
        -Expected $savedProgress -Actual $global:ProgressPreference
} else {
    Write-TestResult -Name "Dotbot.Theme animation helpers" -Status Skip `
        -Message "Dotbot.Theme module not found"
}

# ═══════════════════════════════════════════════════════════════════
# ContentResolver Module
# ═══════════════════════════════════════════════════════════════════

Write-Host "--- ContentResolver Module ---" -ForegroundColor Cyan

$resolverModulePath = Join-Path $repoRoot "src/runtime/Modules/ContentResolver/ContentResolver.psm1"
if (Test-Path $resolverModulePath) {
    Import-Module $resolverModulePath -Force -DisableNameChecking

    # Isolated fake project + fake framework under $TEMP. $env:DOTBOT_HOME
    # points the resolver at the fake framework so we don't depend on the
    # user's real install layout.
    $resolverProj = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-resolver-proj-$(New-Guid)"
    $resolverFw   = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-resolver-fw-$(New-Guid)"

    foreach ($dir in @(
        (Join-Path $resolverProj "content/agents/impl"),
        (Join-Path $resolverProj "content/agents/planner"),
        (Join-Path $resolverProj "content/prompts"),
        (Join-Path $resolverProj "content/skills/project-skill"),
        (Join-Path $resolverProj "hooks/verify"),
        (Join-Path $resolverFw   "content/agents/impl"),
        (Join-Path $resolverFw   "content/agents/reviewer"),
        (Join-Path $resolverFw   "content/agents/framework-only"),
        (Join-Path $resolverFw   "content/prompts"),
        (Join-Path $resolverFw   "content/skills/framework-skill"),
        (Join-Path $resolverFw   "src/hooks/verify")
    )) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    Set-Content -Path (Join-Path $resolverProj "content/prompts/100-single-session-task.md") -Value '# project prompt'
    Set-Content -Path (Join-Path $resolverProj "content/prompts/project-ref.md") -Value '# project ref prompt'
    Set-Content -Path (Join-Path $resolverProj "content/skills/project-skill/SKILL.md") -Value '# project skill'
    Set-Content -Path (Join-Path $resolverProj "hooks/verify/00-foo.ps1") -Value '# project foo'
    Set-Content -Path (Join-Path $resolverProj "hooks/verify/01-bar.ps1") -Value '# project bar'
    Set-Content -Path (Join-Path $resolverFw   "content/prompts/99-other.md") -Value '# framework other'
    Set-Content -Path (Join-Path $resolverFw   "content/prompts/98-framework.md") -Value '# framework prompt'
    Set-Content -Path (Join-Path $resolverFw   "content/prompts/framework-ref.md") -Value '# framework ref prompt'
    Set-Content -Path (Join-Path $resolverFw   "content/skills/framework-skill/SKILL.md") -Value '# framework skill'
    Set-Content -Path (Join-Path $resolverFw   "src/hooks/verify/01-bar.ps1") -Value '# framework bar (overridden)'
    Set-Content -Path (Join-Path $resolverFw   "src/hooks/verify/02-baz.ps1") -Value '# framework baz'

    $savedDotbotHome = $env:DOTBOT_HOME
    $savedXdgConfigHome = $env:XDG_CONFIG_HOME
    $savedAppData = $env:APPDATA
    $resolverUserConfigRoot = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-usercfg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        $env:DOTBOT_HOME = $resolverFw
        New-Item -ItemType Directory -Force -Path $resolverUserConfigRoot | Out-Null
        $env:XDG_CONFIG_HOME = $resolverUserConfigRoot
        $env:APPDATA = $resolverUserConfigRoot

        Assert-Equal -Name "Get-DotbotUserContentPath uses DOTBOT_HOME content root" `
            -Expected (Join-Path $resolverFw "content") `
            -Actual (Get-DotbotUserContentPath)

        # --- Resolve-DotbotContent ---

        Assert-Equal -Name "Resolve-DotbotContent: project-only item returns project path" `
            -Expected (Resolve-Path (Join-Path $resolverProj "content/agents/planner")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type agents -Name planner)

        Assert-Equal -Name "Resolve-DotbotContent: DOTBOT_HOME item returns framework path" `
            -Expected (Resolve-Path (Join-Path $resolverFw "content/agents/reviewer")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type agents -Name reviewer)

        Assert-Equal -Name "Resolve-DotbotContent: framework-only item returns framework path" `
            -Expected (Resolve-Path (Join-Path $resolverFw "content/agents/framework-only")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type agents -Name framework-only)

        Assert-Equal -Name "Resolve-DotbotContent: collision -- project wins" `
            -Expected (Resolve-Path (Join-Path $resolverProj "content/agents/impl")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type agents -Name impl)

        Assert-Equal -Name "Resolve-DotbotContent: missing item returns null" `
            -Expected $null `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type agents -Name nonexistent)

        Assert-Equal -Name "Resolve-DotbotContent: prompt file resolves to project layer" `
            -Expected (Resolve-Path (Join-Path $resolverProj "content/prompts/100-single-session-task.md")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type prompts -Name '100-single-session-task.md')

        Assert-Equal -Name "Resolve-DotbotContent: prompt file falls back to DOTBOT_HOME content" `
            -Expected (Resolve-Path (Join-Path $resolverFw "content/prompts/99-other.md")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type prompts -Name '99-other.md')

        Assert-Equal -Name "Resolve-DotbotContent: prompt file falls back to framework layer" `
            -Expected (Resolve-Path (Join-Path $resolverFw "content/prompts/98-framework.md")).Path `
            -Actual (Resolve-DotbotContent -BotRoot $resolverProj -Type prompts -Name '98-framework.md')

        # --- Resolve-DotbotContentReference ---

        Assert-Equal -Name "Resolve-DotbotContentReference: bare prompt resolves project layer" `
            -Expected (Resolve-Path (Join-Path $resolverProj "content/prompts/project-ref.md")).Path `
            -Actual (Resolve-DotbotContentReference -BotRoot $resolverProj -Type prompts -Reference 'project-ref')

        Assert-Equal -Name "Resolve-DotbotContentReference: prompt prefix falls back to DOTBOT_HOME layer" `
            -Expected (Resolve-Path (Join-Path $resolverFw "content/prompts/framework-ref.md")).Path `
            -Actual (Resolve-DotbotContentReference -BotRoot $resolverProj -Type prompts -Reference 'prompts/framework-ref.md')

        Assert-Equal -Name "Resolve-DotbotContentReference: agent content path resolves item directory" `
            -Expected (Resolve-Path (Join-Path $resolverProj "content/agents/planner")).Path `
            -Actual (Resolve-DotbotContentReference -BotRoot $resolverProj -Type agents -Reference '.bot/content/agents/planner/AGENT.md')

        Assert-Equal -Name "Resolve-DotbotContentReference: skill marker path resolves item directory" `
            -Expected (Resolve-Path (Join-Path $resolverProj "content/skills/project-skill")).Path `
            -Actual (Resolve-DotbotContentReference -BotRoot $resolverProj -Type skills -Reference 'content/skills/project-skill/SKILL.md')

        # --- Get-DotbotContentItems ---

        $agents = Get-DotbotContentItems -BotRoot $resolverProj -Type agents
        Assert-Equal -Name "Get-DotbotContentItems: agents returns 4 entries across project/DOTBOT_HOME" `
            -Expected 4 -Actual ($agents.Count)

        $impl = $agents | Where-Object Name -eq 'impl' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotContentItems: impl sourced as 'project' on collision" `
            -Expected 'project' -Actual $impl.Source

        $reviewer = $agents | Where-Object Name -eq 'reviewer' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotContentItems: reviewer sourced as 'framework'" `
            -Expected 'framework' -Actual $reviewer.Source

        $frameworkOnly = $agents | Where-Object Name -eq 'framework-only' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotContentItems: framework-only sourced as 'framework'" `
            -Expected 'framework' -Actual $frameworkOnly.Source

        $agentNames = ($agents | ForEach-Object Name) -join ','
        Assert-Equal -Name "Get-DotbotContentItems: agents sorted alphabetically" `
            -Expected 'framework-only,impl,planner,reviewer' -Actual $agentNames

        $prompts = Get-DotbotContentItems -BotRoot $resolverProj -Type prompts
        $otherPrompt = $prompts | Where-Object Name -eq '99-other.md' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotContentItems: prompt sourced from DOTBOT_HOME content" `
            -Expected 'framework' -Actual $otherPrompt.Source

        # Type with no items in any layer returns an empty array
        $stacks = Get-DotbotContentItems -BotRoot $resolverProj -Type stacks
        Assert-True -Name "Get-DotbotContentItems: empty type returns an array" `
            -Condition ($stacks -is [array]) `
            -Message "Got type: $($stacks.GetType().FullName)"
        Assert-Equal -Name "Get-DotbotContentItems: empty type has 0 entries" `
            -Expected 0 -Actual ($stacks.Count)

        # --- Get-DotbotHookChain ---

        $verify = Get-DotbotHookChain -BotRoot $resolverProj -Phase verify
        Assert-Equal -Name "Get-DotbotHookChain: verify returns 3 entries (00-foo, 01-bar, 02-baz)" `
            -Expected 3 -Actual ($verify.Count)

        $foo = $verify | Where-Object Name -eq '00-foo.ps1' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotHookChain: 00-foo.ps1 sourced as 'project' (project-only)" `
            -Expected 'project' -Actual $foo.Source

        $bar = $verify | Where-Object Name -eq '01-bar.ps1' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotHookChain: 01-bar.ps1 sourced as 'project' on collision (D2)" `
            -Expected 'project' -Actual $bar.Source

        $baz = $verify | Where-Object Name -eq '02-baz.ps1' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotHookChain: 02-baz.ps1 sourced as 'framework' (framework-only still runs)" `
            -Expected 'framework' -Actual $baz.Source

        $hookNames = ($verify | ForEach-Object Name) -join ','
        Assert-Equal -Name "Get-DotbotHookChain: verify sorted by filename (matches numeric prefix order)" `
            -Expected '00-foo.ps1,01-bar.ps1,02-baz.ps1' -Actual $hookNames

        # Empty phase returns an empty array, not $null
        $devChain = Get-DotbotHookChain -BotRoot $resolverProj -Phase dev
        Assert-True -Name "Get-DotbotHookChain: empty phase returns an array" `
            -Condition ($devChain -is [array]) `
            -Message "Got type: $($devChain.GetType().FullName)"
        Assert-Equal -Name "Get-DotbotHookChain: empty phase has 0 entries" `
            -Expected 0 -Actual ($devChain.Count)

        New-Item -ItemType Directory -Force -Path (Join-Path $resolverFw "content/stacks/base/hooks/verify") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $resolverFw "content/stacks/child") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $resolverProj ".control") | Out-Null
        '{"name":"base","description":"Base test stack"}' | Set-Content -Path (Join-Path $resolverFw "content/stacks/base/manifest.json")
        '{"name":"child","description":"Child test stack","extends":"base"}' | Set-Content -Path (Join-Path $resolverFw "content/stacks/child/manifest.json")
        "# stack hook" | Set-Content -Path (Join-Path $resolverFw "content/stacks/base/hooks/verify/03-stack.ps1")
        '{"stacks":["child"]}' | Set-Content -Path (Join-Path $resolverProj ".control/settings.json")

        $activeStacks = Get-DotbotActiveStackChain -BotRoot $resolverProj
        Assert-Equal -Name "Get-DotbotActiveStackChain: includes inherited parent before selected child" `
            -Expected 'base,child' -Actual (($activeStacks | ForEach-Object Name) -join ',')
        $verifyWithStack = Get-DotbotHookChain -BotRoot $resolverProj -Phase verify
        $stackHook = $verifyWithStack | Where-Object Name -eq '03-stack.ps1' | Select-Object -First 1
        Assert-Equal -Name "Get-DotbotHookChain: active stack hook participates without materialization" `
            -Expected 'stack:base' -Actual $stackHook.Source

        Remove-Item -LiteralPath (Join-Path $resolverProj ".control/settings.json") -Force
        $resolverUserSettingsDir = Join-Path $resolverUserConfigRoot "dotbot"
        New-Item -ItemType Directory -Force -Path $resolverUserSettingsDir | Out-Null
        '{"stacks":["child"]}' | Set-Content -Path (Join-Path $resolverUserSettingsDir "user-settings.json")

        $activeStacksFromUserSettings = Get-DotbotActiveStackChain -BotRoot $resolverProj
        Assert-Equal -Name "Get-DotbotActiveStackChain: reads stacks from merged user settings" `
            -Expected 'base,child' -Actual (($activeStacksFromUserSettings | ForEach-Object Name) -join ',')

    } finally {
        if ($null -ne $savedDotbotHome -and $savedDotbotHome -ne '') {
            $env:DOTBOT_HOME = $savedDotbotHome
        } elseif (Test-Path Env:DOTBOT_HOME) {
            Remove-Item Env:DOTBOT_HOME
        }
        if ($null -ne $savedXdgConfigHome -and $savedXdgConfigHome -ne '') {
            $env:XDG_CONFIG_HOME = $savedXdgConfigHome
        } elseif (Test-Path Env:XDG_CONFIG_HOME) {
            Remove-Item Env:XDG_CONFIG_HOME
        }
        if ($null -ne $savedAppData -and $savedAppData -ne '') {
            $env:APPDATA = $savedAppData
        } elseif (Test-Path Env:APPDATA) {
            Remove-Item Env:APPDATA
        }
        Remove-Item $resolverProj -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $resolverFw   -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $resolverUserConfigRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

} else {
    Write-TestResult -Name "ContentResolver module" -Status Skip `
        -Message "ContentResolver module not found at $resolverModulePath"
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 4 — init shrinks to .bot/workspace/ + .bot/.gitignore only
# Bare init produces no other children. -Workflow / -Stack materialise
# valid project-tier effective content only when the framework source ships overrides.
# Init never writes outside .bot/ (.mcp.json, ~/.claude.json, .vscode/, etc).
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Phase 4: dotbot init footprint ---" -ForegroundColor Cyan

$phase4Project = New-TestProject -Prefix "dotbot-phase4-bare"
$phase4InitScript = Join-Path $dotbotDir "src/cli/init-project.ps1"
try {
    Push-Location $phase4Project
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-Null
    $phase4ExitBare = $LASTEXITCODE
    Pop-Location

    Assert-Equal -Name "Phase 4: bare init exits 0" -Expected 0 -Actual $phase4ExitBare

    $p4Bot = Join-Path $phase4Project ".bot"
    Assert-PathExists -Name "Phase 4: .bot/ created" -Path $p4Bot
    Assert-PathExists -Name "Phase 4: .bot/workspace/ created" -Path (Join-Path $p4Bot "workspace")
    Assert-PathExists -Name "Phase 4: .bot/.gitignore created" -Path (Join-Path $p4Bot ".gitignore")

    # The strict claim: only workspace/ and .gitignore exist directly under .bot/.
    $p4Children = @(Get-ChildItem -Path $p4Bot -Force | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-Equal -Name "Phase 4: .bot/ children == { .gitignore, workspace }" `
        -Expected ".gitignore,workspace" -Actual ($p4Children -join ',')

    # Anything outside .bot/ must not have been touched.
    Assert-PathNotExists -Name "Phase 4: no .mcp.json created" -Path (Join-Path $phase4Project ".mcp.json")
    Assert-PathNotExists -Name "Phase 4: no .claude/ created"  -Path (Join-Path $phase4Project ".claude")
    Assert-PathNotExists -Name "Phase 4: no .codex/ created"   -Path (Join-Path $phase4Project ".codex")
    Assert-PathNotExists -Name "Phase 4: no .agents/ created"  -Path (Join-Path $phase4Project ".agents")
    Assert-PathNotExists -Name "Phase 4: no .gemini/ created"  -Path (Join-Path $phase4Project ".gemini")
    Assert-PathNotExists -Name "Phase 4: no .vscode/ created"  -Path (Join-Path $phase4Project ".vscode")
    Assert-PathNotExists -Name "Phase 4: no CLAUDE.md created" -Path (Join-Path $phase4Project "CLAUDE.md")
    Assert-PathNotExists -Name "Phase 4: no AGENTS.md created" -Path (Join-Path $phase4Project "AGENTS.md")
    Assert-PathNotExists -Name "Phase 4: no GEMINI.md created" -Path (Join-Path $phase4Project "GEMINI.md")
} finally {
    Remove-TestProject -Path $phase4Project
}

# -Workflow X must not add .bot/content/workflows/X/ when X ships no overrides/ tree.
$phase4WfProject = New-TestProject -Prefix "dotbot-phase4-wf"
try {
    Push-Location $phase4WfProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript -Workflow start-from-prompt 2>&1 | Out-Null
    $phase4WfExit = $LASTEXITCODE
    Pop-Location

    Assert-Equal -Name "Phase 4: init -Workflow start-from-prompt exits 0" -Expected 0 -Actual $phase4WfExit

    $p4WfBot = Join-Path $phase4WfProject ".bot"
    Assert-PathNotExists -Name "Phase 4: no .bot/content/workflows/start-from-prompt/ (workflow has no overrides/)" `
        -Path (Join-Path $p4WfBot "content" "workflows" "start-from-prompt")

    # The selection is recorded in .control/settings.json (lazy-created).
    $p4WfControl = Join-Path $p4WfBot ".control" "settings.json"
    Assert-PathExists -Name "Phase 4: .control/settings.json lazy-created when -Workflow passed" -Path $p4WfControl
    if (Test-Path $p4WfControl) {
        $p4WfSettings = Get-Content $p4WfControl -Raw | ConvertFrom-Json
        Assert-Equal -Name "Phase 4: .control/settings.json records active workflow" `
            -Expected "start-from-prompt" -Actual $p4WfSettings.workflow
    }
    Push-Location $phase4WfProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "src/cli/workflow-list.ps1") 2>&1 | Out-Null
    $phase4ListExit = $LASTEXITCODE
    Pop-Location
    Assert-Equal -Name "Phase 4: sparse project can execute framework-backed workflow-list" `
        -Expected 0 -Actual $phase4ListExit
} finally {
    Remove-TestProject -Path $phase4WfProject
}

# -Workflow X DOES add .bot/content/workflows/X/ when X declares overrides/.
# Build a synthetic workflow under a temporary DOTBOT_HOME so the assertion
# does not depend on the framework shipping such a workflow.
$phase4OvrProject = New-TestProject -Prefix "dotbot-phase4-ovr"
$phase4FakeHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-phase4-home-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$phase4PrevHome = $env:DOTBOT_HOME
try {
    # Seed the fake DOTBOT_HOME with the layout init needs: bin/dotbot.ps1,
    # content/workspace-template/, content/workflows/<name>/{workflow.json,overrides/}.
    New-Item -ItemType Directory -Path (Join-Path $phase4FakeHome "bin") -Force | Out-Null
    New-Item -ItemType File      -Path (Join-Path $phase4FakeHome "bin/dotbot.ps1") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $phase4FakeHome "content/workspace-template/tasks") -Force | Out-Null
    Copy-Item (Join-Path $dotbotDir "src") -Destination (Join-Path $phase4FakeHome "src") -Recurse -Force
    $fakeWfDir = Join-Path $phase4FakeHome "content/workflows/with-overrides"
    New-Item -ItemType Directory -Path (Join-Path $fakeWfDir "overrides/recipes/prompts") -Force | Out-Null
    '{"name":"with-overrides","description":"test fixture"}' | Set-Content (Join-Path $fakeWfDir "workflow.json")
    "override prompt content" | Set-Content (Join-Path $fakeWfDir "overrides/recipes/prompts/00-test.md")

    $env:DOTBOT_HOME = $phase4FakeHome
    $fakeInitScript = Join-Path $phase4FakeHome "src/cli/init-project.ps1"

    Push-Location $phase4OvrProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $fakeInitScript -Workflow with-overrides 2>&1 | Out-Null
    $phase4OvrExit = $LASTEXITCODE
    Pop-Location

    Assert-Equal -Name "Phase 4: init -Workflow with-overrides exits 0" -Expected 0 -Actual $phase4OvrExit
    $p4OvrBot = Join-Path $phase4OvrProject ".bot"
    Assert-PathExists -Name "Phase 4: .bot/content/workflows/with-overrides/ created when overrides/ ships" `
        -Path (Join-Path $p4OvrBot "content/workflows/with-overrides")
    Assert-PathExists -Name "Phase 4: override file copied verbatim into project tier" `
        -Path (Join-Path $p4OvrBot "content/workflows/with-overrides/recipes/prompts/00-test.md")
    Assert-PathExists -Name "Phase 4: materialised override retains workflow manifest" `
        -Path (Join-Path $p4OvrBot "content/workflows/with-overrides/workflow.json")

    Push-Location $phase4OvrProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $phase4FakeHome "src/cli/workflow-list.ps1") 2>&1 | Out-Null
    $phase4OvrListExit = $LASTEXITCODE
    Pop-Location
    Assert-Equal -Name "Phase 4: workflow with overrides remains discoverable in sparse project" `
        -Expected 0 -Actual $phase4OvrListExit
} finally {
    if ($null -ne $phase4PrevHome -and $phase4PrevHome -ne '') {
        $env:DOTBOT_HOME = $phase4PrevHome
    } elseif (Test-Path Env:DOTBOT_HOME) {
        Remove-Item Env:DOTBOT_HOME
    }
    Remove-TestProject -Path $phase4OvrProject
    Remove-Item $phase4FakeHome -Recurse -Force -ErrorAction SilentlyContinue
}

# --copy-runtime adds a project-local runtime checkout and the PATH shim prefers it
# over DOTBOT_HOME when invoked from anywhere under that project.
$phase4VendorProject = New-TestProject -Prefix "dotbot-phase4-vendor"
$phase4VendorSavedHome = $env:DOTBOT_HOME
try {
    Push-Location $phase4VendorProject
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript --copy-runtime 2>&1 | Out-Null
        $phase4VendorExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Assert-Equal -Name "Phase 4: init --copy-runtime exits 0" -Expected 0 -Actual $phase4VendorExit

    $p4VendorBot = Join-Path $phase4VendorProject ".bot"
    $p4VendorRoot = Join-Path $p4VendorBot "runtime"
    Assert-PathExists -Name "Phase 4: .bot/runtime created" -Path $p4VendorRoot
    Assert-PathExists -Name "Phase 4: project-local runtime CLI exists" -Path (Join-Path $p4VendorRoot "bin/dotbot.ps1")
    Assert-PathExists -Name "Phase 4: project-local runtime module exists" -Path (Join-Path $p4VendorRoot "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1")
    Assert-PathExists -Name "Phase 4: project-local runtime workspace template exists" -Path (Join-Path $p4VendorRoot "content/workspace-template")
    Assert-PathNotExists -Name "Phase 4: init --copy-runtime does not write runtime marker" -Path (Join-Path $p4VendorRoot ".dotbot-runtime.json")

    $p4VendorNested = Join-Path $phase4VendorProject "src/nested"
    New-Item -ItemType Directory -Path $p4VendorNested -Force | Out-Null

    Remove-Item Env:DOTBOT_HOME -ErrorAction SilentlyContinue
    $phase4Shim = Join-Path $dotbotDir "bin/shim/dotbot.ps1"
    Push-Location $p4VendorNested
    try {
        $phase4VendorStatusOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4Shim status -Json 2>&1 | Out-String
        $phase4VendorStatusExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Assert-Equal -Name "Phase 4: shim runs from project-local runtime without DOTBOT_HOME" `
        -Expected 0 -Actual $phase4VendorStatusExit `
        -Message "Output: $phase4VendorStatusOutput"
    $phase4VendorStatus = $null
    try { $phase4VendorStatus = $phase4VendorStatusOutput | ConvertFrom-Json -ErrorAction Stop } catch {}
    Assert-True -Name "Phase 4: project-local runtime status output parses" `
        -Condition ($null -ne $phase4VendorStatus) `
        -Message "Output: $phase4VendorStatusOutput"
    if ($null -ne $phase4VendorStatus) {
        Assert-Equal -Name "Phase 4: shim reports project-local dotbot_home" `
            -Expected ([System.IO.Path]::GetFullPath($p4VendorRoot)) -Actual ([System.IO.Path]::GetFullPath([string]$phase4VendorStatus.dotbot_home))
        Assert-Equal -Name "Phase 4: project-local runtime status sees initialized project" `
            -Expected $true -Actual $phase4VendorStatus.project.initialized
    }

    $p4NestedGit = Join-Path $phase4VendorProject "nested-git"
    New-Item -ItemType Directory -Path $p4NestedGit -Force | Out-Null
    & git -C $p4NestedGit init --quiet 2>&1 | Out-Null
    Remove-Item Env:DOTBOT_HOME -ErrorAction SilentlyContinue
    Push-Location $p4NestedGit
    try {
        $phase4NestedGitOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4Shim status -Json 2>&1 | Out-String
        $phase4NestedGitExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Assert-True -Name "Phase 4: project-local runtime discovery stops at nested .git" `
        -Condition ($phase4NestedGitExit -ne 0) `
        -Message "Expected no project-local runtime fallback past nested .git. Output: $phase4NestedGitOutput"
    Assert-True -Name "Phase 4: nested .git fallback still requires DOTBOT_HOME" `
        -Condition ($phase4NestedGitOutput -match 'DOTBOT_HOME is not set') `
        -Message "Output: $phase4NestedGitOutput"
} finally {
    if ($null -ne $phase4VendorSavedHome -and $phase4VendorSavedHome -ne '') {
        $env:DOTBOT_HOME = $phase4VendorSavedHome
    } elseif (Test-Path Env:DOTBOT_HOME) {
        Remove-Item Env:DOTBOT_HOME
    }
    Remove-TestProject -Path $phase4VendorProject
}

# `dotbot install runtime` installs into an existing initialized project without
# re-running init. Existing project-local runtimes prompt before replacement.
$phase4InstallProject = New-TestProject -Prefix "dotbot-phase4-install-runtime"
$phase4InstallSavedHome = $env:DOTBOT_HOME
$phase4LegacyRuntimeSource = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-legacy-runtime-$([guid]::NewGuid().ToString('N'))"
try {
    $env:DOTBOT_HOME = $dotbotDir
    Push-Location $phase4InstallProject
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-Null
        $phase4InstallInitExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal -Name "Phase 4: install runtime fixture init exits 0" `
        -Expected 0 -Actual $phase4InstallInitExit

    New-Item -ItemType Directory -Path (Join-Path $phase4LegacyRuntimeSource "bin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $phase4LegacyRuntimeSource "content/workspace-template") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $phase4LegacyRuntimeSource "src/cli") -Force | Out-Null
    '# fake runtime CLI' | Set-Content -LiteralPath (Join-Path $phase4LegacyRuntimeSource "bin/dotbot.ps1") -Encoding UTF8
    '{ "version": "legacy-test" }' | Set-Content -LiteralPath (Join-Path $phase4LegacyRuntimeSource "version.json") -Encoding UTF8
    '{ "legacy": true }' | Set-Content -LiteralPath (Join-Path $phase4LegacyRuntimeSource "src/cli/.dotbot-runtime.json") -Encoding UTF8

    $phase4Cli = Join-Path $dotbotDir "bin/dotbot.ps1"
    Push-Location $phase4InstallProject
    try {
        $phase4InstallOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4Cli install runtime --from $phase4LegacyRuntimeSource 2>&1 | Out-String
        $phase4InstallExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal -Name "Phase 4: dotbot install runtime exits 0" `
        -Expected 0 -Actual $phase4InstallExit `
        -Message "Output: $phase4InstallOutput"

    $phase4InstallBot = Join-Path $phase4InstallProject ".bot"
    $phase4InstallRoot = Join-Path $phase4InstallBot "runtime"
    Assert-PathExists -Name "Phase 4: dotbot install runtime creates runtime root" -Path $phase4InstallRoot
    Assert-PathExists -Name "Phase 4: dotbot install runtime creates project-local CLI" `
        -Path (Join-Path $phase4InstallRoot "bin/dotbot.ps1")
    $phase4VendoredLegacyMarkers = @(Get-ChildItem -LiteralPath $phase4InstallRoot -Force -Recurse -File -Filter ".dotbot-runtime.json" -ErrorAction SilentlyContinue)
    Assert-Equal -Name "Phase 4: dotbot install runtime removes legacy runtime marker" `
        -Expected 0 -Actual $phase4VendoredLegacyMarkers.Count
    Remove-Item -LiteralPath $phase4InstallRoot -Recurse -Force

    Push-Location $phase4InstallProject
    try {
        $phase4InstallRealOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4Cli install runtime 2>&1 | Out-String
        $phase4InstallRealExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal -Name "Phase 4: dotbot install runtime from real source exits 0" `
        -Expected 0 -Actual $phase4InstallRealExit `
        -Message "Output: $phase4InstallRealOutput"
    Assert-PathExists -Name "Phase 4: dotbot install runtime from real source keeps runtime root" -Path $phase4InstallRoot
    Assert-PathNotExists -Name "Phase 4: dotbot install runtime from real source does not write runtime marker" -Path (Join-Path $phase4InstallRoot ".dotbot-runtime.json")

    Push-Location $phase4InstallProject
    try {
        $phase4DeclineOutput = "n" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4Cli install runtime 2>&1 | Out-String
        $phase4DeclineExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal -Name "Phase 4: dotbot install runtime decline exits 0" `
        -Expected 0 -Actual $phase4DeclineExit `
        -Message "Output: $phase4DeclineOutput"
    Assert-True -Name "Phase 4: dotbot install runtime decline leaves runtime unchanged" `
        -Condition ($phase4DeclineOutput -match 'Runtime install unchanged') `
        -Message "Output: $phase4DeclineOutput"
    $phase4DeclineBackups = @(Get-ChildItem -LiteralPath $phase4InstallBot -Directory -Filter "runtime.backup-*" -ErrorAction SilentlyContinue)
    Assert-Equal -Name "Phase 4: declined runtime replacement creates no backup" `
        -Expected 0 -Actual $phase4DeclineBackups.Count

    Push-Location $phase4InstallProject
    try {
        $phase4ReplaceOutput = "yes" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4Cli install runtime 2>&1 | Out-String
        $phase4ReplaceExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal -Name "Phase 4: dotbot install runtime accepted replace exits 0" `
        -Expected 0 -Actual $phase4ReplaceExit `
        -Message "Output: $phase4ReplaceOutput"
    Assert-PathExists -Name "Phase 4: dotbot install runtime keeps runtime root after replace" -Path $phase4InstallRoot
    $phase4ReplaceBackups = @(Get-ChildItem -LiteralPath $phase4InstallBot -Directory -Filter "runtime.backup-*" -ErrorAction SilentlyContinue)
    Assert-True -Name "Phase 4: accepted runtime replacement creates backup" `
        -Condition ($phase4ReplaceBackups.Count -ge 1) `
        -Message "Output: $phase4ReplaceOutput"
} finally {
    if ($null -ne $phase4InstallSavedHome -and $phase4InstallSavedHome -ne '') {
        $env:DOTBOT_HOME = $phase4InstallSavedHome
    } elseif (Test-Path Env:DOTBOT_HOME) {
        Remove-Item Env:DOTBOT_HOME
    }
    Remove-TestProject -Path $phase4InstallProject
    Remove-Item $phase4LegacyRuntimeSource -Recurse -Force -ErrorAction SilentlyContinue
}

# `dotbot install skill|prompt|agent` installs versioned content from a
# marketplace-shaped source. Project installs land under .bot/content; global
# installs land under <DOTBOT_HOME>/content.
$phase4ContentProject = New-TestProject -Prefix "dotbot-phase4-install-content"
$phase4ContentMarketplace = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-marketplace-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$phase4ContentRegistryHome = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-registry-home-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$phase4GlobalAgentName = "global-agent-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$phase4ContentSavedHome = $env:DOTBOT_HOME
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $phase4ContentMarketplace "skills/code-review/v1") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $phase4ContentMarketplace "skills/code-review/v2") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $phase4ContentMarketplace "prompts/onboarding-interview/v2") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $phase4ContentMarketplace "agents/code-reviewer/v3") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $phase4ContentRegistryHome "registries/marketplace/skills/registry-review/v4") | Out-Null

    "---`nname: code-review`ndescription: Reviews code`nsource: github.com/example/marketplace/skills/code-review`nversion: 1`n---`nold skill" |
        Set-Content -Path (Join-Path $phase4ContentMarketplace "skills/code-review/v1/SKILL.md") -Encoding UTF8
    "---`nname: code-review`ndescription: Reviews code`nsource: github.com/example/marketplace/skills/code-review`nversion: 2`n---`nnew skill" |
        Set-Content -Path (Join-Path $phase4ContentMarketplace "skills/code-review/v2/SKILL.md") -Encoding UTF8
    "---`nsource: github.com/example/marketplace/prompts/onboarding-interview`nversion: 2`n---`nPrompt body" |
        Set-Content -Path (Join-Path $phase4ContentMarketplace "prompts/onboarding-interview/v2/onboarding-interview.md") -Encoding UTF8
    "---`nname: $phase4GlobalAgentName`nsource: github.com/example/marketplace/agents/code-reviewer`nversion: 3`n---`nAgent body" |
        Set-Content -Path (Join-Path $phase4ContentMarketplace "agents/code-reviewer/v3/code-reviewer.md") -Encoding UTF8
    "---`nname: registry-review`ndescription: Reviews code from registry`nsource: marketplace/registry-review`nversion: 4`n---`nregistry skill" |
        Set-Content -Path (Join-Path $phase4ContentRegistryHome "registries/marketplace/skills/registry-review/v4/SKILL.md") -Encoding UTF8
    @"
{
  "name": "marketplace",
  "display_name": "Marketplace",
  "version": "1.0.0",
  "content": {
    "skills": ["registry-review"]
  }
}
"@ | Set-Content -Path (Join-Path $phase4ContentRegistryHome "registries/marketplace/registry.json") -Encoding UTF8

    $env:DOTBOT_HOME = $dotbotDir

    Push-Location $phase4ContentProject
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-Null
        $phase4ContentInitExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Assert-Equal -Name "Phase 4: install content fixture init exits 0" `
        -Expected 0 -Actual $phase4ContentInitExit

    $phase4ContentCli = Join-Path $dotbotDir "bin/dotbot.ps1"
    Push-Location $phase4ContentProject
    try {
        $skillSource = Join-Path $phase4ContentMarketplace "skills/code-review"
        $phase4SkillOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4ContentCli install skill --from $skillSource --version 2 --force 2>&1 | Out-String
        $phase4SkillExit = $LASTEXITCODE
        $env:DOTBOT_HOME = $phase4ContentRegistryHome
        $phase4RegistrySkillOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4ContentCli install skill marketplace/registry-review:v4 --force 2>&1 | Out-String
        $phase4RegistrySkillExit = $LASTEXITCODE
        $env:DOTBOT_HOME = $dotbotDir
        $promptSource = "$(Join-Path $phase4ContentMarketplace "prompts/onboarding-interview"):v2"
        $phase4PromptOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4ContentCli install prompt $promptSource --force 2>&1 | Out-String
        $phase4PromptExit = $LASTEXITCODE
        $agentSource = Join-Path $phase4ContentMarketplace "agents/code-reviewer"
        $phase4AgentOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4ContentCli install --global agent --from $agentSource --force 2>&1 | Out-String
        $phase4AgentExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Assert-Equal -Name "Phase 4: dotbot install skill exits 0" -Expected 0 -Actual $phase4SkillExit -Message "Output: $phase4SkillOutput"
    Assert-Equal -Name "Phase 4: dotbot install skill from registry alias exits 0" -Expected 0 -Actual $phase4RegistrySkillExit -Message "Output: $phase4RegistrySkillOutput"
    Assert-Equal -Name "Phase 4: dotbot install prompt exits 0" -Expected 0 -Actual $phase4PromptExit -Message "Output: $phase4PromptOutput"
    Assert-Equal -Name "Phase 4: dotbot install --global agent exits 0" -Expected 0 -Actual $phase4AgentExit -Message "Output: $phase4AgentOutput"

    $phase4ContentBot = Join-Path $phase4ContentProject ".bot"
    Assert-PathExists -Name "Phase 4: skill installs to project content" `
        -Path (Join-Path $phase4ContentBot "content/skills/code-review/SKILL.md")
    Assert-True -Name "Phase 4: skill install selects requested version" `
        -Condition ((Get-Content -Raw -Path (Join-Path $phase4ContentBot "content/skills/code-review/SKILL.md")) -match 'version:\s*2') `
        -Message "Expected installed skill to contain version 2"
    Assert-PathExists -Name "Phase 4: prompt installs to project content" `
        -Path (Join-Path $phase4ContentBot "content/prompts/onboarding-interview.md")
    Assert-PathExists -Name "Phase 4: registry alias skill installs to project content" `
        -Path (Join-Path $phase4ContentBot "content/skills/registry-review/SKILL.md")
    Assert-True -Name "Phase 4: registry alias install selects requested version" `
        -Condition ((Get-Content -Raw -Path (Join-Path $phase4ContentBot "content/skills/registry-review/SKILL.md")) -match 'version:\s*4') `
        -Message "Expected installed registry skill to contain version 4"

    $phase4GlobalAgent = Join-Path $dotbotDir "content/agents/$phase4GlobalAgentName/AGENT.md"
    Assert-PathExists -Name "Phase 4: agent installs to DOTBOT_HOME content as AGENT.md" -Path $phase4GlobalAgent
} finally {
    if ($null -ne $phase4ContentSavedHome -and $phase4ContentSavedHome -ne '') {
        $env:DOTBOT_HOME = $phase4ContentSavedHome
    } elseif (Test-Path Env:DOTBOT_HOME) {
        Remove-Item Env:DOTBOT_HOME
    }
    Remove-Item -LiteralPath (Join-Path $dotbotDir "content/agents/$phase4GlobalAgentName") -Recurse -Force -ErrorAction SilentlyContinue
    Remove-TestProject -Path $phase4ContentProject
    Remove-Item -LiteralPath $phase4ContentMarketplace -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $phase4ContentRegistryHome -Recurse -Force -ErrorAction SilentlyContinue
}

# `dotbot go` must launch the installed runtime + dashboard server for sparse projects;
# fresh sparse init no longer writes a project-local .bot/go.ps1.
$phase4GoProject = New-TestProject -Prefix "dotbot-phase4-go"
$phase4GoProcess = $null
$phase4GoOut = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-go-out-$([guid]::NewGuid().ToString('N')).txt"
$phase4GoErr = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-go-err-$([guid]::NewGuid().ToString('N')).txt"
try {
    Push-Location $phase4GoProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-Null
    Pop-Location

    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $phase4GoPort = [int]$tcp.LocalEndpoint.Port
    $tcp.Stop()

    $dotbotCli = Join-Path $dotbotDir "bin/dotbot.ps1"
    $phase4GoProcess = Start-Process -FilePath "pwsh" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dotbotCli, "go", "-Port", "$phase4GoPort") `
        -WorkingDirectory $phase4GoProject `
        -RedirectStandardOutput $phase4GoOut `
        -RedirectStandardError $phase4GoErr `
        -PassThru

    $phase4GoPortFile = Join-Path $phase4GoProject ".bot/.control/ui-port"
    $phase4GoRuntimeFile = Join-Path $phase4GoProject ".bot/.control/runtime.json"
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline -and
           ((-not (Test-Path $phase4GoPortFile)) -or (-not (Test-Path $phase4GoRuntimeFile))) -and
           -not $phase4GoProcess.HasExited) {
        Start-Sleep -Milliseconds 250
        $phase4GoProcess.Refresh()
    }

    Assert-True -Name "Phase 4: dotbot go keeps dashboard process running" `
        -Condition (-not $phase4GoProcess.HasExited) `
        -Message "dotbot go exited early. stderr: $(if (Test-Path $phase4GoErr) { Get-Content $phase4GoErr -Raw } else { '' })"
    Assert-PathExists -Name "Phase 4: dotbot go writes ui-port" -Path $phase4GoPortFile
    Assert-PathExists -Name "Phase 4: dotbot go writes runtime connection" -Path $phase4GoRuntimeFile
    if (Test-Path $phase4GoPortFile) {
        Assert-Equal -Name "Phase 4: dotbot go uses requested port" `
            -Expected "$phase4GoPort" -Actual ((Get-Content $phase4GoPortFile -Raw).Trim())
    }
} finally {
    if ($phase4GoProcess -and -not $phase4GoProcess.HasExited) {
        Stop-Process -Id $phase4GoProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-TestProject -Path $phase4GoProject
    Remove-Item $phase4GoOut, $phase4GoErr -Force -ErrorAction SilentlyContinue
}

# A sparse init must not silently create a repository outside .bot/.
$phase4NonGitProject = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-phase4-nongit-$([guid]::NewGuid().ToString('N').Substring(0,8))"
try {
    New-Item -ItemType Directory -Path $phase4NonGitProject -Force | Out-Null
    Push-Location $phase4NonGitProject
    "n" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-Null
    $phase4NonGitExit = $LASTEXITCODE
    Pop-Location
    Assert-True -Name "Phase 4: init in non-git directory exits non-zero when prompt is declined" `
        -Condition ($phase4NonGitExit -ne 0) `
        -Message "Expected non-zero exit, got $phase4NonGitExit"
    Assert-PathNotExists -Name "Phase 4: declined non-git init does not create .git" `
        -Path (Join-Path $phase4NonGitProject ".git")
} finally {
    Remove-TestProject -Path $phase4NonGitProject
}

# Accepting the non-git prompt creates a repository, then continues normal init.
$phase4PromptGitProject = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-test-phase4-promptgit-$([guid]::NewGuid().ToString('N').Substring(0,8))"
try {
    New-Item -ItemType Directory -Path $phase4PromptGitProject -Force | Out-Null
    Push-Location $phase4PromptGitProject
    "yes" | & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-Null
    $phase4PromptGitExit = $LASTEXITCODE
    Pop-Location
    Assert-Equal -Name "Phase 4: init in non-git directory exits 0 when prompt is accepted" `
        -Expected 0 -Actual $phase4PromptGitExit
    Assert-PathExists -Name "Phase 4: accepted non-git init creates .git" `
        -Path (Join-Path $phase4PromptGitProject ".git")
    Assert-PathExists -Name "Phase 4: accepted non-git init creates .bot/workspace" `
        -Path (Join-Path $phase4PromptGitProject ".bot" "workspace")
} finally {
    Remove-TestProject -Path $phase4PromptGitProject
}

# Unset DOTBOT_HOME must produce a clear non-zero exit.
$phase4MissingProject = New-TestProject -Prefix "dotbot-phase4-noenv"
$phase4SavedHome = $env:DOTBOT_HOME
try {
    Remove-Item Env:DOTBOT_HOME -ErrorAction SilentlyContinue
    Push-Location $phase4MissingProject
    $phase4NoEnvOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $phase4InitScript 2>&1 | Out-String
    $phase4NoEnvExit = $LASTEXITCODE
    Pop-Location
    Assert-True -Name "Phase 4: init with no DOTBOT_HOME exits non-zero" `
        -Condition ($phase4NoEnvExit -ne 0) `
        -Message "Expected non-zero exit, got $phase4NoEnvExit (output: $phase4NoEnvOutput)"
    Assert-True -Name "Phase 4: error message mentions DOTBOT_HOME" `
        -Condition ($phase4NoEnvOutput -match 'DOTBOT_HOME') `
        -Message "Expected error to mention DOTBOT_HOME"
} finally {
    if ($null -ne $phase4SavedHome -and $phase4SavedHome -ne '') {
        $env:DOTBOT_HOME = $phase4SavedHome
    }
    Remove-TestProject -Path $phase4MissingProject
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 5 — `dotbot status --json` shape contract
# Consumers (CI scripts, the UI banner, agents) read the JSON output
# so the field names must stay stable across releases.
# ═══════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "--- Phase 5: dotbot status --json shape ---" -ForegroundColor Cyan

$statusScript = Join-Path $dotbotDir "src/cli/status.ps1"
$statusProject = New-TestProject -Prefix "dotbot-status"
try {
    Push-Location $statusProject
    $statusOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $statusScript -Json 2>&1 | Out-String
    $statusExit = $LASTEXITCODE
    Pop-Location

    Assert-Equal -Name "status --json exits 0" -Expected 0 -Actual $statusExit

    $statusObj = $null
    try { $statusObj = $statusOutput | ConvertFrom-Json -ErrorAction Stop } catch {}
    Assert-True -Name "status --json output is valid JSON" `
        -Condition ($null -ne $statusObj) `
        -Message "Output did not parse as JSON: $statusOutput"

    if ($null -ne $statusObj) {
        foreach ($key in @('dotbot_home','dotbot_home_env_set','version','framework','user_settings_path','user_settings_exists','project')) {
            Assert-True -Name "status --json has top-level key '$key'" `
                -Condition ([bool]$statusObj.PSObject.Properties[$key]) `
                -Message "Missing top-level key: $key"
        }
        foreach ($key in @('is_git_repo','sha','sha_short','branch','dirty')) {
            Assert-True -Name "status --json framework.$key present" `
                -Condition ([bool]$statusObj.framework.PSObject.Properties[$key]) `
                -Message "Missing framework.$key"
        }
        foreach ($key in @('initialized','bot_dir','workflow','provider','stacks')) {
            Assert-True -Name "status --json project.$key present" `
                -Condition ([bool]$statusObj.project.PSObject.Properties[$key]) `
                -Message "Missing project.$key"
        }
        Assert-Equal -Name "status --json project.initialized==false when no .bot/" `
            -Expected $false -Actual $statusObj.project.initialized
        Assert-True -Name "status --json dotbot_home is a non-empty string" `
            -Condition (-not [string]::IsNullOrWhiteSpace([string]$statusObj.dotbot_home)) `
            -Message "dotbot_home was empty"
    }
} finally {
    Remove-TestProject -Path $statusProject
}

# After init, project.initialized + project.workflow should reflect the recorded selection.
$statusInitProject = New-TestProject -Prefix "dotbot-status-init"
$initScript = Join-Path $dotbotDir "src/cli/init-project.ps1"
try {
    Push-Location $statusInitProject
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $initScript -Workflow start-from-prompt 2>&1 | Out-Null
    $statusOutput2 = & pwsh -NoProfile -ExecutionPolicy Bypass -File $statusScript -Json 2>&1 | Out-String
    Pop-Location

    $obj2 = $null
    try { $obj2 = $statusOutput2 | ConvertFrom-Json -ErrorAction Stop } catch {}
    Assert-True -Name "status --json post-init parses" -Condition ($null -ne $obj2) `
        -Message "Output: $statusOutput2"
    if ($null -ne $obj2) {
        Assert-Equal -Name "status --json post-init: project.initialized==true" `
            -Expected $true -Actual $obj2.project.initialized
        Assert-Equal -Name "status --json post-init: project.workflow==start-from-prompt" `
            -Expected "start-from-prompt" -Actual $obj2.project.workflow
    }

    $nestedStatusDir = Join-Path $statusInitProject "src/nested"
    New-Item -ItemType Directory -Force -Path $nestedStatusDir | Out-Null
    Push-Location $nestedStatusDir
    $nestedStatusOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $statusScript -Json 2>&1 | Out-String
    Pop-Location

    $nestedObj = $null
    try { $nestedObj = $nestedStatusOutput | ConvertFrom-Json -ErrorAction Stop } catch {}
    Assert-True -Name "status --json nested post-init parses" -Condition ($null -ne $nestedObj) `
        -Message "Output: $nestedStatusOutput"
    if ($null -ne $nestedObj) {
        Assert-Equal -Name "status --json nested: project.initialized==true" `
            -Expected $true -Actual $nestedObj.project.initialized
        Assert-Equal -Name "status --json nested: project.workflow==start-from-prompt" `
            -Expected "start-from-prompt" -Actual $nestedObj.project.workflow
        Assert-Equal -Name "status --json nested: bot_dir resolves to project root .bot" `
            -Expected (Join-Path $statusInitProject ".bot") -Actual $nestedObj.project.bot_dir
    }
} finally {
    Remove-TestProject -Path $statusInitProject
}

# ═══════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════

Remove-TestProject -Path $testProject

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 2: Components"

if (-not $allPassed) {
    exit 1
}
