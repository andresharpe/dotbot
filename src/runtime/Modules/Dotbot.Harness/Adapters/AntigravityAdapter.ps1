<#
.SYNOPSIS
Antigravity (Google) harness adapter.

.DESCRIPTION
Wraps the Antigravity CLI with stream-json parsing. The parser assumes a
Claude-shaped event schema (message.delta.text, message.content[] blocks,
type='result'); revisit if the upstream wire format diverges.

Antigravity does not currently support resumable sessions; NewSession returns
$null and RemoveSession is a no-op.
#>

function Invoke-AntigravityLineHandler {
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

    # --- Claude-like event handling (Antigravity stream-json shares this format) ---

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
        Write-HarnessLog "init" "Antigravity: $($evt.model)" "*"
        Write-ActivityLog -Type "init" -Message "Antigravity model: $($evt.model)"
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

function Invoke-AntigravityAdapterStream {
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

    if (Update-DotbotTheme) { $script:theme = Get-DotbotTheme }
    $t = $script:theme

    $Model = Resolve-HarnessModelId -ModelAlias $Model -Config $Config

    $cliArgs = Build-HarnessCliArgs -Config $Config -Prompt $Prompt -ModelId $Model `
        -SessionId $SessionId -PersistSession ([bool]$PersistSession) -Streaming $true `
        -PermissionMode $PermissionMode

    $executable = $Config.executable
    if (-not (Get-Command $executable -ErrorAction SilentlyContinue)) {
        throw "Antigravity CLI '$executable' not found on PATH. Install Antigravity CLI from https://antigravity.google/docs/cli and retry."
    }

    $state = @{
        assistantText     = [System.Text.StringBuilder]::new()
        totalInputTokens  = 0
        totalOutputTokens = 0
        totalCacheRead    = 0
        totalCacheCreate  = 0
        pendingToolCalls  = @()
        lastUnknown       = Get-Date
        theme             = $t
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
    $pushedLocation = $false

    # Honor WorkingDirectory so per-task worktree isolation actually applies
    # (Edit/Write/Bash inside antigravity resolve relative paths against cwd).
    try {
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushedLocation = $true
        }
        $handleOutput = {
            $raw = $_.ToString()
            if (-not $raw) { return }
            $line = $raw.TrimStart()
            if ($line.Length -eq 0) { return }

            [void](Invoke-AntigravityLineHandler -Line $line -State $state -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose)
        }
        if ($Config.prompt_flag) {
            & $executable @cliArgs 2>&1 | ForEach-Object -Process $handleOutput
        } else {
            $Prompt | & $executable @cliArgs 2>&1 | ForEach-Object -Process $handleOutput
        }
    } finally {
        if ($pushedLocation) { Pop-Location }
        [Console]::OutputEncoding = $prevOutputEncoding
    }
}

function Invoke-AntigravityAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        $Config,

        [string]$Model,
        [string]$PermissionMode,
        [string]$WorkingDirectory
    )

    $Model = Resolve-HarnessModelId -ModelAlias $Model -Config $Config

    $cliArgs = Build-HarnessCliArgs -Config $Config -Prompt $Prompt -ModelId $Model `
        -Streaming $false -PermissionMode $PermissionMode

    $executable = $Config.executable
    if (-not (Get-Command $executable -ErrorAction SilentlyContinue)) {
        throw "Antigravity CLI '$executable' not found on PATH. Install Antigravity CLI from https://antigravity.google/docs/cli and retry."
    }

    Invoke-WithUtf8Console -Script {
        $pushedLocation = $false
        try {
            if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
                Push-Location $WorkingDirectory
                $pushedLocation = $true
            }
            if ($Config.prompt_flag) {
                & $executable @cliArgs
            } else {
                $Prompt | & $executable @cliArgs
            }
        } finally {
            if ($pushedLocation) { Pop-Location }
        }
    }
}

function New-AntigravityAdapterSession {
    param($Config)
    # Antigravity does not yet support resumable sessions.
    return $null
}

function Remove-AntigravityAdapterSession {
    param(
        $Config,
        [string]$SessionId,
        [string]$ProjectRoot
    )
    # No local session artifacts to clean.
    return $false
}

Register-HarnessAdapter -Name 'Antigravity' -Spec @{
    Models           = @{
        fast     = @{
            id           = 'gemini-3.5-flash'
            display_name = 'Fast'
            description  = 'Fast and efficient for straightforward work.'
        }
        balanced = @{
            id           = 'gemini-3.5-flash'
            display_name = 'Balanced'
            description  = 'The default middle tier for routine work.'
        }
        best     = @{
            id           = 'gemini-3.5-flash'
            display_name = 'Best'
            description  = 'Highest capability for complex reasoning.'
            badge        = 'Recommended'
        }
    }
    DefaultModel     = 'best'
    Stream           = { Invoke-AntigravityAdapterStream @args }
    Invoke           = { Invoke-AntigravityAdapter @args }
    NewSession       = { New-AntigravityAdapterSession @args }
    RemoveSession    = { Remove-AntigravityAdapterSession @args }
}
