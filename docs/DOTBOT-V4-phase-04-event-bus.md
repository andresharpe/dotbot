# Phase 4: Event Bus

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Design
A lightweight in-process event system for the outpost.

**Path:** `profiles/default/systems/runtime/modules/EventBus.psm1`

```powershell
# Publishing events
Publish-DotBotEvent -Type "task.completed" -Data @{ task_id = $id; name = $name }

# Subscribing (plugins register at startup)
Register-DotBotEventSink -Name "aether" -Handler { param($Event) ... }
Register-DotBotEventSink -Name "webhooks" -Handler { param($Event) ... }
Register-DotBotEventSink -Name "mothership" -Handler { param($Event) ... }
```

**Event envelope:**
```json
{
  "id": "evt-abc123",
  "type": "task.completed",
  "timestamp": "2026-03-14T10:00:00Z",
  "source": "runtime",
  "data": { "task_id": "...", "name": "..." }
}
```

**File-based event log:** `.bot/.control/events.jsonl` — all events are persisted for replay and debugging.

**Plugin discovery:** Event sinks are loaded from `systems/events/sinks/` — each subfolder contains a `sink.psm1` with `Register-*` and `Invoke-*` functions.

```
systems/events/
  EventBus.psm1
  sinks/
    aether/sink.psm1       # Refactored from AetherAPI.psm1
    webhooks/sink.psm1     # NEW — POST events to configured URLs
    mothership/sink.psm1   # Refactored from NotificationClient.psm1
```

## Aether refactor
- Currently: `AetherAPI.psm1` (UI module) + `aether.js` (frontend) poll state and react
- Target: `aether/sink.psm1` subscribes to events via the bus. The UI frontend (`aether.js`) receives events via the existing polling/SSE mechanism and drives the Hue API calls.
- The Hue bridge interaction stays client-side (browser → API proxy → bridge) since it needs LAN access

## Webhook sink
```json
"webhooks": {
  "enabled": true,
  "endpoints": [
    {
      "url": "https://hooks.example.com/dotbot",
      "events": ["task.completed", "decision.created"],
      "secret": "hmac-secret"
    }
  ]
}
```

## Files
- Create: `profiles/default/systems/events/EventBus.psm1`
- Create: `profiles/default/systems/events/sinks/aether/sink.psm1`
- Create: `profiles/default/systems/events/sinks/webhooks/sink.psm1`
- Create: `profiles/default/systems/events/sinks/mothership/sink.psm1`
- Modify: `profiles/default/systems/ui/modules/AetherAPI.psm1` (delegate to sink)
- Modify: `profiles/default/systems/mcp/modules/NotificationClient.psm1` (delegate to sink)
- Modify: Runtime process types to emit events at lifecycle points
- Settings: Add `events` section to `settings.default.json`
