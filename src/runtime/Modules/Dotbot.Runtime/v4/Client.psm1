<#
.SYNOPSIS
Invoke-RuntimeRequest — thin client used by MCP tools (PRD-07) and the UI
proxy (PRD-08) to talk to the per-project HTTP runtime.

Canonical PRD: docs/prds/PRD-04-runtime-http-server.md §Implementation
Decisions: "The MCP and UI clients import Resolve-RuntimeEndpoint and a thin
Invoke-RuntimeRequest helper from Dotbot.Runtime."

Endpoint discovery is delegated to Resolve-RuntimeEndpoint. On 401 the helper
re-discovers (a stale runtime.json with a regenerated token is the canonical
case named by the PRD) and retries once.
#>

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
        [Parameter(Mandatory)] [string]$BotRoot,

        [Parameter(Mandatory)]
        [ValidateSet('GET','POST','PATCH','PUT','DELETE')]
        [string]$Method,

        [Parameter(Mandatory)] [string]$Path,

        [object]$Body,

        [hashtable]$Query,

        [int]$TimeoutSec = 30
    )

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
            if ($pairs.Count -gt 0) { $uri = "$uri?$($pairs -join '&')" }
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

Export-ModuleMember -Function @(
    'Invoke-RuntimeRequest'
)
