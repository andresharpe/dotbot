using namespace System.Management.Automation

# Import DotBotTheme for consistent colors
if (-not (Get-Module DotBotTheme)) {
    Import-Module "$PSScriptRoot\..\modules\DotBotTheme.psm1" -Force
}
$script:theme = Get-DotBotTheme

# Import PathSanitizer for stripping absolute paths from activity log messages
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "systems\mcp\modules\PathSanitizer.psm1") -Force

#region Helper Functions

function Get-Timestamp {
    (Get-Date).ToString("HH:mm:ss")
}

function Get-PreviewText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [int]$MaxLength = 140
    )
    
    if (-not $Text) { return "" }
    
    $cleaned = $Text -replace "\r", "" -replace "\s+", " "
    
    if ($cleaned.Length -le $MaxLength) {
        return $cleaned
    }
    
    $cleaned.Substring(0, $MaxLength) + "…"
}

function Write-ActivityLog {
    [CmdletBinding()]
    param(
        [string]$Type,
        [string]$Message,
        [string]$Phase  # Optional: 'analysis' or 'execution'. Falls back to $env:DOTBOT_CURRENT_PHASE
    )

    if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
        # Delegate to DotBotLog — handles activity.jsonl, per-process logs, path sanitization, retry
        $levelMap = @{ 'error' = 'Error'; 'warning' = 'Warn'; 'fatal' = 'Fatal' }
        $level = if ($levelMap[$Type]) { $levelMap[$Type] } else { 'Info' }
        $ctx = @{ activity_type = $Type }
        if ($Phase) { $ctx.phase_override = $Phase }

        $savedPhase = $env:DOTBOT_CURRENT_PHASE
        if ($Phase) { $env:DOTBOT_CURRENT_PHASE = $Phase }
        try {
            Write-BotLog -Level $level -Message $Message -Context $ctx
        } finally {
            if ($Phase) { $env:DOTBOT_CURRENT_PHASE = $savedPhase }
        }
    } else {
        # Fallback: direct file write if DotBotLog not loaded
        $controlDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) ".control"
        if (-not (Test-Path $controlDir)) {
            New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
        }

        $effectivePhase = if ($Phase) { $Phase } elseif ($env:DOTBOT_CURRENT_PHASE) { $env:DOTBOT_CURRENT_PHASE } else { $null }
        $sanitizedMessage = Remove-AbsolutePaths -Text $Message -ProjectRoot $global:DotbotProjectRoot

        $event = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            type = $Type
            message = $sanitizedMessage
            task_id = $env:DOTBOT_CURRENT_TASK_ID
            phase = $effectivePhase
        } | ConvertTo-Json -Compress

        $logPath = Join-Path $controlDir "activity.jsonl"
        $maxRetries = 3
        for ($r = 0; $r -lt $maxRetries; $r++) {
            try {
                $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
                $sw.WriteLine($event)
                $sw.Close()
                $fs.Close()
                break
            } catch {
                if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
            }
        }

        $procId = $env:DOTBOT_PROCESS_ID
        if ($procId) {
            $processLogPath = Join-Path (Join-Path $controlDir "processes") "$procId.activity.jsonl"
            for ($r = 0; $r -lt $maxRetries; $r++) {
                try {
                    $fs = [System.IO.FileStream]::new($processLogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                    $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
                    $sw.WriteLine($event)
                    $sw.Close()
                    $fs.Close()
                    break
                } catch {
                    if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
                }
            }
        }
    }
}

function Write-ClaudeLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Kind,
        
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        
        [string]$Icon = ""
    )
    
    $t = $script:theme
    
    # Always newline before timestamp
    [Console]::Error.WriteLine("")
    
    $iconStr = if ($Icon) { "$Icon " } else { "" }
    $ts = Get-Timestamp
    [Console]::Error.WriteLine("$($t.Bezel)[$ts]$($t.Reset) $iconStr$($t.Cyan)$Kind$($t.Reset) $($t.AmberDim)$Message$($t.Reset)")
    [Console]::Error.Flush()
    
    # Also write to activity log for UI
    try {
        Write-ActivityLog -Type $Kind -Message $Message
    } catch {
        # Silently ignore logging errors
    }
}

function Write-ClaudeUnknown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawLine
    )
    
    $t = $script:theme
    
    # Always newline before timestamp
    [Console]::Error.WriteLine("")
    $ts = Get-Timestamp
    [Console]::Error.WriteLine("$($t.Bezel)[$ts]$($t.Reset) $($t.Label)$RawLine$($t.Reset)")
    [Console]::Error.Flush()
}

function ConvertTo-RenderedMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Markdown
    )
    
    # Use theme colors for markdown rendering
    $t = $script:theme
    $RESET  = $t.Reset
    $BOLD   = "`e[1m"
    $DIM    = $t.GreenDim
    $CYAN   = $t.Cyan
    $GREEN  = $t.Green
    $AMBER  = $t.Amber
    
    $lines = $Markdown -split "\r?\n"
    $result = New-Object System.Text.StringBuilder
    $inCodeBlock = $false
    $null = $codeLines = [System.Collections.ArrayList]::new()
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Code block detection
        if ($line -match '^```') {
            if (-not $inCodeBlock) {
                $inCodeBlock = $true
                $null = $codeLines = [System.Collections.ArrayList]::new()
                continue
            } else {
                # End of code block
                $inCodeBlock = $false
                
                if ($codeLines.Count -gt 0) {
                    $measureResult = $codeLines | Measure-Object -Property Length -Maximum
                    $maxLen = $measureResult.Maximum
                    $width = [Math]::Max($maxLen + 4, 40)
                    
                    [void]$result.AppendLine("$DIM+" + ("-" * ($width - 2)) + "+$RESET")
                    foreach ($codeLine in $codeLines) {
                        [void]$result.AppendLine("$DIM|$RESET $codeLine")
                    }
                    [void]$result.AppendLine("$DIM+" + ("-" * ($width - 2)) + "+$RESET")
                }
                continue
            }
        }
        
        if ($inCodeBlock) {
            [void]$codeLines.Add($line)
            continue
        }
        
        # Horizontal rule
        if ($line -match '^---+$' -or $line -match '^___+$') {
            [void]$result.AppendLine("")
            [void]$result.AppendLine("$DIM" + ("-" * 60) + "$RESET")
            [void]$result.AppendLine("")
            continue
        }
        
        # Headers
        if ($line -match '^(#{1,6})\s+(.+)$') {
            $level = $matches[1].Length
            $text = $matches[2]
            
            [void]$result.AppendLine("")
            if ($level -eq 1) {
                [void]$result.AppendLine("$BOLD$CYAN$text$RESET")
            } elseif ($level -eq 2) {
                [void]$result.AppendLine("$BOLD$text$RESET")
            } else {
                [void]$result.AppendLine("$BOLD$text$RESET")
            }
            continue
        }
        
        # Skip empty lines
        if ($line -match '^\s*$') {
            [void]$result.AppendLine($line)
            continue
        }
        
        # Apply green as base color first
        $processed = "$GREEN$line$RESET"
        
        # Inline code - reset to dim, then back to green
        $processed = $processed -replace '`([^`]+)`', "$RESET$DIM`$1$RESET$GREEN"
        
        # Bold - add bold, then back to green
        $processed = $processed -replace '\*\*([^\*]+)\*\*', "$BOLD`$1$RESET$GREEN"
        
        # Links [text](url) - cyan for text, dim for url, back to green
        $processed = $processed -replace '\[([^\]]+)\]\(([^\)]+)\)', "$RESET$CYAN`$1$RESET$DIM (`$2)$RESET$GREEN"
        
        # Bullet lists
        if ($line -match '^(\s*)[-*]\s+(.+)$') {
            $indent = $matches[1]
            # Re-process to add bullet
            $processed = $processed -replace '^(\x1b\[[0-9;]*m)(\s*)[-*]\s+', "`$1`$2* "
        }
        
        [void]$result.AppendLine($processed)
    }
    
    return $result.ToString()
}

