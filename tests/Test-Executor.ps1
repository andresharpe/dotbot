#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Layer 1: plugin executor tests.
.DESCRIPTION
    Covers the public surface of Dotbot.Executor:

      - Discovery: a fixture directory of valid executors + one malformed
        either registers cleanly (with -IgnoreMalformed) or fails the scan.
      - Dispatch: known type → correct executor invoked; unknown type →
        UnknownTaskType; missing required field → MissingExecutorField.
      - Timeout: an executor with max_executor_duration=1 that sleeps for 5
        is killed by the watchdog and returns failure within bounded time.
      - Shipped executors (prompt / script / mcp): the registry parses each
        one and a minimal round-trip dispatch succeeds for each.

    No installed dotbot needed (module is imported directly from src/).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Import-Module "$PSScriptRoot\Test-Helpers.psm1" -Force

$repoRoot = Get-RepoRoot

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Plugin Executors" -ForegroundColor Blue
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""

Reset-TestResults

Import-Module (Join-Path $repoRoot 'src/runtime/Modules/Dotbot.Executor/Dotbot.Executor.psd1') -Force -DisableNameChecking -Global

# Helper: assert a scriptblock throws AND the InvalidOperationException carries
# a `Kind` data entry that matches.
function Assert-DispatcherKind {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ExpectedKind,
        [Parameter(Mandatory)] [scriptblock]$Action
    )
    $threw = $false
    $kind  = $null
    $msg   = ''
    try { & $Action } catch {
        $threw = $true
        $msg = $_.Exception.Message
        if ($_.Exception.Data -and $_.Exception.Data.Contains('Kind')) {
            $kind = $_.Exception.Data['Kind']
        }
    }
    if (-not $threw) {
        Write-TestResult -Name $Name -Status Fail -Message "Expected an exception, got none."
        return
    }
    if ($kind -ne $ExpectedKind) {
        Write-TestResult -Name $Name -Status Fail -Message "Expected Kind '$ExpectedKind', got '$kind' (message: $msg)."
        return
    }
    Write-TestResult -Name $Name -Status Pass
}

# ═══════════════════════════════════════════════════════════════════════════
# Fixture: a synthetic executors directory with three valid + one malformed
# ═══════════════════════════════════════════════════════════════════════════

function New-FixtureExecutorsDir {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-prd05-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $root | Out-Null

    # ── Echo executor: returns whatever it's given. Has a fast timeout so
    #    the dispatch path stays snappy.
    $echoDir = Join-Path $root 'echo'
    New-Item -ItemType Directory -Path $echoDir | Out-Null
    Set-Content -LiteralPath (Join-Path $echoDir 'metadata.yaml') -Value @'
name: echo
task_type: echo
description: "Returns the task name verbatim."
required_fields:
  - name
optional_fields: []
supports_worktree: false
supports_analysis: false
max_executor_duration: 10
'@ -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $echoDir 'script.ps1') -Value @'
function Invoke-Executor {
    param([hashtable]$Task, [hashtable]$RunContext)
    return @{
        Success  = $true
        Message  = "echo:" + [string]$Task['name']
        ExitCode = 0
    }
}
Export-ModuleMember -Function Invoke-Executor
'@ -Encoding utf8NoBOM

    # ── Hang executor: sleeps for 5s with a 1s budget. The watchdog should kill it.
    $hangDir = Join-Path $root 'hang'
    New-Item -ItemType Directory -Path $hangDir | Out-Null
    Set-Content -LiteralPath (Join-Path $hangDir 'metadata.yaml') -Value @'
name: hang
task_type: hang
description: "Sleeps past the watchdog budget so timeout enforcement is observable."
required_fields: []
optional_fields: []
supports_worktree: false
supports_analysis: false
max_executor_duration: 1
'@ -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $hangDir 'script.ps1') -Value @'
function Invoke-Executor {
    param([hashtable]$Task, [hashtable]$RunContext)
    Start-Sleep -Seconds 5
    return @{ Success = $true; Message = "should never reach here"; ExitCode = 0 }
}
Export-ModuleMember -Function Invoke-Executor
'@ -Encoding utf8NoBOM

    # ── Strict executor: requires `payload` to be populated.
    $strictDir = Join-Path $root 'strict'
    New-Item -ItemType Directory -Path $strictDir | Out-Null
    Set-Content -LiteralPath (Join-Path $strictDir 'metadata.yaml') -Value @'
name: strict
task_type: strict
description: "Requires payload."
required_fields:
  - payload
optional_fields: []
supports_worktree: false
supports_analysis: false
max_executor_duration: 10
'@ -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $strictDir 'script.ps1') -Value @'
function Invoke-Executor {
    param([hashtable]$Task, [hashtable]$RunContext)
    return @{ Success = $true; Message = "ok"; ExitCode = 0 }
}
Export-ModuleMember -Function Invoke-Executor
'@ -Encoding utf8NoBOM

    # ── Malformed executor: missing required metadata field (task_type).
    $badDir = Join-Path $root 'bad'
    New-Item -ItemType Directory -Path $badDir | Out-Null
    Set-Content -LiteralPath (Join-Path $badDir 'metadata.yaml') -Value @'
name: bad
description: "Missing task_type AND max_executor_duration."
'@ -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $badDir 'script.ps1') -Value @'
function Invoke-Executor { param([hashtable]$Task, [hashtable]$RunContext) }
Export-ModuleMember -Function Invoke-Executor
'@ -Encoding utf8NoBOM

    return $root
}

