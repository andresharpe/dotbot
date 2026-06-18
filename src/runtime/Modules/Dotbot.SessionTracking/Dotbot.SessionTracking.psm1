<#
.SYNOPSIS
Session tracking utilities for Claude Code session continuation

.DESCRIPTION
Provides functions for tracking Claude session IDs on tasks to enable
conversation continuation when analysis is paused for user input.

Sessions are stored in three places:
1. Signal files (.bot/.control/analysing.signal) - for observability while running
2. Task JSON claude_session_id - current session for resumption
3. Task JSON session arrays - full history for debugging/audit
#>

function Add-SessionToTask {
    <#
    .SYNOPSIS
    Add a new session entry to a task's session history array

    .PARAMETER TaskContent
    The task content object (PSCustomObject from JSON)

    .PARAMETER SessionId
    The Claude session ID to track

    .PARAMETER Phase
    Which phase this session is for: 'analysis' or 'execution'
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskContent,

        [Parameter(Mandatory = $false)]
        [string]$SessionId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('analysis', 'execution')]
        [string]$Phase
    )

    if (-not $SessionId) { return }

    $arrayName = "${Phase}_sessions"

    # Initialize array if it doesn't exist
    if (-not $TaskContent.PSObject.Properties[$arrayName]) {
        $TaskContent | Add-Member -NotePropertyName $arrayName -NotePropertyValue @() -Force
    }

    # Create session entry
    $entry = [PSCustomObject]@{
        id = $SessionId
        started_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        ended_at = $null
    }

    # Add to array (convert to array if needed, then append)
    $existingSessions = @($TaskContent.$arrayName)
    $TaskContent.$arrayName = $existingSessions + @($entry)

    # Set current session ID for resumption
    if (-not $TaskContent.PSObject.Properties['claude_session_id']) {
        $TaskContent | Add-Member -NotePropertyName 'claude_session_id' -NotePropertyValue $null -Force
    }
    $TaskContent.claude_session_id = $SessionId
}

function Close-SessionOnTask {
    <#
    .SYNOPSIS
    Mark a session as ended in the task's session history array

    .PARAMETER TaskContent
    The task content object (PSCustomObject from JSON)

    .PARAMETER SessionId
    The Claude session ID to close

    .PARAMETER Phase
    Which phase this session is for: 'analysis' or 'execution'
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskContent,

        [Parameter(Mandatory = $false)]
        [string]$SessionId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('analysis', 'execution')]
        [string]$Phase
    )

    if (-not $SessionId) { return }

    $arrayName = "${Phase}_sessions"

    # If array doesn't exist, nothing to close
    if (-not $TaskContent.PSObject.Properties[$arrayName]) {
        return
    }

    # Find and update the session entry
    foreach ($session in $TaskContent.$arrayName) {
        if ($session.id -eq $SessionId -and -not $session.ended_at) {
            $session.ended_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            break
        }
    }
}

function Get-SessionFromTask {
    <#
    .SYNOPSIS
    Get the current Claude session ID from a task for resumption

    .PARAMETER TaskContent
    The task content object (PSCustomObject from JSON)

    .OUTPUTS
    The session ID string, or $null if none stored
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$TaskContent
    )

    if ($TaskContent.PSObject.Properties['claude_session_id']) {
        return $TaskContent.claude_session_id
    }

    return $null
}

Export-ModuleMember -Function @(
    'Add-SessionToTask'
    'Close-SessionOnTask'
    'Get-SessionFromTask'
)
