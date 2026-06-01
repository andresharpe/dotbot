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
  .bot/workspace/product/ -> branch-local product artifacts and briefing
  .bot/hooks/             -> verification scripts, commit-bot-state, dev lifecycle
  .bot/systems/           -> MCP server, runtime, UI
  .bot/recipes/           -> agents, skills, prompts, research, standards
  .bot/settings/          -> settings defaults

Required manifest dependencies: Dotbot.TaskFile.
#>

# Large, regenerable directories excluded from gitignored file copying
$script:NoiseDirectories = @(
    'bin', 'obj', 'node_modules', 'packages',
    'Debug', 'Release', 'x64', 'x86',
    '.vs', '.idea', '.vscode',
    '__pycache__', '.mypy_cache',
    '.git', '.control',
    'TestResults', 'test-results', 'playwright-report',
    'sessions'
)

$script:SharedWorktreeCopyPathPrefixes = @(
    # These paths are linked from task worktrees back to the main checkout.
    '.bot/.control',
    '.bot/workspace/tasks'
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


function Get-WorktreeMapPath {
    # Resolves to <BotRoot>/.control/worktree-map.json. BotRoot defaults to the
    # nearest .bot/ ancestor of $PWD; callers pass it explicitly for tests
    # or out-of-tree invocations.
    param([string]$BotRoot)
    if (-not $BotRoot) { $BotRoot = Get-DotbotProjectBotPath }
    Join-Path $BotRoot ".control" "worktree-map.json"
}

function Read-WorktreeMap {
    param([string]$BotRoot)
    $path = Get-WorktreeMapPath -BotRoot $BotRoot
    if (-not (Test-Path $path)) { return @{} }
    try {
        $content = Get-Content $path -Raw
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
    param(
        [Parameter(Mandatory)][hashtable]$Map,
        [string]$BotRoot
    )
    $path = Get-WorktreeMapPath -BotRoot $BotRoot
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    $tempFile = "$path.tmp"
    for ($r = 0; $r -lt 3; $r++) {
        try {
            $Map | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding utf8NoBOM -NoNewline
            Move-Item -Path $tempFile -Destination $path -Force -ErrorAction Stop
            return
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            if ($r -lt 2) { Start-Sleep -Milliseconds (50 * ($r + 1)) }
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

function Test-RepositoryHasCommits {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $count = $null
    try {
        $stdout = git -C $ProjectRoot rev-list --count HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $stdout) {
            $count = [int]($stdout.ToString().Trim())
        }
    } catch {
        $count = $null
    }
    return ($count -and $count -gt 0)
}

function Resolve-UnbornBaseBranch {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    if (Test-RepositoryHasCommits -ProjectRoot $ProjectRoot) { return $null }
    $branch = (git -C $ProjectRoot symbolic-ref --quiet --short HEAD 2>$null) -as [string]
    $branch = if ($branch) { $branch.Trim() } else { '' }
    if ($branch) { return $branch }
    return 'main'
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
    if ($currentBranch -eq 'HEAD') {
        $symbolicBranch = git -C $ProjectRoot symbolic-ref --quiet --short HEAD 2>$null
        if ($symbolicBranch -and $symbolicBranch.Trim() -eq $BranchName) {
            return $BranchName
        }
    }
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
        [int]$TimeoutSeconds = 10,
        [string]$BotRoot
    )
    $lockFile = "$(Get-WorktreeMapPath -BotRoot $BotRoot).lock"
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
            $gitBashStyle = $forwardSlash -replace '^([A-Za-z]):', { '/' + $_.Groups[1].Value.ToLowerInvariant() }
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

function Get-DotbotWorktreeFrameworkRoot {
    if (Get-Command Get-DotbotInstallPath -ErrorAction SilentlyContinue) {
        return Get-DotbotInstallPath
    }

    $configuredHome = [Environment]::GetEnvironmentVariable('DOTBOT_HOME')
    if (-not [string]::IsNullOrWhiteSpace($configuredHome)) {
        $configuredHome = $configuredHome.Trim()
        if ($configuredHome -eq '~') {
            $configuredHome = $HOME
        } elseif ($configuredHome.StartsWith('~/') -or $configuredHome.StartsWith('~\')) {
            $configuredHome = Join-Path $HOME $configuredHome.Substring(2)
        }
        try { return [System.IO.Path]::GetFullPath($configuredHome) } catch { return $configuredHome }
    }

    $modulesDir = Split-Path -Parent $PSScriptRoot
    $runtimeDir = Split-Path -Parent $modulesDir
    $srcDir = Split-Path -Parent $runtimeDir
    return (Split-Path -Parent $srcDir)
}

function Copy-DotbotDirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -Path $Destination -ItemType Directory -Force | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
}

function Get-DistinctDotbotUserContentRoot {
    param([Parameter(Mandatory)][string]$FrameworkRoot)

    if (-not (Get-Command Get-DotbotUserContentPath -ErrorAction SilentlyContinue)) {
        return $null
    }

    $userContentRoot = Get-DotbotUserContentPath
    if ([string]::IsNullOrWhiteSpace($userContentRoot)) { return $null }

    $frameworkContentRoot = Join-Path $FrameworkRoot 'content'
    try {
        $userFull = [System.IO.Path]::GetFullPath($userContentRoot).TrimEnd('\','/')
        $frameworkFull = [System.IO.Path]::GetFullPath($frameworkContentRoot).TrimEnd('\','/')
        if ([string]::Equals($userFull, $frameworkFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
    } catch {
        return $userContentRoot
    }

    return $userContentRoot
}

function Reset-DotbotGeneratedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    Remove-DotbotGeneratedPath -Path $Path -WorktreePath $WorktreePath
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function Remove-DotbotGeneratedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    Assert-PathWithinBounds -Path $Path -ExpectedRoot $WorktreePath
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($item) {
            $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $item.LinkType
            if ($isLink) {
                if ($IsWindows) {
                    cmd /c rmdir "$Path" 2>$null
                } else {
                    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path -LiteralPath $Path) {
                    try { [System.IO.Directory]::Delete($Path, $false) } catch {}
                }
            } else {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function ConvertTo-DotbotTomlString {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Ensure-DotbotWorktreeExcludes {
    param([Parameter(Mandatory)][string]$WorktreePath)

    $excludePath = git -C $WorktreePath rev-parse --git-path info/exclude 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $excludePath) { return }
    if (-not [System.IO.Path]::IsPathRooted($excludePath)) {
        $excludePath = Join-Path $WorktreePath $excludePath
    }

    $excludeDir = Split-Path $excludePath -Parent
    if (-not (Test-Path -LiteralPath $excludeDir)) {
        New-Item -Path $excludeDir -ItemType Directory -Force | Out-Null
    }

    $markerStart = '# dotbot generated execution environment: start'
    $markerEnd = '# dotbot generated execution environment: end'
    $blockLines = @(
        $markerStart
        '.mcp.json'
        '.claude/'
        '.codex/'
        '.opencode/'
        '.agents/'
        # Legacy Gemini CLI paths are still excluded so upgraded worktrees cannot
        # accidentally replay stale generated files.
        '.gemini/'
        '.bot/.control'
        '.bot/.control/'
        '.bot/.handoffs'
        '.bot/.handoffs/'
        '.bot/workspace/tasks'
        '.bot/workspace/tasks/'
        '.bot/content/'
        '.bot/hooks/'
        '.bot/settings/'
        $markerEnd
    )

    $existing = if (Test-Path -LiteralPath $excludePath) { Get-Content -LiteralPath $excludePath -Raw } else { '' }
    if ($existing -match [regex]::Escape($markerStart)) {
        $pattern = "(?s)$([regex]::Escape($markerStart)).*?$([regex]::Escape($markerEnd))"
        $existing = [regex]::Replace($existing, $pattern, ($blockLines -join "`n"))
    } else {
        if ($existing -and -not $existing.EndsWith("`n")) { $existing += "`n" }
        $existing += ($blockLines -join "`n")
    }
    Set-Content -Path $excludePath -Value $existing -Encoding utf8NoBOM
}

function Set-DotbotMcpServerJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $mcpConfig = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $mcpConfig = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if (-not $mcpConfig.PSObject.Properties['mcpServers']) {
                $mcpConfig | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
            }
        } catch {
            $mcpConfig = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        }
    }

    $mcpScript = Join-Path $FrameworkRoot 'src/mcp/dotbot-mcp.ps1'
    $server = [ordered]@{
        command = 'pwsh'
        args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mcpScript)
        env     = [ordered]@{
            DOTBOT_HOME         = $FrameworkRoot
            DOTBOT_PROJECT_ROOT = $WorktreePath
        }
    }
    $mcpConfig.mcpServers | Add-Member -NotePropertyName dotbot -NotePropertyValue $server -Force

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $mcpConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Set-DotbotCodexMcpConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $mcpScript = Join-Path $FrameworkRoot 'src/mcp/dotbot-mcp.ps1'
    $lines = @(
        '# Generated by dotbot for this execution worktree.'
        '[mcp_servers.dotbot]'
        'command = "pwsh"'
        ('args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", {0}]' -f (ConvertTo-DotbotTomlString $mcpScript))
        ''
        '[mcp_servers.dotbot.env]'
        ('DOTBOT_HOME = {0}' -f (ConvertTo-DotbotTomlString $FrameworkRoot))
        ('DOTBOT_PROJECT_ROOT = {0}' -f (ConvertTo-DotbotTomlString $WorktreePath))
        ''
    )
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Set-Content -Path $Path -Value ($lines -join "`n") -Encoding utf8NoBOM
}

function Set-DotbotAntigravityMcpConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $settings = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if (-not $settings.PSObject.Properties['mcpServers']) {
                $settings | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
            }
        } catch {
            $settings = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        }
    }

    $mcpScript = Join-Path $FrameworkRoot 'src/mcp/dotbot-mcp.ps1'
    $server = [ordered]@{
        command = 'pwsh'
        args    = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mcpScript)
        env     = [ordered]@{
            DOTBOT_HOME         = $FrameworkRoot
            DOTBOT_PROJECT_ROOT = $WorktreePath
        }
    }
    $settings.mcpServers | Add-Member -NotePropertyName dotbot -NotePropertyValue $server -Force

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Set-DotbotOpenCodeMcpConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $config = [pscustomobject]@{
        '$schema' = 'https://opencode.ai/config.json'
        mcp       = [pscustomobject]@{}
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if (-not $config.PSObject.Properties['mcp']) {
                $config | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{}) -Force
            }
        } catch {
            $config = [pscustomobject]@{
                '$schema' = 'https://opencode.ai/config.json'
                mcp       = [pscustomobject]@{}
            }
        }
    }

    $mcpScript = Join-Path $FrameworkRoot 'src/mcp/dotbot-mcp.ps1'
    $server = [ordered]@{
        type        = 'local'
        command     = @('pwsh', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mcpScript)
        enabled     = $true
        environment = [ordered]@{
            DOTBOT_HOME         = $FrameworkRoot
            DOTBOT_PROJECT_ROOT = $WorktreePath
        }
    }
    $config.mcp | Add-Member -NotePropertyName dotbot -NotePropertyValue $server -Force

    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8NoBOM
}

