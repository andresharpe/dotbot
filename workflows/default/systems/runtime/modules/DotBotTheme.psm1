# DOTBOT Control Panel - PowerShell Theme
# Oscilloscope aesthetic with configurable color themes
# Reads selected theme from ui-settings.json, colors from theme-config.json

# Track last modification time to avoid unnecessary re-reads
$script:LastThemeCheckTime = $null
$script:LastThemeFileTime = $null
$script:UiSettingsPath = $null

# Helper function to get the selected theme name from ui-settings.json
function Get-SelectedThemeName {
    if (-not $script:UiSettingsPath) {
        $script:UiSettingsPath = Join-Path $PSScriptRoot "..\..\..\.control\ui-settings.json"
        # Normalize path (handle relative traversal)
        $script:UiSettingsPath = [System.IO.Path]::GetFullPath($script:UiSettingsPath)
    }

    if (-not (Test-Path $script:UiSettingsPath)) {
        return "amber"  # Default theme
    }

    try {
        $settings = Get-Content $script:UiSettingsPath -Raw | ConvertFrom-Json
        if ($settings.theme) {
            return $settings.theme
        }
        return "amber"  # Default if theme not set
    } catch {
        return "amber"  # Default on error
    }
}

# Helper function to load theme preset from theme-config.json
function Get-ThemePreset {
    param([string]$ThemeName)

    $uiThemePath = Join-Path $PSScriptRoot "..\..\ui\static\theme-config.json"
    $defaultThemePath = Join-Path $PSScriptRoot "..\..\..\defaults\theme.default.json"

    $configPath = if (Test-Path $uiThemePath) { $uiThemePath } else { $defaultThemePath }
    if (-not (Test-Path $configPath)) { return $null }

    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $preset = $config.presets.$ThemeName
        if (-not $preset) {
            # Fall back to amber if requested theme not found
            $preset = $config.presets.amber
        }
        return $preset
    } catch {
        return $null
    }
}

# Helper function to build theme from preset
function Build-ThemeFromPreset {
    param([object]$Preset)

    return @{
        # Primary semantic colors from preset
        Primary     = $PSStyle.Foreground.FromRgb($Preset.primary[0], $Preset.primary[1], $Preset.primary[2])
        PrimaryDim  = $PSStyle.Foreground.FromRgb($Preset.'primary-dim'[0], $Preset.'primary-dim'[1], $Preset.'primary-dim'[2])
        Secondary   = $PSStyle.Foreground.FromRgb($Preset.secondary[0], $Preset.secondary[1], $Preset.secondary[2])
        Tertiary    = $PSStyle.Foreground.FromRgb($Preset.tertiary[0], $Preset.tertiary[1], $Preset.tertiary[2])
        Success     = $PSStyle.Foreground.FromRgb($Preset.success[0], $Preset.success[1], $Preset.success[2])
        SuccessDim  = $PSStyle.Foreground.FromRgb($Preset.'success-dim'[0], $Preset.'success-dim'[1], $Preset.'success-dim'[2])
        Error       = $PSStyle.Foreground.FromRgb($Preset.error[0], $Preset.error[1], $Preset.error[2])
        Warning     = $PSStyle.Foreground.FromRgb($Preset.warning[0], $Preset.warning[1], $Preset.warning[2])
        Info        = $PSStyle.Foreground.FromRgb($Preset.info[0], $Preset.info[1], $Preset.info[2])
        Muted       = $PSStyle.Foreground.FromRgb($Preset.muted[0], $Preset.muted[1], $Preset.muted[2])
        Bezel       = $PSStyle.Foreground.FromRgb($Preset.bezel[0], $Preset.bezel[1], $Preset.bezel[2])
        Reset       = $PSStyle.Reset
    }
}

