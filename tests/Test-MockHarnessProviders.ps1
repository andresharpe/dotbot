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

$mockShimDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-mock-harness-bin-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
New-Item -ItemType Directory -Path $mockShimDir -Force | Out-Null

$antigravityMock = Join-Path $PSScriptRoot "mock-antigravity.ps1"
$openCodeMock = Join-Path $PSScriptRoot "mock-opencode.ps1"
$copilotMock = Join-Path $PSScriptRoot "mock-copilot.ps1"
$openCodePs1 = Join-Path $mockShimDir "opencode.ps1"
Set-Content -Path $openCodePs1 -Encoding UTF8 -Value @"
#!/usr/bin/env pwsh
& '$openCodeMock' @args
"@
if ($IsWindows) {
    $agyCmd = Join-Path $mockShimDir "agy.cmd"
    Set-Content -Path $agyCmd -Encoding ASCII -Value @(
        "@echo off"
        "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$antigravityMock`" %*"
    )
    $copilotCmd = Join-Path $mockShimDir "copilot.cmd"
    Set-Content -Path $copilotCmd -Encoding ASCII -Value @(
        "@echo off"
        "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$copilotMock`" %*"
    )
} else {
    $agy = Join-Path $mockShimDir "agy"
    Set-Content -Path $agy -Encoding ASCII -Value @(
        '#!/usr/bin/env bash'
        "pwsh -NoProfile -ExecutionPolicy Bypass -File '$antigravityMock' ""`$@"""
    )
    & chmod +x $agy 2>$null
    $copilot = Join-Path $mockShimDir "copilot"
    Set-Content -Path $copilot -Encoding ASCII -Value @(
        '#!/usr/bin/env bash'
        "pwsh -NoProfile -ExecutionPolicy Bypass -File '$copilotMock' ""`$@"""
    )
    & chmod +x $copilot 2>$null
}

$originalPath = $env:PATH
$env:PATH = "$mockShimDir$([System.IO.Path]::PathSeparator)$PSScriptRoot$([System.IO.Path]::PathSeparator)$env:PATH"

