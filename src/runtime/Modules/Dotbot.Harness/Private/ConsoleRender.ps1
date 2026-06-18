<#
.SYNOPSIS
Console rendering helpers shared by all harness adapters.

.DESCRIPTION
Provides:
  - Get-Timestamp / Get-PreviewText      — string helpers
  - Write-HarnessLog                      — themed timestamped log line to stderr
  - Write-HarnessUnknown                  — themed unknown-event log line
  - ConvertTo-RenderedMarkdown            — markdown → ANSI-colored stdout
  - Format-ResultSummary                  — final result summary rendering

Dot-sourced into Dotbot.Harness module scope so adapters and dispatcher
functions can use them without further imports.
#>

function Get-Timestamp {
    (Get-Date).ToString("HH:mm:ss")
}

function Invoke-WithUtf8Console {
    <#
    .SYNOPSIS
    Runs a scriptblock with UTF-8 (no-BOM) console encoding, restoring the
    previous encoding on exit. Used by non-streaming adapter invocations that
    pipe stdin/stdout to a CLI subprocess.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Script
    )

    $prevOutput     = $OutputEncoding
    $prevConsoleIn  = [Console]::InputEncoding
    $prevConsoleOut = [Console]::OutputEncoding
    $utf8           = [System.Text.UTF8Encoding]::new($false)
    try {
        $OutputEncoding              = $utf8
        [Console]::InputEncoding     = $utf8
        [Console]::OutputEncoding    = $utf8
        & $Script
    } finally {
        $OutputEncoding              = $prevOutput
        [Console]::InputEncoding     = $prevConsoleIn
        [Console]::OutputEncoding    = $prevConsoleOut
    }
}

function Get-PreviewText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [int]$MaxLength = 140
    )

    if (-not $Text) { return "" }

    $cleaned = $Text -replace "\r", "" -replace "\s+", " "
    if ($cleaned.Length -le $MaxLength) { return $cleaned }
    $cleaned.Substring(0, $MaxLength) + "…"
}

