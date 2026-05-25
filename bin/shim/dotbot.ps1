#!/usr/bin/env pwsh
# dotbot — standalone PATH shim (PowerShell).
#
# This is the only machine-wide dotbot artifact. It reads $env:DOTBOT_HOME
# and execs into that checkout's CLI. It contains no framework code.
#
# Per design decision D1: DOTBOT_HOME must be set explicitly. There is no
# fallback to ~/dotbot — the whole point of the env-var-driven model is
# that the dev declares which tree they are pointing at.

Set-StrictMode -Off

$dotbotHome = $env:DOTBOT_HOME
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