function Copy-DotbotProviderContent {
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$BotRoot,
        [Parameter(Mandatory)][string]$FrameworkRoot
    )

    $userContentRoot = Get-DistinctDotbotUserContentRoot -FrameworkRoot $FrameworkRoot

    foreach ($providerDir in @('.claude', '.codex', '.opencode')) {
        $providerRoot = Join-Path $WorktreePath $providerDir
        foreach ($type in @('agents', 'skills')) {
            $dest = Join-Path $providerRoot $type
            Reset-DotbotGeneratedDirectory -Path $dest -WorktreePath $WorktreePath
            Copy-DotbotDirectoryContents -Source (Join-Path $FrameworkRoot 'content' $type) -Destination $dest
            if ($userContentRoot) {
                Copy-DotbotDirectoryContents -Source (Join-Path $userContentRoot $type) -Destination $dest
            }
            Copy-DotbotDirectoryContents -Source (Join-Path $BotRoot 'content' $type) -Destination $dest
        }
    }

    $antigravityRoot = Join-Path $WorktreePath '.agents'
    Reset-DotbotGeneratedDirectory -Path $antigravityRoot -WorktreePath $WorktreePath
    $antigravitySkills = Join-Path $antigravityRoot 'skills'
    Copy-DotbotDirectoryContents -Source (Join-Path $FrameworkRoot 'content/skills') -Destination $antigravitySkills
    if ($userContentRoot) {
        Copy-DotbotDirectoryContents -Source (Join-Path $userContentRoot 'skills') -Destination $antigravitySkills
    }
    Copy-DotbotDirectoryContents -Source (Join-Path $BotRoot 'content/skills') -Destination $antigravitySkills
}

