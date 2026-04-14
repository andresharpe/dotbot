# Common.ps1
# Shared utilities for dev scripts

# Import DotBotTheme for Write-Status and other theme helpers (deployed path)
$_dotBotTheme = Join-Path $PSScriptRoot "..\..\systems\runtime\modules\DotBotTheme.psm1"
if (Test-Path $_dotBotTheme) {
    Import-Module $_dotBotTheme -Force -DisableNameChecking
}

function Invoke-InProjectRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) {
        throw "Not in a git repository"
    }
    Set-Location $root -ErrorAction Stop
    return $root
}

function Load-EnvFile {
    param(
        [string]$Path = ".env.local",
        [switch]$Export
    )
    
    if (-not (Test-Path $Path)) {
        throw "Environment file not found at $Path"
    }
    
    $env = @{}
    Get-Content $Path | ForEach-Object {
        # Skip empty lines and comments
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            $env[$key] = $value
            
            if ($Export) {
                [Environment]::SetEnvironmentVariable($key, $value, "Process")
            }
        }
    }
    return $env
}

function Get-ProjectName {
    $root = git rev-parse --show-toplevel 2>$null
    if ($root) { return (Split-Path $root -Leaf) }
    return "project"
}

function Find-ApiProject {
    <#
    .SYNOPSIS
        Auto-detect the API .csproj file under src/.
    .OUTPUTS
        Relative path from repo root, or $null if not found.
    #>
    param([string]$RepoRoot)
    $src = Join-Path $RepoRoot "src"
    if (Test-Path $src) {
        $found = Get-ChildItem -Path $src -Filter "*.csproj" -Recurse -File |
            Where-Object { $_.Name -match 'Api\.csproj$' } |
            Select-Object -First 1
        if ($found) {
            return $found.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
        }
    }
    return $null
}

function Get-GitHubRepo {
    <#
    .SYNOPSIS
        Derive GitHub owner/repo from git remote origin.
    .OUTPUTS
        String like "owner/repo", or $null.
    #>
    $remote = git remote get-url origin 2>$null
    if ($remote -match 'github\.com[:/](.+?)(?:\.git)?$') {
        return $matches[1]
    }
    return $null
}
