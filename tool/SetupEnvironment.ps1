[CmdletBinding()]
param(
    [switch]$SkipNodeDependencies,
    [switch]$SkipAndroidLicenses,
    [switch]$SkipWarmBuild
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$appDirectory = Join-Path $repositoryRoot 'app'
$androidSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
$androidStudio = Join-Path $env:ProgramFiles 'Android\Android Studio'
$javaHome = Join-Path $androidStudio 'jbr'
$flutterParent = Join-Path $env:USERPROFILE 'develop'
$flutterSdk = Join-Path $flutterParent 'flutter'
$flutter = Join-Path $flutterSdk 'bin\flutter.bat'

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'
}

function Add-UserPath([string]$Directory) {
    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts -notcontains $Directory) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $Directory) -join ';'), 'User')
    }
}

function Install-WingetPackage([string]$Id, [string]$Command) {
    Refresh-Path
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "$Command is already installed."
        return
    }

    Write-Step "Installing $Id with winget"
    $installed = $false
    foreach ($attempt in 1..3) {
        & winget.exe install --id $Id --exact --accept-package-agreements `
            --accept-source-agreements --silent --disable-interactivity
        if ($LASTEXITCODE -eq 0) {
            $installed = $true
            break
        }
        if ($attempt -lt 3) {
            Write-Warning "winget attempt $attempt for $Id failed; retrying in 5 seconds."
            Start-Sleep -Seconds 5
        }
    }
    if (-not $installed) { throw "winget could not install $Id after three attempts." }
    Refresh-Path
}

function Install-GitMirrorFallback {
    # Git for Windows publishes on GitHub. Some networks return 504 for GitHub's
    # release CDN even though package metadata is reachable, so use a public
    # university mirror of that exact signed release as a fallback.
    $version = '2.56.0.4'
    $expectedSha256 = '4961a4a8cc778d8b6e00a5819e5fe4d078b754555aff7aedc2d77a5d74c2de80'
    $mirror = "https://mirrors.lzu.edu.cn/github-release/git-for-windows/git/LatestRelease/Git-$version-64-bit.exe"
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("simplemoney-git-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        Write-Step 'Downloading the signed Git for Windows installer from the fallback mirror'
        $installer = Join-Path $temporaryDirectory 'Git-Setup.exe'
        & curl.exe --fail --location --retry 3 --output $installer $mirror
        if ($LASTEXITCODE -ne 0) { throw 'The Git fallback download failed.' }

        $actualSha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $expectedSha256) {
            throw "The Git installer checksum did not match. Expected $expectedSha256; got $actualSha256."
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid') {
            throw "The Git installer signature is not valid: $($signature.Status)."
        }

        $process = Start-Process -FilePath $installer -ArgumentList '/SP-', '/VERYSILENT', `
            '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "The Git installer failed (exit $($process.ExitCode))." }
        Refresh-Path
        if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
            throw 'Git installed, but git.exe was not found after refreshing PATH.'
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            try {
                [IO.Directory]::Delete("\\?\$temporaryDirectory", $true)
            } catch {
                Write-Warning "Could not remove temporary Git installer directory: $temporaryDirectory"
            }
        }
    }
}