# Helper function to build fallback theme (hardcoded amber)
function Build-FallbackTheme {
    return @{
        # Primary phosphor colors (hardcoded fallback)
        Amber       = $PSStyle.Foreground.FromRgb(232, 160, 48)   # #e8a030
        AmberDim    = $PSStyle.Foreground.FromRgb(184, 120, 32)   # #b87820
        Green       = $PSStyle.Foreground.FromRgb(0, 255, 136)    # #00ff88
        GreenDim    = $PSStyle.Foreground.FromRgb(0, 170, 92)     # #00aa5c
        Cyan        = $PSStyle.Foreground.FromRgb(95, 179, 179)   # #5fb3b3
        Red         = $PSStyle.Foreground.FromRgb(209, 105, 105)  # #d16969
        Blue        = $PSStyle.Foreground.FromRgb(68, 136, 255)   # #4488ff
        Purple      = $PSStyle.Foreground.FromRgb(170, 136, 255)  # #aa88ff

        # UI chrome colors
        Label       = $PSStyle.Foreground.FromRgb(136, 136, 153)  # #888899
        Bezel       = $PSStyle.Foreground.FromRgb(58, 59, 72)     # #3a3b48

        Reset       = $PSStyle.Reset
    }
}

# Helper function to add legacy aliases to theme
function Add-LegacyAliases {
    param([hashtable]$Theme, [bool]$FromPreset)

    if ($FromPreset) {
        # Legacy aliases for backward compatibility (preset has semantic names)
        $Theme.Amber     = $Theme.Primary
        $Theme.AmberDim  = $Theme.PrimaryDim
        $Theme.Green     = $Theme.Success
        $Theme.GreenDim  = $Theme.SuccessDim
        $Theme.Cyan      = $Theme.Secondary
        $Theme.Red       = $Theme.Error
        $Theme.Blue      = $Theme.Info
        $Theme.Purple    = $Theme.Tertiary
        $Theme.Label     = $Theme.Muted
    } else {
        # Semantic aliases matching CSS usage (fallback has legacy names)
        $Theme.Primary   = $Theme.Amber
        $Theme.PrimaryDim = $Theme.AmberDim
        $Theme.Secondary = $Theme.Cyan
        $Theme.Tertiary  = $Theme.Purple
        $Theme.Success   = $Theme.Green
        $Theme.SuccessDim = $Theme.GreenDim
        $Theme.Error     = $Theme.Red
        $Theme.Warning   = $Theme.Amber
        $Theme.Info      = $Theme.Cyan
        $Theme.Muted     = $Theme.Label
    }
}

# Core function to load/reload the theme
function Initialize-Theme {
    $selectedTheme = Get-SelectedThemeName
    $themePreset = Get-ThemePreset -ThemeName $selectedTheme

    if ($themePreset) {
        $script:Theme = Build-ThemeFromPreset -Preset $themePreset
        Add-LegacyAliases -Theme $script:Theme -FromPreset $true
    } else {
        $script:Theme = Build-FallbackTheme
        Add-LegacyAliases -Theme $script:Theme -FromPreset $false
    }

    # Update tracking timestamps
    if ($script:UiSettingsPath -and (Test-Path $script:UiSettingsPath)) {
        $script:LastThemeFileTime = (Get-Item $script:UiSettingsPath).LastWriteTimeUtc
    }
    $script:LastThemeCheckTime = [DateTime]::UtcNow
}

# Get selected theme and load its colors
$selectedTheme = Get-SelectedThemeName
$themePreset = Get-ThemePreset -ThemeName $selectedTheme

