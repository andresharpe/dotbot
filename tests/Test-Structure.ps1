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
# REPO BIN/ AND PATH SHIM
# ═══════════════════════════════════════════════════════════════════

Write-Host "  REPO BIN/ AND PATH SHIM" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$repoBinDir = Join-Path $repoRoot "bin"
$repoCli = Join-Path $repoBinDir "dotbot.ps1"
$repoCliPosix = Join-Path $repoBinDir "dotbot"
$repoShimDir = Join-Path $repoBinDir "shim"
$repoShimPs1 = Join-Path $repoShimDir "dotbot.ps1"
$repoShimPosix = Join-Path $repoShimDir "dotbot"
$repoShimCmd = Join-Path $repoShimDir "dotbot.cmd"

Assert-PathExists -Name "repo bin/dotbot.ps1 exists" -Path $repoCli
Assert-PathExists -Name "repo bin/dotbot (POSIX sibling) exists" -Path $repoCliPosix
Assert-PathExists -Name "repo bin/shim/dotbot.ps1 exists" -Path $repoShimPs1
Assert-PathExists -Name "repo bin/shim/dotbot (POSIX) exists" -Path $repoShimPosix
Assert-PathExists -Name "repo bin/shim/dotbot.cmd exists" -Path $repoShimCmd
Assert-ValidPowerShell -Name "repo bin/dotbot.ps1 is valid PowerShell" -Path $repoCli
Assert-ValidPowerShell -Name "repo bin/shim/dotbot.ps1 is valid PowerShell" -Path $repoShimPs1

