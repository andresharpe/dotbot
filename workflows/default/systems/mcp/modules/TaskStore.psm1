<#
.SYNOPSIS
Centralised task store — atomic state transitions and CRUD operations.

.DESCRIPTION
Provides Move-TaskState (atomic, validated), Get-TaskByIdOrSlug (unified lookup),
New-TaskRecord (create with defaults), and Update-TaskRecord (merge-update).
TaskIndexCache.psm1 remains the read-only query layer.
#>

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:ValidStatuses = @(
    'todo', 'analysing', 'needs-input', 'analysed',
    'in-progress', 'done', 'split', 'skipped', 'cancelled'
)

$script:ReservedFields = @('status', 'updated_at', 'id', 'created_at')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-DotbotProjectRoot {
    if ($global:DotbotProjectRoot) {
        return $global:DotbotProjectRoot
    }

    $cursor = $PSScriptRoot
    while ($cursor) {
        if ((Split-Path -Leaf $cursor) -eq ".bot") {
            return (Split-Path -Parent $cursor)
        }

        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }

    throw "Dotbot project root could not be resolved"
}

function Get-TasksBaseDir {
    param(
        [string]$TasksBaseDir
    )

    if ($TasksBaseDir) {
        return $TasksBaseDir
    }

    $projectRoot = Get-DotbotProjectRoot
    return (Join-Path $projectRoot ".bot\workspace\tasks")
}

function Get-TodoDirectories {
    param(
        [string]$TasksBaseDir
    )

    $resolvedBaseDir = Get-TasksBaseDir -TasksBaseDir $TasksBaseDir
    $todoDir = Join-Path $resolvedBaseDir "todo"
    $editedDir = Join-Path $todoDir "edited_tasks"
    $deletedDir = Join-Path $todoDir "deleted_tasks"

    return @{
        TasksBaseDir = $resolvedBaseDir
        TodoDir      = $todoDir
        EditedDir    = $editedDir
        DeletedDir   = $deletedDir
    }
}

function Ensure-TodoDirectories {
    param(
        [string]$TasksBaseDir
    )

    $paths = Get-TodoDirectories -TasksBaseDir $TasksBaseDir
    foreach ($dir in @($paths.TodoDir, $paths.EditedDir, $paths.DeletedDir)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $paths
}

function Get-TodoTaskRecord {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,
        [string]$TasksBaseDir
    )

    $paths = Get-TodoDirectories -TasksBaseDir $TasksBaseDir
    if (-not (Test-Path -Path $paths.TodoDir -PathType Container)) {
        return $null
    }
    $files = Get-ChildItem -Path $paths.TodoDir -Filter "*.json" -File -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        try {
            $task = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if ($task.id -eq $TaskId) {
                return @{
                    task           = $task
                    path           = $file.FullName
                    file_name      = $file.Name
                    todo_dir       = $paths.TodoDir
                    edited_dir     = $paths.EditedDir
                    deleted_dir    = $paths.DeletedDir
                    tasks_base_dir = $paths.TasksBaseDir
                }
            }
        } catch {
            Write-BotLog -Level Warn -Message "[TaskStore] Failed to read task file '$($file.FullName)'" -Exception $_
        }
    }

    return $null
}

function Get-StatusDir {
    param([string]$Status)
    return (Join-Path (Get-TasksBaseDir) $Status)
}

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

function Find-TaskFileById {
    <#
    .SYNOPSIS
    Searches status directories for a task JSON file matching the given ID.
    Returns @{ File = <FileInfo>; Status = <string>; Content = <PSObject> } or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [string[]]$SearchStatuses
    )

    if (-not $SearchStatuses) {
        $SearchStatuses = $script:ValidStatuses
    }

    foreach ($status in $SearchStatuses) {
        $dir = Get-StatusDir -Status $status
        if (-not (Test-Path $dir)) { continue }

        $files = Get-ChildItem -Path $dir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $TaskId) {
                    return @{
                        File    = $file
                        Status  = $status
                        Content = $content
                    }
                }
            } catch {
                # Malformed JSON — skip
            }
        }
    }
    return $null
}

