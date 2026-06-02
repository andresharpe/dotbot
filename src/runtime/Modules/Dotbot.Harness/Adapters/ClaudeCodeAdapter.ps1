<#
.SYNOPSIS
Claude Code harness adapter.

.DESCRIPTION
Wraps the Claude CLI (claude / claude.exe) with the streaming engine that has
been battle-tested through the project's task pipeline:

  - JSON stream-format parsing (stream-json events)
  - Inline rendered-markdown rendering on stdout
  - Activity-log writes for every tool call, tool result, and agent event
  - Token-usage tracking with periodic JSONL milestones and a context-window
    warning when usage crosses 80%
  - Stderr drain background task to prevent buffer deadlock when child
    processes inherit Claude's pipes
  - Descendant-PID snapshot monitor (Windows) and pkill (Unix) to kill grand-
    children spawned via the Bash tool (e.g. backgrounded dev servers and
    `dotnet test` → testhost.exe)

Public surface — registered with the harness registry at the bottom of this
file:

  Stream           = Invoke-ClaudeCodeAdapterStream
  Invoke           = Invoke-ClaudeCodeAdapter
  NewSession       = New-ClaudeCodeAdapterSession
  RemoveSession    = Remove-ClaudeCodeAdapterSession

The functions below are dot-sourced into Dotbot.Harness module scope and are
not exported externally.
#>

