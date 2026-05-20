function Invoke-WorkflowList {
    param([hashtable]$Arguments)
    Invoke-McpRuntimeRequest -Method GET -Path '/workflows/runs'
}