function Assert-ValidStatus {
    param([string]$Status, [string]$ParameterName)
    if ($Status -notin $script:ValidStatuses) {
        throw "$ParameterName '$Status' is not valid. Allowed: $($script:ValidStatuses -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Move-TaskState
# ---------------------------------------------------------------------------

function Move-TaskState {
    <#
    .SYNOPSIS
    Atomic, validated task state transition.

    .DESCRIPTION
    Finds a task by ID in one of the -FromStates directories, validates the
    transition, applies -Updates, sets status/updated_at, and moves the file
    to the target status directory. Returns a result hashtable.

    Idempotent: if the task is already in -ToState, returns success with
    already_in_state = $true and does NOT apply -Updates.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string[]]$FromStates,
        [Parameter(Mandatory)][string]$ToState,
        [hashtable]$Updates = @{}
    )

    # Validate states
    foreach ($s in $FromStates) { Assert-ValidStatus -Status $s -ParameterName 'FromStates' }
    Assert-ValidStatus -Status $ToState -ParameterName 'ToState'

    # Block reserved fields in Updates
    foreach ($key in @($Updates.Keys)) {
        if ($key -in $script:ReservedFields) {
            throw "Cannot override reserved field '$key' via -Updates. Use Move-TaskState parameters instead."
        }
    }

    # Search in FromStates + ToState (for idempotent handling)
    $searchStatuses = @($FromStates) + @($ToState) | Select-Object -Unique
    $found = Find-TaskFileById -TaskId $TaskId -SearchStatuses $searchStatuses

    if (-not $found) {
        throw "Task '$TaskId' not found in statuses: $($searchStatuses -join ', ')"
    }

    # Idempotent: already in target state
    if ($found.Status -eq $ToState) {
        return @{
            success          = $true
            already_in_state = $true
            task_id          = $TaskId
            task_name        = $found.Content.name
            old_status       = $ToState
            new_status       = $ToState
            file_path        = $found.File.FullName
            task_content     = $found.Content
        }
    }

    $taskContent = $found.Content
    $oldStatus   = $found.Status

    # Set standard fields
    Set-OrAddProperty -Object $taskContent -Name 'status'     -Value $ToState
    Set-OrAddProperty -Object $taskContent -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))

    # Apply caller updates
    foreach ($key in $Updates.Keys) {
        Set-OrAddProperty -Object $taskContent -Name $key -Value $Updates[$key]
    }

    # Ensure target directory exists
    $targetDir = Get-StatusDir -Status $ToState
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }

    # Write to new location, then remove old file
    $newFilePath = Join-Path $targetDir $found.File.Name

    $oldPathResolved = [System.IO.Path]::GetFullPath($found.File.FullName)
    $newPathResolved = [System.IO.Path]::GetFullPath($newFilePath)

    if ($oldPathResolved -ne $newPathResolved) {
        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $newFilePath -Encoding UTF8
        Remove-Item -Path $found.File.FullName -Force
    } else {
        # Same directory (e.g. re-skipping) — update in place
        $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $found.File.FullName -Encoding UTF8
    }

    return @{
        success          = $true
        already_in_state = $false
        task_id          = $TaskId
        task_name        = $taskContent.name
        old_status       = $oldStatus
        new_status       = $ToState
        file_path        = if ($oldPathResolved -ne $newPathResolved) { $newFilePath } else { $found.File.FullName }
        task_content     = $taskContent
    }
}

# ---------------------------------------------------------------------------
# Get-TaskByIdOrSlug
# ---------------------------------------------------------------------------

