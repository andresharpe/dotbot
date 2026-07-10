# All decision generation lives in New-DecisionRecord on the Dotbot.Decision
# runtime module -- the single point that owns the record shape, validation, and
# write. Resolved relative to this tool script so it works in both the source
# tree and a vendored .bot/src deployment (same relative layout in both).
Import-Module (Join-Path $PSScriptRoot ".." ".." ".." "runtime" "Modules" "Dotbot.Decision" "Dotbot.Decision.psd1") -DisableNameChecking -Global

function Invoke-DecisionCreate {
    param([hashtable]$Arguments)

    # Pure caller, zero generation logic. The default status stays 'proposed'
    # (set inside New-DecisionRecord) to preserve the AI-agent path's behaviour.
    return New-DecisionRecord -Arguments $Arguments
}