if ($themePreset) {
    # Build theme from preset (array format: [R, G, B])
    $script:Theme = @{
        # Primary semantic colors from preset
        Primary     = $PSStyle.Foreground.FromRgb($themePreset.primary[0], $themePreset.primary[1], $themePreset.primary[2])
        PrimaryDim  = $PSStyle.Foreground.FromRgb($themePreset.'primary-dim'[0], $themePreset.'primary-dim'[1], $themePreset.'primary-dim'[2])
        Secondary   = $PSStyle.Foreground.FromRgb($themePreset.secondary[0], $themePreset.secondary[1], $themePreset.secondary[2])
        Tertiary    = $PSStyle.Foreground.FromRgb($themePreset.tertiary[0], $themePreset.tertiary[1], $themePreset.tertiary[2])
        Success     = $PSStyle.Foreground.FromRgb($themePreset.success[0], $themePreset.success[1], $themePreset.success[2])
        SuccessDim  = $PSStyle.Foreground.FromRgb($themePreset.'success-dim'[0], $themePreset.'success-dim'[1], $themePreset.'success-dim'[2])
        Error       = $PSStyle.Foreground.FromRgb($themePreset.error[0], $themePreset.error[1], $themePreset.error[2])
        Warning     = $PSStyle.Foreground.FromRgb($themePreset.warning[0], $themePreset.warning[1], $themePreset.warning[2])
        Info        = $PSStyle.Foreground.FromRgb($themePreset.info[0], $themePreset.info[1], $themePreset.info[2])
        Muted       = $PSStyle.Foreground.FromRgb($themePreset.muted[0], $themePreset.muted[1], $themePreset.muted[2])
        Bezel       = $PSStyle.Foreground.FromRgb($themePreset.bezel[0], $themePreset.bezel[1], $themePreset.bezel[2])

        Reset       = $PSStyle.Reset
    }

    # Legacy aliases for backward compatibility
    $script:Theme.Amber     = $script:Theme.Primary
    $script:Theme.AmberDim  = $script:Theme.PrimaryDim
    $script:Theme.Green     = $script:Theme.Success
    $script:Theme.GreenDim  = $script:Theme.SuccessDim
    $script:Theme.Cyan      = $script:Theme.Secondary
    $script:Theme.Red       = $script:Theme.Error
    $script:Theme.Blue      = $script:Theme.Info
    $script:Theme.Purple    = $script:Theme.Tertiary
    $script:Theme.Label     = $script:Theme.Muted
} else {
    # Fallback to hardcoded amber values if config not found
    $script:Theme = @{
        # Primary phosphor colors (hardcoded fallback)
        Amber       = $PSStyle.Foreground.FromRgb(232, 160, 48)   # #e8a030
        AmberDim    = $PSStyle.Foreground.FromRgb(184, 120, 32)   # #b87820
        Green       = $PSStyle.Foreground.FromRgb(0, 255, 136)    # #00ff88
        GreenDim    = $PSStyle.Foreground.FromRgb(0, 170, 92)     # #00aa5c
        Cyan        = $PSStyle.Foreground.FromRgb(95, 179, 179)   # #5fb3b3
        Red         = $PSStyle.Foreground.FromRgb(209, 105, 105)  # #d16969
        Blue        = $PSStyle.Foreground.FromRgb(68, 136, 255)   # #4488ff
        Purple      = $PSStyle.Foreground.FromRgb(170, 136, 255)  # #aa88ff

        # UI chrome colors
        Label       = $PSStyle.Foreground.FromRgb(136, 136, 153)  # #888899
        Bezel       = $PSStyle.Foreground.FromRgb(58, 59, 72)     # #3a3b48

        Reset       = $PSStyle.Reset
    }

    # Semantic aliases matching CSS usage
    $script:Theme.Primary   = $script:Theme.Amber
    $script:Theme.PrimaryDim = $script:Theme.AmberDim
    $script:Theme.Secondary = $script:Theme.Cyan
    $script:Theme.Tertiary  = $script:Theme.Purple
    $script:Theme.Success   = $script:Theme.Green
    $script:Theme.SuccessDim = $script:Theme.GreenDim
    $script:Theme.Error     = $script:Theme.Red
    $script:Theme.Warning   = $script:Theme.Amber
    $script:Theme.Info      = $script:Theme.Cyan
    $script:Theme.Muted     = $script:Theme.Label
}

function Get-DotBotTheme {
    <#
    .SYNOPSIS
    Returns the DOTBOT theme hashtable for direct use
    #>
    return $script:Theme
}

