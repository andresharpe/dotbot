<#
.SYNOPSIS
Git worktree lifecycle management for per-task isolation.

.DESCRIPTION
Each task gets its own git branch and worktree, created at analysis start
and persisting through execution. On completion, the branch is squash-merged
to main and the worktree is cleaned up.

Worktree path convention:
  {repo-parent}/worktrees/{repo-name}/task-{short-id}-{slug}/

Branch naming:
  task/{short-id}-{slug}

Shared infrastructure via directory junctions:
  .bot/.control/          -> central control (process registry, settings)
  .bot/workspace/tasks/   -> central task queue (todo, done, etc.)
  .bot/workspace/product/ -> shared research outputs and briefing
  .bot/hooks/             -> verification scripts, commit-bot-state, dev lifecycle
  .bot/systems/           -> MCP server, runtime, UI
  .bot/prompts/           -> workflow prompts, research methodologies, standards
  .bot/defaults/          -> settings defaults
#>

# --- Internal State ---
$script:WorktreeMapPath = $null

# Large, regenerable directories excluded from gitignored file copying
$script:NoiseDirectories = @(
    'bin', 'obj', 'node_modules', 'packages',
    'Debug', 'Release', 'x64', 'x86',
    '.vs', '.idea', '.vscode',
    '__pycache__', '.mypy_cache',
    '.git', '.control', '.playwright-mcp', '.serena',
    'TestResults', 'test-results', 'playwright-report',
    'sessions'
)

# --- Internal Helpers ---

function Get-BaseBranch {
    param([string]$ProjectRoot)
    # Try current HEAD branch
    $branch = git -C $ProjectRoot symbolic-ref --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $branch) {
        git -C $ProjectRoot rev-parse --verify $branch 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $branch }
    }
    # Fallback: try common defaults
    foreach ($candidate in @('main', 'master')) {
        git -C $ProjectRoot rev-parse --verify $candidate 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    return $null
}

function Initialize-WorktreeMap {
    param([string]$BotRoot)
    $controlDir = Join-Path $BotRoot ".control"
    $script:WorktreeMapPath = Join-Path $controlDir "worktree-map.json"
}

function Read-WorktreeMap {
    if (-not $script:WorktreeMapPath -or -not (Test-Path $script:WorktreeMapPath)) {
        return @{}
    }
    try {
        $content = Get-Content $script:WorktreeMapPath -Raw
        if ([string]::IsNullOrWhiteSpace($content)) { return @{} }
        $json = $content | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $map[$prop.Name] = $prop.Value
        }
        return $map
    } catch {
        return @{}
    }
}

function Write-WorktreeMap {
    param([hashtable]$Map)
    if (-not $script:WorktreeMapPath) { return }
    $dir = Split-Path $script:WorktreeMapPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $tempFile = "$($script:WorktreeMapPath).tmp"
    $maxRetries = 3
    for ($r = 0; $r -lt $maxRetries; $r++) {
        try {
            $Map | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
            Move-Item -Path $tempFile -Destination $script:WorktreeMapPath -Force -ErrorAction Stop
            return
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            if ($r -lt ($maxRetries - 1)) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
        }
    }
}

function Get-TaskSlug {
    param([string]$TaskName)
    $slug = $TaskName.ToLower()
    $slug = $slug -replace '[^a-z0-9]+', '-'
    $slug = $slug -replace '^-|-$', ''
    if ($slug.Length -gt 50) { $slug = $slug.Substring(0, 50) -replace '-$', '' }
    return $slug
}

