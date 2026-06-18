# =============================================================================
# Theme.Animation.ps1
# Animated spinners, step tracking, shimmer, themed progress bars, and grids.
# Dot-sourced by Dotbot.Theme.psm1 so the helpers share its $script:Theme.
# Inspired by FxConsole — re-implemented natively with no external dependency.
# =============================================================================

# -----------------------------------------------------------------------------
# Spinner and bullet libraries
# -----------------------------------------------------------------------------

$script:DotbotSpinners = @{
    bars      = @([char]0x2581,[char]0x2582,[char]0x2583,[char]0x2584,[char]0x2585,[char]0x2586,[char]0x2587,[char]0x2588,[char]0x2587,[char]0x2586,[char]0x2585,[char]0x2584,[char]0x2583,[char]0x2581)
    braille   = @([char]0x280B,[char]0x2819,[char]0x2839,[char]0x2838,[char]0x283C,[char]0x2834,[char]0x2826,[char]0x2827,[char]0x2807,[char]0x280F)
    orbit     = @([char]0x2801,[char]0x2808,[char]0x2810,[char]0x2820,[char]0x2880,[char]0x2840,[char]0x2804,[char]0x2802)
    dots      = @([char]0x2808,[char]0x2800,[char]0x2801,[char]0x2800)
    arrows    = @([char]0x2190,[char]0x2196,[char]0x2191,[char]0x2197,[char]0x2192,[char]0x2198,[char]0x2193,[char]0x2199)
    triangles = @([char]0x25E2,[char]0x25E3,[char]0x25E4,[char]0x25E5)
    quarters  = @([char]0x2596,[char]0x2598,[char]0x259D,[char]0x2597)
    pulse     = @([char]0x25E1,[char]0x2299,[char]0x25E0)
    classic   = @('-','\','|','/')
    circle    = @([char]0x25D0,[char]0x25D3,[char]0x25D1,[char]0x25D2)
    arc       = @([char]0x25DC,[char]0x25DD,[char]0x25DE,[char]0x25DF)
    bounce    = @([char]0x2801,[char]0x2802,[char]0x2804,[char]0x2840,[char]0x2804,[char]0x2802)
    pipe      = @([char]0x2524,[char]0x2518,[char]0x2534,[char]0x2514,[char]0x251C,[char]0x250C,[char]0x252C,[char]0x2510)
}

$script:DotbotBulletSets = @{
    scope   = @{ Pending = [char]0x25CB; Done = [char]0x25C9; Sub = '-' }
    check   = @{ Pending = [char]0x25CB; Done = [char]0x2713; Sub = [char]0x25B8 }
    diamond = @{ Pending = [char]0x25C7; Done = [char]0x25C6; Sub = [char]0x25B9 }
    square  = @{ Pending = [char]0x25A1; Done = [char]0x25A0; Sub = [char]0x25AA }
    circle  = @{ Pending = [char]0x25CB; Done = [char]0x25CF; Sub = [char]0x25E6 }
    star    = @{ Pending = [char]0x2606; Done = [char]0x2605; Sub = [char]0x00B7 }
    arrow   = @{ Pending = [char]0x25B7; Done = [char]0x25B6; Sub = [char]0x25B8 }
    minimal = @{ Pending = [char]0x00B7; Done = [char]0x2713; Sub = '-' }
}

# Defaults align with dotbot's CRT/amber aesthetic — bars + scope.
$script:DotbotSpinChars = $script:DotbotSpinners['bars']
$script:DotbotBullets   = $script:DotbotBulletSets['scope']

# Per-activity stopwatches for Write-DotbotProgress timing.
$script:DotbotProgressTimers = @{}

# -----------------------------------------------------------------------------
# Internal helpers (not exported)
# -----------------------------------------------------------------------------

function Get-DotbotBufferWidth {
    # [Console]::BufferWidth returns 0 in non-TTY contexts (CI, pipes,
    # captured stdout). Fall back to 120 so PadRight callers never receive
    # a negative width.
    try {
        $w = [Console]::BufferWidth
        if ($w -lt 2) { 120 } else { $w }
    } catch { 120 }
}

function Convert-DotbotHsvToRgb {
    param([double]$H, [double]$S, [double]$V)
    $H = $H % 360
    $c = $V * $S
    $x = $c * (1 - [Math]::Abs(($H / 60) % 2 - 1))
    $m = $V - $c
    switch ([int]($H / 60)) {
        0       { $r = $c; $g = $x; $b = 0 }
        1       { $r = $x; $g = $c; $b = 0 }
        2       { $r = 0;  $g = $c; $b = $x }
        3       { $r = 0;  $g = $x; $b = $c }
        4       { $r = $x; $g = 0;  $b = $c }
        default { $r = $c; $g = 0;  $b = $x }
    }
    @([int](($r + $m) * 255), [int](($g + $m) * 255), [int](($b + $m) * 255))
}

function Get-DotbotThemeRgb {
    <#
    .SYNOPSIS
    Extract the RGB triple of a theme color by parsing its ANSI escape sequence.
    Falls back to amber if the color is unknown or the escape can't be parsed.
    #>
    param([string]$ColorName)
    $ansi = $script:Theme[$ColorName]
    if ($ansi -and $ansi -match '38;2;(\d+);(\d+);(\d+)') {
        return @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
    return @(232, 160, 48)
}

function Write-DotbotShimmerFrame {
    param(
        [string]$Text,
        [string]$Prefix,
        [int]$Frame,
        [double]$Intensity,
        [int]$BaseR, [int]$BaseG, [int]$BaseB,
        [int]$AccR,  [int]$AccG,  [int]$AccB,
        [bool]$Rainbow,
        [int]$Pad
    )

    $line    = [System.Text.StringBuilder]::new()
    $flicker = 0.96 + (Get-Random -Minimum 0 -Maximum 5) / 100.0
    $s       = $script:DotbotSpinChars[$Frame % $script:DotbotSpinChars.Length]
    $pulse   = 0.85 + 0.15 * [Math]::Sin($Frame * 0.5)

    if ($Rainbow) {
        $c = Convert-DotbotHsvToRgb -H ($Frame * 12 % 360) -S 0.85 -V ($pulse * $Intensity)
        $sr = $c[0]; $sg = $c[1]; $sb = $c[2]
    } else {
        $sr = [int][Math]::Min(255, [int]($AccR * $pulse * $Intensity))
        $sg = [int][Math]::Min(255, [int]($AccG * $pulse * $Intensity))
        $sb = [int][Math]::Min(255, [int]($AccB * $pulse * $Intensity))
    }
    [void]$line.Append("$([char]27)[38;2;${sr};${sg};${sb}m${Prefix} $s $([char]27)[0m")

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $wave = [Math]::Sin(($i * 0.4) + ($Frame * 0.15))
        $glow = (0.78 + 0.22 * $wave) * $flicker * $Intensity
        if ($Rainbow) {
            $c = Convert-DotbotHsvToRgb -H (($i * 18 + $Frame * 6) % 360) -S 0.85 -V $glow
            $cr = $c[0]; $cg = $c[1]; $cb = $c[2]
        } else {
            $cr = [int][Math]::Min(255, $BaseR * $glow)
            $cg = [int][Math]::Min(255, $BaseG * $glow)
            $cb = [int][Math]::Min(255, $BaseB * $glow)
        }
        [void]$line.Append("$([char]27)[38;2;${cr};${cg};${cb}m$($Text[$i])")
    }
    [void]$line.Append("$([char]27)[0m".PadRight($Pad))
    [Console]::Write("`r$($line.ToString())")
}

# -----------------------------------------------------------------------------
# Public: spinner and bullet management
# -----------------------------------------------------------------------------

function Get-DotbotSpinner {
    <#
    .SYNOPSIS
    List available spinner styles (id + character preview).
    #>
    $script:DotbotSpinners.Keys | Sort-Object | ForEach-Object {
        [PSCustomObject]@{
            Id      = $_
            Preview = ($script:DotbotSpinners[$_] -join ' ')
        }
    }
}

function Set-DotbotSpinner {
    <#
    .SYNOPSIS
    Set the active spinner style by name. Unknown names fall back to 'bars'.
    .EXAMPLE
    Set-DotbotSpinner braille
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    if ($script:DotbotSpinners.ContainsKey($Name)) {
        $script:DotbotSpinChars = $script:DotbotSpinners[$Name]
    } else {
        $script:DotbotSpinChars = $script:DotbotSpinners['bars']
    }
}

function Get-DotbotBullet {
    <#
    .SYNOPSIS
    List available bullet styles for step markers.
    #>
    $script:DotbotBulletSets.Keys | Sort-Object | ForEach-Object {
        $b = $script:DotbotBulletSets[$_]
        [PSCustomObject]@{
            Id      = $_
            Pending = $b.Pending
            Done    = $b.Done
            Sub     = $b.Sub
        }
    }
}

function Set-DotbotBullet {
    <#
    .SYNOPSIS
    Set the active bullet set by name. Unknown names fall back to 'scope'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )
    if ($script:DotbotBulletSets.ContainsKey($Name)) {
        $script:DotbotBullets = $script:DotbotBulletSets[$Name]
    } else {
        $script:DotbotBullets = $script:DotbotBulletSets['scope']
    }
}

