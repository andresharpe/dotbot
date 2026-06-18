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

function New-AntigravityLogPath {
    [CmdletBinding()]
    param([string]$WorkingDirectory)

    $candidateRoots = @()
    if ($WorkingDirectory) { $candidateRoots += $WorkingDirectory }
    if ($global:DotbotProjectRoot -and $global:DotbotProjectRoot -ne $WorkingDirectory) {
        $candidateRoots += $global:DotbotProjectRoot
    }

    foreach ($root in $candidateRoots) {
        $controlDir = Join-Path $root ".bot/.control"
        if (-not (Test-Path -LiteralPath $controlDir -PathType Container)) { continue }

        $logDir = Join-Path $controlDir "logs"
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            return (Join-Path $logDir ("antigravity-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))))
        } catch {
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Debug -Message "Unable to create Antigravity log under project control directory" -Exception $_
            }
        }
    }

    $fallbackDir = Join-Path ([System.IO.Path]::GetTempPath()) "dotbot-antigravity-logs"
    try {
        New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
        return (Join-Path $fallbackDir ("antigravity-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), ([guid]::NewGuid().ToString("N").Substring(0, 8))))
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Unable to create Antigravity fallback log directory" -Exception $_
        }
    }

    return $null
}

function Add-AntigravityLogFileArg {
    [CmdletBinding()]
    param(
        [object[]]$CliArgs,
        [string]$LogPath,
        $Config
    )

    if (-not $LogPath) { return @($CliArgs) }

    $result = [System.Collections.Generic.List[string]]::new()
    $printFlag = if ($Config.cli_args.print) { [string]$Config.cli_args.print } else { $null }
    $inserted = $false

    foreach ($arg in @($CliArgs)) {
        if (-not $inserted -and $printFlag -and [string]::Equals([string]$arg, $printFlag, [System.StringComparison]::Ordinal)) {
            $result.Add("--log-file")
            $result.Add($LogPath)
            $inserted = $true
        }
        $result.Add([string]$arg)
    }

    if (-not $inserted) {
        $result.Add("--log-file")
        $result.Add($LogPath)
    }

    return @($result)
}

function Write-AntigravityLogActivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Icon = "",
        [string]$Key
    )

    if ($Key) {
        if ($State.logActivitySeen.ContainsKey($Key)) { return }
        $State.logActivitySeen[$Key] = $true
    }

    Write-HarnessLog $Kind $Message $Icon
}

function Get-AntigravityCliHome {
    [CmdletBinding()]
    param()

    if ($env:DOTBOT_ANTIGRAVITY_CLI_HOME) {
        return $env:DOTBOT_ANTIGRAVITY_CLI_HOME
    }

    $profileRoot = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if (-not $profileRoot) { $profileRoot = $HOME }
    if (-not $profileRoot) { return $null }

    return (Join-Path $profileRoot ".gemini/antigravity-cli")
}

function Resolve-AntigravityTranscriptPath {
    [CmdletBinding()]
    param([string]$ConversationId)

    if (-not $ConversationId) { return $null }

    $cliHome = Get-AntigravityCliHome
    if (-not $cliHome) { return $null }

    $logDir = Join-Path $cliHome (Join-Path "brain" (Join-Path $ConversationId ".system_generated/logs"))
    $candidates = @(
        (Join-Path $logDir "transcript.jsonl"),
        (Join-Path $logDir "transcript_full.jsonl")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    return $candidates[0]
}

function ConvertFrom-AntigravityTranscriptValue {
    [CmdletBinding()]
    param($Value)

    if ($Value -isnot [string]) { return $Value }

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed[0] -eq '"' -and $trimmed[$trimmed.Length - 1] -eq '"') {
        try { return ($trimmed | ConvertFrom-Json -ErrorAction Stop) } catch { }
    }

    return $Value
}

function Get-AntigravityToolArg {
    [CmdletBinding()]
    param(
        $Args,
        [Parameter(Mandatory)][string[]]$Names
    )

    $value = Get-HarnessPropertyValue -Object $Args -Names $Names
    if ($null -eq $value) { return $null }
    return ConvertFrom-AntigravityTranscriptValue $value
}

