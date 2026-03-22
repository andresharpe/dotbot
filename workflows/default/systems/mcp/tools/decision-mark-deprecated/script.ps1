function Invoke-DecisionMarkDeprecated {
    param([hashtable]$Arguments)

    $decId = $Arguments['decision_id']
    $reason = $Arguments['reason'] ?? ''
    if (-not $decId) { throw "decision_id is required" }
    if ($decId -notmatch '^dec-[a-f0-9]{8}$') { throw "Invalid decision_id format '$decId'. Expected: dec-XXXXXXXX" }

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
    $dec.status = 'deprecated'
    $dec.date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
    if ($reason) { $dec.deprecation_reason = $reason }

    $targetDir = Join-Path $decisionsBaseDir "deprecated"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

    $targetPath = Join-Path $targetDir $found.file.Name
    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Encoding UTF8
    Remove-Item -Path $found.file.FullName -Force

    return @{
        success = $true
        decision_id = $decId
        message = "Decision '$decId' deprecated"
        file_path = $targetPath
    }
}
