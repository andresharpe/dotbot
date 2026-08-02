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

        $hasHookChain    = [bool](Get-Command Get-DotbotHookChain -ErrorAction SilentlyContinue)
        $hasWorktreeInfo = [bool](Get-Command Get-TaskWorktreeInfo -ErrorAction SilentlyContinue)

        # frameworkRoot is only resolved lazily, on demand — it's mandatory for
        # the content resolver (Get-DotbotHookChain drives the verify chain
        # itself) but merely best-effort for the worktree lookup (a resolution
        # failure there just means the cwd falls through to working_directory
        # / BotRoot). Don't hard-fail the whole hook over the optional path.
        $frameworkRoot = $null
        if (-not $hasHookChain -or -not $hasWorktreeInfo) {
            $frameworkRoot = if ($env:DOTBOT_HOME) {
                $env:DOTBOT_HOME
            } elseif (Get-Command Get-DotbotInstallPath -ErrorAction SilentlyContinue) {
                Get-DotbotInstallPath
            } else {
                $null
            }
        }

        if (-not $hasHookChain) {
            if (-not $frameworkRoot) {
                $sw.Stop()
                return @{
                    Success  = $false
                    Message  = "enter-done: DOTBOT_HOME is required to load the content resolver."
                    Duration = $sw.Elapsed
                }
            }
            $contentResolverModule = Join-Path $frameworkRoot "src/runtime/Modules/Dotbot.Content/Dotbot.Content.psm1"
            Import-Module $contentResolverModule -DisableNameChecking -Global
        }

        # This hook's runspace is a fresh child runspace (see Dispatch.psm1) and
        # doesn't inherit modules loaded by the parent process, so the worktree
        # lookup below needs its own explicit import — same reasoning as the
        # Dotbot.Content import above. Best-effort: if frameworkRoot couldn't be
        # resolved, just skip it — Get-TaskWorktreeInfo simply won't be found
        # below and cwd resolution falls through to working_directory / BotRoot.
        if (-not $hasWorktreeInfo -and $frameworkRoot) {
            # Import via the .psd1 manifest, not the bare .psm1 — matches the
            # established pattern elsewhere (Invoke-DotbotProcess.ps1,
            # Dotbot.TaskInput.psm1). The manifest's ScriptsToProcess pulls in
            # Dotbot.Core / Dotbot.TaskFile first, which Dotbot.Worktree's
            # functions depend on (e.g. Write-BotLog); importing the .psm1
            # directly skips that and risks a confusing secondary failure the
            # first time one of those dependencies is actually needed.
            $worktreeManifest = Join-Path $frameworkRoot "src/runtime/Modules/Dotbot.Worktree/Dotbot.Worktree.psd1"
            if (Test-Path -LiteralPath $worktreeManifest) {
                Import-Module $worktreeManifest -DisableNameChecking -Global
            }
        }

        # Resolve where the verify chain should actually run: the task's
        # project, not wherever the runtime process happened to be launched
        # from (issue #628). Preference order:
        #   1. Worktree registry (tasks owned by a WorkflowRun) - the checkout
        #      the agent actually edited, which can differ from $botRoot.
        #   2. $Task['working_directory'], if the executor set one.
        #   3. $botRoot, as a last resort - keeps old behaviour only when
        #      nothing more specific is known (standalone tasks live in the
        #      project checkout directly).
        $verifyCwd = $null

        $runId = $null
        if ($Task.ContainsKey('provenance') -and $Task['provenance']) {
            $prov = $Task['provenance']
            if ($prov -is [hashtable] -and $prov.ContainsKey('run_id')) {
                $runId = $prov['run_id']
            } elseif ($prov.PSObject.Properties['run_id']) {
                $runId = $prov.run_id
            }
        }

        if ($runId -and (Get-Command -Name Get-TaskWorktreeInfo -ErrorAction SilentlyContinue)) {
            $worktreeInfo = Get-TaskWorktreeInfo -TaskId $Task['id'] -BotRoot $botRoot -ErrorAction SilentlyContinue
            if ($worktreeInfo -and $worktreeInfo.worktree_path -and
                (Test-Path -LiteralPath $worktreeInfo.worktree_path -PathType Container)) {
                $verifyCwd = $worktreeInfo.worktree_path
            }
        }

        if (-not $verifyCwd -and $Task.ContainsKey('working_directory') -and $Task['working_directory'] -and
            (Test-Path -LiteralPath $Task['working_directory'] -PathType Container)) {
            $verifyCwd = $Task['working_directory']
        }

        if (-not $verifyCwd -and (Test-Path -LiteralPath $botRoot -PathType Container)) {
            $verifyCwd = $botRoot
        }

        if (-not $verifyCwd) {
            $sw.Stop()
            return @{
                Success  = $false
                Message  = "enter-done: no valid working directory could be resolved (worktree, working_directory, and BotRoot '$botRoot' are all invalid or missing)."
                Duration = $sw.Elapsed
            }
        }

        # Merged verify chain: project hooks at <BotRoot>/hooks/verify/ win
        # over framework defaults at <DOTBOT_HOME>/src/hooks/verify/ for
        # files of the same name; framework-only files still run. Sorted
        # by filename so the numbered convention (00-, 01-, ...) keeps
        # determining execution order.
        $scripts = Get-DotbotHookChain -BotRoot $botRoot -Phase verify
        $failedScript = $null

        Push-Location -LiteralPath $verifyCwd
        try {
            foreach ($s in $scripts) {
                try {
                    $raw = & pwsh -NoProfile -File $s.Path -TaskId $Task['id'] -Category ([string]$Task['category']) 2>$null
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
        } finally {
            Pop-Location
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
