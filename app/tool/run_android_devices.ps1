[CmdletBinding()]
param(
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode = 'debug',
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
$appDirectory = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'android_production_build.ps1')
$flutterPath = Get-AndroidFlutterExecutable -AppDirectory $appDirectory
$buildArguments = @("--$Mode") + @(Get-AndroidDartDefineArguments -AppDirectory $appDirectory)
if ($Mode -eq 'release' -and -not $ListOnly) {
    $buildArguments = @(Get-AndroidProductionBuildArguments -AppDirectory $appDirectory)
}
Push-Location -LiteralPath $appDirectory
try {
    Write-Host 'Finding connected Android phones and emulators...'
    $deviceJson = & $flutterPath devices --machine --device-timeout 10
    if ($LASTEXITCODE -ne 0) { throw 'Could not discover devices. Check adb and try again.' }
    $devices = @((($deviceJson -join "`n") | ConvertFrom-Json) | Where-Object {
        $_.targetPlatform -like 'android-*' -and $_.isSupported -eq $true
    })
    if ($devices.Count -eq 0) { throw 'No connected Android devices. Start an emulator or connect a phone with USB or Wireless debugging enabled.' }
    foreach ($device in $devices) { Write-Host ('  {0} [{1}]' -f $device.name, $device.id) }
    if ($ListOnly) { return }
    # Seed the sqlite3 native libraries from the local cache so no download is needed.
    . (Join-Path (Split-Path -Parent $appDirectory) 'tool/OfflineNativeAssets.ps1')
    & $flutterPath pub get --offline | Out-Null
    Restore-SqliteNativeAssets -AppDirectory $appDirectory
    # Compile only the CPU architectures of the connected devices (much faster
    # than the fat APK with arm, arm64 and x64). Play Store bundles use their own script.
    $targetPlatforms = @($devices | ForEach-Object { $_.targetPlatform } | Sort-Object -Unique)
    $buildArguments += "--target-platform=$($targetPlatforms -join ',')"
    Write-Host "`nBuilding one $Mode APK for: $($targetPlatforms -join ', ')..."
    & $flutterPath build apk @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed. See the build output above.' }
    $apkPath = Join-Path $appDirectory "build/app/outputs/flutter-apk/app-$Mode.apk"
    $failedDevices = @()
    foreach ($device in $devices) {
        Write-Host ("`nLaunching on {0}..." -f $device.name)
        & $flutterPath run --device-id $device.id "--$Mode" --use-application-binary $apkPath --no-pub --no-resident
        if ($LASTEXITCODE -ne 0) { $failedDevices += $device.name }
    }
    if ($failedDevices.Count) { throw ('Could not launch on: ' + ($failedDevices -join ', ') + '. Reconnect those devices and Run again.') }
    Write-Host ("`nApp running ($Mode) on all {0} connected Android device(s)." -f $devices.Count)
    Write-Host 'Click Run again to rebuild. Use main.dart with one Android device for IDE debugging and hot reload.'
} finally { Pop-Location }
