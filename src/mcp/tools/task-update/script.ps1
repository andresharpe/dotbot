function Invoke-TaskUpdate {
    param([hashtable]$Arguments)
    $taskId = $Arguments['task_id']
    $body = @{ actor = Get-McpActor }
    foreach ($k in $Arguments.Keys) {
        if ($k -eq 'task_id') { continue }
        $value = $Arguments[$k]
        if ($k -eq 'extensions' -and $value -is [string]) {
            $trimmed = $value.Trim()
            if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
                try { $value = $trimmed | ConvertFrom-Json -ErrorAction Stop } catch { $value = $Arguments[$k] }
            }
        }
        $body[$k] = $value
    }
    Invoke-McpRuntimeRequest -Method PATCH -Path "/tasks/$taskId" -Body $body
}
