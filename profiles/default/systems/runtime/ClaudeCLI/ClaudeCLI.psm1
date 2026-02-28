using namespace System.Management.Automation

# Import DotBotTheme for consistent colors
Import-Module "$PSScriptRoot\..\modules\DotBotTheme.psm1" -Force
$script:theme = Get-DotBotTheme

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

    # Ensure .control directory exists (.bot/.control - ClaudeCLI is at .bot/systems/runtime/ClaudeCLI)
    $controlDir = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) ".control"
    if (-not (Test-Path $controlDir)) {
        New-Item -Path $controlDir -ItemType Directory -Force | Out-Null
    }

    # Determine phase: parameter > environment variable > null (for backward compatibility)
    $effectivePhase = if ($Phase) { $Phase } elseif ($env:DOTBOT_CURRENT_PHASE) { $env:DOTBOT_CURRENT_PHASE } else { $null }

    $event = @{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        type = $Type
        message = $Message
        task_id = $env:DOTBOT_CURRENT_TASK_ID  # Always include, null when no task
        phase = $effectivePhase  # Include phase for filtering (null for backward compat)
    } | ConvertTo-Json -Compress

    # Write to global activity.jsonl (always, for oscilloscope / backward compat)
    $logPath = Join-Path $controlDir "activity.jsonl"
    $maxRetries = 3
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $fs = [System.IO.FileStream]::new(
                $logPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
            $sw.WriteLine($event)
            $sw.Close()
            $fs.Close()
            break
        } catch {
            if ($r -lt ($maxRetries - 1)) {
                Start-Sleep -Milliseconds (50 * ($r + 1))
            }
            # Final retry failure is silently ignored (non-critical logging)
        }
    }

    # Also write to per-process activity log when DOTBOT_PROCESS_ID is set
    $procId = $env:DOTBOT_PROCESS_ID
    if ($procId) {
        $processLogPath = Join-Path $controlDir "processes\$procId.activity.jsonl"
        for ($r = 0; $r -lt $maxRetries; $r++) {
            try {
                $fs = [System.IO.FileStream]::new(
                    $processLogPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite
                )
                $sw = [System.IO.StreamWriter]::new($fs, [System.Text.Encoding]::UTF8)
                $sw.WriteLine($event)
                $sw.Close()
                $fs.Close()
                break
            } catch {
                if ($r -lt ($maxRetries - 1)) {
                    Start-Sleep -Milliseconds (50 * ($r + 1))
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
    Claude model to use (default: claude-opus-4-6).
    
    .PARAMETER SessionId
    Optional session ID for conversation continuity.
    
    .PARAMETER ShowDebugJson
    Show raw JSON events in dark gray.
    
    .PARAMETER ShowVerbose
    Show detailed tool results and metadata.
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "What files are in the current directory?"
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "Analyze the code" -Model "claude-sonnet-4-20250514"
    
    .EXAMPLE
    Invoke-ClaudeStream -Prompt "Debug this" -ShowDebugJson -ShowVerbose
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model = "claude-opus-4-6",

        [int]$FlushChars = 200,

        [int]$UnknownEverySeconds = 2,

        [int]$PreviewChars = 140,

        [string]$SessionId,

        [switch]$PersistSession,

        [switch]$ShowDebugJson,

        [switch]$ShowVerbose
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
    $lastUnknown = Get-Date
    $unknownEvery = [TimeSpan]::FromSeconds($UnknownEverySeconds)
    $assistantText = New-Object System.Text.StringBuilder
    $pendingToolCalls = @()
    
    # Token usage tracking
    $totalInputTokens = 0
    $totalOutputTokens = 0
    $totalCacheRead = 0
    $totalCacheCreate = 0

    $cliArgs = @(
        "--model", $Model
        "--dangerously-skip-permissions"
    )

    # Only add --no-session-persistence when NOT persisting sessions
    if (-not $PersistSession) {
        $cliArgs += "--no-session-persistence"
    }

    $cliArgs += @(
        "--output-format", "stream-json"
        "--print"
        "--verbose"
        "--"
        $Prompt
    )

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
    & claude.exe @cliArgs 2>&1 | ForEach-Object -Process {
        $lineCount++
        if ($ShowDebugJson -and $lineCount -le 3) {
            [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Received line $lineCount$($t.Reset)")
            [Console]::Error.Flush()
        }
        try {
            $raw = $_.ToString()
            if (-not $raw) { return }

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
                if (($now - $lastUnknown) -ge $unknownEvery) {
                    Write-ClaudeUnknown (Get-PreviewText $line 1200)
                    $lastUnknown = $now
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
            if ($usage.input_tokens) { $totalInputTokens += $usage.input_tokens }
            if ($usage.output_tokens) { $totalOutputTokens += $usage.output_tokens }
            if ($usage.cache_read_input_tokens) { $totalCacheRead += $usage.cache_read_input_tokens }
            if ($usage.cache_creation_input_tokens) { $totalCacheCreate += $usage.cache_creation_input_tokens }
        }

        if ($text) {
            [void]$assistantText.Append($text)
            return
        }

        # --- 2) Init/config event ---
        if ($evt.type -and $evt.subtype -and $evt.model -and $evt.cwd) {
            $m = $evt.model
            Write-ClaudeLog "init" "$m" "*"
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
                    if ($totalInputTokens -gt 0 -or $totalOutputTokens -gt 0) {
                        $tokenInfo = "tokens: ${totalInputTokens}in"
                        if ($totalCacheRead -gt 0) {
                            $tokenInfo += " (${totalCacheRead} cached)"
                        }
                        $tokenInfo += " / ${totalOutputTokens} out"
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
                    if ($totalInputTokens -gt 0 -or $totalOutputTokens -gt 0) {
                        $tokenInfo = "tokens: ${totalInputTokens}in"
                        if ($totalCacheRead -gt 0) {
                            $tokenInfo += " (${totalCacheRead} cached)"
                        }
                        $tokenInfo += " / ${totalOutputTokens} out"
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

        # --- 5) Result summary ---
        if ($evt.type -eq "result") {
            # Render any remaining assistant text
            if ($assistantText.Length -gt 0) {
                # Show token usage FIRST in dark gray if we have any
                if ($totalInputTokens -gt 0 -or $totalOutputTokens -gt 0) {
                    $tokenInfo = "tokens: ${totalInputTokens}in"
                    if ($totalCacheRead -gt 0) {
                        $tokenInfo += " (${totalCacheRead} cached)"
                    }
                    $tokenInfo += " / ${totalOutputTokens} out"
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
            return
        }

            # --- 6) Unknown fallback (throttled) ---
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("")
                [Console]::Error.WriteLine("$($t.Bezel)[JSON] $line$($t.Reset)")
                [Console]::Error.Flush()
            } else {
                $now = Get-Date
                if (($now - $lastUnknown) -ge $unknownEvery) {
                    Write-ClaudeUnknown (Get-PreviewText $line 2000)
                    $lastUnknown = $now
                }
            }
        } catch {
            # Silently catch and continue on any processing errors
            # to prevent the entire stream from crashing
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Amber)[DEBUG] Error processing event: $($_.Exception.Message)$($t.Reset)")
                [Console]::Error.Flush()
            }
            Write-Debug "Error processing stream event: $($_.Exception.Message)"
        }
    }

    # Debug: show stream completed
    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Stream completed. Total lines received: $lineCount$($t.Reset)")
        [Console]::Error.Flush()
    }
    } finally {
        # Restore original output encoding
        [Console]::OutputEncoding = $prevOutputEncoding
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
    Claude model to use (default: claude-opus-4-6).
    
    .PARAMETER SessionId
    Optional session ID for conversation continuity.
    
    .PARAMETER NoPermissions
    Skip permission checks (default: enabled).
    
    .EXAMPLE
    Invoke-Claude -Prompt "What is 2+2?"
    
    .EXAMPLE
    "Explain this code" | Invoke-Claude -Model "claude-sonnet-4-20250514"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [string]$Prompt,

        [Parameter(Position = 1)]
        [string]$Model = "claude-opus-4-6",
        
        [string]$SessionId,
        
        [switch]$NoPermissions
    )

    $cliArgs = @(
        "--model", $Model
        "-p", $Prompt
    )
    
    if ($NoPermissions) {
        $cliArgs += "--dangerously-skip-permissions"
    }
    
    if ($SessionId) {
        $cliArgs += "--session-id", $SessionId
    }

    & claude.exe @cliArgs
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
        Name = "claude-opus-4-6"
        Description = "Most capable model"
        Alias = "opus"
    }
    [PSCustomObject]@{
        Name = "claude-sonnet-4-20250514"
        Description = "Balanced performance"
        Alias = "sonnet"
    }
    [PSCustomObject]@{
        Name = "claude-3-5-sonnet-20241022"
        Description = "Previous Sonnet version"
        Alias = "sonnet-3.5"
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
        Write-Host "Rate limited: $rateLimitMsg"
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
