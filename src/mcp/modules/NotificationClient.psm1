<#
.SYNOPSIS
Deprecated: use MothershipClient.psm1 instead.

.DESCRIPTION
This shim is kept for backward compatibility. It forwards to MothershipClient.psm1.
New callers should import MothershipClient.psm1 directly.
#>

Import-Module (Join-Path $PSScriptRoot 'MothershipClient.psm1') -Force -Global
