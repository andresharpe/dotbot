# dotbot v4 — Release Roadmap

> Three focused releases. Each one unlocks the next.

---

## Delivery History

| Version | Released | Issues Closed |
|---|---|---|
| v4.0.0 | June 4, 2026 | Initial v4 launch |
| [v4.0.1](release-notes/v4.0.1.md) | July 3, 2026 | 41 issues — 27 fixes, 14 enhancements |

---

## Release Summary

| Release | Version | Theme | Focus | Issues |
|---|---|---|---|---|
| R1 | v4.1 | **Stable · Enterprise · Drone** | Harden the runtime, deliver questionnaire & approval layer, land fleet registration & Drone | 13 |
| R2 | v4.2 | **Fleet · Workflow · Nice-to-have** | Fleet dashboard & auth, complete the workflow engine, ship deferred enterprise & improvement items | 15 |
| R3 | v4.3 | **Intelligence · Improvements** | AI self-improvement, knowledge injection, Aether conduits, remaining improvement backlog | 9 |
| — | ongoing | **UI / UX** | Design system delivered incrementally across all releases | 5 |

---

## R1 — v4.1 · Stable · Enterprise · Drone

> Harden the runtime. Deliver questionnaire & approval layer. Land fleet registration & Drone.

**Why first:** Stabilization items unblock clean development. The Event Bus (#93) is a hard blocker for fleet, drone, and enterprise features. Enterprise questionnaire and team/roles form the approval layer that downstream automation depends on.

### Stabilization (2 remaining)

> 8 of 10 stabilization items shipped in v4.0.1.

| Issue | Title |
|---|---|
| [#509](https://github.com/andresharpe/dotbot/issues/509) | Preflight content-aware checks |
| [#458](https://github.com/andresharpe/dotbot/issues/458) | Update README docs |

<details>
<summary>Closed in v4.0.1 (8 issues)</summary>

| Issue | Title |
|---|---|
| ~~[#537](https://github.com/andresharpe/dotbot/issues/537)~~ | ~~Orphan worktree corrupts filesystem~~ |
| ~~[#536](https://github.com/andresharpe/dotbot/issues/536)~~ | ~~Non-atomic task claim under concurrency~~ |
| ~~[#518](https://github.com/andresharpe/dotbot/issues/518)~~ | ~~Output delta validation on resume~~ |
| ~~[#516](https://github.com/andresharpe/dotbot/issues/516)~~ | ~~interview-answers.json merge conflicts~~ |
| ~~[#519](https://github.com/andresharpe/dotbot/issues/519)~~ | ~~Products page missing artifacts~~ |
| ~~[#393](https://github.com/andresharpe/dotbot/issues/393)~~ | ~~CI Bump & Release fails~~ |
| ~~[#504](https://github.com/andresharpe/dotbot/issues/504)~~ | ~~Cannot find Claude and Git~~ |
| ~~[#511](https://github.com/andresharpe/dotbot/issues/511)~~ | ~~Manage dotbot versioning~~ |

</details>

### Enterprise (3 remaining)

> 2 of 5 enterprise items shipped in v4.0.1.

| Issue | Title |
|---|---|
| [#93](https://github.com/andresharpe/dotbot/issues/93) | Event bus — critical blocker |
| [#545](https://github.com/andresharpe/dotbot/issues/545) | Q&A web provider & channel prefs |
| [#98](https://github.com/andresharpe/dotbot/issues/98) | Project team & roles |

<details>
<summary>Closed in v4.0.1 (2 issues)</summary>

| Issue | Title |
|---|---|
| ~~[#29](https://github.com/andresharpe/dotbot/issues/29)~~ | ~~Expand QuestionService & approvals~~ |
| ~~[#30](https://github.com/andresharpe/dotbot/issues/30)~~ | ~~Jira as an approval channel~~ |

</details>

### Mothership & Fleet (6 issues)

| Issue | Title |
|---|---|
| [#544](https://github.com/andresharpe/dotbot/issues/544) | Fleet server: registration & heartbeat |
| [#95](https://github.com/andresharpe/dotbot/issues/95) | Mothership fleet coordination |
| [#96](https://github.com/andresharpe/dotbot/issues/96) | Drone agent — remote task execution |
| [#576](https://github.com/andresharpe/dotbot/issues/576) | Mothership deployment & setup (Dockerfile, docker-compose, env reference) |
| [#574](https://github.com/andresharpe/dotbot/issues/574) | Drone credential store (PAT-in-URL fix, http.extraHeader auth) |
| [#575](https://github.com/andresharpe/dotbot/issues/575) | Outpost-to-Drone task delegation (execution: local\|drone\|auto) |

**Gate to R2:** Event Bus emitting events end-to-end · all stabilization items closed · fleet registration working · Drone agent spawning

---

## R2 — v4.2 · Fleet · Workflow · Nice-to-have

> Fleet dashboard & auth. Complete the workflow engine. Ship deferred enterprise & improvement items.

**Why second:** Fleet dashboard and OIDC/RBAC build on the fleet registration layer from R1. Workflow Builder completion depends on the process refactor and event-driven triggers landed in R1. Enterprise and Mothership nice-to-haves are deferred here to keep R1 lean.

### Enterprise (2 issues)

| Issue | Title |
|---|---|
| [#38](https://github.com/andresharpe/dotbot/issues/38) | OpenClaw channels for orchestration |
| [#39](https://github.com/andresharpe/dotbot/issues/39) | Jira-initiated project kickstart |

### Mothership & Fleet (2 issues)

| Issue | Title |
|---|---|
| [#547](https://github.com/andresharpe/dotbot/issues/547) | Fleet dashboard: instance cards & metrics |
| [#548](https://github.com/andresharpe/dotbot/issues/548) | Auth layer: OIDC, IAuthProvider & RBAC |

### Workflow Builder (5 issues)

> `#522` removed — delivered as [#427](https://github.com/andresharpe/dotbot/issues/427) in v4.0.1.

| Issue | Title |
|---|---|
| [#129](https://github.com/andresharpe/dotbot/issues/129) | GitHub Workflow Family |
| [#102](https://github.com/andresharpe/dotbot/issues/102) | User-level workflow editor |
| [#380](https://github.com/andresharpe/dotbot/issues/380) | Skill Builder Feature |
| [#542](https://github.com/andresharpe/dotbot/issues/542) | Process isolation: InterviewLoop & IPolicyEvaluator |
| [#543](https://github.com/andresharpe/dotbot/issues/543) | HealthAPI, ConfigValidator & idempotent init |

### Improvements & Dev Exp (6 issues)

| Issue | Title |
|---|---|
| [#512](https://github.com/andresharpe/dotbot/issues/512) | Selective Workflow Re-run |
| [#510](https://github.com/andresharpe/dotbot/issues/510) | Task Output Contract & execution gates |
| [#503](https://github.com/andresharpe/dotbot/issues/503) | On-Demand External Task Trigger |
| [#416](https://github.com/andresharpe/dotbot/issues/416) | Promote inbound decisions to ADRs |
| [#546](https://github.com/andresharpe/dotbot/issues/546) | Telemetry: OTel SDK & sinks |
| [#550](https://github.com/andresharpe/dotbot/issues/550) | Registry: remove, namespace:stack & auto-update |

**Gate to R3:** Fleet dashboard live · OIDC/RBAC enforced · Workflow Builder feature-complete · all improvement items closed

---

## R3 — v4.3 · Intelligence · Improvements

> AI self-improvement, knowledge injection, Aether conduits, and the remaining improvement backlog.

**Why third:** Self-improvement loop and Aether conduits depend on a stable Event Bus (R1) and a working fleet/drone layer (R2). Knowledge provider and shared memory require the workflow engine to be complete (R2).

### Improvements & Dev Exp (5 issues)

| Issue | Title |
|---|---|
| [#97](https://github.com/andresharpe/dotbot/issues/97) | Self-improvement loop |
| [#99](https://github.com/andresharpe/dotbot/issues/99) | Aether conduit plugin architecture |
| [#549](https://github.com/andresharpe/dotbot/issues/549) | IKnowledgeProvider: vector DB & ontology |
| [#76](https://github.com/andresharpe/dotbot/issues/76) | Built-in Shared Memory System |
| [#505](https://github.com/andresharpe/dotbot/issues/505) | Filter & Sort Decisions per Workflow |

### Workflow Builder (4 issues)

Remaining Workflow Builder items to be scheduled into R3 as R2 closes. Candidates from the gap analysis:
- `workflow-status`, `pause` & `resume` MCP tools (Ph3/Ph7 tail)
- Workflow tab UI & task lifecycle visualisation (Ph3 tail)
- Mothership registry sync & auto-update trigger (Ph11 tail)
- Additional workflow policy and retry items identified during R2

**Gate to ship:** Self-improvement loop running · at least 2 Aether conduit types bonding to events · Workflow Builder fully closed

---

## UI / UX — Ongoing Across All Releases

Design system delivered incrementally. Not gated to a single release.

| Issue | Title |
|---|---|
| [#32](https://github.com/andresharpe/dotbot/issues/32) | Workflow tab UI & task lifecycle viz |
| [#551](https://github.com/andresharpe/dotbot/issues/551) | Navigation shell redesign |
| [#552](https://github.com/andresharpe/dotbot/issues/552) | Visual design system |
| [#553](https://github.com/andresharpe/dotbot/issues/553) | ⌘K command palette |
| [#554](https://github.com/andresharpe/dotbot/issues/554) | Accessibility & ADR integration |

---

## Dependency Chain

```
R1: Stabilization ──► Event Bus (#93) ──────────────────────────┐
                           │                                     │
                           ├─► Enterprise Q&A (#545, #98)        │
                           ├─► Fleet registration (#544, #95)    │
                           ├─► Drone agent (#96)                 │
                           ├─► Mothership setup (#576)           │
                           ├─► Drone credential store (#574)     │
                           └─► Task delegation (#575)            │
                                                                  │
R2: Fleet dashboard (#547, #548) ◄── R1 fleet layer              │
    Workflow Builder (#129, #102, #380, #542, #543)               │
    Improvements (#512, #510, #503, #416, #546, #550)             │
    Enterprise nice-to-have (#38, #39)                            │
                                                                  │
R3: Self-improvement (#97) ◄── drones (R1) + workflow (R2)       │
    Aether conduits (#99) ◄──────────────────────────────────────┘
    Knowledge provider (#549), Shared memory (#76)
    Remaining Workflow Builder (4 items)

UI/UX (#32, #551, #552, #553, #554) ── ongoing across R1 → R3
```

---

## All Issues by Release

| Issue | Title | Release | Area |
|---|---|---|---|
| [#509](https://github.com/andresharpe/dotbot/issues/509) | Preflight content-aware checks | R1 | V4-Stabilization |
| [#458](https://github.com/andresharpe/dotbot/issues/458) | Update README docs | R1 | V4-Stabilization |
| [#93](https://github.com/andresharpe/dotbot/issues/93) | Event bus — critical blocker | R1 | Enterprise Features |
| [#545](https://github.com/andresharpe/dotbot/issues/545) | Q&A web provider & channel prefs | R1 | Enterprise Features |
| [#98](https://github.com/andresharpe/dotbot/issues/98) | Project team & roles | R1 | Enterprise Features |
| [#544](https://github.com/andresharpe/dotbot/issues/544) | Fleet server: registration & heartbeat | R1 | Mothership & Fleet |
| [#95](https://github.com/andresharpe/dotbot/issues/95) | Mothership fleet coordination | R1 | Mothership & Fleet |
| [#96](https://github.com/andresharpe/dotbot/issues/96) | Drone agent — remote task execution | R1 | Mothership & Fleet |
| [#576](https://github.com/andresharpe/dotbot/issues/576) | Mothership deployment & setup | R1 | Mothership & Fleet |
| [#574](https://github.com/andresharpe/dotbot/issues/574) | Drone credential store | R1 | Mothership & Fleet |
| [#575](https://github.com/andresharpe/dotbot/issues/575) | Outpost-to-Drone task delegation | R1 | Mothership & Fleet |
| [#38](https://github.com/andresharpe/dotbot/issues/38) | OpenClaw channels for orchestration | R2 | Enterprise Features |
| [#39](https://github.com/andresharpe/dotbot/issues/39) | Jira-initiated project kickstart | R2 | Enterprise Features |
| [#547](https://github.com/andresharpe/dotbot/issues/547) | Fleet dashboard: instance cards & metrics | R2 | Mothership & Fleet |
| [#548](https://github.com/andresharpe/dotbot/issues/548) | Auth layer: OIDC, IAuthProvider & RBAC | R2 | Mothership & Fleet |
| [#129](https://github.com/andresharpe/dotbot/issues/129) | GitHub Workflow Family | R2 | Workflow Builder |
| [#102](https://github.com/andresharpe/dotbot/issues/102) | User-level workflow editor | R2 | Workflow Builder |
| [#380](https://github.com/andresharpe/dotbot/issues/380) | Skill Builder Feature | R2 | Workflow Builder |
| [#542](https://github.com/andresharpe/dotbot/issues/542) | Process isolation: InterviewLoop & IPolicyEvaluator | R2 | Workflow Builder |
| [#543](https://github.com/andresharpe/dotbot/issues/543) | HealthAPI, ConfigValidator & idempotent init | R2 | Workflow Builder |
| [#512](https://github.com/andresharpe/dotbot/issues/512) | Selective Workflow Re-run | R2 | Improvements & Developer Experience |
| [#510](https://github.com/andresharpe/dotbot/issues/510) | Task Output Contract & execution gates | R2 | Improvements & Developer Experience |
| [#503](https://github.com/andresharpe/dotbot/issues/503) | On-Demand External Task Trigger | R2 | Improvements & Developer Experience |
| [#416](https://github.com/andresharpe/dotbot/issues/416) | Promote inbound decisions to ADRs | R2 | Improvements & Developer Experience |
| [#546](https://github.com/andresharpe/dotbot/issues/546) | Telemetry: OTel SDK & sinks | R2 | Improvements & Developer Experience |
| [#550](https://github.com/andresharpe/dotbot/issues/550) | Registry: remove, namespace:stack & auto-update | R2 | Improvements & Developer Experience |
| [#97](https://github.com/andresharpe/dotbot/issues/97) | Self-improvement loop | R3 | Improvements & Developer Experience |
| [#99](https://github.com/andresharpe/dotbot/issues/99) | Aether conduit plugin architecture | R3 | Improvements & Developer Experience |
| [#549](https://github.com/andresharpe/dotbot/issues/549) | IKnowledgeProvider: vector DB & ontology | R3 | Improvements & Developer Experience |
| [#76](https://github.com/andresharpe/dotbot/issues/76) | Built-in Shared Memory System | R3 | Improvements & Developer Experience |
| [#505](https://github.com/andresharpe/dotbot/issues/505) | Filter & Sort Decisions per Workflow | R3 | Improvements & Developer Experience |
| [#32](https://github.com/andresharpe/dotbot/issues/32) | Workflow tab UI & task lifecycle viz | ongoing | UI/UX |
| [#551](https://github.com/andresharpe/dotbot/issues/551) | Navigation shell redesign | ongoing | UI/UX |
| [#552](https://github.com/andresharpe/dotbot/issues/552) | Visual design system | ongoing | UI/UX |
| [#553](https://github.com/andresharpe/dotbot/issues/553) | ⌘K command palette | ongoing | UI/UX |
| [#554](https://github.com/andresharpe/dotbot/issues/554) | Accessibility & ADR integration | ongoing | UI/UX |

---

*Last updated: 2026-07-03*
