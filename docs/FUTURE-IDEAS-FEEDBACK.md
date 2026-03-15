# FUTURE IDEAS — User Feedback Analysis

> Synthesized from structured feedback sessions with 7 teams who used dotbot-v3 over a 3-day evaluation period. Names of companies, projects, internal systems, and individuals have been sanitized.

**Source:** `docs/dotbot-v3-feedback.html`
**Raw counts:** 34 bugs, 54 feature requests, 4 discussions, 1 aspirational

---

## 1. Already Implemented

These items were requested but already exist in the codebase. Teams may not have discovered them, or the features need better visibility/documentation.

| Requested Feature | Status | Evidence |
|---|---|---|
| Mermaid diagram support | Fully working | `mermaid-loader.js` + bundled Mermaid v10.9.0 with CRT theme integration |
| Philips Hue ambient light feedback | Fully working | `AetherAPI.psm1` + `aether.js` — SSDP/mDNS bridge discovery, registration, and status display |
| Task dependencies and priority | Data model complete | `task-create/metadata.yaml` defines `dependencies` array + `priority` (1-100). Roadmap UI visualizes dependency chains |
| Cross-platform support | CI-tested | `Platform-Functions.psm1` (Win/Mac/Linux detection), CI matrix across all three OS |
| Activity logging infrastructure | Core implemented | Per-process `.activity.jsonl` files, global `activity.jsonl`, `Write-ActivityLog` in `ClaudeCLI.psm1` |
| Project instruction file | Pattern exists | `CLAUDE.md` at repo root, read by Claude Code automatically. Profile `init.ps1` sets up IDE directories |
| Task editing in UI | Modal exists | `roadmap-task-actions.js` provides edit modal with priority, status, name, description, effort fields |

**Takeaway:** These features need better onboarding documentation or in-UI discoverability, not reimplementation.

---

## 2. Implemented But Buggy

These features exist in the codebase but users reported real issues with them. The infrastructure is there; the implementation needs hardening.

### 2.1 Responsive UI Layout

**Feedback:** Overview page collapses when browser is resized. Components lose vertical content (e.g., current task widget on overview screen) even on non-mobile screens.

**Codebase:** `responsive.css` has media queries at 1200px and 900px breakpoints with hamburger menu. The CSS exists but doesn't handle all viewport-component interactions correctly.

**Recommended fix:** Audit all dashboard widgets for `overflow: hidden` clipping and fixed-height containers that truncate content. Test at intermediate widths (1000-1200px) where the layout isn't fully collapsed but content areas shrink.

### 2.2 Whisper / Steering UI

**Feedback:** The whisper input is sometimes impossible to type into. Errors are subtle enough that spotting them is "largely luck." The value of the whisper approach itself was questioned.

**Codebase:** Full steering protocol exists — `steering-heartbeat` MCP tool, `.whisper.jsonl` files, `ProcessAPI.psm1` whisper endpoint, `steering.ps1` CLI. The backend is solid; the UI layer is unreliable.

**Recommended fix:** (1) Fix the whisper input rendering/focus bug. (2) Add prominent error banners when a running process encounters issues. (3) Consider a persistent "process health" indicator (green/amber/red) in the process list.

### 2.3 Rate Limit Recovery

**Feedback:** When token limits are hit, dotbot hangs and waits for timeout instead of retrying. Users had to stop and restart entirely.

**Codebase:** `rate-limit-handler.ps1` has `Wait-ForRateLimitReset` with countdown display and `Get-RateLimitResetTime` parsing. The handler exists but may not be catching all rate-limit response patterns, or the countdown UI isn't visible enough.

**Recommended fix:** (1) Verify the rate-limit regex catches all Claude API rate-limit messages. (2) Surface the countdown prominently in the web UI (currently only in terminal). (3) Add a manual "retry now" button in the UI.

### 2.4 Notification Dispatch Confirmation

**Feedback:** When questions are sent via Teams/email, there's no UI acknowledgement of what was sent, to whom, or when. No way to verify delivery.

**Codebase:** `NotificationClient.psm1` sends notifications and `NotificationPoller.psm1` polls for responses. Dispatch confirmation is logged in task metadata but not surfaced in the UI.

**Recommended fix:** Add a "Notifications" section to the task detail view showing: timestamp, channel, recipient, message content, delivery status.

### 2.5 Process Lifecycle & Orphan Cleanup

