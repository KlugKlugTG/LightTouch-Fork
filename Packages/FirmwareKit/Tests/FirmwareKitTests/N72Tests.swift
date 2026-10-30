import Foundation
import Testing

@testable import FirmwareKit

/// N72 format contracts, independent legacy digests, and optional stock-firmware bake checks.
@Suite struct N72Tests {
    /// Restore ramdisks are encrypted IMG3s outside all_flash. Omitting their
    /// KBAGs aborts the AES model during a stock USB restore, before bootx.
    @Test func restoreRamdiskKeysAreExported() throws {
        let entry = try Oracle.entry("n72ap-5F138")
        try Oracle.withTemp { dir in
            let plist: [String: Any] = [
                "ProductType": "iPod2,1", "ProductVersion": "2.1.1", "ProductBuildVersion": "5F138",
                "DeviceMap": [["BoardConfig": "n72ap", "Platform": "s5l8720x"]],
                "KernelCachesByPlatform": ["s5l8720x": ["Release": "kernelcache.release.s5l8720x"]],
                "SystemRestoreImages": ["User": "rootfs.dmg"],
                "RestoreRamDisks": ["User": "018-4166-1.dmg", "Update": "018-4177-1.dmg"],
            ]
            let metadata = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try metadata.write(to: dir.appendingPathComponent("Restore.plist"))
            let components = try BuildComponents.fromRestore(RestoreInfo(plistData: metadata))
            for member in Set(components.values) {
                let path = dir.appendingPathComponent(member)
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try (Data("3gmI".utf8) + DeviceTree.Value.le([20, 0, 0, 0])).write(to: path)
            }
            var expected = Data()
            for (index, component) in ["RestoreRamDisk", "UpdateRamDisk"].enumerated() {
                let kbag = Data((0..<32).map { UInt8($0 + index * 32) })
                let le = { (words: [UInt32]) in DeviceTree.Value.le(words) }
                let tag = Data("GABK".utf8) + le([52, 40, 1, 128]) + kbag
                let image = Data("3gmI".utf8) + le([UInt32(20 + tag.count), UInt32(tag.count), 0, 0]) + tag
                try image.write(to: dir.appendingPathComponent(try #require(components[component])))
                let key = try #require(entry.keys[component])
                let ivHex = try #require(key.iv)
                let iv = try #require(Data(hex: ivHex))
                let aesKey = try #require(Data(hex: key.key))
                expected += kbag + iv + aesKey
            }
            try K48Oracle.sh(
                [
                    "/usr/bin/zip", "-q", "-r", "fixture.ipsw", "Restore.plist", "Firmware",
                    "rootfs.dmg", "kernelcache.release.s5l8720x", "018-4166-1.dmg", "018-4177-1.dmg",
                ],
                cwd: dir
            )
            let (blobs, names) = try N72Board.gidBlobs(
                IPSWArchive(dir.appendingPathComponent("fixture.ipsw")),
                entry: entry
            )
            #expect(blobs == expected)
            #expect(names == ["018-4166-1.dmg", "018-4177-1.dmg"])
        }
    }

    /// ipod2g_nand.selfcheck.
    /// iBoot's first AES request encrypts the seed under the UID (mode 6, | 1, | 8 with the mode read back); the NOR
    /// wraps every SHSH with that key (openssl enc -aes-128-ecb of kdfConst under 0123...EF).
    @Test func wrappingKeyIsTheUIDEncrypt() throws {
        #expect(try N72NOR.wrappingKey() == Data(hexLiteral: "435473c386c2c7df0b61d1e6ead8b50e"))
    }

    @Test func metadataSelfcheck() throws {
        let p = N72NAND.metadataPages(blocks: 128000, epoch: 1)
        #expect(p.count == 50 && p.values.allSatisfy { $0.count == 4096 + 64 })
        let hdr = try #require(p[.init(cs: 1, page: 256)])
        #expect(
            crc(hdr[0..<0x10] + [0, 0, 0, 0] + hdr[0x14..<0x5C]) == UInt32(hdr[0x10]) | UInt32(hdr[0x11]) << 8
                | UInt32(hdr[0x12]) << 16 | UInt32(hdr[0x13]) << 24
        )
        #expect(p[.init(cs: 2, page: 256)]![0x28..<0x30].reversed().reduce(0) { $0 << 8 | Int($1) } == 128002)
        #expect(N72NAND.predict(0) == .init(cs: 3, page: 256) && N72NAND.predict(1) == .init(cs: 0, page: 384))
    }

    @Test(arguments: [1, 127, 128, 129, 255, 256, 257, 1023, 1024, 1025, 128000, 1_835_008])
    func partitionAndFilesystemHaveTheSameAlternateHeader(_ blocks: Int) throws {
        let pages = N72NAND.gptPages(blocks)
        func le(_ data: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        let first = le(pages[2], 0x20, 8)
        let last = le(pages[2], 0x28, 8)
        #expect(first == 3)
        // Covers small/unaligned geometries too: even a one-block excess moves
        // the device-end alternate away from the filesystem's actual header.
        #expect(last - first + 1 == UInt64(blocks))
        #expect((last - first + 1) * 4096 - 1024 == UInt64(blocks) * 4096 - 1024)
        #expect(UInt64(crc(pages[2][0..<0x80])) == le(pages[1], 0x58, 4))
        var header = pages[1]
        header.replaceSubrange(0x10..<0x14, with: [0, 0, 0, 0])
        #expect(UInt64(crc(header[0..<0x5C])) == le(pages[1], 0x10, 4))
        // Protective MBR geometry is deliberately outside this correction.
        #expect(le(pages[0], 0x1BE + 8, 4) == 3)
        #expect(le(pages[0], 0x1BE + 12, 4) == UInt64(blocks + 10))
    }

    /// Preserve48 historical metadata pages and qualify exactly the two GPT
    /// geometry replacements from independently captured Python output.
    @Test func metadataPreservesLegacyExceptExactPartitionGPT() throws {
        let want = LegacyPreparationGoldens.n72Metadata.map { line in
            let fields = line.split(separator: " ")
            let key = "\(fields[0]) \(fields[1])"
            return LegacyPreparationGoldens.n72ExactPartitionGPT[key].map { "\(key) \($0)" } ?? line
        }
        let got = N72NAND.metadataPages(blocks: 1_835_008, epoch: 4).sorted {
            ($0.key.cs, $0.key.page) < ($1.key.cs, $1.key.page)
        }
        .map { "\($0.key.cs) \($0.key.page) \(Oracle.sha256(Data($0.value)))" }
        #expect(got == want)
    }

    /// The 7E18 IPSW's all_flash with an identity: the 1 MiB build_nor.py --identity made (recorded digest).
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func norMatchesLegacyReference() throws {
        let fw = Oracle.firmware("n72ap-7E18")
        guard fw.available else { try FixtureRequirements.missing(#"N72Tests.swift: fw.available"#) }
        try Oracle.withTemp { dir in
            let ipsw = IPSWArchive(fw.ipsw)
            let prefix = "Firmware/all_flash/all_flash.n72ap.production/"
            var images: [String: Data] = [:]
            for n in try ipsw.names() where n.hasPrefix(prefix) && n.hasSuffix(".img3") {
                images[try N72NOR.type(of: ipsw.read(n))] = try ipsw.read(n)
            }
            let id = try UnitIdentity.synthesizeIPod(seed: "n72-test", modelNumber: "MB528", regionInfo: "LL/A")
            let got = try N72NOR.build(identity: id, images: images, types: N72NOR.order, wrapTypes: nil)
            #expect(Oracle.sha256(got) == LegacyPreparationGoldens.n72NOR)
        }
    }

    /// The GL front end on 2.x, 5F138's stock OpenGLES: the export scan and, with an armv6.itpack at hand,
    /// GuestPackage.seed: n72-ios2's hook puts the one front end
    /// (contrib/gles-public) over OpenGLES, the stock binary kept as OpenGLES.baked, every stock name still exported.
    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func frontEnd() async throws {
        let fw = Oracle.firmware("n72ap-5F138")
        let dmg = fw.cache?.appendingPathComponent("rootfs.dmg")
        guard let dmg, Oracle.exists(dmg) else {
            try FixtureRequirements.missing(#"N72Tests.swift: let dmg, Oracle.exists(dmg)"#)
        }
        try await Oracle.withTemp { dir in
            let raw = dir.appendingPathComponent("rootfs.hfs")
            let stock = dir.appendingPathComponent("OpenGLES")
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            let v = try HFSPlusVolume(raw)
            try v.contents(v.record(at: N72Board.openGLES)).write(to: stock)
            try FileManager.default.removeItem(at: raw)
            let names = try N72Board.exportedSymbols(Data(contentsOf: stock))
            #expect(names.count > 200)

            let itpack = Oracle.guestPackages.appendingPathComponent("armv6.itpack")
            guard Oracle.exists(itpack) else {
                try FixtureRequirements.missing(#"N72Tests.swift: Oracle.exists(itpack)"#)
            }
            // the firmware the seed's load checks read (5F138's own executables and libSystem)
            guard let base = try await FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138"), in: dir) else {
                try FixtureRequirements.missing(
                    #"N72Tests.swift: let base = try await FitFixture.volume("n72ap-5F138", FitFixture.stock("n72ap-5F138"), in: dir)"#
                )
            }
            func volume(_ name: String) throws -> URL {
                let m = dir.appendingPathComponent(name)
                let sv = m.appendingPathComponent(GuestPackage.systemVersion)
                try FileManager.default.copyItem(at: base, to: m)
                try SystemEdits.mkdirs(m.appendingPathComponent(N72Board.openGLES).deletingLastPathComponent())
                try SystemEdits.put(Data(contentsOf: stock), m.appendingPathComponent(N72Board.openGLES), mode: 0o755)
                try SystemEdits.mkdirs(sv.deletingLastPathComponent())
                try PropertyListSerialization.data(
                    fromPropertyList: ["ProductBuildVersion": "5F138"], format: .xml, options: 0
                ).write(to: sv)
                return m
            }
            let a = try volume("swift")
            let (written, record) = try GuestPackage.seed(volume: a, itpack: itpack, gles: true)
            #expect(!written.isEmpty)
            #expect(record.family == "n72-ios2" && record.hooks == ["/" + N72Board.openGLES])
            // The seed's state must let a different first offer restore the stock
            // front end, before the loader ever reads this seed's own offer.
            let statePath = GuestPackage.root + "/state"
            let state = try String(contentsOf: a.appendingPathComponent(statePath), encoding: .utf8)
            #expect(state == "seed \(record.seed)\nhook 1 /\(N72Board.openGLES)\n")

            // Dropping the GL hook keeps stock bytes and does not claim ownership.
            let noGL = try volume("no-gl")
            let (_, noGLRecord) = try GuestPackage.seed(volume: noGL, itpack: itpack, gles: false)
            #expect(noGLRecord.hooks.isEmpty)
            #expect(
                try String(contentsOf: noGL.appendingPathComponent(statePath), encoding: .utf8)
                    == "seed \(record.seed)\n"
            )
            #expect(try Data(contentsOf: noGL.appendingPathComponent(N72Board.openGLES)) == Data(contentsOf: stock))

            // A deliberately omitted target is neither recreated nor claimed.
            let omitted = try volume("omitted")
            let omittedTarget = omitted.appendingPathComponent(N72Board.openGLES)
            try FileManager.default.removeItem(at: omittedTarget)
            let (_, omittedRecord) = try GuestPackage.seed(
                volume: omitted,
                itpack: itpack,
                gles: true,
                omitted: ["/" + N72Board.openGLES]
            )
            #expect(omittedRecord.hooks.isEmpty)
            #expect(FileManager.default.fileExists(atPath: omittedTarget.path) == false)
            #expect(
                try String(contentsOf: omitted.appendingPathComponent(statePath), encoding: .utf8)
                    == "seed \(record.seed)\n"
            )

            // A target that cannot be copied must not be recorded as installed.
            // The GL hook's own fit proof is external, so the directory reaches
            // the real seed copy path rather than failing a synthetic loader check.
            let failed = try volume("failed-copy")
            let target = failed.appendingPathComponent(N72Board.openGLES)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try SystemEdits.put(
                Data(contentsOf: stock),
                failed.appendingPathComponent(N72Board.openGLES + ".baked"),
                mode: 0o755
            )
            #expect(throws: (any Error).self) {
                try GuestPackage.seed(volume: failed, itpack: itpack, gles: true)
            }
            #expect(
                try String(contentsOf: failed.appendingPathComponent(statePath), encoding: .utf8)
                    == "seed \(record.seed)\n"
            )
            let file = { (m: URL, s: String) in try Data(contentsOf: m.appendingPathComponent(N72Board.openGLES + s)) }
            let hooked = try file(a, "")
            let baked = try file(a, ".baked")
            let stockBytes = try Data(contentsOf: stock)
            #expect(hooked != stockBytes && baked == stockBytes)
            #expect(try SystemEdits.permissions(a.appendingPathComponent(N72Board.openGLES + ".baked")) == 0o755)
            #expect(Set(try N72Board.exportedSymbols(hooked)).isSuperset(of: names))  // every stock name, and 3.x-5.x's
        }
    }

    /// Smoke #45 and the once-only defaults: without helpers (1.x, 2.x/3.0) the bake writes it_prefs' keys itself into
    /// the user's com.apple.springboard.plist, keeping the Sounds defaults already there: SBDidShowReorderText = <true/>,
    /// Brightness at maximum under the key this SpringBoard names (2.x-3.x SBBacklightLevel2, 1.x SBBacklightLevel; a
    /// key that only prefixes another is not named) and Auto-Lock Never (SBAutoLockTime and SBAutoDimTime -1: SpringBoard
    /// resets a lock time below the dim time to its defaults). A SpringBoard naming none
    /// is left alone. With the 5F138 cache at hand, its real SpringBoard names the tip.
    @Test func prefsBakedWithoutHelpers() throws {
        try Oracle.withTemp { m in
            let sb = m.appendingPathComponent(N72Board.springBoard)
            let plist = m.appendingPathComponent(N72Board.prefs + "/com.apple.springboard.plist")
            func baked() throws -> [String: Any] {
                try #require(
                    PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
                )
            }
            try SystemEdits.mkdirs(sb.deletingLastPathComponent())
            try Data(
                "\0SBDidShowReorderText\0SBBacklightLevel2\0SBAutoLockTime\0SBAutoLockTimeKey\0SBAutoDimTime\0".utf8
            ).write(to: sb)
            try SystemEdits.seedPlist(plist) { $0["lock-unlock"] = true }
            #expect(
                try N72Board.bakePrefs(m, dir: N72Board.prefs)
                    == "SBDidShowReorderText, SBBacklightLevel2, SBAutoLockTime, SBAutoDimTime baked (no helpers)"
            )
            var d = try baked()
            #expect(d[N72Board.reorderTip] as? Bool == true && d["lock-unlock"] as? Bool == true)
            #expect(
                d["SBBacklightLevel2"] as? Double == 1.0 && d["SBBacklightLevel"] == nil
                    && d["SBAutoLockTime"] as? Int == -1 && d["SBAutoDimTime"] as? Int == -1
            )
            #expect(
                try String(contentsOf: plist, encoding: .utf8).contains("<key>SBDidShowReorderText</key>\n\t<true/>")
            )

            try FileManager.default.removeItem(at: plist)  // 1.x: SBBacklightLevel, no reorder tip
            // 1.0's SpringBoard names these (and no SBShowBatteryPercentage): as it_prefs sets them on 2.x+
            try Data("\0SBBacklightLevel\0SBAutoLockTime\0SBHideACPower\0SBEnableALS\0".utf8).write(to: sb)
            #expect(
                try N72Board.bakePrefs(m, dir: N72Board.prefs)
                    == "SBBacklightLevel, SBAutoLockTime, SBHideACPower, SBEnableALS baked (no helpers)"
            )
            d = try baked()
            #expect(
                d["SBBacklightLevel"] as? Double == 1.0 && d["SBBacklightLevel2"] == nil
                    && d[N72Board.reorderTip] == nil
            )
            #expect(
                d["SBHideACPower"] as? Bool == true && d["SBEnableALS"] as? Bool == false
                    && d["SBShowBatteryPercentage"] == nil
            )

            try FileManager.default.removeItem(at: plist)
            try Data("SpringBoard SBDidShowReorderTextX".utf8).write(to: sb)
            #expect(try N72Board.bakePrefs(m, dir: N72Board.prefs).hasSuffix("left alone") && !Oracle.exists(plist))
        }
    }

    @Test(.enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"))
    func stock2xSpringBoardReadsReorderTip() async throws {
        let fw = Oracle.firmware("n72ap-5F138")
        guard let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg) else {
            try FixtureRequirements.missing(
                #"N72Tests.swift: let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg)"#
            )
        }
        try await Oracle.withTemp { dir in
            let raw = dir.appendingPathComponent("rootfs.hfs")
            try await UDIF.extractRootfs(dmg: dmg, to: raw)
            let v = try HFSPlusVolume(raw)
            #expect(try v.contents(v.record(at: N72Board.springBoard)).range(of: Data(N72Board.reorderTip.utf8)) != nil)
        }
    }
}