# -----------------------------------------------------------------------------
# Public: inline color composition
# -----------------------------------------------------------------------------

function Format-Phosphor {
    <#
    .SYNOPSIS
    Return a theme-colored string for inline composition. Companion to Write-Phosphor.
    .EXAMPLE
    "$(Format-Phosphor 'Status:' Muted) $(Format-Phosphor 'Ready' Success)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [Parameter(Position = 1)][string]$Color = 'Primary'
    )
    $c = $script:Theme[$Color]
    if (-not $c) { $c = $script:Theme['Primary'] }
    "${c}${Text}$($script:Theme.Reset)"
}

# -----------------------------------------------------------------------------
# Public: step tracking
# -----------------------------------------------------------------------------

function Write-Step {
    <#
    .SYNOPSIS
    Write a process step: in-progress, done, or sub-step.
    .DESCRIPTION
    Renders a single themed step line that overwrites the current cursor
    column. Pair with Complete-Section to rewrite a parent header as done
    once its sub-steps finish.
    .PARAMETER Text
    The step description.
    .PARAMETER Prefix
    Optional left-side prefix (e.g. extra indent for sub-steps).
    .PARAMETER Sub
    Render as a sub-step (Secondary color, sub-bullet marker).
    .PARAMETER Done
    Render as a completed step (Success color, done-bullet marker).
    .PARAMETER Color
    Override the theme color for the marker and text.
    .EXAMPLE
    Write-Step 'INSTALL PACKAGES'
    Write-Step 'express@4.18' -Sub
    Write-Step 'INSTALL PACKAGES' -Done
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [string]$Prefix = '',
        [switch]$Sub,
        [switch]$Done,
        [string]$Color
    )

    if ($Sub) {
        $colorName = if ($Color) { $Color } else { 'Secondary' }
        $marker    = $script:DotbotBullets.Sub
    } elseif ($Done) {
        $colorName = if ($Color) { $Color } else { 'Success' }
        $marker    = $script:DotbotBullets.Done
    } else {
        $colorName = if ($Color) { $Color } else { 'Primary' }
        $marker    = $script:DotbotBullets.Pending
    }

    $c = $script:Theme[$colorName]
    if (-not $c) { $c = $script:Theme['Primary'] }
    $r = $script:Theme.Reset
    $w = Get-DotbotBufferWidth

    [Console]::Write("`r${c}${Prefix} ${marker} ${Text}${r}".PadRight($w - 1))
    [Console]::WriteLine()
}

