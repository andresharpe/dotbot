# PRD-030: Lean Workflow Runtime

## Problem

Dotbot workflows currently pay a high coordination cost for every AI-backed task. A prompt task normally runs as:

1. Create or repair a task worktree.
2. Launch an analysis provider session.
3. Ask the model to inspect the repo and write `extensions.analysis`.
4. Close that provider session.
5. Launch a second execution provider session.
6. Ask the model to reload the task context, implement, test, commit, and mark done.
7. Run post-task checks, squash-merge, update task state, and clean the worktree.

This preserves auditability and human-in-the-loop control, but it is slow. The framework repeatedly starts provider sessions, reloads MCP schemas, replays context through task JSON, and asks one model run to prepare handoff material for another model run. For small and medium tasks this often costs more than the implementation.

## Current Behavior Summary

Workflow start materializes every manifest task into a `WorkflowRun` directory, then launches a `task-runner` process with `-Continue`. The runner repeatedly picks the next eligible task from the run directory. It prioritizes resumed `analysing` tasks with answered questions, then `analysed`, then `todo`.

Prompt tasks use the two-phase path. The runner loads `98-analyse-task.md`, starts a provider session, expects the agent to write `extensions.analysis`, then flips the task to `analysed`. It then loads `99-autonomous-task.md`, starts a separate provider session, expects the agent to call `task_get_context`, use the analysis package, implement, commit, verify, and call `task_set_status(done)`.

Non-prompt tasks are already closer to the desired shape. They skip analysis by default, auto-promote through `analysing` and `analysed`, run a local executor, validate outputs, then mark done.

The runtime has good primitives worth keeping:

- Per-task or per-run git isolation.
- Auditable task state and activity events.
- `needs-input` pauses with pending questions.
- Verification hooks and post-task output validation.
- Worktree preservation on merge/post-task failure.
- Workflow manifests and content resolver overrides.

The main issue is not the primitives. It is that the default AI path uses those primitives in the most expensive way for almost every task.

## Main Sources Of Latency

1. **Two provider sessions per prompt task**
   - Analysis and execution both load tools, read prompt context, and build their own mental model.
   - The second session must trust a handoff package written by the first, which creates context drift when the package is incomplete, stale, or too abstract.

2. **Analysis is mandatory by default for prompt tasks**
   - Only non-prompt executors default to `skip_analysis`.
   - Small prompt tasks pay the same analysis ceremony as large ambiguous implementation tasks.

3. **Workflows are over-decomposed into AI microtasks**
   - `start-from-jira` contains many serial prompt and task generation phases.
   - Each phase has its own prompt contract, status transitions, validation, and often another AI session.

4. **The agent owns too much lifecycle ceremony**
   - Prompts require the agent to call status tools at several points.
   - The runtime then has to infer whether the agent called the right thing and retry or escalate if not.

5. **Worktree lifecycle is per task even when the work is mostly planning/documentation**
   - Worktrees are essential for code changes, but expensive when a workflow phase only writes `.bot/workspace/product` artifacts.

6. **The context contract is heavier than the data model**
   - `99-autonomous-task.md` asks for a pre-flight context bundle and even mentions `has_analysis`, but the runtime endpoint returns the task and run record. The usable analysis is nested under the task. The model has to infer the rest.

## Proposal

Make the AI unit a **single task run with explicit session attempts**. This is not a selectable mode. It is the framework standard.

A task should complete in one provider invocation by default. That invocation handles:

1. Focused discovery.
2. Implementation or artifact generation.
3. Verification.
4. Completion or pause for input.

Analysis becomes an activity inside the task session, not a separate runtime phase, handoff document, or second provider session.

When a task is blocked by human input, the task remains the same task. The provider session exits, a compact worktree-local handoff is attached to that task, and the next provider invocation later resumes the same task from that exact handoff. Dotbot should not create "tasks of tasks" merely because a human had to answer a question.

## Task Standard

Every AI-backed task follows the same standard:

