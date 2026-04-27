# Dotbot UI Architecture & Domain Model Whitepaper v2

| Field | Value |
|-------|-------|
| **Date** | 2026-04-05 |
| **Authors** | André Sharpe, with input from Erol Karabeg |
| **Status** | DRAFT v2 — open questions resolved, ready for final review |

---

## 1. Why This Document Exists

Dotbot has three UI surfaces emerging in parallel — the **Project Dashboard** (Outpost Control Panel), the **Workflow Editor** (PR #113), and the **Mothership Server** — with no unified architecture governing how they relate, navigate between each other, or share a visual identity. Simultaneously, Erol has proposed enriching the domain model with persons, roles, accountability, escalation paths, and transforming workflow configuration from a development exercise into a visual, no-code activity. The open-source project [Paperclip](https://paperclip.ing/) ([GitHub](https://github.com/paperclipai/paperclip)) demonstrates a mature organizational metaphor for AI agent orchestration that validates several of these ideas and suggests additional ones worth adopting.

This whitepaper consolidates the vision into a single reference document. Once reviewed, it becomes the basis for GitHub issues on [Project #2 (v4 Roadmap)](https://github.com/users/andresharpe/projects/2).

**Changes from v1:** All five open questions from section 11 are now resolved with decisions inline. The document is ready for final review.

---

## 2. The Three-Tier Model

### 2.1 Topology

```
                    ┌──────────────────────────────────┐
                    │          MOTHERSHIP               │
                    │    Fleet · Teams · Decisions       │
                    │    Drone Console (real-time)       │
                    │    (Azure / central .NET server)   │
                    └──────────────┬───────────────────┘
                                   │ HTTPS (heartbeat, sync, events)
                  ┌────────────────┼────────────────┐
                  │                │                │
         ┌────────┴───────┐ ┌─────┴──────┐  ┌──────┴──────┐
         │  OUTPOST A     │ │ OUTPOST B  │  │   DRONE     │
         │  (Project UI)  │ │ (Project)  │  │  (headless) │
         │  :8686         │ │ :8687      │  │  telemetry→ │
         └───────┬────────┘ └────────────┘  └─────────────┘
                 │
         ┌───────┴────────┐
         │ WORKFLOW EDITOR │  ← launched from Outpost
         │ (global tool)   │
         │ :9001           │
         └────────────────┘
```

### 2.2 Surface Definitions

**Outpost Control Panel** — The primary daily interface. Per-project, launched via `.bot/go.ps1`. PowerShell HTTP server + vanilla JS frontend. Seven tabs today (Overview, Product, Roadmap, Processes, Decisions, Workflows, Settings), with a Team tab planned. Full CRT retro-futuristic design with configurable theme presets. This is the cockpit where a developer monitors and steers their project's AI processes.

**Mothership Dashboard** — The fleet command center. ASP.NET Core Razor Pages app with vanilla JS. Currently serves Q&A notifications (Overview, By Person, By Project tabs). Will expand to fleet management: instance registry, cross-org decision routing, drone management with full real-time console, team directory, cost/velocity dashboards. Hosted centrally (Azure, on-prem, or self-hosted).

**Workflow Editor** — A global power tool for authoring workflow definitions, recipes, **and MCP tool definitions**. React + React Flow + Vite, served by a PowerShell HTTP server. Visual DAG editor for `workflow.yaml` files with drag-and-drop task creation, type-specific property panels, and an integrated file editor for recipes and tool scripts. Launched from the Outpost's Workflows tab or via `dotbot editor` CLI. Operates on `~/dotbot/workflows/` (global) or project-scoped workflows.

**Drone** — A headless autonomous worker. No local UI — all telemetry streams to the Mothership, which provides a full real-time console view. Reuses the same Runtime and MCP Server as an Outpost but replaces the Dashboard with a lightweight agent supervisor that polls the Mothership work queue.

### 2.3 User Mental Model

> "I open my **project** to work on tasks, check the **mothership** for fleet status and drone activity, and launch the **editor** when I need to modify workflows or tools."

Each surface has a clear purpose. A developer shouldn't need to think about which UI to open — it follows from what they're doing.

---

## 3. Design System: Full CRT Everywhere

### 3.1 Decision

The CRT retro-futuristic design is dotbot's brand identity. **All surfaces get the full CRT treatment** — scanlines, phosphor glow, amber/cyan palette, monospace typography — including the Workflow Editor's React Flow canvas. DAG nodes render as phosphor-colored circuit elements. Edges glow. The canvas background has subtle scanlines.

This is a deliberate aesthetic choice: dotbot is not another generic developer tool. The CRT identity makes it instantly recognizable and reinforces the "autonomous command center" metaphor.

### 3.2 Shared Token Architecture

To unify three different tech stacks under one visual identity, extract a shared CSS foundation:

**`dotbot-tokens.css`** (~120 lines) — The single source of truth for:
- Color palette as RGB components (`--color-primary-rgb`, `--color-bg-deep-rgb`, etc.) for opacity compositing
- Typography (`--font-mono: 'JetBrains Mono', Consolas, monospace`)
- Spacing scale, border radius, bezel variables
- Theme preset definitions (amber, cyan, green, blue, purple, white)

**`dotbot-crt.css`** (~80 lines) — Reusable CRT effects:
- Scanline overlay (CSS pseudo-elements)
- Phosphor glow (`text-shadow`, `box-shadow`)
- Bezel/border treatment
- LED indicator styles
- CRT flicker animation (subtle)

**Consumption pattern:**
| Surface | Tokens | CRT Effects | Tech Stack |
|---------|--------|-------------|------------|
| Outpost Control Panel | ✓ (refactor existing `theme.css` to import) | ✓ (existing `crt.css` → shared) | Vanilla JS |
| Mothership Dashboard | ✓ (replace hardcoded hex in `dashboard.css`) | ✓ (extend existing partial CRT from commit `dfea1c3`) | Razor Pages + vanilla JS |
| Workflow Editor | ✓ (replace slate theme in `globals.css`) | ✓ (apply to canvas, nodes, edges, toolbox, properties panel) | React + React Flow |

### 3.3 Editor CRT Treatment

The Workflow Editor (PR #113) currently uses a modern dark slate theme. To bring it into the CRT family:

- **Canvas background:** Deep black (`--color-bg-deep`) with subtle scanline overlay
- **Task nodes:** Bezel-bordered panels with type-colored phosphor accents (blue→cyan, green→green, purple→magenta mapped to CRT palette)
- **Edges:** Glowing dependency lines using `filter: drop-shadow` with `--color-progress` cyan
- **Toolbox & Properties panels:** Same panel styling as Outpost sidebar (bezel borders, monospace type)
- **Header/toolbar:** Match the Outpost header style (logo, font, LED indicators)
- **MiniMap:** Phosphor-colored node thumbnails on dark background

---

## 4. Navigation Model

### 4.1 Principle

Each surface is an independent app running its own server. Cross-surface navigation opens new browser tabs. No iframes, no micro-frontends, no embedding. Simple and reliable.

### 4.2 Link Map

**Outpost → Mothership:**
- Header: Mothership connectivity icon (next to existing `connection-led`). Click opens Mothership dashboard URL in new tab.
- Settings > Mothership section: "Open Dashboard" button (visible when configured + server healthy).
- Decisions tab: "View in Mothership" link on synced decision cards.
- Team tab (future): "View org-wide directory" link.

**Mothership → Outpost:**
- Fleet Dashboard: Each registered outpost card shows its URL. "Open Control Panel" link when reachable.
- Q&A Dashboard: Decision/question cards show originating project with link back to outpost.

**Outpost → Workflow Editor:**
- Workflows tab: "Visual Editor" button in tab header. Calls `/api/launch-editor` which starts the editor server (if not already running) and returns the URL. Opens in new tab with `?workflow=<name>` context parameter.
- CLI: `dotbot editor` / `dotbot editor --workflow default` / `dotbot editor --project ./myapp`

**Workflow Editor → Outpost:**
- Editor header: "← Back to Control Panel" link. Port discovered from `~/.dotbot/.control/ui-port` or passed as URL parameter.

### 4.3 Context Passing

URLs carry context between surfaces:
- `http://localhost:9001/?workflow=default` — editor opens a specific workflow
- `http://localhost:8686/#decisions/dec-abc123` — outpost deep-links to a decision
- `https://mothership.example.com/fleet/outpost-xyz` — mothership links to a specific instance

---

## 5. Feature Placement Matrix

| Feature | Outpost | Mothership | Editor | Drone |
|---------|---------|------------|--------|-------|
| Task lifecycle (create, analyse, execute) | ✦ primary | view only | — | executes |
| Process monitoring (start, stop, whisper) | ✦ primary | ✦ drone console (real-time) | — | streams telemetry |
| Product docs (PRD, specs, discovery) | ✦ primary | — | — | — |
| Roadmap / pipeline view | ✦ primary | aggregate view | — | — |
| Decision records & approval | ✦ create & approve | ✦ route, approve via channels | — | — |
| Workflow file viewer (read-only) | ✦ primary | — | — | — |
| Workflow visual editing | launches editor → | — | ✦ primary | — |
| MCP tool management | — | — | ✦ primary (metadata + script) | — |
| Theme / UI settings | ✦ primary | own settings | — | — |
| Team management | ✦ primary (per-project) | ✦ aggregate (org-wide) | — | — |
| Q&A notifications | sends questions | ✦ delivers & routes | — | — |
| Fleet overview / instance registry | — | ✦ primary | — | — |
| Drone management / work queue | — | ✦ primary + console | — | agent |
| Cost tracking (per-LLM-call) | per-project rollup | ✦ fleet-wide dashboard | — | reports per-call |
| Extension registries | consumes | ✦ discovery hub | ✦ library browser | consumes |
| Audit / governance | activity.jsonl | ✦ aggregated trails | — | reports |

---

## 6. Domain Model

### 6.1 Current Entity Inventory

Dotbot today knows about these entities:

**Core Orchestration:**
- **Process** — A tracked AI invocation (types: analysis, execution, workflow, planning, commit, task-creation). States: starting → running → completed|stopped|failed.
- **Task** — A unit of work. States: todo → analysing → analysed → in-progress → done (also: needs-input, skipped, split, cancelled).
- **Session** — A continuous working period with start/end tracking.
- **Worktree** — Git worktree for task isolation (branch `task/{id}-{slug}`).

**Workspace Artifacts:**
- **Product docs** — PRD, overview, roadmap, epics, discovery notes (markdown in `workspace/product/`)
- **Decision** — Structured decision records with lifecycle (proposed → accepted → deprecated → superseded)
- **Plan** — Analysis output consumed by execution phase
- **Activity log** — JSONL event stream (`workspace/activity.jsonl`)
- **Standards** — Project coding standards and conventions

**Configuration:**
- **Profile/Stack** — Technology overlay (dotnet, dotnet-blazor, dotnet-ef)
- **Workflow** — Multi-phase pipeline definition (`workflow.yaml`)
- **Settings** — Hierarchical config (defaults + user overrides)
- **Provider** — LLM provider configuration (Claude, Codex, Gemini)

**Recipes (Reusable Components):**
- **Agent** — AI persona with system prompt and tool configuration (implementer, planner, reviewer, tester)
- **Skill** — Reusable technical guidance (write-unit-tests, design-system, etc.)
- **Prompt** — Workflow step instructions (markdown)
- **MCP Tool** — Discoverable tool with metadata + script (26 tools today)

**Infrastructure:**
- **Hook** — Dev lifecycle and verification scripts
- **Event** — Published by event bus, consumed by sinks (Aether, webhooks, mothership)

### 6.2 Proposed Domain Extensions

#### 6.2.1 Person & Team (from Phase 14 + Erol's vision)

The flat `recipients` list in mothership settings becomes a structured team registry:

**Person** — A human team member associated with a project.
```
Person {
  id, name, email
  aliases: { github, azure_devops, jira, slack, discord }
  roles: [Role]
  domains: [string]           // "backend", "infrastructure", "database"
  channels: { primary, fallback[], preferences }
  availability: { status, out_of_office_until, delegate }
  accountability: {           // NEW — from Erol
    expected_response_time    // SLA for questions/decisions
    nudging_strategy          // gentle, moderate, aggressive
    escalation_path           // who to contact if unresponsive
  }
}
```

**Role** — A permission + routing template.
```
Role {
  id, name, description
  permissions: [string]       // approve-decisions, manage-team, etc.
  auto_include_in: [string]   // decision.architecture, questionnaire.*
  approval_authority: boolean // can this role approve outputs?
}
```

Predefined roles: `lead`, `architect`, `developer`, `reviewer`, `stakeholder`, `qa`.

**Team-Level Properties (NEW):**
```
Team {
  members: [Person]
  escalation_defaults: {
    manager_role: "lead"
    escalation_timeout_hours: 24
    fallback_strategy: "next-available-in-role"
  }
  approval_gates: {
    require_human_approval: ["decision.high_impact", "merge.main"]
    auto_approve: ["decision.low_impact"]
    approval_quorum: 1        // how many approvals needed
  }
}
```

#### 6.2.2 Task Enrichments (from Erol's vision)

Tasks gain person-centric metadata:

```
Task (extended) {
  ...existing fields...
  assigned_to: Person.id | null
  accountable: Person.id | null   // RACI: who's accountable
  reviewers: [Person.id]
  expected_completion: datetime
  nudging: {
    enabled: boolean
    strategy: "gentle" | "moderate" | "aggressive"
    last_nudge: datetime
    next_nudge: datetime
  }
  requires_approval: boolean
  approval_status: "pending" | "approved" | "rejected" | null
  approved_by: Person.id | null
}
```

#### 6.2.3 Cost Tracking (per-LLM-call granularity) ✅ DECIDED

**Decision:** Track costs at the per-LLM-call level. Every API call records tokens in/out, model, and calculated cost. These roll up to process and task summaries for display.

**CostRecord** — Recorded per LLM invocation:
```
CostRecord {
  id: string
  timestamp: datetime
  process_id: Process.id
  task_id: Task.id | null
  provider: "claude" | "codex" | "gemini"
  model: string                    // exact model version
  tokens_in: number
  tokens_out: number
  cost_usd: number                 // calculated from provider pricing
  correlation_id: string           // links to audit trail
}
```

**CostPolicy** — Budget enforcement:
```
CostPolicy {
  scope: "project" | "workflow" | "task"
  budget_usd: number
  period: "monthly" | "per-run" | "per-task"
  warning_threshold: 0.8          // warn at 80%
  hard_limit: true                 // stop at 100%
  current_spend: number            // aggregated from CostRecords
}
```

**Implementation:** ProviderCLI captures token counts from API responses and writes CostRecords to `.bot/.control/costs/`. The Outpost dashboard shows per-project rollups. The Mothership aggregates fleet-wide with drill-down to project → task → individual call.

#### 6.2.4 Nudging via Event Bus ✅ DECIDED

**Decision:** Nudging is implemented as scheduled events on the event bus. No dedicated NudgeService — the event bus's composability means any sink (Teams, Slack, email, Aether) can deliver nudges without coupling.

**Implementation:**
- When a task has `nudging.enabled: true`, the Runtime publishes a `nudge.scheduled` event with the next nudge time.
- An event bus timer checks for due nudges and publishes `nudge.due` events.
- Configured sinks deliver the nudge via the appropriate channel.
- Escalation follows the Person's `accountability.escalation_path` — if no response within `expected_response_time`, a `nudge.escalated` event targets the escalation contact.
- Nudge events: `nudge.scheduled`, `nudge.due`, `nudge.delivered`, `nudge.acknowledged`, `nudge.escalated`.

**Dependency:** Requires Phase 4 (Event Bus). Nudging cannot ship before the event bus is in place.

#### 6.2.5 Approval Gates — Both Outpost & Channels ✅ DECIDED

**Decision:** Humans can approve outputs in **both** the Outpost Decisions tab (primary, for active developers) **and** via Mothership notification channels (Teams, Slack, email) for async/mobile approval. The Mothership syncs the approval back to the originating outpost.

**Approval Flow:**
```
1. Task/decision flagged as requires_approval
2. Outpost Decisions tab shows pending approval card
3. Simultaneously, Mothership routes approval request to channels
   based on team member's channel preferences
4. First approval (from either surface) is authoritative
5. Mothership syncs approval back to outpost if received via channel
6. Outpost updates task/decision status
```

**Conflict resolution:** If an approval arrives from both surfaces simultaneously, the first one timestamped wins. Subsequent approvals are recorded as confirmations, not conflicts.

#### 6.2.6 Governance & Audit (inspired by Paperclip)

**Audit Trail Enhancement:**
The existing `activity.jsonl` captures events but lacks governance structure. Extend with:
```
AuditEntry {
  ...existing activity fields...
  correlation_id: string      // thread through entire task lifecycle
  actor: "ai" | "human"
  actor_id: Person.id | Process.id
  action_type: "decision" | "approval" | "override" | "delegation"
  cost_record_id: CostRecord.id | null   // links to cost data
  reversible: boolean
  reverted_by: AuditEntry.id | null
}
```

**Heartbeat Scheduling (inspired by Paperclip):**
Paperclip's agents wake on schedules, not just on-demand. Dotbot's equivalent is the steering heartbeat (`steering-heartbeat` MCP tool) which already allows operator interrupts during autonomous execution. Extend this to support:
- Scheduled process launches (e.g., nightly analysis runs)
- Periodic health checks for long-running workflows
- Mothership-initiated wake-ups for drone assignment
- Nudge delivery (via event bus, as decided above)

#### 6.2.7 Organizational Hierarchy (Paperclip-inspired, scoped to project)

Paperclip models an entire company with reporting structures and delegation chains. Dotbot keeps this **project-scoped** — no company org chart, but delegation within the project team:

**Delegation Flow:**
```
Person.delegation {
  can_delegate_to: [Person.id]
  escalate_to: Person.id          // manager or senior role
  delegation_rules: [
    { trigger: "out_of_office", delegate_to: "next-in-role" },
    { trigger: "response_timeout", escalate_to: "lead" }
  ]
}
```

The Mothership aggregates team visibility across projects for org-wide awareness, but authority stays local.

---

## 7. Visual Configuration Tool

### 7.1 Vision

Erol's core insight: **creating new dotbot configurations should be a configuration exercise, not a development task.** The workflow editor ([PR #113](https://github.com/andresharpe/dotbot/pull/113)) is the first step. The long-term vision is a visual tool that lets users:

1. **Design workflow DAGs** — drag-and-drop tasks, draw dependencies, configure per-task properties
2. **Edit recipe files** — prompts, agent definitions, skill guides, inline in the editor
3. **Manage MCP tools** — visual metadata.yaml editing + code editor for script.ps1 ✅ DECIDED
4. **Browse shared libraries** — when connected to a Mothership, discover and import workflows, skills, agents, and tools from extension registries (Phase 11)
5. **Create new process types** — start-from-jira, idea intake, product proposal — without writing PowerShell
6. **Configure pipeline phases** — visual definition of workflow pipelines with LLM, interview, workflow, and script phases

### 7.2 MCP Tool Management in the Editor ✅ DECIDED

**Decision:** The workflow editor manages the full MCP tool lifecycle — both `metadata.yaml` (visual form editor) and `script.ps1` (code editor panel). This makes the editor the single place for all dotbot configuration, from workflows to recipes to tools.

**metadata.yaml editing:**
- Visual form for tool name, description, JSON Schema input parameters
- Parameter type dropdown, required/optional toggle, description fields
- Live YAML preview alongside the form
- Validation against MCP protocol schema

**script.ps1 editing:**
- Code editor panel with PowerShell syntax highlighting
- Template scaffolding for new tools (generates the `Invoke-ToolName` function boilerplate)
- "Test" button that invokes the tool with sample input and shows output

**Tool browser:**
- Left panel lists all tools in the current workflow/global install
- Click to open metadata or script
- "New Tool" creates the folder, metadata.yaml, and script.ps1 scaffolding
- Naming convention enforcement (folder=kebab-case, YAML name=snake_case, function=PascalCase)

### 7.3 PR #113: Current State

The existing workflow editor prototype includes:
- React + React Flow visual DAG canvas with 6 task types (Prompt, Prompt Template, Script, MCP Tool, Task Generator, Barrier)
- Drag-and-drop task creation from toolbox
- Type-aware properties panel with required field validation
- Bidirectional dependency sync (edges ↔ `depends_on`)
- Integrated recipe file editor (prompts, agents, skills)
- PowerShell REST API for workflow CRUD operations
- Workflow picker for opening existing workflows

### 7.4 Evolution Path

**Phase 1 (PR #113 as-is):** Merge the workflow editor with CRT restyling. It handles workflow YAML editing and recipe file management for the global install.

**Phase 2 (MCP Tool Management):** Add the tool browser panel, metadata.yaml form editor, and script.ps1 code editor. The editor becomes the single configuration surface.

**Phase 3 (Post Phase 6 — Stacks vs Workflows):** Once profiles are split into stacks and workflows, the editor manages both independently. Stacks define technology layers; workflows define process pipelines. The editor gets a mode switch.

**Phase 4 (Post Phase 7 — Workflow Isolated Runs):** The editor gains a "Run" button that creates a workflow run directly from the editor canvas. Live run status overlays on nodes (green=done, amber=running, red=failed).

**Phase 5 (Post Phase 11 — Extension Registries):** The editor connects to registries. A "Library" panel shows available workflows, skills, agents, and tools from configured registries. Import with one click. Publish back to a registry. When connected to a Mothership, the library spans all registered registries.

**Phase 6 (Workflow Pipeline Designer):** The editor supports workflow pipeline definition — the multi-phase onboarding flow (LLM analysis → interview → workflow generation → script execution). Pipeline phases are visual blocks with configurable inputs, outputs, and branching logic.

### 7.5 Standalone vs Mothership-Connected

| Capability | Standalone | Mothership-Connected |
|-----------|-----------|---------------------|
| Edit local workflows | ✓ | ✓ |
| Edit global workflows | ✓ | ✓ |
| Manage MCP tools | ✓ | ✓ |
| Browse shared libraries | Local registries only | All fleet registries |
| Publish to registry | Local git push | Mothership-mediated publish |
| Team recipe sharing | Manual copy | Automatic sync |
| Workflow templates | Bundled defaults | Fleet-curated catalog |

---

## 8. Competitive Landscape: Paperclip

### 8.1 What Paperclip Is

[Paperclip](https://paperclip.ing/) ([GitHub](https://github.com/paperclipai/paperclip)) is an open-source, self-hosted AI company orchestration platform. It treats AI agents as employees in an organizational hierarchy — with job descriptions, reporting structures, budgets, and governance. Users act as the "board of directors" with override authority.

**Stack:** Node.js + embedded PostgreSQL + React UI. MIT licensed. No external accounts required.

### 8.2 Key Concepts

| Paperclip Concept | Description | Dotbot Equivalent |
|-------------------|-------------|-------------------|
| **Organization** | Company hierarchy with roles & reporting | Project team (Phase 14) — scoped to project, not company |
| **Agent as Employee** | Agents have job descriptions, understand their org position | Agents have personas (implementer, planner, reviewer, tester) but no hierarchy |
| **Budget Enforcement** | Per-agent monthly USD limits, hard stops at 100% | Per-LLM-call cost tracking + CostPolicy budgets (decided) |
| **Heartbeat Scheduling** | Agents wake on schedules or triggers | Steering heartbeat exists; event bus scheduling for nudges + process launches |
| **Delegation** | Work flows bidirectionally through org chart | Project-scoped delegation with escalation paths |
| **Ticket Threading** | Persistent conversations with full context | Tasks have activity logs; decisions have discussion threads |
| **Goal Alignment** | Tasks trace to missions | Product docs (PRD, mission, roadmap) — explicit `goal_id` linkage planned |
| **Audit Trails** | Immutable logs of all decisions and tool calls | Enhanced AuditEntry with correlation IDs, actor attribution, cost linkage |
| **Multi-Tenancy** | One deployment, many isolated companies | Mothership supports multiple outpost registrations |
| **BYOA (Bring Your Own Agent)** | Runtime-agnostic (Claude, Codex, etc.) | ProviderCLI already supports Claude, Codex, Gemini |

### 8.3 What to Adopt

1. **Per-call cost tracking** — Every LLM invocation records tokens, model, and cost. Roll up to project/fleet dashboards. CostPolicy budgets with warning thresholds and hard limits.

2. **Governance-grade audit** — Extend activity.jsonl with correlation IDs (Phase 1 plans this), actor attribution, action classification, and cost linkage. Make it queryable via MCP tools.

3. **Scheduled agent wakeups** — Support cron-style process scheduling, not just on-demand launches. Useful for nightly analysis sweeps, periodic health checks, and nudge delivery via event bus.

4. **Goal ↔ Task linkage** — Formally connect tasks to product goals/epics. Currently tasks reference product docs implicitly; make it an explicit `goal_id` field.

### 8.4 Where Dotbot Differentiates

1. **Two-phase execution** — Analysis → Implementation is a core architectural insight that Paperclip lacks. The pre-flight analysis phase catches issues before expensive execution.

2. **Worktree isolation** — Per-task git worktrees with automatic branch management and squash-merge. Paperclip has atomic execution but not git-level isolation.

3. **CRT identity** — Dotbot has a distinctive, recognizable visual brand. Paperclip uses a generic React dashboard.

4. **PowerShell-native** — Runs anywhere PowerShell 7 runs (Windows, macOS, Linux) with zero Node.js runtime dependency (except the workflow editor build step). No database required — file-based state.

5. **MCP tool ecosystem** — 26 auto-discovered tools with metadata-driven registration, now with visual management in the editor. Paperclip uses skills injection via markdown files.

6. **Workflow-as-code** — Dotbot workflows are declarative YAML with visual editing. This is more flexible than Paperclip's hardcoded org-chart model for defining arbitrary process types.

7. **Multi-surface approval** — Approvals work both locally (Outpost Decisions tab) and remotely (Mothership channels). Paperclip's governance is dashboard-only.

---

## 9. Mothership Dashboard Architecture

### 9.1 Decision: Extend Razor Pages

The Mothership dashboard expands the existing ASP.NET Core Razor Pages app (`server/src/Dotbot.Server/`). No separate SPA. The existing Q&A pages (Index, Confirmation, Respond) are joined by new fleet management pages.

### 9.2 Planned Pages

| Page | Purpose | Depends On |
|------|---------|-----------|
| **Q&A Dashboard** (existing) | Question delivery and response | — |
| **Fleet Overview** | Instance cards with status, task counts, health | Phase 8 |
| **Instance Detail** | Deep view of a single outpost: processes, tasks, decisions | Phase 8 |
| **Drone Console** ✅ DECIDED | **Full real-time streamed process output from drones** — like watching a remote Outpost's Processes tab | Phase 10 |
| **Drone Management** | Active drones, work queue, assignment status, capacity | Phase 10 |
| **Decision Hub** | Cross-project decision routing and approval (both surfaces) | Phase 5 + 8 |
| **Team Directory** | Org-wide team members aggregated from all outposts | Phase 14 |
| **Cost Dashboard** | Fleet-wide LLM spend with per-call drill-down, budget alerts | Phase 8 |
| **Velocity Metrics** | Tasks completed, cycle time, quality trends | Phase 8 |
| **Extension Library** | Registry browser for shared workflows, skills, agents, tools | Phase 11 |

### 9.3 Drone Console Design

**Decision:** The Mothership provides a full real-time drone console — not just summary cards. This is essential for debugging, oversight, and trust.

**Implementation:**
- Drones forward their `.activity.jsonl` events to the Mothership via the event bus (event forwarding sink)
- The Mothership stores recent events per-drone and serves them via WebSocket or SSE
- The console page renders streamed output identically to the Outpost's Processes tab
- Operators can send commands to drones via the Mothership (stop, whisper, reassign)
- Multiple drones viewable in a grid layout or single-drone focused view

### 9.4 CRT Styling

The Mothership dashboard already has partial CRT alignment from commit `dfea1c3` (grid patterns, scanlines, amber palette). Import `dotbot-tokens.css` and `dotbot-crt.css` to complete the treatment. All new fleet pages use the shared design system from day one.

---

## 10. Phased Rollout

### Phase A: Design Token Extraction (foundation)
**Goal:** Establish the shared visual foundation.
1. Extract `dotbot-tokens.css` from Outpost's `theme.css` — CSS custom properties only
2. Extract `dotbot-crt.css` from Outpost's `crt.css` — reusable CRT effects
3. Refactor Outpost CSS to import shared files
4. Refactor Mothership `dashboard.css` to use shared tokens + CRT
5. Update `design-system` skill documentation

**Key files:** `core/ui/static/css/theme.css`, `core/ui/static/css/crt.css`, `server/src/Dotbot.Server/wwwroot/css/dashboard.css`

### Phase B: Navigation Scaffolding
**Goal:** Connect the surfaces.
1. Add Mothership connectivity icon to Outpost header (opens Mothership in new tab)
2. Add "Open Dashboard" button in Settings > Mothership section
3. Add outpost URL to Mothership registration payload
4. Add "Open Control Panel" links in Mothership fleet dashboard
5. Implement `/api/launch-editor` endpoint on Outpost server

**Key files:** `core/ui/static/index.html`, `core/ui/static/modules/controls.js`, `core/ui/modules/SettingsAPI.psm1`

### Phase C: Workflow Editor CRT + Tool Management (builds on PR #113)
**Goal:** Bring the editor into the CRT family and expand scope to MCP tools.
1. Replace slate theme with `dotbot-tokens.css` + `dotbot-crt.css`
2. Style React Flow nodes as CRT circuit elements (phosphor type badges, glowing edges, bezel panels)
3. Apply scanline overlay to canvas background
4. Match editor header/toolbar to Outpost header style
5. Add MCP tool browser panel, metadata.yaml form editor, script.ps1 code editor
6. Add "Visual Editor" button to Outpost Workflows tab
7. Add "← Back to Control Panel" link in editor header
8. Wire file watcher so Outpost detects editor saves

**Key files:** `workflow-editor/src/client/styles/globals.css`, `workflow-editor/src/client/components/TaskNode.tsx`, `workflow-editor/src/client/components/Canvas.tsx`

### Phase D: Domain Model Enrichment (aligns with v4 Phases 8 + 14)
**Goal:** Implement team, accountability, cost tracking, and governance entities.
1. Create Team tab in Outpost dashboard (between Workflows and Settings)
2. Build `TeamAPI.psm1` for Outpost server
3. Create team MCP tools (team-add, team-list, team-update, team-remove, team-set-availability, role-list, role-create)
4. Extend task schema with assigned_to, accountable, reviewers, expected_completion, approval fields
5. Implement per-LLM-call cost tracking in ProviderCLI → CostRecord storage
6. Add CostPolicy budget enforcement with warning/hard-limit thresholds
7. Implement nudge events on event bus (nudge.scheduled → nudge.due → nudge.delivered → nudge.escalated)
8. Add delegation/escalation logic to Q&A routing
9. Implement dual-surface approval flow (Outpost Decisions tab + Mothership channels, first-timestamp-wins)
10. Extend activity.jsonl with governance audit fields (correlation_id, actor, cost_record_id)
11. Add team sync endpoint to Mothership
12. Add Team Directory page to Mothership dashboard

### Phase E: Drone Console + Fleet Dashboard (aligns with v4 Phases 8 + 10)
**Goal:** Full fleet visibility with real-time drone monitoring.
1. Build fleet overview page on Mothership (instance cards, status, task counts)
2. Add heartbeat API + client sender
3. Build drone console page with real-time event streaming (WebSocket/SSE)
4. Add drone command interface (stop, whisper, reassign)
5. Build cost dashboard with fleet-wide per-call drill-down
6. Cross-org decision routing page with dual-surface approval

### Phase F: Visual Config Tool Evolution
**Goal:** Expand the editor to its full vision.
1. Add "Run Workflow" button that creates a live workflow run from the canvas
2. Add registry library panel for browsing/importing shared components (workflows, skills, agents, tools)
3. Add workflow pipeline designer mode
4. Support stack configuration editing alongside workflows

---

## 11. Decisions Log

All open questions from v1 are now resolved:

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Cost tracking granularity | **Per-LLM-call** | Most granular. Roll up to process/task/project for display. ProviderCLI captures token counts from API responses. |
| 2 | Nudging implementation | **Event bus** | Composable — any sink can deliver nudges. Depends on Phase 4 (Event Bus). No dedicated NudgeService needed. |
| 3 | Workflow editor scope | **Full tool management** (metadata + script) | The editor becomes the single configuration surface. metadata.yaml gets a visual form; script.ps1 gets a code editor. |
| 4 | Approval gates UX | **Both** Outpost + Mothership channels | Approve locally in Decisions tab or async via Teams/Slack/email. First timestamp wins. Mothership syncs back. |
| 5 | Drone console | **Full real-time console** | Streamed process output via event forwarding. Essential for debugging and trust. Grid or focused view. |

---

## 12. Summary

Dotbot's three UI surfaces serve distinct purposes and remain independent apps linked by contextual new-tab navigation. The CRT design system unifies them visually through shared CSS tokens and effects — applied fully everywhere, including the React Flow editor canvas. The domain model is enriched in four directions: team/accountability (persons, roles, escalation, nudging via event bus), cost tracking (per-LLM-call with budget policies), governance (audit trails, dual-surface approval gates), and workflow configurability (visual editor evolution to a no-code platform managing workflows, recipes, and MCP tools). [Paperclip](https://paperclip.ing/) validates the organizational and governance concepts while dotbot's project-centric, file-based, two-phase architecture remains differentiated.

**Next steps:** Final review of this v2 → create GitHub issues on [Project #2](https://github.com/users/andresharpe/projects/2) → prioritize against existing v4 phases.