function Update-DotBotTheme {
    <#
    .SYNOPSIS
    Update the theme if ui-settings.json has changed since last read.
    Call this at natural breakpoints (between tasks, on pause/resume).

    .DESCRIPTION
    Checks if the ui-settings.json file has been modified since the last theme load.
    If so, reloads the theme. This allows theme changes in the browser UI to be
    reflected in console output without restarting scripts.

    .PARAMETER Force
    Force a theme reload regardless of file modification time.

    .OUTPUTS
    Returns $true if theme was updated, $false if no update was needed.

    .EXAMPLE
    Update-DotBotTheme

    .EXAMPLE
    Update-DotBotTheme -Force
    #>
    param(
        [switch]$Force
    )

    # Ensure settings path is initialized
    if (-not $script:UiSettingsPath) {
        $script:UiSettingsPath = Join-Path $PSScriptRoot "..\..\..\.control\ui-settings.json"
        $script:UiSettingsPath = [System.IO.Path]::GetFullPath($script:UiSettingsPath)
    }

    # If file doesn't exist, nothing to refresh
    if (-not (Test-Path $script:UiSettingsPath)) {
        return $false
    }

    # Check if refresh is needed
    $currentFileTime = (Get-Item $script:UiSettingsPath).LastWriteTimeUtc

    if (-not $Force) {
        # Skip if file hasn't changed since last read
        if ($script:LastThemeFileTime -and $currentFileTime -le $script:LastThemeFileTime) {
            return $false
        }
    }

    # Reload theme
    Initialize-Theme
    return $true
}

function Write-Phosphor {
    <#
    .SYNOPSIS
    Write colored output using DOTBOT phosphor colors
    
    .PARAMETER Message
    The message to display
    
    .PARAMETER Color
    Color name: Amber, AmberDim, Green, GreenDim, Cyan, Red, Blue, Purple, Label
    
    .PARAMETER NoNewline
    Don't add newline at end
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter(Position = 1)]
        [ValidateSet('Amber', 'AmberDim', 'Green', 'GreenDim', 'Cyan', 'Red', 'Blue', 'Purple', 'Label', 'Bezel')]
        [string]$Color = 'Amber',
        
        [switch]$NoNewline
    )
    
    $c = $script:Theme[$Color]
    $r = $script:Theme.Reset
    
    if ($NoNewline) {
        Write-Host "${c}${Message}${r}" -NoNewline
    } else {
        Write-Host "${c}${Message}${r}"
    }
}

function Write-Status {
    <#
    .SYNOPSIS
    Write a status message with icon prefix (oscilloscope style)
    
    .PARAMETER Message
    The message to display
    
    .PARAMETER Type
    Status type: Info, Success, Error, Warn, Process, Complete
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Success', 'Error', 'Warn', 'Process', 'Complete')]
        [string]$Type = 'Info'
    )
    
    $icons = @{
        Info     = '›'
        Success  = '✓'
        Error    = '✗'
        Warn     = '⚠'
        Process  = '◆'
        Complete = '●'
    }
    
    $colors = @{
        Info     = $script:Theme.Cyan
        Success  = $script:Theme.Green
        Error    = $script:Theme.Red
        Warn     = $script:Theme.Amber
        Process  = $script:Theme.Amber
        Complete = $script:Theme.Green
    }
    
    $icon = $icons[$Type]
    $iconColor = $colors[$Type]
    $textColor = $script:Theme.Amber
    $r = $script:Theme.Reset
    
    Write-Host "${iconColor}${icon}${r} ${textColor}${Message}${r}"
}

function Write-Label {
    <#
    .SYNOPSIS
    Write a label: value pair (like sidebar items)
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Label,
        
        [Parameter(Mandatory, Position = 1)]
        [string]$Value,
        
        [ValidateSet('Amber', 'Green', 'Cyan', 'Red', 'Blue', 'Purple')]
        [string]$ValueColor = 'Amber'
    )
    
    $labelC = $script:Theme.Label
    $valueC = $script:Theme[$ValueColor]
    $r = $script:Theme.Reset
    
    Write-Host "${labelC}${Label}: ${r}${valueC}${Value}${r}"
}

function Write-Header {
    <#
    .SYNOPSIS
    Write a section header (uppercase, letter-spaced like CSS)
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Text
    )
    
    $c = $script:Theme.AmberDim
    $r = $script:Theme.Reset
    $formatted = ($Text.ToUpper().ToCharArray() -join ' ')
    
    Write-Host ""
    Write-Host "${c}── ${formatted} ──${r}"
    Write-Host ""
}

