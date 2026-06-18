<#
.SYNOPSIS
Script executor — runs a PowerShell script declared on the task.

Useful for workflows that mostly orchestrate without an AI in the loop:
the task declares `script_path` (and optionally `script_args` and
`working_directory`), this executor invokes the script inside the executor
runspace, captures pipeline output, and returns success based on the exit code.

The dispatcher already checks required_fields, so `script_path` is
guaranteed present by the time Invoke-Executor runs.
#>

function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    $scriptPath = Resolve-ScriptPath -ScriptPath ([string]$Task['script_path']) -RunContext $RunContext
    $scriptArgs = Resolve-ScriptArguments -ScriptPath $scriptPath -Task $Task -RunContext $RunContext
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
            Message  = "script_path '$($Task['script_path'])' does not exist."
            ExitCode = 2
        }
    }

    $previous = (Get-Location).Path
    $output = @()
    $exit = 0
    try {
        Set-Location -LiteralPath $workingDir
        $global:LASTEXITCODE = $null
        $output = @(& $scriptPath @scriptArgs 2>&1)
        $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    } catch {
        return @{
            Success  = $false
            Message  = "Script '$scriptPath' threw: $($_.Exception.Message)"
            ExitCode = 1
            stdout   = ($output | ForEach-Object { [string]$_ }) -join "`n"
            stderr   = $_.Exception.Message
        }
    } finally {
        try { Set-Location -LiteralPath $previous } catch { $null = $_ }
    }

    return @{
        Success  = ($exit -eq 0)
        Message  = if ($exit -eq 0) { "Script '$scriptPath' completed successfully." } else { "Script '$scriptPath' exited with code $exit." }
        ExitCode = $exit
        stdout   = ($output | ForEach-Object { [string]$_ }) -join "`n"
        stderr   = ''
    }
}

function Resolve-ScriptPath {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$RunContext
    )
    if ([System.IO.Path]::IsPathRooted($ScriptPath)) { return $ScriptPath }

    $candidates = @()
    foreach ($key in @('workflow_dir', 'runtime_root', 'bot_root')) {
        if ($RunContext.Contains($key) -and $RunContext[$key]) {
            $candidates += (Join-Path ([string]$RunContext[$key]) $ScriptPath)
        }
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf -ErrorAction SilentlyContinue) { return $c }
    }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $ScriptPath
}

function Resolve-ScriptArguments {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    if ($Task.Contains('script_args') -and $Task['script_args']) {
        if ($Task['script_args'] -is [System.Collections.IDictionary]) { return $Task['script_args'] }
        if ($Task['script_args'] -is [PSCustomObject]) {
            $bag = @{}
            foreach ($p in $Task['script_args'].PSObject.Properties) { $bag[$p.Name] = $p.Value }
            return $bag
        }
        return @($Task['script_args'])
    }

    $built = @{}
    try {
        $params = (Get-Command -Name $ScriptPath -ErrorAction Stop).Parameters
        if ($params.ContainsKey('BotRoot') -and $RunContext['bot_root']) { $built['BotRoot'] = $RunContext['bot_root'] }
        if ($params.ContainsKey('ProcessId') -and $RunContext['process_id']) { $built['ProcessId'] = $RunContext['process_id'] }
        if ($params.ContainsKey('Settings') -and $RunContext.Contains('settings')) { $built['Settings'] = $RunContext['settings'] }
        if ($params.ContainsKey('Model') -and $RunContext['model']) { $built['Model'] = $RunContext['model'] }
        if ($params.ContainsKey('WorkflowDir') -and $RunContext['workflow_dir']) { $built['WorkflowDir'] = $RunContext['workflow_dir'] }
    } catch {
        if ($RunContext['bot_root']) { $built['BotRoot'] = $RunContext['bot_root'] }
        if ($RunContext['process_id']) { $built['ProcessId'] = $RunContext['process_id'] }
    }
    return $built
}

Export-ModuleMember -Function Invoke-Executor
