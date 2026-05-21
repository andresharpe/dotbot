<#
.SYNOPSIS
Script executor — runs a PowerShell script declared on the task.

Useful for workflows that mostly orchestrate without an AI in the loop:
the task declares `script_path` (and optionally `script_args` and
`working_directory`), this executor invokes the script with pwsh, captures
stdout / stderr, and returns success based on the exit code.

The dispatcher already checks required_fields, so `script_path` is
guaranteed present by the time Invoke-Executor runs.
#>

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    $scriptPath = [string]$Task['script_path']
    $scriptArgs = @()
    if ($Task.Contains('script_args') -and $Task['script_args']) {
        $scriptArgs = @($Task['script_args'])
    }
    $workingDir = if ($Task.Contains('working_directory') -and $Task['working_directory']) {
        [string]$Task['working_directory']
    } elseif ($RunContext.Contains('worktree_path') -and $RunContext['worktree_path']) {
        [string]$RunContext['worktree_path']
    } elseif ($RunContext.Contains('project_root') -and $RunContext['project_root']) {
        [string]$RunContext['project_root']
    } else {
        (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return @{
            Success  = $false
            Message  = "script_path '$scriptPath' does not exist."
            ExitCode = 2
        }
    }

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName  = 'pwsh'
    [void]$startInfo.ArgumentList.Add('-NoProfile')
    [void]$startInfo.ArgumentList.Add('-ExecutionPolicy')
    [void]$startInfo.ArgumentList.Add('Bypass')
    [void]$startInfo.ArgumentList.Add('-File')
    [void]$startInfo.ArgumentList.Add($scriptPath)
    foreach ($a in $scriptArgs) { [void]$startInfo.ArgumentList.Add([string]$a) }
    $startInfo.WorkingDirectory       = $workingDir
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    $startInfo.UseShellExecute        = $false

    $proc = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exit   = $proc.ExitCode

    try { Remove-Item -LiteralPath $stdoutFile -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    try { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue } catch { $null = $_ }

    return @{
        Success  = ($exit -eq 0)
        Message  = if ($exit -eq 0) { "Script '$scriptPath' completed successfully." } else { "Script '$scriptPath' exited with code $exit." }
        ExitCode = $exit
        stdout   = $stdout
        stderr   = $stderr
    }
}

Export-ModuleMember -Function Invoke-Executor
