<#
.SYNOPSIS
Task mutation helpers for todo edits, deletions, restores, and ignore state.

.DESCRIPTION
Provides audited mutations for todo tasks. Edited and deleted snapshots are
archived under todo\edited_tasks and todo\deleted_tasks so operators can view
or restore previous versions.
#>

Import-Module (Join-Path $PSScriptRoot "TaskStore.psm1") -Force

function Get-ArchiveActor {
    param(
        [string]$Actor
    )

    if ($Actor) {
        return $Actor
    }

    $userName = [System.Environment]::UserName
    if ($userName) {
        return $userName
    }

    return "unknown"
}

function Get-AuditUsername {
    if ($IsWindows) {
        try {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            if ($identity -and $identity.Name) {
                return $identity.Name
            }
        } catch {
            # Fall back to cross-platform APIs below.
        }
    }

    $user = [System.Environment]::UserName

    if ($IsWindows) {
        $domain = [System.Environment]::UserDomainName
        if ($domain -and $user -and $domain -ne $user) {
            return "$domain\$user"
        }
    }

    if ($user) {
        return $user
    }

    return "unknown"
}

function Set-TaskAuditUser {
    param(
        [Parameter(Mandatory)]
        [object]$Target,
        [string]$PropertyName = "updated_by_user",
        [string]$UserName
    )

    $resolvedUserName = if ($UserName) { $UserName } else { Get-AuditUsername }
    if ($Target.PSObject.Properties[$PropertyName]) {
        $Target.$PropertyName = $resolvedUserName
    } else {
        $Target | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $resolvedUserName -Force
    }
}
function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("o")
}

function ConvertTo-DeepClone {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    return ($InputObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}

function ConvertTo-TaskArray {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        return @($Value)
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value)
    }

    return @($Value)
}

function Get-TaskPriorityValue {
    param(
        [object]$Task
    )

    try {
        if ($null -ne $Task.priority -and "$($Task.priority)".Trim()) {
            return [int]$Task.priority
        }
    } catch {
        # Keep malformed priorities at the end of the ordinal alias list.
    }

    return [int]::MaxValue
}

function Add-TaskReferenceAlias {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ReferenceMap,
        [Parameter(Mandatory)]
        [string]$TaskId,
        [object]$Alias
    )

    if ($null -eq $Alias) {
        return
    }

    $normalizedAlias = "$Alias".Trim().ToLowerInvariant()
    if (-not $normalizedAlias) {
        return
    }

    $ReferenceMap[$normalizedAlias] = $TaskId
}