function Format-TokenUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Usage
    )
    
    $null = $lines = [System.Collections.ArrayList]::new()
    
    if ($Usage.input_tokens -or $Usage.output_tokens) {
        $inp = if ($Usage.input_tokens) { $Usage.input_tokens } else { 0 }
        $out = if ($Usage.output_tokens) { $Usage.output_tokens } else { 0 }
        [void]$lines.Add("  tokens: in=$inp out=$out")
    }
    
    if ($Usage.cache_read_input_tokens) {
        $cacheRead = $Usage.cache_read_input_tokens
        [void]$lines.Add("  cache_read: $cacheRead")
    }
    
    if ($Usage.cache_creation_input_tokens) {
        $cacheCreate = $Usage.cache_creation_input_tokens
        [void]$lines.Add("  cache_create: $cacheCreate")
    }
    
    if ($Usage.server_tool_use) {
        $stu = $Usage.server_tool_use
        if ($stu.web_search_requests -or $stu.web_fetch_requests) {
            $ws = if ($stu.web_search_requests) { $stu.web_search_requests } else { 0 }
            $wf = if ($stu.web_fetch_requests) { $stu.web_fetch_requests } else { 0 }
            [void]$lines.Add("  web: search=$ws fetch=$wf")
        }
    }
    
    return $lines
}

function Format-ResultSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Event
    )
    
    $t = $script:theme
    
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("$($t.Bezel)" + ("─" * 70) + "$($t.Reset)")
    
    # Status
    $statusColor = if ($Event.subtype -eq "success") { $t.Green } else { $t.Red }
    $statusIcon = if ($Event.subtype -eq "success") { "✓" } else { "✗" }
    $statusText = if ($Event.subtype -eq "success") { "Success" } else { $Event.subtype }
    
    # Build summary line
    $null = $parts = [System.Collections.ArrayList]::new()
    [void]$parts.Add("$statusColor$statusIcon $statusText$($t.Reset)")
    
    if ($Event.duration_ms) {
        $durSec = [math]::Round($Event.duration_ms / 1000, 1)
        [void]$parts.Add("$($t.Label)time:$($t.Reset) $($t.Cyan)${durSec}s$($t.Reset)")
    }
    
    if ($Event.num_turns) {
        $turns = $Event.num_turns
        [void]$parts.Add("$($t.Label)turns:$($t.Reset) $($t.Cyan)$turns$($t.Reset)")
    }
    
    if ($Event.total_cost_usd) {
        $cost = [math]::Round($Event.total_cost_usd, 4)
        [void]$parts.Add("$($t.Amber)`$$cost$($t.Reset)")
    }
    
    [Console]::Error.WriteLine(($parts -join "  "))
    
    # Token usage
    if ($Event.usage) {
        $inp = if ($Event.usage.input_tokens) { $Event.usage.input_tokens } else { 0 }
        $out = if ($Event.usage.output_tokens) { $Event.usage.output_tokens } else { 0 }
        
        $null = $tokenParts = [System.Collections.ArrayList]::new()
        [void]$tokenParts.Add("$($t.Label)tokens:$($t.Reset) $($t.Cyan)in=$inp out=$out$($t.Reset)")
        
        if ($Event.usage.cache_read_input_tokens) {
            $cacheRead = $Event.usage.cache_read_input_tokens
            $cacheReadK = [math]::Round($cacheRead / 1000, 1)
            [void]$tokenParts.Add("$($t.Label)cache:$($t.Reset) $($t.Cyan)${cacheReadK}k$($t.Reset)")
        }
        
        [Console]::Error.WriteLine(($tokenParts -join "  "))
    }
    
    [Console]::Error.WriteLine("$($t.Bezel)" + ("─" * 70) + "$($t.Reset)")
    [Console]::Error.WriteLine("")
    [Console]::Error.Flush()
}

#endregion

#region Main Functions

# Script-scoped variable to store rate limit info for caller to check
$script:LastRateLimitInfo = $null

