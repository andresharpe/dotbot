@{
    RootModule        = 'Dotbot.Runtime.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3c7d2f4-9b18-4a5e-9c2a-9d7e3b5a8c41'
    Author            = 'dotbot contributors'
    Description       = 'Per-project HTTP runtime (PRD-04). Owns mutexes, transitions, and activity-log emission. Sole writer of project state. Exposes Resolve-RuntimeEndpoint + Invoke-RuntimeRequest for MCP/UI clients.'
    PowerShellVersion = '7.0'

    # All concerns live as nested modules so each is findable in isolation.
    NestedModules     = @(
        'v4/EndpointDiscovery.psm1',
        'v4/Mutex.psm1',
        'v4/ActivityLog.psm1',
        'v4/Lifecycle.psm1',
        'v4/HttpServer.psm1',
        'v4/Client.psm1'
    )

    FunctionsToExport = @(
        # Endpoint discovery
        'Resolve-RuntimeEndpoint'
        'Get-RuntimeConnectionFilePath'
        'Read-RuntimeConnectionFile'
        'Write-RuntimeConnectionFile'
        'Remove-RuntimeConnectionFile'

        # Mutex
        'Lock-TaskMutex'
        'Unlock-TaskMutex'
        'Lock-RunMutex'
        'Unlock-RunMutex'
        'Lock-TaskMutexes'
        'Unlock-TaskMutexes'
        'Clear-RuntimeMutexPool'

        # Activity log
        'Write-ActivityEvent'
        'Get-ActivityLogPath'
        'Get-DotbotProjectId'

        # Lifecycle
        'Start-DotbotRuntime'
        'Stop-DotbotRuntime'
        'Test-RuntimeAlive'
        'New-RuntimeBearerToken'
        'Find-AvailableRuntimePort'

        # HTTP server (callable for tests / direct embed)
        'Start-RuntimeHttpListener'
        'Stop-RuntimeHttpListener'

        # Dispatch + handlers — exported so per-request runspaces (which only
        # see exported surface) can call them. Production callers should use
        # the HTTP API, not invoke these directly.
        'Invoke-RuntimeRequestDispatch'
        'Invoke-HealthHandler'
        'Invoke-CreateTaskHandler'
        'Invoke-GetTaskHandler'
        'Invoke-ListTasksHandler'
        'Invoke-PatchTaskHandler'
        'Invoke-TaskStatusHandler'
        'Invoke-GetNextTaskHandler'
        'Invoke-GetTaskContextHandler'
        'Invoke-CreateRunHandler'
        'Invoke-GetRunHandler'
        'Invoke-ListRunsHandler'

        # Client helpers (PRD-07: MCP tools call these)
        'Invoke-RuntimeRequest'
        'Invoke-McpRuntimeRequest'
        'Get-McpActor'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
