function Invoke-WorkflowGet {
    param([hashtable]$Arguments)
    Invoke-McpRuntimeRequest -Method GET -Path "/workflows/runs/$($Arguments['run_id'])"
}
