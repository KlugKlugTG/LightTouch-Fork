#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Fetch, verify, patch and compile the pinned iBoot32Patcher helper executable.

iBoot32Patcher is GPL-3.0-or-later and is invoked by firmwarekit as a separate
process (K48IBoot.patchIBoot) for the iPad 1st gen (k48ap) iBoot chain.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

REPO = Path(__file__).resolve().parents[1]
DEPENDENCIES = REPO / "build-support/dependencies.json"
PATCH = REPO / "build-support/patches/iBoot32Patcher-ltm.patch"
SOURCES = ("src/finders.c", "src/functions.c", "src/iBoot32Patcher.c", "src/patchers.c")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def dependency_entry() -> dict:
    ledger = json.loads(DEPENDENCIES.read_text())
    for item in ledger["packages"]:
        if item.get("name") == "iBoot32Patcher":
            return item
    raise SystemExit(f"build-iboot32patcher: missing iBoot32Patcher in {DEPENDENCIES}")


def resolve_archive(entry: dict, archive: Path | None, cache_dir: Path | None) -> Path:
    expected = entry["sha256"].lower()
    if archive is not None:
        if not archive.is_file() or sha256(archive) != expected:
            raise SystemExit(f"build-iboot32patcher: archive {archive} does not match pinned SHA-256 {expected}")
        return archive
    target = (cache_dir or Path(tempfile.gettempdir())) / entry["archive"]
    if target.is_file() and sha256(target) == expected:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".part")
    with urllib.request.urlopen(entry["url"], timeout=60) as response, partial.open("wb") as out:
        shutil.copyfileobj(response, out)
    actual = sha256(partial)
    if actual != expected:
        partial.unlink(missing_ok=True)
        raise SystemExit(f"build-iboot32patcher: {entry['url']} SHA-256 {actual} != {expected}")
    partial.replace(target)
    return target


def safe_extract(archive: Path, destination: Path) -> None:
    root = destination.resolve()
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            if member.issym() or member.islnk():
                raise SystemExit(f"build-iboot32patcher: unexpected link in archive: {member.name}")
            target = (root / member.name).resolve()
            if root != target and root not in target.parents:
                raise SystemExit(f"build-iboot32patcher: unsafe archive path: {member.name}")
        tar.extractall(root)


def apply_patch(source_dir: Path) -> None:
    if shutil.which("patch"):
        subprocess.run(["patch", "-p1", "--batch", "--forward", "-i", str(PATCH)], cwd=source_dir, check=True)
        return
    subprocess.run(["git", "apply", "--unsafe-paths", "--directory", str(source_dir), str(PATCH)], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Output executable path")
    parser.add_argument("--license-output", type=Path, help="Optional destination for iBoot32Patcher's LICENSE")
    parser.add_argument("--cc", default="cc", help="C compiler executable")
    parser.add_argument("--strip", help="Optional strip executable")
    parser.add_argument("--android", action="store_true", help="Build 16 KiB-aligned Android PIE helper")
    parser.add_argument("--archive", type=Path, help="Pre-fetched iBoot32Patcher tarball")
    parser.add_argument("--cache-dir", type=Path, help="Directory to cache downloaded tarball")
    parser.add_argument("--extra-cflag", action="append", default=[], help="Extra flag passed to compiler")
    args = parser.parse_args()

    entry = dependency_entry()
    tarball = resolve_archive(entry, args.archive, args.cache_dir)
    with tempfile.TemporaryDirectory(prefix="iboot32patcher-") as scratch:
        scratch_dir = Path(scratch)
        safe_extract(tarball, scratch_dir)
        source_dir = scratch_dir / entry["directory"]
        if not source_dir.is_dir():
            raise SystemExit(f"build-iboot32patcher: missing extracted {source_dir}")
        apply_patch(source_dir)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        flags = ["-O2", "-fPIE", "-pie", "-Wno-multichar", "-Wno-int-conversion", "-Wno-pointer-to-int-cast", f"-I{source_dir}"]
        if args.android:
            flags.append("-Wl,-z,max-page-size=16384")
        flags.extend(args.extra_cflag)
        command = [args.cc, *flags, *(str(source_dir / rel) for rel in SOURCES), "-o", str(args.output)]
        subprocess.run(command, check=True)
        if args.strip:
            subprocess.run([args.strip, str(args.output)], check=True)
        args.output.chmod(0o755)
        if args.license_output is not None:
            args.license_output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_dir / "LICENSE", args.license_output)


if __name__ == "__main__":
    main()
