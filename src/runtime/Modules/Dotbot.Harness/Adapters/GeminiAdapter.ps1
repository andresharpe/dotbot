<#
.SYNOPSIS
Gemini (Google) harness adapter.

.DESCRIPTION
Wraps the Gemini CLI with stream-json parsing. Gemini's CLI is built on the
same MCP SDK foundation as Claude's, so its stream events largely mirror
Claude's format with a few variations. This adapter handles both shapes.

Like Codex, Gemini does not yet support resumable sessions; NewSession returns
$null and RemoveSession is a no-op.
#>

function Invoke-GeminiLineHandler {
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

    # --- Claude-like event handling (Gemini stream-json shares this format) ---

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

    if ($evt.message?.usage -or $evt.usage) {
        $usage = if ($evt.message?.usage) { $evt.message.usage } else { $evt.usage }
        if ($usage.input_tokens) { $State.totalInputTokens += $usage.input_tokens }
        if ($usage.output_tokens) { $State.totalOutputTokens += $usage.output_tokens }
    }

    if ($text) {
        [void]$State.assistantText.Append($text)
        return 'text'
    }

    if ($evt.type -and $evt.model -and $evt.cwd) {
        Write-HarnessLog "init" "Gemini: $($evt.model)" "*"
        Write-ActivityLog -Type "init" -Message "Gemini model: $($evt.model)"
        return 'init'
    }

    if ($evt.type -eq "assistant" -and $evt.message?.content -is [System.Array]) {
        $toolUses = @($evt.message.content | Where-Object { $_.type -eq "tool_use" })
        if ($toolUses.Count -gt 0) {
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
                Write-HarnessLog $tu.name $detail ">"
                Write-ActivityLog -Type $tu.name -Message $detail
            }
            return 'tool_use'
        }
    }

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
                Write-HarnessLog "done" "" $icon
            }
            return 'tool_result'
        }
    }

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

    if ($evt.type -eq "error" -or $evt.error) {
        $errorMsg = if ($evt.message) { $evt.message } elseif ($evt.error?.message) { $evt.error.message } else { "Unknown error" }

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

function Invoke-GeminiAdapterStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        $Config,

        [string]$Model,
        [string]$SessionId,
        [switch]$PersistSession,
        [switch]$ShowDebugJson,
        [switch]$ShowVerbose,
        [string]$PermissionMode,
        [string]$WorkingDirectory
    )

    if (Update-DotbotTheme) {
        $script:theme = Get-DotbotTheme
    }
    $t = Get-DotbotTheme

    if (-not $Model) {
        $Model = $Config.models.($Config.default_model).id
    }

    $cliArgs = Build-HarnessCliArgs -Config $Config -Prompt $Prompt -ModelId $Model `
        -SessionId $SessionId -PersistSession ([bool]$PersistSession) -Streaming $true `
        -PermissionMode $PermissionMode

    $executable = $Config.executable

    $state = @{
        assistantText    = New-Object System.Text.StringBuilder
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheRead   = 0
        totalCacheCreate = 0
        pendingToolCalls = @()
        lastUnknown      = Get-Date
        theme            = $t
    }

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("$($t.Bezel)--- HARNESS: $($Config.display_name) ---$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)Executable: $executable$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)Args: $($cliArgs -join ' ')$($t.Reset)")
        [Console]::Error.Flush()
    }

    $prevOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    try {
        $Prompt | & $executable @cliArgs 2>&1 | ForEach-Object -Process {
            $raw = $_.ToString()
            if (-not $raw) { return }
            $line = $raw.TrimStart()
            if ($line.Length -eq 0) { return }

            [void](Invoke-GeminiLineHandler -Line $line -State $state -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose)
        }
    } finally {
        [Console]::OutputEncoding = $prevOutputEncoding
    }
}

function Invoke-GeminiAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        $Config,

        [string]$Model,
        [string]$PermissionMode
    )

    if (-not $Model) {
        $Model = $Config.models.($Config.default_model).id
    }

    $cliArgs = Build-HarnessCliArgs -Config $Config -Prompt $Prompt -ModelId $Model `
        -Streaming $false -PermissionMode $PermissionMode

    $executable = $Config.executable
    $previousOutputEncoding = $OutputEncoding
    $previousConsoleInputEncoding = [Console]::InputEncoding
    $previousConsoleOutputEncoding = [Console]::OutputEncoding
    $utf8Encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        $OutputEncoding = $utf8Encoding
        [Console]::InputEncoding = $utf8Encoding
        [Console]::OutputEncoding = $utf8Encoding

        $Prompt | & $executable @cliArgs
    }
    finally {
        $OutputEncoding = $previousOutputEncoding
        [Console]::InputEncoding = $previousConsoleInputEncoding
        [Console]::OutputEncoding = $previousConsoleOutputEncoding
    }
}

function New-GeminiAdapterSession {
    param($Config)
    return $null
}

function Remove-GeminiAdapterSession {
    param(
        $Config,
        [string]$SessionId,
        [string]$ProjectRoot
    )
    return $false
}

Register-HarnessAdapter -Name 'Gemini' -Spec @{
    Stream           = { Invoke-GeminiAdapterStream @args }
    Invoke           = { Invoke-GeminiAdapter @args }
    NewSession       = { New-GeminiAdapterSession @args }
    RemoveSession    = { Remove-GeminiAdapterSession @args }
}
