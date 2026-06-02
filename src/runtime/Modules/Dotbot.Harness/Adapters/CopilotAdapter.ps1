<#
.SYNOPSIS
GitHub Copilot CLI harness adapter.

.DESCRIPTION
Wraps the standalone `copilot` CLI in non-interactive prompt mode. The GitHub
CLI `gh copilot` entry point is a preview wrapper; this adapter targets
`copilot` directly and falls back to `gh copilot --` only when the standalone
binary is not on PATH.

Streaming mode requests JSONL with `--output-format=json`. Copilot's JSON event
schema is still evolving, so the parser accepts several common text, tool, and
usage shapes and treats unknown events as debug-only noise.

Sessions are managed by Copilot itself. Dotbot invokes prompt mode as a
short-lived process, so NewSession returns $null and RemoveSession is a no-op.
#>

function Resolve-CopilotInvocation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $configured = if ($Config.executable) { [string]$Config.executable } else { 'copilot' }
    if (Get-Command $configured -ErrorAction SilentlyContinue) {
        return @{
            Executable = $configured
            Prefix     = @()
        }
    }

    if ($configured -eq 'copilot' -and (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
        return @{
            Executable = 'gh'
            Prefix     = @('copilot', '--')
        }
    }

    throw "GitHub Copilot CLI '$configured' not found on PATH. Install the standalone 'copilot' CLI or install GitHub CLI with Copilot support for the 'gh copilot --' fallback."
}

function ConvertTo-CopilotMcpConfigJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $frameworkRoot = Get-DotbotInstallPath
    $mcpScript = Join-Path $frameworkRoot 'src/mcp/dotbot-mcp.ps1'

    $config = [ordered]@{
        mcpServers = [ordered]@{
            dotbot = [ordered]@{
                type    = 'stdio'
                command = 'pwsh'
                args    = @(
                    '-NoProfile',
                    '-ExecutionPolicy',
                    'Bypass',
                    '-File',
                    $mcpScript
                )
                env     = [ordered]@{
                    DOTBOT_HOME         = $frameworkRoot
                    DOTBOT_PROJECT_ROOT = $WorkingDirectory
                }
                tools   = @('*')
            }
        }
    }

    return ($config | ConvertTo-Json -Compress -Depth 8)
}

function Add-CopilotWorktreeArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$CliArgs,

        [string]$WorkingDirectory
    )

    if (-not $WorkingDirectory -or -not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        return $CliArgs
    }

    $mcpJson = ConvertTo-CopilotMcpConfigJson -WorkingDirectory $WorkingDirectory
    return @("--add-dir=$WorkingDirectory", "--additional-mcp-config=$mcpJson") + $CliArgs
}

function Get-CopilotObjectValue {
    param(
        $Object,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-CopilotTextFromBlock {
    param($Block)

    if ($null -eq $Block) { return $null }
    if ($Block -is [string]) { return $Block }

    $text = Get-CopilotObjectValue -Object $Block -Name 'text'
    if ($text) { return [string]$text }

    $content = Get-CopilotObjectValue -Object $Block -Name 'content'
    if ($content -is [string]) { return $content }

    $delta = Get-CopilotObjectValue -Object $Block -Name 'delta'
    if ($delta -is [string]) { return $delta }
    if ($delta) {
        $deltaText = Get-CopilotObjectValue -Object $delta -Name 'text'
        if ($deltaText) { return [string]$deltaText }
    }

    return $null
}

function Get-CopilotEventText {
    param($Event)

    foreach ($name in @('text', 'content', 'response', 'answer', 'message')) {
        $value = Get-CopilotObjectValue -Object $Event -Name $name
        if ($value -is [string]) { return $value }
    }

    $delta = Get-CopilotObjectValue -Object $Event -Name 'delta'
    $deltaText = Get-CopilotTextFromBlock $delta
    if ($deltaText) { return $deltaText }

    $message = Get-CopilotObjectValue -Object $Event -Name 'message'
    if ($message) {
        $messageText = Get-CopilotTextFromBlock $message
        if ($messageText) { return $messageText }

        $messageDelta = Get-CopilotObjectValue -Object $message -Name 'delta'
        $messageDeltaText = Get-CopilotTextFromBlock $messageDelta
        if ($messageDeltaText) { return $messageDeltaText }

        $messageContent = Get-CopilotObjectValue -Object $message -Name 'content'
        if ($messageContent -is [System.Array]) {
            $parts = @()
            foreach ($block in $messageContent) {
                $part = Get-CopilotTextFromBlock $block
                if ($part) { $parts += $part }
            }
            if ($parts.Count -gt 0) { return ($parts -join '') }
        }
    }

    $content = Get-CopilotObjectValue -Object $Event -Name 'content'
    if ($content -is [System.Array]) {
        $parts = @()
        foreach ($block in $content) {
            $part = Get-CopilotTextFromBlock $block
            if ($part) { $parts += $part }
        }
        if ($parts.Count -gt 0) { return ($parts -join '') }
    }

    return $null
}

function Write-CopilotBufferedText {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State
    )

    if ($State.assistantText.Length -eq 0) { return }

    $text = $State.assistantText.ToString()
    [Console]::WriteLine("")
    [Console]::WriteLine($text)
    Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
    [Console]::Out.Flush()
    $State.assistantText.Length = 0
}

function Add-CopilotUsage {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        $Usage
    )

    if (-not $Usage) { return }

    foreach ($name in @('input_tokens', 'inputTokens', 'prompt_tokens', 'promptTokens')) {
        $value = Get-CopilotObjectValue -Object $Usage -Name $name
        if ($value) {
            $State.totalInputTokens += [int]$value
            break
        }
    }

    foreach ($name in @('output_tokens', 'outputTokens', 'completion_tokens', 'completionTokens')) {
        $value = Get-CopilotObjectValue -Object $Usage -Name $name
        if ($value) {
            $State.totalOutputTokens += [int]$value
            break
        }
    }
}

