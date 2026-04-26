function Invoke-TaskCreateBulk {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $tasks = $Arguments['tasks']
    
    # Validate required fields
    if (-not $tasks) {
        throw "Tasks array is required"
    }
    
    if ($tasks.Count -eq 0) {
        throw "At least one task must be provided"
    }
    
    # Validate categories: come from the merged settings chain (defaults + ~/dotbot + .control)
    $defaultCategories = @('core', 'feature', 'enhancement', 'bugfix', 'infrastructure', 'ui-ux')
    $botRoot = Join-Path $global:DotbotProjectRoot ".bot"
    if (-not (Get-Module SettingsLoader)) {
        Import-Module (Join-Path $botRoot "systems\runtime\modules\SettingsLoader.psm1") -DisableNameChecking -Global
    }

    $settings = Get-MergedSettings -BotRoot $botRoot
    if ($settings.PSObject.Properties['task_categories'] -and $settings.task_categories) {
        $validCategories = @($settings.task_categories) + $defaultCategories | Select-Object -Unique
    } else {
        $validCategories = $defaultCategories
    }
    $validEfforts = @('XS', 'S', 'M', 'L', 'XL')
    
    # Import task index module for dependency validation
    $indexModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskIndexCache.psm1"
    if (-not (Get-Module TaskIndexCache)) {
        Import-Module $indexModule -Force
    }
    
    # Initialize task index
    $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
    Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
    $index = Get-TaskIndex
    
    # Define tasks directory
    $tasksDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\todo"
    
    # Ensure directory exists
    if (-not (Test-Path $tasksDir)) {
        New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    }
    
    # Process each task
    $createdTasks = @()
    $errors = @()
    $basePriority = 1
    
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $task = $tasks[$i]
        
        try {
            # Validate required fields for this task
            if (-not $task.name) {
                throw "Task #$($i+1): name is required"
            }
            
            if (-not $task.description) {
                throw "Task #$($i+1): description is required"
            }
            
            # Validate category if provided
            if ($task.category -and $task.category -notin $validCategories) {
                throw "Task #$($i+1): Invalid category. Must be one of: $($validCategories -join ', ')"
            }
            
            # Validate effort if provided
            if ($task.effort -and $task.effort -notin $validEfforts) {
                throw "Task #$($i+1): Invalid effort. Must be one of: $($validEfforts -join ', ')"
            }
            
            # Set defaults
            $category = if ($task.category) { $task.category } else { 'feature' }
            $priority = if ($task.priority) { [int]$task.priority } else { $basePriority + $i }
            $effort = if ($task.effort) { $task.effort } else { 'M' }
            $dependencies = if ($task.dependencies -is [array]) {
                $task.dependencies
            } elseif ($task.dependencies -is [string]) {
                @($task.dependencies)
            } else {
                @()
            }
            $acceptanceCriteria = if ($task.acceptance_criteria) { $task.acceptance_criteria } else { @() }
            $steps = if ($task.steps) { $task.steps } else { @() }
            $applicableStandards = if ($task.applicable_standards) { $task.applicable_standards } else { @() }
            $applicableAgents = if ($task.applicable_agents) { $task.applicable_agents } else { @() }
            $applicableSkills = if ($task.applicable_skills) { $task.applicable_skills } else { @() }
            
            # Validate dependencies exist
            if ($dependencies -and $dependencies.Count -gt 0) {
                $invalidDeps = @()
                foreach ($dep in $dependencies) {
                    $depLower = $dep.ToLowerInvariant()
                    $found = $false
                    
                    # Check all existing tasks
                    $allTasks = @($index.Todo.Values) + @($index.InProgress.Values) + @($index.Done.Values)
                    
                    # Also check previously created tasks in this batch
                    $allTasks += $createdTasks | ForEach-Object {
                        $taskSlug = ($_.name -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
                        [PSCustomObject]@{
                            id = $_.id
                            name = $_.name
                            slug = $taskSlug
                        }
                    }
                    
                    foreach ($t in $allTasks) {
                        # Check ID match
                        if ($t.id -eq $dep) { $found = $true; break }
                        
                        # Check name match
                        if ($t.name -eq $dep) { $found = $true; break }
                        
                        # Check slug match
                        $taskSlug = if ($t.slug) { $t.slug } else { ($t.name -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant() }
                        if ($taskSlug -eq $depLower) { $found = $true; break }
                        
                        # Fuzzy match
                        if ($taskSlug -like "*$depLower*" -or $depLower -like "*$taskSlug*") { $found = $true; break }
                    }
                    
                    if (-not $found) {
                        $invalidDeps += $dep
                    }
                }
                
                if ($invalidDeps.Count -gt 0) {
                    $depList = $invalidDeps -join "', '"
                    throw "Invalid dependencies: '$depList'. These tasks do not exist in the system or earlier in this batch."
                }
            }
            
            # Generate unique ID
            $id = [System.Guid]::NewGuid().ToString()
            
            # Create task object
            $newTask = @{
                id = $id
                name = $task.name
                description = $task.description
                category = $category
                priority = $priority
                effort = $effort
                status = 'todo'
                dependencies = $dependencies
                acceptance_criteria = $acceptanceCriteria
                steps = $steps
                applicable_standards = $applicableStandards
                applicable_agents = $applicableAgents
                applicable_skills = $applicableSkills
                needs_interview = ($task.needs_interview -eq $true)
                group_id = $task.group_id
                human_hours = $task.human_hours
                ai_hours = $task.ai_hours
                working_dir = $task.working_dir
                created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                completed_at = $null
            }

            # Passthrough: preserve extra/custom fields from input (e.g., research_prompt, external_repo)
            $reservedFields = @('id', 'status', 'created_at', 'updated_at', 'completed_at')
            # Use .Keys for dictionary entries; skip .NET internal properties from OrderedDictionary
            $dictKeys = if ($task -is [System.Collections.IDictionary]) { $task.Keys } else { $task.PSObject.Properties.Name }
            foreach ($key in $dictKeys) {
                if (-not $newTask.ContainsKey($key) -and $key -notin $reservedFields) {
                    $newTask[$key] = $task[$key]
                }
            }

            # Create filename from name (sanitized)
            $fileName = ($task.name -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
            if ($fileName.Length -gt 50) {
                $fileName = $fileName.Substring(0, 50)
            }
            $fileName = "$fileName-$($id.Split('-')[0]).json"
            $filePath = Join-Path $tasksDir $fileName
            
            # Save task to file
            $newTask | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
            
            # Add to created list
            $createdTasks += @{
                id = $id
                name = $task.name
                file_path = $filePath
                priority = $priority
            }
            
        } catch {
            $errors += @{
                index = $i
                name = $task.name
                error = $_.Exception.Message
            }
        }
    }
    
    # Return result
    return @{
        success = ($errors.Count -eq 0)
        created_count = $createdTasks.Count
        error_count = $errors.Count
        created_tasks = $createdTasks
        errors = $errors
        message = if ($errors.Count -eq 0) {
            "Successfully created $($createdTasks.Count) tasks"
        } else {
            "Created $($createdTasks.Count) tasks with $($errors.Count) errors"
        }
    }
}