if (-not $IsWindows) {
    foreach ($shimName in @("claude", "codex", "opencode")) {
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
    # Two views of the same temp directory:
    #   $expectedCwd        — canonical form (e.g. `/var/folders/...` resolved to
    #                          `/private/var/folders/...` on macOS). Use this when
    #                          comparing against `(Get-Location).Path` inside a
    #                          spawned process — the OS resolves symlinks for
    #                          the process cwd, so the canonical form is what
    #                          comes back.
    #   $argsCwdPatterns    — array of candidate strings to match against args
    #                          captured by the mock harness adapters. The adapters
    #                          pass `-WorkingDirectory $tempCwd` straight through
    #                          to the CLI, so the args contain the raw temp path,
    #                          not the canonical one. Allow either form so the
    #                          assertions work the same on Linux (raw == canonical),
    #                          macOS (`/var` vs `/private/var`), and Windows.
    $expectedCwd = Get-CanonicalCwd -Path $tempCwd
    $argsCwdPatterns = @($tempCwd, $expectedCwd) | Sort-Object -Unique
    $activityLog = Join-Path $tempCwd ".bot/.control/activity.jsonl"

    function Test-ArgsContainCwd {
        # Returns $true when at least one $argsCwdPatterns string appears in the
        # whole-args text (used for `-match` style checks on the raw log file).
        param([Parameter(Mandatory)][string]$ArgsText)
        foreach ($candidate in $argsCwdPatterns) {
            if ($ArgsText -match [regex]::Escape($candidate)) { return $true }
        }
        return $false
    }

    function Test-ArgsListContainsCwd {
        # Returns $true when at least one $argsCwdPatterns string is a literal
        # element of the args array (used for `-contains` style checks).
        param([Parameter(Mandatory)][string[]]$ArgsList)
        foreach ($candidate in $argsCwdPatterns) {
            if ($ArgsList -contains $candidate) { return $true }
        }
        return $false
    }

    function Test-ArgsListContainsCwdWithPrefix {
        # Returns $true when any element of the args array equals
        # "${Prefix}${candidate}" for any candidate cwd (used for the Copilot
        # adapter's `--add-dir=<cwd>` inline-equals form).
        param(
            [Parameter(Mandatory)][string[]]$ArgsList,
            [Parameter(Mandatory)][string]$Prefix
        )
        foreach ($candidate in $argsCwdPatterns) {
            if ($ArgsList -contains "${Prefix}${candidate}") { return $true }
        }
        return $false
    }

    Write-Host "  HARNESS THEME BOUNDARY" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    $adapterFiles = Get-ChildItem -Path (Join-Path $dotbotDir "src/runtime/Modules/Dotbot.Harness/Adapters") -Filter "*.ps1"
    foreach ($adapterFile in $adapterFiles) {
        $adapterSource = Get-Content -LiteralPath $adapterFile.FullName -Raw
        Assert-True -Name "$($adapterFile.BaseName) stream uses guarded theme refresh" `
            -Condition ($adapterSource -match "function\s+Invoke-.*AdapterStream[\s\S]*Update-HarnessTheme") `
            -Message "Expected stream adapter to call Update-HarnessTheme"
        Assert-True -Name "$($adapterFile.BaseName) does not call Update-DotbotTheme directly" `
            -Condition (-not ($adapterSource -match "Update-DotbotTheme")) `
            -Message "Adapter must use Update-HarnessTheme so script-task scopes cannot abort provider execution"
    }

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
            -Condition (($codexArgs -match "(?m)^-C$") -and (Test-ArgsContainCwd -ArgsText $codexArgs)) `
            -Message "Expected -C with cwd matching one of [$($argsCwdPatterns -join ', ')] in args: $codexArgs"
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
            -Condition (($openCodeArgs -contains "--dir") -and (Test-ArgsListContainsCwd -ArgsList $openCodeArgs)) `
            -Message "Expected --dir with cwd matching one of [$($argsCwdPatterns -join ', ')] in args: $($openCodeArgs -join ' ')"
    }

    if (Test-Path $openCodePromptLog) {
        $openCodePrompt = Get-Content $openCodePromptLog -Raw
        Assert-True -Name "OpenCode receives prompt as positional message" `
            -Condition ($openCodePrompt -match "Mock OpenCode prompt") `
            -Message "Expected prompt in mock log"
    }

    try {
        Push-Location $tempCwd
        try {
            $dynamicHarnessModule = New-Module -ScriptBlock {
                param($HarnessModulePath, $ThemeModulePath, $WorkDir)
                $ErrorActionPreference = 'Stop'
                Import-Module $HarnessModulePath -Force
                Import-Module $ThemeModulePath -Force
                Invoke-HarnessStream -Prompt "Mock OpenCode dynamic module prompt" -Model "fast" -HarnessName "opencode" -WorkingDirectory $WorkDir *>&1 | Out-Null
            } -ArgumentList $harnessModule, $themeModule, $tempCwd
            & $dynamicHarnessModule { }
            Assert-True -Name "OpenCode harness stream works from dynamic module scope" -Condition $true
        } finally {
            Pop-Location
        }
    } catch {
        Write-TestResult -Name "OpenCode harness stream works from dynamic module scope" -Status Fail -Message $_.Exception.Message
    }

    Write-Host ""
    Write-Host "  ANTIGRAVITY ADAPTER" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    try {
        Push-Location $tempCwd
        try {
            Invoke-HarnessStream -Prompt "Mock Antigravity prompt" -Model "fast" -HarnessName "antigravity" -WorkingDirectory $tempCwd *>&1 | Out-Null
            Assert-True -Name "Antigravity harness stream doesn't crash with mock" -Condition $true
        } finally {
            Pop-Location
        }
    } catch {
        Write-TestResult -Name "Antigravity harness stream doesn't crash with mock" -Status Fail -Message $_.Exception.Message
    }

    Assert-FileContains -Name "Antigravity parser logs plain text output" `
        -Path $activityLog `
        -Pattern "DOTBOT_ANTIGRAVITY_MOCK_OK"

    $antigravityCwdLog = Join-Path $mockLogDir "mock-antigravity-cwd.log"
    if (Test-Path $antigravityCwdLog) {
        $antigravityCwd = (Get-Content $antigravityCwdLog -Raw).Trim()
        $pathsMatch = if ($IsWindows) { $antigravityCwd -ieq $expectedCwd } else { $antigravityCwd -ceq $expectedCwd }
        Assert-True -Name "Antigravity process cwd follows -WorkingDirectory" `
            -Condition $pathsMatch `
            -Message "Expected cwd=$expectedCwd, got cwd=$antigravityCwd"
    }

    $antigravityArgsLog = Join-Path $mockLogDir "mock-antigravity-args.log"
    Assert-PathExists -Name "Antigravity mock captured args" -Path $antigravityArgsLog
    if (Test-Path $antigravityArgsLog) {
        $antigravityArgs = @(Get-Content $antigravityArgsLog)
        Assert-True -Name "Antigravity args include worktree root with --add-dir" `
            -Condition (($antigravityArgs -contains "--add-dir") -and (Test-ArgsListContainsCwd -ArgsList $antigravityArgs)) `
            -Message "Expected --add-dir with cwd matching one of [$($argsCwdPatterns -join ', ')] in args: $($antigravityArgs -join ' ')"
    }

    if (Test-Path -LiteralPath $activityLog) {
        Remove-Item -LiteralPath $activityLog -Force -ErrorAction SilentlyContinue
    }

    $env:DOTBOT_MOCK_ANTIGRAVITY_MODE = "slow-stream"
    $slowStreamJob = $null
    try {
        $slowStreamJob = Start-Job -ScriptBlock {
            param($HarnessModulePath, $ThemeModulePath, $WorkDir)
            $ErrorActionPreference = 'Stop'
            Import-Module $HarnessModulePath -Force
            Import-Module $ThemeModulePath -Force
            Push-Location $WorkDir
            try {
                Invoke-HarnessStream -Prompt "Mock Antigravity slow stream prompt" -Model "fast" -HarnessName "antigravity" -WorkingDirectory $WorkDir *>&1 | Out-Null
            } finally {
                Pop-Location
            }
        } -ArgumentList $harnessModule, $themeModule, $tempCwd

        $deadline = (Get-Date).AddSeconds(2)
        $foundWhileRunning = $false
        while ((Get-Date) -lt $deadline) {
            if ((Test-Path -LiteralPath $activityLog) -and
                ((Get-Content -LiteralPath $activityLog -Raw) -match "DOTBOT_ANTIGRAVITY_STREAM_FIRST")) {
                $foundWhileRunning = ($slowStreamJob.State -eq 'Running')
                break
            }
            if ($slowStreamJob.State -ne 'Running') { break }
            Start-Sleep -Milliseconds 100
        }

        Assert-True -Name "Antigravity logs stream output before process exit" `
            -Condition $foundWhileRunning `
            -Message "Expected first activity line while slow mock was still running"

        $completedJob = Wait-Job -Job $slowStreamJob -Timeout 10
        if ($completedJob) {
            Receive-Job -Job $slowStreamJob -ErrorAction Stop | Out-Null
            Assert-True -Name "Antigravity slow stream mock completes" -Condition $true
            Assert-FileContains -Name "Antigravity parser logs stderr stream output" `
                -Path $activityLog `
                -Pattern "DOTBOT_ANTIGRAVITY_STREAM_STDERR"
        } else {
            Stop-Job -Job $slowStreamJob -ErrorAction SilentlyContinue
            Write-TestResult -Name "Antigravity slow stream mock completes" -Status Fail -Message "Timed out waiting for slow stream mock"
        }
    } catch {
        Write-TestResult -Name "Antigravity logs stream output before process exit" -Status Fail -Message $_.Exception.Message
    } finally {
        $env:DOTBOT_MOCK_ANTIGRAVITY_MODE = $null
        if ($slowStreamJob) {
            Remove-Job -Job $slowStreamJob -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "  COPILOT ADAPTER" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    try {
        Push-Location $tempCwd
        try {
            Invoke-HarnessStream -Prompt "Mock Copilot prompt" -Model "fast" -HarnessName "copilot" -WorkingDirectory $tempCwd *>&1 | Out-Null
            Assert-True -Name "Copilot harness stream doesn't crash with mock" -Condition $true
        } finally {
            Pop-Location
        }
    } catch {
        Write-TestResult -Name "Copilot harness stream doesn't crash with mock" -Status Fail -Message $_.Exception.Message
    }

    Assert-FileContains -Name "Copilot parser logs streamed text" `
        -Path $activityLog `
        -Pattern "DOTBOT_COPILOT_MOCK_OK"
    Assert-FileContains -Name "Copilot parser logs bash command detail" `
        -Path $activityLog `
        -Pattern "pwsh tests/Run-Tests.ps1 -Layer 1"
    Assert-FileContains -Name "Copilot parser logs read path detail" `
        -Path $activityLog `
        -Pattern "src/runtime/Modules/Dotbot.Harness/Adapters/CopilotAdapter.ps1"

    $copilotArgsLog = Join-Path $mockLogDir "mock-copilot-args.log"
    $copilotCwdLog = Join-Path $mockLogDir "mock-copilot-cwd.log"
    Assert-PathExists -Name "Copilot mock captured args" -Path $copilotArgsLog
    if (Test-Path $copilotArgsLog) {
        $copilotArgs = @(Get-Content $copilotArgsLog)

        # On Windows, pwsh -File arg parsing splits inline-equals args at the
        # drive-letter colon: `--add-dir=C:\path` arrives as `[--add-dir=C,
        # \path]` in the script's `$args`. The mock then writes both halves on
        # separate lines, so the args log loses the colon. Re-glue any
        # `<prefix>=<letter>` line followed by a `\` or `/` line so the
        # assertion sees the original arg the adapter intended to pass.
        if ($IsWindows) {
            $repaired = @()
            for ($i = 0; $i -lt $copilotArgs.Count; $i++) {
                if ($i + 1 -lt $copilotArgs.Count -and
                    $copilotArgs[$i]   -match '^([^=]*=)([A-Za-z])$' -and
                    $copilotArgs[$i+1] -match '^[/\\]') {
                    $repaired += ($copilotArgs[$i] + ':' + $copilotArgs[$i+1])
                    $i++
                } else {
                    $repaired += $copilotArgs[$i]
                }
            }
            $copilotArgs = $repaired
        }

        Assert-True -Name "Copilot args include worktree root" `
            -Condition (Test-ArgsListContainsCwdWithPrefix -ArgsList $copilotArgs -Prefix '--add-dir=') `
            -Message "Expected --add-dir=<cwd> with cwd matching one of [$($argsCwdPatterns -join ', ')] in args: $($copilotArgs -join ' ')"
    }
    if (Test-Path $copilotCwdLog) {
        $copilotCwd = (Get-Content $copilotCwdLog -Raw).Trim()
        $pathsMatch = if ($IsWindows) { $copilotCwd -ieq $expectedCwd } else { $copilotCwd -ceq $expectedCwd }
        Assert-True -Name "Copilot process cwd follows -WorkingDirectory" `
            -Condition $pathsMatch `
            -Message "Expected cwd=$expectedCwd, got cwd=$copilotCwd"
    }

    Write-Host ""
    Write-Host "  DYNAMIC MODULE HARNESS INVOCATION" -ForegroundColor Cyan
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray

    foreach ($providerName in @("claude", "codex", "opencode", "antigravity", "copilot")) {
        try {
            Push-Location $tempCwd
            try {
                $dynamicHarnessModule = New-Module -ScriptBlock {
                    param($HarnessModulePath, $ThemeModulePath, $WorkDir, $ProviderName)
                    $ErrorActionPreference = 'Stop'
                    Import-Module $HarnessModulePath -Force
                    Import-Module $ThemeModulePath -Force
                    Invoke-HarnessStream -Prompt "Mock $ProviderName dynamic module prompt" -Model "fast" -HarnessName $ProviderName -WorkingDirectory $WorkDir *>&1 | Out-Null
                } -ArgumentList $harnessModule, $themeModule, $tempCwd, $providerName
                & $dynamicHarnessModule { }
                Assert-True -Name "$providerName harness stream works from dynamic module scope" -Condition $true
            } finally {
                Pop-Location
            }
        } catch {
            Write-TestResult -Name "$providerName harness stream works from dynamic module scope" -Status Fail -Message $_.Exception.Message
        }
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
    if ($mockShimDir -and (Test-Path $mockShimDir)) {
        Remove-Item -Path $mockShimDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""

$allPassed = Write-TestSummary -LayerName "Layer 3: Mock Harness Providers"

if (-not $allPassed) {
    exit 1
}
