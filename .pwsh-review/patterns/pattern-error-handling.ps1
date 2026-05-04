# Canonical error-handling example for the dotbot codebase.
# Adapted from core/runtime/modules/SettingsLoader.psm1 (Get-MergedSettings).
# The original demonstrates:
#   - Tolerant layered reads (per-layer try/catch with warning + fall-through)
#   - Logging via Write-BotLog when available, with a soft fallback
#   - Predictable empty-state return when no layer is parseable
#
# The version below is annotated and includes terminating-error patterns
# expected of dotbot code that does not have a tolerant fall-through path.
# Rule of thumb: a per-item try/catch that emits a warning is acceptable
# only when the function is genuinely tolerant. Otherwise use Write-Error
# -ErrorAction Stop with a stable -ErrorId.

function Get-MergedSettingsExample {
    <#
    .SYNOPSIS
        Returns a deep-merged PSCustomObject combining the three dotbot settings layers.

    .DESCRIPTION
        Reads (in order) settings.default.json, ~/dotbot/user-settings.json, and
        .control/settings.json. Missing files are silently skipped. Malformed JSON
        in one layer logs a warning and falls through to the remaining layers.

        Returns an empty PSCustomObject if no layer is present or parseable.

    .PARAMETER BotRoot
        The .bot root directory for the current project.

    .EXAMPLE
        $settings = Get-MergedSettingsExample -BotRoot ~/myproject/.bot

    .OUTPUTS
        [pscustomobject]
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$BotRoot
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    if (-not (Test-Path -LiteralPath $BotRoot)) {
        # Stable error ID lets tests assert on it without parsing the message.
        $writeErrorParams = @{
            Message      = "BotRoot does not exist: $BotRoot"
            Category     = [System.Management.Automation.ErrorCategory]::ObjectNotFound
            ErrorId      = 'BotRootNotFound'
            TargetObject = $BotRoot
            ErrorAction  = 'Stop'
        }
        Write-Error @writeErrorParams
    }

    $layerFiles = @(
        (Join-Path $BotRoot 'settings/settings.default.json'),
        (Join-Path $HOME 'dotbot' 'user-settings.json'),
        (Join-Path $BotRoot '.control/settings.json')
    )

    $merged = $null

    foreach ($layerFile in $layerFiles) {
        if (-not (Test-Path -LiteralPath $layerFile)) { continue }

        try {
            $layerContent = Get-Content -LiteralPath $layerFile -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch [System.Management.Automation.ItemNotFoundException], [System.Text.Json.JsonException], [System.ArgumentException] {
            # Tolerant fall-through is intentional here. The function is
            # documented to skip malformed layers and prefer remaining layers
            # over failing the whole read. Other functions should NOT be
            # this tolerant - they should re-raise via Write-Error -ErrorAction Stop.
            if (Get-Command Write-BotLog -ErrorAction SilentlyContinue) {
                Write-BotLog -Level Warn -Message "Failed to parse settings layer: $layerFile" -Exception $_
            }
            continue
        }

        if ($null -eq $merged) {
            $merged = $layerContent
        } else {
            $merged = Merge-DeepSettings $merged $layerContent
        }
    }

    if ($null -eq $merged) {
        return [pscustomobject]@{}
    }

    return $merged
}
