function Invoke-TaskSetStatus {
    param([hashtable]$Arguments)
    # The runtime's wire format uses `to` for the target status (see
    # HttpServer.psm1's Invoke-TaskStatusHandler). The MCP tool exposes the
    # more natural `status` field to the agent and translates here.
    $body = @{
        to    = $Arguments['status']
        actor = Get-McpActor
    }
    if ($Arguments.ContainsKey('reason') -and $Arguments['reason']) {
        $body['reason'] = $Arguments['reason']
    }
    Invoke-McpRuntimeRequest -Method POST -Path "/tasks/$($Arguments['task_id'])/status" -Body $body
}
