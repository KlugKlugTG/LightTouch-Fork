// VolumeMount: file-level edits of a raw HFS+ image through the stock tools, as an ordinary user (no root).
// Ports ipad1_rootfs.Mounted / grow_to_partition, build_nand.attach / resize and ipad1_nand.make_hfs_image.
// The disk-image operations (attach, detach, resize) go through DiskImage; mount/unmount, newfs_hfs and
// fsck_hfs are run here.
//
//   try await VolumeMount.withMounted(image, at: mountPoint) { root in ... }   // attach + diskutil mount (noowners,
//                                                                        // nobrowse); then junk removed, unmount
//                                                                        // (retried), fsck_hfs -fn, detach
//   try await VolumeMount.makeHFS(image, size: bytes, name: "Data")            // sparse, case-sensitive, journaled
//   try await VolumeMount.grow(image, toBytes: n)                              // resize + alternate header fix
//
// The mount is noowners: everything written lands as the host user and chown is refused, so owners are
// patched offline afterwards with HFSPlusVolume.setOwner. Write files in place (never replace them by
// rename) so an existing file keeps its catalog record and Apple's owner.

import Foundation
#if canImport(Android)
import Android
#endif

public enum VolumeMount {
    /// What macOS drops on a mounted volume; removed from its root before unmounting.
    public static let junk = [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems", ".DS_Store"]

    /// Mounts `image` read-write at `mountPoint` (created if needed), runs `body` with the mount root, then
    /// removes `junk`, unmounts (retrying while Spotlight or fseventsd hold the volume), checks it with
    /// `fsck_hfs -fn` and detaches (findings that are only folder counts are set offline and rechecked:
    /// `repairingFolderCounts`). A volume that would not unmount is never fsck'd (a mounted volume
    /// reports bogus damage); it is force-detached and the call throws. When `body` throws, its error wins.
    nonisolated(nonsending) public static func withMounted<T>(
        _ image: URL,
        at mountPoint: URL,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        #if !os(macOS)
        return try await withExtracted(image, at: mountPoint, body)
        #else
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let journal = (try? HFSPlusVolume(image).journalSnapshot()) ?? nil
        let dev = try await attach(image)
        let value: T
        do {
            try await run(
                "/usr/sbin/diskutil",
                ["mount", "-mountOptions", "nobrowse", "-mountPoint", mountPoint.path, dev]
            )
            try Task.checkCancellation()
            value = try await body(mountPoint)
            try Task.checkCancellation()
        } catch {
            // Original body/cancellation diagnostic wins; cleanup failure is explicit.
            do { _ = try await finish(dev: dev, mountPoint: mountPoint, check: false) } catch {
                FirmwareDiagnostics.write(Data("mount cleanup: \(error)\n".utf8))
            }
            throw error
        }
        let fsck = try await repairingFolderCounts(
            image,
            try await finish(dev: dev, mountPoint: mountPoint, check: true)
        )
        guard fsck.ok else {
            throw FirmwareError(
                .internal,
                "fsck_hfs is not happy with \(image.lastPathComponent): \(fsck.output.suffix(600))"
            )
        }
        if let journal { try HFSPlusVolume(image, writable: true).restore(journal) }
        return value
        #endif
    }

    #if !os(macOS)
    /// withMounted where no HFS+ driver is at hand (Linux, Android, Windows): the volume's files are laid out at
    /// `mountPoint` by HFSPlusEditor, `body` edits them there, and what changed is written back into the image.
    nonisolated(nonsending) static func withExtracted<T>(
        _ image: URL,
        at mountPoint: URL,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let journal = (try? HFSPlusVolume(image).journalSnapshot()) ?? nil
        if FileManager.default.fileExists(atPath: mountPoint.path) { try removeTree(mountPoint) }
        defer { try? removeTree(mountPoint) }
        // What the edit adds gets the modes a Mac's mount gives it (umask 022), not this process's (Linux's 002,
        // an Android app's 077).
        let mask = umask(0o022)
        defer { umask(mask) }
        let editor = try HFSPlusEditor(image)
        try editor.extract(to: mountPoint)
        try Task.checkCancellation()
        let value = try await body(mountPoint)
        try Task.checkCancellation()
        for name in junk { try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent(name)) }
        try editor.commit(from: mountPoint)
        if let journal { try HFSPlusVolume(image, writable: true).restore(journal) }
        return value
    }

