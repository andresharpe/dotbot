# Extract a Jira/ADO work-item key from a jira-context.md document. The
# Fetch-Jira-Context step is supposed to emit a canonical `| Jira Key | KEY |`
# row, but agents have been observed free-forming the metadata table with other
# labels (`Primary Jira Keys`, `Parent Epic`, ...). Try the canonical row first,
# then known label variants, then the H1 title, then any key anywhere -- so a
# minor table-format drift no longer kills the entire code-execution phase.
# Matching is case-SENSITIVE (-cmatch): real keys are upper-case, and an
# insensitive match would treat tokens like `utf-8` / `sha-1` as keys.
function Get-RepoCloneJiraKey {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    $key = '[A-Z]{2,10}-\d+'

    # (a) canonical row
    if ($Content -cmatch "\|\s*Jira Key\s*\|\s*($key)") { return $matches[1] }
    # (b) known label variants (first key in the cell)
    if ($Content -cmatch "\|\s*(?:Primary Jira Keys?|Parent Epic|Programme[^|]*)\s*\|\s*($key)") { return $matches[1] }
    # (c) the H1 title (e.g. "# Jira Context: ENHANCE-9851 ...")
    foreach ($line in ($Content -split "`n")) {
        if ($line -match '^\s*#\s' -and $line -cmatch "($key)") { return $matches[1] }
    }
    # (d) last resort: first key-shaped token anywhere
    if ($Content -cmatch "($key)") { return $matches[1] }

    return $null
}

# A directory that merely exists is not a usable clone: a leftover empty gitlink
# (a 160000 tree entry with no working tree) or a dangling .git pointer leaves a
# dir that must be re-cloned. Treat a clone as complete when it is a real work
# tree with an origin remote -- which covers both populated clones and a valid
# clone of an empty (commitless) remote, without requiring a resolvable HEAD or
# tracked files (an empty-but-valid clone has neither yet, and must not be
# wrongly reclaimed).
function Test-RepoCloneComplete {
    param([Parameter(Mandatory)][string]$ClonePath)

    if (-not (Test-Path (Join-Path $ClonePath '.git'))) { return $false }
    $null = & git -C $ClonePath rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    $remote = & git -C $ClonePath config --get remote.origin.url 2>$null
    return [bool]$remote
}

