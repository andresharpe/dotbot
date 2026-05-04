# This is the default template for pattern-module-init.
# The dotbot codebase does NOT follow the canonical Public/Private dot-source
# split. Modules under core/ define functions inline and call
# Export-ModuleMember -Function 'A','B' at the bottom (or rely on the manifest
# FunctionsToExport list).
#
# The template below is the canonical advanced shape. It is kept here as
# aspirational reference. Do not flag dotbot modules for not following it.
#
# What to look for in a real canonical example:
#   - Public/Private dot-source split
#   - Strict mode and error preferences set at top
#   - Files loaded in a deterministic order
#   - Failures during load surface clearly (do not swallow)
#   - Export-ModuleMember explicit, never default
#   - No I/O during module load other than dot-sourcing

#requires -Version 7.4

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Resolve the module's own directory, robust to module relocation.
$ModuleRoot = $PSScriptRoot

# Ordered load: classes first, private functions next, public functions last.
# Pester tests are excluded.
$loadOrder = @(
    'Classes'
    'Private'
    'Public'
)

foreach ($subDir in $loadOrder) {
    $dirPath = Join-Path -Path $ModuleRoot -ChildPath $subDir
    if (-not (Test-Path -LiteralPath $dirPath)) { continue }

    $files = Get-ChildItem -Path $dirPath -Filter '*.ps1' -File -Recurse |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        Sort-Object FullName

    foreach ($file in $files) {
        try {
            . $file.FullName
        } catch {
            $writeErrorParams = @{
                Message      = "Failed to dot-source $($file.FullName): $($_.Exception.Message)"
                Category     = [System.Management.Automation.ErrorCategory]::OperationStopped
                ErrorId      = 'ModuleLoadError'
                TargetObject = $file.FullName
                Exception    = $_.Exception
                ErrorAction  = 'Stop'
            }
            Write-Error @writeErrorParams
        }
    }
}

# Export only what is in Public/. Source of truth: filenames in Public/.
$publicDir = Join-Path -Path $ModuleRoot -ChildPath 'Public'
if (Test-Path -LiteralPath $publicDir) {
    $publicFunctions = Get-ChildItem -Path $publicDir -Filter '*.ps1' -File -Recurse |
        Where-Object { $_.Name -notmatch '\.Tests\.ps1$' } |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }

    Export-ModuleMember -Function $publicFunctions
}
