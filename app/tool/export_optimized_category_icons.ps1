param(
  [string]$SourceDirectory,
  [string]$OutputDirectory,
  [int]$CanvasSize = 128,
  [string[]]$IconKeys
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$projectRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $projectRoot
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
  $SourceDirectory = Join-Path $workspaceRoot 'assets_raw\icon_packs_raw\3d'
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  $OutputDirectory = Join-Path $projectRoot 'assets\icon_packs\3d'
}

$dwebp = Join-Path $PSScriptRoot 'bin\dwebp.exe'
$cwebp = Join-Path $PSScriptRoot 'bin\cwebp.exe'
if (-not (Test-Path -LiteralPath $dwebp) -or -not (Test-Path -LiteralPath $cwebp)) {
  throw "Missing tool/bin/cwebp.exe and/or tool/bin/dwebp.exe. Download the " +
    "Windows libwebp release from " +
    "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/ " +
    "and place cwebp.exe/dwebp.exe in app/tool/bin/ (gitignored)."
}

Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class OptimizedCategoryIconExporter {
  public static void Export(string sourcePngPath, string outputPngPath, int canvasSize) {
    using (var source = new Bitmap(sourcePngPath)) {
      int overscan = (int)Math.Round(canvasSize * 0.052);
      var artBounds = new Rectangle(-overscan, -overscan,
          canvasSize + overscan * 2, canvasSize + overscan * 2);
      using (var output = new Bitmap(canvasSize, canvasSize, PixelFormat.Format32bppArgb)) {
        using (var graphics = Graphics.FromImage(output)) {
          graphics.Clear(Color.Transparent);
          graphics.CompositingMode = CompositingMode.SourceOver;
          graphics.CompositingQuality = CompositingQuality.HighQuality;
          graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
          graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
          graphics.SmoothingMode = SmoothingMode.HighQuality;
          graphics.DrawImage(source, artBounds, 0, 0, source.Width, source.Height,
              GraphicsUnit.Pixel);
        }
        output.Save(outputPngPath, ImageFormat.Png);
      }
    }
  }
}
'@

if (-not (Test-Path -LiteralPath $SourceDirectory)) {
  throw "Missing raw icon directory: $SourceDirectory"
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$sources = @(Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.webp' -File)
if ($IconKeys) {
  $sources = @($sources | Where-Object { $_.BaseName -in $IconKeys })
  foreach ($key in $IconKeys) {
    if ($key -notin $sources.BaseName) { throw "Missing raw category icon: $key" }
  }
}
if ($sources.Count -eq 0) {
  throw "No raw category icons found."
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
  foreach ($source in $sources) {
    # System.Drawing (GDI+) has no WebP codec, so decode the raw master to a
    # temp PNG first; the compositor below is unchanged and still PNG-based.
    $rawPng = Join-Path $tempDir "$($source.BaseName).raw.png"
    & $dwebp -quiet $source.FullName -o $rawPng
    if ($LASTEXITCODE -ne 0) { throw "dwebp failed to decode $($source.Name)" }

    $composedPng = Join-Path $tempDir "$($source.BaseName).png"
    [OptimizedCategoryIconExporter]::Export($rawPng, $composedPng, $CanvasSize)

    $outputPath = Join-Path $OutputDirectory "$($source.BaseName).webp"
    & $cwebp -quiet -q 90 -alpha_q 100 -m 6 $composedPng -o $outputPath
    if ($LASTEXITCODE -ne 0) { throw "cwebp failed to encode $($source.Name)" }
    Write-Host "Exported $($source.BaseName)"
  }
} finally {
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Theme effects are now rendered by Flutter, so old duplicated dark assets
# must not remain in the application bundle after a re-export.
Get-ChildItem -LiteralPath $OutputDirectory -Filter '*_dark.*' -File |
  Remove-Item -Force

Write-Host "Exported $($sources.Count) shared category icons at ${CanvasSize}px, lossy WebP q90."