function Stop-WorktreeProcesses {
    <#
    .SYNOPSIS
    Kill all processes whose command line references a given worktree path.
    Prevents file locks from blocking worktree removal and git operations.
    Returns the number of processes killed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$WorktreePath
    )

    if (-not $WorktreePath) { return 0 }

    $killed = 0

    try {
        if ($IsWindows) {
            # On Windows, use WMI to query process command lines in all path formats:
            # backslash (PowerShell), forward-slash (Node/npm), Git Bash (/c/Users/...)
            $escapedOriginal = [regex]::Escape($WorktreePath)
            $forwardSlash = $WorktreePath -replace '\\', '/'
            $escapedForward = [regex]::Escape($forwardSlash)
            $gitBashStyle = $forwardSlash -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLower() }
            $escapedGitBash = [regex]::Escape($gitBashStyle)

            $candidates = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.CommandLine -and (
                        $_.CommandLine -match $escapedOriginal -or
                        $_.CommandLine -match $escapedForward -or
                        $_.CommandLine -match $escapedGitBash
                    )
                }

            foreach ($proc in $candidates) {
                if ($proc.ProcessId -eq $PID) { continue }
                try {
                    Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                    $killed++
                } catch {}
            }
        } else {
            # On Linux/macOS, use ps to find processes by command line
            $escapedPath = [regex]::Escape($WorktreePath)
            $psOutput = & /bin/ps -eo pid,args 2>/dev/null
            if ($psOutput) {
                foreach ($psLine in $psOutput) {
                    if ($psLine -match '^\s*(\d+)\s+(.+)$') {
                        $procPid = [int]$Matches[1]
                        $cmdLine = $Matches[2]
                        if ($procPid -eq $PID) { continue }
                        if ($cmdLine -match $escapedPath) {
                            try {
                                Stop-Process -Id $procPid -Force -ErrorAction Stop
                                $killed++
                            } catch {}
                        }
                    }
                }
            }
        }
    } catch {
        # Query failure - non-fatal, best-effort cleanup
    }

    return $killed
}

function Test-JunctionsExist {
    <#
    .SYNOPSIS
    Defense-in-depth check: returns $true if ANY known junction/symlink paths still exist as links.
    Used as a final gate before git worktree remove --force to prevent link-following data loss.
    Detects both Windows junctions (ReparsePoint) and Unix symlinks.
    #>
    param([string]$WorktreePath)

    $botDir = Join-Path $WorktreePath ".bot"
    $junctionPaths = @(
        (Join-Path $botDir ".control"),
        (Join-Path (Join-Path $botDir "workspace") "tasks"),
        (Join-Path (Join-Path $botDir "workspace") "product"),
        (Join-Path $botDir "hooks"),
        (Join-Path $botDir "systems"),
        (Join-Path $botDir "prompts"),
        (Join-Path $botDir "defaults")
    )
    foreach ($jp in $junctionPaths) {
        if (Test-Path -LiteralPath $jp) {
            try {
                $item = Get-Item -LiteralPath $jp -Force
            } catch {
                # Best-effort: if Get-Item fails (access denied, transient IO, broken link),
                # treat as "junctions exist" to avoid unsafe --force removal
                return $true
            }
            # Windows: junctions have ReparsePoint attribute
            # Linux/macOS: symlinks have LinkType set
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
                ($item.LinkType)) {
                return $true
            }
        }
    }
    return $false
}

