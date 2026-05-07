# ═══════════════════════════════════════════════════════════════
# FRAMEWORK FILE — DO NOT MODIFY IN TARGET PROJECTS
# Managed by dotbot. Overwritten on 'dotbot init --force'.
# ═══════════════════════════════════════════════════════════════
param(
    [string]$TaskId,
    [string]$Category
)

# Check for uncommitted changes outside .bot/
$issues = @()
$warnings = @()
$details = @{}

try {
    $gitStatus = git status --porcelain 2>$null
    if ($gitStatus) {
        $nonBotChanges = $gitStatus | Where-Object { $_ -notmatch '\.bot/' }

        # Separate modified/staged tracked files from untracked files
        # Untracked (??) are pre-existing project files the task isn't responsible for
        $modifiedTracked = $nonBotChanges | Where-Object { $_ -notmatch '^\?\?' }
        $untracked       = $nonBotChanges | Where-Object { $_ -match '^\?\?' }

        if ($modifiedTracked) {
            $details['uncommitted_count'] = ($modifiedTracked | Measure-Object).Count
            $details['uncommitted_files'] = @($modifiedTracked)
            $issues += @{
                issue    = "Uncommitted changes detected ($($details['uncommitted_count']) file(s))"
                severity = "error"
                context  = "Commit all changes before marking task done"
            }
        }

        if ($untracked) {
            $details['untracked_count'] = ($untracked | Measure-Object).Count
            $details['untracked_files'] = @($untracked)
            $warnings += @{
                issue    = "Untracked files present ($($details['untracked_count']) file(s)) — not blocking"
                severity = "warning"
                context  = "These files are not part of the task's committed changes"
            }
        }
    }
    $details['clean'] = ($issues.Count -eq 0)
} catch {
    $issues += @{
        issue    = "Failed to check git status: $($_.Exception.Message)"
        severity = "error"
    }
}

@{
    success  = ($issues.Count -eq 0)
    script   = "01-git-clean.ps1"
    message  = if ($issues.Count -eq 0) { "Working directory clean" } else { "Uncommitted changes found" }
    details  = $details
    failures = $issues
    warnings = $warnings
} | ConvertTo-Json -Depth 10
