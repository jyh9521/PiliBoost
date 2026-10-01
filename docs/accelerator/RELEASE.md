# Android release preparation

Version: `0.1.4+6`. Release application ID: `com.jyh9521.piliboost`.
Debug remains `com.example.piliplus.debug`. Release and debug installs are
separate applications; neither automatically migrates the other's data.
Display name, source link and update API now belong to PiliBoost.

## Local build

Use the Flutter version pinned in `pubspec.yaml`, the existing dependency lock,
Java 17+ and Android SDK. Apply the original common SDK patches through
`tool/phase1/prepare_test_environment.ps1` on a dedicated build SDK.

Create a private Android signing keystore, keep an offline backup, then configure
ignored `android/key.properties` with `storeFile`, `storePassword`, `keyAlias`
and `keyPassword`. `storeFile` may be an absolute path. Never commit keys or
passwords; keep the same release key for future upgrades.

```powershell
& tool/phase1/build_android_release.ps1 -FlutterRoot $FlutterRoot -PythonPath $PythonPath
```

The script requires signing configuration, uses an Android-only plugin
registration fixture, embeds pubspec version/commit/build time without changing
the version file, and verifies generated registrant presence and ZIP CRC.
Output: `build/app/outputs/flutter-apk/app-release.apk` (universal Android APK).
Verify APK signature, certificate fingerprint, package/version and 16 KiB ZIP
alignment before distribution. The release variant does not use debug-key
fallback when release signing configuration is missing.

Existing upstream multi-platform Build workflows are retained as upstream
infrastructure, not the verified fork release pipeline. This local release
script is the currently validated Android path.

## Device acceptance and publication

Release-mode compilation/signing is not proof of sustained device playback.
Complete the unified same-content OFF/ON test, including high-bitrate playback,
seek/quality changes, background/PiP and network changes. Check diagnostics for
real observed concurrency, valid identities and fallback, not only a mode label.

After acceptance, create a version tag from the verified commit and publish a
GitHub Release in `jyh9521/PiliBoost` with APK, SHA256 and release notes. No stable
release/tag is created merely by running the local build. Never overwrite an
existing release's assets or signing identity silently.

## Upstream synchronization

Run the manual `Review upstream changes` workflow to obtain merge-base, upstream
commit and changed-file evidence. It only fetches/read-compares upstream main;
it does not merge, push a branch or publish a release.

Review on an ordinary descriptive branch, resolve fork settings, update source,
release identity and accelerator boundaries deliberately, and run all regression
tests before merging. Keep original author/license/NOTICE attribution.

```sh
git fetch upstream main
git switch -c maintenance/upstream-sync
git merge --no-commit --no-ff upstream/main
# Inspect changes, resolve conflicts, test, then commit; or git merge --abort.
```