function Install-AndroidCommandLineTools {
    $sdkManager = Join-Path $androidSdk 'cmdline-tools\latest\bin\sdkmanager.bat'
    $sdkManagerLibrary = Join-Path $androidSdk 'cmdline-tools\latest\lib\sdklib\libsdkmanager_lib.jar'
    if ((Test-Path -LiteralPath $sdkManager) -and (Test-Path -LiteralPath $sdkManagerLibrary)) { return }

    $package = 'commandlinetools-win-15859902_latest.zip'
    $expectedSha256 = '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
    $url = "https://dl.google.com/android/repository/$package"
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("simplemoney-android-tools-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        Write-Step 'Installing Android SDK command-line tools'
        $archive = Join-Path $temporaryDirectory $package
        & curl.exe --fail --location --retry 3 --connect-timeout 20 --output $archive $url
        if ($LASTEXITCODE -ne 0) { throw 'The Android command-line tools download failed.' }
        $actualSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $expectedSha256) {
            throw "The Android tools checksum did not match. Expected $expectedSha256; got $actualSha256."
        }

        $target = Join-Path $androidSdk 'cmdline-tools\latest'
        if (Test-Path -LiteralPath $target) {
            $resolvedAndroidSdk = [IO.Path]::GetFullPath($androidSdk).TrimEnd('\')
            $resolvedTarget = [IO.Path]::GetFullPath($target).TrimEnd('\')
            if (-not $resolvedTarget.StartsWith("$resolvedAndroidSdk\", [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to replace unexpected Android tools path: $resolvedTarget"
            }
            [IO.Directory]::Delete("\\?\$resolvedTarget", $true)
        }
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        & tar.exe -xf $archive -C $target --strip-components=1
        if ($LASTEXITCODE -ne 0) { throw 'The Android command-line tools extraction failed.' }
        if (-not ((Test-Path -LiteralPath $sdkManager) -and (Test-Path -LiteralPath $sdkManagerLibrary))) {
            throw 'sdkmanager.bat was not installed correctly.'
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            try {
                [IO.Directory]::Delete("\\?\$temporaryDirectory", $true)
            } catch {
                Write-Warning "Could not remove temporary Android tools directory: $temporaryDirectory"
            }
        }
    }
}

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    # App Installer is often present but its winget alias is not registered
    # for this user yet (fresh profile or after sign-in); registering fixes it.
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    } catch {
        Write-Warning "Could not register App Installer: $($_.Exception.Message)"
    }
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if (($env:Path -split ';') -notcontains $windowsApps) { $env:Path = "$env:Path;$windowsApps" }
}
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw 'winget is required. Install or update App Installer from Microsoft Store, then run this file again.'
}

try {
    Install-WingetPackage -Id 'Git.Git' -Command 'git.exe'
} catch {
    Write-Warning $_.Exception.Message
    Install-GitMirrorFallback
}
Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Command 'node.exe'

function Get-AndroidStudioRecords {
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Android Studio' })
}

function Resolve-AndroidStudioJava {
    # Prefer the default location, then wherever Windows says Studio lives.
    $candidates = @($androidStudio)
    $registered = Get-ItemProperty 'HKLM:\SOFTWARE\Android Studio' -ErrorAction SilentlyContinue
    if ($registered -and $registered.Path) { $candidates += $registered.Path }
    foreach ($record in Get-AndroidStudioRecords) {
        if ($record.UninstallString) { $candidates += [IO.Path]::GetDirectoryName($record.UninstallString.Trim('"')) }
    }
    # Plain string joins: Join-Path throws when a recorded drive no longer exists.
    foreach ($candidate in $candidates) {
        $jbr = [IO.Path]::Combine($candidate, 'jbr')
        if (Test-Path -LiteralPath ([IO.Path]::Combine($jbr, 'bin\java.exe'))) { return $jbr }
    }
    return $null
}

