# DevLayout.psm1
# Window layout management for development environments
# Adapted from DevLayout project - Windows-only functionality

# Platform check - Win32 APIs only work on Windows
$script:IsWindowsPlatform = $IsWindows -or ($env:OS -eq "Windows_NT")

# Internal status writer (avoids dependency on Common.ps1)
function Write-LayoutStatus {
    param(
        [string]$Message,
        [ValidateSet("Success", "Info", "Warning", "Error", "Neutral")]
        [string]$Type = "Info"
    )
    $prefix = switch ($Type) {
        "Success" { "[OK]" }
        "Info"    { "[--]" }
        "Warning" { "[!!]" }
        "Error"   { "[XX]" }
        "Neutral" { "[  ]" }
    }
    $color = switch ($Type) {
        "Success" { "Green" }
        "Info"    { "Cyan" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Neutral" { "Gray" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# Win32 type definitions (only load on Windows)
if ($script:IsWindowsPlatform) {
    if (-not ([System.Management.Automation.PSTypeName]'Win32DevLayout').Type) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32DevLayout {
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int W, int H, bool repaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    public const uint WM_CLOSE = 0x0010;
    public const uint WM_KEYDOWN = 0x0100;
    public const uint WM_KEYUP = 0x0101;
    public const int VK_F5 = 0x74;
}
"@
    }
    # Separate type for DPI detection (avoids caching issues with main type)
    if (-not ([System.Management.Automation.PSTypeName]'Win32DpiHelper').Type) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32DpiHelper {
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int awareness);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    public const int PROCESS_PER_MONITOR_DPI_AWARE = 2;
}
"@
    }
    # Set process DPI awareness to get accurate monitor DPI values
    try { [Win32DpiHelper]::SetProcessDpiAwareness([Win32DpiHelper]::PROCESS_PER_MONITOR_DPI_AWARE) | Out-Null } catch {}
    Add-Type -AssemblyName System.Windows.Forms
}

# Get DPI scale factor for a screen
function Get-ScreenDpiScale {
    param($Screen)
    try {
        # Get monitor handle from a point on this screen
        $pt = New-Object Win32DpiHelper+POINT
        $pt.X = $Screen.Bounds.X + 10
        $pt.Y = $Screen.Bounds.Y + 10
        $hMonitor = [Win32DpiHelper]::MonitorFromPoint($pt, 0)
        
        $dpiX = [uint32]0
        $dpiY = [uint32]0
        $result = [Win32DpiHelper]::GetDpiForMonitor($hMonitor, 0, [ref]$dpiX, [ref]$dpiY)
        
        if ($result -eq 0 -and $dpiX -gt 0) {
            return [double]$dpiX / 96.0
        }
    } catch {
        # Fall back to 1.0 if DPI detection fails
    }
    return 1.0
}

# Layout definitions: [x%, y%, w%, h%]
$script:Layouts = @{
    "1L-1R" = @{
        terminals = ,@(0, 0, 50, 100)
        browser   = @(50, 0, 50, 100)
    }
    "2L-1R" = @{
        terminals = @(@(0, 0, 50, 50), @(0, 50, 50, 50))
        browser   = @(50, 0, 50, 100)
    }
    "3L-1R" = @{
        terminals = @(@(0, 0, 50, 33), @(0, 33, 50, 33), @(0, 66, 50, 34))
        browser   = @(50, 0, 50, 100)
    }
    "1T-1B" = @{
        terminals = ,@(0, 0, 100, 50)
        browser   = @(0, 50, 100, 50)
    }
    "2T-2B" = @{
        terminals = @(@(0, 0, 50, 50), @(50, 0, 50, 50))
        browser   = @(0, 50, 100, 50)
    }
}

function Get-LayoutRect {
    param($Zone, $Screen)
    @{
        X = $Screen.X + [int]($Screen.Width * $Zone[0] / 100)
        Y = $Screen.Y + [int]($Screen.Height * $Zone[1] / 100)
        W = [int]($Screen.Width * $Zone[2] / 100)
        H = [int]($Screen.Height * $Zone[3] / 100)
    }
}

