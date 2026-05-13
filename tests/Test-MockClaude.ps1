#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 3: Mock Claude integration tests.
.DESCRIPTION
    Tests the Claude CLI integration using a mock executable.
    Validates stream parsing, prompt capture, and rate limit detection.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 3: Mock Claude Integration Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

# Check prerequisite: dotbot must be installed (for Dotbot.Harness module)
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 3 prerequisites" -Status Fail -Message "dotbot not installed globally — run install.ps1 first"
    Write-TestSummary -LayerName "Layer 3: Mock Claude"
    exit 1
}

# Set up mock log directory
$mockLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-mock-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $mockLogDir -Force | Out-Null
$env:DOTBOT_MOCK_LOG_DIR = $mockLogDir
$promptLog = Join-Path $mockLogDir "mock-claude-prompt.log"

# Save original PATH and prepend tests/ directory so mock claude is found first
$originalPath = $env:PATH
$testsDir = $PSScriptRoot
$env:PATH = "$testsDir$([System.IO.Path]::PathSeparator)$env:PATH"

# Ensure unix shim is executable and has LF line endings (macOS rejects CRLF shebangs)
if (-not $IsWindows) {
    $unixShim = Join-Path $testsDir "claude"
    if (Test-Path $unixShim) {
        $content = [System.IO.File]::ReadAllText($unixShim) -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($unixShim, $content)
        & chmod +x $unixShim 2>$null
    }
}

