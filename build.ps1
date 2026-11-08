$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$app = Join-Path $root 'app'
$Target = if ($args.Count -gt 0) { $args[0] } else { '' }

. (Join-Path $app 'tool/android_production_build.ps1')

switch ($Target) {
    'app:play' {
        if ($args.Count -ne 1 -and ($args.Count -ne 3 -or $args[1] -ne '--')) {
            throw 'Usage: build app:play [-- <major.minor.patch>]'
        }

        $pubspecPath = Join-Path $app 'pubspec.yaml'
        $pubspec = [System.IO.File]::ReadAllText($pubspecPath)
        $versionMatch = [regex]::Match($pubspec, '(?m)^version:[ \t]*(?<full>(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)\+(?<code>\d+))[ \t]*\r?$')
        if (-not $versionMatch.Success) { throw 'Expected pubspec.yaml version in major.minor.patch+buildCode format' }

        $major = [int]$versionMatch.Groups['major'].Value
        $minor = [int]$versionMatch.Groups['minor'].Value
        $patch = [int]$versionMatch.Groups['patch'].Value
        $buildCode = [int]$versionMatch.Groups['code'].Value
        if ($args.Count -eq 3) {
            $versionName = $args[2]
            if ($versionName -cnotmatch '^\d+\.\d+\.\d+$') {
                throw 'Explicit version must be major.minor.patch, for example 0.60.3'
            }
            $parts = $versionName.Split('.') | ForEach-Object { [int]$_ }
            if ($parts[0] -lt $major -or
                ($parts[0] -eq $major -and $parts[1] -lt $minor) -or
                ($parts[0] -eq $major -and $parts[1] -eq $minor -and $parts[2] -le $patch)) {
                throw "Explicit version must be greater than $major.$minor.$patch"
            }
        } else {
            $versionName = "$major.$minor.$($patch + 1)"
        }
        $nextCode = $buildCode + 1
        $version = "$versionName+$nextCode"
        $productionArguments = @(Get-AndroidProductionBuildArguments -AppDirectory $app -Version $version)
        $flutterPath = Get-AndroidFlutterExecutable -AppDirectory $app

        Push-Location $app
        try {
            & $flutterPath build appbundle @productionArguments
            if ($LASTEXITCODE -ne 0) { throw "flutter build failed ($LASTEXITCODE)" }
        } finally { Pop-Location }

        $out = Join-Path $root 'apkOut\play'
        New-Item -ItemType Directory -Force $out | Out-Null
        $src = Join-Path $app 'build\app\outputs\bundle\release\app-release.aab'
        $dest = Join-Path $out ("simple-money-$version.aab")
        Copy-Item $src $dest -Force
        $fullVersion = $versionMatch.Groups['full']
        $updatedPubspec = $pubspec.Substring(0, $fullVersion.Index) + $version + $pubspec.Substring($fullVersion.Index + $fullVersion.Length)
        [System.IO.File]::WriteAllText($pubspecPath, $updatedPubspec, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Play bundle: $dest"
    }
    default {
        Write-Host 'Usage: build <target>'
        Write-Host '  app:play [-- 0.60.3]   bump version and build release .aab -> apkOut\play\simple-money-<version>.aab'
        if ($Target -ne '') { exit 1 }
    }
}
