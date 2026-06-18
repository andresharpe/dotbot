#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 3: Mock Claude integration tests.
.DESCRIPTION
    Tests the Claude CLI integration using a mock executable.
    Validates stream parsing and prompt capture.
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
    Write-TestResult -Name "Layer 3 prerequisites" -Status Fail -Message "dotbot not installed globally — set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
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
    foreach ($shimName in @("claude", "opencode")) {
        $unixShim = Join-Path $testsDir $shimName
        if (Test-Path $unixShim) {
            $content = [System.IO.File]::ReadAllText($unixShim) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($unixShim, $content)
            & chmod +x $unixShim 2>$null
        }
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
    $harnessModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psd1"
    if (Test-Path $harnessModule) {
        try {
            # Import the Dotbot.Theme dependency first
            $themeModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1"
            if (Test-Path $themeModule) {
                Import-Module $themeModule -Force
            }

            Import-Module $harnessModule -Force

            # Test Invoke-HarnessStream with the mock — capture stderr (where logs go)
            $streamError = $null
            try {
                # Redirect all output to null — we just want to verify no crash
                Invoke-HarnessStream -Prompt "Test prompt for mock validation" -Model "best" -HarnessName "claude" *>&1 | Out-Null
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

            # Regression for #389: stream readers must stop when the task has
            # reached a terminal state, even if the provider process stays alive
            # silently after emitting a result.
            try {
                $modeFile = Join-Path $mockLogDir "mock-claude-mode.txt"
                "hang-after-result" | Set-Content -Path $modeFile
                $stopAfter = (Get-Date).AddMilliseconds(500)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                Invoke-HarnessStream `
                    -Prompt "Stop predicate hang test" `
                    -Model "opus" `
                    -HarnessName "claude" `
                    -ShouldStopStream { return ((Get-Date) -ge $stopAfter) } `
                    -StopCheckIntervalSeconds 1 `
                    -StopGraceSeconds 0 `
                    -StopReason "mock task reached terminal state" *>&1 | Out-Null
                $sw.Stop()
                Assert-True -Name "Invoke-HarnessStream exits when stop predicate fires (#389)" `
                    -Condition ($sw.Elapsed.TotalSeconds -lt 10) `
                    -Message "Expected stream to stop within 10s, took $([math]::Round($sw.Elapsed.TotalSeconds, 2))s"
            } catch {
                Write-TestResult -Name "Invoke-HarnessStream exits when stop predicate fires (#389)" -Status Fail -Message $_.Exception.Message
            } finally {
                if (Test-Path $modeFile) { Remove-Item $modeFile -Force }
            }

            # #467: a stream-json error event (e.g. mid-run auth expiry) is
            # surfaced to the caller as ErrorText so the failure classifier can
            # detect it instead of receiving empty text.
            try {
                $modeFile = Join-Path $mockLogDir "mock-claude-mode.txt"
                "auth-error" | Set-Content -Path $modeFile
                $authResult = Invoke-HarnessStream -Prompt "Auth expiry test" -Model "best" -HarnessName "claude" 2>$null
                Assert-True -Name "Invoke-HarnessStream surfaces stream error as ErrorText (#467)" `
                    -Condition ($null -ne $authResult -and $authResult.ErrorText -match 'OAuth token expired') `
                    -Message "Expected ErrorText to carry the auth-expiry message, got: '$($authResult.ErrorText)'"
            } catch {
                Write-TestResult -Name "Invoke-HarnessStream surfaces stream error as ErrorText (#467)" -Status Fail -Message $_.Exception.Message
            } finally {
                if (Test-Path $modeFile) { Remove-Item $modeFile -Force }
            }

        } catch {
            Write-TestResult -Name "Dotbot.Harness module import" -Status Fail -Message $_.Exception.Message
        }
    } else {
        Write-TestResult -Name "Dotbot.Harness module tests" -Status Skip -Message "Module not found at $harnessModule"
    }

    Write-Host ""

    # ═══════════════════════════════════════════════════════════════════
    # INVOKE-HARNESSSTREAM WITH MOCK OPENCODE
    # ═══════════════════════════════════════════════════════════════════

    Write-Host "  INVOKE-HARNESSSTREAM OPENCODE" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    if (Test-Path $harnessModule) {
        $openCodePromptLog = Join-Path $mockLogDir "mock-opencode-prompt.log"
        $openCodeArgsLog = Join-Path $mockLogDir "mock-opencode-args.log"
        $longOpenCodePrompt = "OpenCode attached prompt sentinel " + ("x" * 9000)

        try {
            Invoke-HarnessStream -Prompt $longOpenCodePrompt -Model "best" -HarnessName "opencode" *>&1 | Out-Null
            Assert-True -Name "Invoke-HarnessStream doesn't crash with mock OpenCode" -Condition $true
        } catch {
            Write-TestResult -Name "Invoke-HarnessStream doesn't crash with mock OpenCode" -Status Fail -Message $_.Exception.Message
        }

        if (Test-Path $openCodePromptLog) {
            $capturedOpenCodePrompt = Get-Content $openCodePromptLog -Raw
            Assert-True -Name "OpenCode harness sends full prompt via attached file" `
                -Condition ($capturedOpenCodePrompt -match "OpenCode attached prompt sentinel" -and $capturedOpenCodePrompt.Length -gt 9000) `
                -Message "Expected long prompt content in mock OpenCode attached file"
        } else {
            Write-TestResult -Name "OpenCode harness sends full prompt via attached file" -Status Fail -Message "Mock OpenCode prompt log was not created"
        }

        if (Test-Path $openCodeArgsLog) {
            $capturedOpenCodeArgs = Get-Content $openCodeArgsLog -Raw
            Assert-True -Name "OpenCode harness passes --file" `
                -Condition ($capturedOpenCodeArgs -match "(?m)^--file$") `
                -Message "Expected --file in OpenCode args: $capturedOpenCodeArgs"
            Assert-True -Name "OpenCode harness keeps raw prompt off command line" `
                -Condition (-not ($capturedOpenCodeArgs -match "OpenCode attached prompt sentinel")) `
                -Message "Long prompt should not be passed as a native CLI argument"
        }
    } else {
        Write-TestResult -Name "OpenCode mock harness tests" -Status Skip -Message "Dotbot.Harness module not available"
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
            Invoke-HarnessStream -Prompt "Permission test default" -Model "best" -HarnessName "claude" *>&1 | Out-Null
            if (Test-Path $argsLog) {
                $capturedArgs = Get-Content $argsLog -Raw
                Assert-True -Name "Default permission mode includes --dangerously-skip-permissions" `
                    -Condition ($capturedArgs -match "dangerously-skip-permissions") `
                    -Message "Expected bypass flag in captured args"
            }

            # Explicit auto permission mode (resolves to --permission-mode auto from config)
            Invoke-HarnessStream -Prompt "Permission test auto" -Model "best" -HarnessName "claude" -PermissionMode "auto" *>&1 | Out-Null
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
                Invoke-HarnessStream -Prompt "cwd test explicit" -Model "best" -HarnessName "claude" -WorkingDirectory $tempCwd *>&1 | Out-Null
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
                Invoke-HarnessStream -Prompt "cwd test fallback" -Model "best" -HarnessName "claude" *>&1 | Out-Null
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
