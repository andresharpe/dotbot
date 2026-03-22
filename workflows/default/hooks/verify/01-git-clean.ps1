param(
    [string]$TaskId,
    [string]$Category
)

# Check for uncommitted changes outside .bot/
$issues = @()
$details = @{}

try {
    $gitStatus = git status --porcelain 2>$null
    if ($gitStatus) {
        $nonBotChanges = $gitStatus | Where-Object { $_ -notmatch '\.bot/' }
        if ($nonBotChanges) {
            $details['uncommitted_count'] = ($nonBotChanges | Measure-Object).Count
            $details['uncommitted_files'] = @($nonBotChanges)
            $issues += @{
                issue = "Uncommitted changes detected ($($details['uncommitted_count']) file(s))"
                severity = "error"
                context = "Commit all changes before marking task done"
            }
        }
    }
    $details['clean'] = ($issues.Count -eq 0)
} catch {
    $issues += @{
        issue = "Failed to check git status: $($_.Exception.Message)"
        severity = "error"
    }
}

@{
    success = ($issues.Count -eq 0)
    script = "01-git-clean.ps1"
    message = if ($issues.Count -eq 0) { "Working directory clean" } else { "Uncommitted changes found" }
    details = $details
    failures = $issues
} | ConvertTo-Json -Depth 10