function ConvertTo-AntigravityDetailText {
    [CmdletBinding()]
    param(
        $Value,
        [string]$BasePath
    )

    if ($Value -is [string] -and $BasePath) {
        try {
            $candidate = [System.IO.Path]::GetFullPath($Value).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            $root = [System.IO.Path]::GetFullPath($BasePath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ([string]::Equals($candidate, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
                return "."
            }
        } catch { }
    }

    return (ConvertTo-HarnessDetailString -Value $Value -BasePath $BasePath)
}

function Get-AntigravityToolName {
    [CmdletBinding()]
    param($ToolCall)

    $rawName = Get-HarnessToolName -Event $ToolCall -Default 'tool'
    switch ($rawName) {
        'list_dir' { return 'list' }
        'ListDir' { return 'list' }
        'view_file' { return 'read' }
        'ReadFile' { return 'read' }
        'run_command' { return 'bash' }
        'RunCommand' { return 'bash' }
        default { return $rawName }
    }
}

function Get-AntigravityToolDetail {
    [CmdletBinding()]
    param(
        $ToolCall,
        [string]$BasePath
    )

    $args = Get-HarnessPropertyValue -Object $ToolCall -Names @('args', 'input', 'arguments')
    $action = Get-AntigravityToolArg -Args $args -Names @('toolAction', 'tool_action')
    $summary = Get-AntigravityToolArg -Args $args -Names @('toolSummary', 'tool_summary')

    $target = $null
    foreach ($names in @(
        @('CommandLine', 'command_line', 'command'),
        @('AbsolutePath', 'absolute_path', 'path', 'file_path'),
        @('DirectoryPath', 'directory_path', 'directory'),
        @('Cwd', 'cwd')
    )) {
        $target = Get-AntigravityToolArg -Args $args -Names $names
        if ($target) { break }
    }

    $targetText = if ($target) { ConvertTo-AntigravityDetailText -Value $target -BasePath $BasePath } else { "" }
    $actionText = if ($action) { ConvertTo-AntigravityDetailText -Value $action -BasePath $BasePath } else { "" }
    if ($actionText -and $targetText -and -not [string]::Equals($actionText, $targetText, [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Get-PreviewText "${actionText}: $targetText" 160)
    }
    if ($actionText) { return $actionText }
    if ($targetText) { return $targetText }
    if ($summary) { return (ConvertTo-AntigravityDetailText -Value $summary -BasePath $BasePath) }

    return (Get-HarnessToolDetail -InputObject $args -BasePath $BasePath)
}

function Invoke-AntigravityTranscriptLineHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][hashtable]$State
    )

    $evt = $null
    try { $evt = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return }
    if (-not $evt) { return }

    $stepIndex = Get-HarnessPropertyValue -Object $evt -Names @('step_index', 'stepIndex')
    $toolCalls = Get-HarnessPropertyValue -Object $evt -Names @('tool_calls', 'toolCalls')
    if ($null -eq $stepIndex -or -not $toolCalls) { return }

    $i = 0
    foreach ($toolCall in @($toolCalls)) {
        $key = "tool-$stepIndex-$i"
        $i++
        if ($State.transcriptSeen.ContainsKey($key)) { continue }
        $State.transcriptSeen[$key] = $true

        $name = Get-AntigravityToolName -ToolCall $toolCall
        $detail = Get-AntigravityToolDetail -ToolCall $toolCall -BasePath $State.basePath
        Write-HarnessLog $name $detail ">"
    }
}

function Invoke-AntigravityLogLineHandler {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][hashtable]$State
    )

    $message = $Line
    if ($Line -match '^\S+\s+\S+\s+\S+\s+[^]]+\]\s*(.+)$') {
        $message = $Matches[1]
    }

    if ($message -match '^Print mode: starting') {
        Write-AntigravityLogActivity -State $State -Kind "init" -Message "Antigravity print mode started" -Icon "*" -Key "print-start"
        return
    }

    if ($message -match '^Print mode: not authenticated, trying silent auth') {
        Write-AntigravityLogActivity -State $State -Kind "auth" -Message "Antigravity silent auth started" -Icon "*" -Key "silent-auth-start"
        return
    }

    if ($message -match '^Print mode: silent auth succeeded') {
        Write-AntigravityLogActivity -State $State -Kind "auth" -Message "Antigravity silent auth succeeded" -Icon "+" -Key "silent-auth-ok"
        return
    }

    if ($message -match '^Print mode: conversation=([^,]+), sending message') {
        $State.conversationId = $Matches[1]
        Write-AntigravityLogActivity -State $State -Kind "init" -Message "Antigravity conversation: $($State.conversationId)" -Icon "*" -Key "conversation-$($State.conversationId)"
        return
    }

    if ($message -match 'streamGenerateContent') {
        $State.logStreamRequests++
        Write-AntigravityLogActivity -State $State -Kind "turn" -Message "Antigravity stream request #$($State.logStreamRequests)" -Icon ">" -Key "stream-$($State.logStreamRequests)"
        return
    }

    if ($message -match '^project: failed to add project resource folder') {
        return
    }

    if ($Line -match '^E' -and
        $message -notmatch 'You are not logged into Antigravity' -and
        $message -notmatch 'Failed to resolve GeminiDir' -and
        $message -notmatch 'path is already tracked' -and
        $message -notmatch '^checkpoint model generated tool calls$') {
        Write-AntigravityLogActivity -State $State -Kind "warning" -Message (Get-PreviewText $message 200) -Icon "!" -Key "warning-$message"
    }
}

