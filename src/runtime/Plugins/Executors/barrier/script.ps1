function Invoke-Executor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Task,
        [Parameter(Mandatory)][hashtable]$RunContext
    )

    return @{
        Success  = $true
        Message  = "Barrier reached: $($Task['name'])"
        ExitCode = 0
    }
}

Export-ModuleMember -Function Invoke-Executor
