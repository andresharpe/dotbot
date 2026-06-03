<#
.SYNOPSIS
Antigravity (Google) harness adapter.

.DESCRIPTION
Wraps the Antigravity CLI. Current agy print mode emits plain text; older or
future builds may emit Claude-shaped JSON events, so the adapter accepts both.

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
            [Console]::Error.WriteLine("$($t.Bezel)[PLAIN] $Line$($t.Reset)")
            [Console]::Error.Flush()
        }
        if ($Line) {
            [Console]::WriteLine($Line)
            Write-ActivityLog -Type "text" -Message (Get-PreviewText $Line 200)
            [Console]::Out.Flush()
        }
        return 'text'
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
                $name = Get-HarnessToolName -Event $tu -Default 'tool'
                $detail = Get-HarnessToolDetail -InputObject $tu.input -BasePath $State.basePath
                if (-not $detail) { $detail = Get-HarnessToolDetail -InputObject $tu -BasePath $State.basePath }
                Write-HarnessLog $name $detail ">"
                Write-ActivityLog -Type $name -Message $detail
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

function Flush-AntigravityAssistantText {
    param([Parameter(Mandatory)][hashtable]$State)

    if ($State.assistantText.Length -le 0) { return }

    $text = $State.assistantText.ToString().TrimEnd()
    if ($text) {
        [Console]::WriteLine("")
        [Console]::WriteLine($text)
        Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
        [Console]::Out.Flush()
    }
    $State.assistantText.Length = 0
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
        [string]$WorkingDirectory,
        [scriptblock]$ShouldStopStream,
        [int]$StopCheckIntervalSeconds = 2,
        [int]$StopGraceSeconds = 10,
        [string]$StopReason = "provider stream stop requested"
    )

    $t = Update-HarnessTheme

    $Model = Resolve-HarnessModelId -ModelAlias $Model -Config $Config

    $cliArgs = Build-HarnessCliArgs -Config $Config -Prompt $Prompt -ModelId $Model `
        -SessionId $SessionId -PersistSession ([bool]$PersistSession) -Streaming $true `
        -PermissionMode $PermissionMode -WorkingDirectory $WorkingDirectory
    if (-not $Config.prompt_flag) {
        $cliArgs += $Prompt
    }

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
        basePath          = $WorkingDirectory
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
        $handleOutput = {
            param([string]$raw)
            if (-not $raw) { return }
            $line = $raw.TrimStart()
            if ($line.Length -eq 0) { return }

            [void](Invoke-AntigravityLineHandler -Line $line -State $state -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose)
        }
        $streamResult = Invoke-HarnessProcessStream `
            -Executable $executable `
            -CliArgs $cliArgs `
            -WorkingDirectory $WorkingDirectory `
            -HandleOutput $handleOutput `
            -HandleErrorOutput $handleOutput `
            -ShouldStopStream $ShouldStopStream `
            -StopCheckIntervalSeconds $StopCheckIntervalSeconds `
            -StopGraceSeconds $StopGraceSeconds `
            -StopReason $StopReason `
            -ShowDebugJson:$ShowDebugJson `
            -Theme $t
        Flush-AntigravityAssistantText -State $state
        if ($streamResult.ExitCode -ne 0 -and -not $streamResult.StopRequested) {
            $nativeExitCode = $streamResult.ExitCode
            throw "Antigravity CLI exited with code $nativeExitCode"
        }
    } finally {
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
        -Streaming $false -PermissionMode $PermissionMode -WorkingDirectory $WorkingDirectory
    if (-not $Config.prompt_flag) {
        $cliArgs += $Prompt
    }

    $executable = $Config.executable
    if (-not (Get-Command $executable -ErrorAction SilentlyContinue)) {
        throw "Antigravity CLI '$executable' not found on PATH. Install Antigravity CLI from https://antigravity.google/docs/cli and retry."
    }

    Invoke-WithUtf8Console -Script {
        Invoke-WithHarnessProcessContext -WorkingDirectory $WorkingDirectory -Script {
            if ($Config.prompt_flag) {
                & $executable @cliArgs
            } else {
                & $executable @cliArgs
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Antigravity CLI exited with code $LASTEXITCODE"
            }
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
            display_name = 'Fast'
            description  = 'Fast and efficient for straightforward work.'
        }
        balanced = @{
            display_name = 'Balanced'
            description  = 'The default middle tier for routine work.'
        }
        best     = @{
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
