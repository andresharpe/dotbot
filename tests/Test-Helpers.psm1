#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Shared test utilities for dotbot integration tests.
.DESCRIPTION
    Provides lightweight assertion functions, test project scaffolding,
    MCP server helpers, and test result tracking.
#>

# --- Test Result Tracking ---

$script:TestResults = @{
    Passed  = 0
    Failed  = 0
    Skipped = 0
    Errors  = [System.Collections.ArrayList]::new()
}

# Stopwatch reset on each result so each line shows time since the previous result.
# This attributes setup cost (Initialize-TestBotProject, Start-McpServer, Start-Sleep)
# to the first assertion that follows it — exactly what we want to triage slow tests.
$script:LastResultStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
# Suite-wide stopwatch — used in Write-TestSummary so the displayed total includes
# any time spent after the final result (teardown, finally blocks, MCP shutdown).
$script:SuiteStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Reset-TestResults {
    $script:TestResults = @{
        Passed  = 0
        Failed  = 0
        Skipped = 0
        Errors  = [System.Collections.ArrayList]::new()
    }
    $script:LastResultStopwatch.Restart()
    $script:SuiteStopwatch.Restart()
}

function Get-TestResults {
    return $script:TestResults
}

function Format-TestElapsed {
    param([int64]$Ms)
    return "({0}ms)" -f $Ms
}

function Write-TestResult {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Fail', 'Skip')]
        [string]$Status,
        [string]$Message = ""
    )

    $elapsedMs = $script:LastResultStopwatch.ElapsedMilliseconds
    $script:LastResultStopwatch.Restart()
    $elapsedTag = Format-TestElapsed -Ms $elapsedMs

    switch ($Status) {
        'Pass' {
            $script:TestResults.Passed++
            Write-Host "  ✓ $Name " -NoNewline -ForegroundColor Green
            Write-Host $elapsedTag -ForegroundColor DarkGray
        }
        'Fail' {
            $script:TestResults.Failed++
            [void]$script:TestResults.Errors.Add("${Name}: ${Message}")
            Write-Host "  ✗ $Name " -NoNewline -ForegroundColor Red
            Write-Host $elapsedTag -ForegroundColor DarkGray
            if ($Message) {
                Write-Host "    $Message" -ForegroundColor DarkRed
            }
        }
        'Skip' {
            $script:TestResults.Skipped++
            Write-Host "  ○ $Name (skipped) " -NoNewline -ForegroundColor Yellow
            Write-Host $elapsedTag -ForegroundColor DarkGray
            if ($Message) {
                Write-Host "    $Message" -ForegroundColor DarkYellow
            }
        }
    }
}

function Write-TestSummary {
    param([string]$LayerName = "Tests")

    $r = $script:TestResults
    $total = $r.Passed + $r.Failed + $r.Skipped
    $totalSeconds = [math]::Round($script:SuiteStopwatch.Elapsed.TotalSeconds, 1)

    Write-Host ""
    Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  $LayerName Summary: " -NoNewline -ForegroundColor White
    Write-Host "$($r.Passed) passed" -NoNewline -ForegroundColor Green
    Write-Host ", " -NoNewline
    Write-Host "$($r.Failed) failed" -NoNewline -ForegroundColor $(if ($r.Failed -gt 0) { "Red" } else { "Green" })
    Write-Host ", " -NoNewline
    Write-Host "$($r.Skipped) skipped" -NoNewline -ForegroundColor Yellow
    Write-Host " / $total total " -NoNewline
    Write-Host "(${totalSeconds}s)" -ForegroundColor DarkGray

    if ($r.Errors.Count -gt 0) {
        Write-Host ""
        Write-Host "  Failures:" -ForegroundColor Red
        foreach ($err in $r.Errors) {
            Write-Host "    • $err" -ForegroundColor DarkRed
        }
    }
    Write-Host ""

    return $r.Failed -eq 0
}

