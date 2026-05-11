if (-not (Get-Module PathSanitizer)) {
    Import-Module (Join-Path $global:DotbotProjectRoot ".bot/core/mcp/modules/PathSanitizer.psm1") -DisableNameChecking -Global
}

function Get-ExecutionActivityLog {
    param(
        [string]$TaskId,
        [string]$ProjectRoot
    )

    $controlDir  = Join-Path $global:DotbotProjectRoot ".bot\.control"
    $activityFile = Join-Path $controlDir "activity.jsonl"

    if (-not (Test-Path $activityFile)) { return @() }

    $taskActivities = [System.Collections.Generic.List[object]]::new()
    Get-Content $activityFile | ForEach-Object {
        try {
            $entry = $_ | ConvertFrom-Json
            if ($entry.task_id -eq $TaskId -and (-not $entry.phase -or $entry.phase -eq 'execution')) {
                $sanitizedMessage = Remove-AbsolutePaths -Text $entry.message -ProjectRoot $ProjectRoot
                $sanitizedEntry   = $entry | Select-Object -Property type, timestamp
                $sanitizedEntry | Add-Member -NotePropertyName 'message' -NotePropertyValue $sanitizedMessage -Force
                $taskActivities.Add($sanitizedEntry)
            }
        } catch { Write-BotLog -Level Debug -Message "ActivityLog: skipping malformed entry" -Exception $_ }
    }

    return $taskActivities.ToArray()
}

Export-ModuleMember -Function 'Get-ExecutionActivityLog'
