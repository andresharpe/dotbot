function Invoke-WorkflowStart {
    param([hashtable]$Arguments)
    $body = @{ actor = Get-McpActor }
    foreach ($k in @('workflow_name','task_ids','task_definitions')) {
        if ($Arguments.ContainsKey($k)) { $body[$k] = $Arguments[$k] }
    }
    Invoke-McpRuntimeRequest -Method POST -Path '/workflows/runs' -Body $body
}
