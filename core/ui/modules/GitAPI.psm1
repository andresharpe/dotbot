<#
.SYNOPSIS
Git status and commit operations API module

.DESCRIPTION
Provides git status querying and commit-and-push functionality.
Extracted from server.ps1 for modularity.
#>

$script:Config = @{
    ProjectRoot = $null
    BotRoot = $null
}

function Initialize-GitAPI {
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [Parameter(Mandatory)] [string]$BotRoot
    )
    $script:Config.ProjectRoot = $ProjectRoot
    $script:Config.BotRoot = $BotRoot
}

function Get-GitStatus {
    $projectRoot = $script:Config.ProjectRoot

    try {
        # Get current branch
        $branch = (git -C $projectRoot rev-parse --abbrev-ref HEAD 2>$null)
        if (-not $branch) { $branch = "unknown" }

        # Get short commit hash
        $commitHash = (git -C $projectRoot rev-parse --short HEAD 2>$null)
        if (-not $commitHash) { $commitHash = "" }

        # Get porcelain status for machine-readable output
        $statusLines = @(git -C $projectRoot status --porcelain 2>$null)

        $staged = @()
        $unstaged = @()
        $untracked = @()

        foreach ($line in $statusLines) {
            if (-not $line -or $line.Length -lt 3) { continue }
            $indexStatus = $line[0]
            $workTreeStatus = $line[1]
            $filePath = $line.Substring(3).Trim()

            # Staged changes (index column has a letter)
            if ($indexStatus -match '[MADRC]') {
                $staged += @{ status = [string]$indexStatus; file = $filePath }
            }
            # Unstaged changes (work tree column has a letter)
            if ($workTreeStatus -match '[MADR]') {
                $unstaged += @{ status = [string]$workTreeStatus; file = $filePath }
            }
            # Untracked files
            if ($indexStatus -eq '?' -and $workTreeStatus -eq '?') {
                $untracked += $filePath
            }
        }

        # Get upstream status (ahead/behind)
        $ahead = 0
        $behind = 0
        $upstream = ""
        try {
            $upstreamRef = (git -C $projectRoot rev-parse --abbrev-ref '@{upstream}' 2>$null)
            if ($upstreamRef) {
                $upstream = $upstreamRef
                $counts = (git -C $projectRoot rev-list --left-right --count "HEAD...$upstreamRef" 2>$null)
                if ($counts -match '(\d+)\s+(\d+)') {
                    $ahead = [int]$matches[1]
                    $behind = [int]$matches[2]
                }
            }
        } catch { Write-BotLog -Level Debug -Message "Git operation failed" -Exception $_ }

        return @{
            branch = $branch
            commit = $commitHash
            upstream = $upstream
            ahead = $ahead
            behind = $behind
            staged = @($staged)
            unstaged = @($unstaged)
            untracked = @($untracked)
            staged_count = $staged.Count
            unstaged_count = $unstaged.Count
            untracked_count = $untracked.Count
            clean = ($staged.Count -eq 0 -and $unstaged.Count -eq 0 -and $untracked.Count -eq 0)
        }
    } catch {
        return @{
            error = "Failed to get git status"
            branch = "unknown"
            clean = $true
            staged = @()
            unstaged = @()
            untracked = @()
            staged_count = 0
            unstaged_count = 0
            untracked_count = 0
        }
    }
}

function Start-GitCommitAndPush {
    $botRoot = $script:Config.BotRoot

    $launcherPath = Join-Path $botRoot "systems\runtime\launch-process.ps1"
    $launchArgs = @("-File", "`"$launcherPath`"", "-Type", "commit", "-Model", "Sonnet", "-Description", "`"Commit and push changes`"")
    $startParams = @{ ArgumentList = $launchArgs; PassThru = $true }
    if ($IsWindows) { $startParams.WindowStyle = 'Normal' }
    $proc = Start-Process pwsh @startParams

    return @{
        success = $true
        pid = $proc.Id
        message = "Commit and push started via process manager."
    }
}

Export-ModuleMember -Function @('Initialize-GitAPI', 'Get-GitStatus', 'Start-GitCommitAndPush')
