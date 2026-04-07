# Phase 15: Aether Conduit Plugins

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Problem

Aether is currently hardwired as a single Hue-only integration inside the UI module (`AetherAPI.psm1` + `aether.js`). Five mature, tested PowerShell modules exist as standalone repos that control IoT/console hardware. These need to be unified under the Aether conduit abstraction and migrated into a single add-in collection repo that any dotbot outpost can consume via the Phase 4 Event Bus.

## Current State

### Standalone Repos

**Ambient Conduit — Hue** (`Hue`)
- Module: `HueBridge` v2.0.0, 39 public functions
- Capabilities: Bridge discovery (N-UPnP, SSDP, ARP, subnet scan), CLIP v1+v2 REST, DTLS entertainment streaming, multi-light effects (chase, wave, color cycle, strobe, rainbow, two-tone, color burst), state save/restore, rate limiting
- Protocol: HTTPS REST + DTLS UDP streaming (LAN)
- 43 source files, 2 test files

**Window Conduit — Pixoo** (`Pixoo`)
- Module: `Pixoo64` v1.0.0, 36 public functions
- Capabilities: Device discovery (cloud API, ARP, subnet scan), text/image/animation display, GIF URLs, solid colors, clock faces, channels, timer/stopwatch/scoreboard/noise meter/buzzer, batch commands, brightness/rotation/mirror
- Protocol: HTTP REST (LAN)
- 41 source files, 5 test files, PSScriptAnalyzer config

**Sonic & Ambient Conduit — JblPartyBox** (`JblPartyBox`)
- Module: `JblPartyBox`, light + sound control
- Capabilities: Light patterns (Neon, Loop, Bounce, Trim, Switch, Freeze, Custom), solid colors by name/RGB, brightness/speed, 4 light zones, color modes (ColorLoop, Static), 19 DJ sound effects (horn, scratch, party, etc.), 5 DJ audio filters (repeater, filter, gater, echo, wipeout)
- Protocol: Bluetooth serial (Windows only)
- 25 source files, 27 test files (best test coverage)

**Console Conduit — StreamDeck** (`StreamDeck`)
- Module: `DotBot.Sidecar` v0.1.0, 7 public functions + SD plugin (TypeScript)
- Capabilities: HTTP sidecar server (port 7331), button icon generation, strip icon generation, deck state model, dotbot state polling, Hue state bridging, SD plugin install/profile import
- Protocol: HTTP sidecar ↔ Stream Deck SDK (WebSocket)
- Already references "aether conduit" — most tightly coupled to dotbot
- 36 source files, 16 test files

**Counter Conduit — TextPrinter** (`TextPrinter`)
- Module: `Printer`, 19 public functions
- Capabilities: Network discovery (ARP, subnet scan), text printing with formatting (alignment, bold, size), receipt printing (header/body/footer), paper cut, two-color printing (black/red), font selection, buzzer, horizontal rules
- Protocol: TCP/IP port 9100 (ESC/POS)
- 24 source files, 5 test files

### Existing Aether in dotbot

- `profiles/default/systems/ui/modules/AetherAPI.psm1` (290 lines) — Hue-only discovery, bond, node control
- `profiles/default/systems/ui/static/modules/aether.js` (930 lines) — frontend event reactions, Hue API proxy calls
- Lexicon already established: Conduit, Node, Bond, Pulse, Radiate, Scan, Token, Cluster

### Cost Settings (relevant to Counter Conduit)

`settings.default.json` already has `costs.hourly_rate`, `costs.ai_cost_per_task`, `costs.ai_speedup_factor`, `costs.currency` — the data needed for tally/reckoning receipts.

---

## Design

### Conduit Type Taxonomy

Conduit types describe the *nature* of the conduit, not the hardware. Multiple hardware implementations can share a type.

