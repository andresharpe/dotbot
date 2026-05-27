#!/usr/bin/env pwsh
# dotbot — standalone PATH shim (PowerShell).
#
# This is the only machine-wide dotbot artifact. It prefers a project-local
# .bot/vendor/dotbot checkout when present, otherwise reads $env:DOTBOT_HOME
# and execs into that checkout's CLI. It contains no framework code.
#
# DOTBOT_HOME must be set explicitly unless the current directory is inside
# a project that vendors dotbot under .bot/vendor/dotbot.

Set-StrictMode -Off

function Find-VendoredDotbotHome {
    $dir = (Get-Location).Path
    try {
        $dir = [System.IO.Path]::GetFullPath($dir)
    } catch {
        return $null
    }

    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $botDir = Join-Path $dir '.bot'
        if (Test-Path -LiteralPath $botDir) {
            $candidate = Join-Path $botDir 'vendor' 'dotbot'
            $candidateCli = Join-Path $candidate 'bin' 'dotbot.ps1'
            $candidateContent = Join-Path $candidate 'content' 'workspace-template'
            if ((Test-Path -LiteralPath $candidateCli -PathType Leaf) -and
                (Test-Path -LiteralPath $candidateContent -PathType Container)) {
                return [System.IO.Path]::GetFullPath($candidate)
            }
            return $null
        }

        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $null }

        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }

    return $null
}

$dotbotHome = $env:DOTBOT_HOME
$vendoredDotbotHome = Find-VendoredDotbotHome
if (-not [string]::IsNullOrWhiteSpace($vendoredDotbotHome)) {
    if (-not [string]::IsNullOrWhiteSpace($dotbotHome)) {
        $env:DOTBOT_MACHINE_HOME = $dotbotHome
    }
    $dotbotHome = $vendoredDotbotHome
    $env:DOTBOT_HOME = $vendoredDotbotHome
}

if ([string]::IsNullOrWhiteSpace($dotbotHome)) {
    Write-Error @"
dotbot: DOTBOT_HOME is not set.

Set it to a dotbot checkout, then re-run. For example:
  `$env:DOTBOT_HOME = '$HOME/code/dotbot'
"@
    exit 1
}

# Match the ~ expansion behaviour of Get-DotbotInstallPath so the shim
# accepts the same DOTBOT_HOME values as the rest of the runtime.
$dotbotHome = $dotbotHome.Trim()
if ($dotbotHome -eq '~') {
    $dotbotHome = $HOME
} elseif ($dotbotHome.StartsWith('~/') -or $dotbotHome.StartsWith('~\')) {
    $dotbotHome = Join-Path $HOME $dotbotHome.Substring(2)
}

$cli = Join-Path $dotbotHome 'bin' 'dotbot.ps1'
if (-not (Test-Path $cli)) {
    Write-Error "dotbot: DOTBOT_HOME='$dotbotHome' does not look like a dotbot checkout (missing bin/dotbot.ps1)."
    exit 1
}

& pwsh -NoProfile -File $cli @args
exit $LASTEXITCODE