function Invoke-RepoClone {
    param([hashtable]$Arguments)

    $project = $Arguments['project']
    $repo    = $Arguments['repo']

    if (-not $project) { throw "project is required" }
    if (-not $repo)    { throw "repo is required" }

    # $project/$repo are caller-supplied (MCP tool input). $repo becomes a
    # filesystem path ($clonePath) that is later force-deleted on a re-clone, so
    # reject anything that could escape the repos/ directory: path separators,
    # '..' traversal, or a bare '.'/'..'. (Spaces and other chars are allowed --
    # ADO names permit them -- only traversal is blocked.)
    foreach ($seg in @(@{ name = 'repo'; value = $repo }, @{ name = 'project'; value = $project })) {
        if ($seg.value -match '[\\/]' -or $seg.value -match '\.\.' -or $seg.value -in @('.', '..')) {
            throw "Invalid $($seg.name) name (path traversal not allowed): '$($seg.value)'"
        }
    }

    # ---------------------------------------------------------------------------
    # Load .env.local for credentials
    # ---------------------------------------------------------------------------
    $envLocal = Join-Path $global:DotbotProjectRoot ".env.local"
    if (Test-Path $envLocal) {
        Get-Content $envLocal | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
            }
        }
    }

    $adoOrgUrl = $env:AZURE_DEVOPS_ORG_URL
    $adoPat    = $env:AZURE_DEVOPS_PAT
    if (-not $adoOrgUrl) { throw "AZURE_DEVOPS_ORG_URL not set in .env.local" }
    if (-not $adoPat)    { throw "AZURE_DEVOPS_PAT not set in .env.local" }

    # ---------------------------------------------------------------------------
    # Determine paths and branch name
    # ---------------------------------------------------------------------------
    $reposDir  = Join-Path $global:DotbotProjectRoot "repos"
    $clonePath = Join-Path $reposDir $repo

    # Read jira-context.md to get Jira key for branch name
    $initiativePath = Join-Path $global:DotbotProjectRoot ".bot/workspace/product/briefing/jira-context.md"
    $jiraKey = $null
    if (Test-Path $initiativePath) {
        $jiraKey = Get-RepoCloneJiraKey -Content (Get-Content $initiativePath -Raw)
    }

    # Read branch prefix from the merged settings chain (defaults + ~/dotbot + .control)
    $branchPrefix = "initiative"
    $botRoot = Join-Path $global:DotbotProjectRoot ".bot"
    if (-not (Get-Module Dotbot.Settings)) {
        Import-Module (Join-Path $botRoot "systems/runtime/Modules/Dotbot.Settings/Dotbot.Settings.psm1") -DisableNameChecking -Global
    }

    $settings = Get-MergedSettings -BotRoot $botRoot
    if ($settings.azure_devops -and $settings.azure_devops.branch_prefix) {
        $branchPrefix = $settings.azure_devops.branch_prefix
    }

    if (-not $jiraKey) {
        throw "Cannot determine Jira key from jira-context.md. Run Phase 0 first."
    }

    $workingBranch = "$branchPrefix/$jiraKey"

    # ---------------------------------------------------------------------------
    # Clone the repository
    # ---------------------------------------------------------------------------
    if (-not (Test-Path $reposDir)) {
        New-Item -Path $reposDir -ItemType Directory -Force | Out-Null
    }

    if (Test-Path $clonePath) {
        if (Test-RepoCloneComplete -ClonePath $clonePath) {
            return @{
                success        = $true
                path           = $clonePath
                default_branch = (git -C $clonePath symbolic-ref refs/remotes/origin/HEAD 2>$null) -replace 'refs/remotes/origin/', ''
                working_branch = $workingBranch
                message        = "Repository already cloned at $clonePath"
                already_cloned = $true
            }
        }
        # Path exists but is not a usable clone. Only reclaim it when it is
        # genuinely empty (the observed failure: a leftover empty gitlink dir with
        # no working tree). A non-empty directory might be a real repo that merely
        # failed a transient git check, so refuse to force-delete it.
        $hasContent = @(Get-ChildItem -LiteralPath $clonePath -Force -ErrorAction SilentlyContinue).Count -gt 0
        if ($hasContent) {
            return @{
                success    = $false
                error_type = "incomplete_clone"
                message    = "Path '$clonePath' exists but is not a complete clone (no resolvable HEAD / tracked files). Remove or repair it, then retry."
                path       = $clonePath
            }
        }
        Remove-Item -LiteralPath $clonePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Authenticate with a host-scoped http.extraHeader injected through the
    # GIT_CONFIG_* environment (git >= 2.31). The PAT is never embedded in the
    # clone URL, so it does not appear in process arguments and is not persisted
    # to the cloned repo's .git/config (remote.origin.url stays credential-free).
    $orgHost  = ($adoOrgUrl -replace 'https?://', '').TrimEnd('/')
    $cloneUrl = "https://$orgHost/$project/_git/$repo"
    $basicToken = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":$adoPat"))

    # Preserve any GIT_CONFIG_* the caller already set so the finally block can
    # restore them rather than blindly deleting the caller's environment.
    $gitCfgVars  = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
    $priorGitCfg = @{}
    foreach ($v in $gitCfgVars) { $priorGitCfg[$v] = [Environment]::GetEnvironmentVariable($v, 'Process') }

    $env:GIT_CONFIG_COUNT   = '1'
    $env:GIT_CONFIG_KEY_0   = "http.https://$orgHost/.extraHeader"
    $env:GIT_CONFIG_VALUE_0 = "Authorization: Basic $basicToken"

    try {
        $cloneOutput = & git clone $cloneUrl $clonePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorMsg = ($cloneOutput | Out-String).Trim()
            $errorMsg = $errorMsg -replace [regex]::Escape($adoPat), '***'
            $errorMsg = $errorMsg -replace [regex]::Escape($basicToken), '***'

            $errorType = if ($errorMsg -match 'Authentication failed|401|403') { "authentication_failed" }
                         elseif ($errorMsg -match 'not found|does not exist|404') { "repo_not_found" }
                         elseif ($errorMsg -match 'timeout|Could not resolve host') { "network_error" }
                         else { "clone_failed" }

            return @{
                success    = $false
                error_type = $errorType
                message    = "Clone failed for $repo from $project`: $errorMsg"
                path       = $null
            }
        }
    } catch {
        return @{
            success    = $false
            error_type = "exception"
            message    = "Failed to clone $repo from $project`: $_"
            path       = $null
        }
    } finally {
        foreach ($v in $gitCfgVars) { [Environment]::SetEnvironmentVariable($v, $priorGitCfg[$v], 'Process') }
    }

    # Detect default branch
    $defaultBranch = & git -C $clonePath symbolic-ref refs/remotes/origin/HEAD 2>$null
    $defaultBranch = $defaultBranch -replace 'refs/remotes/origin/', ''
    if (-not $defaultBranch) { $defaultBranch = "main" }

    # Create initiative branch
    & git -C $clonePath checkout -b $workingBranch 2>&1 | Out-Null

    # ---------------------------------------------------------------------------
    # Configure NuGet authentication (for .NET repos)
    # ---------------------------------------------------------------------------
    $nugetConfig = Join-Path $clonePath "src/NuGet.config"
    if (-not (Test-Path $nugetConfig)) {
        $nugetConfig = Join-Path $clonePath "NuGet.config"
    }

    if (Test-Path $nugetConfig) {
        $nugetVarName = $env:NUGET_FEED_VAR
        if ($nugetVarName) {
            # Try Machine-level var first (corporate workstation setup)
            $nugetPat = [System.Environment]::GetEnvironmentVariable($nugetVarName, "Machine")

            # Fall back to .env.local value
            if (-not $nugetPat) {
                $nugetPat = $env:NUGET_FEED_PAT
            }

            # Fall back to ADO PAT
            if (-not $nugetPat) {
                $nugetPat = $adoPat
            }

            if ($nugetPat) {
                [System.Environment]::SetEnvironmentVariable($nugetVarName, $nugetPat, "Process")
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Return result
    # ---------------------------------------------------------------------------
    return @{
        success        = $true
        path           = $clonePath
        default_branch = $defaultBranch
        working_branch = $workingBranch
        message        = "Cloned $repo from $project, branch: $workingBranch"
        already_cloned = $false
    }
}
