function Invoke-DecisionMarkSuperseded {
    param([hashtable]$Arguments)

    $decId = $Arguments['decision_id']
    $supersededBy = $Arguments['superseded_by']
    if (-not $decId) { throw "decision_id is required" }
    if ($decId -notmatch '^dec-[a-f0-9]{8}$') { throw "Invalid decision_id format '$decId'. Expected: dec-XXXXXXXX" }
    if (-not $supersededBy) { throw "superseded_by is required" }
    if ($supersededBy -notmatch '^dec-[a-f0-9]{8}$') { throw "Invalid superseded_by format '$supersededBy'. Expected: dec-XXXXXXXX" }

    $decisionsBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\decisions"
    $allStatuses = @('proposed', 'accepted')

    $found = $null
    foreach ($statusDir in $allStatuses) {
        $dirPath = Join-Path $decisionsBaseDir $statusDir
        if (-not (Test-Path $dirPath)) { continue }
        $files = @(Get-ChildItem -LiteralPath $dirPath -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$decId-*.json" -or $_.Name -eq "$decId.json" })
        if ($files.Count -gt 0) { $found = @{ file = $files[0]; status = $statusDir }; break }
    }

    if (-not $found) { throw "Decision '$decId' not found in proposed or accepted" }

    $dec = Get-Content -Path $found.file.FullName -Raw | ConvertFrom-Json
    $dec.status = 'superseded'
    $dec.date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    $dec.superseded_by = $supersededBy

    # Also update the superseding decision's 'supersedes' field if it exists
    $allDirs = @('proposed', 'accepted', 'deprecated', 'superseded')
    foreach ($sDir in $allDirs) {
        $sDirPath = Join-Path $decisionsBaseDir $sDir
        if (-not (Test-Path $sDirPath)) { continue }
        $sFiles = @(Get-ChildItem -LiteralPath $sDirPath -Filter "*.json" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$supersededBy-*.json" -or $_.Name -eq "$supersededBy.json" })
        if ($sFiles.Count -gt 0) {
            try {
                $superDec = Get-Content -Path $sFiles[0].FullName -Raw | ConvertFrom-Json
                $superDec.supersedes = $decId
                $superDec | ConvertTo-Json -Depth 10 | Set-Content -Path $sFiles[0].FullName -Encoding UTF8
            } catch { Write-BotLog -Level Debug -Message "Failed to parse data" -Exception $_ }
            break
        }
    }

    $targetDir = Join-Path $decisionsBaseDir "superseded"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

    $targetPath = Join-Path $targetDir $found.file.Name
    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Encoding UTF8
    Remove-Item -Path $found.file.FullName -Force

    return @{
        success = $true
        decision_id = $decId
        superseded_by = $supersededBy
        message = "Decision '$decId' superseded by $supersededBy"
        file_path = $targetPath
    }
}