function Initialize-DotbotWorktreeExecutionEnvironment {
    <#
    .SYNOPSIS
    Materialise provider and MCP config inside a task execution worktree.

    .DESCRIPTION
    `dotbot init` intentionally leaves the project checkout clean. This routine
    creates the AI CLI directories, MCP config, and framework content views only
    inside the disposable worktree used for task execution. The generated paths
    are ignored locally and excluded from patch replay so they never become
    project changes.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    if (-not (Test-Path -LiteralPath $WorktreePath -PathType Container)) { return }

    $frameworkRoot = Get-DotbotWorktreeFrameworkRoot
    Ensure-DotbotWorktreeExcludes -WorktreePath $WorktreePath
    Remove-DotbotGeneratedPath -Path (Join-Path $WorktreePath '.gemini') -WorktreePath $WorktreePath

    $worktreeBotRoot = Join-Path $WorktreePath '.bot'
    if (-not (Test-Path -LiteralPath $worktreeBotRoot)) {
        New-Item -Path $worktreeBotRoot -ItemType Directory -Force | Out-Null
    }

    $worktreeControlDir = Join-Path $worktreeBotRoot '.control'
    $mainControlDir = Join-Path $BotRoot '.control'
    if (-not (Test-Path -LiteralPath $mainControlDir)) {
        New-Item -Path $mainControlDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $worktreeControlDir)) {
        New-DirectoryLink -Path $worktreeControlDir -Target $mainControlDir
    }

    $worktreeTasksDir = Join-Path (Join-Path $worktreeBotRoot 'workspace') 'tasks'
    $mainTasksDir = Join-Path (Join-Path $BotRoot 'workspace') 'tasks'
    if (-not (Test-Path -LiteralPath $mainTasksDir)) {
        New-Item -Path $mainTasksDir -ItemType Directory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $worktreeTasksDir) {
        $tasksItem = Get-Item -LiteralPath $worktreeTasksDir -Force -ErrorAction SilentlyContinue
        $tasksIsLink = $tasksItem -and (($tasksItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $tasksItem.LinkType)
        if (-not $tasksIsLink) {
            Assert-PathWithinBounds -Path $worktreeTasksDir -ExpectedRoot $WorktreePath
            Remove-Item -LiteralPath $worktreeTasksDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $worktreeTasksDir)) {
        $tasksParent = Split-Path $worktreeTasksDir -Parent
        if (-not (Test-Path -LiteralPath $tasksParent)) {
            New-Item -Path $tasksParent -ItemType Directory -Force | Out-Null
        }
        New-DirectoryLink -Path $worktreeTasksDir -Target $mainTasksDir
    }

    foreach ($name in @('content', 'hooks', 'settings')) {
        $dest = Join-Path $worktreeBotRoot $name
        Reset-DotbotGeneratedDirectory -Path $dest -WorktreePath $WorktreePath
    }
    $userContentRoot = Get-DistinctDotbotUserContentRoot -FrameworkRoot $frameworkRoot

    Copy-DotbotDirectoryContents -Source (Join-Path $frameworkRoot 'content') -Destination (Join-Path $worktreeBotRoot 'content')
    if ($userContentRoot) {
        Copy-DotbotDirectoryContents -Source $userContentRoot -Destination (Join-Path $worktreeBotRoot 'content')
    }
    Copy-DotbotDirectoryContents -Source (Join-Path $BotRoot 'content') -Destination (Join-Path $worktreeBotRoot 'content')
    Copy-DotbotDirectoryContents -Source (Join-Path $frameworkRoot 'src/hooks') -Destination (Join-Path $worktreeBotRoot 'hooks')
    Copy-DotbotDirectoryContents -Source (Join-Path $BotRoot 'hooks') -Destination (Join-Path $worktreeBotRoot 'hooks')
    Copy-DotbotDirectoryContents -Source (Join-Path $frameworkRoot 'content/settings') -Destination (Join-Path $worktreeBotRoot 'settings')
    Copy-DotbotDirectoryContents -Source (Join-Path $BotRoot 'settings') -Destination (Join-Path $worktreeBotRoot 'settings')

    Copy-DotbotProviderContent -WorktreePath $WorktreePath -BotRoot $BotRoot -FrameworkRoot $frameworkRoot
    Set-DotbotMcpServerJson -Path (Join-Path $WorktreePath '.mcp.json') -FrameworkRoot $frameworkRoot -WorktreePath $WorktreePath
    Set-DotbotCodexMcpConfig -Path (Join-Path $WorktreePath '.codex/config.toml') -FrameworkRoot $frameworkRoot -WorktreePath $WorktreePath
    Set-DotbotAntigravityMcpConfig -Path (Join-Path $WorktreePath '.agents/mcp_config.json') -FrameworkRoot $frameworkRoot -WorktreePath $WorktreePath
    Set-DotbotOpenCodeMcpConfig -Path (Join-Path $WorktreePath '.opencode/opencode.json') -FrameworkRoot $frameworkRoot -WorktreePath $WorktreePath
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
        (Join-Path $botDir "content"),
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

function Repair-TaskWorktreeProductWorkspace {
    <#
    .SYNOPSIS
    Migrate stale task worktrees from shared product symlink to branch-local dir.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [string]$BotRoot,
        [switch]$SeedFromBotRoot
    )

    $productPath = Join-Path $WorktreePath ".bot\workspace\product"
    $needsSeed = [bool]$SeedFromBotRoot
    if (Test-Path -LiteralPath $productPath) {
        $item = Get-Item -LiteralPath $productPath -Force -ErrorAction SilentlyContinue
        $isLink = $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or $item.LinkType)
        if ($isLink) {
            Remove-Item -LiteralPath $productPath -Force -ErrorAction SilentlyContinue
            $needsSeed = $true
        }
    } else {
        $needsSeed = $true
    }

    if (-not (Test-Path -LiteralPath $productPath)) {
        git -C $WorktreePath checkout -- .bot/workspace/product 2>$null
    }
    if (-not (Test-Path -LiteralPath $productPath)) {
        New-Item -ItemType Directory -Path $productPath -Force | Out-Null
    }

    if ($needsSeed -and $BotRoot) {
        $mainProductPath = Join-Path $BotRoot "workspace\product"
        if (Test-Path -LiteralPath $mainProductPath) {
            Get-ChildItem -LiteralPath $mainProductPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $productPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
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
        (Join-Path $WorktreePath ".bot\content"),
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

function Repair-SharedWorkspaceRebaseConflict {
    <#
    .SYNOPSIS
    Resolve rebase conflicts caused by committed task-worktree links for shared workspace dirs.

    .DESCRIPTION
    Task worktrees replace .bot/workspace/tasks and .bot/workspace/product with
    links to live shared state. If an agent commits with `git add -A`, Git can
    record those links as file replacements. Rebasing that commit onto a branch
    with real directories produces file/directory conflicts. Keep the base
    branch's real directories and strip the shared-link changes out of the
    replayed commit; the shared task/product state is handled separately.
    #>
    param(
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $unmergedOutput = git -C $WorktreePath ls-files -u 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $unmergedOutput) {
        return @{ success = $false; output = @("No shared workspace rebase conflict found") }
    }

    $unmergedPaths = @()
    foreach ($line in @($unmergedOutput)) {
        $tabIndex = "$line".IndexOf("`t")
        if ($tabIndex -ge 0) {
            $unmergedPaths += "$line".Substring($tabIndex + 1)
        }
    }
    $unmergedPaths = @($unmergedPaths | Sort-Object -Unique)

    $sharedMovedPaths = @($unmergedPaths | Where-Object {
        $_.StartsWith('.bot/workspace/product~', [System.StringComparison]::Ordinal) -or
        $_.StartsWith('.bot/workspace/tasks~', [System.StringComparison]::Ordinal)
    })
    if ($sharedMovedPaths.Count -eq 0 -or $sharedMovedPaths.Count -ne $unmergedPaths.Count) {
        return @{ success = $false; output = @("Rebase conflict includes non-shared paths: $($unmergedPaths -join ', ')") }
    }

    $repairOutput = @()

    foreach ($path in $sharedMovedPaths) {
        Remove-Item -LiteralPath (Join-Path $WorktreePath $path) -Force -ErrorAction SilentlyContinue
        $out = git -C $WorktreePath rm --cached -f -- $path 2>&1
        $repairOutput += @($out | ForEach-Object { "$_" })
    }

    $out = git -C $WorktreePath restore --source=HEAD --staged --worktree -- .bot/workspace/product .bot/workspace/tasks 2>&1
    $repairOutput += @($out | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        return @{ success = $false; output = $repairOutput }
    }

    $env:GIT_EDITOR = "true"
    try {
        $out = git -C $WorktreePath `
            -c user.name=dotbot `
            -c user.email=dotbot@localhost `
            rebase --continue 2>&1
        $repairOutput += @($out | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            return @{ success = $false; output = $repairOutput }
        }
    } finally {
        Remove-Item Env:GIT_EDITOR -ErrorAction SilentlyContinue
    }

    # The conflicted commit may still carry deletes/type changes under the
    # shared paths. Remove those changes from the replayed commit itself.
    $out = git -C $WorktreePath checkout HEAD^ -- .bot/workspace/product .bot/workspace/tasks 2>&1
    $repairOutput += @($out | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) {
        $sharedStatus = git -C $WorktreePath status --porcelain -- .bot/workspace/product .bot/workspace/tasks 2>$null
        if ($sharedStatus) {
            $out = git -C $WorktreePath `
                -c user.name=dotbot `
                -c user.email=dotbot@localhost `
                commit --amend --no-edit 2>&1
            $repairOutput += @($out | ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0) {
                return @{ success = $false; output = $repairOutput }
            }
        }
    }

    return @{ success = $true; output = $repairOutput }
}

function Get-TaskBranchPatchPathspecs {
    <#
    .SYNOPSIS
    Return pathspecs for task branch changes that are safe to replay on main.

    .DESCRIPTION
    Task worktrees replace shared runtime state with symlinks/junctions. Those
    link entries must never be replayed into the integration branch; the live
    task state is committed separately after task completion. Product workspace
    files are project artifacts, so they are included in the task branch patch.
    #>
    param()

    return @(
        '.',
        ':(exclude).bot/.control',
        ':(exclude).bot/.control/**',
        ':(exclude).bot/.handoffs',
        ':(exclude).bot/.handoffs/**',
        ':(exclude).bot/workspace/tasks',
        ':(exclude).bot/workspace/tasks/**',
        ':(exclude).bot/content',
        ':(exclude).bot/content/**',
        ':(exclude).bot/hooks',
        ':(exclude).bot/hooks/**',
        ':(exclude).bot/settings',
        ':(exclude).bot/settings/**',
        ':(exclude).bot/runtime',
        ':(exclude).bot/runtime/**',
        ':(exclude).mcp.json',
        ':(exclude).claude',
        ':(exclude).claude/**',
        ':(exclude).codex',
        ':(exclude).codex/**',
        ':(exclude).opencode',
        ':(exclude).opencode/**',
        ':(exclude).agents',
        ':(exclude).agents/**',
        ':(exclude).gemini',
        ':(exclude).gemini/**'
    )
}

function Get-BackupTaskIdFromJson {
    <#
    .SYNOPSIS
    Extract a task id from a backed-up JSON blob for per-task lock keying
    during merge-failure restore.

    .DESCRIPTION
    The canonical task backup carries raw JSON strings for more than the
    one task being merged. Locking every restored file on the merging task's
    id would serialise unrelated tasks on the wrong key. Parse each blob and
    use its own id so concurrent readers of those tasks see the right lock.
    Falls back to '' (no lock) when the blob is malformed — in that case
    Write-TaskFileRawAtomic still writes atomically, just without
    cross-process serialisation.
    #>
    param([string]$RawJson)
    try { return [string](($RawJson | ConvertFrom-Json).id) } catch { return '' }
}

function Get-DotbotTaskStateBackup {
    <#
    .SYNOPSIS
    Capture canonical task-state JSON files under .bot/workspace/tasks.

    .DESCRIPTION
    Runtime task state lives in workflow-runs/ and standalone/. Worktree
    completion resets .bot/workspace/tasks before replaying branch changes, so
    these canonical files must be restored afterward or terminal task status
    can disappear from the UI after a successful merge.
    #>
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $tasksRoot = Join-Path $ProjectRoot ".bot\workspace\tasks"
    $backup = @{}
    if (-not (Test-Path -LiteralPath $tasksRoot)) { return $backup }

    $canonicalRoots = @(
        @{ Root = (Join-Path $tasksRoot 'workflow-runs'); Recurse = $true },
        @{ Root = (Join-Path $tasksRoot 'standalone');    Recurse = $false }
    )

    foreach ($canonicalRoot in $canonicalRoots) {
        if (-not (Test-Path -LiteralPath $canonicalRoot.Root)) { continue }
        $files = if ($canonicalRoot.Recurse) {
            Get-ChildItem -LiteralPath $canonicalRoot.Root -Filter "*.json" -File -Recurse -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $canonicalRoot.Root -Filter "*.json" -File -ErrorAction SilentlyContinue
        }
        foreach ($file in @($files)) {
            try {
                $relativePath = [System.IO.Path]::GetRelativePath($tasksRoot, $file.FullName)
                $key = ($relativePath -replace '\\', '/')
                $backup[$key] = Get-Content -LiteralPath $file.FullName -Raw
            } catch {
                Write-BotLog -Level Debug -Message "Failed to read task backup $($file.FullName)" -Exception $_
            }
        }
    }
    return $backup
}

function Restore-DotbotTaskStateBackup {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$TaskBackup
    )

    $tasksRoot = Join-Path $ProjectRoot ".bot\workspace\tasks"
    foreach ($key in $TaskBackup.Keys) {
        $restorePath = Join-Path $tasksRoot ($key -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $restoreDir = Split-Path $restorePath -Parent
        if (-not (Test-Path -LiteralPath $restoreDir)) {
            New-Item -LiteralPath $restoreDir -ItemType Directory -Force | Out-Null
        }
        Write-TaskFileRawAtomic -Path $restorePath -RawContent $TaskBackup[$key] -TaskId (Get-BackupTaskIdFromJson $TaskBackup[$key])
    }
}

function Remove-DotbotTaskStateNotInBackup {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$TaskBackup
    )

    $tasksRoot = Join-Path $ProjectRoot ".bot\workspace\tasks"
    if (-not (Test-Path -LiteralPath $tasksRoot)) { return }

    $canonicalRoots = @(
        @{ Root = (Join-Path $tasksRoot 'workflow-runs'); Recurse = $true },
        @{ Root = (Join-Path $tasksRoot 'standalone');    Recurse = $false }
    )

    foreach ($canonicalRoot in $canonicalRoots) {
        if (-not (Test-Path -LiteralPath $canonicalRoot.Root)) { continue }
        $files = if ($canonicalRoot.Recurse) {
            Get-ChildItem -LiteralPath $canonicalRoot.Root -Filter "*.json" -File -Recurse -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $canonicalRoot.Root -Filter "*.json" -File -ErrorAction SilentlyContinue
        }
        foreach ($file in @($files)) {
            try {
                $relativePath = [System.IO.Path]::GetRelativePath($tasksRoot, $file.FullName)
                $key = ($relativePath -replace '\\', '/')
                if (-not $TaskBackup.ContainsKey($key)) {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-BotLog -Level Debug -Message "Failed to prune stale task file $($file.FullName)" -Exception $_
            }
        }
    }
}

function Apply-TaskBranchPatch {
    <#
    .SYNOPSIS
    Stage the task branch diff on the project root, excluding shared links.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BaseBranch,
        [Parameter(Mandatory)][string]$BranchName
    )

    $mergeBase = (git -C $ProjectRoot merge-base $BaseBranch $BranchName 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $mergeBase) {
        git -C $ProjectRoot rev-parse --verify "$BranchName^{commit}" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return @{
                success = $false
                output  = @("Unable to determine merge-base for $BaseBranch and $BranchName")
            }
        }
        # Task branches created while the project repository had no commits are
        # orphan roots. After any task initializes the base branch, those older
        # task branches still have no merge-base; replay them as changes from
        # the empty tree so any task can be the first one completed.
        $mergeBase = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
    }

    $patchPath = [System.IO.Path]::GetTempFileName()
    $pathspecs = Get-TaskBranchPatchPathspecs
    try {
        $addedPathsOutput = git -C $ProjectRoot diff --name-status $mergeBase $BranchName -- @pathspecs 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{
                success = $false
                output  = @($addedPathsOutput | ForEach-Object { "$_" })
            }
        }

        $addedPaths = @(
            $addedPathsOutput |
                ForEach-Object { "$_" } |
                Where-Object { $_ -match '^A\s+' } |
                ForEach-Object { $_ -replace '^A\s+', '' }
        )
        foreach ($addedPath in $addedPaths) {
            $targetPath = Join-Path $ProjectRoot $addedPath
            if (-not (Test-Path -LiteralPath $targetPath)) { continue }

            git -C $ProjectRoot ls-files --error-unmatch -- $addedPath 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { continue }

            $branchBlob = (git -C $ProjectRoot rev-parse "$BranchName`:$addedPath" 2>$null)
            $localBlob = (git -C $ProjectRoot hash-object --no-filters -- $addedPath 2>$null)
            if (-not $branchBlob -or -not $localBlob -or $branchBlob.Trim() -ne $localBlob.Trim()) {
                return @{
                    success = $false
                    output  = @("Untracked file would be overwritten by task branch: $addedPath")
                }
            }

            Remove-Item -LiteralPath $targetPath -Force
        }

        $diffOutput = git -C $ProjectRoot diff --binary --output=$patchPath $mergeBase $BranchName -- @pathspecs 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{
                success = $false
                output  = @($diffOutput | ForEach-Object { "$_" })
            }
        }

        $patchInfo = Get-Item -LiteralPath $patchPath -ErrorAction SilentlyContinue
        if (-not $patchInfo -or $patchInfo.Length -eq 0) {
            return @{
                success = $true
                output  = @("Task branch has no non-shared changes to apply")
            }
        }

        $applyOutput = git -C $ProjectRoot apply --index --3way $patchPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            # Distinguish "real conflict" (3-way left U-state files) from
            # "apply outright failed" (no patch context found, etc.). The
            # former produces actionable conflict_files; the latter doesn't.
            $conflictFiles = @(
                git -C $ProjectRoot diff --name-only --diff-filter=U 2>$null |
                    ForEach-Object { "$_" } |
                    Where-Object { $_ }
            )
            return @{
                success        = $false
                output         = @($applyOutput | ForEach-Object { "$_" })
                conflict_files = $conflictFiles
                failure_kind   = if ($conflictFiles.Count -gt 0) { 'rebase_conflict' } else { $null }
            }
        }

        return @{
            success = $true
            output  = @($applyOutput | ForEach-Object { "$_" })
        }
    } finally {
        Remove-Item -LiteralPath $patchPath -Force -ErrorAction SilentlyContinue
    }
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
            Repair-TaskWorktreeProductWorkspace -WorktreePath $worktreePath -BotRoot $BotRoot
            Initialize-DotbotWorktreeExecutionEnvironment -WorktreePath $worktreePath -ProjectRoot $ProjectRoot -BotRoot $BotRoot
            # Valid worktree — ensure map entry exists and return it
            $existingBaseBranch = Resolve-MainBranch -ProjectRoot $ProjectRoot
            Invoke-WorktreeMapLocked -BotRoot $BotRoot -Action {
                $lockedMap = Read-WorktreeMap -BotRoot $BotRoot
                if (-not $lockedMap.ContainsKey($TaskId)) {
                    $lockedMap[$TaskId] = @{
                        worktree_path = $worktreePath
                        branch_name   = $branchName
                        base_branch   = $existingBaseBranch
                        task_name     = $TaskName
                        created_at    = (Get-Date).ToUniversalTime().ToString("o")
                    }
                    Write-WorktreeMap -Map $lockedMap -BotRoot $BotRoot
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
        # Always branch from the canonical integration branch once it exists.
        # A clean newly-initialized repo has no commits yet, so use git's
        # orphan worktree mode for the first task without creating a synthetic
        # base commit in the main checkout.
        $baseBranch = Resolve-MainBranch -ProjectRoot $ProjectRoot
        $baseIsUnborn = $false
        if (-not $baseBranch) {
            $baseBranch = Resolve-UnbornBaseBranch -ProjectRoot $ProjectRoot
            $baseIsUnborn = [bool]$baseBranch
        }
        if (-not $baseBranch) {
            throw "Cannot create worktree: no 'main' or 'master' branch found in $ProjectRoot. Use a standard integration branch name (main or master)."
        }

        if ($baseIsUnborn) {
            $output = git -C $ProjectRoot worktree add --orphan -b $branchName $worktreePath 2>&1
        } else {
            $output = git -C $ProjectRoot worktree add -b $branchName $worktreePath $baseBranch 2>&1
        }
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
        if ($baseIsUnborn) {
            $sourceBotIgnore = Join-Path $BotRoot ".gitignore"
            if (Test-Path -LiteralPath $sourceBotIgnore) {
                $targetBotDir = Join-Path $worktreePath ".bot"
                if (-not (Test-Path -LiteralPath $targetBotDir)) {
                    New-Item -Path $targetBotDir -ItemType Directory -Force | Out-Null
                }
                Copy-Item -LiteralPath $sourceBotIgnore -Destination (Join-Path $targetBotDir ".gitignore") -Force
            }
        }
        Repair-TaskWorktreeProductWorkspace -WorktreePath $worktreePath -BotRoot $BotRoot -SeedFromBotRoot

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

        # Copy non-noisy gitignored build artifacts
        Copy-BuildArtifacts -ProjectRoot $ProjectRoot -WorktreePath $worktreePath
        Initialize-DotbotWorktreeExecutionEnvironment -WorktreePath $worktreePath -ProjectRoot $ProjectRoot -BotRoot $BotRoot

        # Register in worktree map (locked read-modify-write to prevent concurrent entry loss)
        Invoke-WorktreeMapLocked -BotRoot $BotRoot -Action {
            $lockedMap = Read-WorktreeMap -BotRoot $BotRoot
            $lockedMap[$TaskId] = @{
                worktree_path = $worktreePath
                branch_name   = $branchName
                base_branch   = $baseBranch
                task_name     = $TaskName
                created_at    = (Get-Date).ToUniversalTime().ToString("o")
            }
            Write-WorktreeMap -Map $lockedMap -BotRoot $BotRoot
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
    Replay a task branch on main, then clean up the worktree and branch.

    .OUTPUTS
    Hashtable with:
      success        — $true on full merge+commit+cleanup, $false otherwise
      merge_commit   — SHA of the resulting commit (success only) or $null
      message        — human-readable summary
      conflict_files — array of conflicting paths (only populated for
                       failure_kind='rebase_conflict')
      failure_kind   — one of: $null (on success), 'rebase_conflict',
                       'branch_missing', 'merge_command_failed', 'commit_failed',
                       'exception'. Drives the kind-specific pending_question
                       built by Move-TaskToMergeFailureNeedsInput.
      failure_detail — git output / exception text captured for diagnosis.
                       Surfaced in the escalation's pending_question.context.
      push_result    — push-to-remote summary (success path only)
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    $map = Read-WorktreeMap -BotRoot $BotRoot

    if (-not $map.ContainsKey($TaskId)) {
        return @{
            success        = $true
            merge_commit   = $null
            message        = "No worktree found for task $TaskId (no merge needed)"
            conflict_files = @()
            failure_kind   = $null
            failure_detail = ""
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

        # Kill any processes still running in the worktree (dev servers, file watchers, etc.)
        $killedCount = Stop-WorktreeProcesses -WorktreePath $worktreePath
        if ($killedCount -gt 0) {
            Start-Sleep -Milliseconds 500  # Brief pause for handles to release
        }

        # Remove junctions before committing so git sees real tracked files.
        $junctionsClean = Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false

        # Restore tracked task files that were replaced by junctions. Product
        # files are branch-local artifacts now, so only restore them if cleanup
        # removed an old symlink/junction from a pre-migration worktree.
        git -C $worktreePath checkout -- .bot/workspace/tasks 2>$null
        if (-not (Test-Path -LiteralPath (Join-Path $worktreePath ".bot\workspace\product"))) {
            git -C $worktreePath checkout -- .bot/workspace/product 2>$null
        }

        # Auto-commit any uncommitted work left by the provider CLI.
        $worktreeStatus = git -C $worktreePath status --porcelain 2>$null
        if ($worktreeStatus) {
            git -C $worktreePath add -A -- `
                '.' `
                ':!.bot/.control' `
                ':!.bot/.control/**' `
                ':!.bot/.handoffs/' `
                ':!.bot/.handoffs/**' `
                ':!.bot/workspace/tasks/' `
                ':!.bot/content/' `
                ':!.bot/hooks/' `
                ':!.bot/settings/' `
                ':!.mcp.json' `
                ':!.claude/' `
                ':!.codex/' `
                ':!.opencode/' `
                ':!.agents/' `
                ':!.gemini/' 2>$null
            $worktreeStaged = git -C $worktreePath diff --cached --name-only 2>$null
            if ($worktreeStaged) {
                $autoCommitOutput = git -C $worktreePath `
                    -c user.name=dotbot `
                    -c user.email=dotbot@localhost `
                    commit --quiet -m "chore: auto-commit uncommitted work" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    git -C $worktreePath reset 2>$null
                    return @{
                        success        = $false
                        merge_commit   = $null
                        message        = "Auto-commit failed before merge"
                        conflict_files = @()
                        failure_kind   = "commit_failed"
                        failure_detail = (@($autoCommitOutput | ForEach-Object { "$_" }) -join "`n")
                    }
                }
            }
        }

        # Ensure clean index before replay — auto-commit may fail silently
        # (e.g. pre-commit hook blocks .env.local with secrets)
        $indexDirty = git -C $worktreePath diff --cached --name-only 2>$null
        if ($indexDirty) {
            git -C $worktreePath reset 2>$null
        }

        # Backup canonical live task state before merge. These files may have
        # changed through worktree junctions and are restored after task branch
        # replay so the UI sees terminal statuses.
        $taskBackup = Get-DotbotTaskStateBackup -ProjectRoot $ProjectRoot

        # Clean tracked + untracked task files so merge can proceed cleanly
        git -C $ProjectRoot checkout -- .bot/workspace/tasks/ 2>$null
        git -C $ProjectRoot clean -fd -- .bot/workspace/tasks/ 2>$null

        # Stash remaining dirty state EXCLUDING task files (task state is managed by backup-restore).
        # Including task files in the stash causes stale state to be reintroduced after the state commit
        # when git stash pop runs, contaminating the next task's backup.
        $stashOutput = git -C $ProjectRoot stash push -u -m "dotbot-pre-merge-$TaskId" -- `
            '.' `
            ':!.bot/workspace/tasks/' `
            ':!.bot/workspace/decisions/' 2>&1
        $wasStashed = $LASTEXITCODE -eq 0 -and "$stashOutput" -notmatch 'No local changes'

        # Assert main repo is on the base branch after task state is backed up
        # and non-task dirty state is stashed. This lets detached HEAD checkouts
        # return to main without losing live canonical task status.
        try {
            Assert-OnBaseBranch -ProjectRoot $ProjectRoot -BranchName $baseBranch | Out-Null
        } catch {
            if ($wasStashed) { git -C $ProjectRoot stash pop 2>$null }
            Restore-DotbotTaskStateBackup -ProjectRoot $ProjectRoot -TaskBackup $taskBackup
            throw
        }

        # Validate task branch still exists before attempting merge (Fix: branch_not_found)
        git -C $ProjectRoot rev-parse --verify $branchName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($wasStashed) { git -C $ProjectRoot stash pop 2>$null }
            Restore-DotbotTaskStateBackup -ProjectRoot $ProjectRoot -TaskBackup $taskBackup
            return @{
                success        = $false
                merge_commit   = $null
                message        = "Branch $branchName no longer exists — cannot merge task $TaskId"
                conflict_files = @()
                failure_kind   = "branch_missing"
                failure_detail = "Expected branch: $branchName (deleted or never created)"
            }
        }

        $baseCommit = git -C $ProjectRoot rev-parse --verify "$baseBranch^{commit}" 2>$null
        $baseIsUnborn = $LASTEXITCODE -ne 0 -or -not $baseCommit

        # Stage task branch changes on main, excluding shared worktree links.
        # If the base branch is still unborn, the first completed task becomes
        # the initial base commit without requiring a synthetic bootstrap
        # commit before work starts.
        if ($baseIsUnborn) {
            $resetOutput = git -C $ProjectRoot reset --hard $branchName 2>&1
            if ($LASTEXITCODE -ne 0) {
                $mergeResult = @{
                    success = $false
                    output  = @($resetOutput | ForEach-Object { "$_" })
                }
            } else {
                $mergeResult = @{
                    success = $true
                    output  = @("Initialized unborn base branch $baseBranch from $branchName")
                }
            }
        } else {
            $mergeResult = Apply-TaskBranchPatch -ProjectRoot $ProjectRoot -BaseBranch $baseBranch -BranchName $branchName
        }
        if (-not $mergeResult.success) {
            if (-not $baseIsUnborn) {
                git -C $ProjectRoot reset --hard HEAD 2>$null
            }
            # Re-assert base branch after reset — leaves repo in a known good state (Fix: wrong-branch merge)
            Assert-OnBaseBranch -ProjectRoot $ProjectRoot -BranchName $baseBranch | Out-Null
            if ($wasStashed) {
                git -C $ProjectRoot stash pop 2>$null
            }
            # Restore backed-up task state after failed merge
            Restore-DotbotTaskStateBackup -ProjectRoot $ProjectRoot -TaskBackup $taskBackup
            $mergeOutput = @($mergeResult.output | ForEach-Object { "$_" })
            # Apply-TaskBranchPatch surfaces conflict_files and a 'rebase_conflict'
            # failure_kind when git apply --3way left unmerged files. Honour that
            # classification when present — the operator gets a precise "Merge
            # conflict on <file>" pending_question instead of a generic
            # "Squash-merge command failed". Falls back to merge_command_failed
            # for non-conflict apply failures (no patch context, etc.).
            $applyConflicts = if ($mergeResult.PSObject.Properties['conflict_files']) {
                @($mergeResult.conflict_files | Where-Object { $_ })
            } else { @() }
            $applyKind = [string]$mergeResult.failure_kind
            $resolvedKind = if ($applyKind) { $applyKind } else { 'merge_command_failed' }
            $resolvedMessage = if ($resolvedKind -eq 'rebase_conflict') {
                "Merge conflict during squash-merge: $($applyConflicts -join ', ')"
            } else {
                "Task branch patch failed: $($mergeOutput -join ' ')"
            }
            return @{
                success        = $false
                merge_commit   = $null
                message        = $resolvedMessage
                conflict_files = $applyConflicts
                failure_kind   = $resolvedKind
                failure_detail = (@($mergeOutput | ForEach-Object { "$_" }) -join "`n")
            }
        }

        # Discard branch's task state, restore live state from backup
        git -C $ProjectRoot checkout HEAD -- .bot/workspace/tasks/ 2>$null
        Restore-DotbotTaskStateBackup -ProjectRoot $ProjectRoot -TaskBackup $taskBackup

        # Remove canonical task JSON files from the merge that were not present
        # in the live backup.
        Remove-DotbotTaskStateNotInBackup -ProjectRoot $ProjectRoot -TaskBackup $taskBackup

        # Commit if there are staged changes (task may have made no code changes).
        # Capture stderr+stdout so a pre-commit hook rejection (secrets scan,
        # lint, conventional-commit gate, etc.) is surfaced via failure_detail.
        $staged = git -C $ProjectRoot diff --cached --name-only 2>$null
        if ($staged) {
            $commitOutput = git -C $ProjectRoot `
                -c user.name=dotbot `
                -c user.email=dotbot@localhost `
                commit -m "feat: $taskName [task:$shortId]" 2>&1
            if ($LASTEXITCODE -ne 0) {
                git -C $ProjectRoot reset --hard HEAD 2>$null
                # Re-assert base branch after reset (Fix: wrong-branch merge)
                Assert-OnBaseBranch -ProjectRoot $ProjectRoot -BranchName $baseBranch | Out-Null
                if ($wasStashed) { git -C $ProjectRoot stash pop 2>$null }
                Restore-DotbotTaskStateBackup -ProjectRoot $ProjectRoot -TaskBackup $taskBackup
                return @{
                    success        = $false
                    merge_commit   = $null
                    message        = "Commit failed after squash merge"
                    conflict_files = @()
                    failure_kind   = "commit_failed"
                    failure_detail = (@($commitOutput | ForEach-Object { "$_" }) -join "`n")
                }
            }
        }

        $mergeCommit = git -C $ProjectRoot rev-parse HEAD 2>$null

        # Commit current shared runtime state on main. Product workspace files
        # are branch-local and are replayed through Apply-TaskBranchPatch above.
        git -C $ProjectRoot add .bot/workspace/tasks/ .bot/workspace/decisions/ 2>$null
        $stateStaged = git -C $ProjectRoot diff --cached --name-only 2>$null
        if ($stateStaged) {
            $stateCommitOutput = git -C $ProjectRoot `
                -c user.name=dotbot `
                -c user.email=dotbot@localhost `
                commit --quiet -m "chore: update task state" 2>&1
            if ($LASTEXITCODE -ne 0) {
                if ($wasStashed) { git -C $ProjectRoot stash pop 2>$null }
                return @{
                    success        = $false
                    merge_commit   = $null
                    message        = "Task state commit failed after merge"
                    conflict_files = @()
                    failure_kind   = "commit_failed"
                    failure_detail = (@($stateCommitOutput | ForEach-Object { "$_" }) -join "`n")
                }
            }
        }

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
        Invoke-WorktreeMapLocked -BotRoot $BotRoot -Action {
            $lockedMap = Read-WorktreeMap -BotRoot $BotRoot
            $lockedMap.Remove($TaskId)
            Write-WorktreeMap -Map $lockedMap -BotRoot $BotRoot
        }

        return @{
            success        = $true
            merge_commit   = $mergeCommit
            message        = "Squash-merged to $baseBranch and cleaned up"
            conflict_files = @()
            failure_kind   = $null
            failure_detail = ""
            push_result    = $pushResult
        }
    } catch {
        return @{
            success        = $false
            merge_commit   = $null
            message        = "Error during merge: $($_.Exception.Message)"
            conflict_files = @()
            failure_kind   = "exception"
            failure_detail = (@($_.Exception.Message, $_.ScriptStackTrace) | Where-Object { $_ }) -join "`n"
        }
    }
}

