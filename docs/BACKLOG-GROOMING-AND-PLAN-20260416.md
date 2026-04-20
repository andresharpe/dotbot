# Backlog Grooming & Sprint Plan — 2026-04-16

## Overview

Full grooming of the dotbot GitHub backlog: 57 open issues sized, prioritized, assigned to themed milestones, and reflected on the [Dotbot v4 Roadmap](https://github.com/users/andresharpe/projects/2) project board.

---

## Backlog snapshot

| Metric | Value |
|--------|-------|
| Open issues | 57 |
| Previously untriaged (`needs-triage`) | 14 — all now triaged |
| Previously missing from project board | 14 — all now added |
| Null-status items on board | 27 — all set to Done (closed issues) |
| Milestones before | 0 |
| Milestones after | 6 |

---

## Issue sizing

Every open issue was assessed against these definitions:

| Size | Effort | Count |
|------|--------|-------|
| **XS** | A few hours | 11 |
| **S** | About a day | 15 |
| **M** | A few days | 17 |
| **L** | About a week | 8 |
| **XL** | Multi-week | 6 |

### XS — A few hours

| # | Title |
|---|-------|
| 104 | Add needs_review task field |
| 152 | Remove Unused Problem-Log Module |
| 160 | Update Root README Structure |
| 161 | Update Default Workflow README |
| 162 | Update Server README |
| 184 | Remove legacy .serena worktree noise exclusion |
| 212 | Add .txt & image view support to Product Documents Viewer |
| 217 | Adopt chalk/ansi-regex for ANSI stripping |
| 253 | Critical path MCP tools have zero test coverage |
| 257 | Remove unused workspace/feedback/ scaffolding |
| 263 | Dotbot cannot create tasks |

### S — About a day

| # | Title |
|---|-------|
| 101 | Fix default workflow listing after overlay init |
| 103 | Hide global analyze-execute controls |
| 123 | Consolidate duplicate function definitions |
| 135 | Cannot use Codex to kickstart |
| 145 | Reduce Dead Code |
| 146 | Update Documentation |
| 159 | Review Tool-Local Test Scripts |
| 173 | Framework file protection |
| 198 | Resume button incorrectly appears during active task-runner |
| 213 | Dotbot continues even when task fails |
| 214 | Dotbot does not continue after interruption |
| 239 | Overview panel no progress indicator |
| 241 | UI still depends on kickstart engine |
| 256 | Kickstart with Jira failed Phase 4 — missing todo tasks |
| 259 | Workflow tab uses legacy /api/kickstart/status |

### M — A few days

| # | Title |
|---|-------|
| 25 | Script audit — full quality review of all PS scripts |
| 26 | Spec the documents dotbot publishes to Jira/Confluence |
| 29 | Expand QuestionService — artifact approvals, roles, new types |
| 30 | Jira as an approval channel |
| 32 | Workflow tab UI — phase pipeline & task lifecycle viz |
| 37 | E2E test MS Teams and Email Q&A with attachments |
| 40 | Professionalise repo — DevOps setup |
| 76 | Built-in Shared Memory System |
| 90 | Structured logging module (v4 phase 01) |
| 93 | Event bus for inter-system communication (v4 phase 04) |
| 102 | User-level workflow editor |
| 129 | GitHub Workflow Family: github-kickstart & github-remediate |
| 134 | Route .mcp.json through provider config |
| 140 | Normalize cross-platform path handling |
| 204 | UI E2E regression suite |
| 220 | Add interview task type to task-runner |
| 249 | Global User Settings |

### L — About a week

| # | Title |
|---|-------|
| 38 | Research OpenClaw channels for human orchestration |
| 39 | Explore Jira-initiated project kickstart flow |
| 94 | Restructure profiles into stacks and workflows (v4 phase 06) |
| 136 | Platform Portability Issues |
| 143 | Unclear platform/provider/model boundaries |
| 221 | Post-phase question detection & adjustment pass |
| 225 | Add Teams inbound path for operator whispers |
| 254 | Add Incremental QA Workflow |

### XL — Multi-week

| # | Title |
|---|-------|
| 28 | Mothership dashboard — fleet visibility |
| 95 | Mothership fleet coordination (v4 phase 08) |
| 96 | Drone agent — remote task execution (v4 phase 10) |
| 97 | Self-improvement loop (v4 phase 12) |
| 98 | Project team and roles (v4 phase 14) |
| 99 | Aether conduit plugin architecture (v4 phase 15) |

---

## Prioritization

Issues scored on three axes (1-5 each):

- **Impact**: How many users/workflows affected? Does it block core functionality?
- **Risk if deferred**: What breaks or degrades if we don't do this soon?
- **Unlock value**: Does completing this unblock other work or strategic goals?

### P0 — Critical: blocks core use right now

Bugs where the primary workflow (task-runner / kickstart) fails or produces wrong results.

| # | Title | Size | Rationale |
|---|-------|------|-----------|
| 263 | Dotbot cannot create tasks | XS | Task-runner dies on path resolution — blocks entire workflow for kickstart-via-jira users |
| 135 | Cannot use Codex to kickstart | S | Blocks an entire provider — `$trackIdx` crash on startup |
| 213 | Dotbot continues even when task fails | S | Silent failures waste API spend and produce broken output |
| 214 | Dotbot does not continue after interruption | S | Interrupted tasks stuck in `analysing` — no recovery path |
| 256 | Kickstart with Jira failed Phase 4 — missing todo tasks | S | AI ignores task_gen intent, spends $4+ doing the wrong thing |

### P1 — High: core experience is broken or misleading

The workflow runs but the UI lies about it, or launches the wrong engine.

| # | Title | Size | Rationale |
|---|-------|------|-----------|
| 241 | UI still depends on kickstart engine (Resume + right panel) | S | Resume button launches the wrong engine — re-runs phases instead of continuing tasks |
| 198 | Resume button incorrectly appears during active task-runner | S | Confusing UX — button appears, then errors on click |
| 239 | Overview panel doesn't show workflow progress | S | Zero visibility into running workflow from main screen |
| 259 | Workflow tab uses legacy /api/kickstart/status | S | Workflow tab shows all phases as "pending" during active run |
| 123 | Consolidate duplicate function definitions | S | Proven source of bugs (#122) — wrong function wins depending on import order |
| 101 | Fix default workflow listing after overlay init | S | Broken default workflow still visible in tab after overlay |
| 253 | Critical path MCP tools have zero test coverage | XS | 4 tools driving autonomous execution are completely untested |
| 173 | Framework file protection | S | Agents can corrupt .bot/ framework files with no guard |

### P2 — Medium: platform reach, developer experience, quality

| # | Title | Size | Rationale |
|---|-------|------|-----------|
| 140 | Normalize cross-platform path handling | M | 130+ hardcoded backslashes — blocks macOS/Linux |
| 136 | Platform Portability Issues (umbrella) | L | Junctions, env vars, pwsh.exe — macOS/Linux broken at multiple levels |
| 220 | Add interview task type to task-runner | M | Biggest HITL parity gap with kickstart engine |
| 221 | Post-phase question detection & adjustment pass | L | Second HITL parity gap |
| 90 | Structured logging module (v4 phase 01) | M | Foundation for every v4 phase |
| 25 | Script audit — full quality review | M | Error handling inconsistencies create hard-to-debug failures |
| 103 | Hide global analyze-execute controls | S | UI inconsistency alongside per-workflow controls |
| 32 | Workflow tab UI — phase pipeline & task viz | M | Key dashboard upgrade |
| 204 | UI E2E regression suite | M | 23 JS modules, ~500KB frontend, zero browser tests |
| 217 | Adopt chalk/ansi-regex for ANSI stripping | XS | Raw escape codes visible in UI |
| 129 | GitHub Workflow Family | M | GitHub-native workflow — high demand |
| 40 | Professionalise repo — DevOps setup | M | Branch protection, templates, CODEOWNERS |
| 134 | Route .mcp.json through provider config | M | Claude-specific config leaking into generic code |
| 143 | Unclear platform/provider/model boundaries | L | Architectural clarity for multi-provider support |

### P3 — Low: quality of life, cleanup, polish

| # | Title | Size |
|---|-------|------|
| 152 | Remove Unused Problem-Log Module | XS |
| 184 | Remove legacy .serena worktree exclusion | XS |
| 257 | Remove unused workspace/feedback/ scaffolding | XS |
| 145 | Reduce Dead Code | S |
| 159 | Review Tool-Local Test Scripts | S |
| 146 | Update Documentation | S |
| 160 | Update Root README Structure | XS |
| 161 | Update Default Workflow README | XS |
| 162 | Update Server README | XS |
| 104 | Add needs_review task field | XS |
| 212 | Add .txt & image view to Product Documents Viewer | XS |
| 249 | Global User Settings | M |
| 225 | Add Teams inbound path for operator whispers | L |
| 254 | Add Incremental QA Workflow | L |
| 26 | Spec Jira/Confluence document publishing | M |
| 37 | E2E test MS Teams and Email Q&A | M |
| 38 | Research OpenClaw channels | L |

### P4 — Backlog: future vision / v4 roadmap

| # | Title | Size | Depends on |
|---|-------|------|------------|
| 93 | Event bus (v4 phase 04) | M | #90 (logging) |
| 94 | Restructure profiles into stacks & workflows | L | — |
| 76 | Built-in Shared Memory System | M | — |
| 102 | User-level workflow editor | M | — |
| 29 | Expand QuestionService | M | — |
| 30 | Jira as an approval channel | M | #29 |
| 39 | Explore Jira-initiated kickstart flow | L | — |
| 28 | Mothership dashboard — fleet visibility | XL | #90, #93 |
| 95 | Mothership fleet coordination (v4 phase 08) | XL | #28, #93 |
| 96 | Drone agent — remote task execution (v4 phase 10) | XL | #95 |
| 97 | Self-improvement loop (v4 phase 12) | XL | #90, #93 |
| 98 | Project team and roles (v4 phase 14) | XL | #29 |
| 99 | Aether conduit plugin architecture (v4 phase 15) | XL | #93 |

### Priority summary

| Priority | Issues | Total effort |
|----------|--------|-------------|
| P0 Critical | 5 | ~4-5 days |
| P1 High | 8 | ~8-10 days |
| P2 Medium | 14 | ~4-6 weeks |
| P3 Low | 17 | ~3-4 weeks |
| P4 Backlog | 13 | months — phased |

---

## Milestones

Six themed milestones created with time budgets:

| Milestone | Due | Issues | Theme |
|-----------|-----|--------|-------|
| **Stabilize** | 2026-05-02 | 13 | P0 bugs + P1 core experience fixes |
| **Task-runner parity** | 2026-05-16 | 4 | Close HITL gaps between task-runner and kickstart engine |
| **Cross-platform** | 2026-05-30 | 5 | macOS/Linux portability |
| **v4 Foundation** | 2026-06-20 | 6 | Logging, event bus, script quality, test infra, DevOps |
| **Polish & Cleanup** | 2026-07-04 | 14 | Tech debt, docs, small features |
| **v4 Fleet** | no date | 15 | Mothership, drones, agents, vision items |

---

## Dependency chain

```
#90 Logging ──> #93 Event bus ──> #28/#95 Mothership ──> #96 Drone
                             ──> #97 Self-improvement
                             ──> #99 Aether plugins
#29 QuestionService ──> #30 Jira approval ──> #98 Team & roles
#140 Path handling ──> #136 Platform portability (umbrella)
#241 Resume fix ──> #259 Workflow tab fix (same root cause)
```

---

## Sprint 1: Stabilize (Apr 21 — May 2)

### Goal

Fix every bug where dotbot fails or misleads the user. After this sprint, the core task-runner workflow works end-to-end and the UI accurately reflects what is happening.

### Issues

#### P0 — Critical (5 issues, ~4-5 days)

| # | Title | Size | Assignee |
|---|-------|------|----------|
| 263 | Dotbot cannot create tasks | XS | kabaogluemre |
| 135 | Cannot use Codex to kickstart | S | carlospedreira |
| 213 | Dotbot continues even when task fails | S | ProtonPump |
| 214 | Dotbot does not continue after interruption | S | ProtonPump |
| 256 | Kickstart with Jira failed Phase 4 — missing todo tasks | S | EnmaJim |

#### P1 — High (8 issues, ~6-8 days)

| # | Title | Size | Assignee |
|---|-------|------|----------|
| 241 | UI still depends on kickstart engine (Resume + right panel) | S | kabaogluemre |
| 198 | Resume button incorrectly appears during active task-runner | S | kabaogluemre |
| 239 | Overview panel doesn't show workflow progress | S | kabaogluemre |
| 259 | Workflow tab uses legacy /api/kickstart/status | S | kabaogluemre |
| 123 | Consolidate duplicate function definitions | S | DKuleshov |
| 101 | Fix default workflow listing after overlay init | S | kabaogluemre |
| 253 | Critical path MCP tools have zero test coverage | XS | EnmaJim |
| 173 | Framework file protection | S | gmireles-ap |

### Work order

```
Week 1 (Apr 21-25): P0 bugs — get core workflow working
  +-- #263 (XS) -- quick path fix, unblocks Jira workflow users immediately
  +-- #213 + #214 -- task-runner resilience pair, related root causes
  +-- #256 -- task_gen phase fix for Jira workflow
  +-- #135 -- Codex provider fix (carlospedreira already on it)

Week 2 (Apr 28 - May 2): P1 — UI truth + safety
  +-- #241 + #198 + #239 + #259 -- UI/task-runner alignment cluster
  |    (share root cause: Get-KickstartStatus only matches type='kickstart')
  +-- #123 -- duplicate function consolidation (DKuleshov already on it)
  +-- #101 -- workflow listing filter (kabaogluemre already on it)
  +-- #253 -- test coverage for critical MCP tools (already in review)
  +-- #173 -- framework file protection (already in review)
```

### Assignment rationale

| Person | Issues | Why |
|--------|--------|-----|
| **kabaogluemre** | #263, #241, #198, #239, #259, #101 | Built the task-runner engine. #241/#198/#239/#259 share the same root cause in ProductAPI.psm1. Already has PR #258 open for the overview fix. |
| **carlospedreira** | #135 | Already assigned and in progress. Platform/provider expertise. |
| **ProtonPump** | #213, #214 | Deep runtime/workflow knowledge. Both are task-runner resilience bugs — inverse of each other. One person should own the state-recovery logic. |
| **EnmaJim** | #256, #253 | Already working on tests (#267) and init scripts (#261). #256 is a task_gen validation fix. #253 extends test coverage. |
| **gmireles-ap** | #173 | Already has PR #260 open for framework file protection. Just needs to land it. |
| **DKuleshov** | #123 | Already assigned with PR #133 open. Module consolidation expertise. |

### Capacity

~10-13 dev-days total across 6 contributors. All issues are size S or XS. No scope blockers.

---

## Board updates applied

| Action | Detail |
|--------|--------|
| Priority field created | P0/P1/P2/P3/P4 — set on all 57 open issues |
| Size field populated | XS/S/M/L/XL — set on all 57 open issues |
| 14 missing issues added to board | #76, #90, #93, #94, #95, #96, #97, #98, #99, #184, #198, #204, #213, #214 |
| 27 null-status closed issues | Moved to Done |
| 22 Inbox items | Moved to Ready |
| 15 needs-triage labels | Removed |
| Sprint 1 fully assigned | 0 unassigned issues in Stabilize milestone |
