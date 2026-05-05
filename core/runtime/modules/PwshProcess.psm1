<#
.SYNOPSIS
    Starts pwsh child processes with platform-specific stdout/stderr handling.
#>

function Start-PwshProcess {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$FilePath,

        [string[]]$Arguments,

        [string]$WorkingDirectory,

        # Shim-only extensions for migrated call sites with existing Windows launch semantics.
        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle = 'Normal',

        [switch]$NoNewWindow
    )

    $params = @{
        FilePath = $FilePath
        PassThru = $true
    }

    if ($Arguments) { $params.ArgumentList = $Arguments }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }

    if ($IsWindows) {
        if ($NoNewWindow) {
            $params.NoNewWindow = $true
        } else {
            $params.WindowStyle = $WindowStyle
        }
    } else {
        $botRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
        $logsDir = Join-Path $botRoot '.control/logs/spawned'
        if (-not (Test-Path $logsDir)) {
            New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $params.NoNewWindow = $true
        $params.RedirectStandardOutput = Join-Path $logsDir "$stamp-$suffix.out.log"
        $params.RedirectStandardError = Join-Path $logsDir "$stamp-$suffix.err.log"
    }

    Start-Process @params
}

Export-ModuleMember -Function 'Start-PwshProcess'