**Feedback:** PowerShell processes accumulate and cannot be safely cleaned up. No safe teardown mechanism. Failed processes disappear without trace.

**Codebase:** `ProcessAPI.psm1` has TTL-based cleanup (5-minute orphan removal) and dead-PID detection. But the cleanup may not be aggressive enough, and failed processes are removed too quickly before users can inspect them.

**Recommended fix:** (1) Keep failed processes visible for 24 hours (configurable TTL per status). (2) Add a "terminated" state that's visible but non-active. (3) Implement proper process tree termination (kill child processes when parent stops).

### 2.6 Task Re-prioritisation UX

**Feedback:** Need drag-and-drop reordering. Current mechanism not intuitive. Users can't force execution of a manually-created task mid-run.

**Codebase:** Priority field is editable in `roadmap-task-actions.js` modal (numeric input). `Update-TaskContent` in `TaskAPI.psm1` persists changes. No drag-and-drop.

**Recommended fix:** Implement drag-and-drop in the roadmap view. Auto-recalculate priority values when items are reordered. Add a "run next" quick action.

---

## 3. Bugs — Grouped by Theme

### 3.1 Silent Failures (Critical)

The most pervasive theme: dotbot fails without telling anyone.

| Bug | Impact | Reporters |
|---|---|---|
| **Failed tasks silently lost** — When a task fails mid-execution it disappears without trace. No error, no log entry, no way to find the failed process. | Users cannot diagnose or recover from failures | 3 teams |
| **Longer autonomous tasks show increasing silent failure rate** — Tasks requiring little user input fail at higher rates with no error surfaced. | Defeats the purpose of autonomous execution | 1 team |
| **Repeated API failures cause false "no remaining tasks"** — dotbot concludes the queue is empty instead of recognizing a connectivity issue. | Session terminates incorrectly | 1 team |
| **Open questions buried in output files** — Analysis produces MD files with unresolved questions, but never surfaces them to the user. | Users discover gaps only by reading raw output | 1 team |
| **Blocker questions raised after spec creation** — Clarifications surface after all documents are written, not during research. | 8 blockers discovered post-output, rendering the outputs questionable | 1 team |
| **Authentication failures on linked pages silent** — dotbot encounters auth errors (e.g., external wiki pages) but continues without the content. | Incomplete outputs with no warning | 1 team |
| **Push failures not surfaced** — Branch naming rules cause silent push rejection. Session continues without creating the PR. | Work appears complete but code never reaches the remote | 1 team |
| **Rate limiting handled opaquely** — External tool rate-limit responses are neither surfaced nor clearly retried. | Unclear whether outputs are complete or partial | 1 team |

**Pattern:** Dotbot defaults to "keep going" when it should default to "stop and tell the user." Every external interaction (API calls, git push, authentication, rate limits) needs explicit success/failure handling with UI notification.

### 3.2 State Management & Task Integrity

| Bug | Impact | Reporters |
|---|---|---|
| **New tasks silently dropped** — Tasks created by dotbot are not always registered in the queue. | Work planned but never executed | 3 teams |
| **Duplicate task submission** — Restarting dotbot on an existing project recreates tasks already present. | Duplicate work, confusion | 3 teams |
| **Checkbox marked complete while tasks in progress** — Task state transitions don't reflect actual completion. | False confidence in progress | 1 team |
| **Tasks JSON breaks under dotnet profile** — `ConvertFrom-Json` errors cause deadlock. Recovery options (resolve, discard, retry) all fail. | Complete session deadlock | 1 team |
| **MCP task creation lists incorrect categories** — The category list in the tool doesn't match valid values. | Miscategorised tasks | 1 team |

**Pattern:** Task state transitions need to be atomic, validated, and idempotent. Restart should detect existing tasks and resume, not recreate.

### 3.3 Git & Worktree Issues

| Bug | Impact | Reporters |
|---|---|---|
| **Implementation commits lost on worktree cleanup** — Commits not explicitly merged back are permanently lost. Task may report "done" while output no longer exists. | Data loss | 1 team |
| **Merge conflict during squash-merge creates unrecoverable loop** — All three recovery options (resolve, discard, rebase) fail. Manually added files get deleted by rebase. | Unrecoverable session state | 2 teams |
| **Hardcoded branch folder name** — `task/` prefix is hardcoded. Repos with strict naming rules reject the push silently. | Silent push failures | 1 team |
| **Scaffolding lands in root folder** — Path resolution falls back to root when no profile matches, polluting the project. | Messy project structure | 1 team |

