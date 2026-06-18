---
{
  "name": "Fast Prompt Execution",
  "description": "Minimal one-task prompt for executing the user's launch prompt quickly.",
  "version": 1
}
---
# Fast Prompt

Load only these dotbot tools:

```
ToolSearch({ query: "select:mcp__dotbot__task_set_status,mcp__dotbot__steering_heartbeat" })
```

Find the workflow run directory that contains `.bot/workspace/tasks/workflow-runs/*/{{TASK_ID}}.json`, then read `workflow-launch-prompt.txt` from that same directory. If files are listed in `.bot/workspace/product/briefing/`, use only the relevant ones.

Execute the user's prompt directly:

- Keep discovery to the smallest useful set of files.
- Make only required changes.
- Run the quickest relevant verification.
- Commit non-`.bot/` changes with `[task:{{TASK_ID_SHORT}}]` and `[bot:{{INSTANCE_ID_SHORT}}]`.
- Mark this task done with `task_set_status`.

If a missing decision blocks execution, ask one specific question with `task_set_status({ task_id: "{{TASK_ID}}", status: "needs-input" })`.
