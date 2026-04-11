<#
.SYNOPSIS
Console/control sequence sanitization helpers.

.DESCRIPTION
Strips ANSI escape sequences and orphaned CSI fragments from status text so
terminal formatting artifacts do not leak into persisted process metadata or UI
rendering paths.
#>

# The second alternative intentionally strips orphaned CSI fragments after the
# ESC byte is lost, but requires CSI-like parameter content or the common
# parameterless "[m" reset fragment so plain bracketed words are preserved.
$script:ConsoleSequencePattern = "(\x1B\[[0-9;?]*[ -/]*[@-~])|(\[(?:[0-9?][0-9;?]*[ -/]*[A-Za-z]|m))"

function Remove-ConsoleSequences {
    param(
        [AllowNull()]
        [object]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $clean = [regex]::Replace([string]$Text, $script:ConsoleSequencePattern, "")
    return $clean.Trim()
}

function ConvertTo-SanitizedConsoleText {
    param(
        [AllowNull()]
        [object]$Text
    )

    $clean = Remove-ConsoleSequences $Text
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return $null
    }

    return $clean
}

function Update-ProcessHeartbeatFields {
    param(
        [Parameter(Mandatory)]
        [object]$Process
    )

    if ($Process.PSObject.Properties['heartbeat_status']) {
        $Process.heartbeat_status = ConvertTo-SanitizedConsoleText $Process.heartbeat_status
    }

    if ($Process.PSObject.Properties['heartbeat_next_action']) {
        $Process.heartbeat_next_action = ConvertTo-SanitizedConsoleText $Process.heartbeat_next_action
    }

    return $Process
}

Export-ModuleMember -Function @('ConvertTo-SanitizedConsoleText', 'Update-ProcessHeartbeatFields')
