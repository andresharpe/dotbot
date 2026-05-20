function Invoke-TaskList {
    param([hashtable]$Arguments)
    $query = @{}
    foreach ($k in $Arguments.Keys) {
        if ($null -ne $Arguments[$k] -and $Arguments[$k] -ne '') { $query[$k] = $Arguments[$k] }
    }
    Invoke-McpRuntimeRequest -Method GET -Path '/tasks' -Query $query
}