- One task may have only one active provider session attempt at a time.
- Planning, discovery, implementation, verification, and completion happen in one session attempt whenever the task is not externally blocked.
- The task may write notes, plans, or findings for audit, but not as a routine phase-to-phase handoff.
- If the task is too large, the session creates child tasks and stops. Each child task then gets its own single session.
- If the task needs human input, the task writes a worktree-local handoff document, records the question, and stops in `needs-input`. After the answer, the same task starts a new session attempt that consumes that exact handoff.
- If verification or merge fails after the provider exits, the framework preserves diagnostics on the same task. A remediation task is created only when the user or policy decides the original task should stop.

This keeps the framework opinionated and predictable: one task record corresponds to one unit of work, and repeated provider sessions are allowed only as explicit, handoff-backed attempts after an external wait.

Task types can still differ in what the one session is asked to produce:

- Implementation tasks produce code changes.
- Research tasks produce research artifacts.
- Planning tasks produce task definitions or design artifacts.
- Documentation tasks produce docs.
- Script, MCP, and barrier tasks remain non-provider executor tasks.

## New Status Model

The framework status model is deliberately small. There is no separate analysis state.

- `todo`
- `in-progress`
- `needs-input`
- `needs-review`
- `done`
- `failed`
- `skipped`
- `cancelled`

The runtime should own status transitions where possible:

- Runner marks a task `in-progress` before invoking the provider.
- Provider only needs to call a completion tool for `done`, `needs-input`, `needs-review`, `skipped`, or `failed`.
- If the provider exits successfully without a terminal task state, the runner escalates with diagnostics or marks the task failed. It must not launch another provider prompt for the same task ID unless the task is explicitly unblocked by a human answer and a validated handoff.
- `needs-input` is a waiting state for the same task. Answering the question consumes the pending handoff, requeues the task to `todo`, and the next runner claim starts a new `in-progress` session attempt for that same task ID.

## HITL Handoff Protocol

Human-in-the-loop is the main exception pressure against the single-session default. The framework should handle it with explicit handoff artifacts, not provider session resume.

When a task needs human input:

1. The active provider session writes a handoff document inside its own task worktree.
2. The session records the question and the handoff reference on the task.
3. The session exits.
4. The task waits in `needs-input`.
5. When the human answers, dotbot records the answer against the same task and the same pending question.
6. Dotbot validates the exact handoff reference already attached to that task.
7. Dotbot atomically marks the handoff `consumed`.
8. Dotbot starts the next provider session attempt for the same task ID with the answer and handoff reference in the bootstrap context.

There is no requirement to pause or natively resume the provider conversation. This is intentional. Provider/harness resume support is optional, inconsistent across tools, and not available in all adapters. Dotbot resume should be same-task state plus handoff files, not native provider session replay. If an adapter supports native resume, it can use it as an optimization, but the canonical recovery context remains the handoff attached to the task.

### Provider Resume Support

The framework behavior is the same whether the harness can resume sessions or not:

- If native resume is unavailable, dotbot starts a fresh provider session for the same task and passes the answer plus the validated handoff as the first-class bootstrap context.
- If native resume is available, dotbot may resume the provider conversation, but it must still pass the handoff and validate that the task ID, attempt ID, worktree, and branch match.
- If native resume fails, dotbot falls back to a fresh provider session with the same handoff. This fallback must not create a new task.

This keeps the runtime portable across Claude, Codex, OpenCode, and future harnesses while preserving the same task identity.

### Handoff Location

Handoff files must be worktree-local and gitignored:

```text
<task-worktree>/.bot/.handoffs/<run_id>/<task_id>/<attempt_id>/
  handoff.md
  manifest.json
```

The directory is intentionally not `.bot/.control`, because task worktrees link `.bot/.control` back to the shared project control directory. A shared control path would create exactly the cross-task collision risk this protocol is trying to avoid.

