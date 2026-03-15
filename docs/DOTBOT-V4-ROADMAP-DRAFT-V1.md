# Dotbot v3 Major Refactor Plan

## Context

Dotbot v3 has grown organically and now suffers from architectural tensions: profiles conflate stacks and workflows, task/process management is brittle and monolithic, workflows are locked at init time, there's no decision tracking, logging is ad-hoc, the event/feedback system is tightly coupled, and there's no support for remote headless AI agents. This plan addresses all of these while establishing a clean component architecture with Outposts (local dev workspaces), Drones (headless autonomous workers), and a Mothership (central fleet management and work dispatch).

---

## Component Architecture

### Overview

Dotbot is composed of nine distinct architectural components. Each has a clear identity and responsibility boundary.

#### Fleet Topology

```mermaid
graph TD
    subgraph MOTHERSHIP["MOTHERSHIP (.NET server)"]
        WQ[Work Queue]
        FR[Fleet Registry]
        DR[Decision Routing]
        FD[Fleet Dashboard]
    end

    WQ -- dispatch work --> D1
    FR -- register/heartbeat --> D1
    FR -- register/heartbeat --> OA
    FR -- register/heartbeat --> OB
    DR -- sync decisions --> OA
    DR -- sync decisions --> OB

    D1["DRONE-1\n(headless worker)"]
    OA["OUTPOST-A\n(local devs)"]
    OB["OUTPOST-B\n(local devs)"]
```

#### Outpost Internals

```mermaid
graph TD
    subgraph OUTPOST["OUTPOST — Per-project .bot/"]
        DASH["DASHBOARD\nLocal web UI (systems/ui/)"]
        DASH -- events --> EB
        subgraph EB["EVENT BUS"]
            direction LR
        end
        EB --> AETHER["Aether\n(Hue lights)"]
        EB --> WEBHOOKS["Webhooks\n(POST)"]
        EB --> MS_SINK["Mothership\n(notify)"]
        RT["RUNTIME\nProcess launcher, task loop, worktrees"]
        MCP["MCP SERVER\nTool discovery + execution"]
        RT --> MCP
    end

    style OUTPOST fill:#1a1a2e,stroke:#e94560,color:#eee
    style EB fill:#0f3460,stroke:#e94560,color:#eee
```

#### Drone Internals

```mermaid
graph TD
    subgraph DRONE["DRONE — Headless autonomous worker"]
        DA["DRONE AGENT\nPolls Mothership, manages lifecycle"]
        DA --> RT2["RUNTIME\n(same as Outpost, reused)"]
        RT2 --> MCP2["MCP SERVER\n(same tools, reused)"]
        EB2["EVENT BUS\nEvents forwarded to Mothership"]
        NODB["No Dashboard — headless"]
    end

    style DRONE fill:#1a1a2e,stroke:#16c79a,color:#eee
    style NODB fill:#333,stroke:#666,color:#999
```

### 1. Outpost (`.bot/`)

The **Outpost** is the per-project workspace directory. It's where dotbot lives in each repository — the local installation of all dotbot capabilities.

**Contains:**
- `systems/` — runtime, MCP server, UI server
- `prompts/` — agents, skills, workflows
- `workspace/` — tasks, plans, decisions, sessions, workflow runs, product docs
- `defaults/` — settings
- `.control/` — runtime state, logs, processes (gitignored)
- `hooks/` — verification, dev lifecycle, automation scripts

**Key property:** Each outpost is self-contained. You can have multiple repos each with their own outpost, all managed independently or connected to a mothership.

**Architectural name for docs:** "Outpost" — evokes a self-sufficient station that can operate autonomously but reports to a mothership.

### 2. Runtime

The process orchestration engine that drives all work.

**Current:** `launch-process.ps1` (2,924 lines) — monolithic
**Target:** Decomposed into ProcessRegistry + TaskLoop + per-type handlers

**Responsibilities:**
- Process lifecycle (create, track, stop, clean up)
- Task loop (get-next, invoke LLM, check completion, retry)
- Worktree isolation (branch per task, squash-merge on completion)
- Provider CLI abstraction (Claude, Codex, Gemini)

