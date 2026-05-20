function Invoke-TaskUpdate {
    param([hashtable]$Arguments)
    $taskId = $Arguments['task_id']
    $body = @{ actor = Get-McpActor }
    foreach ($k in $Arguments.Keys) {
        if ($k -eq 'task_id') { continue }
        $body[$k] = $Arguments[$k]
    }
    Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body $body
}