function Remove-Junctions {
    <#
    .SYNOPSIS
    Remove directory junctions from a worktree without following into shared dirs.
    Returns $true if all junctions were removed, $false otherwise.
    Throws on failure unless -ErrorOnFailure is $false.
    #>
    param(
        [string]$WorktreePath,
        [bool]$ErrorOnFailure = $true
    )

    $junctionPaths = @(
        (Join-Path $WorktreePath ".bot\.control"),
        (Join-Path $WorktreePath ".bot\workspace\tasks"),
        (Join-Path $WorktreePath ".bot\workspace\product"),
        (Join-Path $WorktreePath ".bot\hooks"),
        (Join-Path $WorktreePath ".bot\systems"),
        (Join-Path $WorktreePath ".bot\prompts"),
        (Join-Path $WorktreePath ".bot\defaults")
    )
    $failures = @()
    foreach ($jp in $junctionPaths) {
        if (-not (Test-Path -LiteralPath $jp)) { continue }
        $item = Get-Item -LiteralPath $jp -Force
        $isJunctionOrSymlink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $item.LinkType
        if ($isJunctionOrSymlink) {
            if ($IsWindows) {
                # cmd rmdir removes the junction link without following into target
                cmd /c rmdir "$jp" 2>$null
            } else {
                # On Linux/macOS, New-Item -ItemType Junction creates a symlink;
                # Remove-Item correctly unlinks it without touching the target
                Remove-Item -LiteralPath $jp -Force -ErrorAction SilentlyContinue
            }

            # Fallback: use .NET to remove the junction
            if (Test-Path -LiteralPath $jp) {
                try {
                    [System.IO.Directory]::Delete($jp, $false)
                } catch {
                    # Last resort failed — record it
                }
            }

            # Final check
            if (Test-Path -LiteralPath $jp) {
                $failures += $jp
            }
        }
    }

    if ($failures.Count -gt 0 -and $ErrorOnFailure) {
        throw "Failed to remove junctions: $($failures -join ', ')"
    }
    return ($failures.Count -eq 0)
}

# --- Exported Functions ---