function Get-HarnessPropertyValue {
    [CmdletBinding()]
    param(
        $Object,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            if ($Object.Contains($name)) { return $Object[$name] }
            foreach ($key in $Object.Keys) {
                if ([string]::Equals([string]$key, $name, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $Object[$key]
                }
            }
        }
        return $null
    }

    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties |
            Where-Object { [string]::Equals($_.Name, $name, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
        if ($prop) { return $prop.Value }
    }

    return $null
}

function ConvertFrom-HarnessJsonString {
    [CmdletBinding()]
    param($Value)

    if ($Value -isnot [string]) { return $Value }

    $trimmed = $Value.Trim()
    if (-not $trimmed) { return $Value }
    if ($trimmed[0] -ne '{' -and $trimmed[0] -ne '[') { return $Value }

    try {
        return ($trimmed | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $Value
    }
}

function ConvertTo-HarnessDetailString {
    [CmdletBinding()]
    param(
        $Value,
        [int]$MaxLength = 140,
        [string]$BasePath
    )

    if ($null -eq $Value) { return "" }

    if ($Value -is [string]) {
        $text = $Value
        foreach ($root in @($BasePath, $PWD.Path, $global:DotbotProjectRoot) | Where-Object { $_ } | Select-Object -Unique) {
            try {
                $fullRoot = [System.IO.Path]::GetFullPath([string]$root)
                if (-not $fullRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
                    $fullRoot += [System.IO.Path]::DirectorySeparatorChar
                }
                $candidate = [System.IO.Path]::GetFullPath($text)
                if ($candidate.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $text = $candidate.Substring($fullRoot.Length)
                    break
                }
            } catch { }
        }
        return Get-PreviewText $text $MaxLength
    }

    if ($Value -is [System.ValueType]) {
        return Get-PreviewText ([string]$Value) $MaxLength
    }

    if ($Value -is [System.Array]) {
        $parts = @()
        foreach ($item in @($Value | Select-Object -First 4)) {
            $part = ConvertTo-HarnessDetailString -Value $item -MaxLength $MaxLength -BasePath $BasePath
            if ($part) { $parts += $part }
        }
        return Get-PreviewText ($parts -join ', ') $MaxLength
    }

    try {
        return Get-PreviewText ($Value | ConvertTo-Json -Compress -Depth 8 -WarningAction SilentlyContinue) $MaxLength
    } catch {
        return Get-PreviewText ([string]$Value) $MaxLength
    }
}

function Find-HarnessToolDetail {
    [CmdletBinding()]
    param(
        $Object,
        [int]$Depth = 0,
        [int]$MaxDepth = 6,
        [int]$MaxLength = 140,
        [string]$BasePath
    )

    if ($null -eq $Object -or $Depth -gt $MaxDepth) { return "" }

    $candidate = ConvertFrom-HarnessJsonString $Object
    if ($candidate -is [string]) {
        return ConvertTo-HarnessDetailString -Value $candidate -MaxLength $MaxLength -BasePath $BasePath
    }

    $detailKeys = @(
        'command', 'cmd', 'script', 'shell_command', 'shellCommand',
        'file_path', 'filePath', 'filepath', 'path', 'absolute_path',
        'directory', 'directory_path', 'dir', 'cwd',
        'query', 'pattern', 'glob', 'url', 'description', 'prompt'
    )
    foreach ($key in $detailKeys) {
        $value = Get-HarnessPropertyValue -Object $candidate -Names @($key)
        if ($null -ne $value -and "$value".Length -gt 0) {
            return ConvertTo-HarnessDetailString -Value $value -MaxLength $MaxLength -BasePath $BasePath
        }
    }

    $wrapperKeys = @(
        'arguments', 'args', 'input', 'parameters', 'params', 'payload',
        'request', 'body', 'state', 'tool_call', 'toolCall', 'function_call',
        'functionCall'
    )
    foreach ($key in $wrapperKeys) {
        $value = Get-HarnessPropertyValue -Object $candidate -Names @($key)
        if ($null -eq $value) { continue }

        $detail = Find-HarnessToolDetail -Object $value -Depth ($Depth + 1) -MaxDepth $MaxDepth -MaxLength $MaxLength -BasePath $BasePath
        if ($detail) { return $detail }
    }

    if ($candidate -is [System.Array]) {
        foreach ($item in $candidate) {
            $detail = Find-HarnessToolDetail -Object $item -Depth ($Depth + 1) -MaxDepth $MaxDepth -MaxLength $MaxLength -BasePath $BasePath
            if ($detail) { return $detail }
        }
    }

    return ""
}

function Get-HarnessToolDetail {
    [CmdletBinding()]
    param(
        $InputObject,
        [int]$MaxLength = 140,
        [string]$BasePath
    )

    $detail = Find-HarnessToolDetail -Object $InputObject -MaxLength $MaxLength -BasePath $BasePath
    if ($detail) { return $detail }

    return ConvertTo-HarnessDetailString -Value (ConvertFrom-HarnessJsonString $InputObject) -MaxLength $MaxLength -BasePath $BasePath
}

function Get-HarnessToolName {
    [CmdletBinding()]
    param(
        $Event,
        [string]$Default = 'tool'
    )

    if ($null -eq $Event) { return $Default }

    foreach ($key in @('name', 'tool', 'tool_name', 'toolName', 'function_name', 'functionName')) {
        $value = Get-HarnessPropertyValue -Object $Event -Names @($key)
        if ($value -is [string] -and $value.Trim()) { return $value.Trim() }
    }

    foreach ($key in @('part', 'item', 'call', 'tool_call', 'toolCall', 'function_call', 'functionCall')) {
        $value = Get-HarnessPropertyValue -Object $Event -Names @($key)
        if ($null -eq $value) { continue }
        $name = Get-HarnessToolName -Event $value -Default ''
        if ($name) { return $name }
    }

    return $Default
}

function Invoke-WithHarnessProcessContext {
    [CmdletBinding()]
    param(
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [scriptblock]$Script
    )

    $pushedLocation = $false
    $savedProjectRoot = $env:DOTBOT_PROJECT_ROOT
    $savedDotbotHome = $env:DOTBOT_HOME

    try {
        if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
            Push-Location -LiteralPath $WorkingDirectory
            $pushedLocation = $true
            $env:DOTBOT_PROJECT_ROOT = $WorkingDirectory
        }

        $frameworkRoot = Get-DotbotInstallPath
        if ($frameworkRoot) { $env:DOTBOT_HOME = $frameworkRoot }

        & $Script
    } finally {
        if ($null -ne $savedProjectRoot) { $env:DOTBOT_PROJECT_ROOT = $savedProjectRoot }
        else { Remove-Item Env:DOTBOT_PROJECT_ROOT -ErrorAction SilentlyContinue }

        if ($null -ne $savedDotbotHome) { $env:DOTBOT_HOME = $savedDotbotHome }
        else { Remove-Item Env:DOTBOT_HOME -ErrorAction SilentlyContinue }

        if ($pushedLocation) { Pop-Location }
    }
}

function Update-HarnessTheme {
    [CmdletBinding()]
    param()

    $updateCommand = Get-Command Update-DotbotTheme -ErrorAction SilentlyContinue
    $getCommand = Get-Command Get-DotbotTheme -ErrorAction SilentlyContinue

    if ($updateCommand -and $getCommand) {
        try {
            if (Update-DotbotTheme) {
                $script:theme = Get-DotbotTheme
            }
        } catch {
            # Theme refresh is cosmetic; a missing or scope-hidden theme helper
            # must not abort a harness invocation.
        }
    } elseif (-not $script:theme -and $getCommand) {
        try { $script:theme = Get-DotbotTheme } catch { }
    }

    return $script:theme
}

function Write-HarnessLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Kind,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [string]$Icon = ""
    )

    $t = $script:theme
    $iconStr = if ($Icon) { "$Icon " } else { "" }
    $ts = Get-Timestamp

    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("$($t.Bezel)[$ts]$($t.Reset) $iconStr$($t.Cyan)$Kind$($t.Reset) $($t.AmberDim)$Message$($t.Reset)")
    [Console]::Error.Flush()

    Write-ActivityLog -Type $Kind -Message $Message
}

