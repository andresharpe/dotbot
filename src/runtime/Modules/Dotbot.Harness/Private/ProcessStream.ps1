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
    if ($IsWindows -and ($exePath.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase) -or $exePath.EndsWith('.bat', [System.StringComparison]::OrdinalIgnoreCase))) {
        $psi.FileName = $env:ComSpec
        $psi.ArgumentList.Add('/d')
        $psi.ArgumentList.Add('/c')
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
    $stderrDrainCts = $null
    $stderrDrain = $null
    $pendingReadTask = $null
    $stopLogged = $false
    $stopRequested = $false
    $stopDeadline = $null

    try {
        $proc.Start() | Out-Null

        if ($PassPromptViaStdin) {
            $proc.StandardInput.Write($Prompt)
        }
        $proc.StandardInput.Close()

        $stderrDrainCts = [System.Threading.CancellationTokenSource]::new()
        $stderrDrain = [System.Threading.Tasks.Task]::Run([Action]{
            $pendingStderrRead = $null
            try {
                while (-not $proc.HasExited -and -not $stderrDrainCts.IsCancellationRequested) {
                    if (-not $pendingStderrRead) {
                        $pendingStderrRead = $proc.StandardError.ReadLineAsync()
                    }
                    if ($pendingStderrRead.Wait(2000)) {
                        $line = $pendingStderrRead.Result
                        $pendingStderrRead = $null
                        if ($null -eq $line) { break }
                        if ($ShowDebugJson -and $Theme) {
                            [Console]::Error.WriteLine("$($Theme.Bezel)[STDERR] $line$($Theme.Reset)")
                            [Console]::Error.Flush()
                        }
                    }
                }
            } catch { }
        })

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
                        try { if (-not $proc.HasExited) { $proc.Kill($true) } } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to stop harness process tree" -Exception $_ } }
                        break
                    }
                }
            }

            try {
                if (-not $pendingReadTask) {
                    $pendingReadTask = $proc.StandardOutput.ReadLineAsync()
                }

                if ($pendingReadTask.Wait($readTimeoutMs)) {
                    $raw = $pendingReadTask.Result
                    $pendingReadTask = $null
                } else {
                    continue
                }
            } catch {
                break
            }

            if ($null -eq $raw) { break }
            & $HandleOutput $raw
        }

        $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { 0 }
        return [pscustomobject]@{
            ExitCode      = $exitCode
            StopRequested = $stopRequested
        }
    } finally {
        if ($stderrDrainCts) {
            try { $stderrDrainCts.Cancel() } catch { }
        }
        if ($proc -and $proc.StandardError) {
            try { $proc.StandardError.Close() } catch { }
        }
        if ($stderrDrain) {
            try { [void]$stderrDrain.Wait(3000) } catch { }
        }
        if ($stderrDrainCts) {
            try { $stderrDrainCts.Dispose() } catch { }
        }
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill($true) } catch { if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) { Write-BotLog -Level Debug -Message "Cleanup: failed to stop harness process tree" -Exception $_ } }
        }
        if ($proc) {
            try { $proc.Dispose() } catch { }
        }
    }
}
