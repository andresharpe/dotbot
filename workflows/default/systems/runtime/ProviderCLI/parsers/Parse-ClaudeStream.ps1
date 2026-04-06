<#
.SYNOPSIS
Claude stream parser for ProviderCLI.

.DESCRIPTION
Processes Claude CLI stream-json output lines. This parser is used as a fallback;
the primary Claude path delegates to Invoke-ClaudeStream in ClaudeCLI.psm1 directly.
Provides Process-StreamLine function for the ProviderCLI dispatcher.
#>

# Import helpers from ClaudeCLI if not already available
if (-not (Get-Command Write-ClaudeLog -ErrorAction SilentlyContinue)) {
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

    # Check for rate limit
    if ($Line -match "hit your limit|error.*rate_limit") {
        try {
            $jsonObj = $Line | ConvertFrom-Json -ErrorAction Stop
            if ($jsonObj.error -eq "rate_limit" -or ($jsonObj.result -and $jsonObj.result -match "resets?")) {
                $State.rateLimitMessage = if ($jsonObj.result) { $jsonObj.result } else { "Rate limit hit" }
                [Console]::Error.WriteLine("$($t.Amber)Rate limit: $($State.rateLimitMessage)$($t.Reset)")
                [Console]::Error.Flush()
                Write-ActivityLog -Type "rate_limit" -Message $State.rateLimitMessage
                return 'rate_limit'
            }
        } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
    }

    # Skip non-JSON
    if ($Line[0] -ne '{') { return 'skip' }

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[JSON] $Line$($t.Reset)")
        [Console]::Error.Flush()
    }

    $evt = $null
    try { $evt = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return 'skip' }
    if (-not $evt) { return 'skip' }

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
    if ($evt.message?.usage) {
        $usage = $evt.message.usage
        if ($usage.input_tokens) { $State.totalInputTokens += $usage.input_tokens }
        if ($usage.output_tokens) { $State.totalOutputTokens += $usage.output_tokens }
        if ($usage.cache_read_input_tokens) { $State.totalCacheRead += $usage.cache_read_input_tokens }
        if ($usage.cache_creation_input_tokens) { $State.totalCacheCreate += $usage.cache_creation_input_tokens }
    }

    if ($text) {
        [void]$State.assistantText.Append($text)
        return 'text'
    }

    # Init event
    if ($evt.type -and $evt.subtype -and $evt.model -and $evt.cwd) {
        Write-ClaudeLog "init" "$($evt.model)" "*"
        return 'init'
    }

    # Tool use
    if ($evt.type -eq "assistant" -and $evt.message?.content -is [System.Array]) {
        $toolUses = @($evt.message.content | Where-Object { $_.type -eq "tool_use" })
        if ($toolUses.Count -gt 0) {
            # Flush assistant text
            if ($State.assistantText.Length -gt 0) {
                $rendered = ConvertTo-RenderedMarkdown $State.assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::Write($rendered)
                $textPreview = (Get-PreviewText $State.assistantText.ToString() 200)
                Write-ActivityLog -Type "text" -Message $textPreview
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }
            foreach ($tu in $toolUses) {
                if ($tu.name -eq "TodoWrite") { continue }
                $detail = ""
                if ($tu.input) {
                    if ($tu.input.command) { $detail = Get-PreviewText $tu.input.command 140 }
                    elseif ($tu.input.pattern) { $detail = "pattern=`"$($tu.input.pattern)`"" }
                    elseif ($tu.input.file_path) { $detail = $tu.input.file_path -replace '\\\\', '\\' -replace [regex]::Escape($PWD.Path + '\'), '' }
                    elseif ($tu.input.description) { $detail = Get-PreviewText $tu.input.description 140 }
                    elseif ($tu.input.prompt) { $detail = Get-PreviewText $tu.input.prompt 140 }
                }
                if (-not $detail) { $detail = "" }
                Write-ClaudeLog $tu.name $detail ">"
            }
            return 'tool_use'
        }
    }

    # Tool result
    if ($evt.type -eq "user" -and $evt.message?.content -is [System.Array]) {
        $toolResults = @($evt.message.content | Where-Object { $_.type -eq "tool_result" })
        if ($toolResults.Count -gt 0) {
            if ($State.assistantText.Length -gt 0) {
                $rendered = ConvertTo-RenderedMarkdown $State.assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::Write($rendered)
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $State.assistantText.ToString() 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }
            foreach ($tr in $toolResults) {
                $isErr = [bool]$tr.is_error
                $icon = if ($isErr) { "x" } else { "+" }
                $meta = @()
                if ($evt.tool_use_result) {
                    if ($evt.tool_use_result.durationMs -ne $null -and $evt.tool_use_result.durationMs -gt 100) {
                        $meta += "$($evt.tool_use_result.durationMs)ms"
                    }
                    if ($evt.tool_use_result.numFiles -ne $null) {
                        $meta += "$($evt.tool_use_result.numFiles) files"
                    }
                }
                $msg = if ($meta.Count -gt 0) { $meta -join ", " } else { "" }
                if ($msg) { Write-ClaudeLog "done" $msg $icon }
            }
            return 'tool_result'
        }
    }

    # Result summary
    if ($evt.type -eq "result") {
        if ($State.assistantText.Length -gt 0) {
            $rendered = ConvertTo-RenderedMarkdown $State.assistantText.ToString()
            [Console]::WriteLine("")
            [Console]::Write($rendered)
            Write-ActivityLog -Type "text" -Message (Get-PreviewText $State.assistantText.ToString() 200)
            [Console]::Out.Flush()
            $State.assistantText.Length = 0
        }
        Format-ResultSummary $evt
        return 'result'
    }

    return 'unknown'
}
