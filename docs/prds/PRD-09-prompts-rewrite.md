# PRD-09: Framework prompts + agents rewrite for new MCP names

## Problem Statement

As a developer running a workflow, I expect the AI to call the right tools — but after PRD-07 lands, the old `task_mark_*` tools no longer exist. Today's framework prompts and agent persona files instruct the model to call those names. The next workflow run after PRD-07 would fail at runtime when the model invokes a tool that's gone.

## Solution

Sweep every prompt and agent file that references a deprecated MCP tool name or the old lifecycle prose. Replace tool names with the new ones, update argument shapes (now requiring `project_id`, `status` enum values, etc.), and rewrite lifecycle prose to match the forward-only state machine with named recovery transitions.

## User Stories

1. As a developer reading a framework prompt, I want the tool names to match the actual MCP surface, so that the AI never calls a non-existent tool.
2. As the AI reading a prompt that describes the task lifecycle, I want the prose to match the actual state machine (forward sequence + named recovery transitions), so that I propose legal transitions.
3. As the AI reading a prompt that describes recovery, I want explicit names for the recovery edges (`done → todo` is "reopen"; `failed → todo` is "retry"), so that I use the right framing in user-facing messages.
4. As a developer reading workflow recipe prompts (e.g. for `start-from-repo`), I want any reference to per-task `skip_worktree` removed, so that the prompts match the new workflow-level `isolated` model.
5. As a developer authoring a new workflow, I want the example prompts to model the new tool calls (with `project_id`), so that I can copy the pattern.
6. As the AI, I want explicit instructions on how to handle `needs-input` (set status, halt, await human reply) rather than calling a defunct `task_answer_question`, so that my behaviour matches the simplified model.
7. As a developer running `grep` for old tool names after this PRD lands, I want zero hits anywhere under `src/` and `.bot/content/`, so that I can be confident the sweep is complete.

## Implementation Decisions

The sweep touches every prompt, agent persona, and workflow recipe file. Tool-name substitutions are mechanical:

| Old | New |
|---|---|
| `task_mark_todo` | `task_set_status` with `status: "todo"` (recovery only — adjust surrounding prose) |
| `task_mark_analysing` | `task_set_status` with `status: "analysing"` |
| `task_mark_analysed` | `task_set_status` with `status: "analysed"` |
| `task_mark_in_progress` | `task_set_status` with `status: "in-progress"` |
| `task_mark_done` | `task_set_status` with `status: "done"` |
| `task_mark_skipped` | `task_set_status` with `status: "skipped"` |
| `task_mark_needs_input` | `task_set_status` with `status: "needs-input"` |
| `task_answer_question` | (removed; prose: "set status to `needs-input`, halt, await human reply") |
| `task_approve_split` | (removed; split status is gone — prose: close the parent and create children) |
| `task_create_bulk` | `task_create` looped — rewrite prompts to iterate |
| `task_get_stats` | `task_list` with summary filter (or drop the reference if no replacement needed) |

Argument-shape changes the prompts must reflect:
- Every mutation tool now takes `project_id` (required). Prompts should reference it explicitly when showing call examples; the AI passes it from the run context.
- `task_set_status` takes `task_id`, `status`, and optional `reason`. Example calls in prompts must use this shape.

Lifecycle prose:
- The forward path is `todo → analysing → analysed → in-progress → done`. Prompts describe this as the normal flow.
- Terminal alternatives are `failed`, `skipped`, and `cancelled`. Prompts mention them with one-line descriptions: `failed` (the task could not complete), `skipped` (the user opted out), `cancelled` (set by the cancellation cascade when a parent WorkflowRun is cancelled — terminal, no recovery).
- Recovery transitions named in prose: `done → todo` is "reopen"; `failed → todo` is "retry"; `skipped → todo` is "unskip"; `in-progress → analysed` is "kick-back" (used when in-flight work needs to be re-planned). `cancelled` is terminal — recovery is not possible.
- Any mention of `split` is removed (the concept is gone).

Isolation/worktree prose:
- Drop every reference to per-task `skip_worktree`.
- Add the workflow-level framing: workflows declare `isolated: true|false` at the top of `workflow.yaml`; tasks inherit; standalone tasks are workflows-of-one with `isolated: true` by default.
- Drop any prose claiming that `.bot/.control/` or other directories are shared with main via junctions inside a worktree (no longer true post PRD-03).

The sweep is by `grep` + edit. Every workflow under `.bot/content/workflows/*/recipes/prompts/` gets the same treatment. Framework prompts (under `src/prompts/` or wherever the v4 layout places them) and agent persona files (under `src/agents/`) also.

## Testing Decisions

A good test asserts on **absence of bad references** and **presence of correct shapes** in the prompt corpus. Tests should be `grep`-style smoke checks, not interpretation of prompt content.

Modules to be tested:
- The prompt corpus as a whole — `Test-PromptHygiene.ps1`:
  - `grep -rn 'task_mark_' src/ .bot/content/` returns zero hits.
  - `grep -rn 'task_answer_question|task_approve_split|task_create_bulk|task_get_stats' src/ .bot/content/` returns zero hits.
  - `grep -rn 'skip_worktree' src/ .bot/content/` returns zero hits.
- Per-workflow smoke test — a Layer 3 mock-Claude run of each workflow (`start-from-repo`, `start-from-prompt`, `start-from-pr`, `start-from-jira`) that exercises at least one new tool call per workflow and verifies no runtime errors from unknown tools.

Prior art: `tests/Test-PrivacyScan.ps1` is the closest analogue — assertions on file contents via patterns. Extend the same approach for tool-name hygiene.

## Out of Scope

- The MCP tools themselves: PRD-07.
- The state machine: PRD-01.
- Workflow YAML changes (top-level `isolated` field, removal of per-task `skip_worktree`): PRD-02 sweeps the YAMLs; this PRD sweeps the recipe prompts and agent personas.
- Any redesign of agent personas or workflow flow: this is a name + prose sweep, not a behaviour change.

## Further Notes

- The sweep should preserve any prose quality and tone; only the tool names and lifecycle prose change.
- For workflows with input-passing patterns (`start-from-pr` takes a PR URL, etc.), confirm whether the input still flows via per-task fields or via `WorkflowRun.extensions`. If the latter, prompts may need adjustments beyond the mechanical substitutions; raise as a follow-up if so.
- Open question for implementor: should we rewrite example tool calls in prompts to be exact JSON, or keep them as natural-language descriptions? Proposal: exact JSON — the AI mimics what it sees.
