<#
.SYNOPSIS
Invoke-RuntimeRequest — thin client used by MCP tools and the UI
proxy to talk to the per-project HTTP runtime.

Endpoint discovery is delegated to Resolve-RuntimeEndpoint. On 401 the helper
re-discovers (a stale runtime.json with a regenerated token is the canonical
failure case) and retries once.

Get-McpActor returns the canonical actor string ("mcp:<session>") that MCP
tools stamp on every mutation. The MCP server seeds
$env:DOTBOT_MCP_SESSION at startup; tools never have to supply it.
#>

function Get-McpActor {
    <#
    .SYNOPSIS
    Return the canonical actor string for an MCP-originating mutation.

    .DESCRIPTION
    Format: "mcp:<session>". The session is sourced from
    $env:DOTBOT_MCP_SESSION (seeded by dotbot-mcp.ps1 at startup) and falls
    back to "unknown" so a misconfigured server still produces a parseable
    actor in audit logs rather than a malformed empty value.
    #>
    [CmdletBinding()]
    param()
    $session = [Environment]::GetEnvironmentVariable('DOTBOT_MCP_SESSION')
    if (-not $session) { $session = 'unknown' }
    return "mcp:$session"
}

function _Resolve-RuntimeBotRoot {
    param([string]$BotRoot)
    if ($BotRoot) { return $BotRoot }
    if ($global:DotbotBotRoot) { return [string]$global:DotbotBotRoot }
    $envRoot = [Environment]::GetEnvironmentVariable('DOTBOT_BOT_ROOT')
    if ($envRoot) { return $envRoot }
    throw "Invoke-RuntimeRequest: BotRoot not supplied and `$global:DotbotBotRoot/`$env:DOTBOT_BOT_ROOT are unset."
}

