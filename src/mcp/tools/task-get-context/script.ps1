function Invoke-TaskGetContext {
    param([hashtable]$Arguments)
    Invoke-McpRuntimeRequest -Method GET -Path "/tasks/$($Arguments['task_id'])/context"
}
