param(
  [Parameter(Mandatory = $true)][string]$SourcePath,
  [string]$OutputPath,
  [int]$CanvasSize = 192,
  [switch]$TrimTransparent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = $SourcePath }
if (-not (Test-Path -LiteralPath $SourcePath)) { throw "Missing source icon: $SourcePath" }

# GDI+ has no WebP codec; decode a WebP source to a temp PNG first.
$sourceForBitmap = $SourcePath
if ([System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant() -eq '.webp') {
  $dwebp = Join-Path $PSScriptRoot 'bin\dwebp.exe'
  if (-not (Test-Path -LiteralPath $dwebp)) {
    throw "Missing tool/bin/dwebp.exe. Download the Windows libwebp release from " +
      "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ " +
      "and place dwebp.exe in app/tool/bin/ (gitignored)."
  }
  $sourceForBitmap = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + '.png')
  & $dwebp -quiet $SourcePath -o $sourceForBitmap
  if ($LASTEXITCODE -ne 0) { throw "dwebp failed to decode $SourcePath" }
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class SingleIconResizer {
  public static void Resize(string sourcePath, string outputPath, int canvasSize, bool trimTransparent) {
    using (var source = new Bitmap(sourcePath)) {
      var crop = new Rectangle(0, 0, source.Width, source.Height);
      var destination = new Rectangle(0, 0, canvasSize, canvasSize);
      if (trimTransparent) {
        int left = source.Width, top = source.Height, right = -1, bottom = -1;
        for (int y = 0; y < source.Height; y++) {
          for (int x = 0; x < source.Width; x++) {
            if (source.GetPixel(x, y).A <= 8) continue;
            left = Math.Min(left, x); top = Math.Min(top, y);
            right = Math.Max(right, x); bottom = Math.Max(bottom, y);
          }
        }
        if (right < left) throw new InvalidOperationException("Icon is fully transparent.");
        crop = Rectangle.FromLTRB(left, top, right + 1, bottom + 1);
        // Preserve the artwork's proportions and a small antialiasing margin.
        double scale = canvasSize * .96 / Math.Max(crop.Width, crop.Height);
        int width = (int)Math.Round(crop.Width * scale);
        int height = (int)Math.Round(crop.Height * scale);
        destination = new Rectangle((canvasSize - width) / 2, (canvasSize - height) / 2, width, height);
      }
      using (var output = new Bitmap(canvasSize, canvasSize, PixelFormat.Format32bppArgb)) {
        using (var graphics = Graphics.FromImage(output)) {
          graphics.Clear(Color.Transparent);
          graphics.CompositingMode = CompositingMode.SourceOver;
          graphics.CompositingQuality = CompositingQuality.HighQuality;
          graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
          graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
          graphics.SmoothingMode = SmoothingMode.HighQuality;
          graphics.DrawImage(source, destination, crop, GraphicsUnit.Pixel);
        }
        output.Save(outputPath, ImageFormat.Png);
      }
    }
  }
}
'@

$tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + '.png')
[SingleIconResizer]::Resize($sourceForBitmap, $tempPath, $CanvasSize, $TrimTransparent.IsPresent)

if ([System.IO.Path]::GetExtension($OutputPath).ToLowerInvariant() -eq '.webp') {
  $cwebp = Join-Path $PSScriptRoot 'bin\cwebp.exe'
  if (-not (Test-Path -LiteralPath $cwebp)) {
    throw "Missing tool/bin/cwebp.exe. Download the Windows libwebp release from " +
      "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ " +
      "and place cwebp.exe in app/tool/bin/ (gitignored)."
  }
  & $cwebp -quiet -q 90 -alpha_q 100 -m 6 $tempPath -o $OutputPath
  if ($LASTEXITCODE -ne 0) { throw "cwebp failed to encode $OutputPath" }
  Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
} else {
  Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force
}
Write-Host "Resized $SourcePath to ${CanvasSize}px -> $OutputPath"
