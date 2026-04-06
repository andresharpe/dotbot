<#
.SYNOPSIS
Workspace instance ID utilities.

.DESCRIPTION
Provides a stable per-workspace GUID by reading and repairing
`.bot/settings/settings.default.json` when needed.
#>

function Get-OrCreateWorkspaceInstanceId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    if (-not (Test-Path $SettingsPath)) {
        return $null
    }

    try {
        $settings = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }

    $currentInstanceId = if ($settings.PSObject.Properties['instance_id']) {
        "$($settings.instance_id)"
    } else {
        ""
    }

    $parsedGuid = [guid]::Empty
    if ([guid]::TryParse($currentInstanceId, [ref]$parsedGuid)) {
        $normalized = $parsedGuid.ToString()
        if ($currentInstanceId -ne $normalized) {
            $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue $normalized -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath
        }
        return $normalized
    }

    $newInstanceId = [guid]::NewGuid().ToString()
    $settings | Add-Member -NotePropertyName "instance_id" -NotePropertyValue $newInstanceId -Force
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsPath
    return $newInstanceId
}

Export-ModuleMember -Function @('Get-OrCreateWorkspaceInstanceId')
