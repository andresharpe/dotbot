function Invoke-DecisionList {
    param([hashtable]$Arguments)

    $filterStatus = $Arguments['status']
    $decisionsBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\decisions"
    $allStatuses = @('proposed', 'accepted', 'deprecated', 'superseded')

    if ($filterStatus -and $filterStatus -notin $allStatuses) {
        throw "Invalid status filter '$filterStatus'. Must be one of: $($allStatuses -join ', ')"
    }

    $searchDirs = if ($filterStatus) { @($filterStatus) } else { $allStatuses }

    $decisions = @()
    foreach ($statusDir in $searchDirs) {
        $dirPath = Join-Path $decisionsBaseDir $statusDir
        if (-not (Test-Path $dirPath)) { continue }

        $files = Get-ChildItem -Path $dirPath -Filter "dec-*.json" -File -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $dec = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                $decisions += @{
                    id = $dec.id
                    title = $dec.title
                    type = $dec.type
                    status = $statusDir
                    date = $dec.date
                    impact = $dec.impact
                    tags = $dec.tags
                    superseded_by = $dec.superseded_by
                    file_path = $file.FullName
                    file_name = $file.Name
                }
            } catch { Write-BotLog -Level Debug -Message "Non-critical operation failed" -Exception $_ }
        }
    }

    $decisions = @($decisions | Sort-Object { $_.id })

    return @{
        success = $true
        count = $decisions.Count
        decisions = $decisions
    }
}
