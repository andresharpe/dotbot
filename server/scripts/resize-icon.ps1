Add-Type -AssemblyName System.Drawing

$srcPath = 'C:\Users\andre\Downloads\u7279566594_smiley_robot_face_on_a_crt_screen_--raw_--v_7_e9a85a4a-a9f5-4916-98e7-4acdf603bb19_0.png'
$colorPath = Join-Path $PSScriptRoot '..\teams-app\color.png'
$outlinePath = Join-Path $PSScriptRoot '..\teams-app\outline.png'

$src = [System.Drawing.Image]::FromFile($srcPath)

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
