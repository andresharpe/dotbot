function Invoke-RepoList {
    param([hashtable]$Arguments)

    $reposDir = Join-Path $global:DotbotProjectRoot "repos"

    if (-not (Test-Path $reposDir)) {
        return @{
            success = $true
            repos   = @()
            count   = 0
            message = "No repos/ directory found. Run repo_clone to clone repositories."
        }
    }

    $repos = @()
    $repoDirs = Get-ChildItem -Path $reposDir -Directory -ErrorAction SilentlyContinue

    foreach ($dir in $repoDirs) {
        $repoPath = $dir.FullName
        $repoName = $dir.Name

        # Check if it's a git repo
        $isGitRepo = Test-Path (Join-Path $repoPath ".git")

        $status = "unknown"
        $branch = $null
        $hasDeepDive = $false
        $hasPlan = $false
        $hasOutcomes = $false
        $hasHandoff = $false

        if ($isGitRepo) {
            # Get current branch
            $branch = & git -C $repoPath branch --show-current 2>$null
            $status = "cloned"

            # Check for analysis artifacts in initiative repo's briefing
            $deepDivePath = Join-Path $global:DotbotProjectRoot ".bot\workspace\product\briefing\repos\$repoName.md"
            $hasDeepDive = Test-Path $deepDivePath

            # Check for per-repo plan/outcomes/handoff
            $planPath = Join-Path $repoPath ".bot\workspace\product\${repoName}_Plan.md"
            $hasPlan = Test-Path $planPath

            $outcomesPath = Join-Path $repoPath ".bot\workspace\product\${repoName}_Outcomes.md"
            $hasOutcomes = Test-Path $outcomesPath

            $handoffPath = Join-Path $repoPath ".bot\workspace\product\${repoName}-handoff.md"
            $hasHandoff = Test-Path $handoffPath

            # Determine status based on artifacts
            if ($hasHandoff) {
                $status = "handoff-ready"
            } elseif ($hasOutcomes) {
                $status = "implemented"
            } elseif ($hasPlan) {
                $status = "planned"
            } elseif ($hasDeepDive) {
                $status = "analyzed"
            }
        }

        $repos += @{
            name          = $repoName
            path          = $repoPath
            status        = $status
            branch        = $branch
            has_deep_dive = $hasDeepDive
            has_plan      = $hasPlan
            has_outcomes  = $hasOutcomes
            has_handoff   = $hasHandoff
        }
    }

    return @{
        success = $true
        repos   = $repos
        count   = $repos.Count
        message = "Found $($repos.Count) repositories in repos/"
    }
}