function New-TerminalWindow {
    param($Command, $Zone, $Screen)
    
    $rect = Get-LayoutRect -Zone $Zone -Screen $Screen
    
    # Track by handle - WT reuses process
    $beforeHandles = @(Get-Process WindowsTerminal -EA SilentlyContinue | 
        Where-Object { $_.MainWindowHandle -ne 0 } | 
        Select-Object -Exp MainWindowHandle)
    
    # Write command to temp script to avoid wt escaping issues
    $tempScript = Join-Path $env:TEMP "devlayout-$(New-Guid).ps1"
    
    # Prepend PATH setup to ensure dotnet and other tools are available
    $scriptContent = @"
# Set up PATH for dev tools
`$env:PATH = '$env:PATH'

# Run the actual command
$Command
"@
    Set-Content -Path $tempScript -Value $scriptContent -Encoding UTF8
    
    # -w new forces a new window instead of a tab in existing window
    # -NoProfile skips profile loading for faster startup and no oh-my-posh errors
    Start-Process wt -ArgumentList "-w new pwsh -NoProfile -NoExit -File `"$tempScript`""
    Start-Sleep -Milliseconds 1500
    
    $wt = Get-Process WindowsTerminal -EA SilentlyContinue | 
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowHandle -notin $beforeHandles } | 
        Select-Object -First 1
    
    if ($wt) {
        # Wait a bit more for window to settle
        Start-Sleep -Milliseconds 500
        [Win32DevLayout]::ShowWindow($wt.MainWindowHandle, 9) | Out-Null
        [Win32DevLayout]::MoveWindow($wt.MainWindowHandle, $rect.X, $rect.Y, $rect.W, $rect.H, $true) | Out-Null
        return @{ handle = $wt.MainWindowHandle.ToInt64(); cmd = $Command }
    }
    return $null
}

function New-BrowserWindow {
    param($Url, $Zone, $Screen, $DpiScale = 1.0)
    
    $rect = Get-LayoutRect -Zone $Zone -Screen $Screen
    
    # MoveWindow behavior with DPI-aware processes is complex:
    # - Position (X/Y) uses physical pixels 
    # - Size (W/H) needs logical (scaled) coordinates for Chrome
    $moveX = $rect.X
    $moveY = $rect.Y
    $moveW = [int]($rect.W / $DpiScale)
    $moveH = [int]($rect.H / $DpiScale)
    
    $beforeHandles = @(Get-Process chrome -EA SilentlyContinue | 
        Where-Object { $_.MainWindowHandle -ne 0 } | 
        Select-Object -Exp MainWindowHandle)
    
    Start-Process "chrome.exe" -ArgumentList "--new-window", $Url
    Start-Sleep -Milliseconds 1500
    
    $chrome = Get-Process chrome -EA SilentlyContinue | 
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowHandle -notin $beforeHandles } | 
        Select-Object -First 1
    
    if ($chrome) {
        [Win32DevLayout]::ShowWindow($chrome.MainWindowHandle, 9) | Out-Null
        [Win32DevLayout]::MoveWindow($chrome.MainWindowHandle, $moveX, $moveY, $moveW, $moveH, $true) | Out-Null
        return @{ handle = $chrome.MainWindowHandle.ToInt64(); url = $Url }
    }
    return $null
}

