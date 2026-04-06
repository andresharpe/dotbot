# Phase 12: Self-Improvement Loop

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## Concept

Dotbot continuously improves its own prompts, skills, agents, and workflows based on execution experience. A utility workflow (`93-self-improvement.md`) periodically analyzes activity logs, task outcomes, error patterns, and retry rates to generate concrete improvement suggestions with evidence-based rationale. Suggestions are stored in the workspace, surfaced in the UI, and can be applied individually or in bulk.

## Trigger mechanism

- **Automatic:** After every N completed tasks (setting: `self_improvement.frequency`, default `10`), the runtime checks if a self-improvement cycle is due. If so, it launches a prompt process with `93-self-improvement.md`.
- **On-demand:** Via MCP tool `improvement-run` or UI button "Run Self-Improvement"
- **Counter tracking:** `.bot/.control/improvement-counter.json` tracks `tasks_since_last_run` and `last_run_at`

## What it analyzes

The self-improvement workflow reads:

1. **Activity JSONL** (`.bot/.control/activity.jsonl`) — all events across all processes
2. **Per-process activity logs** (`.bot/.control/processes/*.activity.jsonl`) — detailed per-task streams
3. **Task JSON files** (`.bot/workspace/tasks/done/`) — completed tasks with their `execution_activity_log`, `analysis_sessions`, `execution_sessions`, retry counts, split proposals
4. **Structured logs** (`.bot/.control/logs/dotbot-*.jsonl`) — errors, warnings, rate limits (Phase 1)
5. **Needs-input history** — tasks that paused for human input (why? what was missing?)
6. **Skipped/cancelled tasks** — why did they fail?
7. **Task splits** — were analysis prompts missing context that led to over-scoping?

## Pattern detection

The LLM analyzes this data for patterns like:

| Pattern | Signal | Improvement type |
|---------|--------|-----------------|
| Repeated analysis retries | Analysis prompt missing guidance for a domain | Prompt edit |
| Tasks frequently need human input on same topic | Missing skill or decision context | New skill |
| Execution failures on specific file types | Missing standards or agent guidance | Agent/skill update |
| High token usage on simple tasks | Prompt too verbose or unfocused | Prompt trim |
| Consistent task splits at same phase | Workflow phase needs decomposition | Workflow tweak |
| Same verification failures recurring | Hook or verification script gap | Hook addition |
| Rate limit clusters | Too-aggressive concurrency or prompt size | Settings change |

## Improvement suggestion format

Stored at `.bot/workspace/improvements/{imp-id}.json`:

```json
{
  "id": "imp-a1b2c3d4",
  "status": "proposed|accepted|rejected|applied",
  "created_at": "2026-03-14T10:00:00Z",
  "applied_at": null,
  "rejected_at": null,
  "rejection_reason": null,
  "trigger": "automatic|manual",
  "tasks_analyzed": 10,
  "analysis_window": {
    "from": "2026-03-10T00:00:00Z",
    "to": "2026-03-14T10:00:00Z"
  },
  "type": "prompt-edit|new-skill|workflow-tweak|settings-change|new-hook|agent-update",
  "target_file": "prompts/workflows/98-analyse-task.md",
  "title": "Add file size estimation to analysis checklist",
  "rationale": "3 of the last 10 tasks required re-analysis because large generated files exceeded context. Adding a file size estimation step would catch these during analysis.",
  "evidence": {
    "task_ids": ["task-abc", "task-def", "task-ghi"],
    "pattern": "Tasks involving code generation consistently underestimate output size",
    "error_samples": ["Context window exceeded at line 1200..."]
  },
  "change": {
    "action": "edit|create|delete",
    "file_path": "prompts/workflows/98-analyse-task.md",
    "diff": "--- a/prompts/workflows/98-analyse-task.md\n+++ b/prompts/workflows/98-analyse-task.md\n@@ -142,6 +142,8 @@\n ## 6. Implementation Guidance\n+\n+### 6a. Output Size Estimation\n+Estimate the total lines of code that will be generated or modified...",
    "new_content": null
  },
  "impact": "low|medium|high",
  "confidence": 0.85,
  "tags": ["analysis", "context-management"]
}
```