function Get-TaskDependencyReferenceTokens {
    param(
        [object]$Dependency
    )

    if ($null -eq $Dependency) {
        return @()
    }

    $rawDependency = "$Dependency".Trim()
    if (-not $rawDependency) {
        return @()
    }

    $tokens = [System.Collections.Generic.List[string]]::new()

    function Add-DependencyToken {
        param(
            [string]$Value
        )

        if (-not $Value) {
            return
        }

        $normalizedValue = $Value.Trim().ToLowerInvariant()
        if ($normalizedValue -and -not $tokens.Contains($normalizedValue)) {
            $null = $tokens.Add($normalizedValue)
        }
    }

    Add-DependencyToken -Value $rawDependency

    $ordinalMatch = [regex]::Match($rawDependency, '^tasks?\s+(.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($ordinalMatch.Success) {
        $ordinalExpression = $ordinalMatch.Groups[1].Value.Trim()
        Add-DependencyToken -Value $ordinalExpression

        foreach ($part in ($ordinalExpression -split '\s*,\s*')) {
            $normalizedPart = [regex]::Replace($part, '^tasks?\s+', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()
            if (-not $normalizedPart) {
                continue
            }

            Add-DependencyToken -Value $normalizedPart
            Add-DependencyToken -Value "task $normalizedPart"
        }

        return @($tokens)
    }

    foreach ($part in ($rawDependency -split '\s*,\s*')) {
        Add-DependencyToken -Value $part
    }

    return @($tokens)
}

function Get-RoadmapOverviewDependencyMap {
    param(
        [string]$TasksBaseDir
    )

    $resolvedBaseDir = Get-TasksBaseDir -TasksBaseDir $TasksBaseDir
    $workspaceDir = Split-Path -Parent $resolvedBaseDir
    $overviewPath = Join-Path $workspaceDir "product\roadmap-overview.md"
    $dependencyMap = @{}
    if (-not (Test-Path $overviewPath)) {
        return $dependencyMap
    }

    foreach ($line in @(Get-Content -Path $overviewPath -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '^\|\s*\d+\s*\|') {
            continue
        }

        $cells = ($line.Trim().Trim('|') -split '\s*\|\s*')
        if ($cells.Count -lt 5) {
            continue
        }

        $methodologyMatch = [regex]::Match($cells[2], '`([^`]+)`')
        if (-not $methodologyMatch.Success) {
            continue
        }

        $methodologyKey = $methodologyMatch.Groups[1].Value.Trim().ToLowerInvariant()
        if (-not $methodologyKey) {
            continue
        }

        $dependencyText = $cells[3].Trim()
        if (-not $dependencyText -or $dependencyText -match '^(none|n/a)$') {
            $dependencyMap[$methodologyKey] = @()
            continue
        }

        $dependencyMap[$methodologyKey] = @($dependencyText)
    }

    return $dependencyMap
}

function Get-ResolvedTaskDependencies {
    param(
        [Parameter(Mandatory)]
        [object]$Task,
        [Parameter(Mandatory)]
        [hashtable]$RoadmapDependencyMap
    )

    $explicitDependencies = @((ConvertTo-TaskArray -Value $Task.dependencies) | Where-Object { $null -ne $_ -and "$($_)".Trim() })
    if ($explicitDependencies.Count -gt 0) {
        return $explicitDependencies
    }

    $researchPrompt = "$($Task.research_prompt)".Trim().ToLowerInvariant()
    if ($researchPrompt -and $RoadmapDependencyMap.ContainsKey($researchPrompt)) {
        return @($RoadmapDependencyMap[$researchPrompt])
    }

    return @()
}

function Save-TaskFile {
    param(
        [Parameter(Mandatory)]
        [object]$Task,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Task | ConvertTo-Json -Depth 30 | Set-Content -Path $Path -Encoding UTF8
}

function Write-TaskArchive {
    param(
        [Parameter(Mandatory)]
        [object]$Task,
        [Parameter(Mandatory)]
        [string]$ArchiveDir,
        [Parameter(Mandatory)]
        [ValidateSet("edit", "delete")]
        [string]$ArchiveKind,
        [Parameter(Mandatory)]
        [string]$Actor,
        [string]$SourceStatus = "todo",
        [string]$SourceFileName = ""
    )

    if (-not (Test-Path $ArchiveDir)) {
        New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
    }

    $capturedAt = Get-UtcTimestamp
    $versionId = [guid]::NewGuid().ToString()
    $safeTaskId = ($Task.id -replace '[^a-zA-Z0-9_-]', '_')
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmssfff")
    $archivePath = Join-Path $ArchiveDir "$safeTaskId--$stamp--$($versionId.Substring(0, 8)).json"

    $archiveRecord = [ordered]@{
        version_id = $versionId
        task_id = $Task.id
        archive_kind = $ArchiveKind
        source_status = $SourceStatus
        source_file_name = $SourceFileName
        captured_at = $capturedAt
        captured_by = $Actor
        captured_by_user = Get-AuditUsername
        task = ConvertTo-DeepClone -InputObject $Task
    }

    $archiveRecord | ConvertTo-Json -Depth 30 | Set-Content -Path $archivePath -Encoding UTF8

    return ($archiveRecord | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}
function Get-NonTodoTaskIds {
    param(
        [string]$TasksBaseDir
    )

    $resolvedBaseDir = Get-TasksBaseDir -TasksBaseDir $TasksBaseDir
    $nonTodoTaskIds = @{}

    foreach ($status in @('analysing', 'needs-input', 'analysed', 'in-progress', 'done', 'split', 'skipped', 'cancelled')) {
        $statusDir = Join-Path $resolvedBaseDir $status
        if (-not (Test-Path $statusDir)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -Path $statusDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $task = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                if ($task.id) {
                    $nonTodoTaskIds[$task.id] = $true
                }
            } catch {
                Write-BotLog -Level Warn -Message "[TaskMutation] Failed to read non-todo task file '$($file.FullName)'" -Exception $_
            }
        }
    }

    return $nonTodoTaskIds
}

function Get-TodoTaskLookup {
    param(
        [string]$TasksBaseDir
    )

    $paths = Ensure-TodoDirectories -TasksBaseDir $TasksBaseDir
    $lookup = @{}
    $referenceMap = @{}
    $orderedTasks = [System.Collections.Generic.List[object]]::new()
    $excludedTaskIds = Get-NonTodoTaskIds -TasksBaseDir $paths.TasksBaseDir

    $files = Get-ChildItem -Path $paths.TodoDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $task = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if (-not $task.id) {
                continue
            }

            if ($excludedTaskIds.ContainsKey($task.id)) {
                continue
            }

            $lookup[$task.id] = $task
            $null = $orderedTasks.Add($task)
        } catch {
            Write-BotLog -Level Warn -Message "[TaskMutation] Failed to read task file '$($file.FullName)'" -Exception $_
        }
    }

    $position = 0
    foreach ($task in @($orderedTasks) | Sort-Object @{ Expression = { Get-TaskPriorityValue -Task $_ } }, @{ Expression = { $_.name } }, @{ Expression = { $_.id } }) {
        $position += 1
        Add-TaskReferenceAlias -ReferenceMap $referenceMap -TaskId $task.id -Alias $task.id
        Add-TaskReferenceAlias -ReferenceMap $referenceMap -TaskId $task.id -Alias $task.name
        Add-TaskReferenceAlias -ReferenceMap $referenceMap -TaskId $task.id -Alias (Get-TaskSlug -TaskName $task.name)
        Add-TaskReferenceAlias -ReferenceMap $referenceMap -TaskId $task.id -Alias $position
        Add-TaskReferenceAlias -ReferenceMap $referenceMap -TaskId $task.id -Alias "task $position"
    }

    return @{
        Tasks = $lookup
        References = $referenceMap
    }
}