function Open-DevLayout {
    <#
    .SYNOPSIS
        Opens a dev environment with split window layout
    .PARAMETER Monitor
        Monitor index (0-based)
    .PARAMETER Layout
        Layout preset: 1L-1R, 2L-1R, 3L-1R, 1T-1B, 2T-2B
    .PARAMETER Terminals
        Array of commands to run in terminal windows
    .PARAMETER Urls
        Array of URLs to open in browser windows
    .PARAMETER SessionName
        Name for the session (used for cleanup)
    .PARAMETER Quiet
        Suppress console output
    #>
    param(
        [int]$Monitor = 0,
        [ValidateSet("1L-1R", "2L-1R", "3L-1R", "1T-1B", "2T-2B")]
        [string]$Layout = "2L-1R",
        [string[]]$Terminals = @(),
        [string[]]$Urls = @(),
        [string]$SessionName = "default",
        [switch]$Quiet
    )
    
    # Skip on non-Windows
    if (-not $script:IsWindowsPlatform) {
        if (-not $Quiet) {
            Write-LayoutStatus "DevLayout skipped (Windows-only feature)" -Type Neutral
        }
        return @{ session = $SessionName; status = "skipped"; reason = "non-windows" }
    }
    
    $sessionFile = Join-Path $env:TEMP "devlayout-$SessionName.json"
    
    # Check for existing session
    if (Test-Path $sessionFile) {
        if (-not $Quiet) {
            Write-LayoutStatus "Session '$SessionName' already running" -Type Warning
        }
        return @{ session = $SessionName; status = "already_running" }
    }
    
    # Get target monitor
    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($Monitor -ge $screens.Count) {
        if (-not $Quiet) {
            Write-LayoutStatus "Monitor $Monitor not found, using 0" -Type Warning
        }
        $Monitor = 0
    }
    
    # After SetProcessDpiAwareness, WorkingArea returns actual pixel dimensions
    # so we can use them directly with MoveWindow
    $workArea = $screens[$Monitor].WorkingArea
    $dpiScale = Get-ScreenDpiScale -Screen $screens[$Monitor]
    $scr = @{
        X = $workArea.X
        Y = $workArea.Y
        Width = $workArea.Width
        Height = $workArea.Height
    }
    
    if (-not $Quiet) {
        Write-LayoutStatus "Layout: $Layout on monitor $Monitor ($($scr.Width)x$($scr.Height))" -Type Info
    }
    
    # Track opened windows
    $session = @{
        name = $SessionName
        started_at = (Get-Date).ToString("o")
        terminals = [System.Collections.ArrayList]@()
        browsers = [System.Collections.ArrayList]@()
    }
    
    # Launch terminals
    $layoutDef = $script:Layouts[$Layout]
    $termZones = $layoutDef.terminals
    
    for ($i = 0; $i -lt $termZones.Count -and $i -lt $Terminals.Count; $i++) {
        $info = New-TerminalWindow -Command $Terminals[$i] -Zone $termZones[$i] -Screen $scr
        if ($info) { 
            [void]$session.terminals.Add($info)
            if (-not $Quiet) {
                Write-LayoutStatus "Terminal opened" -Type Success
            }
        }
    }
    
    # Launch browsers
    foreach ($url in $Urls) {
        $info = New-BrowserWindow -Url $url -Zone $layoutDef.browser -Screen $scr -DpiScale $dpiScale
        if ($info) { 
            [void]$session.browsers.Add($info)
            if (-not $Quiet) {
                Write-LayoutStatus "Browser opened: $url" -Type Success
            }
        }
    }
    
    # Save session
    $session | ConvertTo-Json -Depth 3 | Set-Content $sessionFile -Encoding UTF8
    
    return @{
        session = $SessionName
        status = "running"
        terminals = $session.terminals.Count
        browsers = $session.browsers.Count
    }
}

