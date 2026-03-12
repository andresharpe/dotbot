#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install dotbot globally to ~/dotbot

.DESCRIPTION
    Copies dotbot files to ~/dotbot and adds the CLI to PATH
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$SourceDir = Split-Path -Parent $ScriptDir
$BaseDir = Join-Path $HOME "dotbot"
$BinDir = Join-Path $BaseDir "bin"

# Import platform functions
Import-Module (Join-Path $ScriptDir "Platform-Functions.psm1") -Force

Write-Status "Installing dotbot to $BaseDir"

# Check if source and destination are the same
$resolvedSource = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
$resolvedBase = if (Test-Path $BaseDir) { (Resolve-Path $BaseDir).Path.TrimEnd('\', '/') } else { $null }

if ($resolvedBase -and ($resolvedSource -eq $resolvedBase)) {
    Write-Success "Already running from target installation directory"
    Write-Success "dotbot is installed at: $BaseDir"
} else {
    if ($DryRun) {
        Write-Host "  Would copy files from: $SourceDir" -ForegroundColor Yellow
        Write-Host "  Would copy to: $BaseDir" -ForegroundColor Yellow
    } else {
        # Create base directory
        if (-not (Test-Path $BaseDir)) {
            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        }
        
        # Copy all files except .git
        $itemsToCopy = Get-ChildItem -Path $SourceDir -Exclude ".git"
        
        foreach ($item in $itemsToCopy) {
            $dest = Join-Path $BaseDir $item.Name
            
            if ($item.PSIsContainer) {
                if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
                Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
            } else {
                Copy-Item -Path $item.FullName -Destination $dest -Force
            }
        }
        
        Write-Success "Files copied to: $BaseDir"
    }
}

# Create bin directory with dotbot CLI wrapper
if (-not $DryRun) {
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    }
    
    # Create dotbot.ps1 CLI wrapper
    $cliScript = Join-Path $BinDir "dotbot.ps1"
    $cliContent = @'
#!/usr/bin/env pwsh
# dotbot CLI wrapper
$DotbotBase = Join-Path $HOME "dotbot"
$ScriptsDir = Join-Path $DotbotBase "scripts"

# Import common functions
Import-Module (Join-Path $ScriptsDir "Platform-Functions.psm1") -Force

$Command = $args[0]

# Convert CLI args to a hashtable for proper named-parameter splatting.
# Array splatting only does positional binding; hashtable splatting is
# required for named parameters like -Profile.
$SplatArgs = @{}
if ($args.Count -gt 1) {
    $raw = $args[1..($args.Count-1)]
    $i = 0
    while ($i -lt $raw.Count) {
        if ($raw[$i] -match '^--?(.+)$') {
            $name = $Matches[1]
            if (($i + 1) -lt $raw.Count -and $raw[$i + 1] -notmatch '^--?') {
                $SplatArgs[$name] = $raw[$i + 1]
                $i += 2
            } else {
                $SplatArgs[$name] = $true
                $i++
            }
        } else {
            $i++
        }
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v3" -ForegroundColor Blue
    Write-Host "    Autonomous Development System" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "  COMMANDS" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    init              " -NoNewline -ForegroundColor Yellow
    Write-Host "Initialize .bot in current project" -ForegroundColor White
    Write-Host "    profiles          " -NoNewline -ForegroundColor Yellow
    Write-Host "List available profiles" -ForegroundColor White
    Write-Host "    status            " -NoNewline -ForegroundColor Yellow
    Write-Host "Show installation status" -ForegroundColor White
    Write-Host "    update            " -NoNewline -ForegroundColor Yellow
    Write-Host "Update global installation" -ForegroundColor White
    Write-Host "    help              " -NoNewline -ForegroundColor Yellow
    Write-Host "Show this help message" -ForegroundColor White
    Write-Host ""
}

function Invoke-Init {
    $initScript = Join-Path $ScriptsDir "init-project.ps1"
    if (Test-Path $initScript) {
        if ($SplatArgs.Count -gt 0) {
            & $initScript @SplatArgs
        } else {
            & $initScript
        }
    } else {
        Write-Host "  ✗ Init script not found" -ForegroundColor Red
    }
}

function Invoke-Status {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v3" -ForegroundColor Blue
    Write-Host "    Status" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    
    # Check global installation
    Write-Host "  GLOBAL INSTALLATION" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
    Write-Host "✓ Installed" -ForegroundColor Green
    Write-Host "    Location: " -NoNewline -ForegroundColor Yellow
    Write-Host "$DotbotBase" -ForegroundColor White
    Write-Host ""
    
    # Check project installation
    $botDir = Join-Path (Get-Location) ".bot"
    Write-Host "  PROJECT INSTALLATION" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    
    if (Test-Path $botDir) {
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✓ Enabled" -ForegroundColor Green
        Write-Host "    Location: " -NoNewline -ForegroundColor Yellow
        Write-Host "$botDir" -ForegroundColor White
        
        # Count components
        $mcpDir = Join-Path $botDir "systems\mcp"
        $uiDir = Join-Path $botDir "systems\ui"
        $promptsDir = Join-Path $botDir "prompts"
        
        if (Test-Path $mcpDir) {
            Write-Host "    MCP:      " -NoNewline -ForegroundColor Yellow
            Write-Host "✓ Available" -ForegroundColor Green
        }
        if (Test-Path $uiDir) {
            Write-Host "    UI:       " -NoNewline -ForegroundColor Yellow
            Write-Host "✓ Available (default port 8686)" -ForegroundColor Green
        }
        if (Test-Path $promptsDir) {
            $agentCount = (Get-ChildItem -Path (Join-Path $promptsDir "agents") -Directory -ErrorAction SilentlyContinue).Count
            $skillCount = (Get-ChildItem -Path (Join-Path $promptsDir "skills") -Directory -ErrorAction SilentlyContinue).Count
            Write-Host "    Agents:   " -NoNewline -ForegroundColor Yellow
            Write-Host "$agentCount" -ForegroundColor White
            Write-Host "    Skills:   " -NoNewline -ForegroundColor Yellow
            Write-Host "$skillCount" -ForegroundColor White
        }
        Write-Host ""
    } else {
        Write-Host "    Status:   " -NoNewline -ForegroundColor Yellow
        Write-Host "✗ Not initialized" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Run 'dotbot init' to add dotbot to this project" -ForegroundColor Yellow
        Write-Host ""
    }
}

function Invoke-Profiles {
    $profilesDir = Join-Path $DotbotBase "profiles"
    if (-not (Test-Path $profilesDir)) {
        Write-Host "  No profiles directory found at: $profilesDir" -ForegroundColor Red
        return
    }

    $workflows = @()
    $stacks = @()

    Get-ChildItem -Path $profilesDir -Directory | Where-Object { $_.Name -ne "default" } | ForEach-Object {
        $yamlPath = Join-Path $_.FullName "profile.yaml"
        $meta = @{ type = "stack"; name = $_.Name; description = ""; extends = $null }
        if (Test-Path $yamlPath) {
            Get-Content $yamlPath | ForEach-Object {
                if ($_ -match '^\s*(type|name|description|extends)\s*:\s*(.+)$') {
                    $meta[$Matches[1]] = $Matches[2].Trim()
                }
            }
        }
        if ($meta.type -eq "workflow") { $workflows += $meta }
        else { $stacks += $meta }
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
    Write-Host "    D O T B O T   v3" -ForegroundColor Blue
    Write-Host "    Available Profiles" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""

    if ($workflows.Count -gt 0) {
        Write-Host "  WORKFLOWS (at most one)" -ForegroundColor Blue
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        foreach ($w in $workflows) {
            Write-Host "    $($w.name.PadRight(18))" -NoNewline -ForegroundColor Yellow
            Write-Host $w.description -ForegroundColor White
        }
        Write-Host ""
    }

    if ($stacks.Count -gt 0) {
        Write-Host "  STACKS (composable)" -ForegroundColor Blue
        Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host ""
        foreach ($s in $stacks) {
            $label = $s.name
            if ($s.extends) { $label += " (extends: $($s.extends))" }
            Write-Host "    $($label.PadRight(36))" -NoNewline -ForegroundColor Yellow
            Write-Host $s.description -ForegroundColor White
        }
        Write-Host ""
    }

    Write-Host "  USAGE" -ForegroundColor Blue
    Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    dotbot init --profile dotnet" -ForegroundColor White
    Write-Host "    dotbot init --profile kickstart-via-jira,dotnet-blazor,dotnet-ef" -ForegroundColor White
    Write-Host ""
}

function Invoke-Update {
    Write-Host ""
    Write-Host "  To update dotbot:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    cd ~/dotbot" -ForegroundColor White
    Write-Host "    git pull" -ForegroundColor White
    Write-Host "    ./install.ps1" -ForegroundColor White
    Write-Host ""
}

switch ($Command) {
    "init" { Invoke-Init }
    "profiles" { Invoke-Profiles }
    "status" { Invoke-Status }
    "update" { Invoke-Update }
    "help" { Show-Help }
    "--help" { Show-Help }
    "-h" { Show-Help }
    $null { Show-Help }
    default {
        Write-Host ""
        Write-Host "  ✗ Unknown command: $Command" -ForegroundColor Red
        Write-Host "    Run 'dotbot help' for available commands" -ForegroundColor Yellow
        Write-Host ""
    }
}
'@
    Set-Content -Path $cliScript -Value $cliContent -Force
    Set-ExecutablePermission -FilePath $cliScript
    Write-Success "Created CLI at: $cliScript"

    # On Unix, create a bash shim so 'dotbot' works without the .ps1 extension
    Initialize-PlatformVariables
    if (-not $IsWindows) {
        $bashShim = Join-Path $BinDir "dotbot"
        $bashShimContent = @'
#!/usr/bin/env bash
# dotbot CLI shim — delegates to the PowerShell wrapper
exec pwsh -NoProfile -File "$(dirname "$0")/dotbot.ps1" "$@"
'@
        Set-Content -Path $bashShim -Value $bashShimContent -Force -NoNewline
        Set-ExecutablePermission -FilePath $bashShim
        Write-Success "Created bash shim at: $bashShim"
    }
}

# Add to PATH
if (-not $DryRun) {
    Add-ToPath -Directory $BinDir
}

# Show completion message
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  ✓ Installation Complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Platform: $(Get-PlatformName)" -ForegroundColor Gray
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host ""
Write-Host "  NEXT STEPS" -ForegroundColor Blue
Write-Host "  ────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "    1. Restart your terminal" -ForegroundColor White
Write-Host "    2. Navigate to your project: cd your-project" -ForegroundColor White
Write-Host "    3. Initialize dotbot: dotbot init" -ForegroundColor White
Write-Host ""