## Workflow prompt: `93-self-improvement.md`

**Path:** `profiles/default/prompts/workflows/93-self-improvement.md`

The prompt instructs the LLM to:
1. Read the improvement counter to determine analysis window
2. Load activity logs and completed task JSONs from the window
3. Analyze for the patterns listed above
4. For each finding, generate a concrete improvement suggestion with:
   - The exact file to modify and the diff (or new file content)
   - Evidence linking to specific task IDs and log entries
   - Confidence score (how certain is this improvement?)
   - Impact assessment (how many future tasks would benefit?)
5. Write each suggestion as a JSON file in `workspace/improvements/`
6. Update the improvement counter
7. Emit `improvement.created` events via bus

## MCP tools

- `improvement-run` — trigger a self-improvement cycle manually
- `improvement-list` — list suggestions filtered by status, type, impact, confidence
- `improvement-get` — get a specific suggestion with full diff preview
- `improvement-apply -ImprovementId <id>` — apply a single suggestion (writes the change to the target file)
- `improvement-apply-bulk -Filter <hashtable>` — apply multiple (e.g., all high-confidence prompt-edits)
- `improvement-reject -ImprovementId <id> -Reason <string>` — reject with explanation (feeds back into future analysis)

## Web UI

**"Improvements" tab** in the dashboard:

- List view: pending suggestions sorted by confidence/impact
- Each item shows: title, type badge, target file, rationale summary, confidence bar
- Expand to see: full rationale, evidence (linked task IDs), diff preview
- Actions: Apply, Reject (with reason), View Target File
- Bulk actions: "Apply All High Confidence", "Apply Selected"
- History: previously applied/rejected suggestions

**API module:** `systems/ui/modules/ImprovementAPI.psm1`

## Runtime integration

In the task completion path (after `task-mark-done`):

```powershell
# In ProcessTypes/Invoke-ExecutionProcess.ps1 (or TaskLoop.psm1)
$counter = Get-ImprovementCounter
$counter.tasks_since_last_run++
if ($counter.tasks_since_last_run -ge $settings.self_improvement.frequency) {
    # Queue a self-improvement process (non-blocking)
    Start-Process -Type "prompt" -Workflow "93-self-improvement.md"
    Reset-ImprovementCounter
}
```

## Settings

```json
"self_improvement": {
  "enabled": true,
  "frequency": 10,
  "auto_trigger": true,
  "min_confidence": 0.7,
  "targets": ["prompts", "skills", "agents", "workflows", "settings", "hooks"],
  "max_suggestions_per_run": 5,
  "analysis_window_tasks": 20
}
```

## Feedback loop

When a suggestion is rejected with a reason, that reason is stored and available to future self-improvement runs. This prevents the system from repeatedly suggesting the same change:

```json
// In the next run, the LLM sees:
"previously_rejected": [
  {
    "title": "Add file size estimation...",
    "rejection_reason": "We handle this at the tool level, not in prompts",
    "rejected_at": "2026-03-14"
  }
]
```

## Events

- `improvement.created` — new suggestion generated
- `improvement.applied` — suggestion applied to target file
- `improvement.rejected` — suggestion rejected with reason
- `improvement.cycle_started` — self-improvement analysis began
- `improvement.cycle_completed` — analysis finished, N suggestions created

## Files

- Create: `profiles/default/prompts/workflows/93-self-improvement.md`
- Create: `profiles/default/systems/mcp/tools/improvement-{run,list,get,apply}/` (4+ tools)
- Create: `profiles/default/systems/ui/modules/ImprovementAPI.psm1`
- Modify: Runtime task completion path — add improvement counter check
- Modify: `profiles/default/defaults/settings.default.json` — add `self_improvement` section
- Add to init: `workspace/improvements/`
- Add to init: `.control/improvement-counter.json`