- **Ambient** — emits light (Hue, future: Nanoleaf, WLED)
- **Sonic & Ambient** — emits light and sound (JBL PartyBox)
- **Window** — displays visual information (Pixoo, future: second LED panel)
- **Console** — accepts input, provides control surface (Stream Deck)
- **Counter** — produces physical records/tallies (TextPrinter)

### New Repo: `dotbot-aether`

A single add-in collection repo containing all conduit plugins.

```
dotbot-aether/
  README.md
  conduit.manifest.json          # registry of available conduits
  conduits/
    ambient/
      conduit.json               # type, capabilities, dependencies
      src/AetherAmbient/         # migrated from Hue repo
        AetherAmbient.psm1
        AetherAmbient.psd1
        Public/                  # subset of HueBridge functions needed for sink
        Private/
      tests/
    window/
      conduit.json
      src/AetherWindow/          # migrated from Pixoo repo
        AetherWindow.psm1
        AetherWindow.psd1
        Public/
        Private/
      tests/
    sonic/
      conduit.json
      src/AetherSonic/           # migrated from JblPartyBox repo
        AetherSonic.psm1
        AetherSonic.psd1
        Public/
        Private/
      tests/
    console/
      conduit.json
      src/AetherConsole/         # migrated from StreamDeck repo
        AetherConsole.psm1
        AetherConsole.psd1
        Public/
        Private/
      tests/
    counter/
      conduit.json
      src/AetherCounter/         # migrated from TextPrinter repo
        AetherCounter.psm1
        AetherCounter.psd1
        Public/
        Private/
      tests/
  shared/
    AetherCore.psm1              # shared conduit base: scan, bond, lifecycle
    AetherTypes.ps1              # event type enums, conduit type constants
```

### conduit.json Schema

```json
{
  "name": "ambient",
  "type": "ambient",
  "version": "1.0.0",
  "module": "src/AetherAmbient/AetherAmbient.psd1",
  "capabilities": ["radiate", "pulse", "breathe", "chase", "wave"],
  "discovery": "lan",
  "protocol": "https-rest",
  "platforms": ["windows", "linux", "macos"],
  "events": [
    "task.started",
    "task.completed",
    "task.failed",
    "process.started",
    "process.stopped"
  ]
}
```

### Conduit Interface Contract

Each conduit module must export these standard functions:

- `Initialize-Aether{Type}` — accept config, validate hardware reachability
- `Find-Aether{Type}` — discover hardware on network/bus
- `Connect-Aether{Type}` — bond to discovered hardware
- `Disconnect-Aether{Type}` — clean shutdown
- `Test-Aether{Type}` — health check
- `Invoke-Aether{Type}Event` — handle an event bus event (the sink entry point)

The `Invoke-Aether{Type}Event` function receives the standard event envelope and maps it to hardware-specific actions. Each conduit defines its own event→action mapping.

### Event→Action Mappings

**Ambient (Hue)**
- `task.started` → breathe primary color
- `task.completed` → pulse success color
- `task.failed` → pulse error color, hold 3s
- `process.started` → radiate primary, slow breathe
- `workflow.completed` → celebration chase (theme color sequence)

**Window (Pixoo)**
- `task.started` → display task name + spinner animation
- `task.completed` → display checkmark + task count
- `task.failed` → display X + error icon
- `workflow.completed` → celebration animation
- idle → clock face / task counter dashboard

**Sonic & Ambient (JBL)**
- `task.started` → soft ambient color
- `task.completed` → green pulse + optional short sound
- `task.failed` → red pulse + alert tone
- `workflow.completed` → celebration lights + party sound
- Light patterns mirror Ambient conduit where possible

**Console (StreamDeck)**
- All events → update button states/icons (running, complete, failed indicators)
- Button presses → invoke dotbot API (start task, whisper, approve, stop)
- Strip → status bar (active process count, health)
- Already has sidecar architecture; migrates to event-driven model

