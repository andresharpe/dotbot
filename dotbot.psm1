#!/usr/bin/env pwsh
<#
.SYNOPSIS
    dotbot PowerShell Gallery module entry point

.DESCRIPTION
    Provides the Invoke-Dotbot function and 'dotbot' alias.
    On first run, deploys dotbot files to the DotbotCore install path via install-global.ps1.
    Subsequent calls delegate to the installed CLI wrapper.
#>

$script:ModuleRoot = $PSScriptRoot
Import-Module (Join-Path $script:ModuleRoot "src" "runtime" "Modules" "DotbotCore" "DotbotCore.psm1") -Force -DisableNameChecking
$script:DotbotBase = Get-DotbotInstallPath

function Invoke-Dotbot {
    <#
    .SYNOPSIS
        Run dotbot CLI commands (init, status, profiles, update, help)

    .EXAMPLE
        Invoke-Dotbot init
        Invoke-Dotbot init -Arguments '--profile','dotnet'
        Invoke-Dotbot status
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Command,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    # Ensure dotbot files are deployed to DOTBOT_HOME or ~/dotbot
    $profilesDir = Join-Path $script:DotbotBase "profiles" "default"
    if (-not (Test-Path $profilesDir)) {
        Write-Host "  First run: deploying dotbot to $script:DotbotBase ..." -ForegroundColor Cyan
        $installScript = Join-Path $script:ModuleRoot "src" "cli" "install-global.ps1"
        & $installScript -SourceDir $script:ModuleRoot
    }

    # Delegate to the CLI wrapper
    $cliScript = Join-Path $script:DotbotBase "bin" "dotbot.ps1"
    if (-not (Test-Path $cliScript)) {
        # CLI wrapper missing — re-run install to create it
        $installScript = Join-Path $script:ModuleRoot "src" "cli" "install-global.ps1"
        & $installScript -SourceDir $script:ModuleRoot
    }

    $allArgs = @()
    if ($Command) { $allArgs += $Command }
    if ($Arguments) { $allArgs += $Arguments }
    & $cliScript @allArgs
}

Set-Alias -Name 'dotbot' -Value 'Invoke-Dotbot'

Export-ModuleMember -Function 'Invoke-Dotbot' -Alias 'dotbot'
