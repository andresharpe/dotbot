function Import-PrContextEnvironment {
    $envLocal = Join-Path $global:DotbotProjectRoot ".env.local"
    if (-not (Test-Path $envLocal)) {
        return
    }

    Get-Content $envLocal | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
        }
    }
}

function Get-GitOutput {
    param([string[]]$Arguments)

    try {
        $result = & git @Arguments 2>$null
    } catch {
        return $null
    }

    $first = @($result | Select-Object -First 1)
    if ($first.Count -eq 0) {
        return $null
    }

    return [string]$first[0]
}

function Get-CurrentGitRemote {
    $remote = Get-GitOutput -Arguments @("remote", "get-url", "origin")
    if (-not $remote) {
        throw "Could not determine git remote origin for PR auto-detection."
    }

    return $remote.Trim()
}

function Get-CurrentGitBranch {
    $branch = Get-GitOutput -Arguments @("branch", "--show-current")
    if (-not $branch) {
        throw "Could not determine the current git branch for PR auto-detection."
    }

    return $branch.Trim()
}

function Convert-RemoteToGitHubInfo {
    param([string]$RemoteUrl)

    if ($RemoteUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        return @{
            owner = $matches["owner"]
            repo = $matches["repo"]
        }
    }

    return $null
}

function Convert-RemoteToAdoInfo {
    param([string]$RemoteUrl)

    $patterns = @(
        'https://(?:[^@/]+@)?dev\.azure\.com/(?<org>[^/]+)/(?<project>[^/]+)/_git/(?<repo>[^/]+?)(?:\.git)?$',
        'git@ssh\.dev\.azure\.com:v3/(?<org>[^/]+)/(?<project>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$',
        'https://(?<org>[^/.]+)\.visualstudio\.com/(?<project>[^/]+)/_git/(?<repo>[^/]+?)(?:\.git)?$'
    )

    foreach ($pattern in $patterns) {
        if ($RemoteUrl -match $pattern) {
            return @{
                org = $matches["org"]
                project = $matches["project"]
                repo = $matches["repo"]
            }
        }
    }

    return $null
}

function Convert-PrUrlToGitHubInfo {
    param([string]$PullRequestUrl)

    if ($PullRequestUrl -match '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/pull/(?<number>\d+)(?:[/?#].*)?$') {
        return @{
            owner = $matches["owner"]
            repo = $matches["repo"]
            number = [int]$matches["number"]
        }
    }

    return $null
}

function Convert-PrUrlToAdoInfo {
    param([string]$PullRequestUrl)

    $patterns = @(
        '^https://dev\.azure\.com/(?<org>[^/]+)/(?<project>[^/]+)/_git/(?<repo>[^/]+)/pullrequest/(?<id>\d+)(?:[/?#].*)?$',
        '^https://(?<org>[^/.]+)\.visualstudio\.com/(?<project>[^/]+)/_git/(?<repo>[^/]+)/pullrequest/(?<id>\d+)(?:[/?#].*)?$'
    )

    foreach ($pattern in $patterns) {
        if ($PullRequestUrl -match $pattern) {
            return @{
                org = $matches["org"]
                project = $matches["project"]
                repo = $matches["repo"]
                id = [int]$matches["id"]
            }
        }
    }

    return $null
}

function Get-GitHubHeaders {
    $headers = @{
        "User-Agent" = "dotbot-pr-context"
        "Accept" = "application/vnd.github+json"
    }

    $token = if ($env:GITHUB_TOKEN) {
        $env:GITHUB_TOKEN
    } elseif ($env:GH_TOKEN) {
        $env:GH_TOKEN
    } else {
        $null
    }

    if ($token) {
        $headers["Authorization"] = "Bearer $token"
    }

    return $headers
}

function Get-AdoHeaders {
    if (-not $env:AZURE_DEVOPS_PAT) {
        throw "AZURE_DEVOPS_PAT not set in .env.local or environment."
    }

    $basicToken = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_PAT)"))
    return @{
        "Authorization" = "Basic $basicToken"
        "Accept" = "application/json"
    }
}

function Invoke-GitHubRequest {
    param([string]$Uri)

    return Invoke-RestMethod -Method Get -Uri $Uri -Headers (Get-GitHubHeaders)
}

function Invoke-AdoRequest {
    param([string]$Uri)

    return Invoke-RestMethod -Method Get -Uri $Uri -Headers (Get-AdoHeaders)
}

function Convert-RefToBranchName {
    param([string]$RefName)

    if ($RefName -match '^refs/heads/(.+)$') {
        return $matches[1]
    }

    return $RefName
}

