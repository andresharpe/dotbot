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
    'Start-McpServer'
    'Stop-McpServer'
    'Send-McpRequest'
    'Send-McpInitialize'
    'Get-RepoRoot'
    'Get-DotbotInstallDir'
)