### 3. MCP Server

The tool layer — auto-discovers and executes tools for the LLM.

**Current:** `dotbot-mcp.ps1` (261 lines) + 26 tools in `tools/*/`
**Target:** Same architecture, expanded with workflow/decision/event tools

**Key modules:**
- `TaskIndexCache.psm1` — read-only task query cache
- `TaskStore.psm1` — (NEW) atomic task state transitions
- `SessionTracking.psm1` — session state
- `NotificationClient.psm1` — mothership communication

### 4. Dashboard

The local web UI for monitoring and control.

**Current:** `server.ps1` (1,533 lines) + 9 modules + vanilla JS frontend
**Target:** Same architecture, extended with new tabs (Decisions, Workflows, Fleet)

### 5. Mothership

The centralized .NET server for fleet-wide management and work dispatch.

**Current:** `server/` — ASP.NET Core app with Teams/Email/Jira question delivery
**Target:** Extended to full fleet management: instance registry, heartbeat monitoring, cross-org decision routing, fleet dashboard, **work queue for Drone dispatch**

### 6. Event Bus

**NEW.** Internal pub/sub system for dotbot events. Currently, Aether is hardwired into the UI's polling loop. The mothership notifications are triggered directly from MCP tools. These need to be decoupled.

**Event types:**
- `task.started`, `task.completed`, `task.failed`
- `process.started`, `process.stopped`
- `decision.created`, `decision.accepted`
- `workflow.started`, `workflow.phase_completed`, `workflow.completed`
- `drone.registered`, `drone.assigned`, `drone.completed`, `drone.failed`, `drone.idle`
- `activity.write`, `activity.edit`, `activity.bash`
- `error`, `rate_limit`

**Event sinks (plugins):**
- **Aether** — Hue lights (existing, refactored to subscribe to events)
- **Webhooks** — POST to arbitrary URLs (NEW)
- **Mothership** — sync events to central server (existing NotificationClient, refactored)
- **Future:** WLED, Nanoleaf, sound, Slack, desktop notifications

### 7. Stacks & Workflows

**Stacks** = composable technology overlays (dotnet, dotnet-blazor, dotnet-ef).
**Workflows** = launchable multi-phase pipelines (kickstart-via-jira, kickstart-via-pr).

These are the two "extension" mechanisms, cleanly separated.

### 8. Drones

**NEW.** Headless autonomous AI coding agents running in data centers, managed by the Mothership.

A **Drone** is a dotbot instance without a local developer. It runs the same Runtime and MCP Server as an Outpost but has no Dashboard. Instead, it has a **Drone Agent** — a lightweight supervisor that:

1. **Registers** with the Mothership on startup (capabilities, available providers/models, capacity)
2. **Polls** the Mothership work queue for assignments
3. **Clones** target repos and creates ephemeral Outposts
4. **Executes** work using any configured provider (Claude Code, Codex, Gemini)
5. **Reports** progress via heartbeat and event forwarding
6. **Returns** results (commits, PRs, artifacts) and cleans up

**Drone vs Outpost:**

