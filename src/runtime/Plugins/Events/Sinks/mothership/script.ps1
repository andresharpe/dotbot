<#
.SYNOPSIS
mothership sink — forward selected bus events to the mothership fleet server.

GATED NO-OP (by design, for now): the server-side fleet events endpoint
(POST /api/fleet/{instance_id}/events) is owned by #599/#544 and does not exist
yet. Until it lands this sink evaluates all its gates and then no-ops instead of
POSTing, so enabling it is safe. When the endpoint ships, the forward step wires
through Dotbot.Notification (the existing mothership client) — the decision
logic here (Test-MothershipShouldForward) does not change.

Gates (all must pass to forward):
  - mothership.enabled              (the fleet connection is configured/on)
  - events.mothership.enabled       (the sink itself is turned on)
  - mothership.server_url is set
  - event type matches mothership.sync_events (glob list; empty → all)

Config is handed in via $Context.Settings (full merged settings).
#>

function Test-MothershipShouldForward {
    <#
    .SYNOPSIS
    Decide whether an event should be forwarded to the mothership. Pure logic
    (no network) so it is unit-testable. Returns @{ forward = $bool; reason = '...' }.
    #>
    param(
        [Parameter(Mandatory)] $Event,
        [Parameter(Mandatory)] $Settings
    )

    $ms = $null
    $sink = $null
    if ($null -ne $Settings) {
        $ms = $Settings.mothership
        if ($null -ne $Settings.events) { $sink = $Settings.events.mothership }
    }

    $msEnabled = $false
    try { $msEnabled = [bool]$ms.enabled } catch { $msEnabled = $false }
    if (-not $msEnabled) { return @{ forward = $false; reason = 'mothership_disabled' } }

    $sinkEnabled = $false
    try { $sinkEnabled = [bool]$sink.enabled } catch { $sinkEnabled = $false }
    if (-not $sinkEnabled) { return @{ forward = $false; reason = 'sink_disabled' } }

    $serverUrl = ''
    try { $serverUrl = [string]$ms.server_url } catch { $serverUrl = '' }
    if ([string]::IsNullOrWhiteSpace($serverUrl)) { return @{ forward = $false; reason = 'no_server_url' } }

    $type = if ($Event -is [hashtable]) { [string]$Event['type'] } else { [string]$Event.type }
    $sync = @($ms.sync_events)
    $matched = $sync.Count -eq 0
    foreach ($s in $sync) {
        if ($type -like [string]$s) { $matched = $true; break }
    }
    if (-not $matched) { return @{ forward = $false; reason = 'not_in_sync_events' } }

    return @{ forward = $true; reason = 'ok' }
}

function Invoke-Sink {
    param($Event, $Context)

    $settings = if ($null -ne $Context) { $Context.Settings } else { $null }
    if ($null -eq $settings) { return @{ Success = $true; Message = 'mothership: no settings' } }

    $decision = Test-MothershipShouldForward -Event $Event -Settings $settings
    if (-not $decision.forward) {
        return @{ Success = $true; Message = "mothership: skipped ($($decision.reason))" }
    }

    # GATED NO-OP: the fleet events endpoint (#599/#544) does not exist yet.
    # When it does, forward here via Dotbot.Notification. Until then this is a
    # deliberate no-op — the gates above still run so the behaviour is correct
    # the moment the endpoint ships.
    return @{ Success = $true; Message = 'mothership: would forward (fleet events endpoint pending #599/#544)' }
}

Export-ModuleMember -Function @(
    'Invoke-Sink'
    'Test-MothershipShouldForward'
)
