# =============================================================================
# Platform-Functions.psm1
# Cross-platform helper functions for dotbot installation
# =============================================================================

# Initialize platform detection variables
$script:IsWindows = $false
$script:IsMacOS = $false
$script:IsLinux = $false

# ── Theme colors (amber/green palette matching DotbotTheme) ──
# Use ANSI RGB escape codes for consistent color across platforms
$script:C = @{
    Primary    = "`e[38;2;232;160;48m"     # Amber  #e8a030
    PrimaryDim = "`e[38;2;184;120;32m"     # Dim amber  #b87820
    Success    = "`e[38;2;0;255;136m"      # Green  #00ff88
    SuccessDim = "`e[38;2;0;170;92m"       # Dim green  #00aa5c
    Error      = "`e[38;2;209;105;105m"    # Red  #d16969
    Warning    = "`e[38;2;232;160;48m"     # Amber (same as primary)
    Info       = "`e[38;2;95;179;179m"     # Cyan  #5fb3b3
    Muted      = "`e[38;2;136;136;153m"    # Gray  #888899
    Bezel      = "`e[38;2;58;59;72m"       # Chrome  #3a3b48
    Reset      = "`e[0m"
}

function Initialize-PlatformVariables {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $script:IsWindows = $global:IsWindows
        $script:IsMacOS = $global:IsMacOS
        $script:IsLinux = $global:IsLinux
    } else {
        # PowerShell 5.x is Windows-only
        $script:IsWindows = $true
        $script:IsMacOS = $false
        $script:IsLinux = $false
    }
}

function Get-PlatformName {
    Initialize-PlatformVariables
    if ($script:IsWindows) { return "Windows" }
    if ($script:IsMacOS) { return "macOS" }
    if ($script:IsLinux) { return "Linux" }
    return "Unknown"
}

function Add-ToPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [switch]$DryRun
    )
    
    Initialize-PlatformVariables
    
    if ($script:IsWindows) {
        Add-ToWindowsPath -Directory $Directory -DryRun:$DryRun
    } else {
        Add-ToUnixPath -Directory $Directory -DryRun:$DryRun
    }
}

function Add-ToWindowsPath {
    param(
        [string]$Directory,
        [switch]$DryRun
    )
    
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    if ($currentPath -split ";" -contains $Directory) {
        Write-Success "Already in PATH: $Directory"
        return
    }
    
    if ($DryRun) {
        Write-DotbotWarning "Would add to PATH: $Directory"
        return
    }
    
    $newPath = "$currentPath;$Directory"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    
    # Also update current session
    $env:Path = "$env:Path;$Directory"
    
    Write-Success "Added to PATH: $Directory"
    Write-DotbotWarning "Restart your terminal for changes to take effect"
}

function Add-ToUnixPath {
    param(
        [string]$Directory,
        [switch]$DryRun
    )
    
    # Determine shell profile file
    $profileFiles = @()
    
    if ($env:SHELL -like "*zsh*") {
        $profileFiles += Join-Path $HOME ".zshenv"
        $profileFiles += Join-Path $HOME ".zshrc"
    }
    if ($env:SHELL -like "*bash*" -or $profileFiles.Count -eq 0) {
        $profileFiles += Join-Path $HOME ".bashrc"
        $profileFiles += Join-Path $HOME ".bash_profile"
    }
    $profileFiles += Join-Path $HOME ".profile"
    
    $exportLine = "export PATH=`"$Directory`:`$PATH`""
    
    $addedToAny = $false
    foreach ($profileFile in $profileFiles) {
        if (Test-Path $profileFile) {
            $content = Get-Content $profileFile -Raw -ErrorAction SilentlyContinue
            
            if ($content -and $content.Contains($Directory)) {
                Write-Success "Already in $profileFile"
                $addedToAny = $true
                continue
            }
            
            if ($DryRun) {
                Write-DotbotWarning "Would add to $profileFile"
                $addedToAny = $true
                continue
            }
            
            Add-Content -Path $profileFile -Value "`n# dotbot`n$exportLine"
            Write-Success "Added to $profileFile"
            $addedToAny = $true
        }
    }
    
    # If no profile files existed, create ~/.profile
    if (-not $addedToAny) {
        $fallbackProfile = Join-Path $HOME ".profile"
        if ($DryRun) {
            Write-DotbotWarning "Would create $fallbackProfile"
        } else {
            Set-Content -Path $fallbackProfile -Value "# dotbot`n$exportLine"
            Write-Success "Created $fallbackProfile"
        }
    }
    
    # Show shell-appropriate reload hint
    if ($env:SHELL -like "*zsh*") {
        Write-DotbotWarning "Run 'source ~/.zshrc' or restart your terminal"
    } elseif ($env:SHELL -like "*bash*") {
        Write-DotbotWarning "Run 'source ~/.bashrc' or restart your terminal"
    } else {
        Write-DotbotWarning "Run 'source ~/.profile' or restart your terminal"
    }
}

function Set-ExecutablePermission {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    
    Initialize-PlatformVariables
    
    if (-not $script:IsWindows) {
        if (Test-Path $FilePath) {
            & chmod +x $FilePath 2>$null
        }
    }
    # Windows doesn't need chmod - files are executable by default
}

function Write-Success {
    param([string]$Message)
    $c = $script:C
    Write-Host "$($c.Success)  ✓ $Message$($c.Reset)"
}

function Write-DotbotWarning {
    param([string]$Message)
    $c = $script:C
    Write-Host "$($c.Warning)  ⚠ $Message$($c.Reset)"
}

