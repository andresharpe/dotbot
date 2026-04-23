function Invoke-AtlassianDownload {
    param([hashtable]$Arguments)

    $jiraKey   = $Arguments['jira_key']
    $targetDir = $Arguments['target_dir']

    if (-not $jiraKey) { throw "jira_key is required" }

    # ---------------------------------------------------------------------------
    # Load .env.local for Atlassian credentials
    # ---------------------------------------------------------------------------
    $envLocal = Join-Path $global:DotbotProjectRoot ".env.local"
    if (Test-Path $envLocal) {
        Get-Content $envLocal | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
            }
        }
    }

    $email    = $env:ATLASSIAN_EMAIL
    $apiToken = $env:ATLASSIAN_API_TOKEN
    $cloudId  = $env:ATLASSIAN_CLOUD_ID

    # Auto-resolve site URL to Cloud ID UUID
    if ($cloudId -and $cloudId -match '\.atlassian\.net') {
        $siteUrl = ($cloudId -replace '/+$', '')
        if ($siteUrl -notmatch '^https?://') { $siteUrl = "https://$siteUrl" }
        try {
            $tenantInfo = Invoke-RestMethod -Uri "$siteUrl/_edge/tenant_info" -ErrorAction Stop
            $cloudId = $tenantInfo.cloudId
            $env:ATLASSIAN_CLOUD_ID = $cloudId   # cache for subsequent calls
        } catch {
            throw "ATLASSIAN_CLOUD_ID looks like a site URL but could not resolve via _edge/tenant_info: $_`nSet ATLASSIAN_CLOUD_ID to the UUID directly (find it at $siteUrl/_edge/tenant_info)"
        }
    }

    if (-not $email)    { throw "ATLASSIAN_EMAIL not set in .env.local" }
    if (-not $apiToken) { throw "ATLASSIAN_API_TOKEN not set in .env.local" }
    if (-not $cloudId)  { throw "ATLASSIAN_CLOUD_ID not set in .env.local" }

    # ---------------------------------------------------------------------------
    # Determine target directory
    # ---------------------------------------------------------------------------
    if (-not $targetDir) {
        $targetDir = ".bot\workspace\product\briefing\docs"
    }
    $docsPath = Join-Path $global:DotbotProjectRoot $targetDir
    if (-not (Test-Path $docsPath)) {
        New-Item -Path $docsPath -ItemType Directory -Force | Out-Null
    }

    # ---------------------------------------------------------------------------
    # Auth header for Atlassian REST API
    # ---------------------------------------------------------------------------
    $authBytes = [System.Text.Encoding]::ASCII.GetBytes("${email}:${apiToken}")
    $authHeader = "Basic " + [System.Convert]::ToBase64String($authBytes)
    $headers = @{
        "Authorization" = $authHeader
        "Accept"        = "application/json"
    }

    $baseUrl = "https://api.atlassian.com/ex/jira/$cloudId/rest/api/3"
    $confluenceBaseUrl = "https://api.atlassian.com/ex/confluence/$cloudId"
    $downloadedFiles = @()

    # ---------------------------------------------------------------------------
    # Helper: Download a single attachment
    # ---------------------------------------------------------------------------
    function Download-Attachment {
        param(
            [string]$Url,
            [string]$FileName,
            [string]$IssueKey,
            [string]$Topic,
            [string]$Source
        )

        $safeTopic = $Topic -replace '[^\w\-]', '_'
        $safeFile  = $FileName -replace '[^\w\-\.]', '_'
        $destName  = "${IssueKey}_${safeTopic}_${safeFile}"
        $destPath  = Join-Path $docsPath $destName

        try {
            Invoke-WebRequest -Uri $Url -Headers $headers -OutFile $destPath -ErrorAction Stop
            $fileInfo = Get-Item $destPath
            return @{
                path          = "$targetDir/$destName"
                original_name = $FileName
                source        = $Source
                size          = $fileInfo.Length
                content_type  = switch -Wildcard ([System.IO.Path]::GetExtension($destPath).ToLowerInvariant()) {
                    '.pdf'  { 'application/pdf' }   '.png'  { 'image/png' }
                    '.jpg'  { 'image/jpeg' }        '.jpeg' { 'image/jpeg' }
                    '.gif'  { 'image/gif' }         '.svg'  { 'image/svg+xml' }
                    '.doc'  { 'application/msword' } '.docx' { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
                    '.xls'  { 'application/vnd.ms-excel' } '.xlsx' { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
                    '.ppt'  { 'application/vnd.ms-powerpoint' } '.pptx' { 'application/vnd.openxmlformats-officedocument.presentationml.presentation' }
                    '.msg'  { 'application/vnd.ms-outlook' }
                    '.zip'  { 'application/zip' }   '.json' { 'application/json' }
                    '.txt'  { 'text/plain' }        '.csv'  { 'text/csv' }
                    '.html' { 'text/html' }         '.md'   { 'text/markdown' }
                    default { 'application/octet-stream' }
                }
                issue_key     = $IssueKey
            }
        } catch {
            Write-Warning "Failed to download $FileName from $Source : $_"
            return $null
        }
    }

    # ---------------------------------------------------------------------------
    # 1. Get attachments from the main issue
    # ---------------------------------------------------------------------------
    try {
        $issueResp = Invoke-RestMethod -Uri "$baseUrl/issue/${jiraKey}?fields=attachment,issuelinks,summary" `
            -Headers $headers -ErrorAction Stop

        if ($issueResp.fields.attachment) {
            foreach ($att in $issueResp.fields.attachment) {
                $result = Download-Attachment `
                    -Url $att.content -FileName $att.filename `
                    -IssueKey $jiraKey -Topic "Main" -Source "jira-attachment"
                if ($result) { $downloadedFiles += $result }
            }
        }
    } catch {
        Write-Warning "Failed to fetch main issue $jiraKey : $_"
    }

    # ---------------------------------------------------------------------------
    # 2. Get attachments from child issues
    # ---------------------------------------------------------------------------
    try {
        $jql = [System.Uri]::EscapeDataString("parent = $jiraKey")
        $childResp = Invoke-RestMethod -Method Post `
            -Uri "$baseUrl/search/jql" `
            -Headers ($headers + @{ "Content-Type" = "application/json" }) `
            -Body (@{ jql = "parent = $jiraKey"; fields = @("key","summary","attachment"); maxResults = 50 } | ConvertTo-Json) `
            -ErrorAction Stop

        foreach ($child in $childResp.issues) {
            if ($child.fields.attachment) {
                $childTopic = ($child.fields.summary -replace '[^\w\s\-]', '') -replace '\s+', '_'
                if ($childTopic.Length -gt 40) { $childTopic = $childTopic.Substring(0, 40) }

                foreach ($att in $child.fields.attachment) {
                    $result = Download-Attachment `
                        -Url $att.content -FileName $att.filename `
                        -IssueKey $child.key -Topic $childTopic -Source "jira-child-attachment"
                    if ($result) { $downloadedFiles += $result }
                }
            }
        }
    } catch {
        Write-Warning "Failed to fetch child issues for $jiraKey : $_"
    }

    # ---------------------------------------------------------------------------
    # 3. Get attachments from linked Confluence pages
    # ---------------------------------------------------------------------------
    try {
        $remoteLinks = Invoke-RestMethod `
            -Uri "$baseUrl/issue/${jiraKey}/remotelink" `
            -Headers $headers -ErrorAction Stop

        $confluencePageIds = @()
        foreach ($link in $remoteLinks) {
            $linkUrl = $link.object.url
            if ($linkUrl -match '/wiki/.*?/pages/(\d+)') {
                $confluencePageIds += $matches[1]
            }
        }

        # Also check issue links for Confluence mentions
        if ($issueResp.fields.issuelinks) {
            foreach ($link in $issueResp.fields.issuelinks) {
                $linkedKey = if ($link.outwardIssue) { $link.outwardIssue.key } elseif ($link.inwardIssue) { $link.inwardIssue.key }
                # We only process Confluence remote links, not Jira-to-Jira links here
            }
        }

        foreach ($pageId in $confluencePageIds) {
            try {
                $pageResp = Invoke-RestMethod `
                    -Uri "$confluenceBaseUrl/wiki/api/v2/pages/${pageId}?body-format=storage" `
                    -Headers $headers -ErrorAction Stop

                $pageTitle = ($pageResp.title -replace '[^\w\s\-]', '') -replace '\s+', '_'
                if ($pageTitle.Length -gt 40) { $pageTitle = $pageTitle.Substring(0, 40) }

                # Get page attachments
                $attResp = Invoke-RestMethod `
                    -Uri "$confluenceBaseUrl/wiki/api/v2/pages/${pageId}/attachments" `
                    -Headers $headers -ErrorAction Stop

                foreach ($att in $attResp.results) {
                    $downloadUrl = "$confluenceBaseUrl/wiki/rest/api/content/$($att.id)/download"
                    $result = Download-Attachment `
                        -Url $downloadUrl -FileName $att.title `
                        -IssueKey $jiraKey -Topic $pageTitle -Source "confluence-attachment"
                    if ($result) { $downloadedFiles += $result }
                }
            } catch {
                Write-Warning "Failed to fetch Confluence page $pageId : $_"
            }
        }
    } catch {
        Write-Warning "Failed to fetch remote links for $jiraKey : $_"
    }

    # ---------------------------------------------------------------------------
    # Return manifest
    # ---------------------------------------------------------------------------
    return @{
        success = $true
        files   = $downloadedFiles
        count   = $downloadedFiles.Count
        message = "Downloaded $($downloadedFiles.Count) file(s) to $targetDir"
    }
}
