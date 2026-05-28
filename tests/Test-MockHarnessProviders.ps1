#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 3: Mock harness provider integration tests.
.DESCRIPTION
    Validates non-Claude harness adapters with local CLI shims so provider
    argument construction and stream parsing stay covered without credentials.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$dotbotDir = Get-DotbotInstallDir

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Layer 3: Mock Harness Provider Tests" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

$dotbotInstalled = Test-Path (Join-Path $dotbotDir "src")
if (-not $dotbotInstalled) {
    Write-TestResult -Name "Layer 3 prerequisites" -Status Fail -Message "dotbot not installed globally — set DOTBOT_HOME to a dotbot checkout (src/ + content/ must exist)"
    Write-TestSummary -LayerName "Layer 3: Mock Harness Providers"
    exit 1
}

$mockLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-mock-harness-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $mockLogDir -Force | Out-Null
$env:DOTBOT_MOCK_LOG_DIR = $mockLogDir

$originalPath = $env:PATH
$env:PATH = "$PSScriptRoot$([System.IO.Path]::PathSeparator)$env:PATH"

if (-not $IsWindows) {
    foreach ($shimName in @("codex", "opencode")) {
        $shim = Join-Path $PSScriptRoot $shimName
        if (Test-Path $shim) {
            $content = [System.IO.File]::ReadAllText($shim) -replace "`r`n", "`n"
            [System.IO.File]::WriteAllText($shim, $content)
            & chmod +x $shim 2>$null
        }
    }
}

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

