<#
.SYNOPSIS
Gemini (Google) stream parser for ProviderCLI.

.DESCRIPTION
Processes Gemini CLI --output-format stream-json output. Gemini CLI is built on
the same MCP SDK foundation as Claude CLI, so the stream format may share structure
with Claude's stream-json events. This parser handles both the Claude-like format
and Gemini-specific variations.

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

    # Skip non-JSON lines (Gemini emits plain text for YOLO mode banner, errors, etc.)
    if (-not $Line -or $Line[0] -ne '{') {
        # Check for rate limit in plain text
        if ($Line -match "rate.?limit|quota|429|too many requests") {
            $State.rateLimitMessage = $Line
            [Console]::Error.WriteLine("$($t.Amber)Rate limit: $Line$($t.Reset)")
            [Console]::Error.Flush()
            Write-ActivityLog -Type "rate_limit" -Message $Line
            return 'rate_limit'
        }
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

    # --- Claude-like event handling (Gemini stream-json may share this format) ---

    # Assistant text streaming
    $text = $null
    if ($evt.message?.delta?.text) {
        $text = $evt.message.delta.text
    }
    elseif ($evt.message?.content -is [System.Array]) {
        foreach ($b in $evt.message.content) {
            if ($b.type -eq "text" -and $b.text) { $text += $b.text }
            elseif ($b.delta?.text) { $text += $b.delta.text }
        }
    }
    elseif ($evt.message?.content -is [string]) {
        $text = $evt.message.content
    }

    # Track token usage
    if ($evt.message?.usage -or $evt.usage) {
        $usage = if ($evt.message?.usage) { $evt.message.usage } else { $evt.usage }
        if ($usage.input_tokens) { $State.totalInputTokens += $usage.input_tokens }
        if ($usage.output_tokens) { $State.totalOutputTokens += $usage.output_tokens }
    }

    if ($text) {
        [void]$State.assistantText.Append($text)
        return 'text'
    }

    # Init/config event (Claude-like)
    if ($evt.type -and $evt.model -and $evt.cwd) {
        Write-ClaudeLog "init" "Gemini: $($evt.model)" "*"
        Write-ActivityLog -Type "init" -Message "Gemini model: $($evt.model)"
        return 'init'
    }

    # Tool use (Claude-like)
    if ($evt.type -eq "assistant" -and $evt.message?.content -is [System.Array]) {
        $toolUses = @($evt.message.content | Where-Object { $_.type -eq "tool_use" })
        if ($toolUses.Count -gt 0) {
            # Flush assistant text
            if ($State.assistantText.Length -gt 0) {
                [Console]::WriteLine("")
                [Console]::WriteLine($State.assistantText.ToString())
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $State.assistantText.ToString() 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }
            foreach ($tu in $toolUses) {
                $detail = ""
                if ($tu.input) {
                    if ($tu.input.command) { $detail = Get-PreviewText $tu.input.command 140 }
                    elseif ($tu.input.file_path) { $detail = $tu.input.file_path }
                    elseif ($tu.input.description) { $detail = Get-PreviewText $tu.input.description 140 }
                }
                if (-not $detail) { $detail = "" }
                Write-ClaudeLog $tu.name $detail ">"
                Write-ActivityLog -Type $tu.name -Message $detail
            }
            return 'tool_use'
        }
    }

    # Tool result (Claude-like)
    if ($evt.type -eq "user" -and $evt.message?.content -is [System.Array]) {
        $toolResults = @($evt.message.content | Where-Object { $_.type -eq "tool_result" })
        if ($toolResults.Count -gt 0) {
            if ($State.assistantText.Length -gt 0) {
                [Console]::WriteLine("")
                [Console]::WriteLine($State.assistantText.ToString())
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $State.assistantText.ToString() 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }
            foreach ($tr in $toolResults) {
                $isErr = [bool]$tr.is_error
                $icon = if ($isErr) { "x" } else { "+" }
                Write-ClaudeLog "done" "" $icon
            }
            return 'tool_result'
        }
    }

    # Result summary (Claude-like)
    if ($evt.type -eq "result") {
        if ($State.assistantText.Length -gt 0) {
            [Console]::WriteLine("")
            [Console]::WriteLine($State.assistantText.ToString())
            Write-ActivityLog -Type "text" -Message (Get-PreviewText $State.assistantText.ToString() 200)
            [Console]::Out.Flush()
            $State.assistantText.Length = 0
        }
        Format-ResultSummary $evt
        return 'result'
    }

    # Error event
    if ($evt.type -eq "error" -or $evt.error) {
        $errorMsg = if ($evt.message) { $evt.message } elseif ($evt.error?.message) { $evt.error.message } else { "Unknown error" }

        if ($errorMsg -match "rate.?limit|quota|429") {
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

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[UNKNOWN] type=$($evt.type)$($t.Reset)")
        [Console]::Error.Flush()
    }
    return 'unknown'
}