function Get-TaskIgnoreStateMap {
    param(
        [string]$TasksBaseDir
    )

    $resolvedBaseDir = Get-TasksBaseDir -TasksBaseDir $TasksBaseDir
    $lookup = Get-TodoTaskLookup -TasksBaseDir $resolvedBaseDir
    $tasks = $lookup.Tasks
    $references = $lookup.References
    $roadmapDependencyMap = Get-RoadmapOverviewDependencyMap -TasksBaseDir $resolvedBaseDir
    $memo = @{}
    $resolving = @{}

    function Resolve-IgnoreState {
        param(
            [Parameter(Mandatory)]
            [string]$TaskId
        )

        if ($memo.ContainsKey($TaskId)) {
            return $memo[$TaskId]
        }

        if ($resolving.ContainsKey($TaskId)) {
            return [pscustomobject]@{
                task_id = $TaskId
                manual = $false
                effective = $false
                auto = $false
                blocking_task_ids = @()
                blocking_task_names = @()
                updated_at = $null
                updated_by = $null
                updated_by_user = $null
            }
        }

        $resolving[$TaskId] = $true

        $task = $tasks[$TaskId]
        $manualIgnored = $false
        $updatedAt = $null
        $updatedBy = $null
        $updatedByUser = $null

        if ($task.PSObject.Properties['ignore']) {
            $manualIgnored = ($task.ignore.manual -eq $true)
            $updatedAt = $task.ignore.updated_at
            $updatedBy = $task.ignore.updated_by
            $updatedByUser = $task.ignore.updated_by_user
        }

        $blockingIds = [System.Collections.Generic.List[string]]::new()
        foreach ($dependency in (Get-ResolvedTaskDependencies -Task $task -RoadmapDependencyMap $roadmapDependencyMap)) {
            if (-not $dependency) {
                continue
            }

            $dependencyTaskIds = [System.Collections.Generic.List[string]]::new()
            foreach ($dependencyKey in (Get-TaskDependencyReferenceTokens -Dependency $dependency)) {
                if (-not $references.ContainsKey($dependencyKey)) {
                    continue
                }

                $resolvedDependencyTaskId = $references[$dependencyKey]
                if (-not $tasks.ContainsKey($resolvedDependencyTaskId) -or $dependencyTaskIds.Contains($resolvedDependencyTaskId)) {
                    continue
                }

                $dependencyTaskIds.Add($resolvedDependencyTaskId)
            }

            foreach ($dependencyTaskId in $dependencyTaskIds) {
                $dependencyState = Resolve-IgnoreState -TaskId $dependencyTaskId
                if (-not $dependencyState.effective) {
                    continue
                }

                if ($dependencyState.manual) {
                    if (-not $blockingIds.Contains($dependencyTaskId)) {
                        $blockingIds.Add($dependencyTaskId)
                    }
                    continue
                }

                if ($dependencyState.blocking_task_ids.Count -gt 0) {
                    foreach ($blockingTaskId in $dependencyState.blocking_task_ids) {
                        if (-not $blockingIds.Contains($blockingTaskId)) {
                            $blockingIds.Add($blockingTaskId)
                        }
                    }
                    continue
                }

                if (-not $blockingIds.Contains($dependencyTaskId)) {
                    $blockingIds.Add($dependencyTaskId)
                }
            }

        }
        $blockingNames = @()
        foreach ($blockingTaskId in $blockingIds) {
            if ($tasks.ContainsKey($blockingTaskId) -and $tasks[$blockingTaskId].name) {
                $blockingNames += $tasks[$blockingTaskId].name
            } else {
                $blockingNames += $blockingTaskId
            }
        }

        $state = [pscustomobject]@{
            task_id = $TaskId
            manual = $manualIgnored
            effective = ($manualIgnored -or $blockingIds.Count -gt 0)
            auto = (-not $manualIgnored -and $blockingIds.Count -gt 0)
            blocking_task_ids = @($blockingIds)
            blocking_task_names = @($blockingNames | Select-Object -Unique)
            updated_at = $updatedAt
            updated_by = $updatedBy
            updated_by_user = $updatedByUser
        }

        $memo[$TaskId] = $state
        $resolving.Remove($TaskId) | Out-Null
        return $state
    }

    $result = @{}
    foreach ($taskId in @($tasks.Keys)) {
        $result[$taskId] = Resolve-IgnoreState -TaskId $taskId
    }

    return $result
}
function Set-TaskIgnoreState {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter(Mandatory)]
        [bool]$Ignored,
        [string]$Actor,
        [string]$TasksBaseDir
    )

    $actorName = Get-ArchiveActor -Actor $Actor
    $auditUser = Get-AuditUsername
    $taskRecord = Get-TodoTaskRecord -TaskId $TaskId -TasksBaseDir $TasksBaseDir
    if (-not $taskRecord) {
        throw "Todo task with ID '$TaskId' not found"
    }

    $task = $taskRecord.task
    $timestamp = Get-UtcTimestamp
    $ignoreState = [ordered]@{
        manual = $Ignored
        updated_at = $timestamp
        updated_by = $actorName
        updated_by_user = $auditUser
    }

    if ($task.PSObject.Properties['ignore']) {
        $task.ignore = $ignoreState
    } else {
        $task | Add-Member -NotePropertyName "ignore" -NotePropertyValue $ignoreState -Force
    }

    $task.updated_at = $timestamp
    Set-TaskAuditUser -Target $task -UserName $auditUser
    Save-TaskFile -Task $task -Path $taskRecord.path

    $ignoreMap = Get-TaskIgnoreStateMap -TasksBaseDir $taskRecord.tasks_base_dir

    return @{
        success = $true
        task_id = $TaskId
        ignored = $Ignored
        actor = $actorName
        updated_at = $timestamp
        ignore_state = $ignoreMap[$TaskId]
    }
}
function Update-TaskContent {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter(Mandatory)]
        [hashtable]$Updates,
        [string]$Actor,
        [string]$TasksBaseDir
    )

    $actorName = Get-ArchiveActor -Actor $Actor
    $auditUser = Get-AuditUsername
    $taskRecord = Get-TodoTaskRecord -TaskId $TaskId -TasksBaseDir $TasksBaseDir
    if (-not $taskRecord) {
        throw "Todo task with ID '$TaskId' not found"
    }

    $task = $taskRecord.task
    $archive = Write-TaskArchive -Task $task `
        -ArchiveDir $taskRecord.edited_dir `
        -ArchiveKind "edit" `
        -Actor $actorName `
        -SourceStatus "todo" `
        -SourceFileName $taskRecord.file_name

    $blockedFields = @('id', 'status', 'created_at', 'completed_at')
    foreach ($key in $Updates.Keys) {
        if ($key -in $blockedFields) {
            continue
        }

        if ($task.PSObject.Properties[$key]) {
            $task.$key = $Updates[$key]
        } else {
            $task | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force
        }
    }

    $timestamp = Get-UtcTimestamp
    $task.updated_at = $timestamp
    if ($task.PSObject.Properties['updated_by']) {
        $task.updated_by = $actorName
    } else {
        $task | Add-Member -NotePropertyName "updated_by" -NotePropertyValue $actorName -Force
    }
    Set-TaskAuditUser -Target $task -UserName $auditUser

    Save-TaskFile -Task $task -Path $taskRecord.path

    return @{
        success = $true
        task_id = $TaskId
        actor = $actorName
        updated_at = $timestamp
        archived_version_id = $archive.version_id
        file_path = $taskRecord.path
    }
}
function Remove-TaskFromTodo {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,
        [string]$Actor,
        [string]$TasksBaseDir
    )

    $actorName = Get-ArchiveActor -Actor $Actor
    $taskRecord = Get-TodoTaskRecord -TaskId $TaskId -TasksBaseDir $TasksBaseDir
    if (-not $taskRecord) {
        throw "Todo task with ID '$TaskId' not found"
    }

    $archive = Write-TaskArchive -Task $taskRecord.task `
        -ArchiveDir $taskRecord.deleted_dir `
        -ArchiveKind "delete" `
        -Actor $actorName `
        -SourceStatus "todo" `
        -SourceFileName $taskRecord.file_name

    Remove-Item -Path $taskRecord.path -Force

    return @{
        success = $true
        task_id = $TaskId
        actor = $actorName
        archived_version_id = $archive.version_id
        archived_at = $archive.captured_at
    }
}