function Write-HarnessUnknown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawLine
    )

    $t = $script:theme
    $ts = Get-Timestamp

    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("$($t.Bezel)[$ts]$($t.Reset) $($t.Label)$RawLine$($t.Reset)")
    [Console]::Error.Flush()
}

function ConvertTo-RenderedMarkdown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Markdown
    )

    $t = $script:theme
    $RESET  = $t.Reset
    $BOLD   = "`e[1m"
    $DIM    = $t.GreenDim
    $CYAN   = $t.Cyan
    $GREEN  = $t.Green

    $lines = $Markdown -split "\r?\n"
    $result = [System.Text.StringBuilder]::new()
    $codeLines = [System.Collections.Generic.List[string]]::new()
    $inCodeBlock = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^```') {
            if (-not $inCodeBlock) {
                $inCodeBlock = $true
                $codeLines.Clear()
                continue
            }
            $inCodeBlock = $false
            if ($codeLines.Count -gt 0) {
                $maxLen = ($codeLines | Measure-Object -Property Length -Maximum).Maximum
                $width = [Math]::Max($maxLen + 4, 40)
                [void]$result.AppendLine("$DIM+" + ("-" * ($width - 2)) + "+$RESET")
                foreach ($codeLine in $codeLines) {
                    [void]$result.AppendLine("$DIM|$RESET $codeLine")
                }
                [void]$result.AppendLine("$DIM+" + ("-" * ($width - 2)) + "+$RESET")
            }
            continue
        }

        if ($inCodeBlock) {
            $codeLines.Add($line)
            continue
        }

        if ($line -match '^---+$' -or $line -match '^___+$') {
            [void]$result.AppendLine("")
            [void]$result.AppendLine("$DIM" + ("-" * 60) + "$RESET")
            [void]$result.AppendLine("")
            continue
        }

        if ($line -match '^(#{1,6})\s+(.+)$') {
            $level = $matches[1].Length
            $text = $matches[2]
            [void]$result.AppendLine("")
            if ($level -eq 1) {
                [void]$result.AppendLine("$BOLD$CYAN$text$RESET")
            } else {
                [void]$result.AppendLine("$BOLD$text$RESET")
            }
            continue
        }

        if ($line -match '^\s*$') {
            [void]$result.AppendLine($line)
            continue
        }

        $processed = "$GREEN$line$RESET"
        $processed = $processed -replace '`([^`]+)`', "$RESET$DIM`$1$RESET$GREEN"
        $processed = $processed -replace '\*\*([^\*]+)\*\*', "$BOLD`$1$RESET$GREEN"
        $processed = $processed -replace '\[([^\]]+)\]\(([^\)]+)\)', "$RESET$CYAN`$1$RESET$DIM (`$2)$RESET$GREEN"

        if ($line -match '^(\s*)[-*]\s+(.+)$') {
            $processed = $processed -replace '^(\x1b\[[0-9;]*m)(\s*)[-*]\s+', "`$1`$2* "
        }

        [void]$result.AppendLine($processed)
    }

    return $result.ToString()
}