function New-TaskWorktree {
    <#
    .SYNOPSIS
    Create a git branch and worktree for a task, with junctions and artifact copying.

    .OUTPUTS
    Hashtable with: worktree_path, branch_name, success, message
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    Initialize-WorktreeMap -BotRoot $BotRoot

    $shortId = $TaskId.Substring(0, [Math]::Min(8, $TaskId.Length))
    $slug = Get-TaskSlug -TaskName $TaskName
    $branchName = "task/$shortId-$slug"

    # Worktree path: {repo-parent}/worktrees/{repo-name}/task-{shortId}-{slug}/
    $repoParent = Split-Path $ProjectRoot -Parent
    $repoName = Split-Path $ProjectRoot -Leaf
    $worktreeDir = Join-Path $repoParent "worktrees\$repoName"
    $worktreePath = Join-Path $worktreeDir "task-$shortId-$slug"

    if (-not (Test-Path $worktreeDir)) {
        New-Item -Path $worktreeDir -ItemType Directory -Force | Out-Null
    }

    # If worktree directory already exists, validate it's a real worktree
    if (Test-Path $worktreePath) {
        $gitMarker = Join-Path $worktreePath ".git"
        if (Test-Path $gitMarker) {
            # Valid worktree — ensure map entry exists and return it
            $map = Read-WorktreeMap
            if (-not $map.ContainsKey($TaskId)) {
                $map[$TaskId] = @{
                    worktree_path = $worktreePath
                    branch_name   = $branchName
                    task_name     = $TaskName
                    created_at    = (Get-Date).ToUniversalTime().ToString("o")
                }
                Write-WorktreeMap -Map $map
            }
            return @{
                worktree_path = $worktreePath
                branch_name   = $branchName
                success       = $true
                message       = "Worktree already exists"
            }
        } else {
            # Stale leftover directory (no .git marker) — remove and recreate
            Remove-Item -Path $worktreePath -Recurse -Force -ErrorAction SilentlyContinue
            # Also prune git's worktree list so it doesn't think it still exists
            git -C $ProjectRoot worktree prune 2>$null
        }
    }

    try {
        # Create branch from the repo's current branch and check it out in the worktree
        $baseBranch = Get-BaseBranch -ProjectRoot $ProjectRoot
        if (-not $baseBranch) {
            throw "Cannot create worktree: repository has no commits. Make an initial commit first."
        }
        $output = git -C $ProjectRoot worktree add -b $branchName $worktreePath $baseBranch 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Branch may already exist from an interrupted run — try without -b
            $output = git -C $ProjectRoot worktree add $worktreePath $branchName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "git worktree add failed: $($output -join ' ')"
            }
        }

        # Sanity check: verify worktree was actually created
        $gitMarker = Join-Path $worktreePath ".git"
        if (-not (Test-Path $gitMarker)) {
            throw "git worktree add succeeded but .git marker not found in $worktreePath"
        }

        # --- Set up junctions for shared infrastructure ---

        # 1. .bot/.control/ — gitignored, won't exist in worktree
        $worktreeControlDir = Join-Path $worktreePath ".bot\.control"
        $mainControlDir = Join-Path $BotRoot ".control"
        if (-not (Test-Path $worktreeControlDir)) {
            $controlParent = Split-Path $worktreeControlDir -Parent
            if (-not (Test-Path $controlParent)) {
                New-Item -Path $controlParent -ItemType Directory -Force | Out-Null
            }
            New-Item -ItemType Junction -Path $worktreeControlDir -Target $mainControlDir | Out-Null
        }

        # 2. .bot/workspace/tasks/ — has tracked .gitkeep files, replace with junction
        $worktreeTasksDir = Join-Path $worktreePath ".bot\workspace\tasks"
        $mainTasksDir = Join-Path $BotRoot "workspace\tasks"
        if (Test-Path $worktreeTasksDir) {
            Remove-Item -Path $worktreeTasksDir -Recurse -Force
        }
        $tasksParent = Split-Path $worktreeTasksDir -Parent
        if (-not (Test-Path $tasksParent)) {
            New-Item -Path $tasksParent -ItemType Directory -Force | Out-Null
        }
        New-Item -ItemType Junction -Path $worktreeTasksDir -Target $mainTasksDir | Out-Null

        # 3. .bot/hooks/ — verify scripts, commit-bot-state, dev lifecycle
        $worktreeHooksDir = Join-Path $worktreePath ".bot\hooks"
        $mainHooksDir = Join-Path $BotRoot "hooks"
        if ((Test-Path $mainHooksDir) -and -not (Test-Path $worktreeHooksDir)) {
            New-Item -ItemType Junction -Path $worktreeHooksDir -Target $mainHooksDir | Out-Null
        }

        # 4. .bot/systems/ — MCP server, runtime, UI
        $worktreeSystemsDir = Join-Path $worktreePath ".bot\systems"
        $mainSystemsDir = Join-Path $BotRoot "systems"
        if ((Test-Path $mainSystemsDir) -and -not (Test-Path $worktreeSystemsDir)) {
            New-Item -ItemType Junction -Path $worktreeSystemsDir -Target $mainSystemsDir | Out-Null
        }

        # 5. .bot/prompts/ — workflow prompts, research methodologies, standards
        $worktreePromptsDir = Join-Path $worktreePath ".bot\prompts"
        $mainPromptsDir = Join-Path $BotRoot "prompts"
        if ((Test-Path $mainPromptsDir) -and -not (Test-Path $worktreePromptsDir)) {
            New-Item -ItemType Junction -Path $worktreePromptsDir -Target $mainPromptsDir | Out-Null
        }

        # 6. .bot/defaults/ — settings defaults
        $worktreeDefaultsDir = Join-Path $worktreePath ".bot\defaults"
        $mainDefaultsDir = Join-Path $BotRoot "defaults"
        if ((Test-Path $mainDefaultsDir) -and -not (Test-Path $worktreeDefaultsDir)) {
            New-Item -ItemType Junction -Path $worktreeDefaultsDir -Target $mainDefaultsDir | Out-Null
        }

        # 7. .bot/workspace/product/ — shared research outputs and briefing
        $worktreeProductDir = Join-Path $worktreePath ".bot\workspace\product"
        $mainProductDir = Join-Path $BotRoot "workspace\product"
        if (Test-Path $mainProductDir) {
            if (Test-Path $worktreeProductDir) {
                Remove-Item -Path $worktreeProductDir -Recurse -Force
            }
            $productParent = Split-Path $worktreeProductDir -Parent
            if (-not (Test-Path $productParent)) {
                New-Item -Path $productParent -ItemType Directory -Force | Out-Null
            }
            New-Item -ItemType Junction -Path $worktreeProductDir -Target $mainProductDir | Out-Null
        }

        # Copy non-noisy gitignored build artifacts
        Copy-BuildArtifacts -ProjectRoot $ProjectRoot -WorktreePath $worktreePath

        # Register in worktree map
        $map = Read-WorktreeMap
        $map[$TaskId] = @{
            worktree_path = $worktreePath
            branch_name   = $branchName
            task_name     = $TaskName
            created_at    = (Get-Date).ToUniversalTime().ToString("o")
        }
        Write-WorktreeMap -Map $map

        return @{
            worktree_path = $worktreePath
            branch_name   = $branchName
            success       = $true
            message       = "Worktree created at $worktreePath"
        }
    } catch {
        return @{
            worktree_path = $null
            branch_name   = $branchName
            success       = $false
            message       = "Failed to create worktree: $($_.Exception.Message)"
        }
    }
}

