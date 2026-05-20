function Invoke-WorkflowStart {
    param([hashtable]$Arguments)
    $body = @{ actor = Get-McpActor }
    foreach ($k in $Arguments.Keys) { $body[$k] = $Arguments[$k] }
    Invoke-McpRuntimeRequest -Method POST -Path '/workflows/runs' -Body $body
}