function Remove-FixtureExecutorsDir {
    param([Parameter(Mandatory)][string]$Path)
    try { Remove-Item -Recurse -Force $Path } catch { $null = $_ }
}

# ═══════════════════════════════════════════════════════════════════════════
# Discovery
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "  Discovery (parse, validate, index by task_type)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fixture = New-FixtureExecutorsDir
try {
    # Malformed metadata → throw (default behaviour, PRD User Story 11).
    $threw = $false
    try {
        Get-ExecutorRegistry -ExecutorsDir $fixture | Out-Null
    } catch { $threw = $true }
    Assert-True -Name "Get-ExecutorRegistry throws when a fixture has malformed metadata" -Condition $threw

    # With -IgnoreMalformed the registry should hold exactly the three valid entries.
    $registry = Get-ExecutorRegistry -ExecutorsDir $fixture -IgnoreMalformed
    Assert-Equal -Name "Discovery registers 3 valid executors out of 4 folders" -Expected 3 -Actual $registry.Count
    Assert-True -Name "Discovery indexes 'echo' by task_type"   -Condition ($registry.ContainsKey('echo'))
    Assert-True -Name "Discovery indexes 'hang' by task_type"   -Condition ($registry.ContainsKey('hang'))
    Assert-True -Name "Discovery indexes 'strict' by task_type" -Condition ($registry.ContainsKey('strict'))
    Assert-True -Name "Discovery skips the malformed entry"     -Condition (-not $registry.ContainsKey('bad'))

    # Metadata defaults are filled in.
    $echoMeta = $registry['echo'].metadata
    Assert-Equal -Name "echo metadata: supports_worktree defaulted to false" -Expected $false -Actual $echoMeta['supports_worktree']
    Assert-Equal -Name "echo metadata: max_executor_duration is 10"          -Expected 10     -Actual ([int]$echoMeta['max_executor_duration'])

    # Test-ExecutorMetadata returns errors for a bad shape; Assert-ExecutorMetadata throws.
    $errs = Test-ExecutorMetadata -Metadata @{ name = 'x' }
    Assert-True -Name "Test-ExecutorMetadata returns errors for missing required fields" -Condition ($errs.Count -gt 0)

    $threw = $false
    try {
        Assert-ExecutorMetadata -Metadata @{ name = 'x'; task_type = 'x'; description = 'x'; max_executor_duration = -5 }
    } catch { $threw = $true }
    Assert-True -Name "Assert-ExecutorMetadata throws on max_executor_duration <= 0" -Condition $threw
} finally {
    Remove-FixtureExecutorsDir -Path $fixture
}