function Invoke-ClaudeStream {
    <#
    .SYNOPSIS
    Invokes Claude CLI with streaming output and detailed logging.
    
    .DESCRIPTION
    Executes the Claude CLI with JSON stream output format, parsing and colorizing
    the response in real-time. Provides detailed logging of tool use, results, and
    assistant messages.
    
    .PARAMETER Prompt
    The prompt to send to Claude.
    
    .PARAMETER FlushChars
    Number of characters to accumulate before flushing output (default: 200).
    
    .PARAMETER UnknownEverySeconds
    Throttle unknown event logging to every N seconds (default: 2).
    
    .PARAMETER PreviewChars
    Maximum characters to show in preview messages (default: 140).
    
    .PARAMETER Model
    Claude model to use (default: opus).
    
    .PARAMETER SessionId
    Optional session ID for conversation continuity.
    
    .PARAMETER ShowDebugJson
    Show raw JSON events in dark gray.
    
    .PARAMETER ShowVerbose
    Show detailed tool results and metadata.
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "What files are in the current directory?"
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "Analyze the code" -Model "sonnet"
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "Debug this" -ShowDebugJson -ShowVerbose
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model = "opus",

        [int]$FlushChars = 200,

        [int]$UnknownEverySeconds = 2,

        [int]$PreviewChars = 140,

        [string]$SessionId,

        [switch]$PersistSession,

        [switch]$ShowDebugJson,

        [switch]$ShowVerbose,

        [string[]]$PermissionArgs = @("--dangerously-skip-permissions")
    )

    # Clear any previous rate limit info
    $script:LastRateLimitInfo = $null

    # Refresh theme if ui-settings.json changed since last invocation
    if (Update-DotBotTheme) {
        $script:theme = Get-DotBotTheme
    }

    # Use theme colors
    $t = $script:theme

    $chars = 0
    $unknownEvery = [TimeSpan]::FromSeconds($UnknownEverySeconds)
    $assistantText = New-Object System.Text.StringBuilder
    $pendingToolCalls = @()

    # Mutable state shared with the $processLine scriptblock via hashtable reference.
    # Direct variable assignments ($x += 1) inside a scriptblock invoked with & create
    # local copies. Using a hashtable ($state.x += 1) mutates the shared object.
    $state = @{
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheRead = 0
        totalCacheCreate = 0
        lastTurnInput = 0                # most recent turn's input_tokens (not cumulative)
        lastTurnCacheRead = 0            # most recent turn's cache_read_input_tokens (not cumulative)
        lastUnknown = Get-Date
        turnCount = 0                    # B0f: turn counter
        lastUsageLogAt = 0               # B0b: last context-pct threshold at which we logged usage
        lastToolResultTime = $null       # B0h: wall-clock gap detection
        pendingToolNames = @{}           # B0d: track tool_use_id -> tool name for agent completion
    }

    $cliArgs = @(
        "--model", $Model
    ) + $PermissionArgs

    # Only add --no-session-persistence when NOT persisting sessions
    if (-not $PersistSession) {
        $cliArgs += "--no-session-persistence"
    }

    $cliArgs += @(
        "--output-format", "stream-json"
        "--print"
        "--verbose"
    )
    # Prompt is delivered via stdin after process start to avoid Windows command-line length limits (#167)

    # Session ID must be at the start of CLI args for proper parsing
    if ($SessionId) {
        $cliArgs = @("--session-id", $SessionId) + $cliArgs
    }

    # Ensure UTF-8 encoding for capturing claude.exe output (handles Unicode like middle dot ·)
    $prevOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Debug output: show invocation details
    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("$($t.Bezel)╭─── CLAUDE INVOCATION ───────────────────────────────────────────$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset) $($t.Label)Model:$($t.Reset)     $($t.Cyan)$Model$($t.Reset)")
        if ($SessionId) {
            [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset) $($t.Label)Session:$($t.Reset)   $($t.Cyan)$SessionId$($t.Reset)")
        } else {
            [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset) $($t.Label)Session:$($t.Reset)   $($t.Amber)(none)$($t.Reset)")
        }
        [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset) $($t.Label)CLI Args:$($t.Reset)")
        foreach ($arg in $cliArgs) {
            # Truncate long args (like prompts) for readability
            $displayArg = if ($arg.Length -gt 100) { $arg.Substring(0, 100) + "..." } else { $arg }
            # Escape newlines for display
            $displayArg = $displayArg -replace "`r`n", "↵" -replace "`n", "↵"
            [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)   $($t.Amber)$displayArg$($t.Reset)")
        }
        [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)")

        # Show prompt preview (truncated)
        $promptPreview = if ($Prompt.Length -gt 500) { $Prompt.Substring(0, 500) + "..." } else { $Prompt }
        $promptLines = $promptPreview -split "`r?`n"
        [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset) $($t.Label)Prompt Preview ($($Prompt.Length) chars):$($t.Reset)")
        $lineCount = 0
        foreach ($pline in $promptLines) {
            if ($lineCount -ge 15) {
                [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)   $($t.Amber)... (truncated)$($t.Reset)")
                break
            }
            $displayLine = if ($pline.Length -gt 80) { $pline.Substring(0, 80) + "..." } else { $pline }
            [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)   $($t.Green)$displayLine$($t.Reset)")
            $lineCount++
        }
        [Console]::Error.WriteLine("$($t.Bezel)╰──────────────────────────────────────────────────────────────────$($t.Reset)")
        [Console]::Error.WriteLine("")
        [Console]::Error.Flush()
    }

    # Debug: show we're about to invoke
    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] About to invoke claude.exe...$($t.Reset)")
        [Console]::Error.Flush()
    }

    try {
    $lineCount = 0

    # --- Process-aware invocation (Fix A: Orphaned Background Process Pipeline Deadlock) ---
    # Instead of a simple pipeline (& claude.exe ... | ForEach-Object) which blocks until
    # ALL processes holding the stdout pipe handle exit (including background dev servers
    # launched by Claude via Bash), we use System.Diagnostics.Process to:
    # 1. Track the main claude.exe PID
    # 2. Read stdout line-by-line
    # 3. Detect when claude.exe exits and drain remaining output with a timeout
    # 4. Kill the entire process tree to release orphan children
    # Resolve claude CLI executable (handles .exe, .cmd, and other extensions)
    $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claudeCmd) {
        $claudeCmd = Get-Command claude.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    }
    $claudeExePath = $claudeCmd.Source

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claudeExePath
    # Use ArgumentList (.NET 5+ / PS 7+) for platform-correct quoting — no manual escaping
    foreach ($arg in $cliArgs) { $psi.ArgumentList.Add($arg) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true   # Prompt delivered via stdin to avoid Windows cmd-line length limit (#167)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # Ensure claude.exe starts in the project root so it discovers .mcp.json
    # and starts all configured MCP servers (including dotbot with yaml_write_ticket etc.).
    # Without this, kickstart launches from the UI inherit the server's CWD which
    # may not be the project root — causing all mcp__dotbot__* tools to be missing.
    if ($global:DotbotProjectRoot -and (Test-Path $global:DotbotProjectRoot)) {
        $psi.WorkingDirectory = $global:DotbotProjectRoot
    }
    # Marker env var (informational, not functionally critical)
    $psi.Environment["__DOTBOT_MANAGED"] = "1"

    $claudeProc = New-Object System.Diagnostics.Process
    $claudeProc.StartInfo = $psi
    $claudeProc.Start() | Out-Null

    # Deliver prompt via stdin to avoid Windows command-line length limits (#167)
    $claudeProc.StandardInput.Write($Prompt)
    $claudeProc.StandardInput.Close()

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] claude started as PID $($claudeProc.Id)$($t.Reset)")
        [Console]::Error.Flush()
    }

    # --- Fix C: descendant PID snapshot monitor (Windows only) ---
    # Periodically walks the process tree starting from claude.exe and records
    # every descendant PID we ever observe. This snapshot persists after claude.exe
    # exits (unlike a live ParentProcessId query, which fails post-exit because
    # Windows does not re-parent orphans to a well-known root). Cleanup in the
    # finally block iterates the snapshot and kills each PID by number — which
    # works regardless of whether claude.exe or its intermediate shell hosts are
    # still alive. This is the only reliable way to kill grandchildren like
    # `dotnet test` → `vstest.console` → `testhost.exe` that Claude Code spawns
    # via its Bash tool.
    #
    # Win32_Process is WMI and is Windows-only, so the whole monitor is gated on
    # $IsWindows. On Linux/macOS, claude.exe's children are re-parented to init
    # (PID 1) on exit and can be reached via pgrep/pkill at teardown if needed —
    # the snapshot approach is not required there and would just run an
    # expensive-and-empty CIM query every 2s.
    $descendantPids = $null
    $treeMonitorCts = $null
    $treeMonitor = $null
    if ($IsWindows) {
        $descendantPids = [System.Collections.Concurrent.ConcurrentDictionary[int,byte]]::new()
        $treeMonitorCts = [System.Threading.CancellationTokenSource]::new()
        $claudePidLocal = $claudeProc.Id
        $treeMonitor = [System.Threading.Tasks.Task]::Run([Action]{
            try {
                while (-not $claudeProc.HasExited -and -not $treeMonitorCts.IsCancellationRequested) {
                    try {
                        $allProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
                        if ($allProcs) {
                            # BFS from $claudePidLocal through all known descendants
                            $known = @{ $claudePidLocal = $true }
                            foreach ($k in $descendantPids.Keys) { $known[[int]$k] = $true }
                            $added = $true
                            while ($added) {
                                $added = $false
                                foreach ($p in $allProcs) {
                                    if ($known.ContainsKey([int]$p.ParentProcessId) -and -not $known.ContainsKey([int]$p.ProcessId) -and $p.ProcessId -ne $PID) {
                                        $known[[int]$p.ProcessId] = $true
                                        [void]$descendantPids.TryAdd([int]$p.ProcessId, 0)
                                        $added = $true
                                    }
                                }
                            }
                        }
                    } catch { }
                    # Poll every 2s — fast enough to catch short-lived children, slow
                    # enough to keep WMI query cost negligible
                    [void]$treeMonitorCts.Token.WaitHandle.WaitOne(2000)
                }
            } catch { }
        })
    }

    # Drain stderr line-by-line in a background task to prevent buffer deadlock.
    # Uses ReadLineAsync with a 2s timeout so the loop can detect process exit
    # and cancellation even when the pipe's write-end is held open by an
    # orphaned grandchild process (e.g. a backgrounded `dotnet test` whose
    # testhost.exe inherited claude.exe's stderr handle). Synchronous
    # ReadLine() would block indefinitely on such an orphan-held pipe and
    # leave the main thread unable to cleanly Dispose the process — see
    # "Orphaned Background Process Pipeline Deadlock" note above.
    $stderrDrainCts = [System.Threading.CancellationTokenSource]::new()
    $stderrDrain = [System.Threading.Tasks.Task]::Run([Action]{
        $pendingStderrRead = $null
        try {
            while (-not $claudeProc.HasExited -and -not $stderrDrainCts.IsCancellationRequested) {
                if (-not $pendingStderrRead) {
                    $pendingStderrRead = $claudeProc.StandardError.ReadLineAsync()
                }
                if ($pendingStderrRead.Wait(2000)) {
                    $line = $pendingStderrRead.Result
                    $pendingStderrRead = $null
                    if ($null -eq $line) { break }

                    if ($ShowDebugJson) {
                        [Console]::Error.WriteLine("$($t.Bezel)[STDERR] $line$($t.Reset)")
                        [Console]::Error.Flush()
                    }
                }
                # else: 2s timeout elapsed — loop back and re-check HasExited / cancellation
            }
        } catch {
            # Ignore errors from reading stderr after process exit or stream disposal
        }
    })

    $processLine = {
        param([string]$raw)

        if (-not $raw) { return }
        try {
            $line = $raw.TrimStart()
            if ($line.Length -eq 0) { return }
            
            # Check for rate limit in JSON responses
            if ($line[0] -eq '{' -and $line -match "hit your limit|error.*rate_limit") {
                try {
                    $jsonObj = $line | ConvertFrom-Json -ErrorAction Stop
                    # Extract the actual message text from JSON
                    $rateLimitText = $null
                    if ($jsonObj.result -and $jsonObj.result -match "resets?") {
                        $rateLimitText = $jsonObj.result
                    } elseif ($jsonObj.message?.content -is [System.Array]) {
                        foreach ($c in $jsonObj.message.content) {
                            if ($c.type -eq "text" -and $c.text -match "resets?") {
                                $rateLimitText = $c.text
                                break
                            }
                        }
                    } elseif ($jsonObj.error -eq "rate_limit") {
                        $rateLimitText = "Rate limit hit (no reset time provided)"
                    }
                    
                    if ($rateLimitText) {
                        [Console]::Error.WriteLine("")
                        [Console]::Error.WriteLine("$($t.Amber)⚠ RATE LIMIT: $rateLimitText$($t.Reset)")
                        [Console]::Error.Flush()
                        
                        # Store the extracted message for caller to handle
                        $script:LastRateLimitInfo = $rateLimitText
                        
                        Write-ActivityLog -Type "rate_limit" -Message $rateLimitText
                        return
                    }
                } catch {
                    # JSON parse failed, continue normal processing
                }
            }
            
            # Check for plain text rate limit messages
            if ($line[0] -ne '{' -and $line -match "hit your limit|resets?\s+\d{1,2}:?\d*\s*(am|pm)") {
                [Console]::Error.WriteLine("")
                [Console]::Error.WriteLine("$($t.Amber)⚠ RATE LIMIT: $line$($t.Reset)")
                [Console]::Error.Flush()
                
                $script:LastRateLimitInfo = $line
                Write-ActivityLog -Type "rate_limit" -Message $line
                return
            }
            
            if ($line[0] -ne '{') {
                if ($ShowDebugJson -and $lineCount -le 5) {
                    $preview = if ($line.Length -gt 80) { $line.Substring(0, 80) + "..." } else { $line }
                    [Console]::Error.WriteLine("$($t.Bezel)[SKIP] Not JSON: $preview$($t.Reset)")
                    [Console]::Error.Flush()
                }
                return
            }
            
            # ShowDebugJson: show raw JSON in dark gray
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Bezel)[JSON] $line$($t.Reset)")
                [Console]::Error.Flush()
            }

            $evt = $null
            try { 
                $evt = $line | ConvertFrom-Json -ErrorAction Stop 
            } 
            catch { 
                $evt = $null 
            }

        if (-not $evt) {
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("")
                [Console]::Error.WriteLine("$($t.Bezel)[JSON] $line$($t.Reset)")
                [Console]::Error.Flush()
            } else {
                $now = Get-Date
                if (($now - $state.lastUnknown) -ge $unknownEvery) {
                    Write-ClaudeUnknown (Get-PreviewText $line 1200)
                    $state.lastUnknown = $now
                }
            }
            return
        }

        # Debug: show event type
        if ($ShowDebugJson) {
            $evtType = if ($evt.type) { $evt.type } else { "unknown" }
            $evtSubtype = if ($evt.subtype) { "/$($evt.subtype)" } else { "" }
            [Console]::Error.WriteLine("$($t.Bezel)[EVT] $evtType$evtSubtype$($t.Reset)")
            [Console]::Error.Flush()
        }

        # --- 1) Stream assistant text and track usage ---
        $text = $null

        if ($evt.message?.delta?.text) {
            $text = $evt.message.delta.text
        }
        elseif ($evt.message?.content -is [System.Array]) {
            foreach ($b in $evt.message.content) {
                if ($b.type -eq "text" -and $b.text) { 
                    $text += $b.text 
                }
                elseif ($b.delta?.text) { 
                    $text += $b.delta.text 
                }
            }
        }
        elseif ($evt.message?.content -is [string]) {
            $text = $evt.message.content
        }
        
        # Track token usage from any message
        if ($evt.message?.usage) {
            $usage = $evt.message.usage
            if ($usage.input_tokens) { $state.totalInputTokens += $usage.input_tokens }
            if ($usage.output_tokens) { $state.totalOutputTokens += $usage.output_tokens }
            if ($usage.cache_read_input_tokens) { $state.totalCacheRead += $usage.cache_read_input_tokens }
            if ($usage.cache_creation_input_tokens) { $state.totalCacheCreate += $usage.cache_creation_input_tokens }

            # Track last-turn values (set, not accumulated) for accurate context-window size display
            $state.lastTurnInput = if ($usage.input_tokens) { $usage.input_tokens } else { 0 }
            $state.lastTurnCacheRead = if ($usage.cache_read_input_tokens) { $usage.cache_read_input_tokens } else { 0 }

            # B0f: increment turn counter on each usage report (proxy for turns)
            $state.turnCount++

            # B0b+B0c: periodic usage logging to JSONL (every 25% of context window)
            $ctxTokens = $state.lastTurnInput + $state.lastTurnCacheRead
            $pctRaw = $ctxTokens / 200000 * 100
            $pct = [math]::Round($pctRaw, 1)
            $currentThreshold = [math]::Floor($pctRaw / 25)
            if ($currentThreshold -gt $state.lastUsageLogAt) {
                $state.lastUsageLogAt = $currentThreshold
                $usageMsg = "turn=$($state.turnCount) in=$($state.totalInputTokens) out=$($state.totalOutputTokens) cache=$($state.totalCacheRead) ctx=${pct}%"
                Write-ActivityLog -Type "usage" -Message $usageMsg
                # B0c: console warning when approaching context limit
                if ($pct -gt 80) {
                    [Console]::Error.WriteLine("")
                    [Console]::Error.WriteLine("$($t.Amber)⚠ CONTEXT WINDOW: ${pct}% used ($ctxTokens tokens)$($t.Reset)")
                    [Console]::Error.Flush()
                }
            }
        }

        if ($text) {
            [void]$assistantText.Append($text)
            return
        }

        # --- 2) Init/config event ---
        if ($evt.type -and $evt.subtype -and $evt.model -and $evt.cwd) {
            $m = $evt.model
            Write-ClaudeLog "init" "$m" "*"
            # B0g: Log session start with model and session ID to JSONL
            $sid = if ($SessionId) { $SessionId } else { "none" }
            Write-ActivityLog -Type "session_start" -Message "model=$m session=$sid"
            return
        }

        # --- 3) Tool use ---
        if ($evt.type -eq "assistant" -and $evt.message?.content -is [System.Array]) {
            $null = $toolUses = [System.Collections.ArrayList]::new()
            $filtered = @($evt.message.content | Where-Object { $_.type -eq "tool_use" })
            if ($filtered -and $filtered.Count -gt 0) {
                [void]$toolUses.AddRange($filtered)
            }
            if ($toolUses.Count -gt 0) {
                # Render accumulated assistant text before showing tool calls
                if ($assistantText.Length -gt 0) {
                    # Show token usage FIRST in muted color if we have any
                    if ($state.totalInputTokens -gt 0 -or $state.totalOutputTokens -gt 0) {
                        $tokenInfo = "tokens: $($state.totalInputTokens)in"
                        if ($state.totalCacheRead -gt 0) {
                            $tokenInfo += " ($($state.totalCacheRead) cached)"
                        }
                        $tokenInfo += " / $($state.totalOutputTokens) out"
                        [Console]::WriteLine("")
                        [Console]::WriteLine("$($t.Bezel)[$tokenInfo]$($t.Reset)")
                    }
                    
                    # THEN render the message
                    $rendered = ConvertTo-RenderedMarkdown $assistantText.ToString()
                    [Console]::WriteLine("")
                    [Console]::Write($rendered)
                    
                    # Log assistant text to activity for UI display
                    $textPreview = (Get-PreviewText $assistantText.ToString() 200)
                    Write-ActivityLog -Type "text" -Message $textPreview
                    
                    [Console]::Out.Flush()
                    $assistantText.Length = 0
                }
                
                foreach ($tu in $toolUses) {
                    $name = $tu.name
                    $id   = $tu.id
                    $inp  = $tu.input
                    
                    # B0d: track tool_use_id -> name for agent completion matching
                    if ($id) { $state.pendingToolNames[$id] = $name }

                    # Hide TodoWrite calls
                    if ($name -eq "TodoWrite") {
                        continue
                    }

                    $detail = ""
                    if ($inp) {
                        if ($inp.command) { 
                            $detail = (Get-PreviewText $inp.command $PreviewChars) 
                        }
                        elseif ($inp.pattern) { 
                            $patt = $inp.pattern
                            $detail = 'pattern="' + $patt + '"'
                        }
                        elseif ($inp.file_path) { 
                            # Clean up file path
                            $cleanPath = $inp.file_path -replace '\\\\', '\\' -replace [regex]::Escape($PWD.Path + '\'), ''
                            $detail = $cleanPath
                        }
                        elseif ($inp.description) { 
                            $detail = (Get-PreviewText $inp.description $PreviewChars) 
                        }
                        elseif ($inp.prompt) { 
                            $detail = (Get-PreviewText $inp.prompt $PreviewChars) 
                        }
                    }

                    # Ensure detail is not null
                    if (-not $detail) { $detail = "" }
                    Write-ClaudeLog $name $detail ">"
                }
                return
            }
        }

        # --- 4) Tool result ---
        if ($evt.type -eq "user") {
            $null = $toolResults = [System.Collections.ArrayList]::new()
            if ($evt.message?.content -is [System.Array]) {
                $filtered = @($evt.message.content | Where-Object { $_.type -eq "tool_result" })
                if ($filtered -and $filtered.Count -gt 0) {
                    [void]$toolResults.AddRange($filtered)
                }
            }

            if ($toolResults.Count -gt 0 -or $evt.tool_use_result) {
                # Render accumulated assistant text before showing tool results
                if ($assistantText.Length -gt 0) {
                # Show token usage FIRST in dark gray if we have any
                    if ($state.totalInputTokens -gt 0 -or $state.totalOutputTokens -gt 0) {
                        $tokenInfo = "tokens: $($state.totalInputTokens)in"
                        if ($state.totalCacheRead -gt 0) {
                            $tokenInfo += " ($($state.totalCacheRead) cached)"
                        }
                        $tokenInfo += " / $($state.totalOutputTokens) out"
                        [Console]::WriteLine("")
                        [Console]::WriteLine("$($t.Bezel)[$tokenInfo]$($t.Reset)")
                    }
                    
                    # THEN render the message
                    $rendered = ConvertTo-RenderedMarkdown $assistantText.ToString()
                    [Console]::WriteLine("")
                    [Console]::Write($rendered)
                    
                    # Log assistant text to activity for UI display
                    $textPreview = (Get-PreviewText $assistantText.ToString() 200)
                    Write-ActivityLog -Type "text" -Message $textPreview
                
                    [Console]::Out.Flush()
                    $assistantText.Length = 0
                }
                
                # B0h: record wall-clock time of tool results for gap detection
                $state.lastToolResultTime = Get-Date

                foreach ($tr in $toolResults) {
                    $id = $tr.tool_use_id
                    $isErr = [bool]$tr.is_error
                    $null = $meta = [System.Collections.ArrayList]::new()
                    if ($evt.tool_use_result) {
                        if ($evt.tool_use_result.durationMs -ne $null -and $evt.tool_use_result.durationMs -gt 100) { 
                            $dur = $evt.tool_use_result.durationMs
                            [void]$meta.Add("${dur}ms")
                        }
                        if ($evt.tool_use_result.numFiles -ne $null) { 
                            $nf = $evt.tool_use_result.numFiles
                            [void]$meta.Add("$nf files")
                        }
                    }

                    $icon = if ($isErr) { "x" } else { "+" }
                    $msg = if ($meta.Count -gt 0) { $meta -join ", " } else { ""}

                    if ($msg) {
                        Write-ClaudeLog "done" $msg $icon
                    }

                    # B0d: detect sub-agent completion/failure
                    $toolName = if ($id -and $state.pendingToolNames.ContainsKey($id)) { $state.pendingToolNames[$id] } else { $null }
                    if ($toolName -and $toolName -match '^Agent') {
                        $agentStatus = if ($isErr) { "error" } else { "success" }
                        $agentDur = if ($meta.Count -gt 0) { " $($meta -join ', ')" } else { "" }
                        Write-ActivityLog -Type "agent_done" -Message "$toolName [$agentStatus]$agentDur"
                    }

                    # B0e: log error content to JSONL (always, not just ShowVerbose)
                    if ($isErr -and $tr.content) {
                        $errPreview = if ($tr.content -is [string]) { Get-PreviewText $tr.content 200 } else { "(non-string error)" }
                        $errToolName = if ($toolName) { $toolName } else { "unknown" }
                        Write-ActivityLog -Type "error" -Message "$errToolName`: $errPreview"
                    }

                    # Clean up pending tool name tracking
                    if ($id -and $state.pendingToolNames.ContainsKey($id)) { $state.pendingToolNames.Remove($id) }
                    
                    # ShowVerbose: show tool result content
                    if ($ShowVerbose -and $tr.content) {
                        $content = $tr.content
                        if ($content -is [string]) {
                            $lines = @($content -split "`n")
                            $lineCount = $lines.Count
                            
                            # Truncate if too long
                            $maxLines = 20
                            if ($lineCount -gt $maxLines) {
                                $displayLines = $lines[0..($maxLines - 1)]
                                [Console]::Error.WriteLine("$($t.Amber)           ↓ Result ($lineCount lines, showing first $maxLines):$($t.Reset)")
                                foreach ($line in $displayLines) {
                                    [Console]::Error.WriteLine("$($t.Amber)           < $line$($t.Reset)")
                                }
                                [Console]::Error.WriteLine("$($t.Amber)           ... truncated $($lineCount - $maxLines) more lines$($t.Reset)")
                            } else {
                                [Console]::Error.WriteLine("$($t.Amber)           ↓ Result ($lineCount lines):$($t.Reset)")
                                foreach ($line in $lines) {
                                    [Console]::Error.WriteLine("$($t.Amber)           < $line$($t.Reset)")
                                }
                            }
                        }
                        [Console]::Error.Flush()
                    }
                }
                return
            }
        }

        # --- 5) System event handling (B0a) ---
        if ($evt.type -eq "system" -or ($evt.type -and "$($evt.type)" -match 'compact')) {
            $subtype = "$($evt.subtype)"

            # Agent lifecycle events — not compaction, just progress/completion notifications
            if ($subtype -in @('task_started', 'task_progress')) {
                Write-ActivityLog -Type "agent_progress" -Message "subtype=$subtype turn=$($state.turnCount)"
                return
            }
            if ($subtype -eq 'task_notification') {
                Write-ActivityLog -Type "agent_done" -Message "turn=$($state.turnCount)"
                return
            }

            # Real context compaction (B0a) — system event with a compaction summary in $evt.message,
            # or event type explicitly contains 'compact'
            $compactMsg = if ($evt.message) { Get-PreviewText "$($evt.message)" 200 } else { "context auto-compacted" }
            $ctxTokens = $state.lastTurnInput + $state.lastTurnCacheRead
            $pct = [math]::Round($ctxTokens / 200000 * 100, 1)
            Write-ClaudeLog "compact" $compactMsg "⚠"
            Write-ActivityLog -Type "compact" -Message "turn=$($state.turnCount) ctx=${ctxTokens} (${pct}%) $compactMsg"
            [Console]::Error.WriteLine("$($t.Amber)⚠ CONTEXT COMPACTED at turn $($state.turnCount) ($ctxTokens tokens, ${pct}%)$($t.Reset)")
            [Console]::Error.Flush()
            # Reset usage-logging threshold so milestones (including >80% warning) fire again
            # as the compacted context regrows.
            $state.lastUsageLogAt = 0
            return
        }

        # --- 5b) Wall-clock gap detection (B0h) ---
        if ($evt.type -eq "assistant" -and $state.lastToolResultTime) {
            $gap = ((Get-Date) - $state.lastToolResultTime).TotalSeconds
            if ($gap -gt 15) {
                $gapRounded = [math]::Round($gap, 1)
                Write-ActivityLog -Type "thinking" -Message "${gapRounded}s pause after turn $($state.turnCount)"
            }
            $state.lastToolResultTime = $null
        }

        # --- 6) Result summary ---
        if ($evt.type -eq "result") {
            # Render any remaining assistant text
            if ($assistantText.Length -gt 0) {
                # Show token usage FIRST in dark gray if we have any
                if ($state.totalInputTokens -gt 0 -or $state.totalOutputTokens -gt 0) {
                    $tokenInfo = "tokens: $($state.totalInputTokens)in"
                    if ($state.totalCacheRead -gt 0) {
                        $tokenInfo += " ($($state.totalCacheRead) cached)"
                    }
                    $tokenInfo += " / $($state.totalOutputTokens) out"
                    [Console]::WriteLine("")
                    [Console]::WriteLine("$($t.Bezel)[$tokenInfo]$($t.Reset)")
                }
                
                # THEN render the message
                $rendered = ConvertTo-RenderedMarkdown $assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::Write($rendered)
                
                # Log assistant text to activity for UI display
                $textPreview = (Get-PreviewText $assistantText.ToString() 200)
                Write-ActivityLog -Type "text" -Message $textPreview
                
                [Console]::Out.Flush()
                [Console]::Out.Flush()
                $assistantText.Length = 0
            }
            
            Format-ResultSummary $evt

            # B0b: persist result summary to JSONL
            $resultParts = @("turns=$(if ($evt.num_turns) { $evt.num_turns } else { $state.turnCount })")
            if ($evt.usage) {
                $rIn = if ($evt.usage.input_tokens) { $evt.usage.input_tokens } else { $state.totalInputTokens }
                $rOut = if ($evt.usage.output_tokens) { $evt.usage.output_tokens } else { $state.totalOutputTokens }
                $resultParts += "in=$rIn", "out=$rOut"
                if ($evt.usage.cache_read_input_tokens) {
                    $rCacheK = [math]::Round($evt.usage.cache_read_input_tokens / 1000, 1)
                    $resultParts += "cache=${rCacheK}k"
                }
            }
            if ($evt.total_cost_usd) { $resultParts += "cost=`$$([math]::Round($evt.total_cost_usd, 4))" }
            if ($evt.duration_ms) { $resultParts += "time=$([math]::Round($evt.duration_ms / 1000, 1))s" }
            Write-ActivityLog -Type "result" -Message ($resultParts -join " ")

            return
        }

            # --- 7) Unknown fallback (throttled) ---
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("")
                [Console]::Error.WriteLine("$($t.Bezel)[JSON] $line$($t.Reset)")
                [Console]::Error.Flush()
            } else {
                $now = Get-Date
                if (($now - $state.lastUnknown) -ge $unknownEvery) {
                    Write-ClaudeUnknown (Get-PreviewText $line 2000)
                    $state.lastUnknown = $now
                }
            }
        } catch {
            # Silently catch and continue on any processing errors
            # to prevent the entire stream from crashing
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Amber)[DEBUG] Error processing event: $($_.Exception.Message)$($t.Reset)")
                [Console]::Error.Flush()
            }
            Write-BotLog -Level Debug -Message "Error processing stream event" -Exception $_
        }
    }

    # --- Main read loop: read stdout lines until claude.exe exits ---
    # Uses ReadLineAsync with a timeout so the loop can detect process exit even when
    # no output is flowing (e.g., claude.exe hung on an API call). Without this, a
    # synchronous ReadLine() would block indefinitely.
    $mainExited = $false
    $drainDeadline = $null
    $drainGraceSeconds = 10   # seconds to drain remaining output after process exits
    $readTimeoutMs = 2000     # how often to check HasExited between reads
    $pendingReadTask = $null

    while ($true) {
        # Check if main process exited and we haven't started draining yet
        if (-not $mainExited -and $claudeProc.HasExited) {
            $mainExited = $true
            $drainDeadline = (Get-Date).AddSeconds($drainGraceSeconds)
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] claude exited (code $($claudeProc.ExitCode)), draining output...$($t.Reset)")
                [Console]::Error.Flush()
            }
        }

        # If draining and past deadline, stop reading
        if ($mainExited -and (Get-Date) -gt $drainDeadline) {
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Drain deadline reached, stopping read loop$($t.Reset)")
                [Console]::Error.Flush()
            }
            # Cancel any outstanding async read before breaking to avoid
            # an unobserved task holding a reference to the disposed stream
            if ($pendingReadTask) {
                try { $claudeProc.StandardOutput.Close() } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to close stdout stream" -Exception $_ }
                $pendingReadTask = $null
            }
            break
        }

        # Start an async read if we don't have one pending
        try {
            if (-not $pendingReadTask) {
                $pendingReadTask = $claudeProc.StandardOutput.ReadLineAsync()
            }

            # Wait for the read to complete with a timeout
            if ($pendingReadTask.Wait($readTimeoutMs)) {
                # Read completed — get the result
                $raw = $pendingReadTask.Result
                $pendingReadTask = $null
            } else {
                # Timeout — loop back to check HasExited
                continue
            }
        } catch {
            # Stream disposed or broken — exit
            break
        }

        if ($null -eq $raw) { break }

        $lineCount++
        if ($ShowDebugJson -and $lineCount -le 3) {
            [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Received line $lineCount$($t.Reset)")
            [Console]::Error.Flush()
        }

        try {
            & $processLine $raw
        } catch {
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Amber)[DEBUG] Error processing event: $($_.Exception.Message)$($t.Reset)")
                [Console]::Error.Flush()
            }
            Write-BotLog -Level Debug -Message "Error processing stream event" -Exception $_
        }
    }

    # Debug: show stream completed
    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Stream completed. Total lines received: $lineCount$($t.Reset)")
        [Console]::Error.Flush()
    }

    # --- Kill orphan child processes in the claude.exe process tree ---
    try {
        if (-not $claudeProc.HasExited) {
            $claudeProc.WaitForExit(5000)
            if (-not $claudeProc.HasExited) {
                $claudeProc.Kill($true)  # $true = kill entire process tree (.NET 5+)
            }
        }

        # Also find and kill any orphaned child processes by parent PID
        # (children may have been re-parented if claude.exe already exited)
        $claudePid = $claudeProc.Id
        if ($IsWindows) {
            $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ParentProcessId -eq $claudePid -and $_.ProcessId -ne $PID }
            foreach ($child in $children) {
                try { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop child process $($child.ProcessId)" -Exception $_ }
            }
        } else {
            # On Linux/macOS, use pkill to kill children by parent PID
            try { & pkill -P $claudePid 2>/dev/null } catch { Write-BotLog -Level Debug -Message "Cleanup: pkill failed for parent PID ${claudePid}" -Exception $_ }
        }
    } catch {
        # Best-effort cleanup - don't fail the stream on cleanup errors
        if ($ShowDebugJson) {
            [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Process tree cleanup error: $($_.Exception.Message)$($t.Reset)")
            [Console]::Error.Flush()
        }
    }

    } finally {
        # Restore original output encoding
        [Console]::OutputEncoding = $prevOutputEncoding

        # Signal the stderr drain task to stop and wait briefly. Closing the
        # StandardError stream unblocks any in-flight ReadLineAsync so the task
        # can observe the cancellation token. Without this, Process.Dispose()
        # below can race with a live Task still holding the stream. All errors
        # are swallowed silently because (a) this runs during cleanup where the
        # best we can do is move on, and (b) Write-BotLog is in a separate module
        # that may not be loaded by callers such as the mock-claude test harness.
        if ($stderrDrainCts) {
            try { $stderrDrainCts.Cancel() } catch { }
        }
        if ($claudeProc -and $claudeProc.StandardError) {
            try { $claudeProc.StandardError.Close() } catch { }
        }
        if ($stderrDrain) {
            try { [void]$stderrDrain.Wait(3000) } catch { }
        }
        if ($stderrDrainCts) {
            try { $stderrDrainCts.Dispose() } catch { }
        }

        # Kill all descendant PIDs we captured while claude.exe was alive (Fix C).
        # This is bullet-proof against re-parenting: the snapshot persists across
        # claude.exe exit, so we can still terminate orphaned grandchildren.
        if ($descendantPids -and $descendantPids.Count -gt 0) {
            try {
                $pidsToKill = @($descendantPids.Keys) | Where-Object { $_ -ne $claudeProc.Id -and $_ -ne $PID }
                foreach ($dpid in $pidsToKill) {
                    try { Stop-Process -Id $dpid -Force -ErrorAction SilentlyContinue } catch { }
                }
                if ($ShowDebugJson -and $pidsToKill.Count -gt 0) {
                    [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Killed $($pidsToKill.Count) descendant PIDs from snapshot$($t.Reset)")
                    [Console]::Error.Flush()
                }
            } catch { }
        }
        if ($treeMonitorCts) {
            try { $treeMonitorCts.Cancel() } catch { }
            try { if ($treeMonitor) { [void]$treeMonitor.Wait(1000) } } catch { }
            try { $treeMonitorCts.Dispose() } catch { }
        }

        # Ensure process is disposed
        if ($claudeProc -and -not $claudeProc.HasExited) {
            try { $claudeProc.Kill($true) } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to kill process" -Exception $_ }
        }
        if ($claudeProc) {
            try { $claudeProc.Dispose() } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to dispose process" -Exception $_ }
        }
    }
}