function Get-TaskByIdOrSlug {
    <#
    .SYNOPSIS
    Unified lookup — finds a task by ID or slug across all status directories.
    #>
    param(
        [Parameter(Mandatory)][string]$Identifier
    )

    foreach ($status in $script:ValidStatuses) {
        $dir = Get-StatusDir -Status $status
        if (-not (Test-Path $dir)) { continue }

        $files = Get-ChildItem -Path $dir -Filter "*.json" -File
        foreach ($file in $files) {
            try {
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($content.id -eq $Identifier) {
                    return @{ File = $file; Status = $status; Content = $content }
                }
                # Check slug (filename minus .json, or slug field)
                $slug = $file.BaseName
                if ($slug -eq $Identifier -or $content.slug -eq $Identifier) {
                    return @{ File = $file; Status = $status; Content = $content }
                }
            } catch {
                # Malformed JSON — skip
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# New-TaskRecord
# ---------------------------------------------------------------------------

function New-TaskRecord {
    <#
    .SYNOPSIS
    Creates a new task with sensible defaults and writes it to the todo directory.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Properties
    )

    if (-not $Properties.ContainsKey('name')) {
        throw "New-TaskRecord: 'name' property is required and must be a non-empty string."
    }

    $name = $Properties['name']
    if (-not ($name -is [string]) -or [string]::IsNullOrWhiteSpace($name)) {
        throw "New-TaskRecord: 'name' property must be a non-empty string."
    }

    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $id  = if ($Properties.ContainsKey('id')) { $Properties['id'] } else { [guid]::NewGuid().ToString() }

    $task = [PSCustomObject]@{
        id          = $id
        name        = $name
        description = if ($Properties.ContainsKey('description')) { $Properties['description'] } else { '' }
        category    = if ($Properties.ContainsKey('category'))    { $Properties['category'] }    else { 'feature' }
        status      = 'todo'
        priority    = if ($Properties.ContainsKey('priority'))    { $Properties['priority'] }    else { 50 }
        effort      = if ($Properties.ContainsKey('effort'))      { $Properties['effort'] }      else { 'M' }
        created_at  = $now
        updated_at  = $now
    }

    # Merge any additional properties
    $coreKeys = @('id', 'name', 'description', 'category', 'status', 'priority', 'effort', 'created_at', 'updated_at')
    foreach ($key in $Properties.Keys) {
        if ($key -notin $coreKeys) {
            $task | Add-Member -NotePropertyName $key -NotePropertyValue $Properties[$key] -Force
        }
    }

    # Write to todo directory
    $todoDir = Get-StatusDir -Status 'todo'
    if (-not (Test-Path $todoDir)) {
        New-Item -ItemType Directory -Force -Path $todoDir | Out-Null
    }

    # Build filename
    $safeName = ( ($task.name -replace '[^a-zA-Z0-9\s-]', '') -replace '\s+', '-' ).ToLowerInvariant()
    if ($safeName.Length -gt 50) { $safeName = $safeName.Substring(0, 50) }
    if ([string]::IsNullOrEmpty($safeName)) { $safeName = 'task' }
    $shortId  = $id.Substring(0, [Math]::Min(8, $id.Length))
    $fileName = "$safeName-$shortId.json"

    $filePath = Join-Path $todoDir $fileName
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8

    return @{
        success   = $true
        task_id   = $id
        task_name = $task.name
        file_path = $filePath
        task      = $task
    }
}

# ---------------------------------------------------------------------------
# Update-TaskRecord
# ---------------------------------------------------------------------------

function Update-TaskRecord {
    <#
    .SYNOPSIS
    Merge-updates a task's properties in place. Cannot change status — use
    Move-TaskState for that.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][hashtable]$Updates
    )

    # Block status changes
    if ($Updates.ContainsKey('status')) {
        throw "Cannot update 'status' via Update-TaskRecord. Use Move-TaskState instead."
    }

    # Block other reserved fields
    foreach ($key in @($Updates.Keys)) {
        if ($key -in @('id', 'created_at')) {
            throw "Cannot update reserved field '$key'."
        }
    }
    # Silently remove updated_at if supplied — it's set automatically below
    $Updates.Remove('updated_at') | Out-Null

    $found = Find-TaskFileById -TaskId $TaskId
    if (-not $found) {
        throw "Task '$TaskId' not found"
    }

    $taskContent = $found.Content
    Set-OrAddProperty -Object $taskContent -Name 'updated_at' -Value ((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))

    foreach ($key in $Updates.Keys) {
        Set-OrAddProperty -Object $taskContent -Name $key -Value $Updates[$key]
    }

    $taskContent | ConvertTo-Json -Depth 20 | Set-Content -Path $found.File.FullName -Encoding UTF8

    return @{
        success      = $true
        task_id      = $TaskId
        task_name    = $taskContent.name
        status       = $found.Status
        file_path    = $found.File.FullName
        task_content = $taskContent
    }
}

function Get-TaskSlug {
    param([string]$TaskName)
    $slug = $TaskName.ToLowerInvariant()
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug -replace '^-|-$', ''
    if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50) -replace '-$', '' }
    return $slug
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

Export-ModuleMember -Function @(
    'Move-TaskState',
    'Get-TaskByIdOrSlug',
    'New-TaskRecord',
    'Update-TaskRecord',
    'Find-TaskFileById',
    'Set-OrAddProperty',
    'Get-TasksBaseDir',
    'Get-StatusDir',
    'Get-TodoDirectories',
    'Ensure-TodoDirectories',
    'Get-TodoTaskRecord',
    'Get-TaskSlug'
)
