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

Shared infrastructure via directory links (junctions on Windows, symlinks on macOS/Linux):
  .bot/.control/          -> central control (process registry, settings)
  .bot/workspace/tasks/   -> central task queue (todo, done, etc.)
  .bot/workspace/product/ -> shared research outputs and briefing
  .bot/hooks/             -> verification scripts, commit-bot-state, dev lifecycle
  .bot/systems/           -> MCP server, runtime, UI
  .bot/recipes/           -> agents, skills, prompts, research, standards
  .bot/settings/          -> settings defaults
#>

# --- Internal State ---
$script:WorktreeMapPath = $null

# Large, regenerable directories excluded from gitignored file copying
$script:NoiseDirectories = @(
    'bin', 'obj', 'node_modules', 'packages',
    'Debug', 'Release', 'x64', 'x86',
    '.vs', '.idea', '.vscode',
    '__pycache__', '.mypy_cache',
    '.git', '.control', '.serena',
    'TestResults', 'test-results', 'playwright-report',
    'sessions'
)

# --- Internal Helpers ---

function Assert-PathWithinBounds {
    <#
    .SYNOPSIS
    Validates that a resolved path is within an expected root directory.
    Prevents path traversal attacks when paths are constructed from external data.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRoot
    )
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedRoot = [System.IO.Path]::GetFullPath($ExpectedRoot)
    if (-not $resolvedPath.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$Path' resolves to '$resolvedPath' which is outside expected root '$resolvedRoot'"
    }
}

function Invoke-Git {
    <#
    .SYNOPSIS
    Standardized git invocation with proper stdout/stderr separation and exit code handling.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory,
        [switch]$SilentFail
    )
    # Scoped PS 7.4+ preference: makes git failures throw catchable errors
    $PSNativeCommandUseErrorActionPreference = $true

    $gitArgs = @()
    if ($WorkingDirectory) { $gitArgs += @('-C', $WorkingDirectory) }
    $gitArgs += $Arguments

    $output = & git @gitArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
        if ($SilentFail) {
            Write-BotLog -Level Debug -Message "Git failed (exit $exitCode): git $($Arguments -join ' '): $stderr"
            return $null
        }
        throw "git $($Arguments -join ' ') failed (exit $exitCode): $stderr"
    }
    @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