function Complete-TaskWorktree {
    <#
    .SYNOPSIS
    Squash-merge a task branch to main, then clean up the worktree and branch.

    .OUTPUTS
    Hashtable with: success, merge_commit, message, conflict_files
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    Initialize-WorktreeMap -BotRoot $BotRoot
    $map = Read-WorktreeMap

    if (-not $map.ContainsKey($TaskId)) {
        return @{
            success        = $true
            merge_commit   = $null
            message        = "No worktree found for task $TaskId (no merge needed)"
            conflict_files = @()
        }
    }

    $entry = $map[$TaskId]
    $worktreePath = $entry.worktree_path
    $branchName = $entry.branch_name
    $taskName = $entry.task_name
    $shortId = $TaskId.Substring(0, [Math]::Min(8, $TaskId.Length))

    try {
        # Ensure main repo is on its base branch
        $baseBranch = Get-BaseBranch -ProjectRoot $ProjectRoot
        $currentBranch = git -C $ProjectRoot rev-parse --abbrev-ref HEAD 2>$null
        if ($currentBranch -ne $baseBranch) {
            git -C $ProjectRoot checkout $baseBranch 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to checkout $baseBranch branch" }
        }

        # Kill any processes still running in the worktree (dev servers, file watchers, etc.)
        $killedCount = Stop-WorktreeProcesses -WorktreePath $worktreePath
        if ($killedCount -gt 0) {
            Start-Sleep -Milliseconds 500  # Brief pause for handles to release
        }

        # Remove junctions BEFORE commit/rebase so git sees real tracked files
        $junctionsClean = Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false

        # Restore tracked files that were replaced by junctions
        git -C $worktreePath checkout -- .bot/workspace/tasks 2>$null
        git -C $worktreePath checkout -- .bot/workspace/product 2>$null

        # Auto-commit any uncommitted work left by Claude CLI
        $worktreeStatus = git -C $worktreePath status --porcelain 2>$null
        if ($worktreeStatus) {
            git -C $worktreePath add -A -- ':!.bot/workspace/tasks/' 2>$null
            git -C $worktreePath commit --quiet -m "chore: auto-commit uncommitted work" 2>$null
        }

        # Rebase task branch onto base branch (brings task commits up to date)
        $rebaseOutput = git -C $worktreePath rebase $baseBranch 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $worktreePath rebase --abort 2>$null
            $conflictLines = @($rebaseOutput | ForEach-Object { "$_" } | Where-Object { $_ -match 'CONFLICT|error|fatal' })
            return @{
                success        = $false
                merge_commit   = $null
                message        = "Rebase failed - conflicts detected"
                conflict_files = $conflictLines
            }
        }

        # Backup live task state before merge (concurrent processes may have written via junctions)
        $taskBackup = @{}
        foreach ($subDir in @('todo','analysing','analysed','needs-input','in-progress','done','skipped','split','cancelled')) {
            $backupDir = Join-Path $ProjectRoot ".bot\workspace\tasks\$subDir"
            $backupFiles = Get-ChildItem $backupDir -Filter "*.json" -File -ErrorAction SilentlyContinue
            foreach ($bf in $backupFiles) {
                try {
                    $taskBackup["$subDir/$($bf.Name)"] = Get-Content $bf.FullName -Raw
                } catch {}
            }
        }

        # Clean tracked + untracked task files so merge can proceed cleanly
        git -C $ProjectRoot checkout -- .bot/workspace/tasks/ 2>$null
        git -C $ProjectRoot clean -fd -- .bot/workspace/tasks/ 2>$null

        # Stash all remaining dirty state (e.g. .gitignore, user edits) so merge can proceed
        $stashOutput = git -C $ProjectRoot stash push -u -m "dotbot-pre-merge-$TaskId" 2>&1
        $wasStashed = $LASTEXITCODE -eq 0 -and "$stashOutput" -notmatch 'No local changes'

        # Squash merge into main
        $mergeOutput = git -C $ProjectRoot merge --squash $branchName 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $ProjectRoot reset --hard HEAD 2>$null
            if ($wasStashed) {
                git -C $ProjectRoot stash pop 2>$null
            }
            # Restore backed-up task state after failed merge
            foreach ($key in $taskBackup.Keys) {
                $restorePath = Join-Path $ProjectRoot ".bot\workspace\tasks\$key"
                $restoreDir = Split-Path $restorePath -Parent
                if (-not (Test-Path $restoreDir)) { New-Item $restoreDir -ItemType Directory -Force | Out-Null }
                $taskBackup[$key] | Set-Content $restorePath -Encoding UTF8
            }
            return @{
                success        = $false
                merge_commit   = $null
                message        = "Squash merge failed: $($mergeOutput -join ' ')"
                conflict_files = @()
            }
        }

        # Discard branch's task state, restore live state from backup
        git -C $ProjectRoot checkout HEAD -- .bot/workspace/tasks/ 2>$null
        foreach ($key in $taskBackup.Keys) {
            $restorePath = Join-Path $ProjectRoot ".bot\workspace\tasks\$key"
            $restoreDir = Split-Path $restorePath -Parent
            if (-not (Test-Path $restoreDir)) { New-Item $restoreDir -ItemType Directory -Force | Out-Null }
            $taskBackup[$key] | Set-Content $restorePath -Encoding UTF8
        }

        # Remove any task JSON files from the merge that weren't in the live backup.
        # The branch may carry stale copies of tasks that moved while the branch was alive
        # (e.g., a task split from todo→split while this branch still had the todo copy).
        foreach ($subDir in @('todo','analysing','analysed','needs-input','in-progress','done','skipped','split','cancelled')) {
            $dir = Join-Path $ProjectRoot ".bot\workspace\tasks\$subDir"
            Get-ChildItem $dir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                $key = "$subDir/$($_.Name)"
                if (-not $taskBackup.ContainsKey($key)) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Commit if there are staged changes (task may have made no code changes)
        $staged = git -C $ProjectRoot diff --cached --name-only 2>$null
        if ($staged) {
            git -C $ProjectRoot commit -m "feat: $taskName [task:$shortId]" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                return @{
                    success        = $false
                    merge_commit   = $null
                    message        = "Commit failed after squash merge"
                    conflict_files = @()
                }
            }
        }

        $mergeCommit = git -C $ProjectRoot rev-parse HEAD 2>$null

        # Commit current task state on main — changes accumulate via junctions
        # but were previously only "accidentally" committed via task branches
        git -C $ProjectRoot add .bot/workspace/tasks/ 2>$null
        git -C $ProjectRoot commit --quiet -m "chore: update task state" 2>$null

        # Auto-push to remote if one is configured
        $pushResult = @{ attempted = $false; success = $false; error = $null }
        $remoteUrl = git -C $ProjectRoot remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteUrl)) {
            $pushResult.attempted = $true
            $pushOutput = git -C $ProjectRoot push origin $baseBranch 2>&1
            if ($LASTEXITCODE -eq 0) {
                $pushResult.success = $true
            } else {
                $pushResult.error = ($pushOutput | Out-String).Trim()
            }
        }

        # Restore stashed state after successful merge+commit
        if ($wasStashed) {
            git -C $ProjectRoot stash pop 2>$null
            if ($LASTEXITCODE -ne 0) {
                # Stash conflicts with merge result — keep merge, drop stash
                git -C $ProjectRoot checkout --theirs -- . 2>$null
                git -C $ProjectRoot add . 2>$null
                git -C $ProjectRoot stash drop 2>$null
            }
        }

        # Remove worktree and branch — only force-remove if junctions were cleaned
        # Defense-in-depth: re-verify no junctions exist right before --force
        if ($junctionsClean -and -not (Test-JunctionsExist -WorktreePath $worktreePath)) {
            git -C $ProjectRoot worktree remove $worktreePath --force 2>$null
        } else {
            if ($junctionsClean) {
                Write-Warning "Junction re-check found surviving junctions in $worktreePath — downgrading to safe removal"
            } else {
                Write-Warning "Skipping force worktree removal — junctions still present in $worktreePath"
            }
            git -C $ProjectRoot worktree remove $worktreePath 2>$null
        }
        git -C $ProjectRoot branch -D $branchName 2>$null

        # Remove from registry
        $map.Remove($TaskId)
        Write-WorktreeMap -Map $map

        return @{
            success        = $true
            merge_commit   = $mergeCommit
            message        = "Squash-merged to $baseBranch and cleaned up"
            conflict_files = @()
            push_result    = $pushResult
        }
    } catch {
        return @{
            success        = $false
            merge_commit   = $null
            message        = "Error during merge: $($_.Exception.Message)"
            conflict_files = @()
        }
    }
}