function Format-ResultSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Event
    )

    $t = $script:theme

    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("$($t.Bezel)" + ("─" * 70) + "$($t.Reset)")

    $statusColor = if ($Event.subtype -eq "success") { $t.Green } else { $t.Red }
    $statusIcon  = if ($Event.subtype -eq "success") { "✓" } else { "✗" }
    $statusText  = if ($Event.subtype -eq "success") { "Success" } else { $Event.subtype }

    $parts = @("$statusColor$statusIcon $statusText$($t.Reset)")
    if ($Event.duration_ms) {
        $durSec = [math]::Round($Event.duration_ms / 1000, 1)
        $parts += "$($t.Label)time:$($t.Reset) $($t.Cyan)${durSec}s$($t.Reset)"
    }
    if ($Event.num_turns) {
        $parts += "$($t.Label)turns:$($t.Reset) $($t.Cyan)$($Event.num_turns)$($t.Reset)"
    }
    if ($Event.total_cost_usd) {
        $cost = [math]::Round($Event.total_cost_usd, 4)
        $parts += "$($t.Amber)`$$cost$($t.Reset)"
    }
    [Console]::Error.WriteLine(($parts -join "  "))

    if ($Event.usage) {
        $inp = if ($Event.usage.input_tokens)  { $Event.usage.input_tokens }  else { 0 }
        $out = if ($Event.usage.output_tokens) { $Event.usage.output_tokens } else { 0 }
        $tokenParts = @("$($t.Label)tokens:$($t.Reset) $($t.Cyan)in=$inp out=$out$($t.Reset)")
        if ($Event.usage.cache_read_input_tokens) {
            $cacheReadK = [math]::Round($Event.usage.cache_read_input_tokens / 1000, 1)
            $tokenParts += "$($t.Label)cache:$($t.Reset) $($t.Cyan)${cacheReadK}k$($t.Reset)"
        }
        [Console]::Error.WriteLine(($tokenParts -join "  "))
    }

    [Console]::Error.WriteLine("$($t.Bezel)" + ("─" * 70) + "$($t.Reset)")
    [Console]::Error.WriteLine("")
    [Console]::Error.Flush()
}