function Get-BaseBranch {
    param([string]$ProjectRoot)
    $branch = Invoke-Git -Arguments @('symbolic-ref', '--short', 'HEAD') -WorkingDirectory $ProjectRoot -SilentFail
    if ($branch) {
        $verify = Invoke-Git -Arguments @('rev-parse', '--verify', $branch.Trim()) -WorkingDirectory $ProjectRoot -SilentFail
        if ($verify) { return $branch.Trim() }
    }
    foreach ($candidate in @('main', 'master')) {
        $verify = Invoke-Git -Arguments @('rev-parse', '--verify', $candidate) -WorkingDirectory $ProjectRoot -SilentFail
        if ($verify) { return $candidate }
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
        Write-BotLog -Level Debug -Message "Worktree map read failed" -Exception $_
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

function Resolve-MainBranch {
    <#
    .SYNOPSIS
    Find the canonical integration branch (main or master) by explicit name lookup.
    Never reads symbolic HEAD — safe to call when the main repo may be on a task branch.
    #>
    param([string]$ProjectRoot)
    foreach ($candidate in @('main', 'master')) {
        git -C $ProjectRoot rev-parse --verify $candidate 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    return $null
}

function Assert-OnBaseBranch {
    <#
    .SYNOPSIS
    Ensure the main repo is checked out on the specified branch (or the canonical
    main/master if none is specified). Checks out the branch if not already on it.
    Throws if the branch cannot be found or checked out.
    Returns the confirmed base branch name.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$BranchName
    )
    if (-not $BranchName) {
        $BranchName = Resolve-MainBranch -ProjectRoot $ProjectRoot
    }
    if (-not $BranchName) {
        throw "Cannot find base branch in $ProjectRoot"
    }
    $currentBranch = git -C $ProjectRoot rev-parse --abbrev-ref HEAD 2>$null
    if ($currentBranch -ne $BranchName) {
        git -C $ProjectRoot checkout $BranchName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to checkout $BranchName in $ProjectRoot (currently on: $currentBranch)"
        }
    }
    return $BranchName
}

function Invoke-WorktreeMapLocked {
    <#
    .SYNOPSIS
    Execute a script block with an exclusive lock on the worktree map file.
    Uses [System.IO.File]::Open with FileMode::CreateNew for atomic, cross-platform
    locking (Windows: CreateFile CREATE_NEW; Linux/macOS: open O_CREAT|O_EXCL).
    Retries on contention with linear backoff up to TimeoutSeconds.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutSeconds = 10
    )
    if (-not $script:WorktreeMapPath) { & $Action; return }
    $lockFile = "$($script:WorktreeMapPath).lock"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $attempt = 0
    while ($true) {
        $lockStream = $null
        try {
            $lockStream = [System.IO.File]::Open(
                $lockFile,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
            # Lock acquired — run the action
            & $Action
            return
        } catch [System.IO.IOException] {
            # Lock held by another process — wait and retry
            if ([DateTime]::UtcNow -ge $deadline) {
                # Timed out — assume stale lock, remove and retry with proper lock acquisition
                Write-BotLog -Level Warn -Message "Worktree map lock timeout after ${TimeoutSeconds}s — removing stale lock"
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
                try {
                    $lockStream = [System.IO.File]::Open(
                        $lockFile,
                        [System.IO.FileMode]::CreateNew,
                        [System.IO.FileAccess]::ReadWrite,
                        [System.IO.FileShare]::None)
                    & $Action
                    return
                } catch [System.IO.IOException] {
                    # Another process grabbed the lock after our removal — run unlocked as last resort
                    Write-BotLog -Level Warn -Message "Worktree map lock contention after stale removal — proceeding without lock"
                    & $Action
                    return
                }
            }
            $attempt++
            Start-Sleep -Milliseconds ([Math]::Min(50 * $attempt, 500))
        } finally {
            if ($lockStream) {
                $lockStream.Dispose()
                Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
            }
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
                } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process $($proc.ProcessId)" -Exception $_ }
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
                            } catch { Write-BotLog -Level Debug -Message "Cleanup: failed to stop process ${procPid}" -Exception $_ }
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

function New-DirectoryLink {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )
    # Windows: NTFS junctions (no elevation required)
    # macOS/Linux: symbolic links
    if ($IsWindows) {
        New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    } else {
        New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    }
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
        (Join-Path $botDir "recipes"),
        (Join-Path $botDir "settings")
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
    Remove directory junctions (Windows) and symlinks (macOS/Linux) from a worktree without following into shared dirs.
    Returns $true if all links were removed, $false otherwise.
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
        (Join-Path $WorktreePath ".bot\recipes"),
        (Join-Path $WorktreePath ".bot\settings")
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
                # On Linux/macOS, Remove-Item correctly unlinks symlinks without touching the target
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
            $existingBaseBranch = Resolve-MainBranch -ProjectRoot $ProjectRoot
            Invoke-WorktreeMapLocked -Action {
                $lockedMap = Read-WorktreeMap
                if (-not $lockedMap.ContainsKey($TaskId)) {
                    $lockedMap[$TaskId] = @{
                        worktree_path = $worktreePath
                        branch_name   = $branchName
                        base_branch   = $existingBaseBranch
                        task_name     = $TaskName
                        created_at    = (Get-Date).ToUniversalTime().ToString("o")
                    }
                    Write-WorktreeMap -Map $lockedMap
                }
            }
            return @{
                worktree_path = $worktreePath
                branch_name   = $branchName
                success       = $true
                message       = "Worktree already exists"
            }
        } else {
            # Stale leftover directory (no .git marker) — remove and recreate
            Assert-PathWithinBounds -Path $worktreePath -ExpectedRoot $worktreeDir
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

        # --- Set up directory links for shared infrastructure ---
        # Windows: NTFS junctions (no elevation required)
        # macOS/Linux: symbolic links

        # 1. .bot/.control/ — gitignored, won't exist in worktree
        $worktreeControlDir = Join-Path $worktreePath ".bot\.control"
        $mainControlDir = Join-Path $BotRoot ".control"
        if (-not (Test-Path $worktreeControlDir)) {
            $controlParent = Split-Path $worktreeControlDir -Parent
            if (-not (Test-Path $controlParent)) {
                New-Item -Path $controlParent -ItemType Directory -Force | Out-Null
            }
            New-DirectoryLink -Path $worktreeControlDir -Target $mainControlDir
        }

        # 2. .bot/workspace/tasks/ — has tracked .gitkeep files, replace with junction
        $worktreeTasksDir = Join-Path $worktreePath ".bot\workspace\tasks"
        $mainTasksDir = Join-Path $BotRoot "workspace\tasks"
        if (Test-Path $worktreeTasksDir) {
            Assert-PathWithinBounds -Path $worktreeTasksDir -ExpectedRoot $worktreePath
            Remove-Item -Path $worktreeTasksDir -Recurse -Force
        }
        $tasksParent = Split-Path $worktreeTasksDir -Parent
        if (-not (Test-Path $tasksParent)) {
            New-Item -Path $tasksParent -ItemType Directory -Force | Out-Null
        }
        New-DirectoryLink -Path $worktreeTasksDir -Target $mainTasksDir

        # 3. .bot/hooks/ — verify scripts, commit-bot-state, dev lifecycle
        $worktreeHooksDir = Join-Path $worktreePath ".bot\hooks"
        $mainHooksDir = Join-Path $BotRoot "hooks"
        if ((Test-Path $mainHooksDir) -and -not (Test-Path $worktreeHooksDir)) {
            New-DirectoryLink -Path $worktreeHooksDir -Target $mainHooksDir
        }

        # 4. .bot/systems/ — MCP server, runtime, UI
        $worktreeSystemsDir = Join-Path $worktreePath ".bot\systems"
        $mainSystemsDir = Join-Path $BotRoot "systems"
        if ((Test-Path $mainSystemsDir) -and -not (Test-Path $worktreeSystemsDir)) {
            New-DirectoryLink -Path $worktreeSystemsDir -Target $mainSystemsDir
        }

        # 5. .bot/recipes/ — recipes, research methodologies, standards
        $worktreeRecipesDir = Join-Path $worktreePath ".bot\recipes"
        $mainRecipesDir = Join-Path $BotRoot "recipes"
        if ((Test-Path $mainRecipesDir) -and -not (Test-Path $worktreeRecipesDir)) {
            New-DirectoryLink -Path $worktreeRecipesDir -Target $mainRecipesDir
        }

        # 6. .bot/settings/ — settings defaults
        $worktreeSettingsDir = Join-Path $worktreePath ".bot\settings"
        $mainSettingsDir = Join-Path $BotRoot "settings"
        if ((Test-Path $mainSettingsDir) -and -not (Test-Path $worktreeSettingsDir)) {
            New-DirectoryLink -Path $worktreeSettingsDir -Target $mainSettingsDir
        }

        # 7. .bot/workspace/product/ — shared research outputs and briefing
        $worktreeProductDir = Join-Path $worktreePath ".bot\workspace\product"
        $mainProductDir = Join-Path $BotRoot "workspace\product"
        if (Test-Path $mainProductDir) {
            if (Test-Path $worktreeProductDir) {
                Assert-PathWithinBounds -Path $worktreeProductDir -ExpectedRoot $worktreePath
                Remove-Item -Path $worktreeProductDir -Recurse -Force
            }
            $productParent = Split-Path $worktreeProductDir -Parent
            if (-not (Test-Path $productParent)) {
                New-Item -Path $productParent -ItemType Directory -Force | Out-Null
            }
            New-DirectoryLink -Path $worktreeProductDir -Target $mainProductDir
        }

        # Copy non-noisy gitignored build artifacts
        Copy-BuildArtifacts -ProjectRoot $ProjectRoot -WorktreePath $worktreePath

        # Register in worktree map (locked read-modify-write to prevent concurrent entry loss)
        Invoke-WorktreeMapLocked -Action {
            $lockedMap = Read-WorktreeMap
            $lockedMap[$TaskId] = @{
                worktree_path = $worktreePath
                branch_name   = $branchName
                base_branch   = $baseBranch
                task_name     = $TaskName
                created_at    = (Get-Date).ToUniversalTime().ToString("o")
            }
            Write-WorktreeMap -Map $lockedMap
        }

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
        # Determine target base branch — prefer the value recorded at worktree creation
        # (immune to HEAD drift on the main repo); fall back to explicit main/master lookup.
        $baseBranch = $entry.base_branch ?? (Resolve-MainBranch -ProjectRoot $ProjectRoot)
        if (-not $baseBranch) { throw "Cannot determine base branch for task $TaskId" }

        # Assert main repo is on the base branch before any git operation (Fix: wrong-branch merge)
        Assert-OnBaseBranch -ProjectRoot $ProjectRoot -BranchName $baseBranch | Out-Null

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

        # Ensure clean index before rebase — auto-commit may fail silently
        # (e.g. pre-commit hook blocks .env.local with secrets)
        $indexDirty = git -C $worktreePath diff --cached --name-only 2>$null
        if ($indexDirty) {
            git -C $worktreePath reset 2>$null
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
                } catch { Write-BotLog -Level Debug -Message "Failed to read task backup $($bf.FullName)" -Exception $_ }
            }
        }

        # Clean tracked + untracked task files so merge can proceed cleanly
        git -C $ProjectRoot checkout -- .bot/workspace/tasks/ 2>$null
        git -C $ProjectRoot clean -fd -- .bot/workspace/tasks/ 2>$null

        # Stash remaining dirty state EXCLUDING task files (task state is managed by backup-restore).
        # Including task files in the stash causes stale state to be reintroduced after the state commit
        # when git stash pop runs, contaminating the next task's backup.
        $stashOutput = git -C $ProjectRoot stash push -u -m "dotbot-pre-merge-$TaskId" -- ':!.bot/workspace/tasks/' 2>&1
        $wasStashed = $LASTEXITCODE -eq 0 -and "$stashOutput" -notmatch 'No local changes'

        # Validate task branch still exists before attempting merge (Fix: branch_not_found)
        git -C $ProjectRoot rev-parse --verify $branchName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($wasStashed) { git -C $ProjectRoot stash pop 2>$null }
            foreach ($key in $taskBackup.Keys) {
                $restorePath = Join-Path $ProjectRoot ".bot\workspace\tasks\$key"
                $restoreDir = Split-Path $restorePath -Parent
                if (-not (Test-Path $restoreDir)) { New-Item $restoreDir -ItemType Directory -Force | Out-Null }
                $taskBackup[$key] | Set-Content $restorePath -Encoding UTF8
            }
            return @{
                success        = $false
                merge_commit   = $null
                message        = "Branch $branchName no longer exists — cannot merge task $TaskId"
                conflict_files = @()
            }
        }

        # Squash merge into main
        $mergeOutput = git -C $ProjectRoot merge --squash $branchName 2>&1
        if ($LASTEXITCODE -ne 0) {
            git -C $ProjectRoot reset --hard HEAD 2>$null
            # Re-assert base branch after reset — leaves repo in a known good state (Fix: wrong-branch merge)
            Assert-OnBaseBranch -ProjectRoot $ProjectRoot -BranchName $baseBranch | Out-Null
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
                git -C $ProjectRoot reset --hard HEAD 2>$null
                # Re-assert base branch after reset (Fix: wrong-branch merge)
                Assert-OnBaseBranch -ProjectRoot $ProjectRoot -BranchName $baseBranch | Out-Null
                if ($wasStashed) { git -C $ProjectRoot stash pop 2>$null }
                foreach ($key in $taskBackup.Keys) {
                    $restorePath = Join-Path $ProjectRoot ".bot\workspace\tasks\$key"
                    $restoreDir = Split-Path $restorePath -Parent
                    if (-not (Test-Path $restoreDir)) { New-Item $restoreDir -ItemType Directory -Force | Out-Null }
                    $taskBackup[$key] | Set-Content $restorePath -Encoding UTF8
                }
                return @{
                    success        = $false
                    merge_commit   = $null
                    message        = "Commit failed after squash merge"
                    conflict_files = @()
                }
            }
        }

        $mergeCommit = git -C $ProjectRoot rev-parse HEAD 2>$null

        # Remove duplicate task files: if a task exists in both a non-terminal directory
        # and done/, the non-terminal copy is stale and must be removed before committing.
        # This is a defensive measure against any mechanism that reintroduces stale files
        # (stash pop, junction race conditions, Reset function edge cases).
        $doneDir = Join-Path $ProjectRoot ".bot\workspace\tasks\done"
        $todoDir = Join-Path $ProjectRoot ".bot\workspace\tasks\todo"
        if ((Test-Path $doneDir) -and (Test-Path $todoDir)) {
            $doneFileNames = @{}
            Get-ChildItem $doneDir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                $doneFileNames[$_.Name] = $true
            }
            Get-ChildItem $todoDir -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                if ($doneFileNames.ContainsKey($_.Name)) {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
            foreach ($intermediateDir in @('analysing', 'analysed', 'in-progress', 'needs-input')) {
                $dirPath = Join-Path $ProjectRoot ".bot\workspace\tasks\$intermediateDir"
                if (Test-Path $dirPath) {
                    Get-ChildItem $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($doneFileNames.ContainsKey($_.Name)) {
                            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
        }

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
                Write-BotLog -Level Warn -Message "Junction re-check found surviving junctions in $worktreePath — downgrading to safe removal"
            } else {
                Write-BotLog -Level Warn -Message "Skipping force worktree removal — junctions still present in $worktreePath"
            }
            git -C $ProjectRoot worktree remove $worktreePath 2>$null
        }
        # Verify worktree is actually gone (Fix: silent removal failures)
        if (Test-Path $worktreePath) {
            Write-BotLog -Level Warn -Message "Worktree removal incomplete — path still exists: $worktreePath. Will be retried on next startup."
        }
        git -C $ProjectRoot branch -D $branchName 2>$null

        # Remove from registry (locked read-modify-write to prevent concurrent entry loss)
        Invoke-WorktreeMapLocked -Action {
            $lockedMap = Read-WorktreeMap
            $lockedMap.Remove($TaskId)
            Write-WorktreeMap -Map $lockedMap
        }

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
    # 'done' is included: tasks that just completed execution may still have a live worktree
    # pending squash-merge by Complete-TaskWorktree. Removing them here would race with that.
    $activeDirs = @('todo', 'analysing', 'needs-input', 'analysed', 'in-progress', 'done')
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
                } catch { Write-BotLog -Level Debug -Message "Failed to read task file $($f.FullName)" -Exception $_ }
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
                Write-BotLog -Level Warn -Message "Junction re-check found surviving junctions in orphan $taskId — downgrading to safe removal"
            } else {
                Write-BotLog -Level Warn -Message "Skipping force worktree removal for orphan $taskId — junctions still present"
            }
            git -C $ProjectRoot worktree remove $worktreePath 2>$null
        }
        # Verify worktree is actually gone (Fix: silent removal failures)
        if ($worktreePath -and (Test-Path $worktreePath)) {
            Write-BotLog -Level Warn -Message "Orphan worktree removal incomplete — path still exists: $worktreePath"
        }
        git -C $ProjectRoot branch -D $branchName 2>$null
    }

    if ($orphanIds.Count -gt 0) {
        # Locked read-modify-write — prevents concurrent processes from losing map entries
        Invoke-WorktreeMapLocked -Action {
            $lockedMap = Read-WorktreeMap
            foreach ($id in $orphanIds) { $lockedMap.Remove($id) }
            Write-WorktreeMap -Map $lockedMap
        }
    }
}

# --- Module Exports ---
Export-ModuleMember -Function @(
    'Initialize-WorktreeMap'
    'Read-WorktreeMap'
    'Write-WorktreeMap'
    'Invoke-WorktreeMapLocked'
    'Resolve-MainBranch'
    'Assert-OnBaseBranch'
    'Stop-WorktreeProcesses'
    'Invoke-Git'
    'Remove-Junctions'
    'New-TaskWorktree'
    'Complete-TaskWorktree'
    'Get-TaskWorktreePath'
    'Get-TaskWorktreeInfo'
    'Get-GitignoredCopyPaths'
    'Copy-BuildArtifacts'
    'Remove-OrphanWorktrees'
)
