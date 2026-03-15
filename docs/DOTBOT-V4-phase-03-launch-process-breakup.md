# Phase 3: Break Up launch-process.ps1

← [Back to Roadmap](DOTBOT-V4-ROADMAP-DRAFT-V1.md)

---

## New structure
```
systems/runtime/
  launch-process.ps1              # ~200 lines: parse args, preflight, dispatch
  modules/
    ProcessRegistry.psm1          # Process CRUD, locking, activity logging
    TaskLoop.psm1                 # Shared task iteration
    ProcessTypes/
      Invoke-AnalysisProcess.ps1
      Invoke-ExecutionProcess.ps1
      Invoke-WorkflowProcess.ps1
      Invoke-KickstartProcess.ps1
      Invoke-PromptProcess.ps1    # planning, commit, task-creation
```

## ProcessRegistry.psm1
Extracted from launch-process.ps1:
- `New-ProcessId`, `Write-ProcessFile`, `Write-ProcessActivity`
- `Test-ProcessStopSignal`, `Test-ProcessLock`, `Set-ProcessLock`, `Remove-ProcessLock`
- `Test-Preflight`

## TaskLoop.psm1
Shared iteration pattern (currently duplicated 3x in analysis/execution/workflow):
- `Invoke-TaskLoop -Strategy <scriptblock> -OnComplete <scriptblock>`
- `Wait-ForTasks` — wait-with-heartbeat
- `Invoke-WithRetry` — retry-with-rate-limit

## Files
- Gut: `launch-process.ps1` → ~200 line dispatcher
- Create: `modules/ProcessRegistry.psm1`
- Create: `modules/TaskLoop.psm1`
- Create: `modules/ProcessTypes/Invoke-{Analysis,Execution,Workflow,Kickstart,Prompt}Process.ps1`
