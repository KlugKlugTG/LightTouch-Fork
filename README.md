# Un1box emulator 
<p align="center"><img src="./Picsart_26-10-25_03-23-04-384.jpg" alt="Senses" width="700"></p>

Un1box emulator runs classic iPhone OS and iOS in an emulator on **Android, Linux, Windows and macOS**. It is a fork of [Light Touch for Mac](https://github.com/samhenrigold/LightTouchMac), built around a shared [qemu-ios engine](https://github.com/blake-lucas/qemu-ios).

The desktop ports share one device library and setup UI. Android has its own touch UI. A prepared iOS system can back several saved devices, each with its own storage.

here are our communities

Discord server:
https://discord.gg/ZpEkAV47H9
Our Telegram channel:
https://t.me/hyperhle

[Download the latest build](https://github.com/KlugKlugTG/Un1box/releases) (CI builds every commit; the plain LightTouch release is on [upstream](https://github.com/blake-lucas/LightTouch/releases/latest), v0.0.11). Un1box is still early and things can change between versions. Android is the most complete: it sets up devices on the phone from start to finish. The Linux, Windows and macOS versions work but take more setup, since most of the work has gone into Android first.

## Current platforms

| Platform | Build | Status |
| --- | --- | --- |
| Android | APK, ARM64 (Android 10+) | The main test platform, on a Poco F3 and a Pixel 10. First launch walks you through preparing a device from an IPSW on the phone. Graphics, audio, touch, tilt and IPA installs work, and the Legacy Store can be browsed like the website, with several installs queued in the background. |
| Linux | x86_64 AppImage | Boot, input, accelerated graphics, audio, the Legacy Store and IPA installs work. Prepares devices with `firmwarekit` from the command line. |
| Windows | x86_64 ZIP | Boot, graphics, audio and Legacy Store installs confirmed by users. Cannot prepare devices yet: copy a prepared `.itbase` from another computer. |
| macOS | Apple Silicon app ZIP | The shared desktop UI builds and packages. Guest services are not yet fully checked. Needs macOS 26. Upstream's [Light Touch for Mac](https://github.com/samhenrigold/LightTouchMac/releases) is the tested Mac app. |

## Devices

| Device | iOS | Status |
| --- | --- | --- |
| iPod touch 2G | 3.1.3 | **Tested**: the main target, fastest. Games such as Flight Control and Jetpack Joyride run at or near 60 fps on recent phones. |
| iPod touch 2G | 4.2.1 | **Tested** |
| iPod touch 3G | 4.2.1 | **Tested** |
| iPod touch 4G | 6.1.6 | **Tested**: on a Pixel 10, Infinity Blade and Infinity Blade II run at full speed and Epic Citadel at 60 fps. Most other games, such as Jetpack Joyride, Doodle Jump and Real Racing, run at or near 60 fps on recent phones. |
| iPhone 3GS | 5.1.1 | **Tested, slow** |
| iPhone 4 | 4.2.1, 4.3.5 | **Tested, slow** |
| Others in the [firmware catalog](Portable/firmware/firmware-catalog.json) | iPhone OS 1 to iOS 7 | Can be prepared and tried; not yet checked on Un1box emulator . [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) records what has been run. |

## Getting started

**On Android**, install the APK and tap **Get started**. Pick a device and iOS version, and the app downloads iOS and prepares it on the phone (the iPod touch 2G on iOS 3.1.3 takes about a minute). You don't need any files of your own. If you already have device files made elsewhere, tap **I already have the device files**.

**On Linux, Windows and macOS**, unpack the build, then get an iOS system for it. The [asset guide](docs/ASSETS.md) covers both routes:

- **Prepare one from Apple's IPSW** with `firmwarekit` on Linux or macOS. Every platform uses the same preparer ([Portable/firmware](Portable/firmware/README.md)).
- **Use an already prepared system** (`.itbase`), for example the one `tools/get-assets.py` takes from upstream's Mac app, along with its guest tools (`armv6.itpack` or `armv7.itpack`) and, for the iPod touch 2G, its boot ROM.

- **Jailbroken, with Cydia.** Turn on **Cydia (jailbreak)** in *Prepare from an IPSW* on Android, or pass
  `--jailbreak` to `firmwarekit create`: the preparation leaves afc2 (the whole file system over USB) and what
  Legacy iOS Kit's jailbroken restores carry — Cydia 1.1.30 with apt and dpkg, Substrate on iOS 3 to 6 and Cydia
  HTTPatch on 3.x — from archives pinned by commit and SHA-1. iPhone OS 2.0 and later. On a phone the app downloads
  them itself, so the preparation needs no network.

  A device that is already prepared can be jailbroken in place instead, keeping its apps and data: **Settings ›
  Device › Jailbreak with Cydia** on Android runs `firmwarekit edit --device … --action jailbreak`, the same edits
  through a stopped edit (the device must not be running). On macOS, **Device › Jailbreak…** does the same. Erase
  returns to the jailbroken state, so the edit can't be undone.

Then start the device. Use the on-screen Home, Power and volume buttons, and **Stop** to shut iOS down cleanly. Each device keeps its own storage, and the prepared system is never changed.

## Performance

Guests run through QEMU's TCG dynamic translation; there is no hardware virtualization of the guest CPU. Much of this fork's engine work is speed: cross-page chaining, indirect-branch caches, fewer big-lock waits, and a faster OpenGL ES path. The history and measurements are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md). On Android the vCPU is kept on the phone's fast cores. The performance overlay shows host-side engine load and memory, not CPU use inside iOS.

## Building and contributing

`scripts/build.sh` builds the engine, the Linux frontend, the Android APK, `firmwarekit` and (on a Mac, over ssh) the guest tools; `scripts/build-release.sh` builds a release for all four platforms. Windows and macOS app builds run through `Desktop/build.py` on their own hosts. [docs/BUILDING.md](docs/BUILDING.md) covers the inputs, and [CONTRIBUTING.md](CONTRIBUTING.md) the repository layout, firmware preparation, tests and style. Development happens on `dev/*` branches of this repository and the engine; releases come from `main`.

## License and credits

Un1box emulator  is free software under GPL version 2 or, at your option, any later
version; see [LICENSE](LICENSE). Upstream authorship and licenses are retained.

It builds on [LightTouchMac](https://github.com/samhenrigold/LightTouchMac),
[qemu-ios](https://github.com/samhenrigold/qemu-ios),
[QEMU](https://www.qemu.org),
[devos50's qemu-ios](https://github.com/devos50/qemu-ios),
[libimobiledevice](https://libimobiledevice.org), libusbmuxd, libplist, libtatsu,
the upstream usbmuxd fork, iBoot32Patcher, FFmpeg, GLib, libslirp, PCRE2, pixman,
OpenSSL, Swift and its Foundation, swift-crypto, ZIPFoundation and Unrar.swift with RARLAB's UnRAR. Preserve each package's bundled
license and source notices.

iPhone, iPod touch and iPad are trademarks of Apple Inc. LightTouch is not
affiliated with Apple.
