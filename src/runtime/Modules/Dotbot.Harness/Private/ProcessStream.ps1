function Invoke-HarnessProcessStream {
    <#
    .SYNOPSIS
    Runs a streaming harness CLI with idle-time stop checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$CliArgs = @(),
        [string]$Prompt,
        [switch]$PassPromptViaStdin,
        [string]$WorkingDirectory,
        [Parameter(Mandatory)][scriptblock]$HandleOutput,
        [scriptblock]$HandleErrorOutput,
        [scriptblock]$ShouldStopStream,
        [int]$StopCheckIntervalSeconds = 2,
        [int]$StopGraceSeconds = 10,
        [string]$StopReason = "provider stream stop requested",
        [switch]$ShowDebugJson,
        $Theme
    )

    $cmd = Get-Command $Executable -ErrorAction Stop | Select-Object -First 1
    $exePath = if ($cmd.Source) { $cmd.Source } else { $cmd.Path }
    if (-not $exePath) { $exePath = $Executable }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $exeExtension = [System.IO.Path]::GetExtension($exePath)
    if ($IsWindows -and ($exeExtension -eq '.cmd' -or $exeExtension -eq '.bat')) {
        $psi.FileName = $env:ComSpec
        $psi.ArgumentList.Add('/d')
        $psi.ArgumentList.Add('/c')
        $psi.ArgumentList.Add($exePath)
    } elseif ($exeExtension -eq '.ps1') {
        $psi.FileName = 'pwsh'
        $psi.ArgumentList.Add('-NoProfile')
        if ($IsWindows) {
            $psi.ArgumentList.Add('-ExecutionPolicy')
            $psi.ArgumentList.Add('Bypass')
        }
        $psi.ArgumentList.Add('-File')
        $psi.ArgumentList.Add($exePath)
    } else {
        $psi.FileName = $exePath
    }
    foreach ($arg in @($CliArgs | Where-Object { $null -ne $_ })) {
        $psi.ArgumentList.Add([string]$arg)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkingDirectory -and (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.Environment["__DOTBOT_MANAGED"] = "1"
    $frameworkRootForMcp = Get-DotbotInstallPath
    $mcpProjectRoot = if ($WorkingDirectory) { $WorkingDirectory } else { $global:DotbotProjectRoot }
    if ($frameworkRootForMcp) {
        $psi.Environment["DOTBOT_HOME"] = $frameworkRootForMcp
    }
    if ($mcpProjectRoot) {
        $psi.Environment["DOTBOT_PROJECT_ROOT"] = $mcpProjectRoot
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $pendingReadTask = $null
    $pendingErrorReadTask = $null
    $stopLogged = $false
    $stopRequested = $false
    $stopDeadline = $null
    $stdoutClosed = $false
    $stderrClosed = $false

    try {
        try {
            $proc.Start() | Out-Null
            Write-HarnessLog "process" "Provider process started: $($cmd.Name) pid=$($proc.Id)" "*"
        } catch {
            Write-ActivityLog -Type "error" -Message "Provider process failed to start: $($cmd.Name) - $($_.Exception.Message)"
            throw
        }

        if ($PassPromptViaStdin) {
            $proc.StandardInput.Write($Prompt)
        }
        $proc.StandardInput.Close()

        $mainExited = $false
        $drainDeadline = $null
        $drainGraceSeconds = 10
        $readTimeoutMs = [Math]::Max(1, $StopCheckIntervalSeconds) * 1000

        while ($true) {
            if (-not $mainExited -and $proc.HasExited) {
                $mainExited = $true
                $drainDeadline = (Get-Date).AddSeconds($drainGraceSeconds)
            }

            if ($mainExited -and (Get-Date) -gt $drainDeadline) {
                if ($pendingReadTask) {
                    try { $proc.StandardOutput.Close() } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to close harness stdout stream" -Exception $_ } }
                    $pendingReadTask = $null
                }
                break
            }

            if ($stdoutClosed -and $stderrClosed) {
                break
            }

            if (-not $mainExited -and $ShouldStopStream) {
                $predicateResult = $false
                try { $predicateResult = [bool](& $ShouldStopStream) } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Harness stream stop predicate failed" -Exception $_ } }
                if ($predicateResult) {
                    $stopRequested = $true
                    if (-not $stopLogged) {
                        Write-ActivityLog -Type "text" -Message "Provider stream stop requested: $StopReason"
                        $stopDeadline = (Get-Date).AddSeconds([Math]::Max(0, $StopGraceSeconds))
                        $stopLogged = $true
                    }
                    if ((Get-Date) -ge $stopDeadline) {
                        if ($pendingReadTask) {
                            try { $proc.StandardOutput.Close() } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to close harness stdout stream" -Exception $_ } }
                            $pendingReadTask = $null
                        }
                        if ($pendingErrorReadTask) {
                            try { $proc.StandardError.Close() } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to close harness stderr stream" -Exception $_ } }
                            $pendingErrorReadTask = $null
                        }
                        try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to stop harness process tree" -Exception $_ } }
                        break
                    }
                }
            }

            try {
                if (-not $stdoutClosed -and -not $pendingReadTask) {
                    $pendingReadTask = $proc.StandardOutput.ReadLineAsync()
                }
                if (-not $stderrClosed -and -not $pendingErrorReadTask) {
                    $pendingErrorReadTask = $proc.StandardError.ReadLineAsync()
                }

                $readTasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
                if ($pendingReadTask) { $readTasks.Add($pendingReadTask) }
                if ($pendingErrorReadTask) { $readTasks.Add($pendingErrorReadTask) }
                if ($readTasks.Count -eq 0) {
                    if ($mainExited) { break }
                    Start-Sleep -Milliseconds $readTimeoutMs
                    continue
                }

                $completedIndex = [System.Threading.Tasks.Task]::WaitAny($readTasks.ToArray(), $readTimeoutMs)
                if ($completedIndex -lt 0) { continue }
                $completedTask = $readTasks[$completedIndex]
            } catch {
                break
            }

            if ($completedTask -eq $pendingReadTask) {
                try {
                    $raw = $pendingReadTask.Result
                } catch {
                    $raw = $null
                }
                $pendingReadTask = $null
                if ($null -eq $raw) {
                    $stdoutClosed = $true
                    continue
                }
                & $HandleOutput $raw
                continue
            }

            if ($completedTask -eq $pendingErrorReadTask) {
                try {
                    $raw = $pendingErrorReadTask.Result
                } catch {
                    $raw = $null
                }
                $pendingErrorReadTask = $null
                if ($null -eq $raw) {
                    $stderrClosed = $true
                    continue
                }
                if ($HandleErrorOutput) {
                    & $HandleErrorOutput $raw
                } elseif ($ShowDebugJson -and $Theme) {
                    [Console]::Error.WriteLine("$($Theme.Bezel)[STDERR] $raw$($Theme.Reset)")
                    [Console]::Error.Flush()
                }
            }
        }

        $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { 0 }
        return [pscustomobject]@{
            ExitCode      = $exitCode
            StopRequested = $stopRequested
        }
    } finally {
        if ($pendingReadTask -and $proc -and $proc.StandardOutput) {
            try { $proc.StandardOutput.Close() } catch { }
        }
        if ($proc -and $proc.StandardError) {
            try { $proc.StandardError.Close() } catch { }
        }
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill($true) } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to stop harness process tree" -Exception $_ } }
        }
        if ($proc) {
            try { $proc.Dispose() } catch { }
        }
    }
}
