<#
.SYNOPSIS
Compatibility shim for runtime-owned task file mutation helpers.

.DESCRIPTION
Atomic task JSON file mutation now lives in Dotbot.TaskFile so runtime modules
do not depend on MCP modules for task persistence primitives. Existing MCP
callers can keep importing this module while MCP depends on runtime instead of
runtime depending on MCP.
#>

$taskFileModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime' 'Modules' 'Dotbot.TaskFile' 'Dotbot.TaskFile.psm1'
Import-Module $taskFileModule -DisableNameChecking -Force

function Write-TaskFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] $Content,
        [int]$Depth = 20,
        [string]$TaskId,
        [string]$BotRoot
    )
    Microsoft.PowerShell.Core\Import-Module $taskFileModule -DisableNameChecking -Force
    & (Microsoft.PowerShell.Core\Get-Command Write-TaskFileAtomic -Module Dotbot.TaskFile) @PSBoundParameters
}

function Write-TaskFileRawAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$RawContent,
        [string]$TaskId,
        [string]$BotRoot
    )
    Microsoft.PowerShell.Core\Import-Module $taskFileModule -DisableNameChecking -Force
    & (Microsoft.PowerShell.Core\Get-Command Write-TaskFileRawAtomic -Module Dotbot.TaskFile) @PSBoundParameters
}

function Move-TaskFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$TargetPath,
        [Parameter(Mandatory)] $Content,
        [int]$Depth = 20,
        [string]$TaskId,
        [string]$BotRoot
    )
    Microsoft.PowerShell.Core\Import-Module $taskFileModule -DisableNameChecking -Force
    & (Microsoft.PowerShell.Core\Get-Command Move-TaskFileAtomic -Module Dotbot.TaskFile) @PSBoundParameters
}

function Remove-TaskFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string]$TaskId,
        [string]$BotRoot
    )
    Microsoft.PowerShell.Core\Import-Module $taskFileModule -DisableNameChecking -Force
    & (Microsoft.PowerShell.Core\Get-Command Remove-TaskFileAtomic -Module Dotbot.TaskFile) @PSBoundParameters
}

function Invoke-WithTaskLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [Parameter(Mandatory)] [scriptblock]$Action,
        [string]$BotRoot,
        [int]$TimeoutSeconds = 30
    )
    Microsoft.PowerShell.Core\Import-Module $taskFileModule -DisableNameChecking -Force
    & (Microsoft.PowerShell.Core\Get-Command Invoke-WithTaskLock -Module Dotbot.TaskFile) @PSBoundParameters
}

Export-ModuleMember -Function @(
    'Write-TaskFileAtomic',
    'Write-TaskFileRawAtomic',
    'Move-TaskFileAtomic',
    'Remove-TaskFileAtomic',
    'Invoke-WithTaskLock'
)
