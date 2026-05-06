<#
.SYNOPSIS
    Starts pwsh child processes with platform-specific stdout/stderr handling.
#>

function Get-LogFilePaths {
    $logsDir = Get-DotbotProjectLogsPath
    $dir = Join-Path $logsDir 'processes'

    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    
    return @{
        OutLog = Join-Path $dir "$stamp-$suffix.out.log"
        ErrLog = Join-Path $dir "$stamp-$suffix.err.log"
    }
}

function Start-DotbotProcess {
    param(
        [Parameter(Mandatory)]
        [string]$File,

        [string[]]$FileArguments,

        [string]$WorkingDirectory,

        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle = 'Normal',

        [switch]$IsHeadless
    )

    $params = @{
        FilePath = 'pwsh'
        PassThru = $true
    }

    $argumentList = [System.Collections.Generic.List[string]]::new()
    $argumentList.Add('-NoProfile')
    $argumentList.Add('-File')
    $argumentList.Add($File)
    if ($FileArguments) {
        foreach ($argument in $FileArguments) {
            $argumentList.Add($argument)
        }
    }
    $params.ArgumentList = $argumentList.ToArray()
    if ($WorkingDirectory) {
        $params.WorkingDirectory = $WorkingDirectory
    }

    if ($IsWindows) {
        if ($IsHeadless) {
            $params.NoNewWindow = $true
        } else {
            $params.WindowStyle = $WindowStyle
        }
    } else {
        # On non-Windows, Start-Process can't create a separate console/window.
        # If the parent process has no usable stdout/stderr, the child can fail when
        # writing to inherited streams. Redirect to log files to give the child valid
        # stdout/stderr sinks.
        $logFiles = Get-LogFilePaths
        $params.RedirectStandardOutput = $logFiles.OutLog
        $params.RedirectStandardError = $logFiles.ErrLog
    }

    Start-Process @params
}
