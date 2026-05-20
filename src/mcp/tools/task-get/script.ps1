function Invoke-TaskGet {
    param([hashtable]$Arguments)
    Invoke-McpRuntimeRequest -Method GET -Path "/tasks/$($Arguments.task_id)"
}