function Invoke-CopilotLineHandler {
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
            [Console]::Error.WriteLine("$($t.Bezel)[TEXT] $Line$($t.Reset)")
            [Console]::Error.Flush()
        }
        if ($Line) {
            [Console]::WriteLine($Line)
            Write-ActivityLog -Type "text" -Message (Get-PreviewText $Line 200)
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

    $type = [string](Get-CopilotObjectValue -Object $evt -Name 'type')
    if (-not $type) { $type = [string](Get-CopilotObjectValue -Object $evt -Name 'event') }
    $kind = $type.ToLowerInvariant()

    $usage = Get-CopilotObjectValue -Object $evt -Name 'usage'
    if (-not $usage) {
        $message = Get-CopilotObjectValue -Object $evt -Name 'message'
        if ($message) { $usage = Get-CopilotObjectValue -Object $message -Name 'usage' }
    }
    Add-CopilotUsage -State $State -Usage $usage

    if ($kind -match '^(session|thread|conversation)[._-]?(started|created)?$' -or $kind -eq 'init') {
        $sessionId = Get-CopilotObjectValue -Object $evt -Name 'session_id'
        if (-not $sessionId) { $sessionId = Get-CopilotObjectValue -Object $evt -Name 'sessionId' }
        if ($sessionId) {
            Write-HarnessLog "init" "Copilot session: $sessionId" "*"
            Write-ActivityLog -Type "init" -Message "Copilot session: $sessionId"
        } else {
            Write-HarnessLog "init" "Copilot started" "*"
            Write-ActivityLog -Type "init" -Message "Copilot started"
        }
        return 'init'
    }

    if ($kind -match 'tool|command|shell') {
        Write-CopilotBufferedText -State $State

        $name = Get-CopilotObjectValue -Object $evt -Name 'name'
        if (-not $name) { $name = Get-CopilotObjectValue -Object $evt -Name 'tool' }
        if (-not $name) { $name = Get-CopilotObjectValue -Object $evt -Name 'command' }
        if (-not $name) { $name = 'tool' }

        $detail = ''
        foreach ($detailName in @('args', 'arguments', 'input', 'command', 'path', 'file', 'description')) {
            $value = Get-CopilotObjectValue -Object $evt -Name $detailName
            if (-not $value) { continue }
            if ($value -is [string]) {
                $detail = Get-PreviewText $value 140
            } else {
                try { $detail = Get-PreviewText ($value | ConvertTo-Json -Compress -Depth 4) 140 } catch { $detail = '' }
            }
            if ($detail) { break }
        }

        Write-HarnessLog $name $detail ">"
        Write-ActivityLog -Type $name -Message $detail

        if ($kind -match 'result|finish|complete|done') {
            Write-HarnessLog "done" "" "+"
        }
        return 'tool_use'
    }

    if ($kind -match 'error|failed|failure') {
        $errorMsg = Get-CopilotObjectValue -Object $evt -Name 'message'
        if (-not $errorMsg) {
            $errorObj = Get-CopilotObjectValue -Object $evt -Name 'error'
            $errorMsg = Get-CopilotObjectValue -Object $errorObj -Name 'message'
        }
        if (-not $errorMsg) { $errorMsg = 'Unknown error' }

        [Console]::Error.WriteLine("")
        [Console]::Error.WriteLine("$($t.Amber)Error: $errorMsg$($t.Reset)")
        [Console]::Error.Flush()
        Write-ActivityLog -Type "error" -Message $errorMsg
        return 'error'
    }

    $text = Get-CopilotEventText -Event $evt
    if ($text) {
        if ($kind -match 'delta|chunk') {
            [void]$State.assistantText.Append($text)
        } else {
            Write-CopilotBufferedText -State $State
            [Console]::WriteLine("")
            [Console]::WriteLine($text)
            Write-ActivityLog -Type "text" -Message (Get-PreviewText $text 200)
            [Console]::Out.Flush()
        }
        return 'text'
    }

    if ($kind -match 'result|complete|completed|done|finish|finished') {
        Write-CopilotBufferedText -State $State
        if ($State.totalInputTokens -gt 0 -or $State.totalOutputTokens -gt 0) {
            Write-HarnessLog "done" "tokens: in=$($State.totalInputTokens) out=$($State.totalOutputTokens)" "+"
        } else {
            Write-HarnessLog "done" "complete" "+"
        }
        return 'result'
    }

    if ($ShowDebugJson) {
        [Console]::Error.WriteLine("$($t.Bezel)[UNKNOWN] type=$type$($t.Reset)")
        [Console]::Error.Flush()
    }
    return 'unknown'
}

