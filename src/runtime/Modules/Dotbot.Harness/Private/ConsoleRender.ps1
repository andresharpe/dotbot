<#
.SYNOPSIS
Console rendering helpers shared by all harness adapters.

.DESCRIPTION
Provides:
  - Get-Timestamp / Get-PreviewText      — string helpers
  - Write-HarnessLog                      — themed timestamped log line to stderr
  - Write-HarnessUnknown                  — themed unknown-event log line
  - ConvertTo-RenderedMarkdown            — markdown → ANSI-colored stdout
  - Format-TokenUsage / Format-ResultSummary — token/result summary rendering

Dot-sourced into Dotbot.Harness module scope so adapters and dispatcher
functions can use them without further imports.
#>

function Get-Timestamp {
    (Get-Date).ToString("HH:mm:ss")
}

function Get-PreviewText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [int]$MaxLength = 140
    )

    if (-not $Text) { return "" }

    $cleaned = $Text -replace "\r", "" -replace "\s+", " "

    if ($cleaned.Length -le $MaxLength) {
        return $cleaned
    }

    $cleaned.Substring(0, $MaxLength) + "…"
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

    [Console]::Error.WriteLine("")

    $iconStr = if ($Icon) { "$Icon " } else { "" }
    $ts = Get-Timestamp
    [Console]::Error.WriteLine("$($t.Bezel)[$ts]$($t.Reset) $iconStr$($t.Cyan)$Kind$($t.Reset) $($t.AmberDim)$Message$($t.Reset)")
    [Console]::Error.Flush()

    try {
        Write-ActivityLog -Type $Kind -Message $Message
    } catch {
        # Silently ignore logging errors
    }
}

function Write-HarnessUnknown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawLine
    )

    $t = $script:theme

    [Console]::Error.WriteLine("")
    $ts = Get-Timestamp
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
    $result = New-Object System.Text.StringBuilder
    $inCodeBlock = $false
    $null = $codeLines = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^```') {
            if (-not $inCodeBlock) {
                $inCodeBlock = $true
                $null = $codeLines = [System.Collections.ArrayList]::new()
                continue
            } else {
                $inCodeBlock = $false

                if ($codeLines.Count -gt 0) {
                    $measureResult = $codeLines | Measure-Object -Property Length -Maximum
                    $maxLen = $measureResult.Maximum
                    $width = [Math]::Max($maxLen + 4, 40)

                    [void]$result.AppendLine("$DIM+" + ("-" * ($width - 2)) + "+$RESET")
                    foreach ($codeLine in $codeLines) {
                        [void]$result.AppendLine("$DIM|$RESET $codeLine")
                    }
                    [void]$result.AppendLine("$DIM+" + ("-" * ($width - 2)) + "+$RESET")
                }
                continue
            }
        }

        if ($inCodeBlock) {
            [void]$codeLines.Add($line)
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

function Format-TokenUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Usage
    )

    $null = $lines = [System.Collections.ArrayList]::new()

    if ($Usage.input_tokens -or $Usage.output_tokens) {
        $inp = if ($Usage.input_tokens) { $Usage.input_tokens } else { 0 }
        $out = if ($Usage.output_tokens) { $Usage.output_tokens } else { 0 }
        [void]$lines.Add("  tokens: in=$inp out=$out")
    }

    if ($Usage.cache_read_input_tokens) {
        $cacheRead = $Usage.cache_read_input_tokens
        [void]$lines.Add("  cache_read: $cacheRead")
    }

    if ($Usage.cache_creation_input_tokens) {
        $cacheCreate = $Usage.cache_creation_input_tokens
        [void]$lines.Add("  cache_create: $cacheCreate")
    }

    if ($Usage.server_tool_use) {
        $stu = $Usage.server_tool_use
        if ($stu.web_search_requests -or $stu.web_fetch_requests) {
            $ws = if ($stu.web_search_requests) { $stu.web_search_requests } else { 0 }
            $wf = if ($stu.web_fetch_requests) { $stu.web_fetch_requests } else { 0 }
            [void]$lines.Add("  web: search=$ws fetch=$wf")
        }
    }

    return $lines
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
    $statusIcon = if ($Event.subtype -eq "success") { "✓" } else { "✗" }
    $statusText = if ($Event.subtype -eq "success") { "Success" } else { $Event.subtype }

    $null = $parts = [System.Collections.ArrayList]::new()
    [void]$parts.Add("$statusColor$statusIcon $statusText$($t.Reset)")

    if ($Event.duration_ms) {
        $durSec = [math]::Round($Event.duration_ms / 1000, 1)
        [void]$parts.Add("$($t.Label)time:$($t.Reset) $($t.Cyan)${durSec}s$($t.Reset)")
    }

    if ($Event.num_turns) {
        $turns = $Event.num_turns
        [void]$parts.Add("$($t.Label)turns:$($t.Reset) $($t.Cyan)$turns$($t.Reset)")
    }

    if ($Event.total_cost_usd) {
        $cost = [math]::Round($Event.total_cost_usd, 4)
        [void]$parts.Add("$($t.Amber)`$$cost$($t.Reset)")
    }

    [Console]::Error.WriteLine(($parts -join "  "))

    if ($Event.usage) {
        $inp = if ($Event.usage.input_tokens) { $Event.usage.input_tokens } else { 0 }
        $out = if ($Event.usage.output_tokens) { $Event.usage.output_tokens } else { 0 }

        $null = $tokenParts = [System.Collections.ArrayList]::new()
        [void]$tokenParts.Add("$($t.Label)tokens:$($t.Reset) $($t.Cyan)in=$inp out=$out$($t.Reset)")

        if ($Event.usage.cache_read_input_tokens) {
            $cacheRead = $Event.usage.cache_read_input_tokens
            $cacheReadK = [math]::Round($cacheRead / 1000, 1)
            [void]$tokenParts.Add("$($t.Label)cache:$($t.Reset) $($t.Cyan)${cacheReadK}k$($t.Reset)")
        }

        [Console]::Error.WriteLine(($tokenParts -join "  "))
    }

    [Console]::Error.WriteLine("$($t.Bezel)" + ("─" * 70) + "$($t.Reset)")
    [Console]::Error.WriteLine("")
    [Console]::Error.Flush()
}