**Pattern:** The worktree system is architecturally sound (isolation + squash-merge) but edge cases around merge conflicts, cleanup timing, and branch naming conventions need hardening. Consider: (1) never delete a worktree until merge is confirmed, (2) make branch prefix configurable, (3) verify push succeeded before cleaning up.

### 3.4 UI & UX Issues

| Bug | Impact | Reporters |
|---|---|---|
| **Process status unclear** — Users cannot tell if dotbot is running, stuck, waiting, or crashed. | Users guess at state | 2 teams |
| **UI shows incorrect active profile** — "DOTNET" displayed when project was initialized with "default". | Root cause of downstream JSON errors | 1 team |
| **Two concurrent sessions cause 100% resource usage** — No concurrency management or warning. | Both sessions blocked | 1 team |
| **Kickstart cannot be re-invoked** — One-shot operation with no way to restart. | Users stuck with bad initial grounding | 2 teams |
| **PS1 scripts fail on strict-mode machines** — System-level `Set-StrictMode` causes property-access errors in dotbot scripts. | Installation failures on certain machines | 1 team |

### 3.5 Scope & Context Issues

| Bug | Impact | Reporters |
|---|---|---|
| **Requirements silently missed or ignored** — Profile files, source documents, and stated requirements skipped with no acknowledgment. | Partial outputs, rework | 4 teams |
| **File upload causes misinterpretation** — Attached files confuse the model instead of grounding it. | Counterproductive input | 1 team |
| **Confluence/Jira attachment reading fails** — PDFs, Excel, screenshots, images not processed from attached items. | Requirements missed even when accessible | 2 teams |
| **Scope boundary violated** — dotbot drifts into linked business specs it was told to ignore. | Work on wrong scope | 1 team |
| **Outputs not scoped to the organization** — Generated content includes generic or all-company data instead of organization-specific figures. | Misleading outputs | 1 team |
| **Profile file ignored during parallel work** — Profile constraints dropped when dotbot works on multiple things simultaneously. | Inconsistent behavior | 1 team |
| **Repository naming mismatch** — Business names don't match DevOps identifiers. Dotbot cannot bridge the gap. | Wrong repo selected | 3 teams |
| **Jira MCP assumes default fields** — Custom Jira field configurations cause silent failures. Permission failures not surfaced. | Malformed tickets, silent failures | 2 teams |

**Pattern:** Dotbot needs stronger input validation, explicit confirmation of what it understood, and strict scope boundaries. A pre-execution summary ("I will work on X using repos Y and Z, ignoring A") would catch most of these issues.

---

## 4. Feature Requests — Grouped by Theme

### 4.1 Workflow Control & Flexibility

| Feature | Description | Reporter Count |
|---|---|---|
| **Configurable human revision gates** | Pause-and-review points at key stages (before research, before repo selection, before execution). Users review and approve before dotbot continues. | 1 |
| **Make workflow steps optional** | Not every project needs every step. Research should be skippable. Forced steps slow teams unnecessarily. | 2 |
| **Research phase before task creation** | Explicit "Idea → Assessment" step before execution begins. Research should happen upfront, not as a side-effect mid-run. | 2 |
| **Functional spec before technical spec** | Functional requirements should be challenged and finalized before technical design begins. Currently conflated into one pass. | 3 |
| **Pre-defined task queues** | Allow subtasks and dependencies to be defined upfront so execution proceeds without mid-run task creation. | 1 |
| **Kickstart re-invocable** | Allow re-running the kickstart step to re-ground a session when initial setup was wrong. | 2 |
| **Context window management** | Phase 1: visible token counter in UI. Phase 2: automatic task splitting when context limit is approaching, rebase to last commit and continue cleanly. | 1 |

### 4.2 Collaboration & Multi-User

| Feature | Description | Reporter Count |
|---|---|---|
| **Shared / collaborative sessions** | Multiple SMEs contribute simultaneously to a single dotbot session. | 1 |
| **Chat with dotbot during execution** | Mid-execution dialogue for course corrections without stopping the session. | 1 |
| **Route questions to predefined contacts** | Contact directory organized by subject area. Auto-route questions to the right SME via Teams/email with context links. | 1 |
| **Well-defined team roles** | Explicit role definitions within dotbot with consistency controls over who can influence outputs. | 2 |

### 4.3 External Integrations

