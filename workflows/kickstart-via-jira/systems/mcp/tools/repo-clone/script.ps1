function Invoke-RepoClone {
    param([hashtable]$Arguments)

    $project = $Arguments['project']
    $repo    = $Arguments['repo']

    if (-not $project) { throw "project is required" }
    if (-not $repo)    { throw "repo is required" }

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
    $initiativePath = Join-Path $global:DotbotProjectRoot ".bot\workspace\product\briefing\jira-context.md"
    $jiraKey = $null
    if (Test-Path $initiativePath) {
        $content = Get-Content $initiativePath -Raw
        if ($content -match '\|\s*Jira Key\s*\|\s*([A-Z]{2,10}-\d+)') {
            $jiraKey = $matches[1]
        }
    }

    # Read branch prefix from settings
    $branchPrefix = "initiative"
    $settingsPath = Join-Path $global:DotbotProjectRoot ".bot\settings\settings.default.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.azure_devops -and $settings.azure_devops.branch_prefix) {
            $branchPrefix = $settings.azure_devops.branch_prefix
        }
    }

    if (-not $jiraKey) {
        throw "Cannot determine Jira key from jira-context.md. Run Phase 0 (kickstart) first."
    }

    $workingBranch = "$branchPrefix/$jiraKey"

    # ---------------------------------------------------------------------------
    # Clone the repository
    # ---------------------------------------------------------------------------
    if (-not (Test-Path $reposDir)) {
        New-Item -Path $reposDir -ItemType Directory -Force | Out-Null
    }

    if (Test-Path $clonePath) {
        return @{
            success        = $true
            path           = $clonePath
            default_branch = (git -C $clonePath symbolic-ref refs/remotes/origin/HEAD 2>$null) -replace 'refs/remotes/origin/', ''
            working_branch = $workingBranch
            message        = "Repository already cloned at $clonePath"
            already_cloned = $true
        }
    }

    # Build clone URL with PAT authentication
    $orgHost = ($adoOrgUrl -replace 'https?://', '')
    $cloneUrl = "https://$($adoPat)@$orgHost/$project/_git/$repo"

    try {
        $cloneOutput = & git clone $cloneUrl $clonePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errorMsg = ($cloneOutput | Out-String).Trim()
            $errorMsg = $errorMsg -replace [regex]::Escape($adoPat), '***'

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
    $nugetConfig = Join-Path $clonePath "src\NuGet.config"
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
