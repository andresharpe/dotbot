<#
.SYNOPSIS
Codex (OpenAI) stream parser for ProviderCLI.

.DESCRIPTION
Processes Codex CLI --json JSONL output. Codex emits events like:
  thread.started, turn.started, message.delta, message.completed,
  turn.completed, turn.failed, error

Provides Process-StreamLine function for the ProviderCLI dispatcher.
#>

# Import helpers
if (-not (Get-Command Write-ActivityLog -ErrorAction SilentlyContinue)) {
    Import-Module "$PSScriptRoot\..\..\ClaudeCLI\ClaudeCLI.psm1" -Force
}

function Process-StreamLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Line,

        [Parameter(Mandatory)]
        [hashtable]$State,

        [switch]$ShowDebugJson,
        [switch]$ShowVerbose
    )

    $t = $State.theme

    # Skip non-JSON lines (stderr noise like rmcp errors)
    if (-not $Line -or $Line[0] -ne '{') {
        if ($ShowDebugJson) {
            [Console]::Error.WriteLine("$($t.Bezel)[SKIP] $Line$($t.Reset)")
            [Console]::Error.Flush()
        }
        return 'skip'
    }

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[JSON] $Line$($t.Reset)")
        [Console]::Error.Flush()
    }

    $evt = $null
    try { $evt = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return 'skip' }
    if (-not $evt) { return 'skip' }

    switch ($evt.type) {
        'thread.started' {
            $threadId = $evt.thread_id
            Write-ClaudeLog "init" "Codex thread: $threadId" "*"
            Write-ActivityLog -Type "init" -Message "Codex thread started: $threadId"
            return 'init'
        }

        'turn.started' {
            Write-ClaudeLog "turn" "started" ">"
            return 'turn_started'
        }

        'message.delta' {
            # Streaming text delta
            if ($evt.delta) {
                [void]$State.assistantText.Append($evt.delta)
            }
            return 'text'
        }

        'message.completed' {
            # If content field present (full message without prior deltas), capture it
            if ($evt.content -and $State.assistantText.Length -eq 0) {
                [void]$State.assistantText.Append($evt.content)
            }

            # Full message completed — flush accumulated text
            if ($State.assistantText.Length -gt 0) {
                $text = $State.assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::WriteLine($text)
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }

            # Track usage if present
            if ($evt.usage) {
                if ($evt.usage.input_tokens) { $State.totalInputTokens += $evt.usage.input_tokens }
                if ($evt.usage.output_tokens) { $State.totalOutputTokens += $evt.usage.output_tokens }
            }
            return 'message_completed'
        }

        'function_call' {
            # Tool/function call
            $name = $evt.name
            $detail = ""
            if ($evt.arguments) {
                try {
                    $args_ = $evt.arguments | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($args_.command) { $detail = Get-PreviewText $args_.command 140 }
                    elseif ($args_.file_path) { $detail = $args_.file_path }
                } catch {
                    $detail = Get-PreviewText $evt.arguments 140
                }
            }
            Write-ClaudeLog $name $detail ">"
            Write-ActivityLog -Type $name -Message $detail
            return 'tool_use'
        }

        'function_call_output' {
            # Tool result
            $icon = if ($evt.is_error) { "x" } else { "+" }
            $msg = ""
            if ($evt.duration_ms -and $evt.duration_ms -gt 100) {
                $msg = "$($evt.duration_ms)ms"
            }
            if ($msg) { Write-ClaudeLog "done" $msg $icon }
            return 'tool_result'
        }

        'turn.completed' {
            # Flush any remaining text
            if ($State.assistantText.Length -gt 0) {
                $text = $State.assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::WriteLine($text)
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }

            # Show summary
            if ($evt.usage) {
                $inp = if ($evt.usage.input_tokens) { $evt.usage.input_tokens } else { 0 }
                $out = if ($evt.usage.output_tokens) { $evt.usage.output_tokens } else { 0 }
                Write-ClaudeLog "done" "tokens: in=$inp out=$out" "+"
            }
            return 'result'
        }

        'turn.failed' {
            $errorMsg = if ($evt.error?.message) { $evt.error.message } else { "Turn failed" }
            [Console]::Error.WriteLine("")
            [Console]::Error.WriteLine("$($t.Amber)Error: $errorMsg$($t.Reset)")
            [Console]::Error.Flush()
            Write-ActivityLog -Type "error" -Message $errorMsg
            return 'error'
        }

        'error' {
            $errorMsg = if ($evt.message) { $evt.message } else { "Unknown error" }

            # Check for rate limit
            if ($errorMsg -match "rate.?limit|too many requests|429") {
                $State.rateLimitMessage = $errorMsg
                [Console]::Error.WriteLine("$($t.Amber)Rate limit: $errorMsg$($t.Reset)")
                [Console]::Error.Flush()
                Write-ActivityLog -Type "rate_limit" -Message $errorMsg
                return 'rate_limit'
            }

            [Console]::Error.WriteLine("")
            [Console]::Error.WriteLine("$($t.Amber)Error: $errorMsg$($t.Reset)")
            [Console]::Error.Flush()
            Write-ActivityLog -Type "error" -Message $errorMsg
            return 'error'
        }

        default {
            if ($ShowDebugJson) {
                [Console]::Error.WriteLine("$($t.Bezel)[UNKNOWN] type=$($evt.type)$($t.Reset)")
                [Console]::Error.Flush()
            }
            return 'unknown'
        }
    }
}