The framework should add `.bot/.handoffs/` to the project `.gitignore` during `dotbot init`, and `Complete-TaskWorktree` should explicitly exclude `.bot/.handoffs/**` from auto-commit and squash replay. Handoff files are working state, not product documentation.

### Handoff Identity

Every handoff gets a stable ID:

```text
ho_<runShort>_<taskShort>_<attemptShort>_<utcTimestamp>
```

The manifest records:

```json
{
  "handoff_id": "ho_wrAbCd_t1234567_a01_20260527T120000Z",
  "run_id": "wr_AbCd1234",
  "task_id": "t_12345678",
  "attempt_id": "a01",
  "worktree_path": "../worktrees/project/task-t_12345678-slug",
  "branch_name": "task/12345678-slug",
  "question_id": "q_...",
  "status": "open",
  "created_at": "2026-05-27T12:00:00Z",
  "consumed_at": null,
  "consumed_by_attempt_id": null
}
```

The task record stores only a reference:

```json
{
  "extensions": {
    "runner": {
      "current_handoff": {
        "handoff_id": "ho_wrAbCd_t1234567_a01_20260527T120000Z",
        "manifest_path": ".bot/.handoffs/wr_AbCd1234/t_12345678/a01/manifest.json",
        "document_path": ".bot/.handoffs/wr_AbCd1234/t_12345678/a01/handoff.md"
      },
      "session_attempts": [
        {
          "attempt_id": "a01",
          "provider_session_id": "optional-provider-id",
          "started_at": "2026-05-27T11:40:00Z",
          "ended_at": "2026-05-27T12:00:00Z",
          "ended_reason": "needs-input",
          "handoff_id": "ho_wrAbCd_t1234567_a01_20260527T120000Z"
        }
      ]
    }
  }
}
```

The runner must never resolve "latest handoff". It must always receive the explicit handoff reference stored on the same task. If the reference is missing, duplicated, outside the expected worktree, or mismatched against the task/run IDs in the manifest, the task must remain blocked and no provider session should launch.

### Handoff Document Shape

The markdown document should be compact and tailored to the next session attempt. It should include:

- Same task purpose.
- Current task and run IDs.
- Worktree and branch.
- User question being asked.
- Expected answer shape, if known.
- What was already done.
- Current working tree state.
- Files changed or relevant.
- Commands/tests already run and their results.
- Open risks or unknowns.
- Exact next steps after the human answer.
- Suggested skills or agent behavior for the next session.

It should be written as a bootstrap note: "read this first, trust it unless a listed stale condition is true, then continue from the exact next step." It should not duplicate content already present in PRDs, task JSON, decisions, commits, diffs, or generated artifacts. It should point to paths instead. It must redact secrets, tokens, local-only sensitive values, and PII.

### Matt Pocock Handoff Skill

Matt Pocock's `handoff` skill is a good pattern to bake into dotbot as a framework-owned protocol, not as an optional external skill dependency.

Adopt these principles:

- Compact markdown written for a fresh session.
- Tailor the handoff to the next session's purpose.
- Include suggested skills or behavior for the next agent.
- Reference existing artifacts instead of duplicating them.
- Redact secrets and sensitive information.
- Treat handoffs as disposable working documents, not permanent repo docs.

Adapt these parts for dotbot:

- Matt's skill saves to the OS temporary directory. Dotbot should not do that for workflow execution because concurrent tasks need deterministic, task-scoped paths.
- Matt's skill is manually invoked. Dotbot should invoke the handoff contract automatically whenever a task enters `needs-input`, split, review rejection, merge failure, or remediation.
- Matt's skill is conversation-oriented. Dotbot's version must be task-oriented and validated by manifest metadata.

### Same-Task Session Attempts

Human input creates a new provider session attempt on the same task, not a new task. The task record keeps an append-only session attempt history:

```json
{
  "task_id": "t_12345678",
  "status": "running",
  "extensions": {
    "runner": {
      "active_attempt_id": "a02",
      "resume_reason": "human-input",
      "consumed_handoff_id": "ho_wrAbCd_t1234567_a01_20260527T120000Z",
      "answer": {
        "question_id": "q_...",
        "answered_at": "2026-05-27T13:15:00Z"
      }
    }
  }
}
```