function Reset-TaskWorktree {
    <#
    .SYNOPSIS
    Discard a task's work: remove its worktree and delete its branch without
    merging. Used when a reviewer rejects a task so it can be restarted from
    scratch.

    .OUTPUTS
    Hashtable with: success, message
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$BotRoot
    )

    $map = Read-WorktreeMap -BotRoot $BotRoot
    if (-not $map.ContainsKey($TaskId)) {
        return @{ success = $true; message = "No worktree found for task $TaskId (nothing to discard)" }
    }

    $entry = $map[$TaskId]
    $worktreePath = $entry.worktree_path
    $branchName = $entry.branch_name

    try {
        # Kill any processes still using the worktree
        $killedCount = Stop-WorktreeProcesses -WorktreePath $worktreePath
        if ($killedCount -gt 0) {
            Start-Sleep -Milliseconds 500
        }

        # Remove junctions before worktree removal to prevent data-loss via --force
        Remove-Junctions -WorktreePath $worktreePath -ErrorOnFailure $false | Out-Null

        # Remove the worktree
        $worktreeOutput = git -C $ProjectRoot worktree remove $worktreePath --force 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errMsg = ($worktreeOutput -join ' ').Trim()
            return @{ success = $false; message = "Reset-TaskWorktree: worktree remove failed for task ${TaskId}: $errMsg" }
        }
        if (Test-Path $worktreePath) {
            Write-BotLog -Level Warn -Message "Reset-TaskWorktree: path still exists after removal: $worktreePath"
        }

        # Delete the task branch
        if ($branchName) {
            $branchOutput = git -C $ProjectRoot branch -D $branchName 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errMsg = ($branchOutput -join ' ').Trim()
                Write-BotLog -Level Warn -Message "Reset-TaskWorktree: branch delete failed for '$branchName': $errMsg"
            }
        }

        # Remove from registry
        Invoke-WorktreeMapLocked -BotRoot $BotRoot -Action {
            $lockedMap = Read-WorktreeMap -BotRoot $BotRoot
            $lockedMap.Remove($TaskId)
            Write-WorktreeMap -Map $lockedMap -BotRoot $BotRoot
        }

        return @{ success = $true; message = "Worktree and branch '$branchName' discarded for task $TaskId" }
    } catch {
        return @{ success = $false; message = "Error discarding worktree for task ${TaskId}: $($_.Exception.Message)" }
    }
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

    $map = Read-WorktreeMap -BotRoot $BotRoot
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
            $normalizedRelativePath = ([string]$relativePath) -replace '\\', '/'
            $isSharedWorktreePath = $false
            foreach ($prefix in $script:SharedWorktreeCopyPathPrefixes) {
                if ($normalizedRelativePath -eq $prefix -or
                    $normalizedRelativePath.StartsWith("$prefix/", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isSharedWorktreePath = $true
                    break
                }
            }
            if ($isSharedWorktreePath) { continue }

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

    $map = Read-WorktreeMap -BotRoot $BotRoot
    if ($map.Count -eq 0) { return }

    $tasksBaseDir = Join-Path $BotRoot "workspace\tasks"
    # 'done' is included: tasks that just completed execution may still have a live worktree
    # pending squash-merge by Complete-TaskWorktree. Removing them here would race with that.
    $activeDirs = @('todo', 'needs-input', 'in-progress', 'needs-review', 'done')
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
        Invoke-WorktreeMapLocked -BotRoot $BotRoot -Action {
            $lockedMap = Read-WorktreeMap -BotRoot $BotRoot
            foreach ($id in $orphanIds) { $lockedMap.Remove($id) }
            Write-WorktreeMap -Map $lockedMap -BotRoot $BotRoot
        }
    }
}

# --- Module Exports ---
Export-ModuleMember -Function @(
    # legacy surface — legacy per-task worktree manager
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
    'Reset-TaskWorktree'
    'Get-TaskWorktreeInfo'
    'Get-GitignoredCopyPaths'
    'Remove-OrphanWorktrees'

    # Per-WorkflowRun surface — defined in Private/Worktree.psm1,
    # re-exported here so the manifest sees them.
    'ConvertTo-WorktreeSlug'
    'Get-WorktreeBasePath'
    'Get-WorktreeBranchName'
    'Get-WorktreeDirName'
    'Resolve-WorkflowMainBranch'
    'Resolve-RunWorktreeLayout'
    'New-RunWorktree'
    'Complete-RunWorktree'
    'Get-PrunableBranches'
    'Invoke-PruneBranches'
)
