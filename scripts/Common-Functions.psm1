# =============================================================================
# dotbot Common Functions Module
# Shared functions used across all dotbot PowerShell scripts
# =============================================================================

# -----------------------------------------------------------------------------
# Color and Output Functions
# -----------------------------------------------------------------------------

function Write-Status {
    param([string]$Message)
    Write-Host "→ $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Verbose {
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
        ClaudeCodeCommands = Get-ConfigValue -ConfigPath $configPath -Key "claude_code_commands"
        UseClaudeCodeSubagents = Get-ConfigValue -ConfigPath $configPath -Key "use_claude_code_subagents"
        DotbotCommands = Get-ConfigValue -ConfigPath $configPath -Key "dotbot_commands"
        StandardsAsClaudeCodeSkills = Get-ConfigValue -ConfigPath $configPath -Key "standards_as_claude_code_skills"
    }
    
    return $config
}

function Test-ConfigValid {
    param(
        [bool]$ClaudeCodeCommands,
        [bool]$UseClaudeCodeSubagents,
        [bool]$DotbotCommands,
        [bool]$StandardsAsClaudeCodeSkills,
        [string]$Profile,
        [string]$BaseDir
    )
    
    # Check if at least one command installation method is enabled
    if (-not $ClaudeCodeCommands -and -not $DotbotCommands) {
        Write-Warning "Neither Claude Code commands nor dotbot commands are enabled."
        Write-Warning "No commands will be installed. You can enable them in config.yml or via command line flags."
    }
    
    # Check if subagents are enabled but Claude Code commands are not
    if ($UseClaudeCodeSubagents -and -not $ClaudeCodeCommands) {
        Write-Warning "Claude Code subagents require Claude Code commands to be enabled."
        Write-Warning "Disabling subagents."
        return $false
    }
    
    # Check if standards as skills is enabled but Claude Code commands are not
    if ($StandardsAsClaudeCodeSkills -and -not $ClaudeCodeCommands) {
        Write-Warning "Standards as Claude Code Skills require Claude Code commands to be enabled."
        Write-Warning "Standards will be provided as file references instead."
        return $false
    }
    
    # Check if profile exists
    $profilePath = Join-Path $BaseDir "profiles\$Profile"
    if (-not (Test-Path $profilePath)) {
        Write-Error "Profile '$Profile' not found at: $profilePath"
        throw "Invalid profile"
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
        [bool]$DryRun = $false
    )
    
    if ($DryRun) {
        Write-Verbose "Would copy: $Source -> $Destination"
        return $Destination
    }
    
    # Check if destination exists
    if ((Test-Path $Destination) -and -not $Overwrite) {
        Write-Verbose "Skipping (already exists): $Destination"
        return $null
    }
    
    # Create destination directory if it doesn't exist
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    
    # Copy file
    Copy-Item -Path $Source -Destination $Destination -Force
    Write-Verbose "Copied: $Destination"
    
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
    'Write-Warning',
    'Write-Verbose',
    'Get-ConfigValue',
    'Get-BaseConfig',
    'Test-ConfigValid',
    'Copy-DotbotFile',
    'Get-ProfileFiles',
    'Get-ProfileFile',
    'Show-Progress',
    'Hide-Progress'
)
