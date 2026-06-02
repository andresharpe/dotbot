<#
.SYNOPSIS
Codex (OpenAI) harness adapter.

.DESCRIPTION
Wraps the `codex exec` CLI with JSONL stream parsing.

Codex emits events like:
    thread.started, turn.started, message.delta, message.completed,
    function_call, function_call_output, turn.completed, turn.failed, error

Stream invocation uses a PowerShell pipeline (`& $exe @args | ForEach-Object`)
rather than the System.Diagnostics.Process descendant-tracking machinery used
by the Claude adapter — Codex sessions are short-lived and do not background
auxiliary processes, so the simpler pipeline suffices.

Sessions and persistence are not supported by the Codex CLI; NewSession returns
$null and RemoveSession is a no-op.
#>

function Invoke-CodexLineHandler {
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

    switch ($evt.type) {
        'thread.started' {
            $threadId = $evt.thread_id
            Write-HarnessLog "init" "Codex thread: $threadId" "*"
            Write-ActivityLog -Type "init" -Message "Codex thread started: $threadId"
            return 'init'
        }

        'turn.started' {
            Write-HarnessLog "turn" "started" ">"
            return 'turn_started'
        }

        'message.delta' {
            if ($evt.delta) {
                [void]$State.assistantText.Append($evt.delta)
            }
            return 'text'
        }

        'message.completed' {
            if ($evt.content -and $State.assistantText.Length -eq 0) {
                [void]$State.assistantText.Append($evt.content)
            }

            if ($State.assistantText.Length -gt 0) {
                $text = $State.assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::WriteLine($text)
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }

            if ($evt.usage) {
                if ($evt.usage.input_tokens) { $State.totalInputTokens += $evt.usage.input_tokens }
                if ($evt.usage.output_tokens) { $State.totalOutputTokens += $evt.usage.output_tokens }
            }
            return 'message_completed'
        }

        'function_call' {
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
            Write-HarnessLog $name $detail ">"
            Write-ActivityLog -Type $name -Message $detail
            return 'tool_use'
        }

        'function_call_output' {
            $icon = if ($evt.is_error) { "x" } else { "+" }
            $msg = ""
            if ($evt.duration_ms -and $evt.duration_ms -gt 100) {
                $msg = "$($evt.duration_ms)ms"
            }
            if ($msg) { Write-HarnessLog "done" $msg $icon }
            return 'tool_result'
        }

        'item.completed' {
            $item = $evt.item
            if (-not $item) { return 'unknown' }

            switch ($item.type) {
                'agent_message' {
                    if ($item.text) {
                        [Console]::WriteLine("")
                        [Console]::WriteLine($item.text)
                        Write-ActivityLog -Type "text" -Message (Get-PreviewText $item.text 200)
                        [Console]::Out.Flush()
                    }
                    return 'message_completed'
                }

                'function_call' {
                    $name = if ($item.name) { $item.name } else { "tool" }
                    $detail = ""
                    if ($item.arguments) {
                        try {
                            $args_ = $item.arguments | ConvertFrom-Json -ErrorAction SilentlyContinue
                            if ($args_.command) { $detail = Get-PreviewText $args_.command 140 }
                            elseif ($args_.file_path) { $detail = $args_.file_path }
                            elseif ($args_.path) { $detail = $args_.path }
                        } catch {
                            $detail = Get-PreviewText $item.arguments 140
                        }
                    }
                    Write-HarnessLog $name $detail ">"
                    Write-ActivityLog -Type $name -Message $detail
                    return 'tool_use'
                }

                'function_call_output' {
                    $icon = if ($item.is_error) { "x" } else { "+" }
                    Write-HarnessLog "done" "" $icon
                    return 'tool_result'
                }
            }

            return 'unknown'
        }

        'turn.completed' {
            if ($State.assistantText.Length -gt 0) {
                $text = $State.assistantText.ToString()
                [Console]::WriteLine("")
                [Console]::WriteLine($text)
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
                [Console]::Out.Flush()
                $State.assistantText.Length = 0
            }

            if ($evt.usage) {
                $inp = if ($evt.usage.input_tokens) { $evt.usage.input_tokens } else { 0 }
                $out = if ($evt.usage.output_tokens) { $evt.usage.output_tokens } else { 0 }
                Write-HarnessLog "done" "tokens: in=$inp out=$out" "+"
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

function ConvertTo-CodexTomlString {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Add-CodexWorktreeArgs {
    param(
        [Parameter(Mandatory)][string[]]$CliArgs,
        [string]$WorkingDirectory
    )

    if (-not $WorkingDirectory -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        return $CliArgs
    }

    $frameworkRoot = Get-DotbotInstallPath
    $mcpScript = Join-Path $frameworkRoot 'src/mcp/dotbot-mcp.ps1'
    $worktreeArgs = @(
        '-C', $WorkingDirectory,
        '-c', ('mcp_servers.dotbot.command={0}' -f (ConvertTo-CodexTomlString 'pwsh')),
        '-c', ('mcp_servers.dotbot.args=[{0},{1},{2},{3},{4}]' -f @(
            (ConvertTo-CodexTomlString '-NoProfile'),
            (ConvertTo-CodexTomlString '-ExecutionPolicy'),
            (ConvertTo-CodexTomlString 'Bypass'),
            (ConvertTo-CodexTomlString '-File'),
            (ConvertTo-CodexTomlString $mcpScript)
        )),
        '-c', ('mcp_servers.dotbot.env={{DOTBOT_HOME={0}, DOTBOT_PROJECT_ROOT={1}}}' -f `
            (ConvertTo-CodexTomlString $frameworkRoot), `
            (ConvertTo-CodexTomlString $WorkingDirectory))
    )

    if ($CliArgs.Count -gt 0 -and $CliArgs[0] -eq 'exec') {
        return @($CliArgs[0]) + $worktreeArgs + @($CliArgs | Select-Object -Skip 1)
    }
    return $worktreeArgs + $CliArgs
}

function Invoke-CodexAdapterStream {
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

    $t = Update-HarnessTheme

    $Model = Resolve-HarnessModelId -ModelAlias $Model -Config $Config

    $cliArgs = Build-HarnessCliArgs -Config $Config -Prompt $Prompt -ModelId $Model `
        -SessionId $SessionId -PersistSession ([bool]$PersistSession) -Streaming $true `
        -PermissionMode $PermissionMode
    $cliArgs = Add-CodexWorktreeArgs -CliArgs $cliArgs -WorkingDirectory $WorkingDirectory

    $executable = $Config.executable

    $state = @{
        assistantText    = [System.Text.StringBuilder]::new()
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
    $pushedLocation = $false

    try {
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            Push-Location $WorkingDirectory
            $pushedLocation = $true
        }
        $handleOutput = {
            $raw = $_.ToString()
            if (-not $raw) { return }
            $line = $raw.TrimStart()
            if ($line.Length -eq 0) { return }

            [void](Invoke-CodexLineHandler -Line $line -State $state -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose)
        }
        if ($Config.prompt_flag) {
            & $executable @cliArgs 2>&1 | ForEach-Object -Process $handleOutput
        } else {
            $Prompt | & $executable @cliArgs 2>&1 | ForEach-Object -Process $handleOutput
        }
        $nativeExitCode = $LASTEXITCODE
        if ($nativeExitCode -ne 0) {
            throw "Codex CLI exited with code $nativeExitCode."
        }
    } finally {
        if ($pushedLocation) { Pop-Location }
        [Console]::OutputEncoding = $prevOutputEncoding
    }
}

function Invoke-CodexAdapter {
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
    $cliArgs = Add-CodexWorktreeArgs -CliArgs $cliArgs -WorkingDirectory $WorkingDirectory

    $executable = $Config.executable

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
            $nativeExitCode = $LASTEXITCODE
            if ($nativeExitCode -ne 0) {
                throw "Codex CLI exited with code $nativeExitCode."
            }
        } finally {
            if ($pushedLocation) { Pop-Location }
        }
    }
}

function New-CodexAdapterSession {
    param($Config)
    # Codex does not support resumable sessions.
    return $null
}

function Remove-CodexAdapterSession {
    param(
        $Config,
        [string]$SessionId,
        [string]$ProjectRoot
    )
    # No local session artifacts to clean.
    return $false
}

Register-HarnessAdapter -Name 'Codex' -Spec @{
    Models           = @{
        fast     = @{
            display_name = 'Fast'
            description  = 'Fast and efficient for straightforward work.'
        }
        balanced = @{
            display_name = 'Balanced'
            description  = 'A balance of capability and speed for everyday work.'
        }
        best     = @{
            display_name = 'Best'
            description  = 'Highest capability for complex coding tasks.'
            badge        = 'Recommended'
        }
    }
    DefaultModel     = 'best'
    Stream           = { Invoke-CodexAdapterStream @args }
    Invoke           = { Invoke-CodexAdapter @args }
    NewSession       = { New-CodexAdapterSession @args }
    RemoveSession    = { Remove-CodexAdapterSession @args }
}
