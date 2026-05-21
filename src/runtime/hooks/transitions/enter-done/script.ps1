# ═══════════════════════════════════════════════════════════════
# enter-done — Dotbot transition hook.
#
# Side effect when a task enters 'done':
#   - Run the framework verification chain (every script under
#     <BotRoot>/hooks/verify/, alphabetical). Any failure aborts and the
#     runtime reverts the transition.
# ═══════════════════════════════════════════════════════════════

function Invoke-Hook {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext,
        [Parameter(Mandatory)][string]$FromStatus,
        [Parameter(Mandatory)][string]$ToStatus
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $botRoot = $null
        if ($RunContext.ContainsKey('BotRoot')) { $botRoot = $RunContext['BotRoot'] }
        if (-not $botRoot) {
            $sw.Stop()
            return @{
                Success  = $false
                Message  = "enter-done: RunContext.BotRoot is required to locate the verify chain."
                Duration = $sw.Elapsed
            }
        }

        $verifyDir = Join-Path $botRoot (Join-Path 'hooks' 'verify')
        $failedScript = $null
        if (Test-Path -LiteralPath $verifyDir -PathType Container) {
            $scripts = Get-ChildItem -LiteralPath $verifyDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
                Sort-Object -Property Name
            foreach ($s in $scripts) {
                try {
                    $raw = & pwsh -NoProfile -File $s.FullName -TaskId $Task['id'] -Category ([string]$Task['category']) 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        $failedScript = @{ name = $s.Name; reason = "exit code $LASTEXITCODE" }
                        break
                    }
                    if ($raw) {
                        $parsed = $null
                        try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
                        if ($parsed -and ($parsed.PSObject.Properties['success']) -and (-not [bool]$parsed.success)) {
                            $msg = if ($parsed.PSObject.Properties['message']) { [string]$parsed.message } else { 'unknown' }
                            $failedScript = @{ name = $s.Name; reason = $msg }
                            break
                        }
                    }
                } catch {
                    $failedScript = @{ name = $s.Name; reason = $_.Exception.Message }
                    break
                }
            }
        }
        if ($failedScript) {
            $sw.Stop()
            return @{
                Success  = $false
                Message  = "Verify '$($failedScript.name)' failed: $($failedScript.reason)"
                Duration = $sw.Elapsed
            }
        }

        $sw.Stop()
        return @{
            Success  = $true
            Message  = "Verification passed."
            Duration = $sw.Elapsed
        }
    } catch {
        $sw.Stop()
        return @{
            Success  = $false
            Message  = "enter-done failed: $($_.Exception.Message)"
            Duration = $sw.Elapsed
        }
    }
}

Export-ModuleMember -Function Invoke-Hook
