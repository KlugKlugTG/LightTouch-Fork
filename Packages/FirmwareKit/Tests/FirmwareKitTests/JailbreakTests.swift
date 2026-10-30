#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing

@testable import FirmwareKit

/// The jailbreak option (firmwarekit create --jailbreak): afc2 beside the stock AFC service.
struct JailbreakTests {
    /// The stock com.apple.afc entries: 1.0's (no unactivated flag), 1.1.4 to 5.x's (afcd at the media folder) and 6.x
    /// to 7.x's (afcd as an XPC service). Through 7.0 afc2 is the same old-style entry on every one: afcd still takes
    /// --lockdown.
    static var stockAFC: [[String: Any]] {
        [
            ["Label": "com.apple.afc", "ProgramArguments": ["/usr/libexec/afcd", "--lockdown"]],
            [
                "AllowUnactivatedService": true, "Label": "com.apple.afc",
                "ProgramArguments": ["/usr/libexec/afcd", "--lockdown", "-d", "/var/mobile/Media", "-u", "mobile"],
            ],
            [
                "AllowUnactivatedService": true, "Label": "com.apple.afc", "UserName": "mobile",
                "XPCServiceName": "com.apple.afcd",
            ],
        ]
    }

    @Test(arguments: 0..<3) func afc2ServesTheRootBesideTheStockService(era: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = root.appendingPathComponent(SystemEdits.lockdownServices)
        try FileManager.default.createDirectory(
            at: services.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stock: [String: Any] = ["com.apple.afc": Self.stockAFC[era], "com.apple.syslog_relay": ["Label": "x"]]
        try PropertyListSerialization.data(fromPropertyList: stock, format: .binary, options: 0).write(to: services)
        try Self.put(Data("usage: -L | --lockdown : run under old-style lockdown".utf8), root, SystemEdits.afcd)
        #expect(try SystemEdits.installAFC2(root).root.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(SystemEdits.afc2d).path))
        var format = PropertyListSerialization.PropertyListFormat.xml
        let edited = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: services), format: &format)
                as? [String: Any]
        )
        #expect(format == .binary, "the stock format is kept")
        let afc2 = try #require(edited["com.apple.afc2"] as? [String: Any])
        #expect(afc2["Label"] as? String == "com.apple.afc2")
        #expect(afc2["ProgramArguments"] as? [String] == ["/usr/libexec/afcd", "--lockdown", "-d", "/"])
        #expect(afc2["AllowUnactivatedService"] as? Bool == true)
        #expect(afc2["UserName"] == nil, "afcd at / runs as root")
        #expect(
            NSDictionary(dictionary: edited["com.apple.afc"] as? [String: Any] ?? [:]).isEqual(to: Self.stockAFC[era])
        )
        #expect(edited.count == 3)
    }

    @Test func afc2NeedsTheStockService() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let services = root.appendingPathComponent(SystemEdits.lockdownServices)
        try FileManager.default.createDirectory(
            at: services.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
            .write(to: services)
        try Self.put(Data("--lockdown".utf8), root, SystemEdits.afcd)
        #expect(throws: FirmwareError.self) { try SystemEdits.installAFC2(root) }
    }

    static func put(_ data: Data, _ root: URL, _ rel: String) throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
    }

    /// 7.1's afcd (no --lockdown, an XPC service at the media folder only), signed, with its root and service name.
    static func afcd71() -> [UInt8] {
        var b = ActivationTests.syntheticMachO()
        for (offset, s) in [(48, "/private/var/mobile/Media"), (80, "com.apple.afcd"), (100, "com.apple.afcd")] {
            b.replaceSubrange(offset..<(offset + s.utf8.count), with: Array(s.utf8))
        }
        return b
    }

    /// 7.1: afc2 is afc2d, a re-signed copy of afcd serving "/" as the XPC service com.apple.afc2, from a launchd job
    /// made from afcd's own without its user.
    @Test func afc2On71IsAnAfcdCopyAtTheRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stockJob: [String: Any] = [
            "Label": "com.apple.afcd", "MachServices": ["com.apple.afcd": true], "EnableTransactions": true,
            "ProgramArguments": ["/usr/libexec/afcd"], "UserName": "mobile",
        ]
        try Self.put(
            try PropertyListSerialization.data(
                fromPropertyList: ["com.apple.afc": Self.stockAFC[2]],
                format: .binary,
                options: 0
            ),
            root,
            SystemEdits.lockdownServices
        )
        try Self.put(
            try PropertyListSerialization.data(fromPropertyList: stockJob, format: .binary, options: 0),
            root,
            SystemEdits.daemons + "/com.apple.afcd.plist"
        )
        let afcd = Self.afcd71()
        try Self.put(Data(afcd), root, SystemEdits.afcd)

        let added = try SystemEdits.installAFC2(root).root
        #expect(added == [SystemEdits.afc2d, SystemEdits.afc2Job])

        let services = try #require(NSDictionary(contentsOf: root.appendingPathComponent(SystemEdits.lockdownServices)))
        #expect(
            services["com.apple.afc2"] as? NSDictionary
                == ["AllowUnactivatedService": true, "Label": "com.apple.afc2", "XPCServiceName": "com.apple.afc2"]
        )
        #expect(services["com.apple.afc"] as? NSDictionary == NSDictionary(dictionary: Self.stockAFC[2]))

        let job = try #require(NSDictionary(contentsOf: root.appendingPathComponent(SystemEdits.afc2Job)))
        #expect(job["Label"] as? String == "com.apple.afc2")
        #expect(job["MachServices"] as? NSDictionary == ["com.apple.afc2": true])
        #expect(job["ProgramArguments"] as? [String] == ["/usr/libexec/afc2d"])
        #expect(job["UserName"] == nil, "afc2d runs as root")
        #expect(job["EnableTransactions"] as? Bool == true, "the rest of afcd's job is kept")

        let copy = try [UInt8](Data(contentsOf: root.appendingPathComponent(SystemEdits.afc2d)))
        func text(_ offset: Int, _ count: Int) -> [UInt8] { Array(copy[offset..<(offset + count)]) }
        #expect(text(48, 26) == Array("/".utf8) + [UInt8](repeating: 0, count: 25), "the root is /")
        #expect(text(80, 15) == Array("com.apple.afc2\0".utf8))
        #expect(text(100, 15) == Array("com.apple.afc2\0".utf8))
        #expect(copy[ActivationTests.cd + 12] == 0 && copy[ActivationTests.cd + 15] & 2 == 2, "signed ad hoc")
        let hash = ActivationTests.cd + 52
        #expect(Array(copy[hash..<(hash + 20)]) == Array(Insecure.SHA1.hash(data: Data(copy[0..<256]))))
        #expect(try Data(contentsOf: root.appendingPathComponent(SystemEdits.afcd)) == Data(afcd), "afcd is untouched")
        let mode =
            try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(SystemEdits.afc2d).path)[
                .posixPermissions
            ] as? Int
        #expect(mode == 0o755)
    }

    /// An afcd with neither --lockdown nor the 7.1 strings is refused rather than given an entry that cannot run.
    @Test func afc2NeedsAnAfcdItKnows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-afc2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.put(
            try PropertyListSerialization.data(
                fromPropertyList: ["com.apple.afc": Self.stockAFC[2]],
                format: .xml,
                options: 0
            ),
            root,
            SystemEdits.lockdownServices
        )
        try Self.put(
            try PropertyListSerialization.data(fromPropertyList: ["Label": "com.apple.afcd"], format: .xml, options: 0),
            root,
            SystemEdits.daemons + "/com.apple.afcd.plist"
        )
        try Self.put(Data(ActivationTests.syntheticMachO()), root, SystemEdits.afcd)
        #expect(throws: FirmwareError.self) { try SystemEdits.installAFC2(root) }
    }

    @Test func theOptionIsOffUnlessAskedFor() throws {
        func options(_ o: String) throws -> SystemEdits.Options {
            SystemEdits.Options(
                recipe: try JSONDecoder().decode(
                    FirmwareEntry.Recipe.self,
                    from: Data(
                        #"{"name": "n90", "version": 1, "storage": "16g", "system_mib": 1664, "data_size": "partition", "options": {\#(o)}}"#
                            .utf8
                    )
                ),
                version: "6.0"
            )
        }
        #expect(try options(#""jailbreak": true"#).jailbreak)
        #expect(try !options("").jailbreak)
    }
}