function Get-ArchiveVersionsForTask {
    param(
        [Parameter(Mandatory)]
        [string]$ArchiveDir,
        [Parameter(Mandatory)]
        [string]$TaskId
    )

    if (-not (Test-Path $ArchiveDir)) {
        return @()
    }

    $versions = @()
    $files = Get-ChildItem -Path $ArchiveDir -Filter "*.json" -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $archiveRecord = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
            if ($archiveRecord.task_id -eq $TaskId) {
                $versions += $archiveRecord
            }
        } catch {
            Write-BotLog -Level Warn -Message "[TaskMutation] Failed to read archive '$($file.FullName)'" -Exception $_
        }
    }

    return @(
        $versions |
            Sort-Object {
                try {
                    if ($_.captured_at) {
                        [DateTime]$_.captured_at
                    } else {
                        [DateTime]::MinValue
                    }
                } catch {
                    [DateTime]::MinValue
                }
            } -Descending
    )
}

function Get-TaskVersionHistory {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,
        [string]$TasksBaseDir
    )

    $paths = Ensure-TodoDirectories -TasksBaseDir $TasksBaseDir

    return @{
        success = $true
        task_id = $TaskId
        edited_versions = Get-ArchiveVersionsForTask -ArchiveDir $paths.EditedDir -TaskId $TaskId
        deleted_versions = Get-ArchiveVersionsForTask -ArchiveDir $paths.DeletedDir -TaskId $TaskId
    }
}