function Complete-Section {
    <#
    .SYNOPSIS
    Rewrite a previously printed section header as done, in-place.
    .DESCRIPTION
    Walks the cursor up past N sub-step lines, rewrites the header with
    Write-Step -Done, then walks back down. Use this after a group of
    sub-steps has finished so the parent header switches to its
    completed marker.
    .EXAMPLE
    Write-Step 'INSTALL PACKAGES'
    Write-Step 'express' -Sub
    Write-Step 'lodash'  -Sub
    Complete-Section 'INSTALL PACKAGES' -SubCount 2
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Header,
        [Parameter(Mandatory)][int]$SubCount
    )
    [Console]::Write("$([char]27)[$($SubCount + 1)A")
    Write-Step -Text $Header -Done
    [Console]::Write("$([char]27)[${SubCount}B")
}

# -----------------------------------------------------------------------------
# Public: shimmer animation + background job
# -----------------------------------------------------------------------------

function Write-Shimmer {
    <#
    .SYNOPSIS
    Animated decorative shimmer for a fixed number of frames.
    .PARAMETER Text
    The line text to shimmer.
    .PARAMETER Frames
    Number of animation frames. Each frame is ~55ms.
    .PARAMETER Prefix
    Left-side prefix (e.g. indent).
    .PARAMETER Intensity
    Brightness scalar (0.0–1.0). Lower values are subtler.
    .PARAMETER Color
    Theme color name for the base glow.
    .PARAMETER Spinner
    Override the active spinner style for this call only.
    .EXAMPLE
    Write-Shimmer 'Resolving providers' -Frames 30 -Intensity 0.6
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [int]$Frames = 40,
        [string]$Prefix = '',
        [double]$Intensity = 1.0,
        [string]$Color = 'Primary',
        [string]$Spinner
    )

    $savedSpinChars = $null
    if ($Spinner -and $script:DotbotSpinners.ContainsKey($Spinner)) {
        $savedSpinChars = $script:DotbotSpinChars
        $script:DotbotSpinChars = $script:DotbotSpinners[$Spinner]
    }

    $rgb = Get-DotbotThemeRgb $Color
    $acc = Get-DotbotThemeRgb 'Secondary'
    $pad = [Math]::Min((Get-DotbotBufferWidth) - 1, $Text.Length + $Prefix.Length + 8)

    try {
        for ($f = 0; $f -lt $Frames; $f++) {
            Write-DotbotShimmerFrame -Text $Text -Prefix $Prefix -Frame $f -Intensity $Intensity `
                -BaseR $rgb[0] -BaseG $rgb[1] -BaseB $rgb[2] `
                -AccR  $acc[0] -AccG  $acc[1] -AccB  $acc[2] `
                -Rainbow $false -Pad $pad
            Start-Sleep -Milliseconds 55
        }
    } finally {
        if ($savedSpinChars) { $script:DotbotSpinChars = $savedSpinChars }
    }
}

function Invoke-PhosphorJob {
    <#
    .SYNOPSIS
    Run a scriptblock in a background runspace while a shimmer animation plays.
    .DESCRIPTION
    Returns the scriptblock output once it completes. The runspace inherits the
    caller's working directory and silences native Write-Progress so it cannot
    flicker through the shimmer.

    Runspaces don't share the caller's variable scope, and $using: isn't wired
    up here (we don't use the remoting transport). Pass closure variables via
    -Variables, which seeds them as runspace-scope variables before the
    scriptblock runs — reference them as plain $Foo inside.
    .PARAMETER Text
    Label shown alongside the shimmer.
    .PARAMETER ScriptBlock
    Work to perform.
    .PARAMETER Variables
    Hashtable of values to surface as variables inside the runspace.
    .EXAMPLE
    $count = Invoke-PhosphorJob 'Counting commits' { git rev-list --count HEAD }
    Write-Step "Counting commits  $(Format-Phosphor $count Muted)" -Done
    .EXAMPLE
    Invoke-PhosphorJob 'Copying tree' -Variables @{ Src = $src; Dst = $dst } {
        Copy-Item $Src $Dst -Recurse -Force
    }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [Parameter(Mandatory, Position = 1)][scriptblock]$ScriptBlock,
        [hashtable]$Variables,
        [string]$Prefix = '',
        [double]$Intensity = 0.55,
        [string]$Color = 'Primary'
    )

    $rgb = Get-DotbotThemeRgb $Color
    $acc = Get-DotbotThemeRgb 'Secondary'
    $pad = [Math]::Min((Get-DotbotBufferWidth) - 1, $Text.Length + $Prefix.Length + 8)

    # Wrap the user scriptblock so the runspace silences Write-Progress and
    # inherits the caller's working directory. Runspaces don't inherit
    # $ProgressPreference or the location stack from the parent.
    $callerDir = (Get-Location).ProviderPath
    $wrapped = [scriptblock]::Create(@"
`$ProgressPreference = 'SilentlyContinue'
Set-Location -LiteralPath '$callerDir'
& { $ScriptBlock }
"@)

    # Seed an initial session state with caller-supplied variables. This is
    # how we replace $using: — values flow in by name, not by capture.
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if ($Variables) {
        foreach ($k in $Variables.Keys) {
            $entry = [System.Management.Automation.Runspaces.SessionStateVariableEntry]::new(
                [string]$k, $Variables[$k], '')
            $iss.Variables.Add($entry)
        }
    }

    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($wrapped)
    $handle = $ps.BeginInvoke()

    try {
        $f = 0
        while (-not $handle.IsCompleted) {
            Write-DotbotShimmerFrame -Text $Text -Prefix $Prefix -Frame $f -Intensity $Intensity `
                -BaseR $rgb[0] -BaseG $rgb[1] -BaseB $rgb[2] `
                -AccR  $acc[0] -AccG  $acc[1] -AccB  $acc[2] `
                -Rainbow $false -Pad $pad
            Start-Sleep -Milliseconds 55
            $f++
        }

        $result = $ps.EndInvoke($handle)
        if ($ps.HadErrors) {
            # Surface runspace errors through the themed channel so the hygiene
            # scan stays clean; the parent Write-Host wrapper still lands on
            # stderr-equivalent visibility.
            $ps.Streams.Error | ForEach-Object { Write-Phosphor "$_" 'Red' }
        }
        return $result
    } finally {
        $ps.Dispose()
        $rs.Dispose()
    }
}

# -----------------------------------------------------------------------------
# Public: themed progress bar
# -----------------------------------------------------------------------------

function Write-DotbotProgress {
    <#
    .SYNOPSIS
    Render a themed in-place progress bar with elapsed time and ETA.
    .DESCRIPTION
    Draws an in-place progress bar using block characters that respects the
    active theme. Tracks elapsed time per activity automatically and estimates
    remaining time from the current percentage. Call with -Complete to clear
    the bar cleanly.
    .PARAMETER Activity
    Label shown before the bar. Also the key used to track per-bar timers.
    .PARAMETER Percent
    Current progress 0–100.
    .PARAMETER Status
    Optional trailing status text (e.g. "42 of 100 files").
    .PARAMETER Complete
    Clear the activity's bar and drop its timer.
    .PARAMETER BarColor
    Theme color for the filled portion of the bar.
    .PARAMETER TrackColor
    Theme color for the empty portion of the bar.
    .PARAMETER Width
    Width of the bar in characters. Defaults to 30.
    .EXAMPLE
    1..100 | ForEach-Object {
        Write-DotbotProgress -Activity 'Downloading' -Percent $_ -Status "$_ of 100 files"
        Start-Sleep -Milliseconds 30
    }
    Write-DotbotProgress -Activity 'Downloading' -Complete
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Activity,
        [Parameter(Position = 1)][ValidateRange(0,100)][int]$Percent = 0,
        [string]$Status,
        [switch]$Complete,
        [string]$BarColor   = 'Primary',
        [string]$TrackColor = 'Bezel',
        [int]$Width = 30
    )

    if (-not $script:DotbotProgressTimers) { $script:DotbotProgressTimers = @{} }

    if ($Complete) {
        $w = Get-DotbotBufferWidth
        [Console]::Write("`r$(' ' * ($w - 1))`r")
        $script:DotbotProgressTimers.Remove($Activity)
        return
    }

    if (-not $script:DotbotProgressTimers.ContainsKey($Activity)) {
        $script:DotbotProgressTimers[$Activity] = [System.Diagnostics.Stopwatch]::StartNew()
    }
    $sw = $script:DotbotProgressTimers[$Activity]

    $bc = $script:Theme[$BarColor];   if (-not $bc) { $bc = $script:Theme['Primary'] }
    $tc = $script:Theme[$TrackColor]; if (-not $tc) { $tc = $script:Theme['Bezel'] }
    $mc = $script:Theme['Muted'];     if (-not $mc) { $mc = $tc }
    $pc = $script:Theme['Primary'];   if (-not $pc) { $pc = $bc }
    $r  = $script:Theme.Reset

    $filled = [Math]::Floor($Width * $Percent / 100)
    $empty  = $Width - $filled
    $bar = "${bc}$([string]::new([char]0x2588, $filled))${tc}$([string]::new([char]0x2591, $empty))${r}"

    $elapsed = $sw.Elapsed
    $elapsedStr = '{0:mm\:ss}' -f $elapsed
    $etaStr = ''
    if ($Percent -gt 0 -and $Percent -lt 100) {
        $totalEstimate = [TimeSpan]::FromTicks($elapsed.Ticks * 100 / $Percent)
        $remaining = $totalEstimate - $elapsed
        if ($remaining.TotalSeconds -ge 0) {
            $etaStr = " ${mc}eta ${r}${pc}$('{0:mm\:ss}' -f $remaining)${r}"
        }
    }

    $percentStr = "${pc}$($Percent.ToString().PadLeft(3))%${r}"
    $statusStr  = if ($Status) { " ${mc}${Status}${r}" } else { '' }
    $line = "${mc}${Activity}${r} ${bar} ${percentStr} ${mc}${elapsedStr}${r}${etaStr}${statusStr}"

    $w = Get-DotbotBufferWidth
    $pad = [Math]::Max(0, $w - 1 - (Get-VisualWidth $line))
    [Console]::Write("`r${line}$(' ' * $pad)")
}

function Invoke-DotbotProgress {
    <#
    .SYNOPSIS
    Pipeline wrapper that drives Write-DotbotProgress as items flow through.
    .DESCRIPTION
    Counts items in the pipeline and renders a themed progress bar. Without a
    -Total, the bar shows a counter only.
    .EXAMPLE
    $files | Invoke-DotbotProgress -Activity 'Copying' -Total $files.Count -ScriptBlock {
        Copy-Item $_ $dest
    }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Activity,
        [scriptblock]$ScriptBlock,
        [int]$Total = 0,
        [Parameter(ValueFromPipeline)][object]$InputObject
    )

    begin { $count = 0 }

    process {
        $count++
        if ($Total -gt 0) {
            $pct = [Math]::Min(100, [int]([Math]::Floor($count * 100 / $Total)))
            Write-DotbotProgress -Activity $Activity -Percent $pct -Status "$count of $Total"
        } else {
            Write-DotbotProgress -Activity $Activity -Percent 0 -Status "$count items"
        }
        if ($ScriptBlock) {
            $InputObject | ForEach-Object $ScriptBlock
        } else {
            $InputObject
        }
    }

    end { Write-DotbotProgress -Activity $Activity -Complete }
}

# -----------------------------------------------------------------------------
# Public: multi-column grid
# -----------------------------------------------------------------------------

function Write-Grid {
    <#
    .SYNOPSIS
    Borderless multi-column layout for dashboard-style output.
    .DESCRIPTION
    Items flow left-to-right, top-to-bottom. Column widths are computed from
    content using the existing ANSI-aware Get-VisualWidth, so cells may
    contain themed strings produced by Format-Phosphor.
    .EXAMPLE
    Write-Grid -Columns 3 -Items @(
        (Format-Phosphor 'CPU: 42%' Primary)
        (Format-Phosphor 'MEM: 68%' Warning)
        (Format-Phosphor 'DISK: 91%' Error)
    )
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyCollection()][string[]]$Items,
        [int]$Columns = 3,
        [int]$Gutter  = 4,
        [int]$Indent  = 2
    )

    if ($Items.Count -eq 0) { return }
    $Columns = [Math]::Min($Columns, $Items.Count)

    $colWidths = [int[]]::new($Columns)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $col = $i % $Columns
        $w = Get-VisualWidth $Items[$i]
        if ($w -gt $colWidths[$col]) { $colWidths[$col] = $w }
    }

    $indentStr = ' ' * $Indent
    $gutterStr = ' ' * $Gutter
    $rowCount = [Math]::Ceiling($Items.Count / $Columns)

    for ($row = 0; $row -lt $rowCount; $row++) {
        $cells = for ($col = 0; $col -lt $Columns; $col++) {
            $idx = $row * $Columns + $col
            if ($idx -lt $Items.Count) {
                Get-PaddedText -Text $Items[$idx] -Width $colWidths[$col]
            }
        }
        [Console]::WriteLine("${indentStr}$($cells -join $gutterStr)")
    }
}