function Invoke-RuntimeRequest {
    <#
    .SYNOPSIS
    Send a request to the local runtime with bearer auth wired in.

    .DESCRIPTION
    The MCP and UI clients should never construct the URL or token by hand —
    they call this helper with the path and let it handle discovery, auth,
    re-discovery on stale-token 401, and JSON encode/decode.

    .PARAMETER BotRoot
    The project's .bot/ root. Required for endpoint discovery.

    .PARAMETER Method
    GET | POST | PATCH | DELETE.

    .PARAMETER Path
    Path part beginning with '/' (e.g. '/tasks', '/tasks/t_AbCd1234/status').

    .PARAMETER Body
    Object to JSON-encode as the request body. Ignored for GET.

    .PARAMETER Query
    Optional hashtable of query-string params.

    .PARAMETER TimeoutSec
    Request timeout in seconds. Default 30. The runtime is local so anything
    longer than a few seconds means a stuck handler — fail loudly.

    .OUTPUTS
    A hashtable with: @{ status_code; body; headers; raw }
    'body' is the parsed JSON when the response is JSON, $null otherwise.
    Non-2xx responses still return — callers inspect status_code rather than
    catching exceptions for expected error responses (404/409/422).
    #>
    [CmdletBinding()]
    param(
        [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method,

        [Parameter(Mandatory)] [string]$Path,

        [object]$Body,

        [hashtable]$Query,

        [int]$TimeoutSec = 30
    )

    $BotRoot = _Resolve-RuntimeBotRoot -BotRoot $BotRoot

    if (-not $Path.StartsWith('/')) {
        throw "Invoke-RuntimeRequest: Path must start with '/'. Got '$Path'."
    }

    # Inner closure that does one attempt against a freshly-resolved endpoint.
    $attempt = {
        param([bool]$Rediscover)
        $endpoint = Resolve-RuntimeEndpoint -BotRoot $BotRoot
        $baseUrl = $endpoint.url.TrimEnd('/')
        $uri = "$baseUrl$Path"
        if ($Query -and $Query.Count -gt 0) {
            $pairs = @()
            foreach ($k in $Query.Keys) {
                $v = $Query[$k]
                if ($null -eq $v) { continue }
                $pairs += ("{0}={1}" -f [Uri]::EscapeDataString([string]$k), [Uri]::EscapeDataString([string]$v))
            }
            # NB: ${uri}? — `$uri?` would be parsed as a variable named "uri?"
            # because `?` is a legal identifier char in PowerShell.
            if ($pairs.Count -gt 0) { $uri = "${uri}?$($pairs -join '&')" }
        }

        $headers = @{ Authorization = "Bearer $($endpoint.token)" }

        $invokeParams = @{
            Uri        = $uri
            Method     = $Method
            Headers    = $headers
            TimeoutSec = $TimeoutSec
            # Don't auto-throw on 4xx/5xx; we surface them as structured results.
            SkipHttpErrorCheck = $true
        }
        if ($Method -ne 'GET' -and $null -ne $Body) {
            $invokeParams['Body']        = ($Body | ConvertTo-Json -Depth 20)
            $invokeParams['ContentType'] = 'application/json; charset=utf-8'
        }

        $resp = Invoke-WebRequest @invokeParams -ErrorAction Stop

        $parsed = $null
        $raw = if ($resp.Content -is [byte[]]) {
            [System.Text.Encoding]::UTF8.GetString($resp.Content)
        } else {
            [string]$resp.Content
        }
        if ($raw) {
            try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
        }

        return [ordered]@{
            status_code = [int]$resp.StatusCode
            body        = $parsed
            headers     = $resp.Headers
            raw         = $raw
        }
    }

    $first = & $attempt $false
    if ($first.status_code -ne 401) { return $first }

    # 401 — token rejected. PRD names this as the canonical "stale-token clients
    # see 401 and re-discover" case. The runtime.json may have been rewritten;
    # blow away any cached state and try once more.
    return (& $attempt $true)
}

function Invoke-McpRuntimeRequest {
    <#
    .SYNOPSIS
    MCP-side wrapper around Invoke-RuntimeRequest: surfaces 4xx/5xx as
    PowerShell exceptions whose messages contain the runtime's body text.

    .DESCRIPTION
    §"Tool error mapping": "a runtime 401 surfaces as MCP
    'authentication error'; a 404 surfaces as 'not found'; a 409 surfaces as
    'conflict' with the body message; a 422 surfaces as 'invalid transition'
    or 'validation error' depending on the body shape." We translate the
    status code to a short tag and throw so dotbot-mcp.ps1's tools/call
    catch-block surfaces it as an MCP error to Claude.

    On 2xx we just return $resp.body (the parsed JSON), which becomes the
    tool's result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method,

        [Parameter(Mandatory)] [string]$Path,
        [object]$Body,
        [hashtable]$Query
    )

    $params = @{ Method = $Method; Path = $Path }
    if ($PSBoundParameters.ContainsKey('Body'))  { $params['Body']  = $Body }
    if ($PSBoundParameters.ContainsKey('Query')) { $params['Query'] = $Query }
    $resp = Invoke-RuntimeRequest @params

    $code = [int]$resp.status_code
    if ($code -ge 200 -and $code -lt 300) {
        return $resp.body
    }

    # — short tag derived from status code, full server message
    # appended so the agent can read it in the surfaced MCP error.
    $tag = switch ($code) {
        401     { 'authentication error' }
        403     { 'forbidden' }
        404     { 'not found' }
        409     { 'conflict' }
        422     {
            # 422 is "invalid transition" for status changes and "validation
            # error" otherwise. The runtime sends an 'error' tag in the body
            # we can use to discriminate without re-parsing the URL.
            if ($resp.body -and $resp.body.PSObject.Properties['error'] -and
                $resp.body.error -eq 'illegal_transition') { 'invalid transition' } else { 'validation error' }
        }
        default { "runtime error ($code)" }
    }
    $serverMsg = $null
    if ($resp.body) {
        if ($resp.body.PSObject.Properties['message']) { $serverMsg = [string]$resp.body.message }
        elseif ($resp.body.PSObject.Properties['error']) { $serverMsg = [string]$resp.body.error }
    }
    if (-not $serverMsg) { $serverMsg = $resp.raw }
    throw "$tag`: $serverMsg"
}

Export-ModuleMember -Function @(
    'Invoke-RuntimeRequest'
    'Invoke-McpRuntimeRequest'
    'Get-McpActor'
)