function Get-TaskWorktreePath {
    <#
    .SYNOPSIS
    Look up the worktree path for a given task ID.

    .OUTPUTS
    Path string or $null if not found / not on disk
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$BotRoot
    )

    Initialize-WorktreeMap -BotRoot $BotRoot
    $map = Read-WorktreeMap
    if ($map.ContainsKey($TaskId)) {
        $path = $map[$TaskId].worktree_path
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Get-TaskWorktreeInfo {
    <#
    .SYNOPSIS
    Look up the full worktree registry entry for a task ID.

    .OUTPUTS
    PSObject with worktree_path, branch_name, task_name, created_at — or $null
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$BotRoot
    )

    Initialize-WorktreeMap -BotRoot $BotRoot
    $map = Read-WorktreeMap
    if ($map.ContainsKey($TaskId)) { return $map[$TaskId] }
    return $null
}

function Get-GitignoredCopyPaths {
    <#
    .SYNOPSIS
    Find gitignored files that exist in the repo, excluding noisy regenerable dirs.

    .OUTPUTS
    Array of relative paths (small config files like .env)
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    try {
        $ignoredFiles = git -C $ProjectRoot ls-files --others --ignored --exclude-standard 2>$null
        if (-not $ignoredFiles -or $LASTEXITCODE -ne 0) { return @() }

        $paths = @()
        foreach ($relativePath in $ignoredFiles) {
            $parts = $relativePath -split '[/\\]'
            $isNoisy = $false
            foreach ($part in $parts) {
                if ($script:NoiseDirectories -contains $part) {
                    $isNoisy = $true
                    break
                }
            }
            if (-not $isNoisy) {
                $paths += $relativePath
            }
        }
        return $paths
    } catch {
        return @()
    }
}