function Write-Led {
    <#
    .SYNOPSIS
    Write an LED indicator status line
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Label,
        
        [Parameter(Position = 1)]
        [ValidateSet('On', 'Off', 'Warn', 'Error')]
        [string]$State = 'On',
        
        [ValidateSet('Green', 'Amber', 'Cyan', 'Red')]
        [string]$Color = 'Green'
    )
    
    $ledColors = @{
        On    = $script:Theme[$Color]
        Off   = $script:Theme.Bezel
        Warn  = $script:Theme.Amber
        Error = $script:Theme.Red
    }
    
    $ledChars = @{
        On    = '●'
        Off   = '○'
        Warn  = '●'
        Error = '●'
    }
    
    $led = $ledColors[$State]
    $char = $ledChars[$State]
    $label = $script:Theme.Label
    $r = $script:Theme.Reset
    
    Write-Host "${led}${char}${r} ${label}${Label}${r}"
}

function Write-Separator {
    <#
    .SYNOPSIS
    Write a subtle separator line
    #>
    param(
        [int]$Width = 40
    )
    
    $c = $script:Theme.Bezel
    $r = $script:Theme.Reset
    Write-Host "${c}$('─' * $Width)${r}"
}

function Write-Banner {
    <#
    .SYNOPSIS
    Write the DOTBOT banner/logo
    #>
    param(
        [string]$Title = "DOTBOT",
        [string]$Subtitle = "",
        [int]$Width = 40
    )
    
    $amber = $script:Theme.Amber
    $dim = $script:Theme.AmberDim
    $r = $script:Theme.Reset
    
    $innerWidth = $Width - 2  # Account for ║ on each side
    $contentWidth = $innerWidth - 4  # Account for "  " padding on each side
    
    Write-Host ""
    Write-Host "${amber}╔$('═' * $innerWidth)╗${r}"
    Write-Host "${amber}║${r}  ${amber}$(Get-PaddedText -Text $Title -Width $contentWidth)${r}  ${amber}║${r}"
    if ($Subtitle) {
        Write-Host "${amber}║${r}  ${dim}$(Get-PaddedText -Text $Subtitle -Width $contentWidth)${r}  ${amber}║${r}"
    }
    Write-Host "${amber}╚$('═' * $innerWidth)╝${r}"
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════
# BOX DRAWING - ANSI-aware width handling
# ═══════════════════════════════════════════════════════════════════

# Box character sets
$script:BoxChars = @{
    Rounded = @{
        TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'
        H  = '─'; V  = '│'
        LT = '├'; RT = '┤'; TT = '┬'; BT = '┴'; X = '┼'
    }
    Square = @{
        TL = '┌'; TR = '┐'; BL = '└'; BR = '┘'
        H  = '─'; V  = '│'
        LT = '├'; RT = '┤'; TT = '┬'; BT = '┴'; X = '┼'
    }
    Double = @{
        TL = '╔'; TR = '╗'; BL = '╚'; BR = '╝'
        H  = '═'; V  = '║'
        LT = '╠'; RT = '╣'; TT = '╦'; BT = '╩'; X = '╬'
    }
    Heavy = @{
        TL = '┏'; TR = '┓'; BL = '┗'; BR = '┛'
        H  = '━'; V  = '┃'
        LT = '┣'; RT = '┫'; TT = '┳'; BT = '┻'; X = '╋'
    }
}

function Get-VisualWidth {
    <#
    .SYNOPSIS
    Get the visual width of a string, ignoring ANSI escape sequences
    #>
    param([string]$Text)
    ($Text -replace '\x1b\[[0-9;]*m', '').Length
}

function Get-PaddedText {
    <#
    .SYNOPSIS
    Pad text to a visual width, accounting for ANSI codes
    #>
    param(
        [string]$Text,
        [int]$Width,
        [string]$PadChar = ' ',
        [ValidateSet('Left', 'Right', 'Center')]
        [string]$Align = 'Left'
    )
    
    $visual = Get-VisualWidth $Text
    $totalPad = [Math]::Max(0, $Width - $visual)
    
    switch ($Align) {
        'Left'   { return $Text + ($PadChar * $totalPad) }
        'Right'  { return ($PadChar * $totalPad) + $Text }
        'Center' {
            $left = [Math]::Floor($totalPad / 2)
            $right = $totalPad - $left
            return ($PadChar * $left) + $Text + ($PadChar * $right)
        }
    }
}

function Write-Card {
    <#
    .SYNOPSIS
    Draw a card with rounded (or other style) borders
    
    .PARAMETER Title
    Optional title in the top border
    
    .PARAMETER Lines
    Array of content lines (can include ANSI colors)
    
    .PARAMETER Width
    Total width of the card including borders
    
    .PARAMETER BorderStyle
    Border style: Rounded, Square, Double, Heavy
    
    .PARAMETER BorderColor
    Color for the border from theme
    
    .PARAMETER TitleColor
    Color for the title from theme
    
    .PARAMETER Padding
    Internal horizontal padding (default 1)
    #>
    param(
        [string]$Title = "",
        [string[]]$Lines = @(),
        [int]$Width = 40,
        [ValidateSet('Rounded', 'Square', 'Double', 'Heavy')]
        [string]$BorderStyle = 'Rounded',
        [string]$BorderColor = 'AmberDim',
        [string]$TitleColor = 'Amber',
        [int]$Padding = 1
    )
    
    $t = $script:Theme
    $bc = $t[$BorderColor]
    $tc = $t[$TitleColor]
    $r = $t.Reset
    $box = $script:BoxChars[$BorderStyle]
    
    $innerWidth = $Width - 2  # account for │ on each side
    $contentWidth = $innerWidth - ($Padding * 2)
    $pad = ' ' * $Padding
    
    # Top border
    if ($Title) {
        $titleText = " $Title "
        $titleVis = Get-VisualWidth $titleText
        $remaining = [Math]::Max(0, $innerWidth - $titleVis - 1)  # -1 for left dash
        $top = "${bc}$($box.TL)$($box.H)${r}${tc}${titleText}${r}${bc}$($box.H * $remaining)$($box.TR)${r}"
    } else {
        $top = "${bc}$($box.TL)$($box.H * $innerWidth)$($box.TR)${r}"
    }
    Write-Host $top
    
    # Content lines
    foreach ($line in $Lines) {
        $padded = Get-PaddedText -Text $line -Width $contentWidth
        Write-Host "${bc}$($box.V)${r}${pad}${padded}${pad}${bc}$($box.V)${r}"
    }
    
    # Bottom border
    Write-Host "${bc}$($box.BL)$($box.H * $innerWidth)$($box.BR)${r}"
}

function Write-CardRow {
    <#
    .SYNOPSIS
    Draw multiple cards side by side
    
    .PARAMETER Cards
    Array of hashtables, each with: Title, Lines, Width (optional)
    
    .PARAMETER Gap
    Space between cards
    #>
    param(
        [hashtable[]]$Cards,
        [int]$Gap = 2,
        [ValidateSet('Rounded', 'Square', 'Double', 'Heavy')]
        [string]$BorderStyle = 'Rounded',
        [string]$BorderColor = 'AmberDim',
        [string]$TitleColor = 'Amber'
    )
    
    $t = $script:Theme
    $bc = $t[$BorderColor]
    $tc = $t[$TitleColor]
    $r = $t.Reset
    $box = $script:BoxChars[$BorderStyle]
    $gapStr = ' ' * $Gap
    
    # Normalize cards - ensure all have Width and Lines
    $normalizedCards = foreach ($card in $Cards) {
        @{
            Title = $card.Title ?? ""
            Lines = $card.Lines ?? @()
            Width = $card.Width ?? 30
        }
    }
    
    # Find max lines
    $maxLines = ($normalizedCards | ForEach-Object { $_.Lines.Count } | Measure-Object -Maximum).Maximum
    $maxLines = [Math]::Max($maxLines, 1)
    
    # Build each row
    # Top borders
    $topRow = ""
    foreach ($card in $normalizedCards) {
        $innerWidth = $card.Width - 2
        if ($card.Title) {
            $titleText = " $($card.Title) "
            $titleVis = Get-VisualWidth $titleText
            $remaining = [Math]::Max(0, $innerWidth - $titleVis - 1)
            $topRow += "${bc}$($box.TL)$($box.H)${r}${tc}${titleText}${r}${bc}$($box.H * $remaining)$($box.TR)${r}${gapStr}"
        } else {
            $topRow += "${bc}$($box.TL)$($box.H * $innerWidth)$($box.TR)${r}${gapStr}"
        }
    }
    Write-Host $topRow.TrimEnd()
    
    # Content rows
    for ($i = 0; $i -lt $maxLines; $i++) {
        $contentRow = ""
        foreach ($card in $normalizedCards) {
            $innerWidth = $card.Width - 2
            $line = if ($i -lt $card.Lines.Count) { " $($card.Lines[$i])" } else { "" }
            $padded = Get-PaddedText -Text $line -Width ($innerWidth - 1)
            $contentRow += "${bc}$($box.V)${r}${padded} ${bc}$($box.V)${r}${gapStr}"
        }
        Write-Host $contentRow.TrimEnd()
    }
    
    # Bottom borders
    $bottomRow = ""
    foreach ($card in $normalizedCards) {
        $innerWidth = $card.Width - 2
        $bottomRow += "${bc}$($box.BL)$($box.H * $innerWidth)$($box.BR)${r}${gapStr}"
    }
    Write-Host $bottomRow.TrimEnd()
}

function Write-Table {
    <#
    .SYNOPSIS
    Draw a table with headers and rows
    
    .PARAMETER Headers
    Array of column headers
    
    .PARAMETER Rows
    Array of arrays, each inner array is a row. Use comma prefix for single-row tables.
    
    .PARAMETER ColumnWidths
    Array of widths for each column (auto-calculated if not provided)
    
    .EXAMPLE
    Write-Table -Headers @("Name", "Status") -Rows @(
        ,@("Task 1", "Done")
        ,@("Task 2", "Pending")
    )
    #>
    param(
        [string[]]$Headers,
        [Parameter(Mandatory)]
        $Rows,
        [int[]]$ColumnWidths = @(),
        [ValidateSet('Rounded', 'Square', 'Double', 'Heavy')]
        [string]$BorderStyle = 'Rounded',
        [string]$BorderColor = 'AmberDim',
        [string]$HeaderColor = 'Amber'
    )
    
    $t = $script:Theme
    $bc = $t[$BorderColor]
    $hc = $t[$HeaderColor]
    $rs = $t.Reset
    $box = $script:BoxChars[$BorderStyle]
    
    # Normalize rows - ensure we have an array of arrays
    $normalizedRows = @()
    foreach ($row in $Rows) {
        # Force each row into array context
        $normalizedRows += ,@($row)
    }
    
    # Auto-calculate column widths if not provided
    if ($ColumnWidths.Count -eq 0) {
        $ColumnWidths = @()
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $maxWidth = Get-VisualWidth $Headers[$i]
            foreach ($row in $normalizedRows) {
                if ($i -lt $row.Count) {
                    $cellWidth = Get-VisualWidth "$($row[$i])"
                    if ($cellWidth -gt $maxWidth) { $maxWidth = $cellWidth }
                }
            }
            $ColumnWidths += ($maxWidth + 2)  # padding
        }
    }
    
    # Top border
    $top = "${bc}$($box.TL)"
    for ($i = 0; $i -lt $ColumnWidths.Count; $i++) {
        $top += "$($box.H * $ColumnWidths[$i])"
        if ($i -lt $ColumnWidths.Count - 1) { $top += "$($box.TT)" }
    }
    $top += "$($box.TR)${rs}"
    Write-Host $top
    
    # Header row
    $headerRow = "${bc}$($box.V)${rs}"
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $cell = Get-PaddedText -Text " $($Headers[$i])" -Width ($ColumnWidths[$i] - 1)
        $headerRow += "${hc}${cell}${rs} ${bc}$($box.V)${rs}"
    }
    Write-Host $headerRow
    
    # Header separator
    $sep = "${bc}$($box.LT)"
    for ($i = 0; $i -lt $ColumnWidths.Count; $i++) {
        $sep += "$($box.H * $ColumnWidths[$i])"
        if ($i -lt $ColumnWidths.Count - 1) { $sep += "$($box.X)" }
    }
    $sep += "$($box.RT)${rs}"
    Write-Host $sep
    
    # Data rows
    foreach ($row in $normalizedRows) {
        $dataRow = "${bc}$($box.V)${rs}"
        for ($i = 0; $i -lt $ColumnWidths.Count; $i++) {
            $cellContent = if ($i -lt $row.Count) { " $($row[$i])" } else { " " }
            $cell = Get-PaddedText -Text $cellContent -Width ($ColumnWidths[$i] - 1)
            $dataRow += "${cell} ${bc}$($box.V)${rs}"
        }
        Write-Host $dataRow
    }
    
    # Bottom border
    $bottom = "${bc}$($box.BL)"
    for ($i = 0; $i -lt $ColumnWidths.Count; $i++) {
        $bottom += "$($box.H * $ColumnWidths[$i])"
        if ($i -lt $ColumnWidths.Count - 1) { $bottom += "$($box.BT)" }
    }
    $bottom += "$($box.BR)${rs}"
    Write-Host $bottom
}