function Invoke-CopilotAdapterStream {
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
    $cliArgs = Add-CopilotWorktreeArgs -CliArgs $cliArgs -WorkingDirectory $WorkingDirectory

    $invocation = Resolve-CopilotInvocation -Config $Config
    $executable = $invocation.Executable
    $cliArgs = @($invocation.Prefix) + $cliArgs

    $state = @{
        assistantText     = [System.Text.StringBuilder]::new()
        totalInputTokens  = 0
        totalOutputTokens = 0
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

            [void](Invoke-CopilotLineHandler -Line $line -State $state -ShowDebugJson:$ShowDebugJson -ShowVerbose:$ShowVerbose)
        }

        & $executable @cliArgs 2>&1 | ForEach-Object -Process $handleOutput
        Write-CopilotBufferedText -State $state
    } finally {
        if ($pushedLocation) { Pop-Location }
        [Console]::OutputEncoding = $prevOutputEncoding
    }
}

function Invoke-CopilotAdapter {
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
    $cliArgs = Add-CopilotWorktreeArgs -CliArgs $cliArgs -WorkingDirectory $WorkingDirectory
    $cliArgs += '-s'

    $invocation = Resolve-CopilotInvocation -Config $Config
    $executable = $invocation.Executable
    $cliArgs = @($invocation.Prefix) + $cliArgs

    Invoke-WithUtf8Console -Script {
        $pushedLocation = $false
        try {
            if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
                Push-Location -LiteralPath $WorkingDirectory
                $pushedLocation = $true
            }
            & $executable @cliArgs
        } finally {
            if ($pushedLocation) { Pop-Location }
        }
    }
}

function New-CopilotAdapterSession {
    param($Config)
    return $null
}

function Remove-CopilotAdapterSession {
    param(
        $Config,
        [string]$SessionId,
        [string]$ProjectRoot
    )
    return $false
}

Register-HarnessAdapter -Name 'Copilot' -Spec @{
    Models           = @{
        fast     = @{
            id           = 'auto'
            display_name = 'Fast'
            description  = 'Auto model selection; lets Copilot choose the fastest suitable available model.'
        }
        balanced = @{
            id           = 'auto'
            display_name = 'Balanced'
            description  = 'Auto model selection; lets Copilot balance speed, cost, and capability.'
        }
        best     = @{
            id           = 'auto'
            display_name = 'Best'
            description  = 'Auto model selection; lets Copilot choose the best available model for the task.'
            badge        = 'Recommended'
        }
    }
    DefaultModel     = 'best'
    Stream           = { Invoke-CopilotAdapterStream @args }
    Invoke           = { Invoke-CopilotAdapter @args }
    NewSession       = { New-CopilotAdapterSession @args }
    RemoveSession    = { Remove-CopilotAdapterSession @args }
}