function Copy-BuildArtifacts {
    <#
    .SYNOPSIS
    Copy non-noisy gitignored files from main repo to worktree.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $paths = Get-GitignoredCopyPaths -ProjectRoot $ProjectRoot
    if ($paths.Count -eq 0) { return }

    foreach ($relativePath in $paths) {
        $sourcePath = Join-Path $ProjectRoot $relativePath
        $destPath = Join-Path $WorktreePath $relativePath

        if (-not (Test-Path $sourcePath)) { continue }

        $destParent = Split-Path $destPath -Parent
        if (-not (Test-Path $destParent)) {
            New-Item -Path $destParent -ItemType Directory -Force | Out-Null
        }

        try {
            if (Test-Path $sourcePath -PathType Container) {
                Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
            } else {
                Copy-Item -Path $sourcePath -Destination $destPath -Force
            }
        } catch {
            # Non-critical — skip files that can't be copied
        }
    }
}

function Remove-OrphanWorktrees {
    <#
    .SYNOPSIS
    Clean up worktrees for tasks that are no longer active (done/skipped/cancelled).
    Called on process startup.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    Initialize-WorktreeMap -BotRoot $BotRoot
    $map = Read-WorktreeMap
    if ($map.Count -eq 0) { return }

    $tasksBaseDir = Join-Path $BotRoot "workspace\tasks"
    $activeDirs = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress')
    $orphanIds = @()

    foreach ($taskId in @($map.Keys)) {
        $isActive = $false
        foreach ($dir in $activeDirs) {
            $dirPath = Join-Path $tasksBaseDir $dir
            if (-not (Test-Path $dirPath)) { continue }
            $files = Get-ChildItem -Path $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                try {
                    $content = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json
                    if ($content.id -eq $taskId) {
                        $isActive = $true
                        break
                    }
                } catch {}
            }
            if ($isActive) { break }
        }
        if (-not $isActive) { $orphanIds += $taskId }
    }

    foreach ($taskId in $orphanIds) {
        $entry = $map[$taskId]
        $worktreePath = $entry.worktree_path
        $branchName = $entry.branch_name

        # Kill any lingering processes in the orphan worktree before cleanup
        if ($worktreePath -and (Test-Path $worktreePath)) {
            $killedCount = Stop-WorktreeProcesses -WorktreePath $worktreePath
            if ($killedCount -gt 0) {
                Start-Sleep -Milliseconds 500
            }
        }

        # Remove junctions first, then only force-remove if junctions are clean
        $junctionsClean = $true
        if ($worktreePath -and (Test-Path $worktreePath)) {
            $junctionsClean = Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false
        }

        # Defense-in-depth: re-verify no junctions exist right before --force
        # Guard against null/missing worktree paths from stale map entries
        if ($junctionsClean -and $worktreePath -and (Test-Path $worktreePath) -and -not (Test-JunctionsExist -WorktreePath $worktreePath)) {
            git -C $ProjectRoot worktree remove $worktreePath --force 2>$null
        } elseif ($worktreePath -and (Test-Path $worktreePath)) {
            if ($junctionsClean) {
                Write-Warning "Junction re-check found surviving junctions in orphan $taskId — downgrading to safe removal"
            } else {
                Write-Warning "Skipping force worktree removal for orphan $taskId — junctions still present"
            }
            git -C $ProjectRoot worktree remove $worktreePath 2>$null
        }
        git -C $ProjectRoot branch -D $branchName 2>$null

        $map.Remove($taskId)
    }

    if ($orphanIds.Count -gt 0) {
        Write-WorktreeMap -Map $map
    }
}

# --- Module Exports ---
Export-ModuleMember -Function @(
    'Initialize-WorktreeMap'
    'Read-WorktreeMap'
    'Write-WorktreeMap'
    'Stop-WorktreeProcesses'
    'Remove-Junctions'
    'New-TaskWorktree'
    'Complete-TaskWorktree'
    'Get-TaskWorktreePath'
    'Get-TaskWorktreeInfo'
    'Get-GitignoredCopyPaths'
    'Copy-BuildArtifacts'
    'Remove-OrphanWorktrees'
)
