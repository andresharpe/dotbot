<#
.SYNOPSIS
Per-task and per-run mutex pool for the runtime.

Canonical PRD: docs/prds/PRD-04-runtime-http-server.md §Implementation Decisions.

The pool is the only serialisation point in the runtime. PRD User Story 9:
"concurrent updates to the same task do not race." User Story 10: concurrent
updates to *different* tasks proceed in parallel. The dictionary + per-key
semaphore primitive gives both.

Implementation note: this is a single-process pool. The PRD's "Further Notes"
section explicitly calls multi-runtime out of scope ("Multi-runtime scenarios
would need a different story — file locks, external coordinator — not in
scope").
#>

# Two side-by-side pools so a task lock and a run lock can be held independently
# (a status transition that touches both takes the run lock first, then the
# task lock — see Lock-RunMutex / Lock-TaskMutex callers).
#
# The pools are stored on AppDomain.CurrentDomain (process-wide static) rather
# than module-script scope. This module is loaded into every per-request
# runspace via Initialise-SessionState.ImportPSModule; if the pool were
# module-script-scoped, each runspace would get its OWN private pool and the
# mutex would not serialise across concurrent requests. AppDomain storage is
# shared across all runspaces in the process, which is what we want here.
$script:DotbotTaskMutexKey = 'Dotbot.Runtime.TaskMutexes'
$script:DotbotRunMutexKey  = 'Dotbot.Runtime.RunMutexes'

function _Get-TaskMutexPool {
    $pool = [System.AppDomain]::CurrentDomain.GetData($script:DotbotTaskMutexKey)
    if ($null -eq $pool) {
        $pool = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]::new()
        [System.AppDomain]::CurrentDomain.SetData($script:DotbotTaskMutexKey, $pool)
    }
    return $pool
}

function _Get-RunMutexPool {
    $pool = [System.AppDomain]::CurrentDomain.GetData($script:DotbotRunMutexKey)
    if ($null -eq $pool) {
        $pool = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]::new()
        [System.AppDomain]::CurrentDomain.SetData($script:DotbotRunMutexKey, $pool)
    }
    return $pool
}

function _Get-Or-Add-Semaphore {
    param(
        [Parameter(Mandatory)] [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.SemaphoreSlim]]$Pool,
        [Parameter(Mandatory)] [string]$Key
    )
    # GetOrAdd is the canonical CAS pattern on ConcurrentDictionary. The factory
    # may be called more than once under contention; that's why the second
    # arg is a lambda — the discarded one falls out of scope and gets GC'd.
    $factory = [System.Func[string, System.Threading.SemaphoreSlim]]{
        param($k) [System.Threading.SemaphoreSlim]::new(1, 1)
    }
    return $Pool.GetOrAdd($Key, $factory)
}

function Lock-TaskMutex {
    <#
    .SYNOPSIS
    Acquire the per-task mutex. Returns the SemaphoreSlim so the caller can
    release it (use Unlock-TaskMutex for the symmetric API).
    #>
    param(
        [Parameter(Mandatory)] [string]$TaskId,
        [int]$TimeoutMs = -1
    )
    $sem = _Get-Or-Add-Semaphore -Pool (_Get-TaskMutexPool) -Key $TaskId
    if ($TimeoutMs -ge 0) {
        if (-not $sem.Wait($TimeoutMs)) {
            throw "Lock-TaskMutex: timed out after ${TimeoutMs}ms acquiring lock for task '$TaskId'."
        }
    } else {
        $sem.Wait()
    }
    return $sem
}

function Unlock-TaskMutex {
    <#
    .SYNOPSIS
    Release a per-task mutex. Pair with Lock-TaskMutex via try/finally —
    callers MUST release on every exit path or the next holder deadlocks.
    #>
    param(
        [Parameter(Mandatory)] [string]$TaskId
    )
    $sem = $null
    if ((_Get-TaskMutexPool).TryGetValue($TaskId, [ref]$sem)) {
        try { [void]$sem.Release() } catch {
            # Releasing more times than Wait() was called throws
            # SemaphoreFullException. That's a logic bug, not a runtime one;
            # swallowing here would mask it. Let it propagate.
            throw
        }
    }
}

function Lock-RunMutex {
    <#
    .SYNOPSIS
    Acquire the per-run mutex (keyed by workflow run ID).
    #>
    param(
        [Parameter(Mandatory)] [string]$RunId,
        [int]$TimeoutMs = -1
    )
    $sem = _Get-Or-Add-Semaphore -Pool (_Get-RunMutexPool) -Key $RunId
    if ($TimeoutMs -ge 0) {
        if (-not $sem.Wait($TimeoutMs)) {
            throw "Lock-RunMutex: timed out after ${TimeoutMs}ms acquiring lock for run '$RunId'."
        }
    } else {
        $sem.Wait()
    }
    return $sem
}

function Unlock-RunMutex {
    param(
        [Parameter(Mandatory)] [string]$RunId
    )
    $sem = $null
    if ((_Get-RunMutexPool).TryGetValue($RunId, [ref]$sem)) {
        [void]$sem.Release()
    }
}

function Lock-TaskMutexes {
    <#
    .SYNOPSIS
    Acquire several task mutexes at once in deadlock-safe (ID-ascending) order.

    .DESCRIPTION
    Multi-task operations (e.g. a batch status update) must take locks in a
    globally consistent order to avoid the classic dining-philosophers
    deadlock. PRD-04 fixes the order at "canonical-ID-ascending" — string
    sort on the canonical 't_XXXXXXXX' form.

    Returns the list of IDs in the order they were acquired so the caller can
    release in reverse.

    Duplicate IDs are deduped on input; locking the same key twice would
    deadlock the caller.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$TaskIds,

        [int]$TimeoutMs = -1
    )
    $unique = @($TaskIds | Sort-Object -Unique)
    foreach ($id in $unique) {
        Lock-TaskMutex -TaskId $id -TimeoutMs $TimeoutMs | Out-Null
    }
    return ,$unique
}

function Unlock-TaskMutexes {
    <#
    .SYNOPSIS
    Release several task mutexes acquired via Lock-TaskMutexes.
    Releases in reverse order to mirror nested acquire semantics.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$TaskIds
    )
    $unique = @($TaskIds | Sort-Object -Unique)
    # Reverse so semaphores that were acquired last get released first.
    [array]::Reverse($unique)
    foreach ($id in $unique) {
        Unlock-TaskMutex -TaskId $id
    }
}

function Clear-RuntimeMutexPool {
    <#
    .SYNOPSIS
    Dispose every semaphore in both pools and reset them. Used in tests so a
    runtime that's been stopped doesn't leak handles.

    .DESCRIPTION
    Production runtime processes are short-lived and rely on process exit to
    clean these up. Tests that spin the runtime up and down in-process need
    an explicit reset. Resets the AppDomain-scoped storage too so a fresh
    pool gets created on next access.
    #>
    foreach ($pool in @((_Get-TaskMutexPool), (_Get-RunMutexPool))) {
        foreach ($key in @($pool.Keys)) {
            $sem = $null
            if ($pool.TryRemove($key, [ref]$sem)) {
                try { $sem.Dispose() } catch { $null = $_ }
            }
        }
    }
}

Export-ModuleMember -Function @(
    'Lock-TaskMutex'
    'Unlock-TaskMutex'
    'Lock-RunMutex'
    'Unlock-RunMutex'
    'Lock-TaskMutexes'
    'Unlock-TaskMutexes'
    'Clear-RuntimeMutexPool'
)
