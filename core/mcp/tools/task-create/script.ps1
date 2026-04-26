function Invoke-TaskCreate {
    param(
        [hashtable]$Arguments
    )
    
    # Extract arguments
    $name = $Arguments['name']
    $description = $Arguments['description']
    $category = $Arguments['category']
    $priority = $Arguments['priority']
    $effort = $Arguments['effort']
    $dependencies = $Arguments['dependencies']
    $acceptanceCriteria = $Arguments['acceptance_criteria']
    $steps = $Arguments['steps']
    $applicableStandards = $Arguments['applicable_standards']
    $applicableAgents = $Arguments['applicable_agents']
    $applicableSkills = $Arguments['applicable_skills']
    $applicableDecisions = $Arguments['applicable_decisions']
    $needsInterview = $Arguments['needs_interview'] -eq $true
    $humanHours = $Arguments['human_hours']
    $aiHours = $Arguments['ai_hours']
    $workingDir = $Arguments['working_dir']
    $taskType = if ($Arguments.ContainsKey('type') -and $Arguments['type']) { $Arguments['type'] } else { $null }
    $scriptPath = if ($Arguments.ContainsKey('script_path')) { $Arguments['script_path'] } else { $null }
    $mcpTool = if ($Arguments.ContainsKey('mcp_tool')) { $Arguments['mcp_tool'] } else { $null }
    $mcpArgs = if ($Arguments.ContainsKey('mcp_args')) { $Arguments['mcp_args'] } else { $null }
    $skipAnalysis = if ($Arguments.ContainsKey('skip_analysis')) { $Arguments['skip_analysis'] } else { $null }
    $skipWorktree = if ($Arguments.ContainsKey('skip_worktree')) { $Arguments['skip_worktree'] } else { $null }
    
    # Validate required fields
    if (-not $name) {
        throw "Task name is required"
    }
    
    if (-not $description) {
        throw "Task description is required"
    }
    
    # Validate category: categories come from the merged settings chain (defaults + ~/dotbot + .control)
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
    if ($category -and $category -notin $validCategories) {
        throw "Invalid category. Must be one of: $($validCategories -join ', ')"
    }
    
    # Validate effort
    $validEfforts = @('XS', 'S', 'M', 'L', 'XL')
    if ($effort -and $effort -notin $validEfforts) {
        throw "Invalid effort. Must be one of: $($validEfforts -join ', ')"
    }
    
    # Validate task type
    $validTypes = @('prompt', 'prompt_template', 'script', 'mcp', 'task_gen')
    if ($null -ne $taskType -and $taskType -notin $validTypes) {
        throw "Invalid type '$taskType'. Must be one of: $($validTypes -join ', ')"
    }
    if ($taskType -in @('script', 'task_gen') -and -not $scriptPath) {
        throw "script_path is required for type '$taskType'"
    }
    if ($taskType -eq 'mcp' -and -not $mcpTool) {
        throw "mcp_tool is required for type 'mcp'"
    }
    if ($taskType -eq 'prompt_template' -and -not $Arguments['prompt']) {
        throw "prompt is required for type 'prompt_template' (path to prompt template file)"
    }
    
    # Set defaults
    if (-not $category) { $category = 'feature' }
    if (-not $priority) { $priority = 50 }
    if (-not $effort) { $effort = 'M' }
    if (-not $dependencies) { $dependencies = @() }
    if (-not $acceptanceCriteria) { $acceptanceCriteria = @() }
    if (-not $steps) { $steps = @() }
    if (-not $applicableStandards) { $applicableStandards = @() }
    if (-not $applicableAgents) { $applicableAgents = @() }
    if (-not $applicableSkills) { $applicableSkills = @() }
    if (-not $applicableDecisions) { $applicableDecisions = @() }
    # needsInterview is already a boolean, no default needed
    
    # Validate dependencies exist
    if ($dependencies -and $dependencies.Count -gt 0) {
        # Import task index module
        $indexModule = Join-Path $global:DotbotProjectRoot ".bot\systems\mcp\modules\TaskIndexCache.psm1"
        if (-not (Get-Module TaskIndexCache)) {
            Import-Module $indexModule -Force
        }
        
        # Initialize index
        $tasksBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks"
        Initialize-TaskIndex -TasksBaseDir $tasksBaseDir
        $index = Get-TaskIndex
        
        $invalidDeps = @()
        foreach ($dep in $dependencies) {
            $depLower = $dep.ToLowerInvariant()
            $found = $false
            
            # Check all tasks (todo, in-progress, done)
            $allTasks = @($index.Todo.Values) + @($index.InProgress.Values) + @($index.Done.Values)
            
            foreach ($task in $allTasks) {
                # Check ID match
                if ($task.id -eq $dep) { $found = $true; break }
                
                # Check name match
                if ($task.name -eq $dep) { $found = $true; break }
                
                # Check slug match (generated from name)
                $taskSlug = ($task.name -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
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
            throw "Invalid dependencies: '$depList'. These tasks do not exist. Create dependency tasks first or remove these dependencies."
        }
    }
    
    # Generate unique ID
    $id = [System.Guid]::NewGuid().ToString()
    
    # Defaults for type-related fields
    if (-not $taskType) { $taskType = 'prompt' }
    if ($taskType -ne 'prompt') {
        $skipAnalysis = if ($skipAnalysis -is [bool]) { $skipAnalysis } else { $true }
        $skipWorktree = if ($skipWorktree -is [bool]) { $skipWorktree } else { $true }
    } else {
        $skipAnalysis = if ($skipAnalysis -is [bool]) { $skipAnalysis } else { $false }
        $skipWorktree = if ($skipWorktree -is [bool]) { $skipWorktree } else { $false }
    }
    if (-not $mcpArgs) { $mcpArgs = @{} }

    # Create task object
    $task = @{
        id = $id
        name = $name
        description = $description
        category = $category
        priority = [int]$priority
        effort = $effort
        status = 'todo'
        type = $taskType
        dependencies = $dependencies
        acceptance_criteria = $acceptanceCriteria
        steps = $steps
        applicable_standards = $applicableStandards
        applicable_agents = $applicableAgents
        applicable_skills = $applicableSkills
        applicable_decisions = $applicableDecisions
        needs_interview = $needsInterview
        human_hours = $humanHours
        ai_hours = $aiHours
        working_dir = $workingDir
        skip_analysis = [bool]$skipAnalysis
        skip_worktree = [bool]$skipWorktree
        created_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        updated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        completed_at = $null
    }
    # Add type-specific fields
    if ($scriptPath) { $task['script_path'] = $scriptPath }
    if ($mcpTool) { $task['mcp_tool'] = $mcpTool }
    if ($mcpArgs.Count -gt 0) { $task['mcp_args'] = $mcpArgs }

    # Passthrough: preserve extra/custom fields from input (e.g., research_prompt, external_repo)
    $reservedFields = @('id', 'status', 'created_at', 'updated_at', 'completed_at')
    foreach ($key in $Arguments.Keys) {
        if (-not $task.ContainsKey($key) -and $key -notin $reservedFields) {
            $task[$key] = $Arguments[$key]
        }
    }

    # Define file path
    $tasksDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\tasks\todo"
    
    # Ensure directory exists
    if (-not (Test-Path $tasksDir)) {
        New-Item -ItemType Directory -Force -Path $tasksDir | Out-Null
    }
    
    # Create filename from name (sanitized)
    $fileName = ($name -replace '[^\w\s-]', '' -replace '\s+', '-').ToLowerInvariant()
    if ($fileName.Length -gt 50) {
        $fileName = $fileName.Substring(0, 50)
    }
    $fileName = "$fileName-$($id.Split('-')[0]).json"
    $filePath = Join-Path $tasksDir $fileName
    
    # Save task to file
    $task | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    
    # Return result
    return @{
        success = $true
        task_id = $id
        file_path = $filePath
        message = "Task '$name' created successfully with ID: $id"
    }
}