    /// Removes a tree whose folders may be read-only (as the volume's own are).
    static func removeTree(_ root: URL) throws {
        let fm = FileManager.default
        var st = stat()
        guard lstat(root.path, &st) == 0 else { return }
        if st.st_mode & S_IFMT == S_IFDIR {
            chmod(root.path, 0o700)
            for name in try fm.contentsOfDirectory(atPath: root.path) { try removeTree(root.appendingPathComponent(name)) }
        }
        try fm.removeItem(at: root)
    }
    #endif

    private static func finish(dev: String, mountPoint: URL, check shouldCheck: Bool) async throws -> (
        ok: Bool, output: String
    ) {
        try await Task.detached {
            for name in junk { try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent(name)) }
            var unmounted = false
            for _ in 0..<20 {
                if (try? await run("/usr/sbin/diskutil", ["unmount", dev])) != nil {
                    unmounted = true
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            var checked: (ok: Bool, output: String) = (false, "")
            do {
                if unmounted && shouldCheck { checked = try await check(dev) }
            } catch {
                await cleanupDetach(dev)
                throw error
            }
            try await detach(dev, force: !unmounted)
            guard unmounted else { throw FirmwareError(.internal, "could not unmount \(mountPoint.path) (\(dev))") }
            return checked
        }.value
    }

    /// Awaited independent teardown; callers retain their resource owner until it returns.
    static func cleanupDetach(_ dev: String, force: Bool = false) async {
        do { try await detach(dev, force: force) } catch {
            FirmwareDiagnostics.write(Data("detach cleanup: \(error)\n".utf8))
        }
    }

    /// Attaches a raw image without mounting it; returns its /dev/diskN.
    public static func attach(_ image: URL) async throws -> String { try await DiskImage.attach(image).device }

    #if !os(macOS)
    /// What needs a Mac's disk images (a device to check or open in a file manager) is not available here.
    static func macOnly(_ what: String) -> FirmwareError {
        FirmwareError(.unsupported, "\(what) needs a Mac (it uses macOS's disk images)")
    }
    #endif

    /// Attaches `image` and mounts it at `mountPoint` (created if needed) out of Finder's sidebar and Desktop
    /// (nobrowse), owners ignored, for a Finder window opened on the folder. Detaching the device unmounts it.
    public static func attachHidden(_ image: URL, at mountPoint: URL, readOnly: Bool = false) async throws
        -> DiskImage.Attached
    {
        #if !os(macOS)
        throw macOnly("Opening a device's files")
        #endif
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let dev = try await DiskImage.attach(image, readOnly: readOnly).device
        do {
            do {
                try await run(
                    "/usr/sbin/diskutil",
                    ["mount"] + (readOnly ? ["readOnly"] : [])
                        + ["-mountOptions", "nobrowse,noowners", "-mountPoint", mountPoint.path, dev]
                )
            } catch {
                // macOS 15's diskutil fails a mount point inside a volume mounted noowners (the data volume on the
                // system volume's private/var: "Volume on diskN failed to mount"); mount(8) takes it.
                try await run(
                    "/sbin/mount",
                    ["-t", "hfs", "-o", "nobrowse,noowners" + (readOnly ? ",rdonly" : ""), dev, mountPoint.path]
                )
            }
        } catch {
            await cleanupDetach(dev, force: true)
            throw error
        }
        return DiskImage.Attached(device: dev, mountPoint: mountPoint.path)
    }

    /// Detaches `dev`, retrying; with `force`, the retries force it.
    /// Failure remains observable so callers cannot release ownership as if detached.
    public static func detach(_ dev: String, force: Bool = false) async throws {
        try await DiskImage.detach(dev, force: force)
    }

    /// `fsck_hfs -fn` (check only; -f because the data volume is journaled) of an attached, unmounted device.
    public static func check(_ dev: String) async throws -> (ok: Bool, output: String) {
        #if os(macOS)
            let (status, out) = try await exec("/sbin/fsck_hfs", ["-fn", dev])
            return (status == 0 && out.contains("appears to be OK"), out)
        #else
            throw macOnly("Checking a volume with fsck_hfs")
        #endif
    }

    /// smoke #36: macOS 27's HFS driver now and then writes a directory's HFSX folder count as 0 at the unmount
    /// (seen on directories the edit only read, e.g. 7B500's private/var/log, and on fresh data volumes), so
    /// fsck finds "Incorrect folder count in a directory". When those are fsck's only findings, set the counts
    /// it names in the detached image and check again; the result of that check is what counts. Any other
    /// finding is returned as is.
    static func repairingFolderCounts(_ image: URL, _ fsck: (ok: Bool, output: String)) async throws -> (
        ok: Bool, output: String
    ) {
        guard !fsck.ok, let counts = folderCountFindings(fsck.output) else { return fsck }
        FirmwareDiagnostics.write(
            Data("\(image.lastPathComponent): fsck_hfs found only folder counts, set offline: \(counts)\n".utf8)
        )
        try HFSPlusVolume(image, writable: true).setFolderCounts(counts)
        let dev = try await attach(image)
        let again: (ok: Bool, output: String)
        do { again = try await check(dev) } catch {
            await cleanupDetach(dev)
            throw error
        }
        try await detach(dev)
        return again.ok ? again : (false, fsck.output + "\nafter setting the folder counts:\n" + again.output)
    }

    /// CNID -> the count fsck_hfs wants, when every finding in `output` is "Incorrect folder count in a directory
    /// (id = N)" + "(It should be X instead of Y)"; nil when there is any other finding (or none).
    static func folderCountFindings(_ output: String) -> [UInt32: UInt32]? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                !$0.isEmpty && !$0.hasPrefix("** ") && !$0.hasPrefix("Executing fsck_hfs")
                    && !$0.hasPrefix("The volume name is ")
            }
        guard !lines.isEmpty, lines.count % 2 == 0 else { return nil }
        var counts: [UInt32: UInt32] = [:]
        for i in stride(from: 0, to: lines.count, by: 2) {
            guard
                let id = lines[i].wholeMatch(of: /Incorrect folder count in a directory \(id = (\d+)\)/).flatMap({
                    UInt32($0.1)
                }),
                let n = lines[i + 1].wholeMatch(of: /\(It should be (\d+) instead of \d+\)/).flatMap({ UInt32($0.1) })
            else { return nil }
            counts[id] = n
        }
        return counts
    }

    /// A bare (no partition map) case-sensitive journaled HFS+ volume in a sparse raw file of `size` bytes
    /// (rounded down to 4 KiB): newfs_hfs writes only metadata, so a 14.7 GB data volume costs ~40 MB.
    public static func makeHFS(_ image: URL, size: Int64, name: String = "Data", journaled: Bool = true) async throws {
        #if !os(macOS)
            return try HFSPlusEditor.format(image, size: size, name: name, journaled: journaled)
        #else
            guard FileManager.default.createFile(atPath: image.path, contents: nil),
                truncate(image.path, off_t(size / 4096 * 4096)) == 0
            else {
                throw FirmwareError(.internal, "cannot create \(image.path)")
            }
            let dev = try await attach(image)
            do { try await run("/sbin/newfs_hfs", ["-s"] + (journaled ? ["-J"] : []) + ["-v", name, dev]) }
            catch {
                await cleanupDetach(dev)
                throw error
            }
            try await detach(dev)
        #endif
    }

    /// Grows the volume in `image` to `bytes` (a multiple of 4096). The resize grows the file and the file
    /// system, but keeps the file's slack past the volume (the iPad IPSW volumes: one 4 KiB sector), so the file
    /// system stops that short; pad the file and move the alternate volume header to the new end - 1024, where
    /// fsck_hfs and the kernel look for it.
    public static func grow(_ image: URL, toBytes bytes: Int, backend: DiskImage.Backend = DiskImage.backend)
        async throws
    {
        guard try size(image) != bytes else { return }
        #if !os(macOS)
            try HFSPlusEditor.grow(image, toBytes: bytes)
        #else
            try await DiskImage.resize(image, toBytes: bytes, backend: backend)
            let old = try size(image)
            guard old <= bytes else { throw FirmwareError(.internal, "resize overshot \(bytes) bytes (\(old))") }
            let f = try FileHandle(forUpdating: image)
            defer { try? f.close() }
            try f.seek(toOffset: UInt64(old - 1024))
            let avh = try f.read(upToCount: 512) ?? Data()
            try f.truncate(atOffset: UInt64(bytes))
            try f.seek(toOffset: UInt64(bytes - 1024))
            try f.write(contentsOf: avh)
        #endif
    }

    static func size(_ u: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Runs a tool; throws with its output on a non-zero exit. Returns its output.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) async throws -> String { try await DiskImage.run([tool] + args) }

    /// (status, stdout and stderr).
    static func exec(_ tool: String, _ args: [String]) async throws -> (Int32, String) {
        try await DiskImage.exec([tool] + args)
    }
}
