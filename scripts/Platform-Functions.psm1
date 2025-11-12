# =============================================================================
# dotbot Platform Functions Module
# Cross-platform helper functions for OS detection and PATH management
# =============================================================================

# -----------------------------------------------------------------------------
# OS Detection
# -----------------------------------------------------------------------------

function Initialize-PlatformVariables {
    <#
    .SYNOPSIS
    Initializes platform detection variables for cross-platform compatibility.
    
    .DESCRIPTION
    Sets script-level variables for OS detection. PowerShell 6+ has built-in
    $IsWindows, $IsLinux, $IsMacOS variables. For PowerShell 5.x (Windows only),
    we set these manually.
    #>
    
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # PowerShell 5.x - Windows only
        $script:IsWindows = $true
        $script:IsLinux = $false
        $script:IsMacOS = $false
    } else {
        # PowerShell 6+ - use built-in variables
        $script:IsWindows = $IsWindows
        $script:IsLinux = $IsLinux
        $script:IsMacOS = $IsMacOS
    }
    
    # Export to parent scope
    Set-Variable -Name "IsWindows" -Value $script:IsWindows -Scope Script
    Set-Variable -Name "IsLinux" -Value $script:IsLinux -Scope Script
    Set-Variable -Name "IsMacOS" -Value $script:IsMacOS -Scope Script
}

function Get-PlatformName {
    <#
    .SYNOPSIS
    Returns the current platform name as a string.
    #>
    
    Initialize-PlatformVariables
    
    if ($script:IsWindows) { return "Windows" }
    if ($script:IsLinux) { return "Linux" }
    if ($script:IsMacOS) { return "macOS" }
    return "Unknown"
}

function Test-PowerShellVersion {
    <#
    .SYNOPSIS
    Checks if PowerShell version meets requirements.
    
    .DESCRIPTION
    Validates PowerShell version. Recommends 7+ for cross-platform support.
    Requires 6+ on non-Windows platforms.
    #>
    
    Initialize-PlatformVariables
    
    $version = $PSVersionTable.PSVersion
    
    if ($version.Major -lt 7) {
        Write-Warning "PowerShell 7+ is recommended for full cross-platform support"
        Write-Warning "Current version: $version"
        
        if (-not $script:IsWindows -and $version.Major -lt 6) {
            Write-Error "PowerShell 6+ is required on macOS and Linux"
            Write-Host ""
            Write-Host "Install PowerShell: https://aka.ms/powershell" -ForegroundColor Yellow
            return $false
        }
        
        if (-not $script:IsWindows) {
            Write-Host "For best experience, upgrade to PowerShell 7+: https://aka.ms/powershell" -ForegroundColor Yellow
        }
    }
    
    return $true
}

# -----------------------------------------------------------------------------
# Path Functions
# -----------------------------------------------------------------------------

function Get-PlatformPathSeparator {
    <#
    .SYNOPSIS
    Returns the PATH environment variable separator for the current platform.
    
    .DESCRIPTION
    Returns ';' on Windows, ':' on Unix-like systems.
    #>
    
    Initialize-PlatformVariables
    
    if ($script:IsWindows) {
        return ';'
    } else {
        return ':'
    }
}

function Get-DotbotHome {
    <#
    .SYNOPSIS
    Returns the cross-platform home directory for dotbot installation.
    
    .DESCRIPTION
    Returns ~/dotbot on all platforms using the $HOME variable which works
    cross-platform in PowerShell.
    #>
    
    return Join-Path $HOME "dotbot"
}

# -----------------------------------------------------------------------------
# PATH Management
# -----------------------------------------------------------------------------

function Add-ToPath {
    <#
    .SYNOPSIS
    Adds a directory to the system PATH in a platform-appropriate way.
    
    .PARAMETER Directory
    The directory to add to PATH.
    
    .PARAMETER DryRun
    If set, shows what would be done without making changes.
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        
        [switch]$DryRun
    )
    
    Initialize-PlatformVariables
    
    if ($DryRun) {
        Write-Host "Would add to PATH: $Directory" -ForegroundColor Cyan
        return
    }
    
    if ($script:IsWindows) {
        Add-ToPathWindows -Directory $Directory
    } else {
        Add-ToPathUnix -Directory $Directory
    }
}

function Add-ToPathWindows {
    param([string]$Directory)
    
    # Get current user PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    # Check if already in PATH
    if ($currentPath -like "*$Directory*") {
        Write-VerboseLog "Directory already in PATH: $Directory"
        return
    }
    
    Write-Status "Adding to PATH..."
    
    # Add to PATH (prepend for priority)
    $newPath = "$Directory;$currentPath"
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    
    # Update current session
    $env:Path = "$Directory;$env:Path"
    
    Write-Success "Added to PATH: $Directory"
    Write-Host ""
    Write-Host "  Restart your terminal for the changes to take effect" -ForegroundColor Yellow
}