# The in-repo CLI trusts its own location — invoking it directly should work
# even when DOTBOT_HOME is unset (it's the SHIM that enforces DOTBOT_HOME).
if (Test-Path $repoCli) {
    $savedHome = $env:DOTBOT_HOME
    try {
        if (Test-Path Env:DOTBOT_HOME) { Remove-Item Env:DOTBOT_HOME }
        $cliOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repoCli help 2>&1
        $cliExit = $LASTEXITCODE
        Assert-True -Name "repo bin/dotbot.ps1 runs without DOTBOT_HOME (trusts own location)" `
            -Condition (($cliExit -eq 0) -or ($null -eq $cliExit)) `
            -Message "Exit: $cliExit`nOutput: $($cliOutput -join "`n")"
    } finally {
        if (Test-Path Env:DOTBOT_HOME) { Remove-Item Env:DOTBOT_HOME }
        if ($null -ne $savedHome -and $savedHome -ne '') { $env:DOTBOT_HOME = $savedHome }
    }
}

# Shim behaviour: DOTBOT_HOME unset → hard error with remediation.
if (Test-Path $repoShimPs1) {
    $savedHome = $env:DOTBOT_HOME
    try {
        if (Test-Path Env:DOTBOT_HOME) { Remove-Item Env:DOTBOT_HOME }
        $shimOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repoShimPs1 help 2>&1
        $shimExit = $LASTEXITCODE
        $shimCombined = ($shimOutput | Out-String)
        Assert-True -Name "shim exits non-zero when DOTBOT_HOME is unset" `
            -Condition ($shimExit -ne 0) `
            -Message "Expected non-zero exit, got $shimExit.`nOutput: $shimCombined"
        Assert-True -Name "shim error mentions DOTBOT_HOME when unset" `
            -Condition ($shimCombined -match 'DOTBOT_HOME is not set') `
            -Message "Remediation text missing.`nOutput: $shimCombined"

        # Shim behaviour: DOTBOT_HOME points at non-checkout → clear error.
        $env:DOTBOT_HOME = if ($IsWindows) {
            "C:\dotbot-test-nonexistent-$(New-Guid)"
        } else {
            "/tmp/dotbot-test-nonexistent-$(New-Guid)"
        }
        $shimOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repoShimPs1 help 2>&1
        $shimExit = $LASTEXITCODE
        $shimCombined = ($shimOutput | Out-String)
        Assert-True -Name "shim exits non-zero when DOTBOT_HOME points at non-checkout" `
            -Condition ($shimExit -ne 0) `
            -Message "Expected non-zero exit, got $shimExit.`nOutput: $shimCombined"
        Assert-True -Name "shim error mentions missing bin/dotbot.ps1 when path is wrong" `
            -Condition ($shimCombined -match 'does not look like a dotbot checkout') `
            -Message "Diagnostic text missing.`nOutput: $shimCombined"

        # Shim behaviour: DOTBOT_HOME points at the repo → routes successfully.
        $env:DOTBOT_HOME = $repoRoot
        $shimOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $repoShimPs1 help 2>&1
        $shimExit = $LASTEXITCODE
        Assert-True -Name "shim with valid DOTBOT_HOME routes to the in-checkout CLI" `
            -Condition (($shimExit -eq 0) -or ($null -eq $shimExit)) `
            -Message "Exit: $shimExit`nOutput: $($shimOutput -join "`n")"
    } finally {
        if (Test-Path Env:DOTBOT_HOME) { Remove-Item Env:DOTBOT_HOME }
        if ($null -ne $savedHome -and $savedHome -ne '') { $env:DOTBOT_HOME = $savedHome }
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PHASE 6 — bootstrap.ps1 contract
# Bootstrap is the only machine-wide install step in v4: drop the
# PATH shim, refuse PS 5.1, and configure DOTBOT_HOME through the
# installed shim without editing user environment/startup files.
# ═══════════════════════════════════════════════════════════════════
Write-Host "  BOOTSTRAP.PS1 (Phase 6)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$bootstrapScript = Join-Path $repoRoot "bootstrap.ps1"
Assert-PathExists -Name "bootstrap.ps1 exists at repo root" -Path $bootstrapScript
Assert-ValidPowerShell -Name "bootstrap.ps1 is valid PowerShell" -Path $bootstrapScript

if (Test-Path $bootstrapScript) {
    $bootstrapSrc = Get-Content $bootstrapScript -Raw

    Assert-True -Name "bootstrap.ps1 refuses PowerShell 5.1" `
        -Condition ($bootstrapSrc -match '\$PSVersionTable\.PSVersion\.Major\s*-lt\s*7') `
        -Message "Expected an explicit PS-major < 7 guard"

    Assert-True -Name "bootstrap.ps1 sources bin/shim/" `
        -Condition ($bootstrapSrc -match "Join-Path\s+\`$RepoDir\s+'bin/shim'") `
        -Message "Expected bootstrap.ps1 to read the shim from bin/shim/"

    Assert-True -Name "bootstrap.ps1 honours -ShimDir override" `
        -Condition ($bootstrapSrc -match '\[string\]\$ShimDir') `
        -Message "Expected a -ShimDir parameter"

    Assert-True -Name "bootstrap.ps1 defaults to ~/.local/bin on Unix" `
        -Condition ($bootstrapSrc -match "Join-Path\s+\`$HOME\s+'\.local'\s+'bin'") `
        -Message "Expected ~/.local/bin as the Unix default"

    Assert-True -Name "bootstrap.ps1 defaults to LOCALAPPDATA\\Microsoft\\WindowsApps on Windows" `
        -Condition ($bootstrapSrc -match "Join-Path\s+\`$base\s+'Microsoft'\s+'WindowsApps'") `
        -Message "Expected the Windows default to be %LOCALAPPDATA%\\Microsoft\\WindowsApps"

    Assert-FileNotContains -Name "bootstrap.ps1 does not write DOTBOT_HOME to Windows user environment" `
        -Path $bootstrapScript -Pattern "SetEnvironmentVariable\([^)]*DOTBOT_HOME"

    Assert-True -Name "bootstrap.ps1 adds shim DOTBOT_HOME fallbacks" `
        -Condition ($bootstrapSrc -match 'dotbot bootstrap fallback') `
        -Message "Expected bootstrap.ps1 to configure DOTBOT_HOME via installed shims"

    Assert-FileNotContains -Name "bootstrap.ps1 does not write Unix shell startup files" `
        -Path $bootstrapScript -Pattern 'Set-Content\s+-Path\s+\$profile|Add-Content\s+-Path\s+\$profile|\.zshrc|\.bashrc|\.profile'

    # Theme-helper hygiene (same policy the scripts/ scanner enforces).
    Assert-FileNotContains -Name "bootstrap.ps1 has no raw Write-Host" `
        -Path $bootstrapScript -Pattern '^\s*Write-Host\b'

    # End-to-end: bootstrap installs into a temp dir and the shim ends up
    # at the expected path, executable on Unix.
    $bsTmp = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-bootstrap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    try {
        $bsOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $bootstrapScript -ShimDir $bsTmp -Force 2>&1
        $bsExit = $LASTEXITCODE
        Assert-Equal -Name "bootstrap.ps1 -ShimDir <tmp> exits 0" -Expected 0 -Actual $bsExit `
            -Message "Output: $($bsOutput -join "`n")"

        $expectedShim = if ($IsWindows) { Join-Path $bsTmp 'dotbot.cmd' } else { Join-Path $bsTmp 'dotbot' }
        Assert-PathExists -Name "bootstrap.ps1 drops the expected shim file" -Path $expectedShim

        if (Test-Path $expectedShim) {
            $installedShimSrc = Get-Content $expectedShim -Raw
            Assert-True -Name "bootstrap.ps1 writes DOTBOT_HOME fallback into installed shim" `
                -Condition ($installedShimSrc -match [regex]::Escape($repoRoot)) `
                -Message "Expected installed shim to include fallback DOTBOT_HOME=$repoRoot"
        }

        if (-not $IsWindows -and (Test-Path $expectedShim)) {
            # +x is asserted indirectly: bash refuses to exec without it.
            $execProbe = & bash -c "test -x '$expectedShim' && echo executable"
            Assert-Equal -Name "bootstrap.ps1 marks the Unix shim executable" `
                -Expected "executable" -Actual ($execProbe ?? '')
        }
    } finally {
        Remove-Item -Path $bsTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ═══════════════════════════════════════════════════════════════════
# PHASE 6 — install.ps1 / install-remote.ps1 retired entirely.
# bootstrap.ps1 is the only entry point; nothing under DOTBOT_HOME
# should re-introduce the copy-based installers.
# ═══════════════════════════════════════════════════════════════════
Assert-PathNotExists -Name "install.ps1 deleted (Phase 6)" `
    -Path (Join-Path $repoRoot "install.ps1")
Assert-PathNotExists -Name "install-remote.ps1 deleted (Phase 6)" `
    -Path (Join-Path $repoRoot "install-remote.ps1")

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PROJECT INIT (Phase 4 — sparse footprint)
# Deep init-behaviour tests live in Test-Components.ps1
# "Phase 4: dotbot init footprint" section. This block keeps a Layer-1
# structural smoke test so installer regressions show up fast.
# ═══════════════════════════════════════════════════════════════════

Write-Host "  PROJECT INIT (smoke test)" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Project init tests" -Status Skip -Message "dotbot checkout missing — set DOTBOT_HOME at a clone (src/ + content/ must exist)"
} else {
    $smokeProject = New-TestProject -Prefix "dotbot-init-smoke"
    try {
        Push-Location $smokeProject
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir 'src/cli/init-project.ps1') 2>&1 | Out-Null
        $smokeExit = $LASTEXITCODE
        Pop-Location
        Assert-Equal -Name "smoke: bare init exits 0" -Expected 0 -Actual $smokeExit
        $smokeBot = Join-Path $smokeProject ".bot"
        Assert-PathExists -Name "smoke: .bot/ created"          -Path $smokeBot
        Assert-PathExists -Name "smoke: .bot/workspace/ seeded" -Path (Join-Path $smokeBot "workspace")
        Assert-PathExists -Name "smoke: .bot/.gitignore seeded" -Path (Join-Path $smokeBot ".gitignore")
    } finally {
        Remove-TestProject -Path $smokeProject
    }
}


Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# PLATFORM FUNCTIONS
# ═══════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════
# MANIFEST VALIDATION (manifest.json files)
# ═══════════════════════════════════════════════════════════════════

Write-Host "  MANIFEST VALIDATION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$workflowsSourceDir = Join-Path $repoRoot "content" "workflows"
$stacksSourceDir = Join-Path $repoRoot "content" "stacks"

# Scan all workflows and stacks for manifest.json
$manifestDirs = @()
if (Test-Path $workflowsSourceDir) {
    $manifestDirs += Get-ChildItem -Path $workflowsSourceDir -Directory
}
if (Test-Path $stacksSourceDir) {
    $manifestDirs += Get-ChildItem -Path $stacksSourceDir -Directory
}

foreach ($manifestDir in $manifestDirs) {
    $JSONPath = Join-Path $manifestDir.FullName "manifest.json"
    Assert-PathExists -Name "manifest.json exists: $($manifestDir.Name)" -Path $JSONPath

    if (Test-Path $JSONPath) {
        try {
            $content = Get-Content $JSONPath -Raw | ConvertFrom-Json
        } catch {
            $content = $null
        }
        Assert-True -Name "manifest.json parses: $($manifestDir.Name)" `
            -Condition ($null -ne $content) `
            -Message "Invalid JSON in manifest.json"
        Assert-True -Name "manifest.json has 'name': $($manifestDir.Name)" `
            -Condition ($null -ne $content -and -not [string]::IsNullOrWhiteSpace($content.name)) `
            -Message "Missing 'name' field"
        Assert-True -Name "manifest.json has 'description': $($manifestDir.Name)" `
            -Condition ($null -ne $content -and -not [string]::IsNullOrWhiteSpace($content.description)) `
            -Message "Missing 'description' field"

        # If extends is declared, the parent stack must exist
        if ($null -ne $content -and -not [string]::IsNullOrWhiteSpace($content.extends)) {
            $parentName = $content.extends
            $parentDir = Join-Path $stacksSourceDir $parentName
            Assert-PathExists -Name "extends target exists: $($manifestDir.Name) -> $parentName" -Path $parentDir
        }
    }
}

Write-Host ""

Write-Host "  PLATFORM FUNCTIONS" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$platformModule = Join-Path $repoRoot "src\cli\Platform-Functions.psm1"
$platformModuleInfo = Import-Module $platformModule -Force -PassThru

# Get-PlatformName returns correct OS
$platformName = Get-PlatformName
$expectedPlatform = if ($IsWindows) { "Windows" } elseif ($IsMacOS) { "macOS" } elseif ($IsLinux) { "Linux" } else { "Unknown" }
Assert-Equal -Name "Get-PlatformName returns '$expectedPlatform'" -Expected $expectedPlatform -Actual $platformName

# Inject -CommandTester so the assertions are deterministic regardless of
# which Linux openers happen to be installed on the host running the suite.
# (Debian/Fedora boxes typically ship `sensible-browser`, which would
# otherwise shadow the candidate ordering we want to exercise.) The
# `& $platformModuleInfo {}` wrapper runs inside the module scope so the
# unexported Get-UrlOpenCommand is reachable.
$preferredLinuxOpener = & $platformModuleInfo {
    Get-UrlOpenCommand `
        -IsWindowsOverride $false -IsMacOSOverride $false -IsLinuxOverride $true `
        -CommandTester { param($n) $n -in @('xdg-open', 'powershell.exe') }
}
Assert-Equal -Name "Get-UrlOpenCommand prefers Linux opener before interop fallback" -Expected "xdg-open" -Actual $preferredLinuxOpener

$interopLinuxOpener = & $platformModuleInfo {
    Get-UrlOpenCommand `
        -IsWindowsOverride $false -IsMacOSOverride $false -IsLinuxOverride $true `
        -CommandTester { param($n) $n -eq 'powershell.exe' }
}
Assert-Equal -Name "Get-UrlOpenCommand falls back to Windows interop when Linux opener is absent" -Expected "powershell.exe" -Actual $interopLinuxOpener

$interopInvocation = & $platformModuleInfo {
    function powershell.exe {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
        return ($Args -join '|')
    }
    try {
        Invoke-UrlOpenCommand -Command 'powershell.exe' -Url 'http://localhost:8686'
    } finally {
        Remove-Item Function:\powershell.exe -ErrorAction SilentlyContinue
    }
}
Assert-Equal -Name "Invoke-UrlOpenCommand uses Start-Process via powershell.exe fallback" -Expected "-NoProfile|-Command|Start-Process 'http://localhost:8686'" -Actual $interopInvocation

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

$providersDir = Join-Path $repoRoot "content\settings\providers"

foreach ($providerName in @("claude", "codex", "antigravity", "opencode")) {
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

            if ($parsed.models) {
                foreach ($tier in @('fast', 'balanced', 'best')) {
                    $tierExists = $parsed.models.PSObject.Properties.Name -contains $tier
                    Assert-True -Name "Provider $providerName declares '$tier' model tier" `
                        -Condition $tierExists `
                        -Message "Missing models.$tier"
                    if ($tierExists) {
                        $tierModel = $parsed.models.$tier
                        Assert-True -Name "Provider $providerName tier '$tier' has display_name" `
                            -Condition ($null -ne $tierModel.display_name -and $tierModel.display_name.Length -gt 0) `
                            -Message "Missing display_name"
                        Assert-True -Name "Provider $providerName tier '$tier' has description" `
                            -Condition ($null -ne $tierModel.description -and $tierModel.description.Length -gt 0) `
                            -Message "Missing description"
                        Assert-True -Name "Provider $providerName tier '$tier' does not expose provider model id" `
                            -Condition (-not ($tierModel.PSObject.Properties.Name -contains 'id')) `
                            -Message "Concrete provider model ids belong in the harness adapter"
                    }
                }

                Assert-True -Name "Provider $providerName default_model uses canonical tier" `
                    -Condition ($parsed.default_model -in @('fast', 'balanced', 'best')) `
                    -Message "default_model must be one of fast, balanced, best"
            }

            Assert-True -Name "Provider $providerName has 'executable'" `
                -Condition ($null -ne $parsed.executable -and $parsed.executable.Length -gt 0) `
                -Message "Missing executable"

            Assert-True -Name "Provider $providerName has 'adapter'" `
                -Condition ($null -ne $parsed.adapter) `
                -Message "Missing adapter (names the harness adapter to use)"

            Assert-True -Name "Provider $providerName does not use stream_parser" `
                -Condition (-not ($parsed.PSObject.Properties.Name -contains 'stream_parser')) `
                -Message "Use adapter instead of stream_parser"

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

            if ($parsed.cli_args) {
                Assert-True -Name "Provider $providerName does not use cli_args.permissions_bypass" `
                    -Condition (-not ($parsed.cli_args.PSObject.Properties.Name -contains 'permissions_bypass')) `
                    -Message "Use permission_modes.<mode>.cli_args instead"
            }

            # Claude-specific: auto mode excludes the fast tier
            if ($providerName -eq "claude" -and $parsed.permission_modes -and $parsed.permission_modes.auto) {
                $autoMode = $parsed.permission_modes.auto
                Assert-True -Name "Claude auto mode has restrictions" `
                    -Condition ($null -ne $autoMode.restrictions) `
                    -Message "Missing restrictions on auto mode"

                if ($autoMode.restrictions) {
                    Assert-True -Name "Claude auto mode excludes fast tier" `
                        -Condition ($autoMode.restrictions.excluded_model_tiers -contains "fast") `
                        -Message "Expected fast in excluded_model_tiers"
                }
            }
        }
    }
}

# Settings has provider field
$settingsFile = Join-Path $repoRoot "content\settings\settings.default.json"
if (Test-Path $settingsFile) {
    $settingsData = Get-Content $settingsFile -Raw | ConvertFrom-Json
    Assert-True -Name "settings.default.json has 'provider' field" `
        -Condition ($null -ne $settingsData.provider) `
        -Message "Missing 'provider' top-level field"

    Assert-True -Name "settings.default.json has 'permission_mode' field" `
        -Condition ($settingsData.PSObject.Properties.Name -contains 'permission_mode') `
        -Message "Missing 'permission_mode' top-level field"
}

# Dotbot.Harness module + adapters exist
$harnessModule = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psm1"
Assert-True -Name "Dotbot.Harness.psm1 exists" `
    -Condition (Test-Path $harnessModule) `
    -Message "Expected $harnessModule"

$harnessManifest = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psd1"
Assert-True -Name "Dotbot.Harness.psd1 exists" `
    -Condition (Test-Path $harnessManifest) `
    -Message "Expected $harnessManifest"

$harnessImports = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Harness/Private/Imports.ps1"
Assert-True -Name "Dotbot.Harness Private/Imports.ps1 exists" `
    -Condition (Test-Path $harnessImports) `
    -Message "Expected $harnessImports"
Assert-FileContains -Name "Dotbot.Harness manifest wires ScriptsToProcess" `
    -Path $harnessManifest `
    -Pattern "ScriptsToProcess\s*=\s*@\(\s*'Private/Imports\.ps1'"
Assert-FileNotContains -Name "Dotbot.Harness root does not inline-import Dotbot.Theme" `
    -Path $harnessModule `
    -Pattern 'Import-Module .*Dotbot\.Theme'
Assert-FileNotContains -Name "Dotbot.Harness root does not inline-import Dotbot.Core" `
    -Path $harnessModule `
    -Pattern 'Import-Module .*Dotbot\.Core'

$processModule = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psm1"
Assert-True -Name "Dotbot.Process.psm1 exists" `
    -Condition (Test-Path $processModule) `
    -Message "Expected $processModule"

$processManifest = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Process/Dotbot.Process.psd1"
Assert-True -Name "Dotbot.Process.psd1 exists" `
    -Condition (Test-Path $processManifest) `
    -Message "Expected $processManifest"

$processImports = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Process/Private/Imports.ps1"
Assert-True -Name "Dotbot.Process Private/Imports.ps1 exists" `
    -Condition (Test-Path $processImports) `
    -Message "Expected $processImports"
Assert-FileContains -Name "Dotbot.Process manifest wires ScriptsToProcess" `
    -Path $processManifest `
    -Pattern "ScriptsToProcess\s*=\s*@\(\s*'Private/Imports\.ps1'"
Assert-FileNotContains -Name "Dotbot.Process root does not inline-import Dotbot.Core" `
    -Path $processModule `
    -Pattern 'Import-Module .*Dotbot\.Core'
Assert-FileNotContains -Name "Dotbot.Process root does not inline-import Dotbot.Settings" `
    -Path $processModule `
    -Pattern 'Import-Module .*Dotbot\.Settings'
Assert-FileNotContains -Name "Dotbot.Harness root does not inline-import Dotbot.Settings" `
    -Path $harnessModule `
    -Pattern 'Import-Module .*Dotbot\.Settings'

# Dotbot.Runtime module manifest-loads its runtime-spine dependencies
$runtimeModule = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psm1"
Assert-True -Name "Dotbot.Runtime.psm1 exists" `
    -Condition (Test-Path $runtimeModule) `
    -Message "Expected $runtimeModule"

$runtimeManifest = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Runtime/Dotbot.Runtime.psd1"
Assert-True -Name "Dotbot.Runtime.psd1 exists" `
    -Condition (Test-Path $runtimeManifest) `
    -Message "Expected $runtimeManifest"

$runtimeImports = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Runtime/Private/Imports.ps1"
Assert-True -Name "Dotbot.Runtime Private/Imports.ps1 exists" `
    -Condition (Test-Path $runtimeImports) `
    -Message "Expected $runtimeImports"
Assert-FileContains -Name "Dotbot.Runtime manifest wires ScriptsToProcess" `
    -Path $runtimeManifest `
    -Pattern "ScriptsToProcess\s*=\s*@\(\s*'Private/Imports\.ps1'"
Assert-FileNotContains -Name "Dotbot.Runtime root does not inline-import Dotbot.Task" `
    -Path $runtimeModule `
    -Pattern 'Import-Module .*Dotbot\.Task'
Assert-FileNotContains -Name "Dotbot.Runtime root does not inline-import Dotbot.Workflow" `
    -Path $runtimeModule `
    -Pattern 'Import-Module .*Dotbot\.Workflow'
Assert-FileNotContains -Name "Dotbot.Runtime root does not inline-import Dotbot.Hook" `
    -Path $runtimeModule `
    -Pattern 'Import-Module .*Dotbot\.Hook'
Assert-FileContains -Name "Dotbot.Runtime imports Dotbot.Settings through the manifest" `
    -Path $runtimeImports `
    -Pattern 'Dotbot\.Settings'

foreach ($helperName in @("ConsoleRender", "ActivityLog", "Failure", "HarnessConfig", "AdapterRegistry")) {
    $helperFile = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Harness/Private/${helperName}.ps1"
    Assert-True -Name "Harness helper exists: ${helperName}.ps1" `
        -Condition (Test-Path $helperFile) `
        -Message "Expected $helperFile"
}

foreach ($adapterName in @("ClaudeCode", "Codex", "Antigravity", "OpenCode")) {
    $adapterFile = Join-Path $repoRoot "src/runtime/Modules/Dotbot.Harness/Adapters/${adapterName}Adapter.ps1"
    Assert-True -Name "Harness adapter exists: ${adapterName}Adapter.ps1" `
        -Condition (Test-Path $adapterFile) `
        -Message "Expected $adapterFile"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# WORKSPACE INSTANCE ID INTEGRATION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  WORKSPACE INSTANCE ID" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$defaultSettingsPath = Join-Path $repoRoot "content\settings\settings.default.json"
$startFromJiraSettingsPath = Join-Path $repoRoot "content\workflows\start-from-jira\settings\settings.default.json"
$startFromPrSettingsPath = Join-Path $repoRoot "content\workflows\start-from-pr\settings\settings.default.json"
$stateBuilderPath = Join-Path $repoRoot "src/ui/modules/StateBuilder.psm1"
$uiIndexPath = Join-Path $repoRoot "src/ui/static/index.html"
$uiUpdatesPath = Join-Path $repoRoot "src/ui/static/modules/ui-updates.js"

Assert-FileContains -Name "default settings template has instance_id placeholder" `
    -Path $defaultSettingsPath `
    -Pattern '"instance_id"\s*:\s*null'
Assert-FileContains -Name "start-from-jira settings template has instance_id placeholder" `
    -Path $startFromJiraSettingsPath `
    -Pattern '"instance_id"\s*:\s*null'
Assert-FileContains -Name "start-from-pr settings template has instance_id placeholder" `
    -Path $startFromPrSettingsPath `
    -Pattern '"instance_id"\s*:\s*null'
Assert-FileContains -Name "StateBuilder includes workspace instance_id in state" `
    -Path $stateBuilderPath `
    -Pattern 'instance_id\s*=\s*\$workspaceInstanceId'
Assert-FileContains -Name "UI footer has instance-id field" `
    -Path $uiIndexPath `
    -Pattern 'id="instance-id"'
Assert-FileContains -Name "UI updates bind state instance_id to footer" `
    -Path $uiUpdatesPath `
    -Pattern "setElementText\('instance-id',\s*InstanceId\s*\|\|\s*'--'\)"

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
        (Join-Path $repoRoot "bootstrap.ps1"),
        (Join-Path $repoRoot "src" "runtime" "Invoke-DotbotProcess.ps1"),
        (Join-Path $repoRoot "src" "ui" "server.ps1"),
        (Join-Path $repoRoot "src" "runtime" "Modules" "Dotbot.Process" "Dotbot.Process.psm1"),
        (Join-Path $repoRoot "src" "runtime" "Scripts" "Invoke-PromptProcess.ps1"),
        (Join-Path $repoRoot "src" "runtime" "Scripts" "Invoke-WorkflowProcess.ps1")
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

$coreDir = Join-Path $repoRoot "src"
if (Test-Path $coreDir) {
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
        'runtime/Modules/Dotbot.Logging/Dotbot.Logging.psm1',
        'runtime/Modules/Dotbot.Theme/Dotbot.Theme.psm1'
    )

    # Patterns for files excluded from enforcement (user-facing scripts, manual test scripts)
    # Use forward slashes for cross-platform -like matching
    $excludePatterns = @(
        '*/test.ps1',       # MCP tool manual test scripts
        'hooks/*',          # Hook scripts (user-facing terminal output)
        'cli/*',            # CLI scripts (covered by INSTALL SCRIPT THEME HYGIENE below)
        'server-dotnet/*',  # Sibling .NET product — its own deploy/test scripts
        'studio-ui/*',      # Sibling Node product — its own server.ps1 output style
        'shared/*'          # Static CSS tokens, not PowerShell
    )

    $violations = @()
    Get-ChildItem -Path $coreDir -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
        # Normalize to forward slashes for cross-platform matching
        $relativePath = $_.FullName.Substring($coreDir.Length + 1).Replace('\', '/')
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
        Write-TestResult -Name "No raw Write-* calls in src/ (except allowlist)" -Status Pass
    } else {
        $sample = ($violations | Select-Object -First 15) -join "`n  "
        $extra = if ($violations.Count -gt 15) { "`n  ... and $($violations.Count - 15) more" } else { "" }
        Write-TestResult -Name "No raw Write-* calls in src/ (except allowlist)" -Status Fail `
            -Message "Found $($violations.Count) violation(s):`n  $sample$extra"
    }
} else {
    Write-TestResult -Name "Logging hygiene" -Status Skip -Message "core/ not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# CROSS-PLATFORM HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  CROSS-PLATFORM HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

if (Test-Path $coreDir) {
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
    Get-ChildItem -Path $coreDir -Recurse -Include *.ps1, *.psm1 | ForEach-Object {
        $relativePath = $_.FullName.Substring($coreDir.Length + 1).Replace('\', '/')
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
        Write-TestResult -Name "No Windows-only APIs in src/ (outside platform guards)" -Status Pass
    } else {
        $sample = ($cpViolations | Select-Object -First 15) -join "`n  "
        $extra = if ($cpViolations.Count -gt 15) { "`n  ... and $($cpViolations.Count - 15) more" } else { "" }
        Write-TestResult -Name "No Windows-only APIs in src/ (outside platform guards)" -Status Fail `
            -Message "Found $($cpViolations.Count) violation(s):`n  $sample$extra"
    }
} else {
    Write-TestResult -Name "Cross-platform hygiene" -Status Skip -Message "core/ not found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# STUDIO NAMING HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  STUDIO NAMING" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$studioDir = Join-Path $repoRoot "src" "studio-ui"
Assert-PathExists -Name "src/studio-ui/ directory exists" -Path $studioDir

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

    # .gitignore references studio-ui (not workflow-editor)
    $gitignorePath = Join-Path $repoRoot ".gitignore"
    if (Test-Path $gitignorePath) {
        Assert-FileContains -Name ".gitignore references src/studio-ui/static" -Path $gitignorePath -Pattern "src/studio-ui/static"
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

# Scans scripts/*.ps1 and bootstrap.ps1 for banned output patterns.
# All terminal output must use theme helpers from Platform-Functions.psm1.
# See CLAUDE.md "Terminal Output Rules" for the full policy.

$themeTargetFiles = @()
# Root bootstrap script (install.ps1 was retired in Phase 6)
$rootBootstrap = Join-Path $repoRoot "bootstrap.ps1"
if (Test-Path $rootBootstrap) { $themeTargetFiles += $rootBootstrap }
# All scripts/*.ps1
$scriptsDir = Join-Path $repoRoot "src" "cli"
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
    Write-TestResult -Name "No raw Write-Host/Verbose/Warning in scripts/ or bootstrap.ps1 (theme hygiene)" -Status Pass
} else {
    $sample = ($themeViolations | Select-Object -First 15) -join "`n  "
    $extra = if ($themeViolations.Count -gt 15) { "`n  ... and $($themeViolations.Count - 15) more" } else { "" }
    Write-TestResult -Name "No raw Write-Host/Verbose/Warning in scripts/ or bootstrap.ps1 (theme hygiene)" -Status Fail `
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

$workflowsDir = Join-Path $repoRoot "content" "workflows"
$invariantTargetFiles = @()
if (Test-Path $workflowsDir) {
    $invariantTargetFiles += @(Get-ChildItem -Path $workflowsDir -Recurse -Include "*.ps1", "*.psm1" -File)
}

# Exempt: files that format user-provided display text where locale casing
# is arguably correct (not identifiers, not persisted to disk, not dispatched).
$invariantExemptPaths = @(
    'DotbotTheme.psm1'  # Write-Header letter-spacing formatter; takes user titles
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
# TASK FILE MUTATION HYGIENE
# ═══════════════════════════════════════════════════════════════════

Write-Host "  TASK FILE MUTATION HYGIENE" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

# Every write to a task JSON file under .bot/workspace/tasks/<state>/*.json
# must go through TaskFile.psm1 (Write-TaskFileAtomic, Write-TaskFileRawAtomic,
# Move-TaskFileAtomic, Remove-TaskFileAtomic) so that writes are atomic,
# retry-aware, and serialised on a per-task lock.
#
# Strategy: scan every .ps1/.psm1 under src/, flag any line that calls
# Set-Content / Out-File / [IO.File]::WriteAllText, and keep only the
# matches whose target path looks like a task JSON file. We identify a
# task target by checking the line itself plus the six preceding lines
# for any of these indicators: a literal "tasks/<state>" path fragment,
# a well-known task-path variable name ($taskFile, $todoPath,
# $needsInputDir, $newFilePath, $result.file_path, $found.FullName,
# $restorePath, etc.), or a Set-TaskState return shape ($result.task_*).
# Decision/plan/session/manifest writes don't match these indicators and
# are therefore left alone.

$taskMutationTargetFiles = @()
$taskMutationScanDirs = @(
    (Join-Path $repoRoot "src" "mcp"),
    (Join-Path $repoRoot "src" "runtime"),
    (Join-Path $repoRoot "src" "ui"),
    (Join-Path $repoRoot "src" "cli"),
    (Join-Path $repoRoot "src" "hooks")
)
foreach ($dir in $taskMutationScanDirs) {
    if (Test-Path $dir) {
        $taskMutationTargetFiles += @(Get-ChildItem -Path $dir -Recurse -Include "*.ps1", "*.psm1" -File)
    }
}

# The canonical helper is the only place allowed to write task files
# directly. Test files set up fixtures and are exempt.
$taskMutationExemptFiles = @(
    'TaskFile.psm1'
)

$taskWritePattern = '(?:\|\s*(?:Set-Content|Out-File)\b)|(?:\[(?:System\.)?IO\.File\]::Write(?:All(?:Text|Bytes|Lines))?\s*\()'

# Indicators that the context is a task JSON write. Kept tight to avoid
# false positives on decision/plan/session writes that also use generic
# variable names like $targetPath or $found.file.FullName.
#  - Literal "tasks/<state>" path fragments (strongest signal)
#  - State directory variables ($todoDir, $analysingDir, etc.)
#  - TaskStore return shape ($result.file_path, $result.task_content)
#  - $taskFile / $taskBackup / $newFilePath in a task-state context
#  - $restorePath (worktree backup restore)
# Case-INsensitive — PowerShell variable and property names are
# case-insensitive at runtime ($TaskFile and $taskFile are the same
# variable), so coding-convention casing is not a reliable signal.
# $found.File.FullName is therefore NOT used as an indicator: it
# legitimately appears in both task and decision contexts, so we rely
# on the stronger surrounding signals instead.
$taskIndicatorPattern = '(?ix)
    tasks[\\/](?:todo|analysing|needs-input|analysed|in-progress|done|skipped|split|cancelled|edited_tasks|deleted_tasks) |
    \$tasksBaseDir | \$tasksDir |
    \$todoDir | \$analysingDir | \$analysedDir | \$inProgressDir | \$doneDir |
    \$needsInputDir | \$skippedDir | \$splitDir | \$cancelledDir |
    \$todoPath | \$analysingPath | \$analysedPath | \$inProgressPath |
    \$donePath | \$needsInputPath | \$skippedPath |
    \$newFilePath\b | \$newTaskPath\b |
    \$taskFile\. | \$taskBackup |
    \$result\.file_path | \$result\.task_content |
    \$restorePath\b
'

$taskMutationViolations = @()
foreach ($file in $taskMutationTargetFiles) {
    if ($file.Name -in $taskMutationExemptFiles) { continue }
    # Exempt test files — they set up fixtures and don't mutate production state.
    if ($file.Name -match '(?i)(^|[._-])tests?\.ps1$') { continue }
    if ($file.FullName -match '[\\/]tests[\\/]') { continue }

    $lines = Get-Content -LiteralPath $file.FullName
    for ($lineNum = 0; $lineNum -lt $lines.Count; $lineNum++) {
        $line = $lines[$lineNum]
        if ($line.TrimStart() -match '^\s*#') { continue }
        if ($line -notmatch $taskWritePattern) { continue }

        # Pipelines can wrap across lines (backtick continuation or trailing
        # pipe). Look at this line plus the preceding 6 to catch context.
        $start = [Math]::Max(0, $lineNum - 6)
        $context = ($lines[$start..$lineNum] -join "`n")
        if ($context -notmatch $taskIndicatorPattern) { continue }

        $relPath = $file.FullName.Substring($repoRoot.Length + 1)
        $taskMutationViolations += "${relPath}:$($lineNum + 1) writes task JSON directly — use Write-TaskFileAtomic / Move-TaskFileAtomic from TaskFile.psm1"
    }
}

if ($taskMutationViolations.Count -eq 0) {
    Write-TestResult -Name "No direct task-JSON writes outside TaskFile.psm1 (mutation hygiene)" -Status Pass
} else {
    $sample = ($taskMutationViolations | Select-Object -First 15) -join "`n  "
    $extra = if ($taskMutationViolations.Count -gt 15) { "`n  ... and $($taskMutationViolations.Count - 15) more" } else { "" }
    Write-TestResult -Name "No direct task-JSON writes outside TaskFile.psm1 (mutation hygiene)" -Status Fail `
        -Message "Found $($taskMutationViolations.Count) violation(s). Use Write-TaskFileAtomic / Move-TaskFileAtomic from src/mcp/modules/TaskFile.psm1 instead.`n  $sample$extra"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# FRAMEWORK FILE PROTECTION
# ═══════════════════════════════════════════════════════════════════

Write-Host "  FRAMEWORK FILE PROTECTION" -ForegroundColor Cyan
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

$frameworkIntegrityModule = Join-Path $repoRoot "src" "mcp" "modules" "FrameworkIntegrity.psm1"
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

$frameworkIntegrityHook = Join-Path $repoRoot "src" "hooks" "verify" "04-framework-integrity.ps1"
Assert-PathExists -Name "04-framework-integrity.ps1 verify hook exists" -Path $frameworkIntegrityHook
Assert-ValidPowerShell -Name "04-framework-integrity.ps1 is valid PowerShell" -Path $frameworkIntegrityHook
if (Test-Path $frameworkIntegrityHook) {
    Assert-FileContains -Name "04-framework-integrity imports FrameworkIntegrity module" `
        -Path $frameworkIntegrityHook -Pattern 'FrameworkIntegrity\.psm1'
}

$verifyConfig = Join-Path $repoRoot "src" "hooks" "verify" "config.json"
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

# removed the task-mark-* MCP tools; the FrameworkIntegrity gate
# now runs from the runtime ( + transition hooks) rather than
# from a tool script. The verify-hook coverage lives in the
# 04-framework-integrity.ps1 assertions above.

# Phase 4 retired init-time generation of: pre-commit hooks, .bot/.manifest.json,
# provider configs, and the framework-protection marker block
# in CLAUDE.md/AGENTS.md/GEMINI.md. The corresponding init-project.ps1 +
# src/init.ps1 + Manifest.psm1 + FrameworkIntegrity assertions moved with them.
# Layer-2 Phase 4 footprint tests live in Test-Components.ps1.

# DO NOT MODIFY headers on key framework files
$headerBannerPattern = 'FRAMEWORK FILE.*DO NOT MODIFY'
$bannerTargets = @(
    'src/mcp/dotbot-mcp.ps1',
    'src/hooks/verify/00-privacy-scan.ps1',
    'src/hooks/verify/01-git-clean.ps1',
    'src/hooks/verify/02-git-pushed.ps1',
    'src/hooks/verify/03-check-md-refs.ps1',
    'src/hooks/verify/04-framework-integrity.ps1',
    'src/hooks/scripts/commit-bot-state.ps1',
    'src/hooks/scripts/steering.ps1',
    'src/hooks/dev/Start-Dev.ps1',
    'src/hooks/dev/Stop-Dev.ps1',
    'content/agents/implementer/AGENT.md',
    'content/agents/planner/AGENT.md',
    'content/agents/reviewer/AGENT.md',
    'content/agents/tester/AGENT.md'
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

# Phase 4 retired .bot/.manifest.json generation; the README no longer
# documents it. The "Keep .bot/ tracked" guidance also moved out of the
# README's intro since the new init never writes framework files into .bot/.

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# NEEDS-REVIEW FEATURE — backend wiring is on disk
# ═══════════════════════════════════════════════════════════════════
# Layer-1 guards against silent removal of the needs-review surface:
# the status enum, the transition edges, the Reset-TaskWorktree export,
# and the two MCP tools that drive review submission.

$transitionsModule = Join-Path $repoRoot 'src/runtime/Modules/Dotbot.Task/Private/Transitions.psm1'
if (Test-Path $transitionsModule) {
    Assert-FileContains -Name "Dotbot.Task: needs-review in status enum" `
        -Path $transitionsModule -Pattern "'needs-review'"
    Assert-FileContains -Name "Dotbot.Task: needs-review row in transition map" `
        -Path $transitionsModule -Pattern "'needs-review'\s*=\s*@\("
}

$worktreeModule = Join-Path $repoRoot 'src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psm1'
if (Test-Path $worktreeModule) {
    Assert-FileContains -Name "Dotbot.Worktree: Reset-TaskWorktree function defined" `
        -Path $worktreeModule -Pattern "function Reset-TaskWorktree"
}
$worktreeManifest = Join-Path $repoRoot 'src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1'
if (Test-Path $worktreeManifest) {
    Assert-FileContains -Name "Dotbot.Worktree: Reset-TaskWorktree exported via .psd1" `
        -Path $worktreeManifest -Pattern "'Reset-TaskWorktree'"
}

foreach ($toolName in @('task-mark-needs-review','task-submit-review')) {
    $toolDir  = Join-Path $repoRoot "src/mcp/tools/$toolName"
    $metaPath = Join-Path $toolDir   'metadata.json'
    $scrPath  = Join-Path $toolDir   'script.ps1'
    Assert-True -Name "MCP tool '$toolName': metadata.json present" `
        -Condition (Test-Path $metaPath)
    Assert-True -Name "MCP tool '$toolName': script.ps1 present" `
        -Condition (Test-Path $scrPath)
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 1: Structure"

if (-not $allPassed) {
    exit 1
}
