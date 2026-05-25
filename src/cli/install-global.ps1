#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Install dotbot globally to DOTBOT_HOME or ~/dotbot

.DESCRIPTION
    Copies dotbot files to DOTBOT_HOME (when set) or ~/dotbot and adds the CLI to PATH
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$SourceDir
)

$ErrorActionPreference = "Stop"


Import-Module (Join-Path $PSScriptRoot ".." "runtime" "Modules" "Dotbot.Core" "Dotbot.Core.psm1") -Force -DisableNameChecking
$ScriptDir = $PSScriptRoot
if (-not $SourceDir) {
    # $ScriptDir is <repo>/src/cli/; the repo root is two levels up.
    $SourceDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
}
$BaseDir = Get-DotbotInstallPath
$BinDir = Join-Path $BaseDir "bin"

# Import platform functions
Import-Module (Join-Path $ScriptDir "Platform-Functions.psm1") -Force
Import-Module (Join-Path $SourceDir "src" "runtime" "Modules" "Dotbot.Theme" "Dotbot.Theme.psd1") -Force -DisableNameChecking

Write-Step "Installing dotbot to $BaseDir"

# Check if source and destination are the same
$resolvedSource = (Resolve-Path $SourceDir).Path.TrimEnd('\', '/')
$resolvedBase = if (Test-Path $BaseDir) { (Resolve-Path $BaseDir).Path.TrimEnd('\', '/') } else { $null }

if ($resolvedBase -and ($resolvedSource -eq $resolvedBase)) {
    Write-Step "Already running from target installation directory" -Done
    Write-Step "dotbot is installed at: $BaseDir" -Done
} else {
    if ($DryRun) {
        Write-DotbotWarning "Would copy files from: $SourceDir"
        Write-DotbotWarning "Would copy to: $BaseDir"
    } else {
        # Resolve studio-ui source up front so the runspace doesn't have to
        # re-discover layout. Pre-flight the static-assets warning here too —
        # the runspace can't reach Platform-Functions/theme helpers.
        $editorSrcResolved = Join-Path $SourceDir "src" "studio-ui"
        if (-not (Test-Path $editorSrcResolved)) {
            $editorSrcResolved = Join-Path $SourceDir "studio-ui"
        }
        $editorHasStatic = (Test-Path $editorSrcResolved) -and
                          (Test-Path (Join-Path $editorSrcResolved "static"))
        if ((Test-Path $editorSrcResolved) -and -not $editorHasStatic) {
            Write-DotbotWarning "studio-ui/static/ not found — the editor UI requires built assets. Run 'npm run build' in studio-ui/ first."
        }

        # The actual copy work runs inside Invoke-PhosphorJob so the user sees
        # a themed shimmer while files stream across. Runspaces don't share
        # the caller's variable scope, so we pass paths via -Variables; the
        # inner scriptblock references them as plain $BaseDir / $SourceDir /
        # $EditorSrc. The inner block also stays free of theme helpers — they
        # aren't imported in the runspace.
        Invoke-PhosphorScript {
            $null = Invoke-PhosphorJob 'Copying framework files' -Variables @{
                BaseDir   = $BaseDir
                SourceDir = $SourceDir
                EditorSrc = $editorSrcResolved
            } {
                if (-not (Test-Path $BaseDir)) {
                    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
                }

                $allowedDirs  = @("src", "content", "workflows", "stacks", "bin")
                $allowedFiles = @("version.json", "dotbot.psm1", "dotbot.psd1", "install.ps1", "install-remote.ps1")

                foreach ($dirName in $allowedDirs) {
                    $src = Join-Path $SourceDir $dirName
                    if (Test-Path $src) {
                        $dest = Join-Path $BaseDir $dirName
                        if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
                        Copy-Item -Path $src -Destination $dest -Recurse -Force
                    }
                }

                foreach ($fileName in $allowedFiles) {
                    $src = Join-Path $SourceDir $fileName
                    if (Test-Path $src) {
                        Copy-Item -Path $src -Destination (Join-Path $BaseDir $fileName) -Force
                    }
                }

                # Studio UI — only deployable files (server.ps1, module, static/).
                if (Test-Path $EditorSrc) {
                    $editorDest = Join-Path $BaseDir "studio-ui"
                    if (Test-Path $editorDest) { Remove-Item -Path $editorDest -Recurse -Force }
                    New-Item -ItemType Directory -Force -Path $editorDest | Out-Null

                    foreach ($file in @("server.ps1", "StudioAPI.psm1")) {
                        $src = Join-Path $EditorSrc $file
                        if (Test-Path $src) {
                            Copy-Item -Path $src -Destination (Join-Path $editorDest $file) -Force
                        }
                    }

                    $staticSrc = Join-Path $EditorSrc "static"
                    if (Test-Path $staticSrc) {
                        Copy-Item -Path $staticSrc -Destination (Join-Path $editorDest "static") -Recurse -Force
                    }
                }
            }
            Write-Step "Files copied to: $BaseDir" -Done
        }
    }
}

# The bin/ tree is now sourced from the in-repo bin/ (copied above as part
# of $allowedDirs). Ensure the launchers are executable — Copy-Item across
# filesystems can lose the +x bit even when the source had it.
if (-not $DryRun) {
    if (-not (Test-Path $BinDir)) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    }

    $cliScript = Join-Path $BinDir "dotbot.ps1"
    if (Test-Path $cliScript) {
        Set-ExecutablePermission -FilePath $cliScript
        Write-Success "Installed CLI at: $cliScript"
    } else {
        Write-DotbotWarning "Expected $cliScript after copy, but it is missing."
    }

    Initialize-PlatformVariables
    if (-not $IsWindows) {
        $bashShim = Join-Path $BinDir "dotbot"
        if (Test-Path $bashShim) {
            Set-ExecutablePermission -FilePath $bashShim
            Write-Success "Installed bash sibling at: $bashShim"
        }
    }
}

# Ensure powershell-yaml module is available. Install-Module can take several
# seconds when it actually has to pull from PSGallery, so we animate the wait
# with the shimmering Invoke-PhosphorJob — the runspace also silences native
# Write-Progress so it can't tear through our animation.
if (-not $DryRun) {
    if (-not (Get-Module -ListAvailable powershell-yaml -ErrorAction SilentlyContinue)) {
        Invoke-PhosphorScript {
            $null = Invoke-PhosphorJob 'Installing powershell-yaml module' {
                Install-Module -Name powershell-yaml -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
            }
            Write-Step 'powershell-yaml module installed' -Done
        }
    } else {
        Write-Step 'powershell-yaml module already installed' -Done
    }
}

# Add to PATH
if (-not $DryRun) {
    Add-ToPath -Directory $BinDir
}

# Show completion message
Write-BlankLine
Write-Success "Installation Complete!"
Write-Step "Platform: $(Get-PlatformName)" -Done
Write-BlankLine
Write-DotbotSection "NEXT STEPS"
Write-Step "Restart your terminal"
Write-Step "Navigate to your project: cd your-project" -Sub
Write-Step "Initialize dotbot: dotbot init" -Sub
Write-BlankLine