function Invoke-Claude {
    <#
    .SYNOPSIS
    Invokes Claude CLI with simple output (no streaming parsing).
    
    .DESCRIPTION
    A simpler wrapper around the Claude CLI that doesn't parse streaming JSON.
    Useful for quick questions where you don't need detailed tool logging.
    
    .PARAMETER Prompt
    The prompt to send to Claude.
    
    .PARAMETER Model
    Claude model to use (default: opus).
    
    .PARAMETER SessionId
    Optional session ID for conversation continuity.
    
    .PARAMETER NoPermissions
    Skip permission checks (default: enabled).
    
    .EXAMPLE
    Invoke-Claude -Prompt "What is 2+2?"
    
    .EXAMPLE
    "Explain this code" | Invoke-Claude -Model "sonnet"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model = "opus",
        
        [string]$SessionId,

        [switch]$NoPermissions,

        [string[]]$PermissionArgs
    )

    # Resolve claude CLI executable (handles .exe, .cmd, and non-Windows platforms)
    $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claudeCmd) {
        $claudeCmd = Get-Command claude.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    }
    $claudeExePath = $claudeCmd.Source

    # Prompt delivered via stdin to avoid Windows cmd-line length limit (#167)
    $cliArgs = @(
        "--model", $Model
        "--print"
    )

    if ($PermissionArgs) {
        $cliArgs += $PermissionArgs
    } elseif ($NoPermissions) {
        $cliArgs += "--dangerously-skip-permissions"
    }

    if ($SessionId) {
        $cliArgs += "--session-id", $SessionId
    }

    $previousOutputEncoding = $OutputEncoding
    $previousConsoleInputEncoding = [Console]::InputEncoding
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    $utf8Encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        $OutputEncoding = $utf8Encoding
        [Console]::InputEncoding = $utf8Encoding
        [Console]::OutputEncoding = $utf8Encoding

        $Prompt | & $claudeExePath @cliArgs
    }
    finally {
        $OutputEncoding = $previousOutputEncoding
        [Console]::InputEncoding = $previousConsoleInputEncoding
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
    }
}