function Remove-StaleAndroidStudioRecords {
    # A drive that was removed or wiped can leave Windows believing Android
    # Studio is installed; winget then refuses to install it. Only records whose
    # uninstaller no longer exists are removed.
    $stale = @(Get-AndroidStudioRecords | Where-Object {
        $uninstaller = "$($_.UninstallString)".Trim('"')
        $uninstaller -and -not (Test-Path -LiteralPath $uninstaller)
    })
    if ($stale.Count -eq 0) { return }
    Write-Step 'Removing a leftover Android Studio install record (its files no longer exist)'
    $paths = @($stale | ForEach-Object { $_.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', 'Registry::' })
    $registered = Get-ItemProperty 'HKLM:\SOFTWARE\Android Studio' -ErrorAction SilentlyContinue
    if ($registered -and $registered.Path -and -not (Test-Path -LiteralPath $registered.Path)) {
        $paths += 'HKLM:\SOFTWARE\Android Studio'
    }
    $command = '$ErrorActionPreference="Stop"; foreach($p in @(' + (($paths | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + ')){ Remove-Item -LiteralPath $p -Recurse }'
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command
    if ($process.ExitCode -ne 0) { throw "Could not remove the leftover Android Studio record (exit $($process.ExitCode))." }
}

$existingJava = Resolve-AndroidStudioJava
if ($existingJava) {
    $javaHome = $existingJava
} else {
    Remove-StaleAndroidStudioRecords
    Write-Step 'Installing Android Studio with winget'
    & winget.exe install --id Google.AndroidStudio --exact --accept-package-agreements `
        --accept-source-agreements --silent --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "winget could not install Android Studio (exit $LASTEXITCODE)." }
    $javaHome = Resolve-AndroidStudioJava
    if (-not $javaHome) { throw 'Android Studio installed, but its bundled Java (jbr) was not found.' }
}

if (-not (Test-Path -LiteralPath $androidSdk)) {
    throw "Android SDK was not found at its default path: $androidSdk. Open Android Studio once, complete its Setup Wizard, and rerun this file."
}

Write-Step 'Configuring standard Android and Java environment variables'
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $androidSdk, 'User')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $androidSdk, 'User')
[Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome, 'User')
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
$env:JAVA_HOME = $javaHome
Add-UserPath (Join-Path $androidSdk 'platform-tools')
Add-UserPath (Join-Path $javaHome 'bin')

$pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }

Write-Step 'Excluding build folders from Windows Defender real-time scanning (faster builds)'
$exclusions = @($repositoryRoot, (Join-Path $env:USERPROFILE '.gradle'), $pubCache, $flutterSdk, $androidSdk,
    (Join-Path $env:USERPROFILE '.simplemoney'))
$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$exclusionCommand = '$ErrorActionPreference="Stop"; foreach($p in @(' + (($exclusions | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + ')){ Add-MpPreference -ExclusionPath $p }'
try {
    if ($isAdministrator) {
        Invoke-Expression $exclusionCommand
    } else {
        $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $exclusionCommand
        if ($process.ExitCode -ne 0) { throw "elevated command exited with $($process.ExitCode)" }
    }
} catch {
    Write-Warning "Could not add Defender exclusions ($($_.Exception.Message)). Builds still work, only slower."
}

if (-not (Test-Path -LiteralPath $flutter)) {
    Write-Step "Installing the latest stable Flutter SDK in $flutterSdk"
    if (Test-Path -LiteralPath $flutterSdk) {
        # A prior interrupted extraction can leave a partial SDK. This exact
        # directory is owned by this bootstrap and is safe to replace.
        $resolvedFlutterParent = [IO.Path]::GetFullPath($flutterParent).TrimEnd('\')
        $resolvedFlutterSdk = [IO.Path]::GetFullPath($flutterSdk).TrimEnd('\')
        if (-not $resolvedFlutterSdk.StartsWith("$resolvedFlutterParent\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to replace unexpected Flutter path: $resolvedFlutterSdk"
        }
        Remove-Item -LiteralPath $resolvedFlutterSdk -Recurse -Force
    }
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("simplemoney-flutter-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        $releaseIndexUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
        $releaseIndexFile = Join-Path $temporaryDirectory 'releases_windows.json'
        & curl.exe --fail --location --retry 3 --connect-timeout 20 --output $releaseIndexFile $releaseIndexUrl
        if ($LASTEXITCODE -ne 0) { throw 'The Flutter release index download failed.' }
        $releaseIndex = Get-Content -LiteralPath $releaseIndexFile -Raw | ConvertFrom-Json
        $stableHash = $releaseIndex.current_release.stable
        $release = $releaseIndex.releases | Where-Object { $_.hash -eq $stableHash } | Select-Object -First 1
        if (-not $release) { throw 'The current stable Flutter release could not be resolved.' }

        New-Item -ItemType Directory -Force -Path $flutterParent | Out-Null
        $archive = Join-Path $temporaryDirectory 'flutter.zip'
        $archiveUrl = "https://storage.googleapis.com/flutter_infra_release/releases/$($release.archive)"
        & curl.exe --fail --location --retry 3 --connect-timeout 20 --output $archive $archiveUrl
        if ($LASTEXITCODE -ne 0) { throw 'The Flutter SDK archive download failed.' }
        # tar handles duplicate ZIP entries present in newer Flutter archives;
        # Expand-Archive aborts when it encounters those entries.
        & tar.exe -xf $archive -C $flutterParent
        if ($LASTEXITCODE -ne 0) { throw 'The Flutter SDK archive extraction failed.' }
    } finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

Add-UserPath (Join-Path $flutterSdk 'bin')
Refresh-Path
$env:ANDROID_HOME = $androidSdk
$env:ANDROID_SDK_ROOT = $androidSdk
$env:JAVA_HOME = $javaHome

Write-Step 'Configuring Flutter'
& $flutter config --android-sdk $androidSdk
if ($LASTEXITCODE -ne 0) { throw 'Flutter Android SDK configuration failed.' }
& $flutter config --no-enable-web --no-enable-windows-desktop
if ($LASTEXITCODE -ne 0) { throw 'Flutter platform configuration failed.' }

Install-AndroidCommandLineTools

if (-not $SkipAndroidLicenses) {
    Write-Step 'Accepting Android SDK licenses'
    1..30 | ForEach-Object { 'y' } | & $flutter doctor --android-licenses
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Android licenses were not fully accepted. Run: flutter doctor --android-licenses'
    }
}

if (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git')) {
    Write-Step 'Restoring Git submodules'
    & git.exe -C $repositoryRoot submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw 'Git submodule restore failed.' }
}

Write-Step 'Restoring SMS parser development dependencies'
Push-Location (Join-Path $appDirectory 'packages\universal_bank_sms_parser\engines\dart')
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'SMS parser pub get failed.' }
} finally {
    Pop-Location
}

Write-Step 'Restoring Flutter and Dart packages'
Push-Location $appDirectory
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
} finally {
    Pop-Location
}

Write-Step 'Installing Android SDK platforms required by plugins'
$sdkManagerBat = Join-Path $androidSdk 'cmdline-tools\latest\bin\sdkmanager.bat'
foreach ($platform in @('platforms;android-35', 'platforms;android-36')) {
    $platformDirectory = Join-Path $androidSdk ('platforms\' + $platform.Split(';')[1])
    if (Test-Path -LiteralPath (Join-Path $platformDirectory 'package.xml')) { continue }
    & $sdkManagerBat --sdk_root=$androidSdk $platform
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not install $platform; install it from Android Studio's SDK Manager." }
}

Write-Step 'Caching native libraries and Flutter engine artifacts for offline builds'
. (Join-Path $PSScriptRoot 'OfflineNativeAssets.ps1')
Restore-SqliteNativeAssets -AppDirectory $appDirectory
& $flutter precache --android
if ($LASTEXITCODE -ne 0) { Write-Warning 'flutter precache --android failed; offline builds may need the network once.' }

if (-not $SkipWarmBuild) {
    # Flutter raises its minimum Android Gradle Plugin (AGP) over time and fails
    # the build when settings.gradle.kts is older. Move to the newest stable AGP
    # from Google Maven (skips alpha/beta/rc). Offline: keep the current version.
    Write-Step 'Checking the latest stable Android Gradle Plugin'
    $settingsFile = Join-Path $appDirectory 'android\settings.gradle.kts'
    try {
        $metadata = [xml](Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 `
            'https://dl.google.com/android/maven2/com/android/tools/build/gradle/maven-metadata.xml').Content
        # Newer AGP than the installed Flutter knows can break plugin builds
        # (e.g. AGP 9.5 rejects build types Flutter copies into plugins), so
        # stay within the newest AGP line this Flutter SDK declares as known.
        $agpCap = $null
        $gradleUtils = Join-Path $flutterSdk 'packages\flutter_tools\lib\src\android\gradle_utils.dart'
        if ((Test-Path -LiteralPath $gradleUtils) -and
            ((Get-Content -LiteralPath $gradleUtils -Raw) -match "maxKnownAgpVersion\s*=\s*'(\d+)\.(\d+)")) {
            $agpCap = [version]"$($Matches[1]).$($Matches[2])"
        }
        $latestAgp = $metadata.metadata.versioning.versions.version |
            Where-Object { $_ -match '^\d+\.\d+\.\d+$' } |
            Where-Object { -not $agpCap -or ([version]$_ -lt [version]"$($agpCap.Major).$($agpCap.Minor + 1).0") } |
            Sort-Object { [version]$_ } | Select-Object -Last 1
        $settingsText = Get-Content -LiteralPath $settingsFile -Raw
        $pattern = '(id\("com\.android\.application"\)\s+version\s+")(\d+\.\d+\.\d+)(")'
        if ($latestAgp -and $settingsText -match $pattern) {
            $currentAgp = $Matches[2]
            if ([version]$latestAgp -ne [version]$currentAgp) {
                [regex]::Replace($settingsText, $pattern, "`${1}$latestAgp`${3}") |
                    Set-Content -LiteralPath $settingsFile -NoNewline
                Write-Host "Android Gradle Plugin: $currentAgp -> $latestAgp"
            } else {
                Write-Host "Android Gradle Plugin $currentAgp is already the latest stable."
            }
        }
    } catch {
        Write-Warning "Could not check the latest Android Gradle Plugin: $($_.Exception.Message)"
    }

    # flutter build runs the Gradle wrapper quietly, so a first-time download of
    # Gradle itself looks like a frozen spinner. Fetch it here with progress.
    # gradlew / gradle-wrapper.jar are git-ignored and generated by Flutter, so
    # a fresh clone does not have them until the first build. Skip the early
    # download in that case; the warm build below creates the wrapper.
    $androidDirectory = Join-Path $appDirectory 'android'
    if (Test-Path (Join-Path $androidDirectory 'gradlew.bat')) {
        Write-Step 'Downloading Gradle (one time)'
        Push-Location $androidDirectory
        try {
            & .\gradlew.bat --version
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Gradle download failed; the build below will retry it.' }
        } finally {
            Pop-Location
        }
    } else {
        Write-Host 'Gradle wrapper not generated yet; the build below will create it and download Gradle.'
    }

    Write-Step 'Warming the Gradle cache with a release build (first run downloads ~1 GB; can take 10-30 minutes)'
    Push-Location $appDirectory
    try {
        & $flutter build apk --release
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Warm-up build failed; fix the error above, then run setup again.' }
    } finally {
        Pop-Location
    }
}

if (-not $SkipNodeDependencies) {
    foreach ($nodeProject in @('relay', 'community')) {
        $nodeDirectory = Join-Path $repositoryRoot $nodeProject
        if (Test-Path -LiteralPath (Join-Path $nodeDirectory 'package-lock.json')) {
            Write-Step "Restoring Node packages for $nodeProject"
            Push-Location $nodeDirectory
            try {
                & npm.cmd ci
                if ($LASTEXITCODE -ne 0) { throw "npm ci failed in $nodeProject." }
            } finally {
                Pop-Location
            }
        }
    }
}

Write-Step 'Checking the toolchain'
& $flutter doctor
if ($LASTEXITCODE -ne 0) { Write-Warning 'Flutter doctor reported an incomplete optional component; review the output above.' }

Write-Host "`nFlutter: $flutterSdk"
Write-Host "Dart:    $(Join-Path $flutterSdk 'bin\cache\dart-sdk')"
Write-Host "Android: $androidSdk"
Write-Host "Java:    $javaHome"
Write-Host "Project: $appDirectory"
