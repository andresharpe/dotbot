function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    if (-not $RunContext.Contains('runtime_root') -or -not $RunContext['runtime_root']) {
        return @{
            Success  = $false
            Message  = "task_gen executor requires RunContext.runtime_root."
            ExitCode = 2
        }
    }

    $scriptExecutor = Join-Path ([string]$RunContext['runtime_root']) 'Plugins' 'Executors' 'script' 'script.ps1'
    if (-not (Test-Path -LiteralPath $scriptExecutor -PathType Leaf)) {
        return @{
            Success  = $false
            Message  = "script executor not found: $scriptExecutor"
            ExitCode = 2
        }
    }

    $module = New-Module -ScriptBlock ([scriptblock]::Create((Get-Content -LiteralPath $scriptExecutor -Raw))) -Name 'dotbot-executor-script-delegate'
    try {
        $result = & $module Invoke-Executor -Task $Task -RunContext $RunContext
        if ($result -is [System.Collections.IDictionary] -and $result.Contains('Message')) {
            $result['Message'] = "Task generator: $($result['Message'])"
        }
        return $result
    } finally {
        try { Remove-Module $module -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
}

Export-ModuleMember -Function Invoke-Executor