function Write-ProgressCard {
    <#
    .SYNOPSIS
    Draw a progress bar inside a card
    #>
    param(
        [string]$Title = "Progress",
        [int]$Percent = 0,
        [int]$Width = 40,
        [string]$BarColor = 'Green',
        [string]$EmptyColor = 'Bezel',
        [ValidateSet('Rounded', 'Square', 'Double', 'Heavy')]
        [string]$BorderStyle = 'Rounded'
    )
    
    $t = $script:Theme
    $barC = $t[$BarColor]
    $emptyC = $t[$EmptyColor]
    $r = $t.Reset
    
    $innerWidth = $Width - 4  # borders + padding
    $filled = [Math]::Floor($innerWidth * ($Percent / 100))
    $empty = $innerWidth - $filled
    
    $bar = "${barC}$('█' * $filled)${r}${emptyC}$('░' * $empty)${r}"
    $percentText = "${Percent}%"
    
    Write-Card -Title $Title -Width $Width -BorderStyle $BorderStyle -Lines @(
        $bar
        (Get-PaddedText -Text $percentText -Width $innerWidth -Align Center)
    )
}

function Write-Panel {
    <#
    .SYNOPSIS
    Draw a simple panel with just a border (no title support, minimal overhead)
    #>
    param(
        [string[]]$Lines,
        [int]$Width = 0,
        [ValidateSet('Rounded', 'Square', 'Double', 'Heavy')]
        [string]$BorderStyle = 'Rounded',
        [string]$BorderColor = 'Bezel'
    )
    
    $t = $script:Theme
    $bc = $t[$BorderColor]
    $r = $t.Reset
    $box = $script:BoxChars[$BorderStyle]
    
    # Auto-width if not specified
    if ($Width -eq 0) {
        $Width = ($Lines | ForEach-Object { Get-VisualWidth $_ } | Measure-Object -Maximum).Maximum + 4
    }
    
    $innerWidth = $Width - 2
    
    Write-Host "${bc}$($box.TL)$($box.H * $innerWidth)$($box.TR)${r}"
    foreach ($line in $Lines) {
        $padded = Get-PaddedText -Text " $line" -Width ($innerWidth - 1)
        Write-Host "${bc}$($box.V)${r}${padded} ${bc}$($box.V)${r}"
    }
    Write-Host "${bc}$($box.BL)$($box.H * $innerWidth)$($box.BR)${r}"
}

# Export functions
Export-ModuleMember -Function @(
    'Get-DotBotTheme'
    'Update-DotBotTheme'
    'Write-Phosphor'
    'Write-Status'
    'Write-Label'
    'Write-Header'
    'Write-Led'
    'Write-Separator'
    'Write-Banner'
    'Get-VisualWidth'
    'Get-PaddedText'
    'Write-Card'
    'Write-CardRow'
    'Write-Table'
    'Write-ProgressCard'
    'Write-Panel'
)