**Counter (TextPrinter)**
- `task.completed` → accumulate cost tally (AI cost vs estimated manual cost)
- `workflow.completed` → print workflow tally receipt (total tasks, savings, duration)
- `reckoning.daily` → print daily summary receipt
- `reckoning.weekly` → print weekly summary receipt
- Receipt format: header (event type), body (metrics), footer (running total), paper cut
- Uses red ink for savings highlight, black for details
- Buzzer on milestone tallies

### Settings Extension

Add to `settings.default.json`:

```json
"aether": {
  "enabled": true,
  "conduit_path": null,
  "conduits": {
    "ambient":  { "enabled": false },
    "window":   { "enabled": false },
    "sonic":    { "enabled": false },
    "console":  { "enabled": false },
    "counter":  { "enabled": false, "reckonings": ["task", "workflow", "daily"] }
  }
}
```

`conduit_path` points to the local clone of `dotbot-aether`. When null, aether is disabled regardless of per-conduit settings.

### Integration with Phase 4 Event Bus

The Event Bus (`EventBus.psm1`) loads conduit sinks at startup:

1. Read `aether.conduit_path` from settings
2. Read `conduit.manifest.json` from the collection repo
3. For each enabled conduit, import its module and call `Initialize-Aether{Type}`
4. Register each conduit as an event sink via `Register-DotBotEventSink`
5. On event, the bus calls `Invoke-Aether{Type}Event` with the event envelope

This replaces the current approach where `aether/sink.psm1` (from Phase 4 spec) was a single Hue-only sink. Instead, the aether sink becomes a *conduit loader* that delegates to individual conduit modules.

### Migration Strategy

The original standalone repos remain intact as the upstream source of each hardware module. The `dotbot-aether` repo wraps them with the conduit interface:

1. Copy source modules into `dotbot-aether/conduits/{type}/src/`
2. Add the conduit interface wrapper (`Invoke-Aether{Type}Event` + standard lifecycle functions)
3. The wrapper imports the underlying hardware module and translates events to hardware calls
4. Tests migrate alongside source; add conduit-interface integration tests
5. Original repos continue to work standalone for direct hardware use outside dotbot

---

## Implementation Steps

1. Create `dotbot-aether` repo with directory structure and `conduit.manifest.json`
2. Create `shared/AetherCore.psm1` — shared scan/bond/lifecycle base, event envelope parsing
3. Migrate Ambient (Hue) — copy `HueBridge` module, add conduit wrapper, wire event→action mappings
4. Migrate Window (Pixoo) — copy `Pixoo64` module, add conduit wrapper, wire event→action mappings
5. Migrate Sonic (JBL) — copy `JblPartyBox` module, add conduit wrapper, wire event→action mappings (both light + sound)
6. Migrate Console (StreamDeck) — copy `DotBot.Sidecar` module, refactor from polling to event-driven, add conduit wrapper
7. Migrate Counter (TextPrinter) — copy `Printer` module, add conduit wrapper, implement tally accumulation and reckoning receipt templates
8. Add `aether` settings section to `settings.default.json` and wire into settings UI
9. Update Phase 4 `aether/sink.psm1` to become the conduit loader (reads manifest, imports enabled conduits, delegates events)
10. Add Aether conduit management to Dashboard UI (conduit status, bond/unbond, test)
11. End-to-end testing — emit events through bus, verify each conduit type reacts

---

## Dependencies

- **Phase 4 (Event Bus)** — conduits subscribe to events via the bus
- **Phase 1 (Logging)** — conduit lifecycle and errors need structured logging

---

## Verification

- `Import-Module shared/AetherCore.psm1` — no errors
- Each conduit: `Find-Aether{Type}` discovers hardware, `Connect-Aether{Type}` bonds, `Test-Aether{Type}` returns healthy
- Event bus emits `task.completed` → all enabled conduits react (light pulses, display updates, receipt prints, button icons update)
- Counter conduit prints accurate cost tally using `costs.*` settings
- Conduit with missing hardware degrades gracefully (logs warning, doesn't block other conduits)
- All existing standalone repo tests pass when run from within `dotbot-aether` structure
