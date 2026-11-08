# Shared by the Play Store bundle command and Android Studio's release launcher.
function Get-AndroidFlutterExecutable {
    param([Parameter(Mandatory)][string]$AppDirectory)

    $propertiesPath = Join-Path $AppDirectory 'android/local.properties'
    if (Test-Path -LiteralPath $propertiesPath) {
        $sdkLine = Get-Content -LiteralPath $propertiesPath | Where-Object { $_ -match '^flutter\.sdk=' } | Select-Object -First 1
        if ($sdkLine) {
            $sdkDirectory = $sdkLine.Substring('flutter.sdk='.Length).Replace('\\', '\').Replace('\:', ':')
            $flutterPath = Join-Path $sdkDirectory 'bin/flutter.bat'
            if (Test-Path -LiteralPath $flutterPath) { return $flutterPath }
        }
    }
    $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
    if ($flutterCommand) { return $flutterCommand.Source }
    $fallback = Join-Path $env:USERPROFILE 'develop/flutter/bin/flutter.bat'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw 'Configure the Flutter SDK in Android Studio or android/local.properties.'
}

# secrets/.env (gitignored) holds the build-time settings: Play product IDs, AdMob
# IDs and the AI relay address. Flutter reads it only when given this flag, and
# hands the values on to Gradle for the manifest.
function Get-AndroidDartDefineArguments {
    param([Parameter(Mandatory)][string]$AppDirectory)

    $envPath = Join-Path (Split-Path -Parent $AppDirectory) 'secrets/.env'
    if (Test-Path -LiteralPath $envPath) { return @("--dart-define-from-file=$envPath") }
    Write-Warning 'secrets/.env not found: building with default settings (no AdMob, Play product, AI relay or report-bot values). Copy app/.env.example to secrets/.env.'
    return @()
}

function Get-AndroidProductionBuildArguments {
    param(
        [Parameter(Mandatory)][string]$AppDirectory,
        [string]$Version
    )

    # Gradle otherwise falls back to the debug key. Neither production entry
    # point should silently create a debug-signed release.
    $signingProperties = Join-Path (Split-Path -Parent $AppDirectory) 'secrets/android/key.properties'
    if (-not (Test-Path -LiteralPath $signingProperties)) {
        throw 'Production builds require secrets/android/key.properties with the Play Store upload signing key.'
    }
    if (-not $Version) {
        $pubspec = [System.IO.File]::ReadAllText((Join-Path $AppDirectory 'pubspec.yaml'))
        $match = [regex]::Match($pubspec, '(?m)^version:[ \t]*(?<version>\d+\.\d+\.\d+\+\d+)[ \t]*\r?$')
        if (-not $match.Success) { throw 'Expected pubspec.yaml version in major.minor.patch+buildCode format.' }
        $Version = $match.Groups['version'].Value
    }
    if ($Version -cnotmatch '^\d+\.\d+\.\d+\+\d+$') {
        throw 'Production version must be major.minor.patch+buildCode.'
    }
    $versionParts = $Version.Split('+')
    # Keep all compilation options here so APK and AAB production builds stay
    # aligned. Only their output format and publishing version differ.
    return @('--release', "--build-name=$($versionParts[0])", "--build-number=$($versionParts[1])") +
        @(Get-AndroidDartDefineArguments -AppDirectory $AppDirectory)
}
