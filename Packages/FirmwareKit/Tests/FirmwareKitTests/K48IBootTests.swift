import Foundation
import Testing

@testable import FirmwareKit

/// The real iBoot chain artifacts (iBoot.bin, nor.bin, gid-blobs.bin) byte-for-byte against the Python pipeline's
/// pre-seal outputs (ipad1_gid.gid_blobs + host_usb_devicetree, ipad1_iboot.py's iBoot+NOR). No QEMU boot: the seal
/// only writes the per-boot effaceable/NVRAM region, so the freshly built NOR is identical on both sides.
/// Requires the IPSW and iBoot32Patcher; expected digests are frozen independently of Swift.
struct K48IBootTests {
    /// The Legacy-iOS-Kit build the port was checked against.
    static let reference = Fixtures.home.appendingPathComponent(
        "Downloads/Legacy-iOS-Kit_complete_v25.09.01/bin/macos/iBoot32Patcher"
    )
    /// iBoot32Patcher: FIRMWAREKIT_IBOOT_PATCHER / IBOOT32PATCHER, else the Legacy-iOS-Kit binary.
    static let patcher: URL? = {
        let env = ProcessInfo.processInfo.environment
        let candidates: [String?] = [env["FIRMWAREKIT_IBOOT_PATCHER"], env["IBOOT32PATCHER"], reference.path]
        for p in candidates.compactMap({ $0 }) where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }()

    /// The IPSW for a catalog entry in the app's download cache (IPSWStore: <sha1>.ipsw), when it is there.
    static func cachedIPSW(_ id: String) throws -> URL? {
        guard let sha1 = try Oracle.entry(id).source.sha1 else { return nil }
        let u = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
        return Oracle.exists(u) ? u : nil
    }

    /// `id`'s decrypted iBoot patched by `tool` (nil when the IPSW is not cached).
    static func patched(_ id: String, by tool: URL) throws -> Data? {
        guard let ipsw = try cachedIPSW(id) else { return nil }
        return try Oracle.withTemp { dir in
            _ = try FirmwareDecryptor.decrypt(ipsw: ipsw, entry: try Oracle.entry(id), into: dir, rootfs: false)
            return try K48IBoot.patchIBoot(
                try Data(contentsOf: dir.appendingPathComponent("iBoot.bin")),
                patcher: tool,
                bootArgs: KBoot.defaultBootArgs,
                log: { _ in }
            )
        }
    }

