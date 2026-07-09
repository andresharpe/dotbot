# dotbot Mothership — Product Requirements Document

> **Status:** Draft — In Review · **Version:** 0.4 · **Date:** July 2026  
> **Releases:** v4.1 · v4.2 · v4.3 · **Audience:** Engineering · Product

---

## Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals](#3-goals)
4. [User Personas](#4-user-personas)
5. [Solution Architecture](#5-solution-architecture)
6. [v4.1 Requirements](#6-v41-requirements)
7. [v4.2 Requirements](#7-v42-requirements)
8. [v4.3 Requirements](#8-v43-requirements)
9. [Non-Functional Requirements](#9-non-functional-requirements)
10. [Out of Scope](#10-out-of-scope)
11. [Success Metrics](#11-success-metrics)
12. [Open Questions](#12-open-questions)
13. [Dependencies](#13-dependencies)

---

## 1. Executive Summary

dotbot v4 is a PowerShell 7+ AI-assisted development orchestration framework. It coordinates Claude-powered task agents, manages git worktrees, routes approvals, and integrates with existing toolchains — all from a single git checkout on a developer's machine. As of v4.0.1 (shipped July 2026), every dotbot installation is a standalone island: one developer, one machine, no shared view across the team.

This PRD covers the **Mothership fleet layer** — a .NET ASP.NET Core server that connects all dotbot instances together, enabling team-wide visibility, intelligent Q&A routing, headless drone execution, and collaborative decision-making. It also covers two developer-productivity features that emerged from team feedback: the **Outpost Work Inbox** (multi-PBI queuing without multiple processes) and **task failure notifications** (alert when dotbot stalls or errors).

> The fleet layer does not replace local development. Studio UI and local execution remain the primary developer experience. Mothership adds the team layer on top — shared visibility, overnight drone runs, and role-based routing — without changing how an individual developer works.

---

## 2. Problem Statement

| # | Problem | Impact |
|---|---------|--------|
| P1 | **No shared visibility.** Five developers running dotbot have five isolated islands. No team lead can see task status, decisions, or running workflows without accessing each machine individually. | Coordination overhead, missed blockers, duplicated effort |
| P2 | **Q&A goes to a flat list.** Questions raised by Claude go to a flat email/Teams list. Everyone receives every question regardless of role, domain, or availability. Wrong people answer; right people miss it. | Slow answers, wrong decisions, alert fatigue |
| P3 | **Someone must be present.** Tasks only run while a developer's machine is on. Overnight jobs, long parallel runs, and CI pipelines require a developer to leave their laptop running. | Slow throughput, wasted developer time watching progress |
| P4 | **Multiple PBIs require multiple dotbot processes.** Working on several PBIs without watching requires starting multiple instances — competing branches from the same base — merge conflict hell at the end. | Developer stays idle watching dotbot or faces manual conflict resolution |
| P5 | **No notification when dotbot stalls or fails.** If the agent stops making progress or errors, nothing happens. The developer must be watching Studio to notice. | Silent failures, time lost, developer can't walk away |

---

## 3. Goals

### v4.1 — Foundation

- Deploy a running Mothership server that outposts register with on startup
- Give team leads a single fleet dashboard showing all outposts and running tasks
- Route Q&A questions to the right role via Mothership web UI with MagicLink access
- Sync outpost events to Mothership in near real-time so the team sees decisions and task status
- Ship secure auth: OIDC for humans, API key for M2M (outposts, drones)

### v4.2 — Fleet & Productivity

- Enable drone workers — headless dotbot instances that run tasks from the Mothership work queue
- Let developers queue multiple PBIs into one dotbot process, walk away, and get clean sequential PRs
- Notify developers via Teams/Email/desktop when a task fails or stalls
- Deliver enterprise Q&A features: questionnaires, escalation policies, quorum approvals

### v4.3 — Scale

- Mothership coordinates team-wide PR merge sequencing — parallel drone runs, no conflict hell
- Multi-tenant org isolation, rate limiting, data retention compliance

### Non-goals (permanent)

- A SaaS-hosted Mothership — self-hosted only
- Replacing local developer execution — local stays primary
- Real-time streaming of live worktree contents to Mothership

---

## 4. User Personas

### Developer

Runs dotbot locally on their machine. Uses Studio UI to trigger tasks, review output, answer their own questions. Primary day-to-day user.

**Needs:** Uninterrupted local experience. Notification when something fails. Ability to queue work and walk away.

### Team Lead

Monitors all outposts, reviews approvals, tracks project health. Does not run tasks directly.

**Needs:** Single fleet dashboard. Role-based question routing. Visibility into decisions and PRs across the team.

### Reviewer / SME

Domain expert routed questions that require their specific knowledge. May not run dotbot themselves.

**Needs:** Low-friction answer experience — MagicLink straight to the question. No account setup required.

### Operator

Deploys and maintains the Mothership server. Manages Docker infrastructure, OIDC config, outpost approvals.

**Needs:** Guided first-time setup. Clear env variable reference. Docker-based deployment that works on any cloud.

---

## 5. Solution Architecture

### Key concepts

| Term | Definition |
|------|-----------|
| `Mothership` | The .NET ASP.NET Core server — fleet hub, work queue, Q&A web UI, team registry, event bus, fleet dashboard. |
| `Fleet` | All dotbot instances collectively (outposts + drones) connected to a Mothership server. |
| `Outpost` | A dotbot instance on a developer's machine. Registers with Mothership on startup, streams events in near real-time. Studio UI still runs locally. |
| `Drone` | A headless dotbot worker — no UI, polls the Mothership work queue, runs Claude, reports results back. Used for overnight jobs, parallel PBIs, CI pipelines. |
| `Work Inbox` | Outpost-side queue that accepts multiple PBIs and processes them sequentially in one running dotbot process, rebasing between each. |

### Target architecture

```
Mothership — always running
─────────────────────────────────────────────────────────
  Mothership server  ↔  Fleet dashboard · Q&A web UI · Team registry
  Mothership server  →  Work queue · Event bus · AlertService · Decision sync

Outposts — developer machines
─────────────────────────────────────────────────────────
  Studio UI  →  Runtime · Work Inbox · Event bus  → registers + streams →  Mothership

Drones — headless workers
─────────────────────────────────────────────────────────
  Drone 1  ← polls work queue ←  Mothership
  Drone 2  ← polls work queue ←  Mothership
```

### Mothership connection model

The outpost connects to a Mothership at **runtime** via a `--mothership <url>` flag. No flag defaults to local — the Studio UI already acts as a local Mothership (runtime and UI communicate over HTTP even on the same machine). The delegation target follows which Mothership the outpost is pointed at.

### Execution model

Drones are **additional capacity, not a replacement** for local execution. Local execution remains the primary developer experience. Drones handle lights-out scenarios: overnight jobs, CI pipelines, parallel batch runs where no developer is present.

---

## 6. v4.1 Requirements

**Milestone:** `Dotbot V4.1.0` · Target: Q3 2026

### Fleet infrastructure

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F01 | Outpost registration & heartbeat | MothershipClient registers on startup, heartbeat every 30s. Mothership tracks instance state (online/stale/offline). | [#544](https://github.com/andresharpe/dotbot/issues/544) |
| F02 | Mothership deployment — Docker image & CLI | Dockerfile, docker-compose for local full stack, env var reference, `dotbot server start/stop/status` CLI. SQLite on local Docker volume. Cloud-agnostic. | [#576](https://github.com/andresharpe/dotbot/issues/576) |
| F03 | First-time admin setup & onboarding | Guided `/setup` page on fresh Mothership start. Creates first admin account, configures auth, shows API key. Outpost approval flow. `dotbot mothership connect <url>`. | [#608](https://github.com/andresharpe/dotbot/issues/608) |
| F04 | Event forwarding — outpost → Mothership | Outpost streams task lifecycle events to Mothership event sink in near real-time. `POST /api/fleet/{instance_id}/events`. Built on event bus (#93). | [#599](https://github.com/andresharpe/dotbot/issues/599) |
| F05 | AlertService — fleet health alerts | Background job polling heartbeat data. Raises alerts when outpost (5 min) or drone (2 min) goes stale. Routes via DeliveryOrchestrator. `GET /api/fleet/alerts`. | [#95](https://github.com/andresharpe/dotbot/issues/95) |

### Fleet dashboard

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F06 | Fleet dashboard UI scaffolding | Dashboard with mock data: instance list, heartbeat status, task counts, drone utilization, active alerts. | [#547](https://github.com/andresharpe/dotbot/issues/547) |
| F07 | Fleet dashboard live wire-up | Replace all mock data with live API calls. Loading, empty, error, and stale states. End-to-end smoke test. | [#598](https://github.com/andresharpe/dotbot/issues/598) |
| F08 | Decision sync | Push outpost decisions to Mothership. Version field for conflict detection. 409 on conflict with Studio diff surface. Audit log. | [#596](https://github.com/andresharpe/dotbot/issues/596) |

### Auth & security

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F09 | IAuthProvider interface + OIDC | Auth abstraction layer. OIDC Auth Code + PKCE for human users. Scope model for catalog-level access control. | [#548](https://github.com/andresharpe/dotbot/issues/548) |
| F10 | M2M auth — OAuth 2.0 client credentials | OAuth 2.0 client credentials flow for unattended outpost and drone authentication. Scoped API access. Replaces or coexists with DOTBOT_API_KEY (see OQ1). | [#594](https://github.com/andresharpe/dotbot/issues/594) |
| F11 | RBAC wiring | Enforce role-based access on all `/api/fleet/*` endpoints using IAuthProvider scopes. | [#597](https://github.com/andresharpe/dotbot/issues/597) |

### Q&A and team registry

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F12 | Core team registry | Team member records with role, domain, channel preferences. 8 MCP tools: team-add, team-remove, team-list, team-get, team-update, team-who-knows, team-available, team-suggest. | [#98](https://github.com/andresharpe/dotbot/issues/98) |
| F13 | Q&A web delivery provider | Questions delivered via the Mothership web UI. ReviewLinks for Q&A answers. Depends on team registry. | [#545](https://github.com/andresharpe/dotbot/issues/545) |
| F14 | Q&A web notification — MagicLink | When a question lands in Mothership web UI, send companion notification with MagicLink. Signed token (48h), pre-authenticated deep link. | [#609](https://github.com/andresharpe/dotbot/issues/609) |
| F15 | Team integrations — Q&A routing & decision stakeholders | Route Q&A questions to the right team member by role/domain. Decision stakeholder resolution. Prompt injection of team context. | [#600](https://github.com/andresharpe/dotbot/issues/600) |

### Navigation shell

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F16 | Shared navigation shell — Studio & Mothership | Unified dotbot-shell.css + HTML harness. Top bar + icon rail rendered identically in both Studio and Mothership. Tab restructure + unified Tasks surface. | [#551](https://github.com/andresharpe/dotbot/issues/551), [#604](https://github.com/andresharpe/dotbot/issues/604)–[#607](https://github.com/andresharpe/dotbot/issues/607) |

---

## 7. v4.2 Requirements

**Milestone:** `Dotbot V4.2.0` · Target: Q4 2026

### Drone fleet

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F17 | WorkQueueService + DroneSchedulerService | Mothership-side work queue. Drones poll `GET /api/fleet/work-queue/next`. Scheduler assigns tasks by capability matching. Dead-letter after max retries. | [#593](https://github.com/andresharpe/dotbot/issues/593) |
| F18 | Drone agent — headless task execution | DroneAgent.psm1 + DroneConfig. Polls work queue, runs Claude in isolated worktree, reports results. Heartbeat every 30s. Missed heartbeat → task returned to queue, max 3 retries, then dead-letter. | [#96](https://github.com/andresharpe/dotbot/issues/96) |
| F19 | Outpost-to-Drone task delegation | MothershipClient functions: Submit-DroneAssignment, Get-DroneAssignmentStatus, Wait-DroneAssignment, Revoke-DroneAssignment. MCP tool: task_delegate_to_drone. Workflow manifest option: `execution: local\|drone\|auto`. | [#575](https://github.com/andresharpe/dotbot/issues/575) |
| F20 | Drone credential store | Secure credentials_ref resolution for repo cloning on drones. Credentials stored outside the task context, resolved at execution time. | [#574](https://github.com/andresharpe/dotbot/issues/574) |

### Outpost Work Inbox

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F21 | Work Inbox — multi-PBI queue in one dotbot process | Persistent queue at `.bot/.control/queue.json`. `dotbot queue add <ref>` CLI. QueueRunner background job: run → PR → rebase → run. Rebase conflict pauses queue and fires notification. Survives restart. Studio Queue panel. When Mothership configured: submits to drone fleet. | [#618](https://github.com/andresharpe/dotbot/issues/618) |

### Notifications

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F22 | Task failure & stall notifications | Stuck detector: fires `task.stalled` when no agent progress for configurable window (default 10 min). Notification sink subscribes to task.failed, task.stalled, workflow.run_failed, queue.conflict, queue.completed. Delivers via Teams, Email, desktop (BurntToast / notify-send). | [#619](https://github.com/andresharpe/dotbot/issues/619) |

### Enterprise Q&A

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F23 | Escalation Policy Engine | Configurable per-question escalation rules. No response within deadline → escalate to next tier. Policy declared in workflow manifest. | [#586](https://github.com/andresharpe/dotbot/issues/586) |
| F24 | Quorum & weighted approval | Multi-respondent approval modes. Quorum: N approvals required. Weighted: senior votes count more. Escalates if quorum not reached within policy window. | [#587](https://github.com/andresharpe/dotbot/issues/587) |
| F25 | QuestionnaireService | Batched question sets with conditional branching, deadline tracking, status lifecycle: pending → partially-answered → complete / expired. | [#602](https://github.com/andresharpe/dotbot/issues/602) |
| F26 | Q&A channel preferences per recipient | Per-team-member delivery channel preference with fallback ordering. Read from team registry at dispatch time. | [#603](https://github.com/andresharpe/dotbot/issues/603) |

### Fleet dashboard expansion

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F27 | Team UI tab + Mothership team sync endpoint | Team tab showing registry members, roles, channel preferences. Sync endpoint for outpost team-add/team-remove. | [#601](https://github.com/andresharpe/dotbot/issues/601) |
| F28 | Fleet dashboard org-scoped isolation | Filter all dashboard views by authenticated org. | [#595](https://github.com/andresharpe/dotbot/issues/595) |
| F29 | Outbound webhooks | Event subscriptions for external integrations. Per-endpoint event filter + HMAC-SHA256 signatures. SSRF guard on all URLs. | [#589](https://github.com/andresharpe/dotbot/issues/589) |
| F30 | Org / multi-tenant isolation | Organisational boundary in Mothership. Each org's data is isolated. RBAC controls cross-org visibility. | [#588](https://github.com/andresharpe/dotbot/issues/588) |

---

## 8. v4.3 Requirements

**Milestone:** `Dotbot V4.3.0` · Target: 2027

| ID | Feature | Description | Issue |
|----|---------|-------------|-------|
| F31 | Mothership merge orchestration | Team-wide PR sequencing. Mothership orders by priority and dependencies, triggers merge in sequence, auto-rebases between merges. Conflict pauses that PR and notifies the owning developer; other PRs continue. Merge queue visible in dashboard. | [#620](https://github.com/andresharpe/dotbot/issues/620) |
| F32 | Rate limiting | Per-outpost throttling on Mothership API. Configurable limits. Returns 429 with retry-after header. | [#590](https://github.com/andresharpe/dotbot/issues/590) |
| F33 | Data retention & GDPR compliance | Erasure, export, and retention policy enforcement. GDPR right-to-erasure for team member data. | [#591](https://github.com/andresharpe/dotbot/issues/591) |
| F34 | HA / multi-instance Mothership | Multiple Mothership instances behind a load balancer. Shared persistence layer. Deferred until single-instance requirements force it. | — |

---

## 9. Non-Functional Requirements

| Area | Requirement |
|------|-------------|
| **Event latency** | Outpost events must appear in Mothership fleet dashboard within **5 seconds** of occurrence under normal network conditions. |
| **Heartbeat** | Outpost heartbeat every **30 seconds**. Stale threshold: outpost 5 min, drone 2 min. AlertService fires on first missed threshold breach. |
| **Deployment** | Docker-based, cloud-agnostic. No Azure/AWS/on-prem lock-in for v4.1. Single instance for v4.1; HA deferred to v4.3. |
| **Persistence** | SQLite on a **local Docker volume** (not network-mounted). NFS-backed storage (e.g. Azure Files) is explicitly unsupported for v4.1 due to locking risk. |
| **Transport security** | HTTPS-only for all Mothership endpoints. Webhook delivery: HTTPS + HMAC-SHA256 + SSRF guard. MagicLink tokens: signed, 48h TTL, single-use configurable. |
| **Auth** | OIDC Auth Code + PKCE for human users. OAuth 2.0 client credentials for M2M (outposts, drones). RBAC on all `/api/fleet/*` endpoints. |
| **Drone reliability** | Missed heartbeat → task returned to work queue. Max 3 retries per task. Dead-letter state after max retries with dashboard visibility and manual retry option. |
| **Event bus delivery** | At-least-once delivery via persisted byte cursor. Crash mid-dispatch replays on restart. Sink failures are non-aborting and logged — they do not block other sinks or roll back task state. |
| **Cross-platform** | Outpost runs on Windows, macOS, and Linux (PowerShell 7.2+). Mothership server runs on any Docker host. Tests run on all three OS via CI matrix. |

---

## 10. Out of Scope

> Items listed here are explicitly excluded. Scope creep into these areas requires a separate PRD and deliberate prioritization decision.

- **SaaS-hosted Mothership** — self-hosted only. No Anthropic-managed or vendor-managed cloud offering.
- **Replacing local developer execution** — Studio and local execution stay primary. Drones are additive capacity, not a replacement.
- **Real-time worktree streaming** — live file edits mid-task stay local. Only completed events (task status, decisions, PRs) are forwarded to Mothership.
- **Drone-to-drone communication** — drones do not coordinate directly. All coordination goes through the Mothership work queue.
- **Automatic AI-assisted conflict resolution** — merge conflicts require human resolution in v4.1–v4.3.
- **Cross-repo merge coordination** — merge orchestration (v4.3) is single-repo only.
- **HA / multi-instance Mothership** — deferred to v4.3. Single instance is the v4.1 and v4.2 target.
- **Network-mounted SQLite storage** — NFS-backed mounts (Azure Files, EFS) are unsupported. Local Docker volume only.

---

## 11. Success Metrics

| Metric | Target | Release |
|--------|--------|---------|
| Outpost registers with Mothership on first `dotbot go` | Zero manual steps after `mothership.url` is configured | v4.1 |
| Task event appears in fleet dashboard after completing locally | < 5 seconds | v4.1 |
| Q&A question reaches the correct role recipient | Role-matched routing, not flat list | v4.1 |
| Mothership first-time setup completed by operator | Admin account + first outpost connected in < 15 minutes from `docker compose up` | v4.1 |
| Developer queues 3 PBIs and walks away | All 3 PRs raised with zero merge conflicts, zero manual triggers between items | v4.2 |
| Developer notified when task stalls | Notification delivered within 1 minute of stall threshold being crossed | v4.2 |
| Drone picks up work queue item and returns result | End-to-end: task submitted → drone executes → result on outpost, no developer present | v4.2 |
| Parallel drone PRs merge without conflicts | Mothership sequences merges correctly for N concurrent PRs (N ≥ 3) | v4.3 |

---

## 12. Open Questions

**OQ1 — Auth model for outposts and drones**

Does DOTBOT_API_KEY coexist with OIDC, or is it retired when [#548](https://github.com/andresharpe/dotbot/issues/548) ships? The API key is currently the only M2M auth mechanism. When OIDC ships, does the key become interim (replaced by OAuth 2.0 client credentials, [#594](https://github.com/andresharpe/dotbot/issues/594)) or remain alongside OIDC? This affects what [#576](https://github.com/andresharpe/dotbot/issues/576) documents and what #548 and #594 need to implement.

→ @carlospedreira

---

**OQ2 — SQLite storage constraint for v4.1**

Is "use local Docker volume only" sufficient as the SQLite storage constraint, or does the risk of network-mounted storage indicate a different DB for containerized deployments? @ap-cbilgin flagged that NFS-backed storage (Azure Files, EFS) can corrupt SQLite under concurrent writes.

→ @ap-cbilgin, @carlospedreira

---

**OQ3 — Local Mothership + local drone delegation**

When connected to a local Mothership (no `--mothership` flag), can tasks delegate to local drones? Does `execution: drone` work with a local Mothership, or does drone delegation require a remote fleet?

→ @carlospedreira, @ap-cbilgin

---

**OQ4 — `auto` mode trigger for drone delegation**

[#575](https://github.com/andresharpe/dotbot/issues/575) defines `auto` as "escalate when outpost load exceeds max_concurrent." Should `auto` also escalate when no developer session is active? If so, how is "developer not active" detected reliably?

→ @carlospedreira, @ap-cbilgin

---

**OQ5 — Mothership hosting target**

Carlos confirmed Docker-first, cloud-agnostic. What is the team's actual intended deployment target — Azure Container Apps, self-hosted VM, Kubernetes? This affects the setup guide scope in [#576](https://github.com/andresharpe/dotbot/issues/576) and whether managed-disk guidance for SQLite is needed.

→ @carlospedreira

---

## 13. Dependencies

### Done — unblocks everything above

| Issue | Title | Status |
|-------|-------|--------|
| [#93](https://github.com/andresharpe/dotbot/issues/93) | Event bus for inter-system communication | **Done** — PR [#610](https://github.com/andresharpe/dotbot/pull/610) merged to releases/4.1.0 |

### v4.1 dependency order

| Issue | Depends on | Blocks |
|-------|-----------|--------|
| [#576](https://github.com/andresharpe/dotbot/issues/576) | #544, #548 | #608 |
| [#544](https://github.com/andresharpe/dotbot/issues/544) | — | #598, #599, #95 |
| [#548](https://github.com/andresharpe/dotbot/issues/548) | — | #594, #597, #608 |
| [#95](https://github.com/andresharpe/dotbot/issues/95) | #544 | #598 |
| [#599](https://github.com/andresharpe/dotbot/issues/599) | #93 (done), #544 | #619 |
| [#98](https://github.com/andresharpe/dotbot/issues/98) | — | #600, #545, #586, #587 |
| [#545](https://github.com/andresharpe/dotbot/issues/545) | #93 (done), #98 | #609 |
| [#547](https://github.com/andresharpe/dotbot/issues/547) | — | #598, #601 |
| [#598](https://github.com/andresharpe/dotbot/issues/598) | #544, #95, #597 | — |
| [#597](https://github.com/andresharpe/dotbot/issues/597) | #544, #548 | #598 |

### v4.2 dependency order

| Issue | Depends on | Blocks |
|-------|-----------|--------|
| [#593](https://github.com/andresharpe/dotbot/issues/593) | #93 (done) | #575, #96 |
| [#96](https://github.com/andresharpe/dotbot/issues/96) | #593 | #575 |
| [#575](https://github.com/andresharpe/dotbot/issues/575) | #95, #96, #574 | #618 |
| [#618](https://github.com/andresharpe/dotbot/issues/618) | #93 (done), #575, #593 | #620 |
| [#619](https://github.com/andresharpe/dotbot/issues/619) | #93 (done), #599 | — |

---

*See also: [DOTBOT-V4-FRAMEWORK.md](DOTBOT-V4-FRAMEWORK.md) · [AGENTS.md](../AGENTS.md) · [Release Notes](release-notes/)*
