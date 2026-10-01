param(
    [Parameter(Mandatory=$true)][string]$FlutterRoot,
    [Parameter(Mandatory=$true)][string]$PythonPath,
    [string]$AndroidSdkRoot = (Join-Path $env:LOCALAPPDATA 'Android/sdk')
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
if (!(Test-Path -LiteralPath (Join-Path $repo 'android/key.properties'))) { throw 'Release signing configuration required.' }
# Android-only registration fixture avoids Windows desktop symlink privileges.
# Neither source platforms nor OS Developer Mode are removed/changed.
$stage = Join-Path ([IO.Path]::GetTempPath()) ('piliboost-registration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
foreach ($name in @('pubspec.yaml','pubspec.lock')) {
    Copy-Item -LiteralPath (Join-Path $repo $name) -Destination $stage
}
New-Item -ItemType Directory -Path "$stage/android/app/src/main" -Force | Out-Null
Copy-Item -LiteralPath "$repo/android/app/src/main/AndroidManifest.xml" -Destination "$stage/android/app/src/main"
Push-Location $stage
try {
    & $flutter pub get --offline
    if ($LASTEXITCODE -ne 0) { throw 'Android-only pub get did not complete.' }
} finally { Pop-Location }
$generated = "$stage/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
if (!(Test-Path -LiteralPath $generated)) { throw 'Flutter did not generate Android plugin registration.' }
$target = "$repo/android/app/src/main/java/io/flutter/plugins"
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -LiteralPath $generated -Destination "$target/GeneratedPluginRegistrant.java"
Push-Location $repo
try {
    $versionLine = Get-Content (Join-Path $repo 'pubspec.yaml') | Where-Object { $_ -match '^version:' }
    if ($versionLine -notmatch '^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)$') { throw 'Invalid release version.' }
    $versionName = $Matches[1]
    $versionCode = [int]$Matches[2]
    $defines = Join-Path $repo 'build/pili_release.json'
    New-Item -ItemType Directory -Path (Split-Path $defines) -Force | Out-Null
    @{'pili.name'=$versionName; 'pili.code'=$versionCode; 'pili.hash'=(git rev-parse HEAD).Trim(); 'pili.time'=[int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()} | ConvertTo-Json -Compress | Set-Content -LiteralPath $defines -Encoding utf8
    & $flutter build apk --release --no-pub --dart-define-from-file=$defines
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
    & $PythonPath "$repo/tool/phase1/verify_android_apk.py" "$repo/build/app/outputs/flutter-apk/app-release.apk"
    if ($LASTEXITCODE -ne 0) { throw 'APK registration validation failed; do not distribute this APK.' }
    $apk = Join-Path $repo 'build/app/outputs/flutter-apk/app-release.apk'
    $tools = Join-Path $AndroidSdkRoot 'build-tools/37.0.0'
    $cert = & (Join-Path $tools 'apksigner.bat') verify --verbose --print-certs $apk
    if ($LASTEXITCODE -ne 0 -or ($cert -join "`n") -match 'CN=Android Debug') { throw 'Dedicated release signature validation failed.' }
    $cert | Write-Output
    & (Join-Path $tools 'zipalign.exe') -c -P 16 4 $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK alignment validation failed.' }
    $badging = & (Join-Path $tools 'aapt.exe') dump badging $apk
    if ($LASTEXITCODE -ne 0 -or ($badging -join "`n") -notmatch "package: name='com.jyh9521.piliboost' versionCode='$versionCode' versionName='$versionName'") { throw 'Release package/version validation failed.' }
    if (($badging -join "`n") -match 'application-debuggable') { throw 'Release APK must not be debuggable.' }
    Write-Output "RELEASE_IDENTITY PASS com.jyh9521.piliboost $versionName+$versionCode; non-debuggable; dedicated signing; alignment verified"
} finally { Pop-Location }
Write-Output 'ANDROID_RELEASE_BUILD PASS complete registration and APK validation'
Write-Output "Registration fixture retained: $stage"