    /// The patcher we build (scripts/build-iboot32patcher.sh: the pinned archive plus
    /// build-support/patches/iBoot32Patcher-ltm.patch; FIRMWAREKIT_IBOOT_PATCHER, e.g. a native root's
    /// build/iBoot32Patcher/iBoot32Patcher or the app's Contents/MacOS copy) patches every k48 iBoot the unpatched
    /// tool could to the same bytes as the Legacy-iOS-Kit binary. Skipped per build without its cached IPSW.
    static var mine: URL? {
        let fm = FileManager.default
        guard
            let mine = ProcessInfo.processInfo.environment["FIRMWAREKIT_IBOOT_PATCHER"].map({ URL(fileURLWithPath: $0) }
            ),
            fm.isExecutableFile(atPath: mine.path), fm.isExecutableFile(atPath: reference.path),
            mine.resolvingSymlinksInPath() != reference.resolvingSymlinksInPath()
        else { return nil }
        return mine
    }

    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: [
            "k48ap-7B367", "k48ap-7B500", "k48ap-8C148", "k48ap-8F190", "k48ap-8G4", "k48ap-8H7", "k48ap-8J3",
            "k48ap-8K2", "k48ap-8L1", "k48ap-9A334", "k48ap-9A405", "k48ap-9B176", "k48ap-9B206", "k48ap-9A5288d",
        ]
    )
    func patcherMatchesReference(id: String) throws {
        guard let mine = Self.mine, let ours = try Self.patched(id, by: mine) else {
            try FixtureRequirements.missing(
                #"K48IBootTests.swift: let mine = Self.mine, let ours = try Self.patched(id, by: mine)"#
            )
        }
        let theirs = try Self.patched(id, by: Self.reference)
        #expect(ours == theirs, "\(id): \(mine.path) and the Legacy-iOS-Kit patcher differ")
    }

    /// 9A5220p (smoke #48): the unpatched tool takes the boot-args address at an unaligned 0x11f22 (two pool words)
    /// and fails; the aligned search finds the literal at 0x11f24 and patches it.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func alignedXrefPatches9A5220p() throws {
        guard let mine = Self.mine, let ours = try Self.patched("k48ap-9A5220p", by: mine) else {
            try FixtureRequirements.missing(
                #"K48IBootTests.swift: let mine = Self.mine, let ours = try Self.patched("k48ap-9A5220p", by: mine)"#
            )
        }
        // Smoke #50: beta 1's call has no R3 output pointer. Retain the result-slot
        // initialization, bypass authentication, then resume normal DATA extraction.
        guard let ipsw = try Self.cachedIPSW("k48ap-9A5220p") else {
            try FixtureRequirements.missing(#"K48IBootTests.swift: let ipsw = try Self.cachedIPSW("k48ap-9A5220p")"#)
        }
        try Oracle.withTemp { dir in
            _ = try FirmwareDecryptor.decrypt(
                ipsw: ipsw,
                entry: try Oracle.entry("k48ap-9A5220p"),
                into: dir,
                rootfs: false
            )
            let stock = try Data(contentsOf: dir.appendingPathComponent("iBoot.bin"))
            #expect(Array(ours[0x10ab4..<0x10ab8]) == [0x00, 0x20, 0x00, 0xbf])  // no STR [R3]
            #expect(ours[0x10ab8..<0x10abc] == stock[0x10ab8..<0x10abc])  // initialize result
            #expect(Array(ours[0x10abc..<0x10abe]) == [0x14, 0xe1])  // B DATA block at 0x10ce8
            #expect(ours[0x10ce8..<0x10e98] == stock[0x10ce8..<0x10e98])  // extract/decrypt/cleanup
            #expect(ours[0x10254..<0x103f4] == stock[0x10254..<0x103f4])  // inner verifier unchanged
        }
        #expect(throws: FirmwareError.self) { try Self.patched("k48ap-9A5220p", by: Self.reference) }
    }

    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: ["k48ap-7B500", "k48ap-8C148"]
    ) func iBootChainMatchesLegacyReference(id: String) throws {
        let fw = Oracle.firmware(id)
        guard fw.available, let patcher = Self.patcher else {
            try FixtureRequirements.missing(#"K48IBootTests.swift: fw.available, let patcher = Self.patcher"#)
        }
        try Oracle.withTemp { dir in
            let entry = try Oracle.entry(id)
            let dec = dir.appendingPathComponent("dec")
            _ = try FirmwareDecryptor.decrypt(ipsw: fw.ipsw, entry: entry, into: dec, rootfs: false)
            let ident = try UnitIdentity.synthesize(
                seed: "ipad1-\(entry.build)-default",
                storage: entry.recipe!.storage
            )

            // Swift artifacts.
            let mine = dir.appendingPathComponent("swift")
            try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
            let ipsw = IPSWArchive(fw.ipsw)
            let (blobs, _) = try K48IBoot.gidBlobs(ipsw, entry: entry)
            try blobs.write(to: mine.appendingPathComponent("gid-blobs.bin"))
            let prefix = "Firmware/all_flash/all_flash.\(entry.board).production/"
            var allFlash: [String: Data] = [:]
            for m in try ipsw.names() where m.hasPrefix(prefix) && m.hasSuffix(".img3") {
                allFlash[try N72NOR.type(of: ipsw.read(m))] = try ipsw.read(m)
            }
            allFlash["dtre"] = try K48IBoot.hostUSBDeviceTree(
                img3: allFlash["dtre"]!,
                plaintext: try Data(contentsOf: dec.appendingPathComponent("DeviceTree.bin")),
                gidBlobs: blobs
            )
            let order = try String(decoding: try ipsw.read(prefix + "manifest"), as: UTF8.self).split(
                whereSeparator: \.isWhitespace
            )
            .map { try N72NOR.type(of: ipsw.read(prefix + String($0))) }
            try K48IBoot.patchIBoot(
                try Data(contentsOf: dec.appendingPathComponent("iBoot.bin")),
                patcher: patcher,
                bootArgs: KBoot.defaultBootArgs,
                log: { _ in }
            )
            .write(to: mine.appendingPathComponent("iBoot.bin"))
            try K48IBoot.buildNOR(identity: ident, allFlash: allFlash, order: order, bootArgs: KBoot.defaultBootArgs)
                .write(to: mine.appendingPathComponent("nor.bin"))

            let expected = try #require(LegacyPreparationGoldens.k48[id])
            for name in ["iBoot.bin", "nor.bin", "gid-blobs.bin"] {
                #expect(
                    Oracle.sha256(try Data(contentsOf: mine.appendingPathComponent(name))) == expected[name],
                    "\(id) \(name): legacy reference differs"
                )
            }
        }
    }

    @Test func patcherDiscoveryFindsAndroidNativeLibSibling() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("k48-patcher-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let helper = dir.appendingPathComponent("liblighttouch_oneshot.so")
        let patcher = dir.appendingPathComponent("libiboot32patcher.so")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: patcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: patcher.path)
        let resolved = K48IBoot.patcher(helper: helper)
        if resolved.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            #expect(resolved.lastPathComponent == "libiboot32patcher.so")
        }
    }
}
