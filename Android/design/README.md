# Cydia interface

Open `cydia-preview.html` in a browser to review the interface mockup, including categories, search, package details, the file tab and both themes. It is a visual prototype with example catalog entries; actual transfers are available in the Android application.

The Android interface uses real APT sources and package indexes. Its Cydia, Sources, Changes, Installed and Search tabs support repository management, package details, available updates and the guest's actual dpkg status. The browser mockup remains an older design reference.

**Import .deb**, **Install from URL** and repository package installation automatically install into the running jailbroken iOS guest. Dependencies are resolved against installed packages and source indexes, downloaded and installed before the target package. Files remain in `/var/mobile/Media/Un1box/Packages/`; temporary Android copies are removed after the attempt. Package Files also supports installing previously saved packages directly, using dpkg's normal dependency checks.

Downloads accept HTTP or HTTPS, including legacy Cydia repositories. HTTPS redirects cannot downgrade to HTTP. Repository downloads verify the advertised size and hash when supplied. Debian control metadata validates package identity, architecture and firmware dependencies; publisher signatures are not verified. Sources support flat indexes and distribution/component indexes compressed with gzip, bzip2 or xz. A stopped guest disables installation. Uploads finish in a hidden temporary file; the helper checks the remote size and renames it after every byte has arrived.

FirmwareKit installs a root launchd worker and queue. The native helper uses AFC2 to validate the worker, submit an atomic request and read its result. The worker runs `dpkg --force-confold -i`, preserves dpkg's dependency checks and refreshes the icon cache. The interface reports success only after the worker finishes and the target appears in installed dpkg status. The stopped editor accepts updating an existing jailbreak, but Android library records currently use a different storage layout and cannot run that editor. Prepare the Android guest with jailbreak enabled in this build to include the worker.

The native guest helper must be rebuilt from this branch with `Android/packaging/build-mobile-android.py`. The perf APK workflow builds and caches this helper; reusing the base APK's old `liblt_appservice.so` does not support transfers.

Jailbroken firmware preparation also requires **FirmwareKit rebuilt from this branch**. The base release's `/usr/bin/tar` does not exist on Android. Current source selects `/system/bin/tar`, drains verbose skipped-file reports without blocking, and parses toybox's link listings. The APK workflow requires that build and validates Cydia extraction with both GNU tar and toybox instead of falling back to the release binary.

Validation:

- `:app:assembleDebug`
- `:app:testDebugUnitTest`
- `sh Android/native-services/tests/run.sh` on Linux with libimobiledevice and libplist development headers
- `swift test --package-path Packages/FirmwareKit --filter 'CydiaInstallTests|DebInstallerTests'` with GNU tar and with `LT_TAR` pointing to toybox via a `tar` symlink

The native tests mock AFC responses and exercise short writes, incomplete copies, rename failures, full storage, unique filenames, installer probing, queue submission and status reads.

Live checks on Android 14 and 15 completed all eight preparation steps for an iPhone 3GS running iOS 5.1.1, refreshed three sources with 10,299 distinct packages and installed iFile 2.2.0-1 with six dependencies, confirmed by dpkg status. Local document-picker import passed on the first phone. On the second phone, opening the picker paused iOS and cleared the UI's socket; the import callback now resumes the worker and reads its current socket. This final fix builds and passes the Android tests, but has not yet been retested on a phone.

iFile's launch/resume watchdog stall (`0x8badf00d`) on the first phone remains unresolved; successful package installation does not establish that every guest application runs correctly.
