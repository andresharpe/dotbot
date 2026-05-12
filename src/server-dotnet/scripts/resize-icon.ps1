param(
    [Parameter(Mandatory = $true)]
    [string]$SourceImage
)

if (-not (Test-Path $SourceImage)) {
    Write-Error "Source image not found: $SourceImage"
    exit 1
}

Add-Type -AssemblyName System.Drawing

$colorPath = Join-Path $PSScriptRoot '..\teams-app\color.png'
$outlinePath = Join-Path $PSScriptRoot '..\teams-app\outline.png'

$src = [System.Drawing.Image]::FromFile($SourceImage)

# Color icon: 192x192
$color = New-Object System.Drawing.Bitmap(192, 192)
$gc = [System.Drawing.Graphics]::FromImage($color)
$gc.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gc.DrawImage($src, 0, 0, 192, 192)
$gc.Dispose()
$color.Save($colorPath, [System.Drawing.Imaging.ImageFormat]::Png)
$color.Dispose()

# Outline icon: 32x32
$outline = New-Object System.Drawing.Bitmap(32, 32)
$go = [System.Drawing.Graphics]::FromImage($outline)
$go.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$go.DrawImage($src, 0, 0, 32, 32)
$go.Dispose()
$outline.Save($outlinePath, [System.Drawing.Imaging.ImageFormat]::Png)
$outline.Dispose()

$src.Dispose()

Write-Host "Icons created:"
Write-Host "  color.png  (192x192): $colorPath"
Write-Host "  outline.png (32x32): $outlinePath"
