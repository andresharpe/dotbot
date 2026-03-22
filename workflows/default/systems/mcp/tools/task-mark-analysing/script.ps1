# Import session tracking module
Import-Module (Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\SessionTracking.psm1") -Force

function Invoke-TaskMarkAnalysing {
    param(
        [hashtable]$Arguments
    )

    function Set-OrAddProperty {
        param(
            [Parameter(Mandatory)] [psobject]$Object,
            [Parameter(Mandatory)] [string]$Name,
            [Parameter()] $Value
        )

        if ($Object.PSObject.Properties[$Name]) {
            $Object.$Name = $Value
        } else {
            $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
        }
    }

    # Extract arguments
    $taskId = $Arguments['task_id']

    # Validate required fields
    if (-not $taskId) {
        throw "Task ID is required"
    }
    
    # Define tasks directories
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    [Console]::Error.WriteLine("[task-mark-analysing] tasksBaseDir=$tasksBaseDir exists=$(Test-Path $tasksBaseDir)")
    $todoDir = Join-Path $tasksBaseDir "todo"
    $analysingDir = Join-Path $tasksBaseDir "analysing"
    
    # Find the task file in todo or analysing (idempotent for resumed tasks)
    $taskFile = $null
    $oldStatus = 'todo'

    # Check todo first
    if (Test-Path $todoDir) {
        $files = Get-ChildItem -Path $todoDir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    $taskFile = $file
                    $oldStatus = 'todo'
                    break
                }
            } catch {
                # Continue searching
            }
        }
    }

    # If not in todo, check if already in analysing (idempotent)
    if (-not $taskFile -and (Test-Path $analysingDir)) {
        $files = Get-ChildItem -Path $analysingDir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $taskId) {
                    # Already analysing - return success (idempotent)
                    return @{
                        success = $true
                        message = "Task already in analysing status"
                        task_id = $taskId
                        task_name = $content.name
                        old_status = 'analysing'
                        new_status = 'analysing'
                        analysis_started_at = $content.analysis_started_at
                        file_path = $file.FullName
                    }
                }
            } catch {
                # Continue searching
            }
        }
    }

    if (-not $taskFile) {
        throw "Task with ID '$taskId' not found in todo or analysing status"
    }

    # Read task content
    $taskContent = Get-Content -Path $taskFile.FullName -Raw | ConvertFrom-Json

    # Update task properties
    Set-OrAddProperty -Object $taskContent -Name 'status' -Value 'analysing'
    Set-OrAddProperty -Object $taskContent -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))

    # Add analysis_started_at timestamp
    Set-OrAddProperty -Object $taskContent -Name 'analysis_started_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))

    # Track Claude session for conversation continuity
    $claudeSessionId = $env:CLAUDE_SESSION_ID
    if ($claudeSessionId) {
        Add-SessionToTask -TaskContent $taskContent -SessionId $claudeSessionId -Phase 'analysis'
    }

    # Ensure analysing directory exists
    if (-not (Test-Path $analysingDir)) {
        New-Item -ItemType Directory -Force -Path $analysingDir | Out-Null
    }

    # Move file to analysing directory
    $newFilePath = Join-Path $analysingDir $taskFile.Name

    # Save updated task to new location
    $taskContent | ConvertTo-Json -Depth 10 | Set-Content -Path $newFilePath -Encoding UTF8
    Remove-Item -Path $taskFile.FullName -Force

    # Return result
    return @{
        success = $true
        message = "Task marked as analysing"
        task_id = $taskId
        task_name = $taskContent.name
        old_status = $oldStatus
        new_status = 'analysing'
        analysis_started_at = $taskContent.analysis_started_at
        file_path = $newFilePath
    }
}
