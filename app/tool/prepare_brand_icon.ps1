param(
  [string]$MasterPath = (Join-Path $PSScriptRoot '..\..\assets_raw\app_icon_master.png')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rawWebp = Join-Path $PSScriptRoot '..\..\assets_raw\app_icon.webp'
$bundledWebp = Join-Path $PSScriptRoot '..\assets\images\app_icon.webp'
$cwebp = Join-Path $PSScriptRoot 'bin\cwebp.exe'
if (-not (Test-Path -LiteralPath $MasterPath)) { throw "Missing icon master: $MasterPath" }
if (-not (Test-Path -LiteralPath $cwebp)) { throw "Missing encoder: $cwebp" }

& $cwebp -quiet -q 96 -alpha_q 100 -m 6 $MasterPath -o $rawWebp
if ($LASTEXITCODE -ne 0) { throw 'Could not encode the launcher icon master.' }
& (Join-Path $PSScriptRoot 'resize_icon.ps1') -SourcePath $MasterPath -OutputPath $bundledWebp -CanvasSize 512
if ($LASTEXITCODE -ne 0) { throw 'Could not create the in-app icon.' }
& (Join-Path $PSScriptRoot 'resize_icon.ps1') -SourcePath $MasterPath -OutputPath (Join-Path $PSScriptRoot '..\..\assets_raw\launcher_icon.png') -CanvasSize 1024 -TrimTransparent

Write-Host 'Prepared the rich purple launcher and in-app icon sources.'
