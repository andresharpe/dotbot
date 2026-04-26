function Invoke-DecisionMarkAccepted {
    param([hashtable]$Arguments)

    $decId = $Arguments['decision_id']
    if (-not $decId) { throw "decision_id is required" }
    if ($decId -notmatch '^dec-[a-f0-9]{8}$') { throw "Invalid decision_id format '$decId'. Expected: dec-XXXXXXXX" }

    $decisionsBaseDir = Join-Path $global:DotbotProjectRoot ".bot\workspace\decisions"
    $sourceDir = Join-Path $decisionsBaseDir "proposed"

    if (-not (Test-Path $sourceDir)) { throw "No proposed decisions directory found" }

    $files = @(Get-ChildItem -LiteralPath $sourceDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$decId-*.json" -or $_.Name -eq "$decId.json" })
    if ($files.Count -eq 0) {
        $acceptedDir = Join-Path $decisionsBaseDir "accepted"
        if (Test-Path $acceptedDir) {
            $existing = @(Get-ChildItem -LiteralPath $acceptedDir -Filter "*.json" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$decId-*.json" -or $_.Name -eq "$decId.json" })
            if ($existing.Count -gt 0) {
                return @{ success = $true; decision_id = $decId; message = "Decision '$decId' is already accepted" }
            }
        }
        throw "Decision '$decId' not found in proposed"
    }

    $file = $files[0]
    $targetDir = Join-Path $decisionsBaseDir "accepted"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

    $dec = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
    $dec.status = 'accepted'
    $dec.date = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

    $targetPath = Join-Path $targetDir $file.Name
    $dec | ConvertTo-Json -Depth 10 | Set-Content -Path $targetPath -Encoding UTF8
    Remove-Item -Path $file.FullName -Force

    return @{
        success = $true
        decision_id = $decId
        message = "Decision '$decId' accepted"
        file_path = $targetPath
    }
}