# ═══════════════════════════════════════════════════════════════════════════
# Dispatch (known → invoke; unknown → UnknownTaskType; missing → MissingExecutorField)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Dispatch (route by task.type)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fixture = New-FixtureExecutorsDir
try {
    $registry = Get-ExecutorRegistry -ExecutorsDir $fixture -IgnoreMalformed

    # Known type → invokes the matching executor.
    $task = @{ id = 't_AbCd1234'; name = 'hello world'; type = 'echo' }
    $r = Invoke-TaskExecutor -Task $task -Registry $registry -RunContext @{}
    Assert-Equal -Name "Dispatch routes 'echo' to its executor"           -Expected $true -Actual $r['Success']
    Assert-Equal -Name "Dispatch returns the executor's Message"          -Expected 'echo:hello world' -Actual $r['Message']
    Assert-Equal -Name "Dispatch stamps 'executor' name onto the result"  -Expected 'echo' -Actual $r['executor']
    Assert-True  -Name "Dispatch stamps 'duration_ms' on the result"      -Condition ($r.ContainsKey('duration_ms'))

    # Unknown type → UnknownTaskType.
    $badTask = @{ id = 't_AbCd1234'; name = 'oops'; type = 'no_such_type' }
    Assert-DispatcherKind -Name "Dispatch throws UnknownTaskType for an unregistered type" `
        -ExpectedKind 'UnknownTaskType' `
        -Action { Invoke-TaskExecutor -Task $badTask -Registry $registry -RunContext @{} | Out-Null }

    # Empty / missing type field also throws UnknownTaskType (cannot route).
    $noType = @{ id = 't_AbCd1234'; name = 'no type' }
    Assert-DispatcherKind -Name "Dispatch throws UnknownTaskType when task.type is missing" `
        -ExpectedKind 'UnknownTaskType' `
        -Action { Invoke-TaskExecutor -Task $noType -Registry $registry -RunContext @{} | Out-Null }

    # Missing required field → MissingExecutorField.
    $strictTask = @{ id = 't_AbCd1234'; name = 'needs payload'; type = 'strict' }
    Assert-DispatcherKind -Name "Dispatch throws MissingExecutorField when a required field is absent" `
        -ExpectedKind 'MissingExecutorField' `
        -Action { Invoke-TaskExecutor -Task $strictTask -Registry $registry -RunContext @{} | Out-Null }

    # Required-field check passes when the field is present and non-empty.
    $okStrictTask = @{ id = 't_AbCd1234'; name = 'has payload'; type = 'strict'; payload = 'something' }
    $r = Invoke-TaskExecutor -Task $okStrictTask -Registry $registry -RunContext @{}
    Assert-Equal -Name "Dispatch invokes strict executor when payload is supplied" -Expected $true -Actual $r['Success']

    # Test-ExecutorRequiredFields surfaces the missing-field list directly.
    $missing = Test-ExecutorRequiredFields -Task $strictTask -RequiredFields @('payload', 'name')
    Assert-Equal -Name "Test-ExecutorRequiredFields lists only the missing fields" -Expected 'payload' -Actual ($missing -join ',')
} finally {
    Remove-FixtureExecutorsDir -Path $fixture
}