The new attempt uses the same worktree and branch as the previous attempt. There is no worktree lease transfer because ownership never leaves the task. The lease is still exclusive: only one active session attempt may run for a task/worktree at a time.

If a task asks another question, it writes a new handoff under the same task ID and the current attempt ID. Repeated HITL becomes a same-task attempt chain:

```text
t_A attempt a01 needs input -> ho_A_a01 -> answer -> t_A attempt a02
t_A attempt a02 needs input -> ho_A_a02 -> answer -> t_A attempt a03
```

No handoff is reused across tasks, and a consumed handoff cannot be consumed again.

### Concurrency Guarantees

Concurrent workflow slots make handoff isolation mandatory. The framework should enforce:

- Handoff paths are scoped by `run_id/task_id/attempt_id`.
- Handoff manifests include the owning task ID, run ID, worktree path, and branch.
- Answer consumption atomically marks the handoff `consumed` and records `consumed_by_attempt_id`.
- A worktree lease table prevents two task sessions from using the same worktree at once.
- A task lock prevents two session attempts for the same task from running concurrently.
- The runner refuses ambiguous handoff discovery and never scans global state for "the most recent" handoff.
- Handoff cleanup only removes files for terminal tasks whose worktree has been merged or discarded.

This gives each concurrent task its own handoff lane and prevents crossed context.

## Single-Session Prompt

Add a new prompt template, for example `100-single-session-task.md`, replacing the default `98` plus `99` path for all prompt tasks.

The prompt should say:

- First, inspect only the files and context needed for this task.
- If ambiguity blocks progress, write pending questions and stop.
- If the task is too large, propose a split and stop.
- Before stopping for human input, write the task handoff document and record its reference.
- Otherwise implement or generate the artifact in the same session.
- Run relevant tests and verification.
- Commit only the task changes.
- Mark the task terminal.

The prompt can ask the agent to make a short plan before edits, but that plan stays in the same session. It is not a separate runtime phase.

## Workflow Shape

Collapse workflows from many AI microtasks into fewer stage-level sessions.

Example `start-from-jira` target shape:

1. `initiative-intake`
   - Fetch Jira/Confluence context.
   - Write briefing and product documents.
   - Ask human questions only if required.

2. `research`
   - Generate and execute research in one stage.
   - Fan out only when independent sources can run in parallel.

3. `implementation-planning`
   - Produce implementation plan and concrete task list.
   - Stop here if the user only wanted planning.

4. `implementation`
   - Execute generated code tasks using the single-session task standard.

5. `handoff`
   - Draft PR/handoff/status docs.

This keeps the audit surface but removes many artificial model-to-model handoffs.

## Isolation Policy

Make isolation configurable per task type, without changing the single-session invariant:

- Code tasks: task worktree by default.
- Research and documentation stage tasks: run-scoped worktree or shared workspace.
- Barrier, MCP, and pure metadata tasks: no worktree.

Long term, prefer a **run-scoped worktree** for stage workflows and a **task-scoped worktree** for generated implementation tasks. That avoids creating and merging a worktree for every planning/documentation artifact.

## Context Contract

Replace the analysis handoff package with a runtime-built `task_context` response:

```json
{
  "task": {},
  "workflow_run": {},
  "task_standard": "single-task-session-attempts",
  "isolation": "task-worktree",
  "relevant_product_files": [],
  "decisions": [],
  "previous_questions": [],
  "active_attempt_id": "a02",
  "current_handoff": null,
  "resume_context": null
}
```

If a task is restarting after human input, the runtime includes the prior question, answer, handoff manifest, and handoff document path under `resume_context`. The bootstrap prompt must instruct the provider to read that handoff first and continue from the exact next step, not rediscover the task from scratch unless the manifest or stale markers say the context is invalid.

## Runtime Changes