function Invoke-ClaudeCodeAdapterStream {
    <#
    .SYNOPSIS
    Streaming Claude CLI invocation with stream-json parsing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        $Config,

        [string]$Model,
        [int]$FlushChars = 200,
        [int]$UnknownEverySeconds = 2,
        [int]$PreviewChars = 140,
        [string]$SessionId,
        [switch]$PersistSession,
        [switch]$ShowDebugJson,
        [switch]$ShowVerbose,
        [string]$PermissionMode,
        [string[]]$PermissionArgs,
        [string]$WorkingDirectory
    )

    $t = Update-HarnessTheme

    $Model = Resolve-HarnessModelId -ModelAlias $Model -Config $Config

    if (-not $PermissionArgs) {
        $PermissionArgs = Resolve-PermissionArgs -Config $Config -PermissionMode $PermissionMode
    }

    $chars = 0
    $unknownEvery = [TimeSpan]::FromSeconds($UnknownEverySeconds)
    $assistantText = [System.Text.StringBuilder]::new()
    $pendingToolCalls = @()

    # Mutable state shared with the $processLine scriptblock via hashtable reference.
    $state = @{
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheRead = 0
        totalCacheCreate = 0
        lastTurnInput = 0
        lastTurnCacheRead = 0
        lastUnknown = Get-Date
        turnCount = 0
        lastUsageLogAt = 0
        lastToolResultTime = $null
        pendingToolNames = @{}
    }

    $cliArgs = @(
        "--model", $Model
    ) + $PermissionArgs

    if (-not $PersistSession) {
        $cliArgs += "--no-session-persistence"
    }

    $cliArgs += @(
        "--output-format", "stream-json"
        "--print"
        "--verbose"
    )

    $mcpConfigRoot = if ($WorkingDirectory) { $WorkingDirectory } elseif ($global:DotbotProjectRoot) { $global:DotbotProjectRoot } else { $null }
    if ($mcpConfigRoot) {
        $mcpConfigPath = Join-Path $mcpConfigRoot '.mcp.json'
        if (Test-Path -LiteralPath $mcpConfigPath -PathType Leaf) {
            $cliArgs += @("--mcp-config", $mcpConfigPath)
        }
    }
    # Prompt is delivered via stdin after process start to avoid Windows command-line length limits (#167)

    if ($SessionId) {
        $cliArgs = @("--session-id", $SessionId) + $cliArgs
    }

    $prevOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
            $displayArg = if ($arg.Length -gt 100) { $arg.Substring(0, 100) + "..." } else { $arg }
            $displayArg = $displayArg.Replace("`r`n", "↵").Replace("`n", "↵")
            [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)   $($t.Amber)$displayArg$($t.Reset)")
        }
        [Console]::Error.WriteLine("$($t.Bezel)│$($t.Reset)")

        $promptPreview = if ($Prompt.Length -gt 500) { $Prompt.Substring(0, 500) + "..." } else { $Prompt }
        $promptLines = [System.Collections.Generic.List[string]]::new()
        $promptReader = [System.IO.StringReader]::new($promptPreview)
        while ($true) {
            $promptLine = $promptReader.ReadLine()
            if ($null -eq $promptLine) { break }
            $promptLines.Add($promptLine)
        }
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

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] About to invoke claude.exe...$($t.Reset)")
        [Console]::Error.Flush()
    }

    try {
        $lineCount = 0

        # --- Process-aware invocation (Orphaned Background Process Pipeline Deadlock fix) ---
        # System.Diagnostics.Process tracking instead of a simple pipeline:
        # 1. Track the main claude.exe PID
        # 2. Read stdout line-by-line
        # 3. Detect claude.exe exit and drain remaining output with a timeout
        # 4. Kill the entire process tree to release orphan children
        $claudeCmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $claudeCmd) {
            $claudeCmd = Get-Command claude.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        }
        $claudeExePath = $claudeCmd.Source

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $claudeExePath
        foreach ($arg in $cliArgs) { $psi.ArgumentList.Add($arg) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        # Claude's cwd controls where Edit/Write/Bash resolve relative paths.
        # - Default: $global:DotbotProjectRoot, so MCP discovery picks up .mcp.json.
        # - Task execution: Invoke-WorkflowProcess passes the worktree path so agent
        #   edits land on the task branch, not on main. Worktree preparation writes
        #   the provider/MCP config there so MCP discovery still works.
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            $psi.WorkingDirectory = $WorkingDirectory
        } elseif ($global:DotbotProjectRoot -and (Test-Path -LiteralPath $global:DotbotProjectRoot -PathType Container)) {
            $psi.WorkingDirectory = $global:DotbotProjectRoot
        }
        $psi.Environment["__DOTBOT_MANAGED"] = "1"
        $frameworkRootForMcp = Get-DotbotInstallPath
        $mcpProjectRoot = if ($WorkingDirectory) { $WorkingDirectory } elseif ($psi.WorkingDirectory) { $psi.WorkingDirectory } else { $global:DotbotProjectRoot }
        if ($frameworkRootForMcp) { $psi.Environment["DOTBOT_HOME"] = $frameworkRootForMcp }
        if ($mcpProjectRoot) { $psi.Environment["DOTBOT_PROJECT_ROOT"] = $mcpProjectRoot }

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

        # --- Descendant PID snapshot monitor (Windows only) ---
        # Win32_Process is WMI and Windows-only. On Linux/macOS, claude.exe's children
        # are re-parented to init (PID 1) on exit and can be reached via pgrep/pkill
        # at teardown if needed.
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
                        [void]$treeMonitorCts.Token.WaitHandle.WaitOne(2000)
                    }
                } catch { }
            })
        }

        # Drain stderr line-by-line in a background task to prevent buffer deadlock.
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
                }
            } catch { }
        })

        $processLine = {
            param([string]$raw)

            if (-not $raw) { return }
            try {
                $line = $raw.TrimStart()
                if ($line.Length -eq 0) { return }

                if ($line[0] -ne '{') {
                    if ($ShowDebugJson -and $lineCount -le 5) {
                        $preview = if ($line.Length -gt 80) { $line.Substring(0, 80) + "..." } else { $line }
                        [Console]::Error.WriteLine("$($t.Bezel)[SKIP] Not JSON: $preview$($t.Reset)")
                        [Console]::Error.Flush()
                    }
                    return
                }

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
                            Write-HarnessUnknown (Get-PreviewText $line 1200)
                            $state.lastUnknown = $now
                        }
                    }
                    return
                }

                if ($ShowDebugJson) {
                    $evtType = if ($evt.type) { $evt.type } else { "unknown" }
                    $evtSubtype = if ($evt.subtype) { "/$($evt.subtype)" } else { "" }
                    [Console]::Error.WriteLine("$($t.Bezel)[EVT] $evtType$evtSubtype$($t.Reset)")
                    [Console]::Error.Flush()
                }

                if ($evt.type -eq "error" -or $evt.error) {
                    $errorMsg = $null
                    if ($evt.message -is [string]) {
                        $errorMsg = $evt.message
                    }
                    elseif ($evt.message?.content -is [System.Array]) {
                        $parts = @()
                        foreach ($c in $evt.message.content) {
                            if ($c.type -eq "text" -and $c.text) {
                                $parts += $c.text
                            }
                        }
                        if ($parts.Count -gt 0) {
                            $errorMsg = $parts -join [Environment]::NewLine
                        }
                    }
                    elseif ($evt.error?.message) {
                        $errorMsg = $evt.error.message
                    }
                    elseif ($evt.error) {
                        $errorMsg = "$($evt.error)"
                    }
                    if (-not $errorMsg) { $errorMsg = "Unknown error" }

                    [Console]::Error.WriteLine("")
                    [Console]::Error.WriteLine("$($t.Amber)Error: $errorMsg$($t.Reset)")
                    [Console]::Error.Flush()
                    Write-ActivityLog -Type "error" -Message $errorMsg
                    return
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

                if ($evt.message?.usage) {
                    $usage = $evt.message.usage
                    if ($usage.input_tokens) { $state.totalInputTokens += $usage.input_tokens }
                    if ($usage.output_tokens) { $state.totalOutputTokens += $usage.output_tokens }
                    if ($usage.cache_read_input_tokens) { $state.totalCacheRead += $usage.cache_read_input_tokens }
                    if ($usage.cache_creation_input_tokens) { $state.totalCacheCreate += $usage.cache_creation_input_tokens }

                    $state.lastTurnInput = if ($usage.input_tokens) { $usage.input_tokens } else { 0 }
                    $state.lastTurnCacheRead = if ($usage.cache_read_input_tokens) { $usage.cache_read_input_tokens } else { 0 }

                    $state.turnCount++

                    $ctxTokens = $state.lastTurnInput + $state.lastTurnCacheRead
                    $pctRaw = $ctxTokens / 200000 * 100
                    $pct = [math]::Round($pctRaw, 1)
                    $currentThreshold = [math]::Floor($pctRaw / 25)
                    if ($currentThreshold -gt $state.lastUsageLogAt) {
                        $state.lastUsageLogAt = $currentThreshold
                        $usageMsg = "turn=$($state.turnCount) in=$($state.totalInputTokens) out=$($state.totalOutputTokens) cache=$($state.totalCacheRead) ctx=${pct}%"
                        Write-ActivityLog -Type "usage" -Message $usageMsg
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
                    Write-HarnessLog "init" "$m" "*"
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
                        if ($assistantText.Length -gt 0) {
                            if ($state.totalInputTokens -gt 0 -or $state.totalOutputTokens -gt 0) {
                                $tokenInfo = "tokens: $($state.totalInputTokens)in"
                                if ($state.totalCacheRead -gt 0) {
                                    $tokenInfo += " ($($state.totalCacheRead) cached)"
                                }
                                $tokenInfo += " / $($state.totalOutputTokens) out"
                                [Console]::WriteLine("")
                                [Console]::WriteLine("$($t.Bezel)[$tokenInfo]$($t.Reset)")
                            }

                            $rendered = ConvertTo-RenderedMarkdown $assistantText.ToString()
                            [Console]::WriteLine("")
                            [Console]::Write($rendered)

                            $textPreview = (Get-PreviewText $assistantText.ToString() 200)
                            Write-ActivityLog -Type "text" -Message $textPreview

                            [Console]::Out.Flush()
                            $assistantText.Length = 0
                        }

                        foreach ($tu in $toolUses) {
                            $name = $tu.name
                            $id   = $tu.id
                            $inp  = $tu.input

                            if ($id) { $state.pendingToolNames[$id] = $name }

                            if ($name -eq "TodoWrite") {
                                continue
                            }

                            $detail = ""
                            if ($inp) {
                                if ($inp.command) {
                                    $detail = (Get-PreviewText $inp.command $PreviewChars)
                                }
                                elseif ($inp.file_path) {
                                    $cleanPath = "$($inp.file_path)".Replace('\\', '\')
                                    $cwdPrefix = $PWD.Path
                                    if (-not $cwdPrefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
                                        $cwdPrefix += [System.IO.Path]::DirectorySeparatorChar
                                    }
                                    if ($cleanPath.StartsWith($cwdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                                        $cleanPath = $cleanPath.Substring($cwdPrefix.Length)
                                    }
                                    $detail = $cleanPath
                                }
                                elseif ($inp.description) {
                                    $detail = (Get-PreviewText $inp.description $PreviewChars)
                                }
                                elseif ($inp.prompt) {
                                    $detail = (Get-PreviewText $inp.prompt $PreviewChars)
                                }
                            }

                            if (-not $detail) { $detail = "" }
                            Write-HarnessLog $name $detail ">"
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
                        if ($assistantText.Length -gt 0) {
                            if ($state.totalInputTokens -gt 0 -or $state.totalOutputTokens -gt 0) {
                                $tokenInfo = "tokens: $($state.totalInputTokens)in"
                                if ($state.totalCacheRead -gt 0) {
                                    $tokenInfo += " ($($state.totalCacheRead) cached)"
                                }
                                $tokenInfo += " / $($state.totalOutputTokens) out"
                                [Console]::WriteLine("")
                                [Console]::WriteLine("$($t.Bezel)[$tokenInfo]$($t.Reset)")
                            }

                            $rendered = ConvertTo-RenderedMarkdown $assistantText.ToString()
                            [Console]::WriteLine("")
                            [Console]::Write($rendered)

                            $textPreview = (Get-PreviewText $assistantText.ToString() 200)
                            Write-ActivityLog -Type "text" -Message $textPreview

                            [Console]::Out.Flush()
                            $assistantText.Length = 0
                        }

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
                                Write-HarnessLog "done" $msg $icon
                            }

                            $toolName = if ($id -and $state.pendingToolNames.ContainsKey($id)) { $state.pendingToolNames[$id] } else { $null }
                            if ($toolName -and $toolName.StartsWith('Agent', [System.StringComparison]::Ordinal)) {
                                $agentStatus = if ($isErr) { "error" } else { "success" }
                                $agentDur = if ($meta.Count -gt 0) { " $($meta -join ', ')" } else { "" }
                                Write-ActivityLog -Type "agent_done" -Message "$toolName [$agentStatus]$agentDur"
                            }

                            if ($isErr -and $tr.content) {
                                $errPreview = if ($tr.content -is [string]) { Get-PreviewText $tr.content 200 } else { "(non-string error)" }
                                $errToolName = if ($toolName) { $toolName } else { "unknown" }
                                Write-ActivityLog -Type "error" -Message "$errToolName`: $errPreview"
                            }

                            if ($id -and $state.pendingToolNames.ContainsKey($id)) { $state.pendingToolNames.Remove($id) }

                            if ($ShowVerbose -and $tr.content) {
                                $content = $tr.content
                                if ($content -is [string]) {
                                    $lines = [System.Collections.Generic.List[string]]::new()
                                    $reader = [System.IO.StringReader]::new($content)
                                    while ($true) {
                                        $contentLine = $reader.ReadLine()
                                        if ($null -eq $contentLine) { break }
                                        $lines.Add($contentLine)
                                    }
                                    $lineCount = $lines.Count

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

                # --- 5) System event handling ---
                $eventType = if ($evt.type) { "$($evt.type)" } else { "" }
                if ($eventType -eq "system" -or $eventType.Contains("compact")) {
                    $subtype = "$($evt.subtype)"

                    if ($subtype -in @('task_started', 'task_progress')) {
                        Write-ActivityLog -Type "agent_progress" -Message "subtype=$subtype turn=$($state.turnCount)"
                        return
                    }
                    if ($subtype -eq 'task_notification') {
                        Write-ActivityLog -Type "agent_done" -Message "turn=$($state.turnCount)"
                        return
                    }

                    $isCompact = $eventType.Contains("compact") -or
                                 ($subtype -eq 'compact_boundary') -or
                                 ($evt.message -and "$($evt.message)".Trim().Length -gt 0)
                    if (-not $isCompact) { return }

                    $compactMsg = if ($evt.message) { Get-PreviewText "$($evt.message)" 200 } else { "context auto-compacted" }
                    $ctxTokens = $state.lastTurnInput + $state.lastTurnCacheRead
                    $pct = [math]::Round($ctxTokens / 200000 * 100, 1)
                    Write-HarnessLog "compact" $compactMsg "⚠"
                    Write-ActivityLog -Type "compact" -Message "turn=$($state.turnCount) ctx=${ctxTokens} (${pct}%) $compactMsg"
                    [Console]::Error.WriteLine("$($t.Amber)⚠ CONTEXT COMPACTED at turn $($state.turnCount) ($ctxTokens tokens, ${pct}%)$($t.Reset)")
                    [Console]::Error.Flush()
                    $state.lastUsageLogAt = 0
                    return
                }

                # --- 5b) Wall-clock gap detection ---
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
                    if ($assistantText.Length -gt 0) {
                        if ($state.totalInputTokens -gt 0 -or $state.totalOutputTokens -gt 0) {
                            $tokenInfo = "tokens: $($state.totalInputTokens)in"
                            if ($state.totalCacheRead -gt 0) {
                                $tokenInfo += " ($($state.totalCacheRead) cached)"
                            }
                            $tokenInfo += " / $($state.totalOutputTokens) out"
                            [Console]::WriteLine("")
                            [Console]::WriteLine("$($t.Bezel)[$tokenInfo]$($t.Reset)")
                        }

                        $rendered = ConvertTo-RenderedMarkdown $assistantText.ToString()
                        [Console]::WriteLine("")
                        [Console]::Write($rendered)

                        $textPreview = (Get-PreviewText $assistantText.ToString() 200)
                        Write-ActivityLog -Type "text" -Message $textPreview

                        [Console]::Out.Flush()
                        [Console]::Out.Flush()
                        $assistantText.Length = 0
                    }

                    Format-ResultSummary $evt

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
                        Write-HarnessUnknown (Get-PreviewText $line 2000)
                        $state.lastUnknown = $now
                    }
                }
            } catch {
                if ($ShowDebugJson) {
                    [Console]::Error.WriteLine("$($t.Amber)[DEBUG] Error processing event: $($_.Exception.Message)$($t.Reset)")
                    [Console]::Error.Flush()
                }
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Error processing stream event" -Exception $_ }
            }
        }

        # --- Main read loop ---
        $mainExited = $false
        $drainDeadline = $null
        $drainGraceSeconds = 10
        $readTimeoutMs = 2000
        $pendingReadTask = $null

        while ($true) {
            if (-not $mainExited -and $claudeProc.HasExited) {
                $mainExited = $true
                $drainDeadline = (Get-Date).AddSeconds($drainGraceSeconds)
                if ($ShowDebugJson) {
                    [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] claude exited (code $($claudeProc.ExitCode)), draining output...$($t.Reset)")
                    [Console]::Error.Flush()
                }
            }

            if ($mainExited -and (Get-Date) -gt $drainDeadline) {
                if ($ShowDebugJson) {
                    [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Drain deadline reached, stopping read loop$($t.Reset)")
                    [Console]::Error.Flush()
                }
                if ($pendingReadTask) {
                    try { $claudeProc.StandardOutput.Close() } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to close stdout stream" -Exception $_ } }
                    $pendingReadTask = $null
                }
                break
            }

            try {
                if (-not $pendingReadTask) {
                    $pendingReadTask = $claudeProc.StandardOutput.ReadLineAsync()
                }

                if ($pendingReadTask.Wait($readTimeoutMs)) {
                    $raw = $pendingReadTask.Result
                    $pendingReadTask = $null
                } else {
                    continue
                }
            } catch {
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
                if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Error processing stream event" -Exception $_ }
            }
        }

        if ($ShowDebugJson) {
            [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Stream completed. Total lines received: $lineCount$($t.Reset)")
            [Console]::Error.Flush()
        }

        # --- Kill orphan child processes in the claude.exe process tree ---
        try {
            if (-not $claudeProc.HasExited) {
                $claudeProc.WaitForExit(5000)
                if (-not $claudeProc.HasExited) {
                    $claudeProc.Kill($true)
                }
            }

            $claudePid = $claudeProc.Id
            if ($IsWindows) {
                $children = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ParentProcessId -eq $claudePid -and $_.ProcessId -ne $PID }
                foreach ($child in $children) {
                    try { Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to stop child process $($child.ProcessId)" -Exception $_ } }
                }
            } else {
                try { & pkill -P $claudePid 2>/dev/null } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: pkill failed for parent PID ${claudePid}" -Exception $_ } }
            }
        } catch {
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Bezel)[DEBUG] Process tree cleanup error: $($_.Exception.Message)$($t.Reset)")
                [Console]::Error.Flush()
            }
        }

    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding

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

        if ($claudeProc -and -not $claudeProc.HasExited) {
            try { $claudeProc.Kill($true) } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to kill process" -Exception $_ } }
        }
        if ($claudeProc) {
            try { $claudeProc.Dispose() } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to dispose process" -Exception $_ } }
        }
    }
}

function Invoke-ClaudeCodeAdapter {
    <#
    .SYNOPSIS
    Simple Claude CLI invocation without streaming parsing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        $Config,

        [string]$Model,
        [string]$SessionId,
        [string]$PermissionMode,
        [string[]]$PermissionArgs
    )

    $Model = Resolve-HarnessModelId -ModelAlias $Model -Config $Config

    if (-not $PermissionArgs) {
        $PermissionArgs = Resolve-PermissionArgs -Config $Config -PermissionMode $PermissionMode
    }

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
    }

    if ($SessionId) {
        $cliArgs += "--session-id", $SessionId
    }

    Invoke-WithUtf8Console -Script {
        $Prompt | & $claudeExePath @cliArgs
    }
}

