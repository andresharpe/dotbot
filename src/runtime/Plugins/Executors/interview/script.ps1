function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    foreach ($key in @('runtime_root', 'bot_root', 'product_dir', 'process_id')) {
        if (-not $RunContext.Contains($key) -or -not $RunContext[$key]) {
            return @{
                Success  = $false
                Message  = "interview executor requires RunContext.$key."
                ExitCode = 2
            }
        }
    }

    # This executor runs in a fresh child runspace (default ISS). Invoke-InterviewLoop
    # relies on commands the runtime normally imports globally -- Write-Status
    # (Dotbot.Theme), Write-ProcessFile / Write-ProcessActivity / Add-JsonFrontMatter
    # (Dotbot.Process), New-HarnessSession / Invoke-HarnessStream (Dotbot.Harness),
    # Assert-TaskInputQuestionsData / Resolve-TaskInputAnswer (Dotbot.TaskInput).
    # Put the runtime Modules dir on PSModulePath so PowerShell auto-loads any of
    # them (and their transitive deps) on first use inside this runspace.
    $modulesDir = Join-Path ([string]$RunContext['runtime_root']) 'Modules'
    if ((Test-Path -LiteralPath $modulesDir) -and
        (($env:PSModulePath -split [System.IO.Path]::PathSeparator) -notcontains $modulesDir)) {
        $env:PSModulePath = $modulesDir + [System.IO.Path]::PathSeparator + $env:PSModulePath
    }

    $taskModule = Join-Path ([string]$RunContext['runtime_root']) 'Modules' 'Dotbot.Task' 'Dotbot.Task.psd1'
    Import-Module $taskModule -Force -DisableNameChecking

    # The child runspace does NOT inherit the parent's global variables, so the
    # $global:DotbotProjectRoot the runner set to the worktree is absent here.
    # The Claude harness falls back to $global:DotbotProjectRoot for Claude's cwd
    # (ClaudeCodeAdapter), so without this the interview's Claude writes
    # clarification-questions.json / interview-summary.md relative to the process
    # cwd (the MAIN project) while Invoke-InterviewLoop looks under the worktree
    # product_dir -- and reports "produced no output". Pin both globals to this
    # task's execution roots so the harness writes where the loop reads.
    if ($RunContext['project_root']) { $global:DotbotProjectRoot = [string]$RunContext['project_root'] }
    if ($RunContext['bot_root'])     { $global:DotbotBotRoot     = [string]$RunContext['bot_root'] }
    # dotbot STATE (task files, decisions) lives in the MAIN repo, not the
    # worktree (issue #515). The child-process harness path exports this; the
    # in-process path does not, so set it here from the run's state_root. The
    # interview funnel hook writes inbound decisions to this main .bot so they
    # match decision_create / decision_list and appear in the dashboard.
    if ($RunContext['state_root']) { $env:DOTBOT_STATE_ROOT = [string]$RunContext['state_root'] }

    $botRoot = [string]$RunContext['bot_root']
    $productDir = [string]$RunContext['product_dir']
    $userPrompt = Resolve-InterviewPrompt -Task $Task -RunContext $RunContext
    $processData = if ($RunContext.Contains('process_data')) { $RunContext['process_data'] } else { @{} }
    $taskId = if ($Task.Contains('id')) { [string]$Task['id'] } else { '' }

    Invoke-InterviewLoop -ProcessId ([string]$RunContext['process_id']) -ProcessData $processData `
        -BotRoot $botRoot -ProductDir $productDir -UserPrompt $userPrompt `
        -ShowDebugJson:([bool]$RunContext['show_debug']) `
        -ShowVerboseOutput:([bool]$RunContext['show_verbose']) `
        -PermissionMode ([string]$RunContext['permission_mode']) `
        -Generator 'dotbot-task-runner' -TaskId $taskId

    $summaryPath = Join-Path $productDir 'interview-summary.md'
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf -ErrorAction SilentlyContinue) {
        return @{
            Success  = $true
            Message  = "Interview completed: $summaryPath"
            ExitCode = 0
        }
    }

    return @{
        Success  = $false
        Message  = "Interview loop completed without producing $summaryPath"
        ExitCode = 1
    }
}

function Resolve-InterviewPrompt {
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    if ($Task.Contains('prompt') -and $Task['prompt']) {
        $promptValue = [string]$Task['prompt']
        $looksLikePath = -not [string]::IsNullOrWhiteSpace($promptValue) -and
            ($promptValue -notmatch "[`r`n]") -and
            ($promptValue.Length -lt 260) -and
            (
                [System.IO.Path]::IsPathRooted($promptValue) -or
                $promptValue -match '[\\/]' -or
                $promptValue -match '^\.\.?(?:[\\/]|$)' -or
                $promptValue -match '\.[A-Za-z0-9]+$'
            )
        if ($looksLikePath) {
            $candidates = @()
            foreach ($key in @('workflow_dir', 'bot_root')) {
                if ($RunContext.Contains($key) -and $RunContext[$key]) {
                    $candidates += (Join-Path ([string]$RunContext[$key]) $promptValue)
                }
            }
            $candidates += $promptValue
            foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
                try {
                    if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
                        return Get-Content -LiteralPath $candidate -Raw -ErrorAction Stop
                    }
                } catch {
                    return $promptValue
                }
            }
        }
        return $promptValue
    }

    # The launch prompt lives in the run's own directory (one folder per run).
    # The run dir is reachable here via the workspace/tasks junction. Fall back to
    # the legacy launchers locations for runs created before this change.
    $launchersBase = Join-Path ([string]$RunContext['bot_root']) '.control' 'launchers'
    $runId = if ($RunContext.Contains('run_id')) { [string]$RunContext['run_id'] } else { '' }
    $promptCandidates = @()
    if ($RunContext.Contains('run_dir') -and $RunContext['run_dir']) {
        $promptCandidates += (Join-Path ([string]$RunContext['run_dir']) 'workflow-launch-prompt.txt')
    }
    if ($runId) { $promptCandidates += (Join-Path (Join-Path $launchersBase $runId) 'workflow-launch-prompt.txt') }
    $promptCandidates += (Join-Path $launchersBase 'workflow-launch-prompt.txt')
    foreach ($defaultPromptPath in $promptCandidates) {
        if (Test-Path -LiteralPath $defaultPromptPath -PathType Leaf -ErrorAction SilentlyContinue) {
            try { return Get-Content -LiteralPath $defaultPromptPath -Raw -ErrorAction Stop } catch { }
        }
    }
    if ($Task.Contains('description') -and $Task['description']) { return [string]$Task['description'] }
    return ''
}

Export-ModuleMember -Function Invoke-Executor
