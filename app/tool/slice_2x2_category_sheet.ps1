param(
  [Parameter(Mandatory = $true)][string]$SourcePath,
  [Parameter(Mandatory = $true)][string]$Keys,
  [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\icon_packs\3d'
}

$keyList = @($Keys.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($keyList.Count -ne 4) { throw 'Exactly four comma-separated keys are required in top-left, top-right, bottom-left, bottom-right order.' }
if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Missing generated sheet: $SourcePath" }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Get-VisibleBounds {
  param([System.Drawing.Bitmap]$Bitmap)
  $left = $Bitmap.Width; $top = $Bitmap.Height; $right = -1; $bottom = -1
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      if ($Bitmap.GetPixel($x, $y).A -gt 8) {
        if ($x -lt $left) { $left = $x }; if ($x -gt $right) { $right = $x }
        if ($y -lt $top) { $top = $y }; if ($y -gt $bottom) { $bottom = $y }
      }
    }
  }
  if ($right -lt $left -or $bottom -lt $top) { throw 'A sheet quadrant contains no visible artwork.' }
  [System.Drawing.Rectangle]::FromLTRB($left, $top, $right + 1, $bottom + 1)
}

$sheet = [System.Drawing.Bitmap]::FromFile($SourcePath)
try {
  $midX = [int][Math]::Floor($sheet.Width / 2.0)
  $midY = [int][Math]::Floor($sheet.Height / 2.0)
  $regions = @(
    [System.Drawing.Rectangle]::new(0, 0, $midX, $midY),
    [System.Drawing.Rectangle]::new($midX, 0, $sheet.Width - $midX, $midY),
    [System.Drawing.Rectangle]::new(0, $midY, $midX, $sheet.Height - $midY),
    [System.Drawing.Rectangle]::new($midX, $midY, $sheet.Width - $midX, $sheet.Height - $midY)
  )

  for ($i = 0; $i -lt 4; $i++) {
    $region = $regions[$i]
    $quadrant = New-Object System.Drawing.Bitmap($region.Width, $region.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
      $g = [System.Drawing.Graphics]::FromImage($quadrant)
      try {
        $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $g.DrawImage($sheet, [System.Drawing.Rectangle]::new(0, 0, $region.Width, $region.Height), $region, [System.Drawing.GraphicsUnit]::Pixel)
      } finally { $g.Dispose() }

      $bounds = Get-VisibleBounds $quadrant
      $canvasSize = 512; $contentSize = 440
      $scale = [Math]::Min($contentSize / [double]$bounds.Width, $contentSize / [double]$bounds.Height)
      $w = [int][Math]::Round($bounds.Width * $scale); $h = [int][Math]::Round($bounds.Height * $scale)
      $x = [int][Math]::Round(($canvasSize - $w) / 2.0); $y = [int][Math]::Round(($canvasSize - $h) / 2.0)
      $icon = New-Object System.Drawing.Bitmap($canvasSize, $canvasSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      try {
        $g = [System.Drawing.Graphics]::FromImage($icon)
        try {
          $g.Clear([System.Drawing.Color]::Transparent)
          $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
          $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
          $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
          $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
          $g.DrawImage($quadrant, [System.Drawing.Rectangle]::new($x, $y, $w, $h), $bounds, [System.Drawing.GraphicsUnit]::Pixel)
        } finally { $g.Dispose() }
        # Raw masters are kept as lossy WebP (see app/tool/bin/README or
        # export_optimized_category_icons.ps1); GDI+ has no WebP encoder, so
        # save a temp PNG and shell out to cwebp for the final file.
        $tempPng = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + '.png')
        $icon.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)
        $cwebp = Join-Path $PSScriptRoot 'bin\cwebp.exe'
        if (-not (Test-Path -LiteralPath $cwebp)) {
          throw "Missing tool/bin/cwebp.exe. Download the Windows libwebp release from " +
            "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ " +
            "and place cwebp.exe in app/tool/bin/ (gitignored)."
        }
        $target = Join-Path $OutputDirectory "$($keyList[$i]).webp"
        & $cwebp -quiet -q 90 -alpha_q 100 -m 6 $tempPng -o $target
        if ($LASTEXITCODE -ne 0) { throw "cwebp failed to encode $($keyList[$i])" }
        Remove-Item -LiteralPath $tempPng -Force -ErrorAction SilentlyContinue
        Write-Host "Created $target"
      } finally { $icon.Dispose() }
    } finally { $quadrant.Dispose() }
  }
} finally { $sheet.Dispose() }
