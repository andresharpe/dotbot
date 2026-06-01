<#
.SYNOPSIS
OpenCode (SST) harness adapter.

.DESCRIPTION
Wraps the `opencode run` CLI with JSONL stream parsing.

OpenCode (github.com/sst/opencode) is a multi-provider terminal AI agent that
fronts 75+ models from Models.dev. Models are addressed with `provider/model`
syntax (e.g. `anthropic/claude-sonnet-4-6`).

Stream invocation uses `opencode run --file <prompt-file> "<message>" --format json`
and emits one JSON event per line. Five event types are emitted:

    step_start    — beginning of a processing step
    text          — accumulated assistant text for a part (not deltas)
    tool_use      — completed tool invocation (input + output)
    step_finish   — token usage, cost, snapshot hash, end reason
    error         — error message

OpenCode requires a positional message and does not expose stdin prompt input.
The adapter writes the full prompt to a temporary file and attaches it with
`--file`, keeping the native command line short enough for Windows.

OpenCode creates a session when `run` is invoked without `--session`. The
current CLI treats `--session` as resume-only, so this adapter does not
pre-create provider session ids. NewSession returns $null and RemoveSession is
a no-op. Explicit `-SessionId` values are still forwarded for callers that
already have a real OpenCode session ID.
#>

function Invoke-OpenCodeLineHandler {
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
        if ($State.ContainsKey('nonJsonLines') -and $State.nonJsonLines.Count -lt 5) {
            [void]$State.nonJsonLines.Add((Get-PreviewText $Line 300))
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

    if ($evt.sessionID -and -not $State.sessionLogged) {
        Write-HarnessLog "init" "OpenCode session: $($evt.sessionID)" "*"
        Write-ActivityLog -Type "init" -Message "OpenCode session: $($evt.sessionID)"
        $State.sessionLogged = $true
    }

    switch ($evt.type) {
        'step_start' {
            return 'step_start'
        }

        'text' {
            $text = $evt.part?.text
            if ($text) {
                [Console]::WriteLine("")
                [Console]::WriteLine($text)
                Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
                [Console]::Out.Flush()
            }
            return 'text'
        }

        'tool_use' {
            $name = $evt.part?.tool
            if (-not $name) { $name = "tool" }

            $detail = ""
            $input = $evt.part?.state?.input
            if ($input) {
                if ($input.command)          { $detail = Get-PreviewText $input.command 140 }
                elseif ($input.file_path)    { $detail = $input.file_path }
                elseif ($input.filePath)     { $detail = $input.filePath }
                elseif ($input.path)         { $detail = $input.path }
                elseif ($input.description)  { $detail = Get-PreviewText $input.description 140 }
                elseif ($input.query)        { $detail = Get-PreviewText $input.query 140 }
                else {
                    try {
                        $json = $input | ConvertTo-Json -Compress -Depth 20 -WarningAction SilentlyContinue
                        $detail = Get-PreviewText $json 140
                    } catch { $detail = "" }
                }
            }

            Write-HarnessLog $name $detail ">"
            Write-ActivityLog -Type $name -Message $detail

            $status = $evt.part?.state?.status
            if ($status -and $status -ne 'completed') {
                $icon = if ($status -eq 'error') { "x" } else { "+" }
                Write-HarnessLog "done" $status $icon
            } else {
                Write-HarnessLog "done" "" "+"
            }
            return 'tool_use'
        }

        'step_finish' {
            $tokens = $evt.part?.tokens
            if ($tokens) {
                if ($tokens.input)  { $State.totalInputTokens  += $tokens.input }
                if ($tokens.output) { $State.totalOutputTokens += $tokens.output }
                if ($tokens.cache?.read)  { $State.totalCacheRead   += $tokens.cache.read }
                if ($tokens.cache?.write) { $State.totalCacheCreate += $tokens.cache.write }
            }
            if ($evt.part?.cost) {
                $State.totalCost += [double]$evt.part.cost
            }

            $reason = $evt.part?.reason
            if ($reason -eq 'stop') {
                $endTimeMs = if ($evt.timestamp) { [long]$evt.timestamp } else { [long]([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) }
                $durationMs = $endTimeMs - $State.startTimeMs

                $summary = [PSCustomObject]@{
                    subtype        = 'success'
                    duration_ms    = $durationMs
                    num_turns      = $State.stepCount
                    total_cost_usd = $State.totalCost
                    usage          = [PSCustomObject]@{
                        input_tokens             = $State.totalInputTokens
                        output_tokens            = $State.totalOutputTokens
                        cache_read_input_tokens  = $State.totalCacheRead
                    }
                }
                Format-ResultSummary $summary
                return 'result'
            }

            $State.stepCount++
            return 'step_finish'
        }

        'error' {
            $errorMsg = "Unknown error"
            if ($evt.error?.data?.message) { $errorMsg = $evt.error.data.message }
            elseif ($evt.error?.message)   { $errorMsg = $evt.error.message }
            elseif ($evt.message)          { $errorMsg = $evt.message }

            [Console]::Error.WriteLine("")
            [Console]::Error.WriteLine("$($t.Amber)Error: $errorMsg$($t.Reset)")
            [Console]::Error.Flush()
            Write-ActivityLog -Type "error" -Message $errorMsg
            $State.hadError = $true
            if ($State.errorMessages) {
                [void]$State.errorMessages.Add($errorMsg)
            }
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

function New-OpenCodePromptFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $fileName = "dotbot-opencode-prompt-$([Guid]::NewGuid().ToString('N')).md"
    $path = Join-Path ([System.IO.Path]::GetTempPath()) $fileName
    [System.IO.File]::WriteAllText($path, $Prompt, [System.Text.Encoding]::UTF8)
    return $path
}

function Add-OpenCodePromptArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$CliArgs,

        [Parameter(Mandatory)]
        [string]$PromptFile
    )

    return @($CliArgs) + @(
        'Read the attached prompt file and follow its instructions exactly.',
        '--file', $PromptFile
    )
}

function Invoke-OpenCodeAdapterStream {
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
        -PermissionMode $PermissionMode -WorkingDirectory $WorkingDirectory

    $executable = $Config.executable
    $promptFile = New-OpenCodePromptFile -Prompt $Prompt
    $cliArgs = Add-OpenCodePromptArgs -CliArgs $cliArgs -PromptFile $promptFile

    $state = @{
        assistantText     = [System.Text.StringBuilder]::new()
        totalInputTokens  = 0
        totalOutputTokens = 0
        totalCacheRead    = 0
        totalCacheCreate  = 0
        totalCost         = 0.0
        stepCount         = 0
        sessionLogged     = $false
        startTimeMs       = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        lastUnknown       = Get-Date
        theme             = $t
        hadError          = $false
        errorMessages     = [System.Collections.Generic.List[string]]::new()
        nonJsonLines      = [System.Collections.Generic.List[string]]::new()
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
    $exitCode = 0

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

            [void](Invoke-OpenCodeLineHandler -Line $line -State $state -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose)
        }
        & $executable @cliArgs 2>&1 | ForEach-Object -Process $handleOutput
        $exitCode = $LASTEXITCODE
    } finally {
        if ($pushedLocation) { Pop-Location }
        if ($promptFile -and (Test-Path -LiteralPath $promptFile)) {
            Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        }
        [Console]::OutputEncoding = $prevOutputEncoding
    }

    if ($exitCode -ne 0 -or $state.hadError) {
        $details = @($state.errorMessages | Where-Object { $_ })
        if ($details.Count -eq 0) {
            $details = @($state.nonJsonLines | Where-Object { $_ })
        }
        $message = if ($details.Count -gt 0) { $details -join '; ' } else { "OpenCode exited with code $exitCode" }
        throw $message
    }
}

function Invoke-OpenCodeAdapter {
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

    $executable = $Config.executable
    $promptFile = New-OpenCodePromptFile -Prompt $Prompt
    $cliArgs = Add-OpenCodePromptArgs -CliArgs $cliArgs -PromptFile $promptFile

    try {
        Invoke-WithUtf8Console -Script {
            $pushedLocation = $false
            try {
                if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
                    Push-Location $WorkingDirectory
                    $pushedLocation = $true
                }
                & $executable @cliArgs
                $exitCode = $LASTEXITCODE
                if ($exitCode -ne 0) {
                    throw "OpenCode exited with code $exitCode"
                }
            } finally {
                if ($pushedLocation) { Pop-Location }
            }
        }
    } finally {
        if ($promptFile -and (Test-Path -LiteralPath $promptFile)) {
            Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-OpenCodeAdapterSession {
    param($Config)
    # OpenCode's --session resumes an existing session; it does not create a new
    # one. Let `opencode run` allocate the session instead.
    return $null
}

function Remove-OpenCodeAdapterSession {
    param(
        $Config,
        [string]$SessionId,
        [string]$ProjectRoot
    )
    # OpenCode manages session storage under ~/.local/share/opencode and does
    # not expose a stable cleanup CLI. Leave artifacts in place.
    return $false
}

Register-HarnessAdapter -Name 'OpenCode' -Spec @{
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
            description  = 'Highest capability for complex reasoning.'
            badge        = 'Recommended'
        }
    }
    DefaultModel     = 'best'
    Stream           = { Invoke-OpenCodeAdapterStream @args }
    Invoke           = { Invoke-OpenCodeAdapter @args }
    NewSession       = { New-OpenCodeAdapterSession @args }
    RemoveSession    = { Remove-OpenCodeAdapterSession @args }
}