function Read-AntigravityLogUpdates {
    [CmdletBinding()]
    param(
        [string]$Path,
        [Parameter(Mandatory)][hashtable]$State
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $reader = $null
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $State.logOffset) {
            $State.logOffset = 0L
            $State.logRemainder = ""
        }
        [void]$stream.Seek([int64]$State.logOffset, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        $chunk = $reader.ReadToEnd()
        $State.logOffset = $stream.Position
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Unable to read Antigravity log updates" -Exception $_
        }
        return
    } finally {
        if ($reader) {
            try { $reader.Dispose() } catch { }
        } elseif ($stream) {
            try { $stream.Dispose() } catch { }
        }
    }

    if (-not $chunk) { return }

    $buffer = "$($State.logRemainder)$chunk"
    $parts = [regex]::Split($buffer, "\r?\n")
    if ($buffer -notmatch "\r?\n$") {
        $State.logRemainder = $parts[$parts.Count - 1]
        $lineCount = $parts.Count - 1
    } else {
        $State.logRemainder = ""
        $lineCount = $parts.Count
    }

    for ($i = 0; $i -lt $lineCount; $i++) {
        $line = $parts[$i]
        if (-not $line) { continue }
        Invoke-AntigravityLogLineHandler -Line $line -State $State
    }
}

function Read-AntigravityTranscriptUpdates {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if (-not $State.conversationId) { return }

    if (-not $State.transcriptPath) {
        $State.transcriptPath = Resolve-AntigravityTranscriptPath -ConversationId $State.conversationId
    }
    if (-not $State.transcriptPath -or -not (Test-Path -LiteralPath $State.transcriptPath -PathType Leaf)) { return }

    $reader = $null
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($State.transcriptPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $State.transcriptOffset) {
            $State.transcriptOffset = 0L
            $State.transcriptRemainder = ""
        }
        [void]$stream.Seek([int64]$State.transcriptOffset, [System.IO.SeekOrigin]::Begin)
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        $chunk = $reader.ReadToEnd()
        $State.transcriptOffset = $stream.Position
    } catch {
        if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
            Write-BotLog -Level Debug -Message "Unable to read Antigravity transcript updates" -Exception $_
        }
        return
    } finally {
        if ($reader) {
            try { $reader.Dispose() } catch { }
        } elseif ($stream) {
            try { $stream.Dispose() } catch { }
        }
    }

    if (-not $chunk) { return }

    $buffer = "$($State.transcriptRemainder)$chunk"
    $parts = [regex]::Split($buffer, "\r?\n")
    if ($buffer -notmatch "\r?\n$") {
        $State.transcriptRemainder = $parts[$parts.Count - 1]
        $lineCount = $parts.Count - 1
    } else {
        $State.transcriptRemainder = ""
        $lineCount = $parts.Count
    }

    for ($i = 0; $i -lt $lineCount; $i++) {
        $line = $parts[$i]
        if (-not $line) { continue }
        Invoke-AntigravityTranscriptLineHandler -Line $line -State $State
    }
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
    $antigravityLogPath = New-AntigravityLogPath -WorkingDirectory $WorkingDirectory
    $cliArgs = Add-AntigravityLogFileArg -CliArgs $cliArgs -LogPath $antigravityLogPath -Config $Config
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
        logPath           = $antigravityLogPath
        logOffset         = 0L
        logRemainder      = ""
        logStreamRequests = 0
        logActivitySeen   = @{}
        conversationId    = $null
        transcriptPath    = $null
        transcriptOffset  = 0L
        transcriptRemainder = ""
        transcriptSeen    = @{}
    }

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("$($t.Bezel)--- HARNESS: $($Config.display_name) ---$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)Executable: $executable$($t.Reset)")
        [Console]::Error.WriteLine("$($t.Bezel)Args: $($cliArgs -join ' ')$($t.Reset)")
        if ($antigravityLogPath) {
            [Console]::Error.WriteLine("$($t.Bezel)Log: $antigravityLogPath$($t.Reset)")
        }
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
        $pollActivity = {
            Read-AntigravityLogUpdates -Path $antigravityLogPath -State $state
            Read-AntigravityTranscriptUpdates -State $state
        }
        $streamResult = Invoke-HarnessProcessStream `
            -Executable $executable `
            -CliArgs $cliArgs `
            -WorkingDirectory $WorkingDirectory `
            -HandleOutput $handleOutput `
            -HandleErrorOutput $handleOutput `
            -PollActivity $pollActivity `
            -ShouldStopStream $ShouldStopStream `
            -StopCheckIntervalSeconds $StopCheckIntervalSeconds `
            -StopGraceSeconds $StopGraceSeconds `
            -StopReason $StopReason `
            -ShowDebugJson:$ShowDebugJson `
            -Theme $t
        Read-AntigravityLogUpdates -Path $antigravityLogPath -State $state
        Read-AntigravityTranscriptUpdates -State $state
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
