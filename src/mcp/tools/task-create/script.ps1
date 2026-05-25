function Invoke-TaskCreate {
    param([hashtable]$Arguments)
    $body = @{ actor = Get-McpActor }
    foreach ($k in $Arguments.Keys) {
        # Top-level `needs_review` is shorthand for extensions.review.required.
        # The runtime stores it in the extensions namespace because the TaskInstance
        # schema is closed; the shorthand keeps the MCP surface ergonomic for agents.
        if ($k -eq 'needs_review') { continue }
        $body[$k] = $Arguments[$k]
    }
    if ($Arguments.ContainsKey('needs_review') -and [bool]$Arguments['needs_review']) {
        $ext = if ($body.ContainsKey('extensions')) { $body['extensions'] } else { @{} }
        $reviewBag = if ($ext -is [System.Collections.IDictionary] -and $ext.Contains('review')) { $ext['review'] } else { @{} }
        if ($reviewBag -isnot [System.Collections.IDictionary]) { $reviewBag = @{} }
        $reviewBag['required'] = $true
        $ext['review'] = $reviewBag
        $body['extensions'] = $ext
    }
    Invoke-McpRuntimeRequest -Method POST -Path '/tasks' -Body $body
}
