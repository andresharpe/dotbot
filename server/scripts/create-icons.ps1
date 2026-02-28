Add-Type -AssemblyName System.Drawing

$teamsDir = Join-Path $PSScriptRoot "..\teams-app"
New-Item -ItemType Directory -Path $teamsDir -Force | Out-Null

# Color icon (192x192) - blue background with white "D"
$bmp = New-Object System.Drawing.Bitmap(192, 192)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::FromArgb(0, 120, 212))
$font = New-Object System.Drawing.Font('Arial', 72, [System.Drawing.FontStyle]::Bold)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center
$rect = New-Object System.Drawing.RectangleF(0, 0, 192, 192)
$g.DrawString('D', $font, [System.Drawing.Brushes]::White, $rect, $sf)
$bmp.Save((Join-Path $teamsDir "color.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()

# Outline icon (32x32) - transparent background with blue "D"
$bmp2 = New-Object System.Drawing.Bitmap(32, 32)
$g2 = [System.Drawing.Graphics]::FromImage($bmp2)
$g2.Clear([System.Drawing.Color]::Transparent)
$font2 = New-Object System.Drawing.Font('Arial', 18, [System.Drawing.FontStyle]::Bold)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 120, 212))
$rect2 = New-Object System.Drawing.RectangleF(0, 0, 32, 32)
$g2.DrawString('D', $font2, $brush, $rect2, $sf)
$bmp2.Save((Join-Path $teamsDir "outline.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$g2.Dispose()
$bmp2.Dispose()

Write-Host "Icons created in $teamsDir" -ForegroundColor Green
