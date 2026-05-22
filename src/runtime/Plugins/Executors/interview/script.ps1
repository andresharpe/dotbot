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

    $taskModule = Join-Path ([string]$RunContext['runtime_root']) 'Modules' 'Dotbot.Task' 'Dotbot.Task.psd1'
    Import-Module $taskModule -Force -DisableNameChecking

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

    $defaultPromptPath = Join-Path ([string]$RunContext['bot_root']) '.control' 'launchers' 'workflow-launch-prompt.txt'
    if (Test-Path -LiteralPath $defaultPromptPath -PathType Leaf -ErrorAction SilentlyContinue) {
        try { return Get-Content -LiteralPath $defaultPromptPath -Raw -ErrorAction Stop } catch { }
    }
    if ($Task.Contains('description') -and $Task['description']) { return [string]$Task['description'] }
    return ''
}

Export-ModuleMember -Function Invoke-Executor