function New-ClaudeCodeAdapterSession {
    [CmdletBinding()]
    param($Config)
    return [Guid]::NewGuid().ToString()
}

function Get-ClaudeCodeProjectDir {
    <#
    .SYNOPSIS
    Get the Claude projects directory for a given project root.

    .PARAMETER ProjectRoot
    Path to the project root directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    # Claude stores sessions in ~/.claude/projects/{project-hash}/
    # Project hash is derived from project path with drive letter and slashes replaced
    $fullPath = [System.IO.Path]::GetFullPath($ProjectRoot)
    $projectHash = $fullPath.Replace(':', '-').Replace('\', '-').Replace('/', '-')

    $claudeProjectDir = Join-Path $HOME '.claude' 'projects' $projectHash

    if (Test-Path $claudeProjectDir) {
        return $claudeProjectDir
    }

    return $null
}

function Remove-ClaudeCodeAdapterSession {
    <#
    .SYNOPSIS
    Removes a Claude session folder and JSONL file from ~/.claude/projects/.
    #>
    [CmdletBinding()]
    param(
        $Config,
        [string]$SessionId,
        [Parameter(Mandatory)]
        [string]$ProjectRoot
    )

    if (-not $SessionId) { return $false }

    $claudeProjectDir = Get-ClaudeCodeProjectDir -ProjectRoot $ProjectRoot
    if (-not $claudeProjectDir) { return $false }

    $removed = $false

    $sessionFolder = Join-Path $claudeProjectDir $SessionId
    if (Test-Path $sessionFolder) {
        Remove-Item $sessionFolder -Recurse -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    $sessionFile = Join-Path $claudeProjectDir "$SessionId.jsonl"
    if (Test-Path $sessionFile) {
        Remove-Item $sessionFile -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    return $removed
}

Register-HarnessAdapter -Name 'ClaudeCode' -Spec @{
    Models           = @{
        fast     = @{
            display_name = 'Fast'
            description  = 'Quick responses for lightweight work.'
            aliases      = @('Haiku', 'haiku')
        }
        balanced = @{
            display_name = 'Balanced'
            description  = 'A balance of capability and speed for everyday work.'
            aliases      = @('Sonnet', 'sonnet')
        }
        best     = @{
            display_name = 'Best'
            description  = 'Highest capability for complex reasoning.'
            badge        = 'Recommended'
            aliases      = @('Opus', 'opus')
        }
    }
    DefaultModel     = 'best'
    Stream           = { Invoke-ClaudeCodeAdapterStream @args }
    Invoke           = { Invoke-ClaudeCodeAdapter @args }
    NewSession       = { New-ClaudeCodeAdapterSession @args }
    RemoveSession    = { Remove-ClaudeCodeAdapterSession @args }
}
