# Setup & Manual Test Guide — Issue #256

**Goal:** Set up `start-from-jira` for the first time and verify that `task_gen` phases (Plan Internet/Atlassian/Sourcebot Research) now create task files instead of doing research directly.

---

## Part 1 — First-Time Setup

### Step 1 — Install the latest build

From the dotbot repo root:

```powershell
pwsh install.ps1
```

### Step 2 — Create a test project directory

```powershell
mkdir C:\test-launch
cd C:\test-launch
git init
```

### Step 3 — Initialise dotbot with the start-from-jira workflow

```powershell
dotbot init -Workflow start-from-jira
```

This creates `.bot/`, scaffolds `.env.local`, and registers the dotbot MCP server.

### Step 4 — Fill in `.env.local`

Open `C:\test-launch\.env.local` and fill in:

| Variable | What to put | Where to find it |
|----------|-------------|-----------------|
| `ATLASSIAN_EMAIL` | Your Atlassian login email | Your Atlassian account |
| `ATLASSIAN_API_TOKEN` | API token | Go to [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens) → **Create API token** |
| `ATLASSIAN_CLOUD_ID` | Your Jira site URL | Copy from browser: `https://yourcompany.atlassian.net` |
| `AZURE_DEVOPS_PAT` | Personal Access Token | `https://dev.azure.com/YOUR_ORG/_usersSettings/tokens` — scopes: **Code (Read & Write)** + **Packaging (Read)** |
| `AZURE_DEVOPS_ORG_URL` | `https://dev.azure.com/YOUR_ORG` | Azure DevOps top-level URL |

### Step 5 — Register the Atlassian MCP server

```powershell
claude mcp add atlassian -s user npx -- @anthropic/mcp-atlassian
```

Verify it registered:

```powershell
claude mcp list
```

You should see `atlassian` in the list.

### Step 6 — Register Sourcebot (optional)

If your org runs Sourcebot:

```powershell
claude mcp add sourcebot https://YOUR_SOURCEBOT_URL/mcp
```

If not, skip this step — the workflow marks Sourcebot research as `optional` and degrades gracefully.

### Step 7 — Find a Jira key to test with

Open Jira in your browser. Navigate to any **epic** (parent issue, not a subtask). The key is shown top-left and in the URL:

```
https://yourcompany.atlassian.net/browse/PROJ-123
                                               ^^^^^^^^
                                               this is your key
```

Use an epic key, not a subtask. The workflow fetches the epic and all its children automatically.

---

## Part 2 — Before/After Verification

### Before the fix (reference — what failure looked like)

If you want to confirm the bug was real, temporarily revert the dispatch change, run the workflow, and observe:

- Phase 4 (Plan Atlassian Research) would spend several minutes reading Jira/Confluence docs
- `tasks/todo/` would contain **0 files** after the phase
- The process would throw: `"expected at least 1 file(s) in tasks/todo, found 0"`
- API spend: ~$4+ per phase

Skip this if you trust the issue report.

### After the fix - what to check

- Claude's phase output completes in seconds, not minutes
- `tasks/todo/` gains one new `.json` file per task_gen phase (internet, atlassian, sourcebot)
- No files under `.bot/workspace/product/` are modified during task_gen phases
- `min_output_count` validation passes with no exception thrown
- Phase logs show `task_create` being called, not `WebFetch`/`Read`/file writes

---

## Part 3 — Running the Test

### Step 1 — Start the web UI

```powershell
cd C:\test-launch
.bot\go.ps1
```

Open `http://localhost:8686` in your browser.

### Step 2 — Launch a workflow run

1. Click the **Product** tab
2. Click **RUN WORKFLOW**
3. Paste your Jira epic key (e.g. `PROJ-123`) into the prompt field
4. Click **Launch**

### Step 3 — Watch Phase 0 and Phase 1 complete

These are `prompt` phases (not affected by this fix). Let them run:

- **Phase 0 — Fetch Jira Context**: downloads Jira/Confluence data → writes `briefing/jira-context.md`
- **Phase 1 — Generate Product Documents**: writes `mission.md` and `roadmap-overview.md`

If the UI shows an **◈ Action Required** widget (bottom-right), answer the questions and the workflow resumes.

### Step 4 — Watch the `task_gen` phases (the fix)

Phases 2a, 2b, 2c are the ones this fix targets. Observe:

| What to watch | Expected behaviour after fix |
|---------------|------------------------------|
| Claude's terminal output during phase | Short — reads `jira-context.md`, calls `task_create`, reports task name/ID, stops |
| Time taken | Seconds to ~1 minute (not 5-10 minutes) |
| API spend | Small (not $4+) |
| Files in `tasks/todo/` after each phase | 1 new `.json` file per phase |
| Spec docs modified | None |

### Step 5 — Check `tasks/todo/` after each phase

```powershell
ls C:\test-launch\.bot\workspace\tasks\todo\
```

After all three `task_gen` phases complete, you should see **3 task files** (one per phase: internet, atlassian, sourcebot).

### Step 6 — Confirm no spec documents were touched

```powershell
git -C C:\test-launch diff .bot\workspace\product\
```

Expected: **no output** — the product docs must be unchanged during `task_gen` phases.

### Step 7 — Inspect a task file

Open one of the JSON files in `tasks/todo/`. Confirm it contains:

- `"category": "research"`
- `"research_prompt"` field
- No `dependencies` (empty array)
- Task name includes the initiative name and Jira key

### Step 8 — Confirm the barrier phase passes

The **Execute Research** barrier phase depends on all three `task_gen` phases. If any produced 0 files it would block here. Confirm the process moves past the barrier and into the task-runner phase.

---

## Part 4 — Automated Tests

Run layers 1-3 (no credentials needed):

```powershell
pwsh tests/Run-Tests.ps1 2>&1 | tee /tmp/test-results.txt
```

All three layers must be green before raising a PR.

---

## Pass / Fail Summary

| Check | Pass condition |
|-------|---------------|
| Layer 1 tests | All green |
| Layer 2 tests | All green |
| Layer 3 tests | All green |
| `tasks/todo/` after phases 2a/2b/2c | 3 task files present |
| `git diff .bot/workspace/product/` after `task_gen` phases | Clean — no changes |
| `min_output_count` validation | No error thrown, process continues |
| API spend per `task_gen` phase | Noticeably lower than $4 |
| Barrier phase (Execute Research) | Reached and passes |