function Write-DotbotError {
    param([string]$Message)
    $c = $script:C
    Write-Host "$($c.Error)  ✗ $Message$($c.Reset)"
}

function Write-DotbotBanner {
    param(
        [string]$Title = "D O T B O T",
        [string]$Subtitle = ""
    )
    $c = $script:C
    $line = '═' * 55
    Write-Host ""
    Write-Host "$($c.Primary)$line$($c.Reset)"
    Write-Host ""
    Write-Host "$($c.Primary)    $Title$($c.Reset)"
    if ($Subtitle) {
        Write-Host "$($c.PrimaryDim)    $Subtitle$($c.Reset)"
    }
    Write-Host ""
    Write-Host "$($c.Primary)$line$($c.Reset)"
    Write-Host ""
}

function Write-DotbotSection {
    param([string]$Title)
    $c = $script:C
    Write-Host "$($c.Primary)  $Title$($c.Reset)"
    Write-Host "$($c.Bezel)  ────────────────────────────────────────────$($c.Reset)"
    Write-Host ""
}

function Write-DotbotLabel {
    param(
        [string]$Label,
        [string]$Value,
        [string]$ValueType = 'Default'
    )
    $c = $script:C
    $vc = switch ($ValueType) {
        'Success' { $c.Success }
        'Error'   { $c.Error }
        'Warning' { $c.Warning }
        'Info'    { $c.Info }
        default   { $c.Primary }
    }
    Write-Host "$($c.PrimaryDim)    $Label$($c.Reset)$vc$Value$($c.Reset)"
}

function Write-DotbotCommand {
    param([string]$Command)
    $c = $script:C
    Write-Host "$($c.Muted)    $Command$($c.Reset)"
}

function Write-BlankLine {
    Write-Host ""
}

function Read-DotbotConfirmation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [bool]$Default = $false
    )

    if ([Environment]::GetEnvironmentVariable('DOTBOT_ASSUME_YES') -match '^(?i:1|true|yes|y)$') {
        Write-DotbotCommand "$Message yes (-y)"
        return $true
    }

    $c = $script:C
    $suffix = if ($Default) { ' [Y/n] ' } else { ' [y/N] ' }
    [Console]::Write("$($c.Warning)  ? $Message$suffix$($c.Reset)")
    $answer = [Console]::ReadLine()

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }

    return $answer.Trim() -match '^(?i:y|yes)$'
}

function Get-UrlOpenCommand {
    param(
        [Nullable[bool]]$IsWindowsOverride = $null,
        [Nullable[bool]]$IsMacOSOverride = $null,
        [Nullable[bool]]$IsLinuxOverride = $null,
        # Probe used to decide whether a candidate is available. Tests inject
        # a deterministic filter so a binary that happens to be installed on
        # the host (e.g. `sensible-browser` on most Debian/Fedora boxes) does
        # not shadow the candidate ordering they want to exercise.
        [scriptblock]$CommandTester = $null
    )

    $useOverrides = ($null -ne $IsWindowsOverride) -or ($null -ne $IsMacOSOverride) -or ($null -ne $IsLinuxOverride)

    if ($useOverrides) {
        $isWindows = [bool]$IsWindowsOverride
        $isMacOS = [bool]$IsMacOSOverride
        $isLinux = [bool]$IsLinuxOverride
    } else {
        Initialize-PlatformVariables
        $isWindows = $script:IsWindows
        $isMacOS = $script:IsMacOS
        $isLinux = $script:IsLinux
    }

    if ($isWindows) {
        return 'Start-Process'
    }

    $candidates = @()
    if ($isMacOS) {
        $candidates += 'open'
    }
    if ($isLinux -or (-not $isWindows -and -not $isMacOS)) {
        # Prefer Linux-native browser launchers, but allow Windows interop when
        # that's the only opener exposed by the current environment.
        $candidates += 'xdg-open', 'gio', 'sensible-browser', 'powershell.exe', 'cmd.exe'
    }

    if (-not $CommandTester) {
        $CommandTester = { param($n) [bool](Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1) }
    }

    foreach ($candidate in $candidates) {
        if (& $CommandTester $candidate) {
            return $candidate
        }
    }

    return $null
}

function Invoke-UrlOpenCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    switch ($Command) {
        'Start-Process' {
            Start-Process $Url
            return
        }
        'gio' {
            & gio open $Url 2>$null
            return
        }
        'powershell.exe' {
            $escapedUrl = $Url.Replace("'", "''")
            & powershell.exe -NoProfile -Command "Start-Process '$escapedUrl'" 2>$null
            return
        }
        'cmd.exe' {
            & cmd.exe /c start '""' ('"{0}"' -f $Url) 2>$null
            return
        }
        default {
            & $Command $Url 2>$null
            return
        }
    }
}

function Open-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    $command = Get-UrlOpenCommand
    if (-not $command) {
        throw "Could not find a URL opener for '$Url'. Tried platform defaults plus xdg-open, gio, sensible-browser, powershell.exe, and cmd.exe."
    }

    Invoke-UrlOpenCommand -Command $command -Url $Url
}

Export-ModuleMember -Function @(
    'Initialize-PlatformVariables',
    'Get-PlatformName',
    'Add-ToPath',
    'Set-ExecutablePermission',
    'Open-Url',
    'Write-Success',
    'Write-DotbotWarning',
    'Write-DotbotError',
    'Write-DotbotBanner',
    'Write-DotbotSection',
    'Write-DotbotLabel',
    'Write-DotbotCommand',
    'Write-BlankLine',
    'Read-DotbotConfirmation'
)
