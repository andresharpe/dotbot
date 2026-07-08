<#
.SYNOPSIS
webhooks sink — POST matching bus events to configured HTTPS endpoints.

Config (from settings' events.webhooks section, handed in via $Context.Settings.events):
    {
      "enabled": true,
      "endpoints": [
        { "url": "https://hooks.example.com/dotbot", "events": ["task.*"], "secret": "…" }
      ]
    }

For each configured endpoint whose `events` filter matches the event type AND
whose URL passes HTTPS + SSRF validation, the event JSON is POSTed with an
HMAC-SHA256 signature (header X-DotBot-Signature: sha256=<hex>) derived from the
endpoint's `secret`.

Helpers are exported alongside Invoke-Sink so they can be unit-tested without a
live endpoint (the actual POST is integration-only).
#>

function Test-IpBlocked {
    <#
    .SYNOPSIS
    $true when an IP is loopback / private / link-local / metadata / otherwise
    not a safe public destination (SSRF guard).
    #>
    param([Parameter(Mandatory)] [System.Net.IPAddress]$IpAddress)

    $ip = $IpAddress
    # Collapse IPv4-mapped IPv6 (::ffff:a.b.c.d) down to IPv4 for range checks.
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }

    if ([System.Net.IPAddress]::IsLoopback($ip)) { return $true }

    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $ip.GetAddressBytes()   # 4 bytes
        if ($b[0] -eq 0)   { return $true }                                   # 0.0.0.0/8 "this network"
        if ($b[0] -eq 10)  { return $true }                                   # 10/8 private
        if ($b[0] -eq 127) { return $true }                                   # loopback
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $true }                # 169.254/16 link-local (incl. 169.254.169.254 metadata)
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $true } # 172.16/12 private
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }                # 192.168/16 private
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $true } # 100.64/10 CGNAT
        if ($b[0] -ge 224) { return $true }                                   # 224/4 multicast + 240/4 reserved
        return $false
    }

    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ($ip.IsIPv6LinkLocal -or $ip.IsIPv6Multicast -or $ip.IsIPv6SiteLocal) { return $true }
        if ($ip.Equals([System.Net.IPAddress]::IPv6Loopback)) { return $true }
        if ($ip.Equals([System.Net.IPAddress]::IPv6Any)) { return $true }
        # fc00::/7 unique-local
        $bytes = $ip.GetAddressBytes()
        if (($bytes[0] -band 0xFE) -eq 0xFC) { return $true }
        return $false
    }

    return $true  # unknown address family → treat as unsafe
}

function Test-WebhookUrlAllowed {
    <#
    .SYNOPSIS
    Validate a webhook URL: HTTPS-only + SSRF guard. Returns
    @{ allowed = $bool; reason = '<why>' }.
    #>
    param([Parameter(Mandatory)] [string]$Url)

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return @{ allowed = $false; reason = 'malformed_url' }
    }
    if ($uri.Scheme -ne 'https') {
        return @{ allowed = $false; reason = 'not_https' }
    }

    $hostName = $uri.DnsSafeHost
    $lower = $hostName.ToLowerInvariant()
    if ($lower -eq 'localhost' -or $lower.EndsWith('.localhost') -or
        $lower.EndsWith('.local') -or $lower.EndsWith('.internal')) {
        return @{ allowed = $false; reason = 'internal_hostname' }
    }

    # IP-literal host → check ranges directly (no DNS).
    $literal = $null
    if ([System.Net.IPAddress]::TryParse($hostName, [ref]$literal)) {
        if (Test-IpBlocked -IpAddress $literal) {
            return @{ allowed = $false; reason = 'blocked_ip_range' }
        }
        return @{ allowed = $true; reason = 'ok' }
    }

    # Hostname → resolve and check every resolved address. Fail closed if it
    # can't be resolved (a webhook to an unresolvable host is undeliverable
    # anyway, and failing closed avoids surprises).
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($hostName)
    } catch {
        return @{ allowed = $false; reason = 'dns_resolution_failed' }
    }
    if (-not $addresses -or $addresses.Count -eq 0) {
        return @{ allowed = $false; reason = 'dns_no_addresses' }
    }
    foreach ($addr in $addresses) {
        if (Test-IpBlocked -IpAddress $addr) {
            return @{ allowed = $false; reason = 'resolves_to_blocked_ip' }
        }
    }
    return @{ allowed = $true; reason = 'ok' }
}