function Get-GitHubLinkedIssues {
    param(
        [string]$Owner,
        [string]$Repo,
        [string[]]$Texts
    )

    $issues = [System.Collections.ArrayList]::new()
    $seen = @{}

    foreach ($text in $Texts) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        foreach ($match in [regex]::Matches($text, '(?<issueOwner>[A-Za-z0-9_.-]+)/(?<issueRepo>[A-Za-z0-9_.-]+)#(?<number>\d+)')) {
            $issueOwner = $match.Groups["issueOwner"].Value
            $issueRepo = $match.Groups["issueRepo"].Value
            $number = $match.Groups["number"].Value
            $key = "$issueOwner/$issueRepo#$number"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$issues.Add(@{ owner = $issueOwner; repo = $issueRepo; number = $number; key = $key })
        }

        foreach ($match in [regex]::Matches($text, '(?<![A-Za-z0-9_.-/])#(?<number>\d+)')) {
            $number = $match.Groups["number"].Value
            $key = "$Owner/$Repo#$number"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$issues.Add(@{ owner = $Owner; repo = $Repo; number = $number; key = "#$number" })
        }
    }

    $resolvedIssues = @()
    foreach ($issue in $issues) {
        $issueUri = "https://api.github.com/repos/$($issue.owner)/$($issue.repo)/issues/$($issue.number)"
        try {
            $issueData = Invoke-GitHubRequest -Uri $issueUri
            $resolvedIssues += @{
                id = [int]$issueData.number
                key = $issue.key
                repository = "$($issue.owner)/$($issue.repo)"
                title = $issueData.title
                state = $issueData.state
                type = if ($issueData.pull_request) { "pull-request" } else { "issue" }
                url = $issueData.html_url
            }
        } catch {
            $resolvedIssues += @{
                id = [int]$issue.number
                key = $issue.key
                repository = "$($issue.owner)/$($issue.repo)"
                title = $null
                state = $null
                type = "issue"
                url = "https://github.com/$($issue.owner)/$($issue.repo)/issues/$($issue.number)"
            }
        }
    }

    return $resolvedIssues
}

function Get-GitHubChangedFiles {
    param(
        [string]$Owner,
        [string]$Repo,
        [int]$PullRequestNumber
    )

    $allFiles = [System.Collections.ArrayList]::new()
    $page = 1

    while ($true) {
        $fileUri = "https://api.github.com/repos/$Owner/$Repo/pulls/$PullRequestNumber/files?per_page=100&page=$page"
        $pageFiles = @(Invoke-GitHubRequest -Uri $fileUri)
        if ($pageFiles.Count -eq 0) {
            break
        }

        foreach ($file in $pageFiles) {
            [void]$allFiles.Add($file)
        }

        if ($pageFiles.Count -lt 100) {
            break
        }

        $page++
    }

    return @($allFiles)
}

function Convert-GitHubPrToResult {
    param(
        [string]$Owner,
        [string]$Repo,
        $PullRequest
    )

    $files = Get-GitHubChangedFiles -Owner $Owner -Repo $Repo -PullRequestNumber $PullRequest.number
    $changedFiles = @($files | ForEach-Object {
        @{
            path = $_.filename
            change_type = $_.status
        }
    })

    $linkedIssues = Get-GitHubLinkedIssues -Owner $Owner -Repo $Repo -Texts @($PullRequest.title, $PullRequest.body)

    return @{
        success = $true
        provider = "github"
        repository = "$Owner/$Repo"
        pr_url = $PullRequest.html_url
        pull_request_id = [int]$PullRequest.number
        title = $PullRequest.title
        description = if ($PullRequest.body) { $PullRequest.body } else { "" }
        state = $PullRequest.state
        author = if ($PullRequest.user) { $PullRequest.user.login } else { $null }
        source_branch = $PullRequest.head.ref
        target_branch = $PullRequest.base.ref
        linked_issues = @($linkedIssues)
        changed_files = $changedFiles
        message = "Loaded GitHub PR #$($PullRequest.number)"
    }
}

function Get-GitHubPrContextByUrl {
    param([string]$PullRequestUrl)

    $info = Convert-PrUrlToGitHubInfo -PullRequestUrl $PullRequestUrl
    if (-not $info) {
        throw "Invalid GitHub PR URL."
    }

    $prUri = "https://api.github.com/repos/$($info.owner)/$($info.repo)/pulls/$($info.number)"
    $pullRequest = Invoke-GitHubRequest -Uri $prUri
    return Convert-GitHubPrToResult -Owner $info.owner -Repo $info.repo -PullRequest $pullRequest
}

