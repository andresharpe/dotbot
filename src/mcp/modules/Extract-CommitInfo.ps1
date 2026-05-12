<#
.SYNOPSIS
    Extracts commit information for a given task ID.

.DESCRIPTION
    Searches recent commits for task ID references in the format [task:XXXXXXXX]
    and optionally parses workspace tags [bot:XXXXXXXX] from matching commits.
    and returns commit details including file changes.

.PARAMETER TaskId
    The task ID to search for. Can be full UUID or short 8-character ID.

.PARAMETER MaxCommits
    Maximum number of commits to search. Defaults to 50.

.PARAMETER ProjectRoot
    The root directory of the git repository. Defaults to current directory.

.EXAMPLE
    Get-TaskCommitInfo -TaskId "7b012fb8-d6fa-45e8-b89e-062b4bcb16ae"

.EXAMPLE
    Get-TaskCommitInfo -TaskId "7b012fb8" -MaxCommits 100
#>

function Get-TaskCommitInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskId,

        [Parameter(Mandatory = $false)]
        [int]$MaxCommits = 50,

        [Parameter(Mandatory = $false)]
        [string]$ProjectRoot = $PWD
    )

    # Extract short task ID (first 8 characters)
    $shortTaskId = $TaskId.Substring(0, [Math]::Min(8, $TaskId.Length))

    # Pattern to search for in commit messages
    $taskPattern = "\[task:$shortTaskId\]"

    $results = @()

    try {
        Push-Location $ProjectRoot

        # Get list of commit SHAs first
        $commitShas = git log -n $MaxCommits --format="%H" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-BotLog -Level Warn -Message "Failed to get git log: $commitShas"
            return $results
        }

        # Handle array or single string
        if ($commitShas -is [string]) {
            $commitShas = @($commitShas)
        }

        foreach ($sha in $commitShas) {
            $sha = $sha.Trim()
            if (-not $sha) { continue }

            # Get full commit message for this SHA
            $commitMessage = git log -1 --format="%B" $sha 2>&1
            if ($commitMessage -is [array]) {
                $commitMessage = $commitMessage -join "`n"
            }

            # Check if this commit contains our task ID
            if ($commitMessage -match $taskPattern) {
                # Get commit metadata
                $commitSubject = git log -1 --format="%s" $sha 2>&1
                $commitTimestamp = git log -1 --format="%aI" $sha 2>&1

                if ($commitSubject -is [array]) { $commitSubject = $commitSubject[0] }
                if ($commitTimestamp -is [array]) { $commitTimestamp = $commitTimestamp[0] }

                # Extract workspace short ID from [bot:XXXXXXXX] or [bot:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx]
                $workspaceShortId = $null
                $botTagMatch = [regex]::Match($commitMessage, '\[bot:([0-9a-fA-F]{8})(?:-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?\]')
                if ($botTagMatch.Success) {
                    $workspaceShortId = $botTagMatch.Groups[1].Value.ToLowerInvariant()
                }
                # Get file changes for this commit
                $fileChanges = Get-CommitFileChanges -CommitSha $sha

                $commitInfo = @{
                    commit_sha = $sha
                    commit_subject = $commitSubject.Trim()
                    commit_message = $commitMessage.Trim()
                    commit_timestamp = $commitTimestamp.Trim()
                    workspace_short_id = $workspaceShortId
                    files_created = $fileChanges.Created
                    files_deleted = $fileChanges.Deleted
                    files_modified = $fileChanges.Modified
                }

                $results += $commitInfo
            }
        }
    }
    catch {
        Write-BotLog -Level Warn -Message "Error extracting commit info" -Exception $_
    }
    finally {
        Pop-Location
    }

    return ,$results
}

function Get-CommitFileChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommitSha
    )

    $created = @()
    $deleted = @()
    $modified = @()

    try {
        # Get file changes with status using diff-tree
        # --name-status shows: A (added), D (deleted), M (modified), R (renamed), C (copied)
        $diffOutput = git diff-tree --no-commit-id --name-status -r $CommitSha 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-BotLog -Level Warn -Message "Failed to get diff-tree for $CommitSha"
            return @{
                Created = $created
                Deleted = $deleted
                Modified = $modified
            }
        }

        # Handle array or single string
        if ($diffOutput -is [string]) {
            $lines = @($diffOutput)
        } else {
            $lines = $diffOutput
        }

        foreach ($line in $lines) {
            if (-not $line -or -not $line.Trim()) { continue }

            # Format: STATUS<tab>FILENAME (or STATUS<tab>OLDFILE<tab>NEWFILE for renames)
            $parts = $line -split "`t"
            if ($parts.Count -lt 2) { continue }

            $status = $parts[0].Trim()
            $filePath = $parts[1].Trim()

            switch -Regex ($status) {
                '^A' { $created += $filePath }
                '^D' { $deleted += $filePath }
                '^M' { $modified += $filePath }
                '^R' {
                    # Rename: old file deleted, new file created
                    $deleted += $filePath
                    if ($parts.Count -gt 2) {
                        $created += $parts[2].Trim()
                    }
                }
                '^C' {
                    # Copy: new file created
                    if ($parts.Count -gt 2) {
                        $created += $parts[2].Trim()
                    }
                }
            }
        }
    }
    catch {
        Write-BotLog -Level Warn -Message "Error getting file changes" -Exception $_
    }

    return @{
        Created = $created
        Deleted = $deleted
        Modified = $modified
    }
}

# Functions are exported automatically when dot-sourced
