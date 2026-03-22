<#
.SYNOPSIS
UI rendering utilities for ANSI formatting and text layout

.DESCRIPTION
NOTE: This module is DEPRECATED. Most functions are now provided by DotBotTheme.psm1.
Retained functions: Strip-Ansi, Wrap-Text (for backward compatibility)
Deprecated functions: Get-VisibleWidth, Format-BoxLine (use DotBotTheme equivalents)

Provides functions for:
- ANSI escape code handling (Strip-Ansi - still used)
- Text wrapping (Wrap-Text - still used)
- Text width calculation (DEPRECATED - use DotBotTheme)
- Box formatting (DEPRECATED - use DotBotTheme)
#>

# ANSI escape sequence pattern
$script:AnsiPattern = "(\x1B\[[0-9;?]*[ -/]*[@-~])"

function Strip-Ansi {
    <#
    .SYNOPSIS
    Remove ANSI escape codes from a string
    
    .PARAMETER Text
    String potentially containing ANSI codes
    
    .OUTPUTS
    String with ANSI codes removed
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    if (-not $Text) { return "" }
    return [regex]::Replace($Text, $script:AnsiPattern, "")
}

function Get-VisibleWidth {
    <#
    .SYNOPSIS
    Calculate the visible width of a string (excluding ANSI codes)
    
    .PARAMETER Text
    String to measure
    
    .OUTPUTS
    Integer representing visible character count
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )
    
    if (-not $Text) { return 0 }
    return (Strip-Ansi $Text).Length
}

function Format-BoxLine {
    <#
    .SYNOPSIS
    Format a line of text within a box with specified width
    
    .PARAMETER Content
    Text content (may contain ANSI codes)
    
    .PARAMETER InnerWidth
    Width of the box interior (excluding borders)
    
    .PARAMETER LeftBorder
    Left border characters (default: "║  ")
    
    .PARAMETER RightBorder
    Right border characters (default: " ║")
    
    .OUTPUTS
    Formatted box line string
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content,
        
        [Parameter(Mandatory = $true)]
        [int]$InnerWidth,
        
        [Parameter(Mandatory = $false)]
        [string]$LeftBorder = "║  ",
        
        [Parameter(Mandatory = $false)]
        [string]$RightBorder = " ║"
    )
    
    $visibleWidth = Get-VisibleWidth $Content
    $padding = $InnerWidth - $visibleWidth
    
    if ($padding -lt 0) {
        # Content too long - truncate based on visible width
        $plain = Strip-Ansi $Content
        $truncated = $plain.Substring(0, $InnerWidth - 3) + "..."
        return $LeftBorder + $truncated + $RightBorder
    }
    
    return $LeftBorder + $Content + (" " * $padding) + $RightBorder
}

function Wrap-Text {
    <#
    .SYNOPSIS
    Wrap text to specified maximum width
    
    .PARAMETER Text
    Text to wrap
    
    .PARAMETER MaxWidth
    Maximum width per line
    
    .OUTPUTS
    Array of wrapped text lines
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        
        [Parameter(Mandatory = $true)]
        [int]$MaxWidth
    )
    
    $words = $Text -split '\s+'
    $lines = @()
    $currentLine = ""
    
    foreach ($word in $words) {
        $testLine = if ($currentLine) { "$currentLine $word" } else { $word }
        if ($testLine.Length -le $MaxWidth) {
            $currentLine = $testLine
        } else {
            if ($currentLine) { $lines += $currentLine }
            $currentLine = $word
        }
    }
    if ($currentLine) { $lines += $currentLine }
    
    return $lines
}
