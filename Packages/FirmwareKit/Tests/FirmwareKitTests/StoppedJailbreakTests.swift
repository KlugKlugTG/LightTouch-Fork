import Foundation
import HostRuntime
import Testing

@testable import FirmwareKit

/// The jailbreak of an existing device (StoppedVolumeEdit.jailbreak, firmwarekit edit --action jailbreak): the
/// preparation's edits (SystemEdits.installJailbreak) through a stopped edit, the user's files kept, the lock and boot
/// files saying jailbroken.
@Suite(.detachesItsImages) struct StoppedJailbreakTests {
    let fm = FileManager.default
    static var springBoardJob: [String: Any] {
        [
            "Label": "com.apple.SpringBoard",
            "EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/usr/lib/it_typein.dylib:/usr/lib/other.dylib"],
        ]
    }

    /// CydiaInstallTests' firmware root at `version`, with lockdown's AFC service, SpringBoard's job and it_typein.
    func firmware(in dir: URL, version: String) throws -> URL {
        let m = try CydiaInstallTests().firmware(in: dir, prefs: nil, version: version)
        try JailbreakTests.put(
            PropertyListSerialization.data(
                fromPropertyList: ["com.apple.afc": JailbreakTests.stockAFC[1]],
                format: .xml,
                options: 0
            ),
            m,
            SystemEdits.lockdownServices
        )
        try JailbreakTests.put(
            PropertyListSerialization.data(fromPropertyList: Self.springBoardJob, format: .xml, options: 0),
            m,
            SystemEdits.springBoardJob
        )
        try JailbreakTests.put(Data("--lockdown".utf8), m, SystemEdits.afcd)
        try JailbreakTests.put(Data("typein".utf8), m, "usr/lib/it_typein.dylib")
        return m
    }

    func environment(_ m: URL) throws -> [String: Any] {
        let job = try #require(NSDictionary(contentsOf: m.appendingPathComponent(SystemEdits.springBoardJob)))
        return job["EnvironmentVariables"] as? [String: Any] ?? [:]
    }

    @Test func typeinMovesToSubstrateOnlyWhenAsked() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-jb-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let bootstrap = try CydiaInstallTests().bootstrap(in: dir)
        let plain = try firmware(in: dir.appendingPathComponent("plain"), version: "4.2.1")
        let r = try SystemEdits.installJailbreak(plain, bootstrap: bootstrap, typeinBySubstrate: false)
        #expect(r.afc2.hasPrefix("afc2:") && r.cydia.hasPrefix("Cydia:"))
        #expect(
            try environment(plain)["DYLD_INSERT_LIBRARIES"] as? String
                == "/usr/lib/it_typein.dylib:/usr/lib/other.dylib"
        )
        let n72 = try firmware(in: dir.appendingPathComponent("n72"), version: "4.2.1")
        let s = try SystemEdits.installJailbreak(n72, bootstrap: bootstrap, typeinBySubstrate: true)
        #expect(try environment(n72)["DYLD_INSERT_LIBRARIES"] as? String == "/usr/lib/other.dylib")
        let ext = "Library/MobileSubstrate/DynamicLibraries/it_typein"
        #expect(
            try fm.destinationOfSymbolicLink(atPath: n72.appendingPathComponent(ext + ".dylib").path)
                == "/usr/lib/it_typein.dylib"
        )
        #expect(fm.fileExists(atPath: n72.appendingPathComponent(ext + ".plist").path))
        #expect(s.root.contains(ext + ".dylib") && s.root.contains(ext + ".plist"))
    }

    @Test func ios3DisablesTypeinWithoutInstallingSubstrate() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-jb-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let root = try firmware(in: dir, version: "3.1.3")
        let result = try SystemEdits.installJailbreak(
            root, bootstrap: CydiaInstallTests().bootstrap(in: dir), typeinBySubstrate: true
        )
        #expect(try environment(root)["DYLD_INSERT_LIBRARIES"] as? String == "/usr/lib/other.dylib")
        let ext = "Library/MobileSubstrate/DynamicLibraries/it_typein"
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(ext + ".dylib").path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(ext + ".plist").path))
        #expect(!result.root.contains(ext + ".dylib") && !result.root.contains(ext + ".plist"))
    }

    @Test func kbootTakesTheJailbrokenBootArgsOnce() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("ltm-jb-kboot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        // An image whose boot_args sit at +0x1000 (command line 56 bytes in), then the K48KBOOT trailer.
        var image = [UInt8](repeating: 0xAA, count: 0x2000)
        let line = Array(K48Board.bootArgs(jailbreak: false).utf8)
        image.replaceSubrange(0x1038..<0x1138, with: line + [UInt8](repeating: 0, count: 256 - line.count))
        let trailer =
            Array("K48KBOOT".utf8) + [0x4000_0000, 0x4000_0100, 0x4000_1000, 0x2000].flatMap(K48IBoot.le32Bytes)
        try Data(image + trailer).write(to: base.appendingPathComponent("kboot.bin"))
        #expect(try K48Board.jailbreakBootFiles(base: base) == "kboot.bin")
        let after = [UInt8](try Data(contentsOf: base.appendingPathComponent("kboot.bin")))
        let want = Array(K48Board.bootArgs(jailbreak: true).utf8)
        #expect(Array(after[0x1038..<0x1038 + want.count + 1]) == want + [0])
        #expect(
            Array(after[0..<0x1038]) == Array(image[0..<0x1038])
                && Array(after[0x1138...]) == Array(image[0x1138...]) + trailer
        )
        #expect(try K48Board.jailbreakBootFiles(base: base) == nil, "already there: unchanged")
    }

    @Test func patchedIBootGrowsItsBootArgsIntoTheCertificateText() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("ltm-jb-iboot-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let text = "Reliance on this certificate by any party assumes acceptance of the then applicable standard terms"
        let before =
            Data(repeating: 0x11, count: 64) + Data((K48Board.bootArgs(jailbreak: false) + "\0").utf8)
            + Data((text + "\0").utf8) + Data(repeating: 0x22, count: 64)
        try before.write(to: base.appendingPathComponent("iBoot.bin"))
        #expect(try K48Board.jailbreakBootFiles(base: base) == "iBoot.bin")
        let after = try Data(contentsOf: base.appendingPathComponent("iBoot.bin"))
        let grown = Data((K48Board.bootArgs(jailbreak: true) + "\0").utf8)
        #expect(after.count == before.count && after.range(of: grown)?.lowerBound == 64)
        #expect(after.suffix(after.count - 64 - grown.count) == before.suffix(before.count - 64 - grown.count))
        #expect(try K48Board.jailbreakBootFiles(base: base) == nil)
        // the string with nothing but NULs after it: no room
        try (Data((K48Board.bootArgs(jailbreak: false) + "\0").utf8) + Data(count: 64))
            .write(to: base.appendingPathComponent("iBoot.bin"))
        #expect(throws: FirmwareError.self) { try K48Board.jailbreakBootFiles(base: base) }
    }

    /// An N72 device (the generated store) with a user's file and a set-user-ID-less volume: after the jailbreak the
    /// published generation has Cydia (cydo set-user-ID root), afc2, the user's file, and a lock that says jailbroken.
    @Test func existingDeviceKeepsItsFilesAndSaysJailbroken() async throws {
        let root = try Fixtures.tempDir("stopped-jailbreak")
        defer { try? fm.removeItem(at: root) }
        let bootstrap = try CydiaInstallTests().bootstrap(in: root.appendingPathComponent("bootstrap"))
        let tree = try firmware(in: root.appendingPathComponent("tree"), version: "3.1.3")
        try JailbreakTests.put(Data("saved game".utf8), tree, "private/var/mobile/Media/user.txt")
        let device = root.appendingPathComponent("device")
        let base = device.appendingPathComponent("base")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("volume.img")
        try await VolumeMount.makeHFS(image, size: 32 << 20, name: "Jailbreak test")
        try await VolumeMount.withMounted(image, at: root.appendingPathComponent("initial")) { mount in
            for item in try fm.contentsOfDirectory(atPath: tree.path) {
                try fm.copyItem(at: tree.appendingPathComponent(item), to: mount.appendingPathComponent(item))
            }
        }
        let hfs = try HFSPlusVolume(image)
        _ = try N72NAND.write(
            volume: image,
            blocks: hfs.totalBlocks * hfs.blockSize / N72NAND.page,
            epoch: 1,
            out: base.appendingPathComponent("nand")
        )
        try JSONSerialization.data(withJSONObject: [
            "board": "n72ap", "product_version": "3.1.3", "derived": ["nand_epoch": 1],
        ]).write(to: base.appendingPathComponent("device.lock.json"))
        try DeviceRecord.data([
            "id": UUID().uuidString, "board": "n72ap", "firmware": "test",
            "base": ["kind": "prepared", "path": base.path],
            "storage": [
                "key": "k", "overlay": device.appendingPathComponent("overlay").path, "snapshot": "s",
                "usbmuxConf": "conf",
            ],
        ]).write(to: device.appendingPathComponent(DeviceRecord.name))

        try await StoppedVolumeEdit.jailbreak(device: device, bootstrap: bootstrap)

        let published = try DeviceRecord.object(Data(contentsOf: device.appendingPathComponent(DeviceRecord.name)))
        let generation = URL(fileURLWithPath: try #require((published["base"] as? [String: String])?["path"]))
        #expect(try DeviceLock.read(base: generation)?.jailbroken == true)
        #expect(try DeviceLock.read(base: base)?.jailbroken == false, "the prepared base is untouched")
        let volume = try HFSPlusVolume(
            try #require(
                try VolumeRebuild.rebuild(
                    base: generation.appendingPathComponent("nand"),
                    overlay: nil,
                    into: root.appendingPathComponent("verify")
                ).first
            ).image
        )
        #expect(try volume.contents(volume.record(at: "private/var/mobile/Media/user.txt")) == Data("saved game".utf8))
        #expect(try volume.contents(volume.record(at: "Applications/Cydia.app/Cydia")) == Data("cydia".utf8))
        let cydo = try volume.record(at: "usr/libexec/cydia/cydo")
        #expect(cydo.uid == 0 && cydo.mode & 0o7777 == 0o6755)
        let services = try PropertyListSerialization.propertyList(
            from: volume.contents(volume.record(at: SystemEdits.lockdownServices)),
            format: nil
        )
        #expect((services as? [String: Any])?["com.apple.afc2"] != nil)
        await #expect(throws: FirmwareError.self, "once only") {
            try await StoppedVolumeEdit.jailbreak(device: device, bootstrap: bootstrap)
        }
    }
}