# --- Assertion Functions ---

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [bool]$Condition,
        [string]$Message = "Expected true but got false"
    )

    if ($Condition) {
        Write-TestResult -Name $Name -Status Pass
    } else {
        Write-TestResult -Name $Name -Status Fail -Message $Message
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        $Expected,
        $Actual,
        [string]$Message = ""
    )

    if ($Expected -eq $Actual) {
        Write-TestResult -Name $Name -Status Pass
    } else {
        $msg = if ($Message) { $Message } else { "Expected '$Expected' but got '$Actual'" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Message = ""
    )

    if (Test-Path $Path) {
        Write-TestResult -Name $Name -Status Pass
    } else {
        $msg = if ($Message) { $Message } else { "Path does not exist: $Path" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

function Assert-PathNotExists {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Message = ""
    )

    if (-not (Test-Path $Path)) {
        Write-TestResult -Name $Name -Status Pass
    } else {
        $msg = if ($Message) { $Message } else { "Path should not exist but does: $Path" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

function Assert-FileContains {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Pattern,
        [string]$Message = ""
    )

    if (-not (Test-Path $Path)) {
        Write-TestResult -Name $Name -Status Fail -Message "File does not exist: $Path"
        return
    }

    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if ($content -match $Pattern) {
        Write-TestResult -Name $Name -Status Pass
    } else {
        $msg = if ($Message) { $Message } else { "File '$Path' does not contain pattern: $Pattern" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

function Assert-ValidJson {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Message = ""
    )

    if (-not (Test-Path $Path)) {
        Write-TestResult -Name $Name -Status Fail -Message "File does not exist: $Path"
        return
    }

    try {
        Get-Content $Path -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
        Write-TestResult -Name $Name -Status Pass
    } catch {
        $msg = if ($Message) { $Message } else { "Invalid JSON in $Path : $($_.Exception.Message)" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

function Assert-ValidPowerShell {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Message = ""
    )

    if (-not (Test-Path $Path)) {
        Write-TestResult -Name $Name -Status Fail -Message "File does not exist: $Path"
        return
    }

    try {
        $content = Get-Content $Path -Raw
        [scriptblock]::Create($content) | Out-Null
        Write-TestResult -Name $Name -Status Pass
    } catch {
        $msg = if ($Message) { $Message } else { "Invalid PowerShell syntax in $Path : $($_.Exception.Message)" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

function Assert-ValidPowerShellAst {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Message = ""
    )

    if (-not (Test-Path $Path)) {
        Write-TestResult -Name $Name -Status Fail -Message "File does not exist: $Path"
        return
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -eq 0) {
        Write-TestResult -Name $Name -Status Pass
    } else {
        $firstError = $parseErrors[0]
        $line = $firstError.Extent.StartLineNumber
        $detail = "$($firstError.Message) (line $line)"
        $msg = if ($Message) { $Message } else { "Invalid PowerShell syntax in $Path : $detail" }
        Write-TestResult -Name $Name -Status Fail -Message $msg
    }
}

# --- Test Project Management ---

function New-TestProject {
    param(
        [string]$Prefix = "dotbot-test"
    )

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "$Prefix-$([System.Guid]::NewGuid().ToString().Substring(0,8))"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # Initialize git repo (required for dotbot init)
    Push-Location $tempDir
    & git init --quiet 2>&1 | Out-Null
    & git config user.email "test@dotbot.dev" 2>&1 | Out-Null
    & git config user.name "Dotbot Test" 2>&1 | Out-Null

    # Create an initial commit (needed for worktree operations)
    "# Test Project" | Set-Content -Path (Join-Path $tempDir "README.md")
    & git add -A 2>&1 | Out-Null
    & git commit -m "Initial commit" --quiet 2>&1 | Out-Null
    Pop-Location

    return $tempDir
}

function Remove-TestProject {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ((Test-Path $Path) -and $Path -like "*dotbot-test*") {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-TestBotProject {
    <#
    .SYNOPSIS
        Create a temp project and run dotbot init.
    #>
    $dotbotDir = Get-DotbotInstallDir
    $project = New-TestProject
    Push-Location $project
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dotbotDir "scripts\init-project.ps1") 2>&1 | Out-Null
    & git add -A 2>&1 | Out-Null
    & git commit -m "dotbot init" --quiet 2>&1 | Out-Null
    Pop-Location

    $botDir = Join-Path $project ".bot"
    $controlDir = Join-Path $botDir ".control"
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    return @{
        ProjectRoot = $project
        BotDir      = $botDir
        ControlDir  = $controlDir
    }
}

# --- Golden Snapshot Fixtures ---
#
# Each Layer 2+ test that needs a ready .bot/ used to call init-project.ps1
# (~30s on Windows). We instead build the post-init project once per workflow
# flavor at suite start and clone it via robocopy (Windows) or cp -a (Unix)
# per test. Tests that exist to verify init behaviour still call
# Initialize-TestBotProject directly. Set DOTBOT_REBUILD_GOLDENS=1 to force
# a rebuild.
#
# A "golden" captures the full post-init project root (sans .git/), not just
# .bot/. init-project.ps1 also creates .gitignore, .mcp.json, .claude/,
# .codex/, .gemini/, AGENTS.md, CLAUDE.md, GEMINI.md, etc. Tests that read
# any of these (e.g. Get-GitignoredCopyPaths reads .gitignore) need the
# whole tree.

function Get-GoldenSnapshotsRoot {
    return Join-Path ([System.IO.Path]::GetTempPath()) 'dotbot-test-goldens'
}

function Copy-DirectoryTree {
    <#
    .SYNOPSIS
        Cross-platform recursive directory copy. Source contents into Destination.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    if ($IsWindows) {
        # /MIR mirrors; /XD .git keeps the destination's own git repo intact.
        # Exit codes 0-7 are success; >=8 is a real failure.
        & robocopy $Source $Destination /MIR /XD .git /MT:8 /NJS /NFL /NDL /NP /NC 2>&1 | Out-Null
        if ($LASTEXITCODE -ge 8) {
            $code = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            throw "robocopy failed (exit $code) copying $Source -> $Destination"
        }
        $global:LASTEXITCODE = 0
    } else {
        # Match Windows behaviour by excluding .git so the destination repo stays
        # intact (and so goldens captured on Unix don't bake a stale .git in).
        Get-ChildItem -LiteralPath $Source -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
            & cp -a $_.FullName $Destination
            if ($LASTEXITCODE -ne 0) {
                throw "cp -a failed (exit $LASTEXITCODE) copying $($_.FullName) -> $Destination"
            }
        }
    }
}

function Initialize-GoldenSnapshots {
    <#
    .SYNOPSIS
        Build per-flavor golden .bot/ snapshots once for the test run.
    .DESCRIPTION
        Each flavor's golden lives at <temp>\dotbot-test-goldens\<flavor>\.bot\.
        Rebuilds any flavor whose golden is missing, older than the installed
        dotbot source, or when $env:DOTBOT_REBUILD_GOLDENS = '1'. Builds all
        stale flavors in parallel via ForEach-Object -Parallel (mirroring the
        pattern in Test-Structure.ps1).
        Returns a hashtable mapping flavor -> .bot/ path.
    #>
    param([Parameter(Mandatory)][string[]]$Flavors)

    $dotbotDir = Get-DotbotInstallDir
    $goldensRoot = Get-GoldenSnapshotsRoot
    if (-not (Test-Path $goldensRoot)) {
        New-Item -ItemType Directory -Path $goldensRoot -Force | Out-Null
    }

    $argsMap = @{
        'default'         = @()
        'start-from-jira' = @('-Workflow', 'start-from-jira')
        'start-from-pr'   = @('-Workflow', 'start-from-pr')
        'start-from-repo' = @('-Workflow', 'start-from-repo')
    }

    foreach ($flavor in $Flavors) {
        if (-not $argsMap.ContainsKey($flavor)) {
            throw "Unknown golden flavor: $flavor"
        }
    }

    # scripts/ is included so a change to init-project.ps1 (or anything else
    # init-project loads) invalidates the golden — workflows/ and stacks/ alone
    # would miss script-only updates. Mirrors the stale-install check in Run-Tests.ps1.
    $sourcePaths = @("$dotbotDir\workflows", "$dotbotDir\stacks", "$dotbotDir\scripts") | Where-Object { Test-Path $_ }
    $sourceNewest = $null
    if ($sourcePaths) {
        $sourceNewest = (Get-ChildItem $sourcePaths -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    }

    $forceRebuild = $env:DOTBOT_REBUILD_GOLDENS -eq '1'
    $needRebuild = @()
    foreach ($flavor in $Flavors) {
        $goldenDir = Join-Path $goldensRoot $flavor
        $goldenBot = Join-Path $goldenDir '.bot'
        if ($forceRebuild -or -not (Test-Path $goldenBot)) {
            $needRebuild += $flavor
            continue
        }
        if ($sourceNewest) {
            # Scan the whole golden tree, not just .bot/ — init writes root
            # files (.gitignore, .mcp.json, .claude/, etc.) that the golden
            # captures, and scripts/ aren't copied under .bot/ at all. Limiting
            # to .bot/ would (a) miss stale root files and (b) trigger
            # constant rebuilds when ~/dotbot/scripts has a newer mtime than
            # any .bot file.
            $goldenNewest = (Get-ChildItem $goldenDir -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
            if (-not $goldenNewest -or $sourceNewest -gt $goldenNewest) {
                $needRebuild += $flavor
            }
        }
    }

    if ($needRebuild.Count -gt 0) {
        Write-Host "  → Building golden snapshots for: $($needRebuild -join ', ')" -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Resolve args per-flavor in the outer scope; ForEach-Object -Parallel
        # rejects subscripted $using: expressions like $using:argsMap[$flavor].
        $buildSpecs = $needRebuild | ForEach-Object {
            [pscustomobject]@{ Flavor = $_; Args = $argsMap[$_] }
        }

        $buildResults = $buildSpecs | ForEach-Object -Parallel {
            $spec = $_
            $flavor = $spec.Flavor
            $goldenFlavorDir = Join-Path $using:goldensRoot $flavor
            $buildError = $null
            $tempProject = $null

            try {
                if (Test-Path $goldenFlavorDir) {
                    Remove-Item -Path $goldenFlavorDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -ItemType Directory -Path $goldenFlavorDir -Force | Out-Null

                Import-Module (Join-Path $using:PSScriptRoot 'Test-Helpers.psm1') -DisableNameChecking
                # Prefix must contain "dotbot-test" so Remove-TestProject's
                # safety allowlist (`$Path -like "*dotbot-test*"`) cleans it up.
                $tempProject = New-TestProject -Prefix 'dotbot-test-golden-build'

                Push-Location $tempProject
                $initOutput = if ($spec.Args.Count -eq 0) {
                    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $using:dotbotDir 'scripts\init-project.ps1') 2>&1
                } else {
                    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $using:dotbotDir 'scripts\init-project.ps1') @($spec.Args) 2>&1
                }
                $initExitCode = $LASTEXITCODE
                Pop-Location

                if ($initExitCode -ne 0) {
                    # Surface init-project.ps1's own output — without it, "exit 1"
                    # alone is hard to debug. Trim and tail to keep errors readable.
                    $initText = (($initOutput | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
                    if ($initText.Length -gt 4000) {
                        $initText = '...' + $initText.Substring($initText.Length - 3997)
                    }
                    if ([string]::IsNullOrWhiteSpace($initText)) {
                        throw "init-project.ps1 failed for flavor $flavor (exit $initExitCode)"
                    }
                    throw "init-project.ps1 failed for flavor $flavor (exit $initExitCode):$([Environment]::NewLine)$initText"
                }
                if (-not (Test-Path (Join-Path $tempProject '.bot'))) {
                    throw "init-project.ps1 did not create .bot for flavor $flavor"
                }
                # Capture entire post-init project (sans .git/) — init creates
                # .gitignore, .mcp.json, .claude/, .codex/, .gemini/, AGENTS.md,
                # CLAUDE.md, GEMINI.md alongside .bot/, and downstream tests
                # (e.g. Get-GitignoredCopyPaths) read these.
                Copy-DirectoryTree -Source $tempProject -Destination $goldenFlavorDir
            } catch {
                $buildError = $_.Exception.Message
            } finally {
                if ($tempProject) {
                    Remove-TestProject -Path $tempProject
                }
            }

            [pscustomobject]@{ Flavor = $flavor; Error = $buildError }
        } -ThrottleLimit 6

        $failures = $buildResults | Where-Object { $_.Error }
        if ($failures) {
            $msg = ($failures | ForEach-Object { "$($_.Flavor): $($_.Error)" }) -join '; '
            throw "Golden snapshot build failed: $msg"
        }

        $sw.Stop()
        Write-Host "  ✓ Goldens built in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green
    }

    $result = @{}
    foreach ($flavor in $Flavors) {
        $result[$flavor] = Join-Path $goldensRoot "$flavor\.bot"
    }
    return $result
}

function New-TestProjectFromGolden {
    <#
    .SYNOPSIS
        Create a test project by cloning a pre-built post-init golden snapshot.
    .DESCRIPTION
        Returns the same shape as Initialize-TestBotProject but ~10-30x faster
        because it skips init-project.ps1. Initialize-GoldenSnapshots must have
        been called first (Run-Tests.ps1 does this once before Layer 2). The
        returned project is fully isolated: regenerating instance_id ensures
        clones don't share workspace identity with the golden or each other.

        Copies the entire golden tree (.bot/, .gitignore, .mcp.json, .claude/,
        .codex/, .gemini/, *.md memory files) into the new test project. The
        new project's .git/ is preserved (Copy-DirectoryTree excludes .git).
    #>
    param(
        [Parameter(Mandatory)][string]$Flavor,
        [string]$Prefix = 'dotbot-test'
    )

    $goldensRoot = Get-GoldenSnapshotsRoot
    $goldenDir = Join-Path $goldensRoot $Flavor
    if (-not (Test-Path (Join-Path $goldenDir '.bot'))) {
        # Standalone test-file runs (e.g. `pwsh tests/Test-Components.ps1`) skip
        # the suite-level build. Lazily build the missing flavor here so each
        # test file remains runnable on its own.
        Initialize-GoldenSnapshots -Flavors @($Flavor) | Out-Null
    }

    $project = New-TestProject -Prefix $Prefix
    Copy-DirectoryTree -Source $goldenDir -Destination $project

    $destBot = Join-Path $project '.bot'

    # Regenerate instance_id so each clone has its own workspace identity.
    $settingsPath = Join-Path $destBot 'settings\settings.default.json'
    if (Test-Path $settingsPath) {
        try {
            $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $newId = [guid]::NewGuid().ToString()
            if ($settings.PSObject.Properties['instance_id']) {
                $settings.instance_id = $newId
            } else {
                $settings | Add-Member -NotePropertyName instance_id -NotePropertyValue $newId -Force
            }
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8
        } catch { Write-Verbose "instance_id regen skipped: $_" }
    }

    $controlDir = Join-Path $destBot '.control'
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    Push-Location $project
    & git add -A 2>&1 | Out-Null
    & git commit -m "dotbot init" --quiet 2>&1 | Out-Null
    Pop-Location

    return @{
        ProjectRoot = $project
        BotDir      = $destBot
        ControlDir  = $controlDir
    }
}

# --- MCP Server Helpers ---

function Start-McpServer {
    param(
        [Parameter(Mandatory)]
        [string]$BotDir
    )

    $mcpScript = Join-Path $BotDir "systems\mcp\dotbot-mcp.ps1"
    if (-not (Test-Path $mcpScript)) {
        throw "MCP server script not found: $mcpScript"
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "pwsh"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$mcpScript`""
    $psi.WorkingDirectory = Split-Path -Parent $BotDir
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    Start-Sleep -Milliseconds 500  # Give server time to boot

    if ($process.HasExited) {
        $stderr = $process.StandardError.ReadToEnd()
        throw "MCP server exited immediately. Stderr: $stderr"
    }

    return $process
}

function Stop-McpServer {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    if (-not $Process.HasExited) {
        try {
            $Process.StandardInput.Close()
            $Process.WaitForExit(3000) | Out-Null
        } catch { Write-Verbose "Cleanup: failed to close resource: $_" }

        if (-not $Process.HasExited) {
            $Process.Kill()
        }
    }
    $Process.Dispose()
}

function Send-McpRequest {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)]
        [hashtable]$Request
    )

    $json = $Request | ConvertTo-Json -Depth 10 -Compress
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
    Start-Sleep -Milliseconds 200

    $response = $Process.StandardOutput.ReadLine()
    if ($response) {
        return $response | ConvertFrom-Json
    }
    return $null
}

function Send-McpInitialize {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )

    $initRequest = @{
        jsonrpc = '2.0'
        id      = 0
        method  = 'initialize'
        params  = @{
            protocolVersion = '2024-11-05'
            capabilities    = @{}
            clientInfo      = @{
                name    = 'dotbot-test'
                version = '1.0.0'
            }
        }
    }

    $response = Send-McpRequest -Process $Process -Request $initRequest
    
    # Send initialized notification
    $notification = @{
        jsonrpc = '2.0'
        method  = 'notifications/initialized'
        params  = @{}
    }
    $notifJson = $notification | ConvertTo-Json -Depth 10 -Compress
    $Process.StandardInput.WriteLine($notifJson)
    $Process.StandardInput.Flush()
    Start-Sleep -Milliseconds 100

    return $response
}

# --- Utility Functions ---

function Get-RepoRoot {
    # Walk up from this script to find the repo root
    $current = $PSScriptRoot
    while ($current) {
        if (Test-Path (Join-Path $current ".git")) {
            return $current
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    throw "Could not find repo root from $PSScriptRoot"
}

function Get-DotbotInstallDir {
    return Join-Path $HOME "dotbot"
}

Export-ModuleMember -Function @(
    'Reset-TestResults'
    'Get-TestResults'
    'Write-TestResult'
    'Write-TestSummary'
    'Assert-True'
    'Assert-Equal'
    'Assert-PathExists'
    'Assert-PathNotExists'
    'Assert-FileContains'
    'Assert-ValidJson'
    'Assert-ValidPowerShell'
    'Assert-ValidPowerShellAst'
    'New-TestProject'
    'Remove-TestProject'
    'Initialize-TestBotProject'
    'Get-GoldenSnapshotsRoot'
    'Copy-DirectoryTree'
    'Initialize-GoldenSnapshots'
    'New-TestProjectFromGolden'
    'Start-McpServer'
    'Stop-McpServer'
    'Send-McpRequest'
    'Send-McpInitialize'
    'Get-RepoRoot'
    'Get-DotbotInstallDir'
)
