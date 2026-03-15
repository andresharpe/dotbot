# FUTURE IDEAS — dotbot-v3

> Architecture analysis and strategic ideas for making dotbot invaluable to teams of all sizes.

---

## 1. Architecture Overview

dotbot-v3 is a **structured AI-assisted development framework** built entirely in PowerShell 7+. It wraps AI coding workflows in managed, auditable processes with two-phase execution, per-task git isolation, and a web dashboard for monitoring.

```
┌─────────────────────────────────────────────────────────────┐
│                        dotbot-v3                            │
│                                                             │
│  ┌──────────┐   ┌──────────┐   ┌──────────────────────┐    │
│  │ MCP      │   │ Web UI   │   │ Runtime              │    │
│  │ Server   │   │ Server   │   │                      │    │
│  │          │   │          │   │  launch-process.ps1   │    │
│  │ 26 tools │   │ 8 API    │   │  WorktreeManager     │    │
│  │ auto-    │   │ modules  │   │  ProviderCLI          │    │
│  │ discover │   │ 22 JS    │   │  (Claude/Codex/       │    │
│  │          │   │ modules  │   │   Gemini)             │    │
│  └────┬─────┘   └────┬─────┘   └──────────┬───────────┘    │
│       │              │                     │                │
│  ┌────┴──────────────┴─────────────────────┴──────────┐     │
│  │              Shared State Layer                     │    │
│  │  .bot/.control/  (runtime state, process registry)  │    │
│  │  .bot/workspace/ (tasks, product docs, roadmap)     │    │
│  │  .bot/defaults/  (settings, provider configs)       │    │
│  └────────────────────────────────────────────────────┘     │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Profile & Overlay System                │   │
│  │  default ──► dotnet ──► dotnet-blazor / dotnet-ef    │   │
│  │  default ──► kickstart-via-jira                      │   │
│  │  default ──► kickstart-via-pr                        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Workflow Engine                          │   │
│  │  Analysis (98) ──► Execution (99)                    │   │
│  │  Steering protocol (whisper interrupts)               │   │
│  │  Agents: planner / tester / implementer / reviewer   │   │
│  │  Skills: write-unit-tests, verify, status, etc.      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              External Integrations                   │   │
│  │  Mothership (Teams bot)  │  Atlassian MCP            │   │
│  │  GitHub / Azure DevOps   │  Verification hooks       │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Component Map

### 2.1 MCP Server (`systems/mcp/`)

Pure PowerShell MCP server using stdio transport (protocol 2024-11-05). Tools auto-discovered from `tools/{name}/` subdirectories.

| Category | Tools |
|----------|-------|
| **Task Management** | `task_create`, `task_create_bulk`, `task_list`, `task_get_next`, `task_get_context`, `task_get_stats` |
| **Task Lifecycle** | `task_mark_analysing`, `task_mark_analysed`, `task_mark_in_progress`, `task_mark_done`, `task_mark_needs_input`, `task_mark_skipped`, `task_mark_todo` |
| **Task Interaction** | `task_answer_question`, `task_approve_split` |
| **Session** | `session_initialize`, `session_get_state`, `session_get_stats`, `session_update`, `session_increment_completed` |
| **Planning** | `plan_create`, `plan_get`, `plan_update` |
| **Dev Environment** | `dev_start`, `dev_stop` |
| **Steering** | `steering_heartbeat` |

### 2.2 Web UI (`systems/ui/`)

Pure PowerShell HTTP server with vanilla JS frontend.

**Backend API modules:** StateBuilder, TaskAPI, ProcessAPI, ProductAPI, ControlAPI, GitAPI, SettingsAPI, NotificationPoller, FileWatcher, ReferenceCache

**Frontend modules (22):** tabs, sidebar, tasks, processes, product, workflow, roadmap-task-actions, kickstart, editor, activity, notifications, actions, controls, polling, ui-updates, theme, icons, utils, markdown, mermaid-loader, config, aether

**Dashboard tabs:** Overview, Product, Workflow, Processes, Settings, Roadmap

### 2.3 Runtime (`systems/runtime/`)

- **launch-process.ps1** — Unified entry point for all Claude invocations. Process types: `analysis`, `execution`, `workflow`, `kickstart`, `planning`, `commit`, `task-creation`
- **WorktreeManager.psm1** — Git worktree lifecycle: create branch + worktree per task, junction shared infrastructure (.bot), squash-merge on completion
- **ProviderCLI.psm1** — Provider-agnostic CLI abstraction with parsers for Claude, Codex, and Gemini streams
- **ClaudeCLI.psm1** — Claude-specific CLI wrapper
- Supporting modules: prompt-builder, rate-limit-handler, ui-rendering, DotBotTheme, InstanceId, cleanup, test-task-completion, get-failure-reason, create-problem-log, task-reset

### 2.4 Workflow Engine (`prompts/workflows/`)

**Two-phase execution:**
1. **Analysis** (`98-analyse-task.md`) — Read-only exploration on main branch. Identifies affected entities, discovers files, validates dependencies, maps standards, creates implementation guidance. May propose task splits or ask clarifying questions.
2. **Execution** (`99-autonomous-task.md`) — Implementation in isolated worktree. Consumes pre-built analysis context, writes code, runs tests, commits with `[task:XXXXXXXX]` tag.

**Kickstart workflows** — Multi-phase project initialization: interview → product docs → task group planning → task expansion

### 2.5 Agent System (`prompts/agents/`)

| Agent | Role | Model |
|-------|------|-------|
| **Planner** | Requirements interviews, task decomposition, effort estimation | Opus |
| **Tester** | Write failing tests first (TDD red phase) | Opus |
| **Implementer** | Write production code to make tests pass (TDD green phase) | Opus |
| **Reviewer** | Code review for quality, security, patterns | Opus |

### 2.6 Profile System (`profiles/`)

- **default** — Base profile: all 26 MCP tools, 4 agents, core workflows, verification hooks, web UI
- **dotnet** — Stack overlay: dev lifecycle (Start-Dev/Stop-Dev with layout management), additional tools (dev-deploy, dev-db, dev-logs, dev-release, prod-start, prod-stop), 7 skills (entity-design, create-migration, implement-api-endpoint, etc.), verification (dotnet-build, dotnet-format)
- **dotnet-blazor** — Adds blazor-component-design skill
- **dotnet-ef** — Entity Framework specialization
- **kickstart-via-jira** — Workflow profile: Atlassian research pipeline with Jira/Confluence integration, 13+ workflow phases, custom tools (atlassian-download, repo-list, repo-clone, research-status)
- **kickstart-via-pr** — Workflow profile: kickstart from GitHub/Azure DevOps pull requests

### 2.7 Hooks (`hooks/`)

- **dev/** — `Start-Dev.ps1`, `Stop-Dev.ps1` for dev environment lifecycle
- **verify/** — Numbered verification chain: `00-privacy-scan.ps1` (secrets/PII detection), `01-git-clean.ps1`, `02-git-pushed.ps1`, plus profile-specific (dotnet-build, dotnet-format)
- **scripts/** — `commit-bot-state.ps1` (workspace state commits), `steering.ps1` (whisper/watch/abort/history), `audit-orphaned-files.ps1`

### 2.8 External Integrations

- **Mothership** (`server/`) — Teams bot (C#/.NET 9, M365 Agents SDK) for sending questions as Adaptive Cards and receiving answers. Deployed to Azure App Service.
- **NotificationPoller** — Background poller checking mothership for external responses to needs-input tasks
- **Atlassian MCP** — Jira issue resolution, Confluence page fetching for kickstart workflows

---

## 3. Future Ideas

### 3.1 Multi-Agent Orchestration

> Current state: Tasks execute sequentially — one analysis or execution at a time per session.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Parallel task execution** | Run multiple analysis/execution processes concurrently across worktrees. Each already has git isolation — the infrastructure is ready. Rate-limit aware scheduling with configurable concurrency. | Large teams: 3-5x throughput on backlogs. Solo devs: background analysis while executing another task. |
| **Agent pipeline composition** | Let users define custom agent chains beyond the fixed planner→tester→implementer→reviewer sequence. E.g., `researcher→architect→implementer→security-reviewer`. | Enables domain-specific workflows without forking core code. |
| **Cross-task awareness** | When multiple tasks touch the same files, the orchestrator detects conflicts early, sequences dependent work, and merges results intelligently. | Eliminates merge hell on large feature pushes. Critical for teams with 10+ concurrent tasks. |
| **Agent delegation** | During execution, an agent can spawn sub-agents for specific subtasks (e.g., "write the migration" → delegate to a migration specialist). Uses the existing MCP tool infrastructure. | More reliable output on complex tasks that span multiple domains. |
| **Warm context pools** | Keep recently-used codebase context in memory across task boundaries. Analysis results from Task A's context package can be reused by Task B if they touch overlapping files. | Reduces AI cost per task by 30-50% on related work. |

### 3.2 Team Collaboration

> Current state: Single-operator model. One person watches the dashboard and sends steering whispers.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Multi-user dashboard** | WebSocket-based real-time state sync. Multiple team members see the same dashboard, can claim tasks, send whispers, and answer questions. Presence indicators show who's watching. | Essential for teams > 3 people. Turns dotbot from a solo tool into team infrastructure. |
| **Role-based access** | Define roles: operator (full control), developer (can answer questions, view progress), viewer (read-only dashboard). Map to team members. | Enterprise adoption requirement. Prevents accidental `abort` from junior team members. |
| **Task ownership** | Assign tasks to specific team members. The assignee gets priority notifications and can provide domain-specific answers to needs-input questions. | Aligns AI work with human expertise. The person who knows the payment system answers payment questions. |
| **Shared whisper log** | All steering interactions (whispers, aborts, answers) are visible to the team with timestamps and attribution. Searchable history. | Audit trail for team decisions. New team members can learn from past steering patterns. |
| **Conflict resolution UI** | When parallel tasks create merge conflicts, present a visual diff in the dashboard with options: auto-resolve, manual merge, or requeue one task. | Removes the #1 friction point of parallel AI development. |

### 3.3 Intelligence & Learning

> Current state: Each task starts fresh. No memory of past successes/failures or codebase patterns.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Codebase pattern memory** | After successful task completion, extract and store patterns: file organization, naming conventions, common imports, test patterns. Feed these into future analysis phases. | Quality improves over time. Task #50 produces more consistent code than Task #1. |
| **Task estimation from history** | Track actual effort (tokens, time, retries) per task category/effort level. Use this to refine future estimates and flag outliers. | Accurate sprint planning. "Our M-effort tasks average 45 minutes and $0.80 in AI cost." |
| **Failure analysis engine** | When tasks fail (tests don't pass, verification hooks fail), classify the failure, store the pattern, and inject preventive guidance into future analysis prompts for similar tasks. | Stops the same mistakes from recurring. Especially valuable for team-wide anti-patterns. |
| **Smart task splitting** | Use historical data on task completion rates by effort size to recommend optimal task granularity. Auto-split XL tasks using patterns from past successful splits. | Reduces the #1 cause of task failure: scope too large. |
| **Code review learning** | When the reviewer agent flags issues, track which issues get fixed vs. dismissed. Weight future reviews toward issues that matter to this team. | Reviewer feedback converges to team preferences over time. |
| **Project knowledge graph** | Build and maintain a semantic graph of the codebase: entities, relationships, API surfaces, test coverage, dependency chains. Use during analysis to provide richer context. | Dramatically improves analysis quality for large codebases (100k+ LOC). |

### 3.4 Integration Ecosystem

> Current state: Claude/Codex/Gemini providers, Teams bot, Atlassian MCP, GitHub/ADO for PRs.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Slack/Discord notifications** | Channel-based notifications for task completion, needs-input questions, and failure alerts. Threaded replies feed back as answers. | Meets teams where they already communicate. Lower friction than Teams for many startups. |
| **CI/CD pipeline integration** | After task completion and merge, automatically trigger CI. Watch for failures and create fix tasks. Close the loop: task → code → merge → CI → fix task if needed. | Full autonomous cycle. The AI doesn't just write code — it ensures it ships. |
| **IDE extensions** | VS Code / JetBrains plugins that show dotbot task status, allow answering questions inline, and provide one-click "create task from selection." | Developer never leaves their editor. Task creation friction drops to near zero. |
| **GitHub Issues/Projects sync** | Two-way sync between dotbot tasks and GitHub Issues. Status changes reflect in both. Labels, milestones, and project boards stay current. | Teams using GitHub for planning get AI execution without changing their workflow. |
| **Linear/Shortcut/Asana adapters** | Same two-way sync pattern but for other popular PM tools. Profile-based: `kickstart-via-linear`, etc. | Broadens addressable market dramatically. Every PM tool becomes a dotbot front-end. |
| **PR auto-creation** | After squash-merge to main, optionally create a PR instead for human review before merging to the default branch. Include analysis context, test results, and diff summary. | Teams that require PR reviews get them automatically. Bridges AI speed with human oversight. |
| **Webhook system** | Expose configurable webhooks for task lifecycle events. Teams can integrate with any internal tool: Datadog, PagerDuty, custom dashboards. | Enterprise integration story. "When a task fails, page the on-call engineer." |

### 3.5 Enterprise & Governance

> Current state: Single-machine, single-operator. No audit trail beyond git history. Cost tracking in settings but not enforced.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Budget controls** | Set daily/weekly/monthly AI spend caps. Alert at 80%, pause at 100%. Track cost per task, per category, per team member. | CFO-friendly. "We spent $340 on AI this sprint across 47 tasks." |
| **Approval workflows** | Configurable gates: "Tasks in category `security` require human approval before execution." "XL tasks need architect sign-off after analysis." | Compliance requirement for regulated industries (finance, healthcare). |
| **Audit log** | Immutable log of all actions: task creation, state changes, whispers, answers, merges, process starts/stops. Exportable for compliance. | SOC 2 and ISO 27001 readiness. Required for enterprise sales. |
| **Multi-project orchestration** | Manage multiple repositories from a single dashboard. Cross-repo task dependencies. Shared knowledge graph across projects. | Large teams (20+) working across microservices need this. |
| **SSO integration** | Support SAML/OIDC for dashboard authentication. Map enterprise groups to dotbot roles. | Enterprise table-stakes. No SSO = no procurement approval. |
| **Policy engine** | Define rules like "never modify files matching `*.secrets.*`", "always run security scan on tasks touching auth/", "require two whisper approvals for production deployments." | Guardrails that scale with team size. Trust the AI more because the policy catches mistakes. |
| **Air-gapped mode** | Support for environments without internet access. Local model endpoints, no external telemetry, self-contained profile packages. | Government, defense, and finance sectors. Significant market. |

### 3.6 Observability & Analytics

> Current state: Session stats via MCP tool. Basic process status in dashboard. Cost estimates in settings.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **AI cost dashboard** | Real-time token usage and cost per task, session, day, week. Breakdown by model (Opus vs Sonnet vs Haiku). Historical trends and forecasting. | Solo devs: "Am I spending wisely?" Large teams: "Which task categories cost the most?" |
| **Velocity metrics** | Tasks completed per day/week. Average time analysis→done. First-pass success rate (no retries). Trend lines over time. | Sprint retrospectives with data. "We're completing 12 tasks/day, up from 8 last month." |
| **Quality dashboard** | Track verification hook pass rates, reviewer findings per task, post-merge CI success rate. Correlate with task attributes (category, effort, complexity). | Identify systemic quality issues. "Infrastructure tasks have 40% first-pass CI failure — we need better test guidance." |
| **Token efficiency tracking** | Measure tokens used in analysis vs. execution. Identify tasks where analysis context was underutilized or where execution ran into unnecessary exploration. | Optimize the two-phase split. "Tasks with thorough analysis use 60% fewer execution tokens." |
| **Process timeline visualization** | Gantt-style view of all processes: when they started, how long each phase took, where they waited (needs-input, rate-limited). | Identify bottlenecks. "Tasks wait an average of 2 hours for human input. Can we pre-answer common questions?" |
| **Exportable reports** | Generate weekly/monthly PDF or HTML reports: work completed, costs, quality metrics, team velocity. Shareable with stakeholders. | Manager-friendly output. "Here's what the AI team accomplished this sprint." |

### 3.7 Developer Experience

> Current state: CLI-first (`dotbot init`), web dashboard, MCP tools in prompts.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Natural language task creation** | "Add pagination to the users endpoint" → auto-generates task with category, priority, effort estimate, acceptance criteria, and applicable standards. | Task creation in 5 seconds instead of 5 minutes. Lower barrier to entry. |
| **Interactive kickstart wizard** | Terminal-based interactive setup: pick profile, configure provider, set team preferences, connect integrations. Visual progress through phases. | First-run experience that builds confidence. Currently requires reading docs. |
| **Task templates** | Pre-built task structures for common work: "add API endpoint", "fix bug", "add database migration", "refactor module". Auto-populate steps and acceptance criteria. | Consistency across team members. Junior developers produce senior-quality task specs. |
| **Smart defaults from codebase** | Scan the repository during `dotbot init` to auto-detect: language/framework, test runner, build system, CI provider. Pre-configure the profile accordingly. | Zero-config for common stacks. `dotbot init` on a Next.js project just works. |
| **Hot-reload profiles** | Change profile settings, add skills, modify workflows without restarting processes. File watcher already exists in the UI — extend to profiles. | Iterate on workflows without losing in-flight work. |
| **Task preview/dry-run** | Before executing, show exactly what the AI plans to do: files to modify, tests to write, estimated scope. Human can approve, modify, or cancel. | Builds trust. Especially valuable when onboarding new team members to dotbot. |
| **Conversational steering** | Instead of terse whispers, support multi-turn conversations with running processes. "Why did you choose that approach?" → AI explains → "Try the factory pattern instead." | More nuanced human-AI collaboration during execution. |

### 3.8 Autonomous Capabilities

> Current state: Two-phase execution with steering. Processes can continue automatically through task queues.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Self-healing pipelines** | When a task fails verification, automatically create a fix task, analyze the failure, and re-execute. Configurable retry depth (default: 1). | Overnight runs that self-correct. Come back in the morning to merged PRs, not failed tasks. |
| **Proactive task creation** | During analysis, if the AI discovers tech debt, missing tests, or security issues unrelated to the current task, create follow-up tasks automatically (tagged `ai-discovered`). | Continuous codebase improvement. The AI becomes a team member who notices things. |
| **Adaptive workflow selection** | Based on task attributes and historical success rates, automatically choose the best workflow variant. Simple bug fix? Skip analysis. Complex feature? Add an extra review phase. | Right-sized process per task. No overhead on trivial fixes, no shortcuts on critical features. |
| **Dependency-aware scheduling** | Respect task dependency chains automatically. When Task A completes, check if Task B's dependencies are now met and auto-queue it. | Unattended multi-task pipelines. "Execute the entire roadmap in dependency order." |
| **Confidence scoring** | After execution, the AI rates its confidence in the implementation (0-100). Low-confidence tasks get flagged for human review. High-confidence tasks auto-merge. | Focus human attention where it matters most. Review 5 tasks instead of 50. |
| **Multi-repo coordination** | For microservice architectures, execute related tasks across repos in the right order. API contract change → server update → client update → integration test. | The only way to do cross-repo AI work reliably at scale. |

### 3.9 Quality & Safety

> Current state: Privacy scan, git clean/pushed checks, profile-specific build/format verification. TDD-oriented agents.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Diff review gate** | After execution, before merge, run an automated review pass that checks: no unintended file changes, no security regressions, test coverage didn't decrease, no TODO/FIXME added without task reference. | Safety net for autonomous execution. Catches the "technically works but shouldn't merge" cases. |
| **Rollback automation** | If post-merge CI fails, automatically revert the squash-merge commit and create a fix task with CI failure context. | Zero-downtime guarantee. AI mistakes don't break main. |
| **Dependency impact analysis** | Before modifying a file, analyze all dependents (importers, callers, tests). Include impact radius in analysis context. Warn on high-impact changes. | Prevents cascade failures. "This utility function is used by 47 files — proceed carefully." |
| **Security scanning integration** | Run SAST/DAST tools (Semgrep, Snyk, Trivy) as verification hooks. Block merges with critical findings. Auto-create fix tasks for new vulnerabilities. | Security-first AI development. Especially important for teams without dedicated security engineers. |
| **Test coverage enforcement** | Track coverage per task. If a task reduces coverage, flag it. Optionally require coverage to increase on feature tasks. | Prevents the common pattern of "AI wrote code but skipped edge case tests." |
| **Deterministic verification** | Record the exact verification hook results for each task. On re-execution (retry/fix), compare results to ensure regression-free. | Confidence that fixes don't introduce new problems. |

### 3.10 Profile Marketplace & Community

> Current state: 6 profiles (default, dotnet, dotnet-blazor, dotnet-ef, kickstart-via-jira, kickstart-via-pr). Profiles are directories in the repo.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Community profile registry** | Publish and discover profiles: `dotbot profile install react-nextjs`. Versioned, with compatibility metadata. | Any team using any stack gets dotbot value on day one. Exponential adoption potential. |
| **Skill marketplace** | Share individual skills (like npm packages): `dotbot skill install write-playwright-tests`. Skills declare their dependencies and compatible profiles. | Modular capability expansion. Teams build once, the community benefits. |
| **Profile composition** | Layer multiple overlays: `default + python + fastapi + aws-lambda`. Resolve conflicts automatically. Currently limited to one stack overlay. | Real-world projects aren't single-stack. A Python+React project needs both profiles. |
| **Custom workflow templates** | Share workflow definitions: "Our 5-phase enterprise workflow with security review and architecture approval." Others can adopt and adapt. | Best practices spread organically across teams. |
| **Profile testing framework** | Test profiles in isolation: does the tool discovery work? Do verification hooks run correctly? Are skills properly formatted? | Profile authors ship with confidence. Reduces broken installs. |
| **Organization-private registry** | Enterprise version of the marketplace: share profiles within the org only. Central management of approved workflows and skills. | Large orgs standardize AI development practices across teams without public exposure. |

### 3.11 Advanced Kickstart & Onboarding

> Current state: Kickstart workflows for new projects (interview → product docs → task groups → task expansion). Jira and PR-based variants.

| Idea | Description | Team Impact |
|------|-------------|-------------|
| **Codebase migration kickstart** | Point dotbot at an existing legacy codebase. It analyzes the architecture, creates a migration roadmap, and generates tasks for modernization. | Massive value for teams inheriting legacy systems. "Migrate this VB.NET monolith to .NET 8 microservices." |
| **Design doc → tasks** | Upload a design document (RFC, PRD, technical spec). AI reads it, creates the entity model, identifies work items, and generates a prioritized task backlog. | Bridges the gap between planning and execution. PMs write docs, AI creates tasks. |
| **Repository onboarding** | New team member runs `dotbot onboard`. AI analyzes the repo, generates an architecture guide, explains key patterns, and creates a "starter tasks" list. | New developer productive in hours instead of weeks. |
| **Competitive analysis kickstart** | Given a competitor product or open-source project, analyze its architecture and generate a task roadmap for building a competitive alternative. | Strategic planning powered by AI. "Build something like Stripe's billing API." |
| **Multi-repo initiative planning** | Kickstart an initiative that spans multiple repositories. AI understands cross-repo dependencies and creates coordinated task lists. | Essential for microservice teams starting large initiatives. |

---

## 4. Prioritization Framework

Ideas above can be evaluated on two axes:

| | Small Teams (1-5) | Large Teams (10+) |
|---|---|---|
| **High impact, low effort** | Natural language task creation, Smart defaults from codebase, Self-healing pipelines, PR auto-creation | Multi-user dashboard, Budget controls, GitHub Issues sync |
| **High impact, high effort** | Parallel task execution, Codebase pattern memory, CI/CD integration | Role-based access, Audit log, Multi-project orchestration, Policy engine |
| **Force multipliers** | Confidence scoring, Task templates, Conversational steering | Profile marketplace, Cross-task awareness, Exportable reports |

### Suggested Phase 1 (Foundation)
1. Parallel task execution (infrastructure already exists via worktrees)
2. Multi-user dashboard (WebSocket upgrade to existing UI)
3. AI cost dashboard (extend existing session stats)
4. PR auto-creation (natural extension of squash-merge flow)
5. Natural language task creation (wrapper around existing task_create)

### Suggested Phase 2 (Intelligence)
1. Codebase pattern memory
2. Failure analysis engine
3. Task estimation from history
4. CI/CD pipeline integration
5. Self-healing pipelines

### Suggested Phase 3 (Scale)
1. Community profile registry
2. Multi-project orchestration
3. Budget controls and approval workflows
4. Audit log
5. IDE extensions
