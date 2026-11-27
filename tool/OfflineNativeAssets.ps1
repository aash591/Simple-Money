# Keeps the prebuilt sqlite3 Android libraries in a per-user cache so release
# builds work offline. The sqlite3 build hook otherwise downloads them from
# GitHub on every fresh .dart_tool (e.g. after `flutter clean`), which fails
# whenever GitHub's release endpoint is down or unreachable.
#
# Dot-source this file and call Restore-SqliteNativeAssets.

$script:SqliteAndroidArchitectures = @('arm', 'arm64', 'x64')

function Get-SqliteReleaseInfo {
    param([Parameter(Mandatory)][string]$AppDirectory)

    $lock = Get-Content -LiteralPath (Join-Path $AppDirectory 'pubspec.lock') -Raw
    $match = [regex]::Match($lock, '(?ms)^  sqlite3:\r?\n.*?^    version: "(?<v>[^"]+)"')
    if (-not $match.Success) { throw 'sqlite3 is not in pubspec.lock. Run flutter pub get first.' }
    $version = $match.Groups['v'].Value

    $pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
    $hashesFile = Join-Path $pubCache "hosted\pub.dev\sqlite3-$version\lib\src\hook\asset_hashes.dart"
    if (-not (Test-Path -LiteralPath $hashesFile)) { throw "sqlite3 $version is not in the pub cache. Run flutter pub get first." }
    $hashes = Get-Content -LiteralPath $hashesFile -Raw

    $tag = [regex]::Match($hashes, "releaseTag\s*=\s*'(?<t>[^']+)'")
    $releaseTag = if ($tag.Success) { $tag.Groups['t'].Value } else { "sqlite3-$version" }

    [pscustomobject]@{ Version = $version; Tag = $releaseTag; Hashes = $hashes }
}

function Save-VerifiedDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Sha256
    )

    # github.com resolves to several edge nodes and some return 504 for release
    # downloads while others work, so try the default route and then known nodes.
    $hostName = ([uri]$Url).Host
    $routes = @($null) + @('20.205.243.166', '140.82.112.3', '140.82.113.3', '140.82.114.3')
    $temporary = "$Destination.part"
    foreach ($attempt in 1..2) {
        foreach ($ip in $routes) {
            $arguments = @('--silent', '--location', '--fail', '--max-time', '180', '--output', $temporary)
            if ($ip) { $arguments += @('--resolve', "${hostName}:443:$ip") }
            & curl.exe @arguments $Url
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $temporary)) {
                $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -eq $Sha256.ToLowerInvariant()) {
                    Move-Item -LiteralPath $temporary -Destination $Destination -Force
                    return $true
                }
            }
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
    return $false
}

function Restore-SqliteNativeAssets {
    param([Parameter(Mandatory)][string]$AppDirectory)

    $info = Get-SqliteReleaseInfo -AppDirectory $AppDirectory
    $cacheDirectory = Join-Path $env:USERPROFILE ".simplemoney\native-assets\sqlite3-$($info.Version)"
    $buildDirectory = Join-Path $AppDirectory '.dart_tool\hooks_runner\shared\sqlite3\build'
    New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null

    $missing = @()
    foreach ($architecture in $script:SqliteAndroidArchitectures) {
        $name = "libsqlite3.$architecture.android.so"
        $hashMatch = [regex]::Match($info.Hashes, "'$([regex]::Escape($name))':\s*'(?<h>[0-9a-f]{64})'")
        if (-not $hashMatch.Success) { throw "No known hash for $name in sqlite3 $($info.Version)." }
        $hash = $hashMatch.Groups['h'].Value
        $cached = Join-Path $cacheDirectory $name

        $valid = (Test-Path -LiteralPath $cached) -and
            ((Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash.ToLowerInvariant() -eq $hash)
        if (-not $valid) {
            $url = "https://github.com/simolus3/sqlite3.dart/releases/download/$($info.Tag)/$name"
            Write-Host "Downloading $name ..."
            if (-not (Save-VerifiedDownload -Url $url -Destination $cached -Sha256 $hash)) {
                $missing += $name
                continue
            }
        }

        # The build hook looks for <build>\download-<first 8 hash chars>\libsqlite3.so
        # and skips the network when the file's hash already matches.
        $target = Join-Path $buildDirectory "download-$($hash.Substring(0, 8))"
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Remove-Item -LiteralPath (Join-Path $target 'libsqlite3.so.tmp') -Force -ErrorAction SilentlyContinue
        $installed = Join-Path $target 'libsqlite3.so'
        if (-not (Test-Path -LiteralPath $installed) -or
            ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash)) {
            Copy-Item -LiteralPath $cached -Destination $installed -Force
        }
    }
    if ($missing.Count) {
        throw ("Could not download: " + ($missing -join ', ') +
            ". Copy those files into $cacheDirectory from a machine with access to GitHub and run again.")
    }
    Write-Host "sqlite3 native libraries ready (offline cache: $cacheDirectory)."
}