function Add-ToPathUnix {
    param([string]$Directory)
    
    # Determine which shell profiles to update
    $shellProfiles = @()
    
    # Check for common shell profile files
    $profileCandidates = @(
        (Join-Path $HOME ".bashrc"),
        (Join-Path $HOME ".bash_profile"),
        (Join-Path $HOME ".zshrc"),
        (Join-Path $HOME ".profile")
    )
    
    foreach ($profile in $profileCandidates) {
        if (Test-Path $profile) {
            $shellProfiles += $profile
        }
    }
    
    # If no profiles exist, create .profile
    if ($shellProfiles.Count -eq 0) {
        $defaultProfile = Join-Path $HOME ".profile"
        New-Item -ItemType File -Path $defaultProfile -Force | Out-Null
        $shellProfiles += $defaultProfile
    }
    
    $exportLine = "export PATH=`"$Directory:`$PATH`""
    $updated = $false
    
    foreach ($profile in $shellProfiles) {
        $content = Get-Content $profile -Raw -ErrorAction SilentlyContinue
        
        # Check if already in this profile
        if ($content -and $content -match [regex]::Escape($Directory)) {
            Write-VerboseLog "Directory already in $profile"
            continue
        }
        
        # Add to profile with markers
        $dotbotBlock = @"

# dotbot - added by dotbot installer
$exportLine
"@
        
        Add-Content -Path $profile -Value $dotbotBlock
        Write-Success "Added to PATH in: $profile"
        $updated = $true
    }
    
    if ($updated) {
        # Update current session
        $env:PATH = "$Directory`:$env:PATH"
        
        Write-Host ""
        Write-Host "  Run one of the following to update your current shell:" -ForegroundColor Yellow
        foreach ($profile in $shellProfiles) {
            Write-Host "    source $profile" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "  Or restart your terminal" -ForegroundColor Yellow
    }
}

function Remove-FromPath {
    <#
    .SYNOPSIS
    Removes a directory from the system PATH in a platform-appropriate way.
    
    .PARAMETER Directory
    The directory to remove from PATH.
    
    .PARAMETER DryRun
    If set, shows what would be done without making changes.
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        
        [switch]$DryRun
    )
    
    Initialize-PlatformVariables
    
    if ($DryRun) {
        Write-Host "Would remove from PATH: $Directory" -ForegroundColor Cyan
        return
    }
    
    if ($script:IsWindows) {
        Remove-FromPathWindows -Directory $Directory
    } else {
        Remove-FromPathUnix -Directory $Directory
    }
}

function Remove-FromPathWindows {
    param([string]$Directory)
    
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    
    if ($currentPath -like "*$Directory*") {
        Write-Status "Removing from PATH..."
        
        $pathEntries = $currentPath -split ';' | Where-Object { $_ -ne $Directory }
        $newPath = $pathEntries -join ';'
        
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        
        # Update current session
        $env:Path = ($env:Path -split ';' | Where-Object { $_ -ne $Directory }) -join ';'
        
        Write-Success "Removed from PATH"
    }
}

function Remove-FromPathUnix {
    param([string]$Directory)
    
    $shellProfiles = @(
        (Join-Path $HOME ".bashrc"),
        (Join-Path $HOME ".bash_profile"),
        (Join-Path $HOME ".zshrc"),
        (Join-Path $HOME ".profile")
    )
    
    $escapedDir = [regex]::Escape($Directory)
    $updated = $false
    
    foreach ($profile in $shellProfiles) {
        if (-not (Test-Path $profile)) {
            continue
        }
        
        $content = Get-Content $profile -Raw
        
        if ($content -match $escapedDir) {
            # Remove the dotbot block (including the comment line)
            $pattern = "(?m)^# dotbot - added by dotbot installer\s*\r?\nexport PATH=`".*$escapedDir.*`"\s*\r?\n?"
            $newContent = $content -replace $pattern, ""
            
            # Also handle cases where the line might not have our comment
            $pattern2 = "(?m)^export PATH=`".*$escapedDir.*`"\s*\r?\n?"
            $newContent = $newContent -replace $pattern2, ""
            
            Set-Content -Path $profile -Value $newContent -NoNewline
            Write-Success "Removed from PATH in: $profile"
            $updated = $true
        }
    }
    
    if ($updated) {
        # Update current session
        $separator = Get-PlatformPathSeparator
        $env:PATH = ($env:PATH -split $separator | Where-Object { $_ -ne $Directory }) -join $separator
    }
}

function Set-ExecutablePermission {
    <#
    .SYNOPSIS
    Sets executable permission on Unix-like systems.
    
    .PARAMETER FilePath
    Path to the file to make executable.
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    
    Initialize-PlatformVariables
    
    if (-not $script:IsWindows) {
        try {
            chmod +x $FilePath
            Write-VerboseLog "Set executable permission: $FilePath"
        }
        catch {
            Write-Warning "Failed to set executable permission on $FilePath"
        }
    }
}

# -----------------------------------------------------------------------------
# Module Initialization
# -----------------------------------------------------------------------------

# Initialize platform variables when module is imported
Initialize-PlatformVariables

# Export functions
Export-ModuleMember -Function @(
    'Initialize-PlatformVariables',
    'Get-PlatformName',
    'Test-PowerShellVersion',
    'Get-PlatformPathSeparator',
    'Get-DotbotHome',
    'Add-ToPath',
    'Remove-FromPath',
    'Set-ExecutablePermission'
)
