# Fix Plan: `task_gen` Dispatch in Kickstart Engine

**Issue:** #256 — Phase 4 (Plan Atlassian Research) falls through to generic LLM handler, Claude does research instead of creating task files, wastes ~$4/run.

**Branch:** `feature/fix-task-gen-kickstart-dispatch`

---

## Root Cause

`Invoke-KickstartProcess.ps1` LLM handler (line 363) injects this instruction:

```
4. Do NOT create tasks or use task management tools unless the workflow explicitly instructs you to
```

`task_gen` phases hit this handler. Instruction 4 fights the prompt's "use `task_create`" guidance — Claude resolves the conflict by doing the research itself instead of calling the MCP tool.

Secondary: no dedicated `task_gen` dispatch branch exists; the type is silently ignored.

---

## Steps

### Step 1 — Add `task_gen` handler branch in `Invoke-KickstartProcess.ps1`

**File:** `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-KickstartProcess.ps1`

Insert new `elseif` before the `else` (LLM) block (~line 330):

```powershell
} elseif ($phaseType -eq "task_gen") {
    # --- Task-gen phase: run .md workflow with strict task-creation constraints ---
    $wfContent = ""
    $wfPath = Join-Path $botRoot "recipes\prompts\$($phase.workflow)"
    if (-not (Test-Path $wfPath)) {
        # Try workflow-scoped path
        $wfPath = Join-Path $activeWorkflowDir "recipes\prompts\$($phase.workflow)"
    }
    if (Test-Path $wfPath) { $wfContent = Get-Content $wfPath -Raw }

    $phasePrompt = @"
$wfContent

User's project description:
$Prompt
$fileRefs
$interviewContext

TASK GENERATION PHASE — STRICT RULES:
- Your ONLY job is to create task definitions using the task_create MCP tool
- Do NOT execute any research, analysis, or implementation work
- Do NOT edit any spec or product documents
- Do NOT write files other than the task file created by task_create
- After task_create succeeds, report the task name and ID, then stop
"@

    $claudeSessionId = New-ProviderSession
    $streamArgs = @{
        Prompt          = $phasePrompt
        Model           = $claudeModelName
        SessionId       = $claudeSessionId
        PersistSession  = $false
    }
    if ($ShowDebug)    { $streamArgs['ShowDebugJson']    = $true }
    if ($ShowVerbose)  { $streamArgs['ShowVerbose']      = $true }
    if ($permissionMode) { $streamArgs['PermissionMode'] = $permissionMode }

    Invoke-ProviderStream @streamArgs

    # Validate min_output_count
    if ($phase.outputs_dir -and $phase.min_output_count) {
        $resolvedOutputsDir = Join-Path $projectRoot ".bot\workspace\$($phase.outputs_dir)"
        $outputFiles = @(Get-ChildItem -Path $resolvedOutputsDir -File -ErrorAction SilentlyContinue)
        $minCount = [int]$phase.min_output_count
        if ($outputFiles.Count -lt $minCount) {
            throw "task_gen phase '$phaseName': expected at least $minCount file(s) in $($phase.outputs_dir), found $($outputFiles.Count)"
        }
        Write-ProcessActivity -Id $procId -ActivityType "text" -Message "task_gen phase '$phaseName': $($outputFiles.Count) task(s) created in $($phase.outputs_dir)"
    }
```

Key difference from generic LLM handler:
- Replaces instruction 4 ("Do NOT create tasks") with the opposite constraint
- No clarification-question loop (task-gen phases don't need it)
- No post-phase `mission.md` detection guard

### Step 2 — Harden the three `task_gen` prompts

**Files:**
- `workflows/kickstart-via-jira/recipes/prompts/02a-plan-internet-research.md`
- `workflows/kickstart-via-jira/recipes/prompts/02b-plan-atlassian-research.md`
- `workflows/kickstart-via-jira/recipes/prompts/02c-plan-sourcebot-research.md`

Add at the very top of each (before `# Plan ...` heading):

```markdown
> **TASK GENERATION ONLY.** This phase creates a task definition. Do NOT execute
> any research, download files, or edit product documents. Call `task_create`
> and stop.
```

Both fixes together — dispatch fix + prompt hardening — give defense-in-depth: even if a future phase type is misconfigured, the prompt constraint fires first.

### Step 3 — Tests

```bash
pwsh tests/Run-Tests.ps1 2>&1 | tee /tmp/test-results.txt
```

Layers 1-3 must pass. If Layer 3 mock workflow has no `task_gen` phase, add one minimal fixture phase to exercise the new branch.

---

## Files Changed

| File | Change |
|------|--------|
| `workflows/default/systems/runtime/modules/ProcessTypes/Invoke-KickstartProcess.ps1` | Add `task_gen` dispatch branch with output validation |
| `workflows/kickstart-via-jira/recipes/prompts/02a-plan-internet-research.md` | Add TASK GENERATION ONLY banner |
| `workflows/kickstart-via-jira/recipes/prompts/02b-plan-atlassian-research.md` | Add TASK GENERATION ONLY banner |
| `workflows/kickstart-via-jira/recipes/prompts/02c-plan-sourcebot-research.md` | Add TASK GENERATION ONLY banner |

---

## Acceptance Criteria

- [ ] Phase 4 creates ≥1 file in `tasks/todo/` — `min_output_count` validation passes
- [ ] Claude does not edit spec documents during `task_gen` phases
- [ ] API spend for a `task_gen` phase is minimal (one `task_create` call, no research loop)
- [ ] Layers 1-3 tests pass

---

## Out of Scope

- `New-WorkflowTask` / `workflow-manifest.ps1` conversion path — not called by kickstart engine
- Other `task_gen` callers outside kickstart — none found