function Restore-TaskVersion {
    param(
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter(Mandatory)]
        [string]$VersionId,
        [string]$Actor,
        [string]$TasksBaseDir
    )

    $actorName = Get-ArchiveActor -Actor $Actor
    $auditUser = Get-AuditUsername
    $paths = Ensure-TodoDirectories -TasksBaseDir $TasksBaseDir
    $history = Get-TaskVersionHistory -TaskId $TaskId -TasksBaseDir $paths.TasksBaseDir
    $archiveVersion = @($history.edited_versions + $history.deleted_versions) |
        Where-Object { $_.version_id -eq $VersionId } |
        Select-Object -First 1

    if (-not $archiveVersion) {
        throw "Archived version '$VersionId' was not found for task '$TaskId'"
    }

    $existingTask = Get-TodoTaskRecord -TaskId $TaskId -TasksBaseDir $paths.TasksBaseDir
    if ($existingTask) {
        Write-TaskArchive -Task $existingTask.task `
            -ArchiveDir $paths.EditedDir `
            -ArchiveKind "edit" `
            -Actor $actorName `
            -SourceStatus "todo" `
            -SourceFileName $existingTask.file_name | Out-Null
    }

    $restoredTask = ConvertTo-DeepClone -InputObject $archiveVersion.task
    $restoredTask.status = "todo"
    $restoredTask.updated_at = Get-UtcTimestamp
    if ($restoredTask.PSObject.Properties['updated_by']) {
        $restoredTask.updated_by = $actorName
    } else {
        $restoredTask | Add-Member -NotePropertyName "updated_by" -NotePropertyValue $actorName -Force
    }
    Set-TaskAuditUser -Target $restoredTask -UserName $auditUser

    $targetFileName = if ($archiveVersion.source_file_name) {
        $archiveVersion.source_file_name
    } elseif ($existingTask) {
        $existingTask.file_name
    } else {
        "$TaskId.json"
    }

    $targetPath = Join-Path $paths.TodoDir $targetFileName
    Save-TaskFile -Task $restoredTask -Path $targetPath

    return @{
        success = $true
        task_id = $TaskId
        restored_version_id = $VersionId
        actor = $actorName
        file_path = $targetPath
        archive_kind = $archiveVersion.archive_kind
    }
}
Export-ModuleMember -Function @(
    'Set-TaskIgnoreState',
    'Update-TaskContent',
    'Remove-TaskFromTodo',
    'Get-TaskVersionHistory',
    'Restore-TaskVersion',
    'Get-TaskIgnoreStateMap',
    'Get-RoadmapOverviewDependencyMap'
)



