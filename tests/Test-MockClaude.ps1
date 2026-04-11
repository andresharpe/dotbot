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

# Check prerequisite: dotbot must be installed (for ClaudeCLI module)
$dotbotInstalled = Test-Path (Join-Path $dotbotDir "workflows\default")
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
    $mockOutput = & $mockScript --model test --print --output-format stream-json -- "Hello test" 2>&1
    Assert-PathExists -Name "Mock logs prompt to file" -Path $promptLog

    if (Test-Path $promptLog) {
        $capturedPrompt = Get-Content $promptLog -Raw
        Assert-True -Name "Mock captured prompt text" `
            -Condition ($capturedPrompt -match "Hello test") `
            -Message "Prompt log doesn't contain expected text"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # INVOKE-CLAUDESTREAM WITH MOCK
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  INVOKE-CLAUDESTREAM" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    # Import ClaudeCLI module
    $claudeModule = Join-Path $dotbotDir "workflows\default\systems\runtime\ClaudeCLI\ClaudeCLI.psm1"
    if (Test-Path $claudeModule) {
        try {
            # Import the DotBotTheme dependency first
            $themeModule = Join-Path $dotbotDir "workflows\default\systems\runtime\modules\DotBotTheme.psm1"
            if (Test-Path $themeModule) {
                Import-Module $themeModule -Force
            }

            Import-Module $claudeModule -Force

            # Test Invoke-ClaudeStream with the mock — capture stderr (where logs go)
            # The function writes to console, so we just verify it doesn't throw
            $streamError = $null
            try {
                # Redirect all output to null — we just want to verify no crash
                Invoke-ClaudeStream -Prompt "Test prompt for mock validation" -Model "opus" *>&1 | Out-Null
                Assert-True -Name "Invoke-ClaudeStream doesn't crash with mock" -Condition $true
            } catch {
                $streamError = $_.Exception.Message
                Write-TestResult -Name "Invoke-ClaudeStream doesn't crash with mock" -Status Fail -Message $streamError
            }

            # Verify prompt was captured by mock
            if (Test-Path $promptLog) {
                $capturedPrompt2 = Get-Content $promptLog -Raw
                Assert-True -Name "ClaudeStream sent prompt to mock" `
                    -Condition ($capturedPrompt2 -match "Test prompt for mock validation") `
                    -Message "Prompt not captured correctly"
            }

        } catch {
            Write-TestResult -Name "ClaudeCLI module import" -Status Fail -Message $_.Exception.Message
        }
    } else {
        Write-TestResult -Name "ClaudeCLI module tests" -Status Skip -Message "Module not found at $claudeModule"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # PERMISSION MODE ARGS
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  PERMISSION MODE ARGS" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $argsLog = Join-Path $mockLogDir "mock-claude-args.log"

    if (Test-Path $claudeModule) {
        try {
            # Test default PermissionArgs (--dangerously-skip-permissions)
            Invoke-ClaudeStream -Prompt "Permission test default" -Model "opus" *>&1 | Out-Null
            if (Test-Path $argsLog) {
                $capturedArgs = Get-Content $argsLog -Raw
                Assert-True -Name "Default PermissionArgs includes --dangerously-skip-permissions" `
                    -Condition ($capturedArgs -match "dangerously-skip-permissions") `
                    -Message "Expected bypass flag in captured args"
            }

            # Test custom PermissionArgs (--permission-mode auto)
            Invoke-ClaudeStream -Prompt "Permission test auto" -Model "opus" -PermissionArgs @("--permission-mode", "auto") *>&1 | Out-Null
            if (Test-Path $argsLog) {
                $capturedArgs = Get-Content $argsLog -Raw
                Assert-True -Name "Custom PermissionArgs includes --permission-mode" `
                    -Condition ($capturedArgs -match "permission-mode") `
                    -Message "Expected --permission-mode in captured args"
                Assert-True -Name "Custom PermissionArgs includes auto value" `
                    -Condition ($capturedArgs -match "(?m)^auto$") `
                    -Message "Expected 'auto' in captured args"
                $noBypass = -not ($capturedArgs -match "dangerously-skip-permissions")
                Assert-True -Name "Custom PermissionArgs does not include bypass flag" `
                    -Condition $noBypass `
                    -Message "Should not contain bypass flag when using auto mode"
            }
        } catch {
            Write-TestResult -Name "Permission mode args test" -Status Fail -Message $_.Exception.Message
        }
    } else {
        Write-TestResult -Name "Permission mode args tests" -Status Skip -Message "ClaudeCLI module not available"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # RATE LIMIT DETECTION
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  RATE LIMIT DETECTION" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    if (Test-Path $claudeModule) {
        try {
            # Set mock to rate-limit mode
            $modeFile = Join-Path $mockLogDir "mock-claude-mode.txt"
            "rate-limit" | Set-Content -Path $modeFile

            # Run Invoke-ClaudeStream — it should detect the rate limit
            try {
                Invoke-ClaudeStream -Prompt "Rate limit test" -Model "opus" *>&1 | Out-Null
            } catch {
                # May throw on rate limit, that's OK
            }

            # Check if rate limit was detected
            $rateLimitInfo = Get-LastRateLimitInfo
            Assert-True -Name "Rate limit detected by stream parser" `
                -Condition ($null -ne $rateLimitInfo) `
                -Message "Get-LastRateLimitInfo returned null"

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
        Write-TestResult -Name "Rate limit detection tests" -Status Skip -Message "ClaudeCLI module not available"
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