function Get-ClaudeModels {
    <#
    .SYNOPSIS
    Lists available Claude models.
    
    .DESCRIPTION
    Returns a list of available Claude models that can be used with the CLI.
    
    .EXAMPLE
    Get-ClaudeModels
    #>
    [CmdletBinding()]
    param()
    
    [PSCustomObject]@{
        Name = "opus"
        Description = "Most capable model"
        Alias = "opus"
    }
    [PSCustomObject]@{
        Name = "sonnet"
        Description = "Balanced performance"
        Alias = "sonnet"
    }
    [PSCustomObject]@{
        Name = "haiku"
        Description = "Lightweight and fast"
        Alias = "haiku"
    }
}

function New-ClaudeSession {
    <#
    .SYNOPSIS
    Creates a new Claude session ID for conversation continuity.
    
    .DESCRIPTION
    Generates a unique session ID that can be used across multiple Claude invocations
    to maintain conversation context.
    
    .EXAMPLE
    $session = New-ClaudeSession
    Invoke-ClaudeStream -Prompt "Hello" -SessionId $session
    Invoke-ClaudeStream -Prompt "What did I just say?" -SessionId $session
    #>
    [CmdletBinding()]
    param()
    
    [Guid]::NewGuid().ToString()
}

function Get-LastRateLimitInfo {
    <#
    .SYNOPSIS
    Gets the last rate limit message detected during Claude streaming.
    
    .DESCRIPTION
    Returns the raw rate limit message if one was detected during the last
    Invoke-ClaudeStream call, or $null if no rate limit was hit.
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "Hello"
    $rateLimitMsg = Get-LastRateLimitInfo
    if ($rateLimitMsg) {
        Write-BotLog -Level Warn -Message "Rate limited: $rateLimitMsg"
    }
    #>
    [CmdletBinding()]
    param()
    
    return $script:LastRateLimitInfo
}

#endregion

#region Aliases

Set-Alias -Name ics -Value Invoke-ClaudeStream
Set-Alias -Name ic -Value Invoke-Claude
Set-Alias -Name gclm -Value Get-ClaudeModels
Set-Alias -Name ncs -Value New-ClaudeSession

#endregion

Export-ModuleMember -Function @(
    'Invoke-ClaudeStream'
    'Invoke-Claude'
    'Get-ClaudeModels'
    'New-ClaudeSession'
    'Get-LastRateLimitInfo'
    'Write-ActivityLog'
) -Alias @('ics', 'ic', 'gclm', 'ncs')
