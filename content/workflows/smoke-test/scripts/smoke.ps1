param(
    [string]$BotRoot,
    [string]$WorkflowDir,
    [string]$ProcessId
)

$controlDir = Join-Path $BotRoot ".control"
if (-not (Test-Path -LiteralPath $controlDir -PathType Container)) {
    New-Item -ItemType Directory -Path $controlDir -Force | Out-Null
}

$marker = [ordered]@{
    workflow   = "smoke-test"
    process_id = $ProcessId
    ran_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$markerPath = Join-Path $controlDir "smoke-test.json"
$marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8NoBOM

Write-Output "smoke-test marker written to $markerPath"