function Close-DevLayout {
    <#
    .SYNOPSIS
        Closes windows opened by Open-DevLayout
    .PARAMETER SessionName
        Name of the session to close
    .PARAMETER Quiet
        Suppress console output
    #>
    param(
        [string]$SessionName = "default",
        [switch]$Quiet
    )
    
    # Skip on non-Windows
    if (-not $script:IsWindowsPlatform) {
        return @{ session = $SessionName; status = "skipped"; reason = "non-windows" }
    }
    
    $sessionFile = Join-Path $env:TEMP "devlayout-$SessionName.json"
    
    if (-not (Test-Path $sessionFile)) {
        return @{ session = $SessionName; status = "not_found" }
    }
    
    $session = Get-Content $sessionFile | ConvertFrom-Json
    
    $closedTerminals = 0
    $closedBrowsers = 0
    
    # Close terminals by handle
    foreach ($t in $session.terminals) {
        $handle = [IntPtr]::new($t.handle)
        if ([Win32DevLayout]::IsWindow($handle)) {
            [Win32DevLayout]::PostMessage($handle, [Win32DevLayout]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            $closedTerminals++
            if (-not $Quiet) {
                Write-LayoutStatus "Closed terminal" -Type Success
            }
        }
    }
    
    # Close browsers by handle
    foreach ($b in $session.browsers) {
        $handle = [IntPtr]::new($b.handle)
        if ([Win32DevLayout]::IsWindow($handle)) {
            [Win32DevLayout]::PostMessage($handle, [Win32DevLayout]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            $closedBrowsers++
            if (-not $Quiet) {
                Write-LayoutStatus "Closed browser" -Type Success
            }
        }
    }
    
    # Remove session file
    Remove-Item $sessionFile -Force
    
    return @{
        session = $SessionName
        status = "closed"
        closed_terminals = $closedTerminals
        closed_browsers = $closedBrowsers
    }
}

function Get-DevLayoutMonitors {
    <#
    .SYNOPSIS
        Lists available monitors
    #>
    if (-not $script:IsWindowsPlatform) {
        Write-Host "Monitor listing only available on Windows" -ForegroundColor Yellow
        return @()
    }
    
    $monitors = @()
    $i = 0
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        $monitors += @{
            index = $i
            primary = $_.Primary
            width = $_.Bounds.Width
            height = $_.Bounds.Height
            x = $_.Bounds.X
            y = $_.Bounds.Y
        }
        $i++
    }
    return $monitors
}

function Send-BrowserRefresh {
    <#
    .SYNOPSIS
        Sends F5 (refresh) to browser windows in a session
    .PARAMETER SessionName
        Name of the session containing browser windows
    .PARAMETER Quiet
        Suppress console output
    #>
    param(
        [string]$SessionName = "default",
        [switch]$Quiet
    )
    
    # Skip on non-Windows
    if (-not $script:IsWindowsPlatform) {
        return @{ status = "skipped"; reason = "non-windows" }
    }
    
    $sessionFile = Join-Path $env:TEMP "devlayout-$SessionName.json"
    
    if (-not (Test-Path $sessionFile)) {
        return @{ status = "not_found" }
    }
    
    $session = Get-Content $sessionFile | ConvertFrom-Json
    $refreshed = 0
    
    foreach ($b in $session.browsers) {
        $handle = [IntPtr]::new($b.handle)
        if ([Win32DevLayout]::IsWindow($handle)) {
            # Bring window to foreground and send F5
            [Win32DevLayout]::SetForegroundWindow($handle) | Out-Null
            Start-Sleep -Milliseconds 100
            [Win32DevLayout]::PostMessage($handle, [Win32DevLayout]::WM_KEYDOWN, [IntPtr]::new([Win32DevLayout]::VK_F5), [IntPtr]::Zero) | Out-Null
            [Win32DevLayout]::PostMessage($handle, [Win32DevLayout]::WM_KEYUP, [IntPtr]::new([Win32DevLayout]::VK_F5), [IntPtr]::Zero) | Out-Null
            $refreshed++
            if (-not $Quiet) {
                Write-LayoutStatus "Refreshed browser" -Type Success
            }
        }
    }
    
    return @{
        status = "refreshed"
        count = $refreshed
    }
}

Export-ModuleMember -Function Open-DevLayout, Close-DevLayout, Get-DevLayoutMonitors, Send-BrowserRefresh
