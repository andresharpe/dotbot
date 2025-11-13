# =============================================================================
# dotbot Common Functions Module
# Shared functions used across all dotbot PowerShell scripts
# =============================================================================

# -----------------------------------------------------------------------------
# Import Platform Functions
# -----------------------------------------------------------------------------

$platformFunctionsPath = Join-Path $PSScriptRoot "Platform-Functions.psm1"
if (Test-Path $platformFunctionsPath) {
    Import-Module $platformFunctionsPath -Force -Global
}

# Import Template Processor
# -----------------------------------------------------------------------------

$templateProcessorPath = Join-Path $PSScriptRoot "Template-Processor.psm1"
if (Test-Path $templateProcessorPath) {
    Import-Module $templateProcessorPath -Force -Global
}

# -----------------------------------------------------------------------------
# Color and Output Functions
# -----------------------------------------------------------------------------

function Write-Status {
    param([string]$Message)
    Write-Host "▸ " -NoNewline -ForegroundColor Yellow
    Write-Host "$Message" -ForegroundColor Gray
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ " -NoNewline -ForegroundColor Blue
    Write-Host "$Message" -ForegroundColor Gray
}

function Write-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Write-FriendlyError {
    param(
        [string]$Message,
        [string]$Suggestion = "",
        [switch]$Fatal
    )
    Write-Host ""
    Write-Host "❌ $Message" -ForegroundColor Red
    if ($Suggestion) {
        Write-Host "💡 $Suggestion" -ForegroundColor Yellow
    }
    Write-Host ""
    
    if ($Fatal) {
        exit 1
    }
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-VerboseLog {
    param([string]$Message)
    if ($script:Verbose) {
        Write-Host "  $Message" -ForegroundColor Gray
    }
}

# -----------------------------------------------------------------------------
# Configuration Functions
# -----------------------------------------------------------------------------

function Get-ConfigValue {
    param(
        [string]$ConfigPath,
        [string]$Key
    )
    
    if (-not (Test-Path $ConfigPath)) {
        return $null
    }
    
    $content = Get-Content $ConfigPath -Raw
    if ($content -match "(?m)^$Key\s*:\s*(.+)$") {
        $value = $Matches[1].Trim()
        # Convert string booleans to actual booleans
        if ($value -eq "true") { return $true }
        if ($value -eq "false") { return $false }
        return $value
    }
    
    return $null
}

function Get-BaseConfig {
    param([string]$BaseDir)
    
    $configPath = Join-Path $BaseDir "config.yml"
    
    $config = @{
        Version = Get-ConfigValue -ConfigPath $configPath -Key "version"
        Profile = Get-ConfigValue -ConfigPath $configPath -Key "profile"
        StandardsAsWarpRules = Get-ConfigValue -ConfigPath $configPath -Key "standards_as_warp_rules"
    }
    
    return $config
}

function Test-ConfigValid {
    param(
        [bool]$StandardsAsWarpRules,
        [string]$Profile,
        [string]$BaseDir
    )
    
    # Check if profile exists
    $profilePath = Join-Path $BaseDir "profiles\$Profile"
    if (-not (Test-Path $profilePath)) {
        Write-FriendlyError "Profile '$Profile' not found" `
            "Check available profiles in $BaseDir\profiles\ or use the default profile" `
            -Fatal
    }
    
    return $true
}

# -----------------------------------------------------------------------------
# File Operations
# -----------------------------------------------------------------------------

function Copy-DotbotFile {
    param(
        [string]$Source,
        [string]$Destination,
        [bool]$Overwrite = $false,
        [bool]$DryRun = $false,
        [hashtable]$TemplateVariables = @{},
        [string]$Profile = "",
        [string]$BaseDir = ""
    )
    
    if ($DryRun) {
        Write-VerboseLog "Would copy: $Source -> $Destination"
        return $Destination
    }
    
    # Check if destination exists
    if ((Test-Path $Destination) -and -not $Overwrite) {
        Write-VerboseLog "Skipping (already exists): $Destination"
        return $null
    }
    
    # Create destination directory if it doesn't exist
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    
    # Read source file
    $content = Get-Content -Path $Source -Raw
    
    # Process templates if variables provided
    if ($TemplateVariables -and $TemplateVariables.Count -gt 0 -and $Profile -and $BaseDir) {
        Write-VerboseLog "Processing templates in: $Source"
        $content = Invoke-ProcessTemplate -Content $content -Variables $TemplateVariables -Profile $Profile -BaseDir $BaseDir
    }
    
    # Write processed content to destination
    Set-Content -Path $Destination -Value $content -Force
    Write-VerboseLog "Copied and processed: $Destination"
    
    return $Destination
}

function Get-ProfileFiles {
    param(
        [string]$Profile,
        [string]$BaseDir,
        [string]$Subfolder = ""
    )
    
    $profilePath = Join-Path $BaseDir "profiles\$Profile"
    
    if ($Subfolder) {
        $searchPath = Join-Path $profilePath $Subfolder
    } else {
        $searchPath = $profilePath
    }
    
    if (Test-Path $searchPath) {
        Get-ChildItem -Path $searchPath -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($profilePath.Length + 1)
            Write-Output $relativePath
        }
    }
}

function Get-ProfileFile {
    param(
        [string]$Profile,
        [string]$RelativePath,
        [string]$BaseDir
    )
    
    $profilePath = Join-Path $BaseDir "profiles\$Profile"
    $fullPath = Join-Path $profilePath $RelativePath
    
    if (Test-Path $fullPath) {
        return $fullPath
    }
    
    return $null
}

# -----------------------------------------------------------------------------
# Progress Functions
# -----------------------------------------------------------------------------

function Show-Progress {
    param(
        [string]$Activity,
        [int]$Current,
        [int]$Total
    )
    
    if ($Total -gt 0) {
        $percent = [math]::Round(($Current / $Total) * 100)
        Write-Progress -Activity $Activity -Status "$Current of $Total" -PercentComplete $percent
    }
}

function Hide-Progress {
    Write-Progress -Activity "Complete" -Completed
}

# -----------------------------------------------------------------------------
# Export Functions
# -----------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Write-Status',
    'Write-Success',
    'Write-Error',
    'Write-FriendlyError',
    'Write-Warning',
    'Write-VerboseLog',
    'Get-ConfigValue',
    'Get-BaseConfig',
    'Test-ConfigValid',
    'Copy-DotbotFile',
    'Get-ProfileFiles',
    'Get-ProfileFile',
    'Show-Progress',
    'Hide-Progress'
)