| Feature | Description | Reporter Count |
|---|---|---|
| **Figma MCP integration** | Connect to Figma for design-driven workflows where visual specs are the source of truth. | 2 |
| **Symbol extraction (Serena MCP)** | Structured code symbol access for large codebases without full scanning. | 2 |
| **Read-only external data sources** | Connect to databases for data-grounded analysis instead of relying solely on documentation. | 1 |
| **Quality gate integration (SonarQube)** | Auto-read quality gate failures from PRs and create fix tasks without manual intervention. | 1 |
| **Azure DevOps branch rule discovery** | Pull branching policies from ADO at session start. Apply repo-specific naming rules instead of hardcoded patterns. | 1 |
| **PR review loop** | Read reviewer comments → apply changes → update PR. Repeatable cycle. Manual PR update trigger as escape hatch. | 2 |
| **Jira ticket overlap detection** | Identify when proposed tickets duplicate existing ones. Surface to PM before creation. | 1 |
| **Store prompts on Jira tickets** | Dedicated area on business spec tickets for the dotbot prompt and attachments as canonical kickstart input. | 1 |
| **Evaluate Jira ticket age/relevancy** | Assess whether a ticket's content is still current before treating it as a source of truth. | 1 |

### 4.4 UI & Task Management

| Feature | Description | Reporter Count |
|---|---|---|
| **Kanban board for roadmap** | Replace current roadmap layout with columns (backlog, in-progress, done) and drag-and-drop cards. | 1 |
| **Drag-and-drop task reordering** | Intuitive priority adjustment by dragging tasks in the backlog. | 2 |
| **Show token/cost estimate per task** | Display estimated tokens and USD per task, not just t-shirt sizing. | 1 |
| **Show task execution dependencies** | Surface priority and dependency order clearly so users understand the real execution sequence. | 1 |
| **Comprehensive logging in UI** | All errors, state transitions, decisions, and task updates visible. Failed processes visible in process list. | 5 |
| **Attach files to tasks** | Add specs, references, and assets to tasks at creation time. Critical for mid-run context updates. | 2 |
| **Embedded prompt writing assistant** | Inline guidance or assistant to help users write effective inputs. | 1 |
| **Documented image ingestion method** | Clear, supported path for providing images as input with format/resolution guidance. | 1 |
| **Name generated files by content** | Output files should have meaningful names reflecting their content, not generic defaults. | 1 |

### 4.5 Enterprise & Scale

| Feature | Description | Reporter Count |
|---|---|---|
| **Server-hosted dotbot instances** | Central server deployment with root index page listing all running/completed instances. Multi-user access. Container/app-service scaling. | 1 |
| **Central shared code repository** | Single local clone shared across all dotbot instances instead of per-project full clones. | 1 |
| **Shared configuration space** | Cross-project config (keys, roles, environment definitions) referenced from a central location. | 2 |
| **Dedicated service account for Jira** | Pre-configured permissions. Permissions pre-check at session start. | 1 |
| **Approved technology stack reference** | Predefined tech stack that dotbot consults. Flag suggestions outside the stack. Override requires warning. Extends to visual/style guidelines. | 1 |
| **Approved document templates** | Central template repository for specs, HLDs, LLDs. Dotbot applies templates rather than generating structure ad-hoc. | 1 |
| **Upfront repository declaration** | Explicit repo selection at session start, honored throughout. Component mappings from project management tools to help auto-identify repos. | 4 |
| **Controlled external publishing** | Publishing to project management tools should be deliberate and user-triggered, not automatic. Human review gate before creation. | 2 |

### 4.6 Content Quality & Intelligence

| Feature | Description | Reporter Count |
|---|---|---|
| **Source references with links** | Inline citations in all generated documents. Each claim references its source with a link where available. | 1 |
| **Avoid unexplained acronyms** | Spell out terms by default. Only use acronyms when universally understood. | 2 |
| **Use real-world data, not placeholders** | Concrete, contextually plausible values instead of generic placeholders. | 2 |
| **Read all attachments before asking questions** | Consume all inputs before starting Q&A to avoid redundant questions. | 2 |
| **Ask the right clarifying question** | Identify the single critical blocker and ask it directly, instead of flooding with derivative questions. | 2 |
| **Self-improvement logging** | Log every question asked, answer received, and decision made. Transparency trail for review and future improvement. | 2 |
| **MFA / external auth stub mechanism** | Dummy implementations for MFA and external system interactions so dotbot can work around them. | 3 |
| **Pre-analyse project dependencies** | Scan for dependency conflicts (e.g., mismatched framework versions) before execution begins. | 1 |
| **Technology decision research workflow** | Dedicated workflow for tech decisions that references the organization's existing stack. | 1 |
| **Task-first architecture** | Restructure around task categories (research, spec, implementation) with per-category model selection and tool preloading. | 1 |
| **Repository description file** | Instruction file in each repo describing what it is, technologies used, and known aliases. Bridges business-name/DevOps-name mismatch. | 3 |

