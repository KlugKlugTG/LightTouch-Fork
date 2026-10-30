#!/usr/bin/env python3
"""Stage firmwarekit's notices for an app that ships it (the Android APK's assets/licenses/firmwarekit).

    stage-notices.py OUT --checkouts DIR --swift-license FILE --source-reference URL

OUT gets each linked dependency's licence and notice files as <package>-<file>, the Swift runtime's licence, a
NOTICE.txt naming what the Swift SDK's static Foundation brings in, and manifest.json in the schema the app's
licence screen reads ({"schema": 1, "source_reference", "files": [{"path", "sha256"}]}).
"""
import argparse, hashlib, json, shutil
from pathlib import Path

# What firmwarekit links off the Mac (MachOKit and its own dependencies are macOS-only), with the files that carry
# each package's terms.
LINKED = {
    "ZIPFoundation": ["LICENSE"],
    "swift-subprocess": ["LICENSE"],
    "Unrar.swift": ["LICENSE.txt", "Sources/Cunrar/license.txt"],
    "swift-argument-parser": ["LICENSE.txt"],
    "swift-crypto": ["LICENSE.txt", "NOTICE.txt"],
    "swift-asn1": ["LICENSE.txt", "NOTICE.txt"],
    "swift-system": ["LICENSE.txt"],
}

NOTICE = """firmwarekit (Packages/FirmwareKit in LightTouch's source) prepares an emulated device from an IPSW.
It is built with the Swift SDK for Android and links, statically:

- the Swift runtime and Foundation (Apache-2.0 with Runtime Library Exception: swift-LICENSE.txt), and through
  FoundationNetworking and FoundationInternationalization: curl (curl licence, https://curl.se/docs/copyright.html),
  OpenSSL (Apache-2.0, https://www.openssl.org/source/license.html), libxml2 (MIT,
  https://gitlab.gnome.org/GNOME/libxml2/-/blob/master/Copyright) and ICU (Unicode licence,
  https://github.com/unicode-org/icu/blob/main/LICENSE);
- the Android NDK's libc++ (Apache-2.0 with LLVM exceptions);
- the Swift packages whose licences follow, as <package>-<file>. swift-crypto carries BoringSSL (its NOTICE.txt).
"""


NOTICE_IBOOT = """
Beside firmwarekit, the package ships iBoot32Patcher (iBoot32Patcher-LICENSE, GPL-3.0-or-later,
https://github.com/LukeZGD/iBoot32Patcher), which firmwarekit runs as a separate process when preparing
the iPad 1st gen (k48ap) iBoot chain.
"""


def main():
    a = argparse.ArgumentParser()
    a.add_argument("out", type=Path)
    a.add_argument("--checkouts", type=Path, required=True)
    a.add_argument("--swift-license", type=Path, required=True)
    a.add_argument("--iboot32patcher-license", type=Path)
    a.add_argument("--source-reference", required=True)
    args = a.parse_args()
    if args.out.exists():
        shutil.rmtree(args.out)
    args.out.mkdir(parents=True)
    notice = NOTICE + (NOTICE_IBOOT if args.iboot32patcher_license is not None else "")
    staged = {"NOTICE.txt": notice.encode()}
    staged["swift-LICENSE.txt"] = args.swift_license.read_bytes()
    if args.iboot32patcher_license is not None:
        if not args.iboot32patcher_license.is_file():
            raise SystemExit(f"stage-notices: missing {args.iboot32patcher_license}")
        staged["iBoot32Patcher-LICENSE"] = args.iboot32patcher_license.read_bytes()
    for package, names in LINKED.items():
        for name in names:
            source = args.checkouts / package / name
            if not source.is_file():
                raise SystemExit(f"stage-notices: missing {source}")
            staged[f"{package}-{name.replace('/', '-')}"] = source.read_bytes()
    files = []
    for path, data in sorted(staged.items()):
        (args.out / path).write_bytes(data)
        files.append({"path": path, "sha256": hashlib.sha256(data).hexdigest()})
    manifest = {"schema": 1, "source_reference": args.source_reference, "files": files}
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