/// Cydia's bootstrap extracted into a system volume (SystemEdits.installCydia), from a small stand-in built here.
struct CydiaInstallTests {
    let fm = FileManager.default

    /// The bootstrap's dpkg status, Patcyh between two others, as freeze.tar's has it.
    static let status =
        "Package: apt7\nStatus: install ok installed\n\nPackage: com.saurik.patcyh\nVersion: 1.2.0\n\n"
        + "Package: bash\nStatus: install ok installed\n\n"

    /// A bootstrap laid out as freeze.tar is (the /etc link, mobile's SpringBoard preferences, a file the firmware
    /// also has, Patcyh), gzipped by /usr/bin/tar; beside it Substrate's and HTTPatch's packages as Legacy iOS Kit's
    /// tars hold them.
    func bootstrap(in dir: URL) throws -> URL {
        let src = dir.appendingPathComponent("src")
        for (rel, text) in [
            ("Applications/Cydia.app/Cydia", "cydia"), ("bin/bash", "bash"),
            ("private/var/lib/dpkg/status", Self.status), ("private/var/lib/dpkg/available", Self.status),
            ("usr/libexec/afcd", "not the firmware's"), ("private/var/Keychains/TrustStore.sqlite3", "roots"),
        ] + SystemEdits.Cydia.patcyh.map({ ($0, "patcyh") }) {
            let u = src.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        for (tar, rel) in [
            ("cydiasubstrate.tar", "private/var/root/Media/Cydia/AutoInstall/mobilesubstrate_fix.deb"),
            ("cydiahttpatch.tar", "private/var/root/Media/Cydia/AutoInstall/cydiahttpatch-1.0.deb"),
        ] {
            let pkg = dir.appendingPathComponent("pkg-" + tar)
            let u = pkg.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(tar.utf8).write(to: u)
            let p = try Process.run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-cf", dir.appendingPathComponent(tar).path, "-C", pkg.path, "."]
            )
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        // cydo, set-user-ID and set-group-ID root as freeze.tar has it
        let cydo = src.appendingPathComponent("usr/libexec/cydia/cydo")
        try fm.createDirectory(at: cydo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cydo".utf8).write(to: cydo)
        #expect(chmod(cydo.path, 0o6755) == 0)
        let prefs = src.appendingPathComponent(SystemEdits.Cydia.springBoardPrefs)
        try fm.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["SBShowNonDefaultSystemApps": true],
            format: .xml,
            options: 0
        ).write(to: prefs)
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("etc").path, withDestinationPath: "private/etc/")
        let file = dir.appendingPathComponent("freeze.tar.gz")
        let p = try Process.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", file.path, "-C", src.path, "."]
        )
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return file
    }

    /// A firmware root: /etc, afcd, /private/var/mobile, (with `prefs`) mobile's SpringBoard preferences and (with
    /// `version`) SystemVersion.plist.
    func firmware(in dir: URL, prefs: [String: Any]?, version: String? = nil) throws -> URL {
        let m = dir.appendingPathComponent("volume")
        for rel in ["private/etc", "usr/libexec", "private/var/mobile", "System/Library/CoreServices"] {
            try fm.createDirectory(at: m.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        if let version {
            try PropertyListSerialization.data(fromPropertyList: ["ProductVersion": version], format: .xml, options: 0)
                .write(to: m.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
        }
        try Data("stock afcd".utf8).write(to: m.appendingPathComponent("usr/libexec/afcd"))
        try fm.createSymbolicLink(atPath: m.appendingPathComponent("etc").path, withDestinationPath: "private/etc")
        if let prefs {
            let u = m.appendingPathComponent(SystemEdits.Cydia.springBoardPrefs)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0).write(to: u)
        }
        return m
    }

    func springBoard(_ m: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: m.appendingPathComponent(SystemEdits.Cydia.springBoardPrefs))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func cydiaLandsBesideTheFirmwaresOwnFiles() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: nil)
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        let cydia = m.appendingPathComponent("Applications/Cydia.app/Cydia")
        #expect(try String(contentsOf: cydia, encoding: .utf8) == "cydia")
        #expect(
            try String(contentsOf: m.appendingPathComponent("usr/libexec/afcd"), encoding: .utf8) == "stock afcd",
            "a file the firmware has is kept"
        )
        #expect(try springBoard(m)["SBShowNonDefaultSystemApps"] as? Bool == true)
        #expect(fm.fileExists(atPath: m.appendingPathComponent(".cydia_no_stash").path), "no stash on first launch")
        #expect(!fm.fileExists(atPath: m.appendingPathComponent("private/var/Keychains").path), "no trust store")
        #expect(!r.root.contains { $0.hasPrefix("private/var/Keychains") })
        for rel in [
            ".cydia_no_stash", "Applications", "Applications/Cydia.app/Cydia", "bin/bash",
            "private/var/lib/dpkg/status",
            "etc",
        ] {
            #expect(r.root.contains(rel), "\(rel) is root's")
        }
        for rel in ["usr/libexec", "usr/libexec/afcd", "private/var/mobile"] {
            #expect(!r.root.contains(rel) && !r.mobile.contains(rel), "the firmware's \(rel) keeps its owner")
        }
        #expect(
            Set(r.mobile) == [
                "private/var/mobile/Library", "private/var/mobile/Library/Preferences",
                SystemEdits.Cydia.springBoardPrefs,
            ]
        )
    }

    /// cydo, which Cydia runs for every root operation (dpkg, the /etc/apt/sources.list.d/cydia.list link), keeps its
    /// set-user-ID bit: tar, not root, drops it, so the catalog gets the archive's mode.
    @Test func cydoKeepsItsSetUserIDMode() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: nil)
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        #expect(r.modes.map(\.path) == ["usr/libexec/cydia/cydo"])
        #expect(r.modes.first?.mode == 0o6755)
        #expect(r.root.contains("usr/libexec/cydia/cydo"))
    }

    @Test func setUserIDLinesOfATarListing() {
        #expect(
            SystemEdits.specialMode("-rwsr-sr-x  0 root   wheel  133808 Feb 15  2017 ./usr/libexec/cydia/cydo")! == (
                "usr/libexec/cydia/cydo", 0o6755
            )
        )
        #expect(
            SystemEdits.specialMode("-r-sr-xr-x  0 root   wheel  105744 Oct 13  2015 ./bin/su")! == ("bin/su", 0o4555)
        )
        #expect(SystemEdits.specialMode("-rwxr-xr-x  0 root   wheel  1 Oct 13  2015 ./bin/bash") == nil)
        #expect(SystemEdits.specialMode("drwxrwsr-x  0 root   authedusers  0 Oct 28  2006 ./private/var/local/") == nil)
        #expect(SystemEdits.specialMode("-rwsr-xr-x  0 root  wheel  9 Oct 13  2015 ./a b")! == ("a b", 0o4755))
    }

    /// Cydia's first launch takes its sources from metadata.plist (Version 1: none of its 1.1.30 defaults added), so
    /// none of the dead ones (apt.modmyi.com, cydia.zodttd.com, repo666.ultrasn0w.com) is ever refreshed.
    @Test func cydiasSourcesAreTheOnesThatAnswerToday() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: nil)
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        let u = m.appendingPathComponent("private/var/lib/cydia/metadata.plist")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: u), format: nil) as? [String: Any]
        )
        #expect(plist["Version"] as? Int == 1)
        let sources = try #require(plist["Sources"] as? [String: [String: Any]])
        #expect(
            Set(sources.keys) == [
                "deb:http://apt.thebigboss.org/repofiles/cydia/:stable", "deb:http://modmyi.saurik.com/:stable",
                "deb:http://zodttd.saurik.com/repo/cydia/:stable",
            ]
        )
        for (key, source) in sources {
            #expect(key == "deb:\(source["URI"] as? String ?? ""):stable" && source["Type"] as? String == "deb")
            #expect(source["Sections"] as? [String] == ["main"] && source["Distribution"] as? String == "stable")
        }
        #expect(try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int == 0o644, "mobile reads it")
        #expect(r.root.contains("private/var/lib/cydia/metadata.plist"))
    }

    @Test func theFirmwaresSpringBoardPreferencesGainTheKey() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: ["SBAutoLockTime": 60])
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        let prefs = try springBoard(m)
        #expect(prefs["SBShowNonDefaultSystemApps"] as? Bool == true)
        #expect(prefs["SBAutoLockTime"] as? Int == 60)
        #expect(r.mobile.isEmpty, "mobile's own preferences keep their owner")
    }

    /// Substrate's AutoInstall package on 3.x to 6.x and HTTPatch's on 3.x, as Legacy iOS Kit's restores add them
    /// (and 6.x, which its restores leave to Cydia); none on 7.x; Patcyh (iOS 8.3 and later) out of the files and
    /// dpkg's records everywhere.
    @Test(arguments: ["3.1.3", "4.2.1", "5.1.1", "6.1.6", "7.1.2"])
    func substrateAndHTTPatchByVersion(_ version: String) throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let m = try firmware(in: dir, prefs: nil, version: version)
        let r = try SystemEdits.installCydia(m, bootstrap: try bootstrap(in: dir))
        let major = Int(version.prefix(1)) ?? 0
        let auto = "private/var/root/Media/Cydia/AutoInstall/"
        for (deb, wanted) in [
            ("mobilesubstrate_fix.deb", (3...6).contains(major)), ("cydiahttpatch-1.0.deb", major == 3),
        ] {
            #expect(fm.fileExists(atPath: m.appendingPathComponent(auto + deb).path) == wanted, "\(version): \(deb)")
            #expect(r.root.contains(auto + deb) == wanted, "\(version): \(deb) is root's")
        }
        for rel in SystemEdits.Cydia.patcyh {
            #expect(!fm.fileExists(atPath: m.appendingPathComponent(rel).path), "\(version): \(rel) is gone")
            #expect(!r.root.contains(rel))
        }
        for rel in ["private/var/lib/dpkg/status", "private/var/lib/dpkg/available"] {
            let text = try String(contentsOf: m.appendingPathComponent(rel), encoding: .utf8)
            #expect(
                text
                    == "Package: apt7\nStatus: install ok installed\n\nPackage: bash\nStatus: install ok installed\n\n",
                "\(version): \(rel) without Patcyh"
            )
        }
    }

    @Test func aBootstrapOfOtherBytesIsRefused() throws {
        let dir = fm.temporaryDirectory.appendingPathComponent("ltm-cydia-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        #expect(throws: FirmwareError.self) {
            try SystemEdits.Cydia.bootstrap(in: dir) { _, file in try Data("not freeze.tar".utf8).write(to: file) }
        }
        #expect((try? fm.contentsOfDirectory(atPath: dir.path)) == [], "nothing is left in the cache")
    }
}
