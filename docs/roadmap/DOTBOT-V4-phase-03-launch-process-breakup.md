# Phase 3: Break Up launch-process.ps1

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## New structure
```
systems/runtime/
  launch-process.ps1              # ~400 lines: parse args, preflight, dispatch
  modules/
    ProcessRegistry.psm1          # Process CRUD, locking, activity logging, task helpers
    InterviewLoop.ps1             # Reusable Q&A loop for kickstart phases
    ProcessTypes/
      Invoke-AnalysisProcess.ps1  # todo -> analysed task loop
      Invoke-ExecutionProcess.ps1 # analysed -> done with worktree isolation
      Invoke-WorkflowProcess.ps1  # unified analyse+execute with slot concurrency
      Invoke-KickstartProcess.ps1 # manifest-driven multi-phase pipeline
      Invoke-PromptProcess.ps1    # planning, commit, task-creation
```

## ProcessRegistry.psm1
Extracted from launch-process.ps1 (15 functions):
- `Initialize-ProcessRegistry` — module-scope state setup
- `New-ProcessId`, `Write-ProcessFile`, `Write-ProcessActivity`, `Write-Diag`
- `Test-ProcessStopSignal`, `Acquire-ProcessLock`, `Test-ProcessLock`, `Set-ProcessLock`, `Remove-ProcessLock`
- `Test-Preflight`, `Add-YamlFrontMatter`
- `Get-NextTodoTask`, `Get-NextWorkflowTask`, `Test-DependencyDeadlock`

## Files
- Gut: `launch-process.ps1` → ~400 line dispatcher
- Create: `modules/ProcessRegistry.psm1`
- Create: `modules/InterviewLoop.ps1`
- Create: `modules/ProcessTypes/Invoke-{Analysis,Execution,Workflow,Kickstart,Prompt}Process.ps1`