try {
    $themeModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Theme/Dotbot.Theme.psd1"
    $harnessModule = Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Harness/Dotbot.Harness.psd1"
    if (Test-Path $themeModule) { Import-Module $themeModule -Force }
    Import-Module $harnessModule -Force

    $tempCwd = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-harness-cwd-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -Path $tempCwd -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $tempCwd ".bot/.control") -ItemType Directory -Force | Out-Null
    $expectedCwd = Get-CanonicalCwd -Path $tempCwd
    $activityLog = Join-Path $tempCwd ".bot/.control/activity.jsonl"

    Write-Host "  CODEX ADAPTER" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    try {
        Push-Location $tempCwd
        try {
            Invoke-HarnessStream -Prompt "Mock Codex prompt" -Model "fast" -HarnessName "codex" -WorkingDirectory $tempCwd *>&1 | Out-Null
            Assert-True -Name "Codex harness stream doesn't crash with mock" -Condition $true
        } finally {
            Pop-Location
        }
    } catch {
        Write-TestResult -Name "Codex harness stream doesn't crash with mock" -Status Fail -Message $_.Exception.Message
    }

    Assert-FileContains -Name "Codex parser logs current item.completed agent message" `
        -Path $activityLog `
        -Pattern "DOTBOT_CODEX_MOCK_OK"

    $codexArgsLog = Join-Path $mockLogDir "mock-codex-args.log"
    $codexPromptLog = Join-Path $mockLogDir "mock-codex-prompt.log"
    $codexCwdLog = Join-Path $mockLogDir "mock-codex-cwd.log"

    Assert-PathExists -Name "Codex mock captured args" -Path $codexArgsLog
    Assert-PathExists -Name "Codex mock captured prompt" -Path $codexPromptLog

    if (Test-Path $codexArgsLog) {
        $codexArgs = Get-Content $codexArgsLog -Raw
        Assert-True -Name "Codex args include worktree root with -C" `
            -Condition (($codexArgs -match "(?m)^-C$") -and ($codexArgs -match [regex]::Escape($expectedCwd))) `
            -Message "Expected -C $expectedCwd in args: $codexArgs"
        Assert-True -Name "Codex args include dotbot MCP env without format errors" `
            -Condition (($codexArgs -match "mcp_servers\.dotbot\.env=\{DOTBOT_HOME=") -and ($codexArgs -match "DOTBOT_PROJECT_ROOT=")) `
            -Message "Expected MCP env inline table in args: $codexArgs"
    }

    if (Test-Path $codexPromptLog) {
        $codexPrompt = Get-Content $codexPromptLog -Raw
        Assert-True -Name "Codex receives prompt over stdin" `
            -Condition ($codexPrompt -match "Mock Codex prompt") `
            -Message "Expected prompt in mock log"
    }

    if (Test-Path $codexCwdLog) {
        $codexCwd = (Get-Content $codexCwdLog -Raw).Trim()
        $pathsMatch = if ($IsWindows) { $codexCwd -ieq $expectedCwd } else { $codexCwd -ceq $expectedCwd }
        Assert-True -Name "Codex process cwd follows -WorkingDirectory" `
            -Condition $pathsMatch `
            -Message "Expected cwd=$expectedCwd, got cwd=$codexCwd"
    }

    Write-Host ""
    Write-Host "  OPENCODE ADAPTER" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $openCodeSession = "not-null"
    try { $openCodeSession = New-HarnessSession -HarnessName "opencode" } catch { Write-Verbose "Session operation failed: $_" }
    Assert-True -Name "OpenCode does not pre-create resume-only sessions" `
        -Condition ($null -eq $openCodeSession) `
        -Message "Expected null session id, got $openCodeSession"

    try {
        Push-Location $tempCwd
        try {
            Invoke-HarnessStream -Prompt "Mock OpenCode prompt" -Model "fast" -HarnessName "opencode" -WorkingDirectory $tempCwd *>&1 | Out-Null
            Assert-True -Name "OpenCode harness stream doesn't crash with mock" -Condition $true
        } finally {
            Pop-Location
        }
    } catch {
        Write-TestResult -Name "OpenCode harness stream doesn't crash with mock" -Status Fail -Message $_.Exception.Message
    }

    Assert-FileContains -Name "OpenCode parser logs text events" `
        -Path $activityLog `
        -Pattern "DOTBOT_OPENCODE_MOCK_OK"

    $openCodeArgsLog = Join-Path $mockLogDir "mock-opencode-args.log"
    $openCodePromptLog = Join-Path $mockLogDir "mock-opencode-prompt.log"

    Assert-PathExists -Name "OpenCode mock captured args" -Path $openCodeArgsLog
    Assert-PathExists -Name "OpenCode mock captured prompt" -Path $openCodePromptLog

    if (Test-Path $openCodeArgsLog) {
        $openCodeArgs = @(Get-Content $openCodeArgsLog)
        Assert-True -Name "OpenCode command starts with run subcommand" `
            -Condition ($openCodeArgs.Count -gt 0 -and $openCodeArgs[0] -eq "run") `
            -Message "Expected first arg to be run: $($openCodeArgs -join ' ')"
        Assert-True -Name "OpenCode does not pass resume-only --session" `
            -Condition (-not ($openCodeArgs -contains "--session")) `
            -Message "Did not expect --session in args: $($openCodeArgs -join ' ')"
        Assert-True -Name "OpenCode worktree root uses --dir" `
            -Condition (($openCodeArgs -contains "--dir") -and ($openCodeArgs -contains $expectedCwd)) `
            -Message "Expected --dir $expectedCwd in args: $($openCodeArgs -join ' ')"
    }

    if (Test-Path $openCodePromptLog) {
        $openCodePrompt = Get-Content $openCodePromptLog -Raw
        Assert-True -Name "OpenCode receives prompt as positional message" `
            -Condition ($openCodePrompt -match "Mock OpenCode prompt") `
            -Message "Expected prompt in mock log"
    }

} finally {
    $env:PATH = $originalPath
    $env:DOTBOT_MOCK_LOG_DIR = $null
    $env:DOTBOT_MOCK_CODEX_MODE = $null
    $env:DOTBOT_MOCK_OPENCODE_MODE = $null
    if ($tempCwd -and (Test-Path $tempCwd)) {
        Remove-Item -Path $tempCwd -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $mockLogDir) {
        Remove-Item -Path $mockLogDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""

$allPassed = Write-TestSummary -LayerName "Layer 3: Mock Harness Providers"

if (-not $allPassed) {
    exit 1
}
