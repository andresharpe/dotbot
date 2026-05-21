<#
.SYNOPSIS
Compatibility shim for the runtime-owned path sanitizer.

.DESCRIPTION
Remove-AbsolutePaths now lives in Dotbot.Core so runtime modules do not depend
on MCP modules. Existing MCP callers can keep importing PathSanitizer while the
dependency direction is reversed: MCP imports runtime Core.
#>

$coreModule = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'runtime' 'Modules' 'Dotbot.Core' 'Dotbot.Core.psm1'
Import-Module $coreModule -DisableNameChecking -Force

Export-ModuleMember -Function 'Remove-AbsolutePaths'