# ═══════════════════════════════════════════════════════════════════════════
# Timeout: max_executor_duration is enforced; bounded time.
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Timeout (watchdog kills runaway executor)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$fixture = New-FixtureExecutorsDir
try {
    $registry = Get-ExecutorRegistry -ExecutorsDir $fixture -IgnoreMalformed

    $hangTask = @{ id = 't_AbCd1234'; name = 'will hang'; type = 'hang' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-TaskExecutor -Task $hangTask -Registry $registry -RunContext @{}
    $sw.Stop()

    Assert-Equal -Name "Hang executor returns Success=false on timeout" -Expected $false -Actual $r['Success']
    Assert-Equal -Name "Hang executor returns conventional exit 124"     -Expected 124 -Actual ([int]$r['ExitCode'])
    Assert-True  -Name "Hang executor result carries TimedOut=true"      -Condition ([bool]$r['TimedOut'])
    # PRD requires "bounded time". max_executor_duration is 1s; allow generous overhead for runspace teardown.
    Assert-True  -Name "Hang dispatch returns within 10s of the 1s budget" -Condition ($sw.ElapsedMilliseconds -lt 10000)
} finally {
    Remove-FixtureExecutorsDir -Path $fixture
}

# ═══════════════════════════════════════════════════════════════════════════
# Shipped executors (prompt / script / mcp)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  Shipped executors (prompt / script / mcp)" -ForegroundColor Cyan
Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor DarkGray

$shippedDir = Get-DotbotExecutorsDir -RuntimeRoot (Join-Path $repoRoot 'src/runtime')
Assert-PathExists -Name "Shipped executors directory exists" -Path $shippedDir

$shippedRegistry = Get-ExecutorRegistry -ExecutorsDir $shippedDir
Assert-True -Name "Shipped registry contains 'prompt'" -Condition ($shippedRegistry.ContainsKey('prompt'))
Assert-True -Name "Shipped registry contains 'script'" -Condition ($shippedRegistry.ContainsKey('script'))
Assert-True -Name "Shipped registry contains 'mcp'"    -Condition ($shippedRegistry.ContainsKey('mcp'))

Assert-Equal -Name "prompt: supports_worktree = true"   -Expected $true  -Actual $shippedRegistry['prompt'].metadata['supports_worktree']
Assert-Equal -Name "prompt: supports_analysis = true"   -Expected $true  -Actual $shippedRegistry['prompt'].metadata['supports_analysis']
Assert-Equal -Name "script: supports_worktree = true"   -Expected $true  -Actual $shippedRegistry['script'].metadata['supports_worktree']
Assert-Equal -Name "mcp: supports_worktree = false"     -Expected $false -Actual $shippedRegistry['mcp'].metadata['supports_worktree']

# Round-trip the prompt executor's contract surface.
$promptTask = @{
    id          = 't_PrPrPrPr'
    name        = 'demo prompt task'
    description = 'A short description that satisfies the required field.'
    type        = 'prompt'
}
$r = Invoke-TaskExecutor -Task $promptTask -Registry $shippedRegistry -RunContext @{ run_id = 'wr_AbCd1234'; worktree_path = '/tmp/wt' }
Assert-Equal -Name "Shipped prompt executor: Success = true" -Expected $true -Actual $r['Success']
Assert-Equal -Name "Shipped prompt executor: ExitCode = 0"   -Expected 0    -Actual ([int]$r['ExitCode'])

# Round-trip the script executor against a tiny inline script.
$tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) ("dotbot-prd05-script-" + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
Set-Content -LiteralPath $tmpScript -Value "exit 0" -Encoding utf8NoBOM
try {
    $scriptTask = @{
        id          = 't_ScScScSc'
        name        = 'demo script task'
        type        = 'script'
        script_path = $tmpScript
    }
    $r = Invoke-TaskExecutor -Task $scriptTask -Registry $shippedRegistry -RunContext @{}
    Assert-Equal -Name "Shipped script executor returns Success=true on exit 0" -Expected $true -Actual $r['Success']
    Assert-Equal -Name "Shipped script executor returns ExitCode=0"             -Expected 0     -Actual ([int]$r['ExitCode'])

    # Non-zero exit should surface as Success=false.
    Set-Content -LiteralPath $tmpScript -Value "exit 7" -Encoding utf8NoBOM
    $r = Invoke-TaskExecutor -Task $scriptTask -Registry $shippedRegistry -RunContext @{}
    Assert-Equal -Name "Shipped script executor returns Success=false on exit 7" -Expected $false -Actual $r['Success']
    Assert-Equal -Name "Shipped script executor surfaces non-zero ExitCode"      -Expected 7      -Actual ([int]$r['ExitCode'])

    # Missing script_path → MissingExecutorField at dispatch time.
    $noPathTask = @{ id = 't_ScScScSc'; name = 'no path'; type = 'script' }
    Assert-DispatcherKind -Name "Shipped script executor rejects task without script_path" `
        -ExpectedKind 'MissingExecutorField' `
        -Action { Invoke-TaskExecutor -Task $noPathTask -Registry $shippedRegistry -RunContext @{} | Out-Null }
} finally {
    try { Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
}

# Round-trip the mcp executor.
$mcpTask = @{
    id        = 't_McMcMcMc'
    name      = 'demo mcp task'
    type      = 'mcp'
    tool_name = 'task_list'
}
$r = Invoke-TaskExecutor -Task $mcpTask -Registry $shippedRegistry -RunContext @{ run_id = 'wr_AbCd1234' }
Assert-Equal -Name "Shipped mcp executor: Success = true" -Expected $true -Actual $r['Success']
Assert-Equal -Name "Shipped mcp executor: tool_name passed through" -Expected 'task_list' -Actual $r['tool_name']

Write-TestSummary -LayerName "Executors"

if ((Get-TestResults).Failed -gt 0) { exit 1 } else { exit 0 }