function New-WebhookSignature {
    <#
    .SYNOPSIS
    HMAC-SHA256 of the body keyed by the endpoint secret, as 'sha256=<hex>'.
    #>
    param(
        [Parameter(Mandatory)] [string]$Body,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Secret
    )
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Body))
    } finally {
        $hmac.Dispose()
    }
    $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
    return "sha256=$hex"
}

function Get-WebhookDeliveryPlan {
    <#
    .SYNOPSIS
    Return the endpoints that WOULD receive this event: those whose `events`
    filter matches the event type AND whose URL passes HTTPS/SSRF validation.
    Pure decision logic (no network), so it is unit-testable.
    #>
    param(
        [Parameter(Mandatory)] $Event,
        [Parameter(Mandatory)] $Config
    )

    $type = if ($Event -is [hashtable]) { [string]$Event['type'] } else { [string]$Event.type }
    $plan = @()
    foreach ($ep in @($Config.endpoints)) {
        if ($null -eq $ep) { continue }
        $url = [string]$ep.url
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        # Per-endpoint event filter. Empty/missing → match everything.
        $filters = @($ep.events)
        $matched = $filters.Count -eq 0
        foreach ($f in $filters) {
            if ($type -like [string]$f) { $matched = $true; break }
        }
        if (-not $matched) { continue }

        $check = Test-WebhookUrlAllowed -Url $url
        if (-not $check.allowed) { continue }

        $plan += ,([pscustomobject]@{
            url    = $url
            secret = [string]$ep.secret
            events = $filters
        })
    }
    return $plan
}

function Invoke-Sink {
    param($Event, $Context)

    $cfg = $null
    if ($null -ne $Context -and $null -ne $Context.Settings -and $null -ne $Context.Settings.events) {
        $cfg = $Context.Settings.events.webhooks
    }
    if ($null -eq $cfg) { return @{ Success = $true; Message = 'webhooks: no config' } }

    $enabled = $false
    try { $enabled = [bool]$cfg.enabled } catch { $enabled = $false }
    if (-not $enabled) { return @{ Success = $true; Message = 'webhooks: disabled' } }

    $plan = @(Get-WebhookDeliveryPlan -Event $Event -Config $cfg)
    if ($plan.Count -eq 0) { return @{ Success = $true; Message = 'webhooks: no matching endpoints' } }

    $type = if ($Event -is [hashtable]) { [string]$Event['type'] } else { [string]$Event.type }
    $body = $Event | ConvertTo-Json -Depth 12 -Compress

    $sent = 0
    $failed = 0
    foreach ($ep in $plan) {
        $sig = New-WebhookSignature -Body $body -Secret $ep.secret
        try {
            Invoke-WebRequest -Uri $ep.url -Method POST -Body $body `
                -ContentType 'application/json; charset=utf-8' `
                -Headers @{ 'X-DotBot-Event' = $type; 'X-DotBot-Signature' = $sig } `
                -TimeoutSec 10 -SkipHttpErrorCheck -UseBasicParsing | Out-Null
            $sent++
        } catch {
            $failed++
        }
    }

    return @{
        Success = ($failed -eq 0)
        Message = "webhooks: sent=$sent failed=$failed of $($plan.Count)"
    }
}

Export-ModuleMember -Function @(
    'Invoke-Sink'
    'Test-IpBlocked'
    'Test-WebhookUrlAllowed'
    'New-WebhookSignature'
    'Get-WebhookDeliveryPlan'
)