function Get-GitHubPrContextByCurrentBranch {
    $remote = Get-CurrentGitRemote
    $repoInfo = Convert-RemoteToGitHubInfo -RemoteUrl $remote
    if (-not $repoInfo) {
        throw "Current git remote is not a GitHub repository."
    }

    $branch = Get-CurrentGitBranch
    $listUri = "https://api.github.com/repos/$($repoInfo.owner)/$($repoInfo.repo)/pulls?head=$($repoInfo.owner):$branch&state=open"
    $pullRequests = @(Invoke-GitHubRequest -Uri $listUri)
    if ($pullRequests.Count -eq 0) {
        $listUri = "https://api.github.com/repos/$($repoInfo.owner)/$($repoInfo.repo)/pulls?head=$($repoInfo.owner):$branch&state=all"
        $pullRequests = @(Invoke-GitHubRequest -Uri $listUri)
    }

    if ($pullRequests.Count -eq 0) {
        throw "No GitHub pull request found for branch '$branch'."
    }

    return Convert-GitHubPrToResult -Owner $repoInfo.owner -Repo $repoInfo.repo -PullRequest $pullRequests[0]
}

function Get-AdoChangedFiles {
    param(
        [string]$Org,
        [string]$Project,
        [string]$Repo,
        [int]$PullRequestId
    )

    $iterationsUri = "https://dev.azure.com/$Org/$Project/_apis/git/repositories/$Repo/pullRequests/$PullRequestId/iterations?api-version=7.1"
    $iterations = Invoke-AdoRequest -Uri $iterationsUri
    $latestIteration = @($iterations.value | Sort-Object -Property id -Descending | Select-Object -First 1)
    if ($latestIteration.Count -eq 0) {
        return @()
    }

    $allChanges = [System.Collections.ArrayList]::new()
    $top = 2000
    $skip = 0

    while ($true) {
        $changesUri = "https://dev.azure.com/$Org/$Project/_apis/git/repositories/$Repo/pullRequests/$PullRequestId/iterations/$($latestIteration[0].id)/changes?`$compareTo=0&`$top=$top&`$skip=$skip&api-version=7.1"
        $changes = Invoke-AdoRequest -Uri $changesUri
        $entries = @($changes.changeEntries)

        foreach ($entry in $entries) {
            [void]$allChanges.Add(@{
                path = $entry.item.path
                change_type = $entry.changeType
            })
        }

        $nextSkip = 0
        if ($null -ne $changes.PSObject.Properties['nextSkip']) {
            $nextSkip = [int]$changes.nextSkip
        }

        if ($entries.Count -eq 0) {
            break
        }

        if ($nextSkip -gt $skip) {
            $skip = $nextSkip
            continue
        }

        if ($entries.Count -lt $top) {
            break
        }

        $skip += $top
    }

    return @($allChanges)
}

function Get-AdoLinkedIssues {
    param(
        [string]$Org,
        [string]$Project,
        [string]$Repo,
        [int]$PullRequestId
    )

    $workItemsUri = "https://dev.azure.com/$Org/$Project/_apis/git/repositories/$Repo/pullRequests/$PullRequestId/workitems?api-version=7.1"
    $workItems = Invoke-AdoRequest -Uri $workItemsUri
    $linkedIssues = @()

    foreach ($item in @($workItems.value)) {
        $detailUri = if ($item.url -match '\?') { "$($item.url)&api-version=7.1" } else { "$($item.url)?api-version=7.1" }
        try {
            $detail = Invoke-AdoRequest -Uri $detailUri
            $linkedIssues += @{
                id = [int]$detail.id
                key = "$($detail.id)"
                repository = "$Project/$Repo"
                title = $detail.fields.'System.Title'
                state = $detail.fields.'System.State'
                type = $detail.fields.'System.WorkItemType'
                url = if ($detail._links -and $detail._links.html) { $detail._links.html.href } else { $item.url }
            }
        } catch {
            $linkedIssues += @{
                id = [int]$item.id
                key = "$($item.id)"
                repository = "$Project/$Repo"
                title = $null
                state = $null
                type = "work-item"
                url = $item.url
            }
        }
    }

    return $linkedIssues
}

