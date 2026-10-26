#!/usr/bin/env python3
"""Check all APK native entries: packaging, ELF PT_LOAD 16KiB alignment and packaged ANGLE identities."""
import argparse
import hashlib
import json
import re
import struct
import zipfile

ANGLE_NAMES = {"libEGL_lighttouch_angle.so", "libGLESv1_CM_lighttouch_angle.so", "libGLESv2_lighttouch_angle.so"}
ANGLE_ABIS = {"arm64-v8a": 183, "x86_64": 62}
ANGLE_PLATFORM = {"libc.so", "libdl.so", "libm.so", "liblog.so", "libnativewindow.so"}


def check_angle_runtime(archive):
    names = archive.namelist()
    assert len(names) == len(set(names)), "Duplicate APK ZIP entry"
    present = {}
    for name in names:
        parts = name.split("/")
        if name.startswith("lib/") and any(parts[-1].startswith(fixed[:-3]) for fixed in ANGLE_NAMES):
            assert parts[-1] in ANGLE_NAMES, "Unexpected provider library name"
        if name.startswith("lib/") and parts[-1] in ANGLE_NAMES:
            assert len(parts) == 3 and parts[1] in ANGLE_ABIS, "Unexpected provider ABI/path"
            present.setdefault(parts[1], set()).add(parts[2])
    expected_metadata = set()
    expected_notice_groups = set()
    expected_notice_paths = set()
    for abi, libraries in present.items():
        assert libraries == ANGLE_NAMES, f"Partial packaged ANGLE provider: {abi}"
        metadata = "angle-runtime.json" if abi == "x86_64" else "angle-runtime-arm64-v8a.json"
        group = "angle" if abi == "x86_64" else "angle-arm64-v8a"
        metadata_path = "assets/providers/" + metadata
        expected_metadata.add(metadata_path)
        expected_notice_groups.add(group)
        provider = json.loads(archive.read(metadata_path))
        assert provider["schema"] == 1 and provider["abi"] == abi, "Mixed provider ABI metadata"
        assert provider.get("notice_group", group) == group, "Provider notice collision"
        assert set(provider["libraries"]) == ANGLE_NAMES
        prefix = "assets/licenses/" + group + "/"
        raw_notice = archive.read(prefix + "manifest.json")
        notice = json.loads(raw_notice)
        assert notice["schema"] == 1 and notice.get("abi", abi) == abi
        assert set(notice["libraries"]) == ANGLE_NAMES
        assert provider["source_reference"] == notice["source_reference"] and provider["source_revision"] == notice["source_revision"], "Mixed provider source metadata"
        if abi == "arm64-v8a":
            assert provider.get("notice_group") == group
            assert re.fullmatch(r"[0-9a-f]{64}", provider.get("closure_manifest_sha256", ""))
            assert re.fullmatch(r"[0-9a-f]{64}", provider.get("notice_manifest_sha256", ""))
        if "notice_manifest_sha256" in provider:
            assert hashlib.sha256(raw_notice).hexdigest() == provider["notice_manifest_sha256"]
        for name, record in provider["libraries"].items():
            data = archive.read(f"lib/{abi}/{name}")
            assert len(data) >= 64 and data[:7] == b"\x7fELF\x02\x01\x01"
            assert struct.unpack_from("<HH", data, 16) == (3, ANGLE_ABIS[abi]), "Cross-ABI provider ELF"
            assert hashlib.sha256(data).hexdigest() == record["sha256"] == notice["libraries"][name], "Provider identity changed"
            assert record["soname"] == name and set(record["needed"]) <= ANGLE_NAMES | ANGLE_PLATFORM
        declared = {prefix + "manifest.json"}
        for record in notice["files"]:
            name = record["path"]
            assert all(part not in ("", ".", "..") and re.fullmatch(r"[A-Za-z0-9._-]+", part) for part in name.split("/")), "Invalid provider notice path"
            path = prefix + name
            assert path not in declared, "Duplicate provider notice"
            declared.add(path)
            assert hashlib.sha256(archive.read(path)).hexdigest() == record["sha256"]
        assert {name for name in names if name.startswith(prefix) and not name.endswith("/")} == declared, "Undeclared provider notice input"
        expected_notice_paths.update(declared)
    assert {name for name in names if name.startswith("assets/providers/angle-runtime")} == expected_metadata, "Undeclared provider metadata"
    actual_notice_groups = {name.split("/")[2] for name in names if name.startswith("assets/licenses/angle")}
    assert actual_notice_groups == expected_notice_groups, "Undeclared provider notice group"
    assert {name for name in names if name.startswith("assets/licenses/angle") and not name.endswith("/")} == expected_notice_paths, "Unexpected provider notice file"
    if present:
        print("Verified closed ABI ANGLE packaged identities/notices; actual app-UID provider remains separate")
    return set(present)


def check_apk(path, legacy_packaging=False):
    count = 0
    compressed = []
    with zipfile.ZipFile(path) as archive:
        with open(path, "rb") as apk:
            for entry in archive.infolist():
                if not entry.filename.startswith("lib/") or not entry.filename.endswith(".so"):
                    continue
                count += 1
                if entry.compress_type == zipfile.ZIP_STORED:
                    # Stored entries are mapped straight out of the APK, so the entry
                    # itself must start on a 16KiB boundary.
                    apk.seek(entry.header_offset)
                    local = apk.read(30)
                    name_length, extra_length = struct.unpack_from("<HH", local, 26)
                    offset = entry.header_offset + 30 + name_length + extra_length
                    assert offset % 16384 == 0, f"Unaligned APK entry {entry.filename}: {offset}"
                else:
                    # useLegacyPackaging: the installer extracts these to
                    # nativeLibraryDir, so entry offsets and alignment inside the
                    # archive carry no meaning. The ELF contract below still does.
                    assert legacy_packaging, f"Compressed {entry.filename}"
                    compressed.append(entry.filename)
                data = archive.read(entry)
                assert data[:6] == b"\x7fELF\x02\x01", f"Expected little-endian ELF64: {entry.filename}"
                phoff = struct.unpack_from("<Q", data, 32)[0]
                phsize, phnum = struct.unpack_from("<HH", data, 54)
                for i in range(phnum):
                    position = phoff + i * phsize
                    kind = struct.unpack_from("<I", data, position)[0]
                    if kind == 1:
                        file_offset, virtual = struct.unpack_from("<QQ", data, position + 8)
                        alignment = struct.unpack_from("<Q", data, position + 48)[0]
                        assert alignment >= 16384, f"4KiB ELF LOAD in {entry.filename}: {alignment}"
                        assert (virtual - file_offset) % 16384 == 0, f"Unaligned ELF LOAD: {entry.filename}"
                packaging = "compressed, legacy" if entry.compress_type != zipfile.ZIP_STORED else "uncompressed, APK/ELF"
                print(entry.filename, f"{packaging} aligned 16KiB")
        check_angle_runtime(archive)
    assert count, "APK has no native libraries"
    print(f"Checked {count} shared libraries; runtime/device acceptance still required")
    if compressed:
        assert legacy_packaging, "Compressed native libraries without legacy packaging"
        print(f"{len(compressed)} of {count} are compressed and extracted on install (useLegacyPackaging)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("apk")
    parser.add_argument(
        "--legacy-packaging",
        action="store_true",
        help="the APK extracts its libraries on install (useLegacyPackaging), so compressed entries are expected "
        "and the archive-offset alignment assertions of stored entries do not apply",
    )
    args = parser.parse_args()
    check_apk(args.apk, legacy_packaging=args.legacy_packaging)
