$ErrorActionPreference = 'Stop'

$teamsAppDir = Join-Path $PSScriptRoot '..\teams-app'
$manifestFile = Join-Path $teamsAppDir 'manifest.json'
$colorIcon = Join-Path $teamsAppDir 'color.png'
$outlineIcon = Join-Path $teamsAppDir 'outline.png'
$zipFile = Join-Path $teamsAppDir 'dotbot-teams-app.zip'

# Verify files exist
foreach ($f in @($manifestFile, $colorIcon, $outlineIcon)) {
    if (-not (Test-Path $f)) { throw "Missing: $f" }
}

# Build zip
Write-Host "Building Teams app zip..." -ForegroundColor Cyan
if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
Compress-Archive -Path $manifestFile, $colorIcon, $outlineIcon -DestinationPath $zipFile
Write-Host "Created: $zipFile" -ForegroundColor Green

# Get Graph token via az CLI (user context)
$token = az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv
if (-not $token) { throw "Failed to get Graph token" }

# Check if app already exists in catalog
Write-Host "`nChecking if Dotbot already exists in catalog..." -ForegroundColor Cyan
$headers = @{ Authorization = "Bearer $token" }
try {
    $existing = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?`$filter=externalId eq '97b86de5-7e81-4d7c-ad55-9de3ccb6170a'" -Headers $headers
    if ($existing.value.Count -gt 0) {
        $catalogId = $existing.value[0].id
        Write-Host "App already in catalog with ID: $catalogId" -ForegroundColor Green
        Write-Host "Updating existing app..." -ForegroundColor Cyan
        
        # Update existing app
        $zipBytes = [System.IO.File]::ReadAllBytes($zipFile)
        $updateHeaders = @{
            Authorization  = "Bearer $token"
            "Content-Type" = "application/zip"
        }
        $uri = "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$catalogId/appDefinitions"
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $updateHeaders -Body $zipBytes
        Write-Host "Updated successfully!" -ForegroundColor Green
        Write-Host "Catalog Teams App ID: $catalogId" -ForegroundColor White
        return
    }
} catch {
    Write-Host "Could not query catalog (may lack AppCatalog.Read.All): $($_.Exception.Message)" -ForegroundColor Yellow
}

# Publish new app to org catalog
Write-Host "`nPublishing to org-wide catalog..." -ForegroundColor Cyan
$zipBytes = [System.IO.File]::ReadAllBytes($zipFile)
$publishHeaders = @{
    Authorization  = "Bearer $token"
    "Content-Type" = "application/zip"
}
try {
    $response = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps?requiresReview=false" -Method Post -Headers $publishHeaders -Body $zipBytes
    Write-Host "Published successfully!" -ForegroundColor Green
    Write-Host "Response:" -ForegroundColor White
    $response | ConvertTo-Json -Depth 5
} catch {
    $errBody = $_.ErrorDetails.Message
    Write-Host "Failed to publish: $($_.Exception.Message)" -ForegroundColor Red
    if ($errBody) { Write-Host "Details: $errBody" -ForegroundColor Red }
    Write-Host "`nYou may need to publish manually via Teams Admin Center:" -ForegroundColor Yellow
    Write-Host "  1. Go to https://admin.teams.microsoft.com/policies/manage-apps" -ForegroundColor Yellow
    Write-Host "  2. Click 'Upload new app' -> 'Upload'" -ForegroundColor Yellow
    Write-Host "  3. Select: $zipFile" -ForegroundColor Yellow
}