function Convert-AdoPrToResult {
    param(
        [string]$Org,
        [string]$Project,
        [string]$Repo,
        $PullRequest,
        [string]$ResolvedPrUrl
    )

    return @{
        success = $true
        provider = "azure-devops"
        repository = "$Project/$Repo"
        pr_url = $ResolvedPrUrl
        pull_request_id = [int]$PullRequest.pullRequestId
        title = $PullRequest.title
        description = if ($PullRequest.description) { $PullRequest.description } else { "" }
        state = $PullRequest.status
        author = if ($PullRequest.createdBy) { $PullRequest.createdBy.displayName } else { $null }
        source_branch = Convert-RefToBranchName -RefName $PullRequest.sourceRefName
        target_branch = Convert-RefToBranchName -RefName $PullRequest.targetRefName
        linked_issues = @(Get-AdoLinkedIssues -Org $Org -Project $Project -Repo $Repo -PullRequestId $PullRequest.pullRequestId)
        changed_files = Get-AdoChangedFiles -Org $Org -Project $Project -Repo $Repo -PullRequestId $PullRequest.pullRequestId
        message = "Loaded Azure DevOps PR $($PullRequest.pullRequestId)"
    }
}

function Get-AdoPrContextByUrl {
    param([string]$PullRequestUrl)

    $info = Convert-PrUrlToAdoInfo -PullRequestUrl $PullRequestUrl
    if (-not $info) {
        throw "Invalid Azure DevOps PR URL."
    }

    $prUri = "https://dev.azure.com/$($info.org)/$($info.project)/_apis/git/repositories/$($info.repo)/pullRequests/$($info.id)?api-version=7.1"
    $pullRequest = Invoke-AdoRequest -Uri $prUri
    return Convert-AdoPrToResult -Org $info.org -Project $info.project -Repo $info.repo -PullRequest $pullRequest -ResolvedPrUrl $PullRequestUrl
}

function Get-AdoPrContextByCurrentBranch {
    $remote = Get-CurrentGitRemote
    $repoInfo = Convert-RemoteToAdoInfo -RemoteUrl $remote
    if (-not $repoInfo) {
        throw "Current git remote is not an Azure DevOps repository."
    }

    $branch = Get-CurrentGitBranch
    $sourceRef = "refs/heads/$branch"
    $listUri = "https://dev.azure.com/$($repoInfo.org)/$($repoInfo.project)/_apis/git/repositories/$($repoInfo.repo)/pullrequests?searchCriteria.sourceRefName=$sourceRef&searchCriteria.status=active&api-version=7.1"
    $pullRequests = Invoke-AdoRequest -Uri $listUri
    $candidates = @($pullRequests.value)
    if ($candidates.Count -eq 0) {
        $listUri = "https://dev.azure.com/$($repoInfo.org)/$($repoInfo.project)/_apis/git/repositories/$($repoInfo.repo)/pullrequests?searchCriteria.sourceRefName=$sourceRef&searchCriteria.status=all&api-version=7.1"
        $pullRequests = Invoke-AdoRequest -Uri $listUri
        $candidates = @($pullRequests.value)
    }

    if ($candidates.Count -eq 0) {
        throw "No Azure DevOps pull request found for branch '$branch'."
    }

    $candidate = $candidates[0]
    $prUri = "https://dev.azure.com/$($repoInfo.org)/$($repoInfo.project)/_apis/git/repositories/$($repoInfo.repo)/pullRequests/$($candidate.pullRequestId)?api-version=7.1"
    $pullRequest = Invoke-AdoRequest -Uri $prUri
    $resolvedUrl = "https://dev.azure.com/$($repoInfo.org)/$($repoInfo.project)/_git/$($repoInfo.repo)/pullrequest/$($candidate.pullRequestId)"
    return Convert-AdoPrToResult -Org $repoInfo.org -Project $repoInfo.project -Repo $repoInfo.repo -PullRequest $pullRequest -ResolvedPrUrl $resolvedUrl
}

function Invoke-PrContext {
    param([hashtable]$Arguments)

    Import-PrContextEnvironment

    $prUrl = $Arguments["pr_url"]
    if ($prUrl) {
        $prUrl = $prUrl.Trim()
        if ($prUrl -match '^https://github\.com/') {
            return Get-GitHubPrContextByUrl -PullRequestUrl $prUrl
        }
        if ($prUrl -match '^https://(?:dev\.azure\.com|[^/.]+\.visualstudio\.com)/') {
            return Get-AdoPrContextByUrl -PullRequestUrl $prUrl
        }

        throw "Unsupported pull request URL. Use a GitHub or Azure DevOps PR URL."
    }

    $remote = Get-CurrentGitRemote
    if (Convert-RemoteToGitHubInfo -RemoteUrl $remote) {
        return Get-GitHubPrContextByCurrentBranch
    }
    if (Convert-RemoteToAdoInfo -RemoteUrl $remote) {
        return Get-AdoPrContextByCurrentBranch
    }

    throw "Could not auto-detect a supported pull request provider from the current git remote."
}