try {
    # ═══════════════════════════════════════════════════════════════════
    # MOCK CLAUDE BASIC
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  MOCK CLAUDE BASIC" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Verify mock is on PATH
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    Assert-True -Name "Mock claude is on PATH" `
        -Condition ($null -ne $claudeCmd) `
        -Message "claude not found after PATH shimming"

    if ($claudeCmd) {
        # Verify it resolves to our mock (not real claude)
        $resolvedPath = $claudeCmd.Source
        $isOurMock = $resolvedPath -like "*tests*"
        Assert-True -Name "Resolved claude is our mock" `
            -Condition $isOurMock `
            -Message "Resolved to: $resolvedPath (expected path containing 'tests')"

        # Verify shim executable actually dispatches to the mock script
        & $resolvedPath --model test --output-format stream-json --print -- "Hello shim" 2>&1 | Out-Null
        $shimPrompt = if (Test-Path $promptLog) { Get-Content $promptLog -Raw } else { "" }
        Assert-True -Name "Shim claude dispatches to mock script" `
            -Condition ($shimPrompt -match "Hello shim") `
            -Message "Shim executable didn't pass prompt through to mock script"
    }

    # Run mock directly and check output (call mock-claude.ps1 directly for cross-platform reliability;
    # shim resolution is already validated by the PATH tests above)
    $mockScript = Join-Path $testsDir "mock-claude.ps1"
    & $mockScript --model test --print --output-format stream-json -- "Hello test" 2>&1 | Out-Null
    Assert-PathExists -Name "Mock logs prompt to file" -Path $promptLog

    if (Test-Path $promptLog) {
        $capturedPrompt = Get-Content $promptLog -Raw
        Assert-True -Name "Mock captured prompt text" `
            -Condition ($capturedPrompt -match "Hello test") `
            -Message "Prompt log doesn't contain expected text"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # INVOKE-HARNESSSTREAM WITH MOCK
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  INVOKE-HARNESSSTREAM" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Import Dotbot.Harness module
    $harnessModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psm1"
    if (Test-Path $harnessModule) {
        try {
            # Import the Dotbot.Theme dependency first
            $themeModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psm1"
            if (Test-Path $themeModule) {
                Import-Module $themeModule -Force
            }

            Import-Module $harnessModule -Force

            # Test Invoke-HarnessStream with the mock — capture stderr (where logs go)
            $streamError = $null
            try {
                # Redirect all output to null — we just want to verify no crash
                Invoke-HarnessStream -Prompt "Test prompt for mock validation" -Model "opus" -HarnessName "claude" *>&1 | Out-Null
                Assert-True -Name "Invoke-HarnessStream doesn't crash with mock" -Condition $true
            } catch {
                $streamError = $_.Exception.Message
                Write-TestResult -Name "Invoke-HarnessStream doesn't crash with mock" -Status Fail -Message $streamError
            }

            # Verify prompt was captured by mock
            if (Test-Path $promptLog) {
                $capturedPrompt2 = Get-Content $promptLog -Raw
                Assert-True -Name "HarnessStream sent prompt to mock" `
                    -Condition ($capturedPrompt2 -match "Test prompt for mock validation") `
                    -Message "Prompt not captured correctly"
            }

        } catch {
            Write-TestResult -Name "Dotbot.Harness module import" -Status Fail -Message $_.Exception.Message
        }
    } else {
        Write-TestResult -Name "Dotbot.Harness module tests" -Status Skip -Message "Module not found at $harnessModule"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # PERMISSION MODE ARGS
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  PERMISSION MODE ARGS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $argsLog = Join-Path $mockLogDir "mock-claude-args.log"

    if (Test-Path $harnessModule) {
        try {
            # Default permission mode (resolves to --dangerously-skip-permissions from config)
            Invoke-HarnessStream -Prompt "Permission test default" -Model "opus" -HarnessName "claude" *>&1 | Out-Null
            if (Test-Path $argsLog) {
                $capturedArgs = Get-Content $argsLog -Raw
                Assert-True -Name "Default permission mode includes --dangerously-skip-permissions" `
                    -Condition ($capturedArgs -match "dangerously-skip-permissions") `
                    -Message "Expected bypass flag in captured args"
            }

            # Explicit auto permission mode (resolves to --permission-mode auto from config)
            Invoke-HarnessStream -Prompt "Permission test auto" -Model "opus" -HarnessName "claude" -PermissionMode "auto" *>&1 | Out-Null
            if (Test-Path $argsLog) {
                $capturedArgs = Get-Content $argsLog -Raw
                Assert-True -Name "Auto permission mode includes --permission-mode" `
                    -Condition ($capturedArgs -match "permission-mode") `
                    -Message "Expected --permission-mode in captured args"
                Assert-True -Name "Auto permission mode includes auto value" `
                    -Condition ($capturedArgs -match "(?m)^auto$") `
                    -Message "Expected 'auto' in captured args"
                $noBypass = -not ($capturedArgs -match "dangerously-skip-permissions")
                Assert-True -Name "Auto permission mode does not include bypass flag" `
                    -Condition $noBypass `
                    -Message "Should not contain bypass flag when using auto mode"
            }
        } catch {
            Write-TestResult -Name "Permission mode args test" -Status Fail -Message $_.Exception.Message
        }
    } else {
        Write-TestResult -Name "Permission mode args tests" -Status Skip -Message "Dotbot.Harness module not available"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # WORKING DIRECTORY (#314)
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  WORKING DIRECTORY (#314)" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    if (Test-Path $harnessModule) {
        $cwdLog = Join-Path $mockLogDir "mock-claude-cwd.log"
        $tempCwd = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-cwd-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $tempCwd -ItemType Directory -Force | Out-Null

        # Canonicalize to match what the kernel reports as cwd inside the spawned process.
        # - Windows: Resolve-Path expands short-name segments (RUNNER~1 -> runneradmin).
        # - macOS:   /var, /tmp, /etc are symlinks to /private/*. getcwd() in the child
        #            returns the resolved /private/* form, so we follow links here too.
        # - Linux:   pwd -P resolves any symlinks in path components.
        # Resolve-Path alone does not follow symlinks, so on POSIX we shell out to pwd -P.
        function Get-CanonicalCwd {
            param([Parameter(Mandatory)][string]$Path)
            $resolved = (Resolve-Path -LiteralPath $Path).Path
            if ($IsMacOS -or $IsLinux) {
                $shellResolved = & /bin/sh -c "cd `"$resolved`" && pwd -P" 2>$null
                if ($LASTEXITCODE -eq 0 -and $shellResolved) {
                    $resolved = $shellResolved.Trim()
                }
            }
            return $resolved
        }

        $expectedCwd = Get-CanonicalCwd -Path $tempCwd

        # Save and rebuild $global:DotbotProjectRoot so the fallback assertion is deterministic
        $savedDotbotProjectRoot = $global:DotbotProjectRoot
        $global:DotbotProjectRoot = Get-CanonicalCwd -Path (Split-Path -Parent $dotbotDir)

        try {
            # 1. -WorkingDirectory pins the child cwd
            try {
                Invoke-HarnessStream -Prompt "cwd test explicit" -Model "opus" -HarnessName "claude" -WorkingDirectory $tempCwd *>&1 | Out-Null
                $captured = if (Test-Path $cwdLog) { (Get-Content $cwdLog -Raw).Trim() } else { "" }
                $pathsMatch = if ($IsWindows) { $captured -ieq $expectedCwd } else { $captured -ceq $expectedCwd }
                Assert-True -Name "Invoke-HarnessStream pins cwd to -WorkingDirectory (#314)" `
                    -Condition $pathsMatch `
                    -Message "Expected cwd=$expectedCwd, got cwd=$captured"
            } catch {
                Write-TestResult -Name "Invoke-HarnessStream pins cwd to -WorkingDirectory (#314)" -Status Fail -Message $_.Exception.Message
            }

            # 2. Without -WorkingDirectory, falls back to $global:DotbotProjectRoot
            try {
                Invoke-HarnessStream -Prompt "cwd test fallback" -Model "opus" -HarnessName "claude" *>&1 | Out-Null
                $captured = if (Test-Path $cwdLog) { (Get-Content $cwdLog -Raw).Trim() } else { "" }
                $pathsMatch = if ($IsWindows) { $captured -ieq $global:DotbotProjectRoot } else { $captured -ceq $global:DotbotProjectRoot }
                Assert-True -Name "Invoke-HarnessStream falls back to DotbotProjectRoot when -WorkingDirectory not set" `
                    -Condition $pathsMatch `
                    -Message "Expected cwd=$global:DotbotProjectRoot, got cwd=$captured"
            } catch {
                Write-TestResult -Name "Invoke-HarnessStream falls back to DotbotProjectRoot when -WorkingDirectory not set" -Status Fail -Message $_.Exception.Message
            }
        } finally {
            $global:DotbotProjectRoot = $savedDotbotProjectRoot
            if (Test-Path $tempCwd) {
                Remove-Item -Path $tempCwd -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-TestResult -Name "Working directory tests" -Status Skip -Message "Dotbot.Harness module not available"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # RATE LIMIT DETECTION
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  RATE LIMIT DETECTION" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    if (Test-Path $harnessModule) {
        try {
            # Set mock to rate-limit mode
            $modeFile = Join-Path $mockLogDir "mock-claude-mode.txt"
            "rate-limit" | Set-Content -Path $modeFile

            # Run Invoke-HarnessStream — adapter should detect the rate limit
            try {
                Invoke-HarnessStream -Prompt "Rate limit test" -Model "opus" -HarnessName "claude" *>&1 | Out-Null
            } catch {
                # May throw on rate limit, that's OK
            }

            # Check if rate limit was detected
            $rateLimitInfo = Get-LastHarnessRateLimitInfo
            Assert-True -Name "Rate limit detected by stream parser" `
                -Condition ($null -ne $rateLimitInfo) `
                -Message "Get-LastHarnessRateLimitInfo returned null"

            if ($rateLimitInfo) {
                Assert-True -Name "Rate limit message captured" `
                    -Condition ($rateLimitInfo -match "limit|reset") `
                    -Message "Unexpected rate limit message: $rateLimitInfo"
            }

        } catch {
            Write-TestResult -Name "Rate limit detection" -Status Fail -Message $_.Exception.Message
        } finally {
            # Reset mock mode
            if (Test-Path $modeFile) { Remove-Item $modeFile -Force }
        }
    } else {
        Write-TestResult -Name "Rate limit detection tests" -Status Skip -Message "Dotbot.Harness module not available"
    }

} finally {
    # Restore original PATH
    $env:PATH = $originalPath
    $env:DOTBOT_MOCK_LOG_DIR = $null

    # Cleanup mock log directory
    if (Test-Path $mockLogDir) {
        Remove-Item $mockLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════

$allPassed = Write-TestSummary -LayerName "Layer 3: Mock Claude"

if (-not $allPassed) {
    exit 1
}