# -----------------------------------------------------------------------------
# Public: console wrapper
# -----------------------------------------------------------------------------

function Invoke-PhosphorScript {
    <#
    .SYNOPSIS
    Run a scriptblock with the console set up for themed output.
    .DESCRIPTION
    Forces UTF-8 output, hides the cursor, and silences native Write-Progress
    so it cannot tear through shimmer/step animations. Restores all three on
    exit, including when the scriptblock throws. Safe in non-TTY contexts:
    cursor visibility failures are swallowed.
    .EXAMPLE
    Invoke-PhosphorScript {
        Write-Banner 'Installer'
        Invoke-PhosphorJob 'Copying files' { Copy-Item ... }
        Write-Step 'Copying files' -Done
    }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock
    )

    $savedOutEnc      = [Console]::OutputEncoding
    $savedScriptEnc   = $script:OutputEncoding
    $savedProgressPref = $global:ProgressPreference

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $script:OutputEncoding   = [System.Text.Encoding]::UTF8
    $global:ProgressPreference = 'SilentlyContinue'

    # CursorVisible throws in non-TTY contexts (CI, redirected output).
    # Swallow — animations still work, the cursor just stays visible.
    try { [Console]::CursorVisible = $false } catch { }

    try {
        & $ScriptBlock
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
        [Console]::OutputEncoding = $savedOutEnc
        $script:OutputEncoding   = $savedScriptEnc
        $global:ProgressPreference = $savedProgressPref
    }
}