1. Add `session_policy: single_unblocked_attempt` as a framework invariant for prompt tasks.
2. Add `isolation` to workflow task definitions and task extensions.
3. Replace the `98` plus `99` prompt path with `100-single-session-task.md`.
4. Remove prompt-task auto-promotion through old phase states.
5. Enforce one active provider session attempt per task ID in the runner.
6. Update `/tasks/<id>/context` to return an explicit context envelope with `task_standard: single-task-session-attempts`.
7. Move lifecycle ownership toward the runner: mark running before provider launch, verify terminal state after provider exit, and limit required agent status calls.
8. Add the worktree-local handoff writer contract to the single-session prompt and completion validation.
9. Add same-task resume handling for answered questions: validate the task's current handoff, consume it atomically, append a new attempt record, and launch the next session attempt for the same task.
10. Add handoff manifest validation, consumed-state tracking, task locks, and worktree lease validation.

## Migration Plan

### Phase 1: Instrument

Record per-task timings:

- worktree setup
- analysis session
- execution session
- verification
- merge/cleanup
- total provider invocations
- handoff count
- session attempt count
- token usage if provider emits it

This gives a baseline and makes the redesign measurable.

### Phase 2: Add Single-Session Path

Create `100-single-session-task.md` and route a small pilot workflow through it. A task in the pilot must launch one provider session unless it reaches `needs-input`.

### Phase 3: Convert Prompt Tasks

Switch prompt tasks to the single-session path.

### Phase 4: Add HITL Handoff

Implement worktree-local handoff files, explicit handoff references, same-task resume attempts, handoff consumed-state tracking, and task/worktree locks. Convert `needs-input` so answers restart the same task from the validated handoff rather than creating child tasks.

### Phase 5: Collapse Built-In Workflows

Rewrite built-in workflow manifests to use fewer stage tasks. Keep generated implementation tasks separate where independent execution and isolated merges still provide value.

### Phase 6: Retire Two-Phase Creation

Stop loading the old analysis prompt in the workflow runner. New workflow tasks use `todo -> in-progress` directly.

## Expected Impact

- Prompt task provider sessions drop from two to one in the common case.
- Tool schema loading happens once per task instead of once per phase.
- Context drift decreases because planning and implementation share one live context.
- Documentation/research workflows create fewer artificial task records.
- Worktree overhead drops when planning/documentation stages use run-scoped isolation.

The target is a 30-50 percent reduction in wall-clock time for normal prompt tasks, with larger wins for workflow-heavy flows like `start-from-jira`.

## Risks

- A single session can over-explore unless the prompt strongly limits discovery.
- Oversized tasks must be split earlier and more aggressively.
- UI and tests must follow the reduced status model.
- Some prompts and docs assume `task_get_context` returns a pre-flight package.
- Run-scoped worktrees need clear merge semantics when multiple stage tasks write product artifacts.
- Handoff documents can become stale if the worktree changes between session attempts.
- Handoff documents can leak sensitive information unless redaction is explicit and validated.

## Non-Goals

- Remove worktree isolation.
- Remove verification hooks.
- Remove human-in-the-loop questions.
- Remove workflow manifests.
- Remove audit records.

The change is to keep safeguards while enforcing one provider session for the common path and handoff-backed same-task attempts when a human wait forces a new session.

## Acceptance Criteria

- A prompt task can complete in one provider invocation by default.
- New prompt tasks cannot launch separate analysis and execution provider sessions.
- Human input creates a task-scoped handoff file and keeps the same task ID. After the answer, the next provider session attempt for that same task must consume the validated handoff.
- Concurrent handoffs cannot cross because every resume uses the explicit handoff reference stored on the same task and validated against run ID, task ID, attempt ID, worktree, and branch.
- `needs-input`, split proposal, review, verification, merge failure, and post-task failure flows still preserve the worktree and audit trail.
- Workflow runs expose clear progress with the reduced task states.
- Built-in workflows no longer require separate AI sessions merely to hand context from one phase to the next.