| Aspect | Outpost | Drone |
|--------|---------|-------|
| Operator | Local developer | None (autonomous) |
| Dashboard | Yes (web UI) | No (headless) |
| Work source | Developer-initiated | Mothership work queue |
| Lifecycle | Persistent (lives with repo) | Ephemeral (per-assignment) |
| Providers | Single (developer's choice) | Multiple (configured per-drone) |
| Steering | Developer whispers | Mothership commands |

**Drone lifecycle:**

```mermaid
stateDiagram-v2
    [*] --> STARTUP: Launch drone-agent.ps1
    STARTUP --> IDLE: Register with Mothership
    IDLE --> ASSIGNED: Work queue returns assignment
    IDLE --> IDLE: No work — heartbeat + sleep
    ASSIGNED --> WORKING: Clone repo, create Outpost, install stacks
    WORKING --> REPORTING: Tasks complete
    WORKING --> REPORTING: Tasks failed
    REPORTING --> CLEANUP: Push commits/PRs, send completion event
    CLEANUP --> IDLE: Remove workspace, return to polling
    IDLE --> [*]: Shutdown signal — deregister
```

**Key architectural property:** Drones reuse the same Runtime, MCP Server, and ProviderCLI as Outposts. The only new code is the Drone Agent supervisor and the Mothership work dispatch system. The existing provider abstraction (`ProviderCLI.psm1` + declarative `providers/*.json`) means a Drone can run Claude, Codex, or Gemini without code changes.

**Existing foundation:**
- `profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1` — multi-provider abstraction
- `profiles/default/defaults/providers/{claude,codex,gemini}.json` — declarative provider configs
- `profiles/default/systems/runtime/launch-process.ps1` — process orchestration (already headless-capable)
- `profiles/default/systems/runtime/modules/WorktreeManager.psm1` — git worktree isolation (enables parallel tasks)

---

## Implementation Phases

### Phase 1: Structured Logging Module (Foundation)

> **Effort:** S-M | **Risk:** Low | **Dependencies:** None
>
> Creates `DotBotLog.psm1` with structured JSONL logging, replaces all silent catch blocks, adds log rotation. Every subsequent phase benefits from proper logging.
>
> **[Full specification →](DOTBOT-V4-phase-01-structured-logging.md)**

---

### Phase 2: TaskStore Abstraction

> **Effort:** S | **Risk:** Low | **Dependencies:** None
>
> Creates `TaskStore.psm1` with atomic state transitions (`Move-TaskState`), unified lookup, and record CRUD. `TaskIndexCache.psm1` becomes read-only query layer.
>
> **[Full specification →](DOTBOT-V4-phase-02-taskstore-abstraction.md)**

---

### Phase 3: Break Up launch-process.ps1

> **Effort:** L | **Risk:** Medium | **Dependencies:** Phase 1, 2
>
> Decomposes the 2,924-line monolith into ~200-line dispatcher + `ProcessRegistry.psm1` + `TaskLoop.psm1` + per-type handler scripts (`Invoke-AnalysisProcess.ps1`, etc.).
>
> **[Full specification →](DOTBOT-V4-phase-03-launch-process-breakup.md)**

---

### Phase 4: Event Bus

> **Effort:** M | **Risk:** Medium | **Dependencies:** Phase 1
>
> Lightweight in-process pub/sub (`EventBus.psm1`) with plugin sinks (Aether, Webhooks, Mothership). Decouples event producers from consumers.
>
> **[Full specification →](DOTBOT-V4-phase-04-event-bus.md)**

---

### Phase 5: Rich Decision Records

> **Effort:** S-M | **Risk:** Low | **Dependencies:** Phase 4 (for events)
>
> Structured decision JSON in `workspace/decisions/`, 5 MCP tools (`decision-create/list/get/update/link`), new Dashboard tab, integration with analysis/execution prompts.
>
> **[Full specification →](DOTBOT-V4-phase-05-decision-records.md)**

---

### Phase 6: Restructure Profiles — Separate Stacks from Workflows

> **Effort:** M | **Risk:** Medium | **Dependencies:** None
>
> Splits `profiles/` into stacks-only + new top-level `workflows/` directory. Introduces `workflow.yaml` definitions. Adds `dotbot run` and `dotbot workflows` CLI commands.
>
> **[Full specification →](DOTBOT-V4-phase-06-profiles-stacks-workflows.md)**

---

### Phase 7: Workflows as Isolated Runs

> **Effort:** L | **Risk:** High | **Dependencies:** Phase 3, 6
>
> `dotbot run` creates workflow run records, generates tasks per phase, isolates task queues per run. Adds `WorkflowRunner.psm1` and workflow MCP tools.
>
> **[Full specification →](DOTBOT-V4-phase-07-workflow-isolated-runs.md)**

---

### Phase 8: Mothership Fleet Management

> **Effort:** L | **Risk:** Medium | **Dependencies:** Phase 4, 5
>
> Extends the .NET Mothership to full fleet management: instance registry, heartbeats, work queue for Drone dispatch, fleet dashboard, decision sync, event forwarding. Renames `NotificationClient` → `MothershipClient`.
>
> **[Full specification →](DOTBOT-V4-phase-08-mothership-fleet.md)**

---

### Phase 9: Additional Improvements

> **Effort:** S each | **Risk:** Low | **Dependencies:** Phases 1-8
>
> Four polish items: (9a) Health check system (`doctor.ps1`), (9b) Process telemetry, (9c) Idempotent init, (9d) Configuration validation.
>
> **[Full specification →](DOTBOT-V4-phase-09-additional-improvements.md)**

---

### Phase 10: Drone Agent

> **Effort:** L | **Risk:** High | **Dependencies:** Phase 7, 8
>
> Headless autonomous worker that polls the Mothership for work, clones repos, executes tasks, and reports results. Includes `drone-agent.ps1`, `DroneAgent.psm1`, Docker support, and Mothership command steering.
>
> **[Full specification →](DOTBOT-V4-phase-10-drone-agent.md)**

---

### Phase 11: Enterprise Extension Registries

> **Effort:** M | **Risk:** Medium | **Dependencies:** Phase 6, 8 (for Mothership discovery)
>
> Git-based extension registries with namespace prefixes (`myorg:workflow-name`). CLI commands for registry management, `RegistryManager.psm1`, Mothership discovery, Drone integration.
>
> **[Full specification →](DOTBOT-V4-phase-11-enterprise-registries.md)**

---

### Phase 12: Self-Improvement Loop

> **Effort:** M | **Risk:** Medium | **Dependencies:** Phase 1, 3, 4
>
> Automated analysis of activity logs and task outcomes to generate evidence-based improvement suggestions for prompts, skills, workflows. Includes `93-self-improvement.md` workflow, MCP tools, and Dashboard tab.
>
> **[Full specification →](DOTBOT-V4-phase-12-self-improvement.md)**

---

### Phase 13: Multi-Channel Q&A with Attachments & Questionnaires

> **Effort:** L | **Risk:** Medium | **Dependencies:** Phase 8
>
> Adds Slack, Discord, WhatsApp, and Web delivery channels. Introduces file attachments, review links, and batched questionnaires with conditional questions and completion policies.
>
> **[Full specification →](DOTBOT-V4-phase-13-multi-channel-qa.md)**

---

### Phase 14: Project Team & Roles

> **Effort:** M | **Risk:** Medium | **Dependencies:** Phase 5, 13
>
> Structured team registry with roles, domains, channel preferences, and availability/delegation. Drives Q&A routing, decision stakeholders, and review requests. Syncs to Mothership for fleet-wide visibility.
>
> **[Full specification →](DOTBOT-V4-phase-14-project-team-roles.md)**

---

## Implementation Order

| # | Phase | Effort | Risk | Dependencies |
|---|-------|--------|------|--------------|
| 1 | Structured Logging | S-M | Low | None |
| 2 | TaskStore Abstraction | S | Low | None |
| 3 | Break up launch-process.ps1 | L | Medium | 1, 2 |
| 4 | Event Bus | M | Medium | 1 |
| 5 | Rich Decision Records | S-M | Low | 4 (for events) |
| 6 | Restructure Profiles | M | Medium | None |
| 7 | Workflows as Isolated Runs | L | High | 3, 6 |
| 8 | Mothership Fleet Management | L | Medium | 4, 5 |
| 9 | Additional improvements | S each | Low | 1-8 |
| 10 | Drone Agent | L | High | 7, 8 |
| 11 | Enterprise Extension Registries | M | Medium | 6, 8 (for Mothership discovery) |
| 12 | Self-Improvement Loop | M | Medium | 1, 3, 4 |
| 13 | Multi-Channel Q&A | L | Medium | 8 |
| 14 | Project Team & Roles | M | Medium | 5, 13 |

**Parallel tracks:**

```mermaid
graph LR
    subgraph TrackA["Track A: Runtime / Task / Workflow"]
        P1["Phase 1\nLogging"] --> P2["Phase 2\nTaskStore"]
        P2 --> P3["Phase 3\nBreak up\nlaunch-process"]
        P3 --> P7["Phase 7\nWorkflow Runs"]
    end

    subgraph TrackB["Track B: Events / Decisions / Fleet / Drones"]
        P4["Phase 4\nEvent Bus"] --> P5["Phase 5\nDecisions"]
        P5 --> P8["Phase 8\nMothership\nFleet Mgmt"]
        P8 --> P10["Phase 10\nDrone Agent"]
    end

    subgraph TrackC["Track C: Profiles + Enterprise"]
        P6["Phase 6\nStacks vs\nWorkflows"]
        P6 --> P11["Phase 11\nEnterprise\nRegistries"]
    end

    subgraph TrackD["Track D: Polish + Self-Improvement"]
        P9["Phase 9\nAdditional\nImprovements"]
        P12["Phase 12\nSelf-Improvement\nLoop"]
    end

    subgraph TrackE["Track E: Communication + Team"]
        P13["Phase 13\nMulti-Channel\nQ&A"]
        P13 --> P14["Phase 14\nProject Team\n& Roles"]
    end

    P1 --> P4
    P6 --> P7
    P7 --> P10
    P8 --> P11
    P3 --> P9
    P8 --> P9
    P11 --> P10
    P1 --> P12
    P3 --> P12
    P4 --> P12
    P8 --> P13
    P5 --> P14
```

**Key dependencies:**
- **Phase 10 (Drones)** depends on Phase 7 (workflow runs), Phase 8 (Mothership fleet), and Phase 11 (registries — Drones need to resolve `myorg:workflow` references)
- **Phase 11 (Enterprise Registries)** depends on Phase 6 (stacks/workflows separation must exist first) and Phase 8 (for optional Mothership discovery)
- **Phase 12 (Self-Improvement)** depends on Phase 1 (structured logs for analysis), Phase 3 (runtime integration for task completion trigger), and Phase 4 (event bus for improvement events)
- **Phase 13 (Multi-Channel Q&A)** depends on Phase 8 (Mothership fleet management must exist for delivery infrastructure)
- **Phase 14 (Project Team & Roles)** depends on Phase 5 (decisions — team drives stakeholder resolution) and Phase 13 (Q&A — team drives recipient routing)

---

## User Feedback — Priority Bug Fixes & Feature Requests

> Sourced from structured feedback sessions with 7 teams (34 bugs, 54 feature requests). Items mapped to the roadmap phase where they should be addressed.

| Roadmap Phase | Items |
|---|---|
| **Phase 1 (Logging)** | Silent failure elimination (8 bugs, 4+ teams — tasks disappear, false "no remaining", buried questions, silent push failures). Failed processes must stay visible. Rate limit recovery visibility. |
| **Phase 2 (TaskStore)** | Task creation idempotency (duplicates on restart). Atomic state transitions (checkbox marked complete while tasks in progress). Dropped tasks (created but never queued). |
| **Phase 3 (Runtime breakup)** | Worktree merge safety — never delete worktree until merge confirmed. Configurable branch prefix (hardcoded `task/` rejected by some repos). Process lifecycle hardening — orphan cleanup too aggressive, failed processes disappear too quickly. |
| **Phase 4 (Event Bus)** | CI/CD pipeline integration triggers. Webhook-based failure alerts to external systems. |
| **Phase 7 (Workflows)** | Configurable human revision gates (pause-and-review at key stages). Optional workflow steps (not every project needs every step). Functional-first spec ordering (functional requirements before technical design). Research phase before task creation. |
| **Phase 8 (Mothership)** | Server-hosted instances (central deployment, multi-user access). Shared configuration space (cross-project keys, roles, environments). Upfront repository declaration (explicit repo selection honored throughout). |
| **Phase 9 (Polish)** | Process status clarity (running/stuck/crashed indicator). Whisper input fix (unreliable focus/rendering). Responsive UI layout (content clipping on resize). Kickstart re-invocable. Kanban board with drag-and-drop. File attachments on tasks. Context window management (visible token counter, auto-split). |
| **Phase 12 (Self-Improvement)** | Ask the right clarifying question (single critical blocker, not question cascades). Read all inputs before asking questions. Self-improvement logging (transparency trail). |
| **Phase 13 (Multi-Channel)** | Notification dispatch confirmation (what was sent, to whom, when). Route questions to predefined contacts by subject area. |
| **Phase 14 (Team)** | Collaborative sessions (multiple SMEs contributing simultaneously). Well-defined team roles with consistency controls. Controlled external publishing (human review gate before Jira/Confluence creation). |

**Key patterns from feedback:**
1. "Silent" is the most dangerous word — every external interaction needs explicit success/fail handling with UI notification
2. The two-phase model works but gates are missing — users want checkpoints between phases
3. Input handling is the weakest link — attachments, images, Confluence files, uploaded documents
4. Teams want collaboration, not just monitoring
5. Scope discipline is critical — explicit boundaries declared upfront and enforced throughout

---

## Strategic Ideas — Phased Incorporation

> Ideas from architectural analysis that extend existing roadmap phases.

| Roadmap Phase | Ideas |
|---|---|
| **Phase 3 (Runtime)** | Parallel task execution — infrastructure ready via worktrees, add rate-limit-aware scheduling with configurable concurrency. 3-5x throughput on backlogs. |
| **Phase 4 (Event Bus)** | Webhook system for task lifecycle events — configurable POST to arbitrary URLs (Datadog, PagerDuty, custom dashboards). |
| **Phase 7 (Workflows)** | Agent pipeline composition — custom agent chains beyond fixed planner→tester→implementer→reviewer (e.g., researcher→architect→implementer→security-reviewer). Adaptive workflow selection based on task attributes and historical success rates. |
| **Phase 8 (Mothership)** | Multi-project orchestration — manage multiple repos from single dashboard with cross-repo task dependencies. Budget controls — daily/weekly/monthly AI spend caps with alerts. Approval workflows — configurable gates per task category. Audit log — immutable action log for SOC 2/ISO 27001. |
| **Phase 9 (Polish)** | PR auto-creation — after squash-merge, optionally create PR for human review instead of direct merge. Smart defaults from codebase — auto-detect language/framework/test runner during `dotbot init`. Natural language task creation — "Add pagination to users endpoint" → auto-generated task with metadata. |
| **Phase 10 (Drones)** | Self-healing pipelines — auto-create fix task on verification failure, configurable retry depth. Dependency-aware scheduling — respect task dependency chains, auto-queue when dependencies met. Multi-repo coordination — API contract → server → client → integration test across repos. Confidence scoring — AI rates implementation confidence (0-100), low-confidence flagged for review. |
| **Phase 11 (Registries)** | Community profile registry (`dotbot profile install react-nextjs`). Skill marketplace (`dotbot skill install write-playwright-tests`). Profile composition — layer multiple overlays (default + python + fastapi + aws-lambda). Custom workflow templates. Profile testing framework. Org-private registry. |
| **Phase 12 (Self-Improvement)** | Codebase pattern memory — extract patterns from successful completions, feed into future analysis. Failure analysis engine — classify failures, inject preventive guidance. Task estimation from history — track actual effort per category for sprint planning. Code review learning — weight reviews toward issues that matter to the team. Smart task splitting — use historical data to recommend optimal granularity. |
| **Phase 14 (Team)** | Multi-user dashboard — WebSocket-based real-time state sync with presence indicators. Task ownership — assign to specific team members, route domain questions. Shared whisper log — all steering interactions visible with timestamps and attribution. Conflict resolution UI — visual diff for parallel task merge conflicts. |

---

## Open GitHub Issues — Mapped to Phases

> 17 open issues as of 2026-03-15. Each mapped to a roadmap phase or flagged as standalone.

### Bugs (fix independently, before or alongside Phase 1)

- **#18** Fallback models not working — ProviderCLI doesn't switch from Opus when alternative model selected. Fix in `ProviderCLI.psm1`.
- **#20** Mac `-WindowStyle` error — `Start-Process -WindowStyle` parameter unsupported on macOS PowerShell. Fix in `launch-process.ps1` with platform check.

### Phase 1 (Logging)

- **#25** Script audit — full quality review of all `.ps1`/`.psm1` (naming, error handling, UTF-8, dead code). Do alongside Phase 1 logging standardization.
- **#27** Centralised error logging — aggregate errors across processes. Core deliverable of Phase 1.

### Phase 7 (Workflows)

- **#32** Workflow tab UI — phase pipeline visualization, task lifecycle tracking with filtering/sorting. Dashboard work for Phase 7.
- **#39** Jira-initiated kickstart — Jira trigger → auto-create repo → dotbot init → auto-kickstart. Research item; relates to workflow extensibility.

### Phase 8 (Mothership)

- **#24** Instance GUID — stable unique identifier per dotbot instance for cross-system tracking. Prerequisite for #28.
- **#28** Mothership dashboard — instance registry, heartbeats, activity streaming, error log aggregation. Core deliverable of Phase 8.
- **#36** Rename Notifications → Mothership — settings key rename (`notifications` → `mothership`), UI theming fixes, health check indicator. Phase 8 prerequisite.

### Phase 9 (Polish)

- **#31** Product tab subfolder tree — folder hierarchy with expand/collapse, inline markdown rendering. Dashboard polish.
- **#35** Clean up deprecated features and dead code — `standards_as_warp_rules`, unused settings, inactive code paths. Standalone tech debt.

### Phase 13 (Multi-Channel Q&A)

- **#26** Spec Jira/Confluence publishing — define artifacts, formats, page hierarchy, update vs append behavior. Specification work.
- **#29** Expand QuestionService — artifact approvals, role-based routing, new question types (approval, document review, free-text, priority ranking), attachment support. Core deliverable of Phase 13 + Phase 14.
- **#30** Jira as approval channel — post questions as Jira issue comments, detect approvals via reply or transition. Phase 13 delivery channel.
- **#37** E2E test Q&A with attachments — Teams/Email/Jira round-trip tests with markdown, PDF, and image attachments. Phase 13 testing.
- **#38** Research OpenClaw channels — evaluate WhatsApp, Telegram, Slack, Discord for human orchestration use case. Phase 13 research.

### Standalone

- **#40** Professionalise repo DevOps — branch protection rules, CI hardening, issue/PR templates, CODEOWNERS, release tagging. Independent repo governance.

---

## Ideas Parked for Future Consideration

The following ideas don't map to current roadmap phases but are worth preserving. Each would require its own dedicated phase or represents speculative work:

- **Project knowledge graph** — Semantic graph of entities, relationships, API surfaces, test coverage. High value for large codebases (100k+ LOC) but requires significant R&D into graph storage and query.
- **Warm context pools** — Reuse analysis context across task boundaries for 30-50% AI cost reduction. Depends on provider memory/caching APIs that don't yet exist reliably.
- **Agent delegation / sub-agents** — An executing agent spawns specialist sub-agents mid-task. Requires careful concurrency control and cost guardrails.
- **Cross-task awareness** — Orchestrator detects file conflicts across concurrent tasks and sequences work. Useful at scale but adds complexity to the worktree model.
- **IDE extensions** — VS Code / JetBrains plugins showing task status, inline question answering, one-click task creation. Significant standalone effort with its own release cycle.
- **SSO integration (SAML/OIDC)** — Enterprise table-stakes but only relevant when the Dashboard has authentication, which it currently doesn't.
- **Air-gapped mode** — Local model endpoints, no telemetry, self-contained profiles. Important for government/defense/finance but orthogonal to the current architecture work.
- **Policy engine** — Rule-based guardrails ("never modify `*.secrets.*`", "require two approvals for production"). Powerful but needs Decision Records (Phase 5) and Team (Phase 14) foundations first.
- **Observability suite** — AI cost dashboard, velocity metrics, quality tracking, token efficiency analysis, process timeline (Gantt), exportable PDF/HTML reports. These form a coherent group that could become Phase 15.
- **Advanced kickstart variants** — Codebase migration, design doc → tasks, repository onboarding for new developers, competitive analysis, multi-repo initiative planning. Natural extensions of existing kickstart workflows; could become Phase 16.
- **DX improvements** — Interactive kickstart wizard, task templates, hot-reload profiles, task preview/dry-run, conversational steering (multi-turn whisper). Quality-of-life items best addressed incrementally rather than as a single phase.
- **External integrations** — Figma MCP, Serena MCP (symbol extraction), SonarQube quality gates, read-only database sources, Jira overlap detection, Azure DevOps branch rule discovery, Linear/Shortcut/Asana adapters, GitHub Issues sync. Each is self-contained; prioritize based on user demand.
- **Content quality improvements** — Source references with inline links, avoid unexplained acronyms, use real-world data instead of placeholders, MFA stubs for external auth, pre-analyse project dependencies, tech decision research workflow, repository description file, meaningful output filenames. Mostly prompt engineering improvements that can be applied incrementally.
- **Quality & safety gates** — Diff review gate (check unintended changes before merge), rollback automation (auto-revert on CI failure), dependency impact analysis (warn on high-impact file changes), security scanning integration (Semgrep/Snyk/Trivy), test coverage enforcement, deterministic verification (compare results across retries). Best addressed when the Runtime decomposition (Phase 3) and Event Bus (Phase 4) are in place.

---

## Verification

After each phase:
1. `pwsh install.ps1`
2. `pwsh tests/Run-Tests.ps1` (layers 1-3)
3. Phase-specific checks:
   - Phase 1: Structured JSONL in logs, no silent catches
   - Phase 2: Task state transitions atomic and validated
   - Phase 3: All process types dispatch correctly
   - Phase 4: Events published and sinks receive them
   - Phase 5: Decisions CRUD + UI tab
   - Phase 6: `dotbot init --profile dotnet` works, workflows separate
   - Phase 7: `dotbot run` creates isolated run with tasks
   - Phase 8: Outpost registers with mothership, heartbeats flow
   - Phase 9: `dotbot doctor` reports health
   - Phase 10: Drone registers, polls work, executes assignment, reports completion
   - Phase 11: `dotbot registry add/list/update`, `dotbot init --profile myorg:stack`, `dotbot run myorg:workflow`
   - Phase 12: Self-improvement cycle generates suggestions, UI displays them, apply/reject works, counter resets
   - Phase 13: Slack/Discord/WhatsApp delivery works, attachments upload and render per channel, questionnaires collect batched responses
   - Phase 14: Team CRUD via MCP tools, role-based Q&A routing resolves correct recipients, availability/delegation works

## Key Files Referenced

| File | Lines | Role |
|------|-------|------|
| `profiles/default/systems/runtime/launch-process.ps1` | 2,924 | Monolith to decompose |
| `scripts/init-project.ps1` | 977 | Init to simplify |
| `profiles/default/systems/mcp/modules/TaskIndexCache.psm1` | — | Task query layer |
| `profiles/default/systems/runtime/modules/ui-rendering.ps1` | — | Activity logging |
| `profiles/default/systems/runtime/ClaudeCLI/ClaudeCLI.psm1` | 1,232 | CLI wrapper |
| `profiles/default/defaults/settings.default.json` | 77 | Settings hub |
| `profiles/default/systems/ui/server.ps1` | 1,533 | Dashboard server |
| `profiles/default/systems/ui/modules/AetherAPI.psm1` | 290 | Hue bridge integration |
| `profiles/default/systems/mcp/modules/NotificationClient.psm1` | 350 | Mothership client |
| `profiles/default/systems/ui/static/modules/aether.js` | 930 | Aether frontend |
| `profiles/default/systems/runtime/ProviderCLI/ProviderCLI.psm1` | 464 | Multi-provider abstraction (Claude/Codex/Gemini) |
| `profiles/default/defaults/providers/{claude,codex,gemini}.json` | ~30 ea | Declarative provider configs |
| `server/src/Dotbot.Server/` | — | Mothership .NET server |