---

## 5. Discussions & Strategic Insights

### 5.1 Prompt Review Action

Multiple teams independently observed dotbot missing requirements, burying open questions, and producing incomplete outputs. A systematic review of all dotbot prompts is recommended — checking for gaps, ambiguous instructions, and missing guardrails. This is a high-leverage action that could address many bugs simultaneously.

### 5.2 Cross-Functional Sessions Produce Better Outcomes

Running dotbot sessions with cross-functional teams present (rather than individuals working alone) was notably more productive. This validates the collaborative session feature request and suggests that dotbot's interaction model should actively support multiple participants.

### 5.3 External Data Source Differentiation

Teams raised questions about how dotbot should handle and differentiate between multiple internal data sources. This requires per-project configuration that maps data source names to connection details and access patterns.

---

## 6. Prioritization

### Tier 1 — Fix Now (reliability foundation)

These issues undermine trust and must be resolved before any feature work.

| Item | Category | Why |
|---|---|---|
| Silent failure elimination | Bug | 4+ teams hit this. Every external call needs success/fail handling with UI notification. |
| Failed processes must stay visible | Bug | Users cannot diagnose issues if evidence disappears. |
| Task creation idempotency | Bug | Duplicate tasks on restart breaks core workflow. |
| Worktree merge safety | Bug | Never delete worktree until merge is confirmed. |
| Process status clarity | Bug | Unambiguous running/stuck/crashed indicator needed. |
| Whisper input fix | Bug | Steering UI must be reliable or it's worse than not having it. |
| Comprehensive logging in UI | Feature | Most bugs would be self-diagnosing with proper logs. |

### Tier 2 — High Impact (workflow effectiveness)

| Item | Category | Why |
|---|---|---|
| Configurable human revision gates | Feature | Gives teams control over the review cadence. |
| Attach files to tasks | Feature | Major blocker for mid-session context updates. |
| Ask the right clarifying question | Feature | Reduces question cascades and user fatigue. |
| Pre-execution scope confirmation | Feature | "I will work on X using Y" prevents most scope bugs. |
| Kanban board with drag-and-drop | Feature | Most-requested UI improvement across teams. |
| Read all inputs before asking questions | Feature | Eliminates redundant Q&A. |
| Functional-first spec ordering | Feature | Improves output quality for document generation. |

### Tier 3 — Strategic (scale and enterprise)

| Item | Category | Why |
|---|---|---|
| Server-hosted instances | Feature | Removes single-machine bottleneck. |
| Shared / collaborative sessions | Feature | Validates cross-functional session finding. |
| Figma MCP + Serena MCP | Feature | Expands addressable workflow space. |
| PR review loop | Feature | Closes the development feedback cycle. |
| Quality gate integration | Feature | Closes the CI/CD feedback cycle. |
| Approved templates & tech stack | Feature | Enterprise consistency at scale. |
| Task-first architecture with per-category models | Feature | Cost optimization and capability targeting. |
| Context window management | Feature | Prevents the most frustrating class of mid-task failures. |

---

## 7. Key Patterns Across All Feedback

1. **"Silent" is the most dangerous word.** Silent failures, silent drops, silent scope changes, silent push failures. The #1 improvement is making dotbot loud about problems.

2. **The two-phase model works, but gates are missing.** Users want checkpoints between phases where they can review, edit, and approve before dotbot continues. The analysis → execution split is right; it just needs more user control points.

3. **Input handling is the weakest link.** Attachments, images, Confluence files, uploaded documents — dotbot struggles with multi-modal input. Strengthening the input pipeline would resolve many reported "missed requirements" bugs.

4. **Teams want collaboration, not just monitoring.** The dashboard is a good start, but teams need shared sessions, role-based access, and multi-SME input workflows.

5. **Scope discipline is critical.** Dotbot needs explicit scope boundaries (which repos, which specs, which data sources) declared upfront and enforced throughout.
