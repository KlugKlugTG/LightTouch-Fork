import Foundation
import Testing

@testable import FirmwareKit

/// The fixtures' inputs: the decrypt cache's rootfs.dmg, the qemu-ios helper build outputs (contrib/*/build.sh)
/// and the GL name table. Everything is read in place; outputs go to temp dirs.
enum K48Oracle {
    static let qemu = Oracle.qemuIOS
    /// helpers-dir name -> qemu-ios file.
    static var sources: [String: URL] {
        let guest = qemu.appendingPathComponent("build/ipad1-guest")
        let contrib = qemu.appendingPathComponent("contrib")
        var m: [String: URL] = [:]
        for t in SystemEdits.Helpers.tools.map(\.name) + ["it_seal", "it_gltest"] {
            m[t] = guest.appendingPathComponent(t)
        }
        for (j, d) in [
            ("com.qemu.it-pbd.plist", "it-pasteboard"), ("com.qemu.it-prefs.plist", "it-prefs"),
            ("com.qemu.it-seal.plist", "it-seal"),
            ("com.qemu.it-gltest.plist", "it-gltest"),
        ] {
            m[j] = contrib.appendingPathComponent("\(d)/\(j)")
        }
        m["libappsync.dylib"] = qemu.appendingPathComponent("build/appsync/libappsync.dylib")
        m["OpenGLES"] = contrib.appendingPathComponent("gles-public/OpenGLES")
        m["gles-names.h"] = qemu.appendingPathComponent("include/hw/arm/guest-services/gles-names.h")
        m[SystemEdits.Helpers.itpack] = Oracle.guestPackages.appendingPathComponent("armv7.itpack")
        return m
    }

    static var available: Bool { sources.values.allSatisfy(Oracle.exists) }

    /// FIRMWAREKIT_GUEST_TOOLS: a flat guest-tools directory (build-guest-tools.sh's ipad-guest-tools, or the app's
    /// Resources/guest-tools) that stands in for the qemu-ios build outputs where those aren't built.
    static let guestTools = ProcessInfo.processInfo.environment["FIRMWAREKIT_GUEST_TOOLS"].map {
        URL(fileURLWithPath: $0)
    }

    /// A helpers directory of symlinks to the qemu-ios build outputs.
    static func helpers(in dir: URL) throws -> URL {
        let h = dir.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        for (n, u) in sources {
            try FileManager.default.createSymbolicLink(at: h.appendingPathComponent(n), withDestinationURL: u)
        }
        return h
    }

    static func sh(_ args: [String], cwd: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw FirmwareError(.internal, "\(args.prefix(3)): \(String(decoding: e.suffix(2000), as: UTF8.self))")
        }
    }
}

@Suite(.serialized, .detachesItsImages) struct SystemEditsTests {
    /// ipad1_rootfs FSTAB_RO: only the root line turns ro (7.x), /private/var stays rw.
    @Test func fstabRO() {
        #expect(SystemEdits.fstabRO == "/dev/disk0s1 / hfs ro 0 1\n/dev/disk0s2 /private/var hfs rw,nosuid,nodev 0 2\n")
    }

    /// A dated build's data volume leaves timed alone (its network answers NTP in the device's time): no
    /// com.apple.timed switches, which on 6.x and 7.x would drop lockdown's zone; its ark says unbricked.
    @Test func datedLeavesTimedAlone() throws {
        let skeleton = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-dated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: skeleton) }
        var o = SystemEdits.Options()
        o.dated = true
        try SystemEdits.seedData(skeleton, o, productMajor: 7, dataArk: ["-ActivationState": "Unactivated"]) { _ in }
        let timed = skeleton.appendingPathComponent("mobile/Library/Preferences/com.apple.timed.plist")
        #expect(!FileManager.default.fileExists(atPath: timed.path), "timed keeps automatic time and zone on")
        let ark =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: skeleton.appendingPathComponent("root/Library/Lockdown/data_ark.plist")),
                format: nil
            ) as? [String: Any]
        #expect(ark?["-BrickState"] as? Bool == false)
    }

    /// 6.x's asset preinstall, as mobileassetd leaves it on a sealed n81ap 10B500: each asset for this unit's region
    /// (here none of a font's) at Assets/<type>/<hash>.asset/<hash>, the catalog without FormatVersion and each asset
    /// Verifying, the completion marker, PreinstalledAssets gone. Not before 6.
    @Test func preinstalledAssetsAsMobileassetdLeavesThem() throws {
        let fm = FileManager.default
        let skeleton = fm.temporaryDirectory.appendingPathComponent("ltm-assets-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: skeleton) }
        let source = skeleton.appendingPathComponent(SystemEdits.preinstalledAssets)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        func odc(_ members: [(String, Data)]) -> Data {
            var d = Data()
            for (name, body) in members + [("TRAILER!!!", Data())] {
                let n = name.utf8.count + 1
                d += Data(String(format: "070707%06o%06o%06o%06o%06o%06o%06o%011o%06o%011o", 0, 0, 0o100644, 0, 0, 1, 0, 0, n, body.count).utf8)
                d += Data(name.utf8) + Data([0]) + body
            }
            return d
        }
        func catalog(_ type: String, _ assets: [[String: Any]]) throws -> Data {
            try PropertyListSerialization.data(
                fromPropertyList: ["AssetType": type, "Assets": assets, "FormatVersion": 1], format: .xml, options: 0)
        }
        let dict = "com_apple_MobileAsset_DictionaryServices_dictionary", font = "com_apple_MobileAsset_Font"
        try odc([
            ("./aa.cpio", Data("dictionary aa".utf8)), ("./bb.cpio", Data("dictionary bb".utf8)),
            ("./\(dict).plist", try catalog("d", [["__RelativePath": "\(dict)/aa.cpio"], ["__RelativePath": "\(dict)/bb.cpio"]])),
        ]).write(to: source.appendingPathComponent(dict + ".cpio"))
        try odc([
            ("./cc.cpio", Data("font".utf8)),
            ("./\(font).plist", try catalog("f", [["__RelativePath": "\(font)/cc.cpio", "__PreinstallRegionCodes": ["CH"]]])),
        ]).write(to: source.appendingPathComponent(font + ".cpio"))

        #expect(try SystemEdits.seedPreinstalledAssets(skeleton, major: 5, version: "5.1.1", build: "9B206", region: "LL") == nil)
        let installed = try SystemEdits.seedPreinstalledAssets(skeleton, major: 6, version: "6.1.6", build: "10B500", region: "LL")
        #expect(installed == ["\(dict)/aa", "\(dict)/bb"])
        let assets = skeleton.appendingPathComponent(SystemEdits.assets)
        #expect(try Data(contentsOf: assets.appendingPathComponent("\(dict)/bb.asset/bb")) == Data("dictionary bb".utf8))
        let out = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: assets.appendingPathComponent("\(dict)/\(dict).plist")), format: nil) as? [String: Any]
        #expect(out?["FormatVersion"] == nil && out?["AssetType"] as? String == "d")
        #expect((out?["Assets"] as? [[String: Any]])?.map { $0["__DownloadState"] as? String } == ["Verifying", "Verifying"])
        #expect(!fm.fileExists(atPath: assets.appendingPathComponent(font).path), "fonts are China, Taiwan and Hong Kong units' only")
        let done = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: assets.appendingPathComponent("preinstall-is-complete.plist")), format: nil) as? [String: String]
        #expect(done == ["BuildVersion": "10B500", "ProductVersion": "6.1.6"])
        #expect(!fm.fileExists(atPath: source.path))
    }

    /// A pinned clock (recipe rtc_epoch, a developer beta) makes the build dated.
    @Test func datedFromRTCEpoch() throws {
        func recipe(_ extra: String) throws -> FirmwareEntry.Recipe {
            try JSONDecoder().decode(
                FirmwareEntry.Recipe.self,
                from: Data(
                    #"{"name": "n90", "version": 1, "storage": "16g", "system_mib": 1664, "data_size": "partition", "boot": "kboot", "options": {}\#(extra)}"#
                        .utf8
                )
            )
        }
        #expect(SystemEdits.Options(recipe: try recipe(#", "rtc_epoch": 1371297600"#), version: "6.0").dated)
        #expect(!SystemEdits.Options(recipe: try recipe(""), version: "6.0").dated)
    }

    /// skip_setup: the keys Setup Assistant itself left on walked devices (the data volume diffed before and after the
    /// sessions harness's walk: n81ap/k48ap 9B206 for 5.x, n90ap 10B329 for 6.x, n90ap 11D257 for 7.x), seeded into the
    /// /private/var skeleton, merged with what is there; the Mac's language moved first. Nothing before iOS 5.
    @Test(arguments: [4, 5, 6, 7]) func finishedSetupSeedsWhatSetupWrites(major: Int) throws {
        let skeleton = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-setup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: skeleton) }
        let global = skeleton.appendingPathComponent(SystemEdits.globalPreferences)
        try FileManager.default.createDirectory(
            at: global.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: ["AppleLanguages": ["en", "fr", "de"], "AppleLocale": "en_US"],
            format: .binary,
            options: 0
        ).write(to: global)
        func options(_ o: String) throws -> SystemEdits.Options {
            SystemEdits.Options(
                recipe: try JSONDecoder().decode(
                    FirmwareEntry.Recipe.self,
                    from: Data(
                        #"{"name": "n90", "version": 1, "storage": "16g", "system_mib": 1664, "data_size": "partition", "boot": "kboot", "options": {\#(o)}}"#
                            .utf8
                    )
                ),
                version: "6.0"
            )
        }
        #expect(try options(#""skip_setup": true"#).skipSetup && !options("").skipSetup, "off unless asked for")
        let (language, locale, _) = try #require(try SystemEdits.seedLanguage(skeleton, tag: "fr-CA"))
        try SystemEdits.seedFinishedSetup(skeleton, major: major, language: language, locale: locale)
        func plist(_ path: String) -> [String: Any] {
            (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: skeleton.appendingPathComponent(path)),
                format: nil
            )) as? [String: Any] ?? [:]
        }
        func keys(_ path: String) -> Set<String> { Set(plist(path).keys) }
        let mobile = "mobile/Library/Preferences/"
        if major < 5 {
            #expect(keys(mobile + "com.apple.purplebuddy.plist").isEmpty)
            return
        }
        let common: Set = [
            "SetupDone", "SetupFinishedAllSteps", "RestoreChoice", "PBTCPresented", "PBDiagnosticsPresented",
            "WiFiPresented", "Language", "Locale",
        ]
        let buddy: [Int: Set<String>] = [
            5: common.union(["AppleIDPresented"]), 6: common.union(["AppleIDPB3Presented", "SetupVersion"]),
            7: common.union([
                "AppleIDPB5Presented", "PasscodePresented", "SetupVersion", "SetupState", "AppleIDForceUpgrade",
            ]),
        ]
        #expect(keys(mobile + "com.apple.purplebuddy.plist") == buddy[major])
        #expect(plist(mobile + "com.apple.purplebuddy.plist")["SetupVersion"] as? Int == [6: 3, 7: 5][major])
        #expect(plist(mobile + "com.apple.purplebuddy.plist")["Locale"] as? String == "fr_CA")
        #expect(
            keys(mobile + "com.apple.purplebuddy.notbackedup.plist")
                == (major == 7
                    ? ["LocationServices2Presented", "CloudConfigPresented"] : ["LocationServicesPresented"])
        )
        let off = major == 7 ? "LocationServicesEnabledIn7.0" : "LocationServicesEnabled"
        for name in ["com.apple.locationd.plist", "com.apple.locationd.notbackedup.plist"] {
            #expect(plist(mobile + name)[off] as? Int == 0, "\(name): Location Services off")
        }
        #expect(
            plist("mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist")[
                "CloudConfigurationUIComplete"
            ]
                as? Bool == (major == 7 ? true : nil),
            "7.x: the cloud configuration step done"
        )
        #expect(
            keys(mobile + "com.apple.mobile.user_preferences.plist")
                == (major == 7 ? ["UserSetLanguage", "UserSetLocale"] : [])
        )
        let g = plist(SystemEdits.globalPreferences)
        #expect(g["AppleLocale"] as? String == "fr_CA" && g["AppleLanguages"] as? [String] == ["fr", "en", "de"])
        #expect(
            keys(SystemEdits.dataArk)
                == (major == 7
                    ? [
                        "-ActivationStateAcknowledged", "com.apple.mobile.chaperone-NotSoFresh",
                        "-FirstPurpleBuddyCompletion",
                    ]
                    : [
                        "com.apple.purplebuddy-SetupState", "com.apple.mobile.user_preferences-UserSetLanguage",
                        "com.apple.mobile.user_preferences-UserSetLocale",
                    ])
        )
    }

    /// Every prepared device gets the Mac's language (or `create --language`'s) as its firmware has it: the first
    /// preferred language the firmware's own AppleLanguages lists, else the next, else English, with the region.
    @Test func deviceLanguageIsTheFirstPreferredOneTheFirmwareHas() throws {
        // AppleLanguages as each rootfs ships it in /private/var/mobile/Library/Preferences/.GlobalPreferences.plist.
        let v114 = [
            "en", "fr", "de", "ja", "nl", "it", "es", "pt-PT", "da", "fi", "nb", "sv", "ko", "zh-Hans", "zh-Hant", "ru",
            "pl",
        ]
        let v313 =
            v114.filter { $0 != "pt-PT" }
            + ["pt", "pt-PT", "tr", "uk", "ar", "hr", "cs", "el", "he", "ro", "sk", "th", "id", "ms"]
        let v421 = v313 + ["en-GB", "ca", "hu", "vi"]  // 4.2.1 and 6.1.3
        let v712 = v421 + ["es-MX", "en-AU"]
        func pick(_ list: [String], _ preferred: [String], _ region: String? = nil) -> String {
            let l = SystemEdits.deviceLanguage(supported: list, preferred: preferred, region: region)
            return region == nil ? l.language : "\(l.language) \(l.locale)"
        }
        #expect(pick(v421, ["de-DE"], "DE") == "de de_DE")
        #expect(pick(v421, ["fr-CA"], "CA") == "fr fr_CA")
        #expect(pick(v421, ["zh-Hans-CN"], "CN") == "zh-Hans zh_CN")
        #expect(pick(v421, ["zh-Hant-TW"]) == "zh-Hant" && pick(v421, ["zh-HK"]) == "zh-Hant")
        #expect(pick(v421, ["pt-BR"]) == "pt" && pick(v421, ["pt-PT"]) == "pt-PT" && pick(v114, ["pt-BR"]) == "pt-PT")
        #expect(pick(v421, ["nb-NO"]) == "nb" && pick(v421, ["no"]) == "nb")
        #expect(pick(v421, ["en-GB"], "GB") == "en-GB en_GB" && pick(v313, ["en-GB"]) == "en")
        #expect(pick(v712, ["en-AU"]) == "en-AU" && pick(v421, ["en-AU"]) == "en-GB" && pick(v421, ["en-US"]) == "en")
        #expect(pick(v712, ["es-MX"]) == "es-MX" && pick(v421, ["es-MX"]) == "es" && pick(v421, ["es-419"]) == "es")
        #expect(pick(v421, ["vi-VN", "fr-FR"]) == "vi" && pick(v313, ["vi-VN", "fr-FR"]) == "fr", "down the list")
        #expect(pick(v421, ["hi-IN"], "IN") == "en en_IN" && pick(v313, ["ca-ES"]) == "en", "else English")
        #expect(SystemEdits.deviceLanguage(supported: v421, preferred: ["fr"], region: nil).locale == "fr")

        // Every prepared device, Skip Setup or not: the firmware's list with the language first, and the region.
        let skeleton = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-lang-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: skeleton) }
        let global = skeleton.appendingPathComponent(SystemEdits.globalPreferences)
        try FileManager.default.createDirectory(
            at: global.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: ["AppleLanguages": v421, "AppleLocale": "en_US"],
            format: .binary,
            options: 0
        ).write(to: global)
        var o = SystemEdits.Options()
        o.webProxy = false
        o.language = "de-DE"
        try SystemEdits.seedData(skeleton, o, productMajor: 4, dataArk: nil) { _ in }
        let g = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: global), format: nil) as? [String: Any]
        )
        #expect(g["AppleLanguages"] as? [String] == ["de"] + v421.filter { $0 != "de" })
        #expect(g["AppleLocale"] as? String == "de_DE")
    }

    /// An ICU common data file (icudt42l.dat's shape) whose table of contents names `entries`.
    static func icuData(_ entries: [String]) -> Data {
        // header size 32, magic, the data info's size, little-endian ASCII, its format, the rest zero
        var d = Data([32, 0, 0xDA, 0x27, 20, 0, 0, 0, 0, 0, 2, 0] + Array("CmnD".utf8))
        d.append(contentsOf: [UInt8](repeating: 0, count: 16))
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(entries.count)
        var names = Data()
        for e in entries {
            u32(4 + entries.count * 8 + names.count)
            u32(0)
            names.append(contentsOf: Array(e.utf8) + [0])
        }
        return d + names
    }

    /// AppleLocale is the Mac's own locale (or `create --language`'s) where the firmware offers it as a region format,
    /// whatever the device's language: 3.2's iPad has no Ukrainian, but its Region Format has Ukrainian (Ukraine).
    @Test func deviceLocaleIsTheMacsWhereTheFirmwareHasTheRegionFormat() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ltm-icu-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let icu = root.appendingPathComponent("usr/share/icu")
        try fm.createDirectory(at: icu, withIntermediateDirectories: true)
        #expect(SystemEdits.regionFormats(root) == nil, "no ICU data")
        try Self.icuData([
            "icudt42l/res_index.res", "icudt42l/en.res", "icudt42l/en_US.res", "icudt42l/uk.res",
            "icudt42l/uk_UA.res", "icudt42l/sr_Latn_RS.res", "icudt42l/coll/hi_IN.res", "icudt42l/cnvalias.icu",
        ]).write(to: icu.appendingPathComponent("icudt42l.dat"))
        let formats = try #require(SystemEdits.regionFormats(root))
        #expect(formats.isSuperset(of: ["en", "en_US", "uk", "uk_UA", "sr_Latn_RS"]))
        #expect(!formats.contains("hi_IN") && !formats.contains("cnvalias.icu"), "only top-level locales")

        // 3.2.2's AppleLanguages
        let v322 = ["en", "fr", "de", "ja", "nl", "it", "es", "zh-Hans", "ru"]
        func pick(_ preferred: String, _ region: String, _ locale: String) -> String {
            let l = SystemEdits.deviceLanguage(
                supported: v322,
                preferred: [preferred],
                region: region,
                locale: locale,
                formats: formats
            )
            return "\(l.language) \(l.locale)"
        }
        #expect(pick("uk-UA", "UA", "uk_UA") == "en uk_UA")
        #expect(pick("ru-UA", "UA", "ru_UA") == "ru ru_UA", "a firmware without the format: language and region")
        #expect(pick("hi-IN", "IN", "hi_IN") == "en en_IN")
        #expect(pick("fr-FR", "FR", "fr_FR") == "fr fr_FR")
        #expect(SystemEdits.deviceLanguage(supported: v322, preferred: ["uk-UA"], region: "UA").locale == "en_UA")

        // The Mac's locale is the user's AppleLocale preference, not Locale.current (the app's language in an app
        // localized only in English); an explicit language wins.
        #expect(SystemEdits.deviceLocale(tag: nil, appleLocale: "uk_UA") == "uk_UA")
        #expect(SystemEdits.deviceLocale(tag: nil, appleLocale: "sr-Latn_RS@calendar=gregorian") == "sr_Latn_RS")
        #expect(SystemEdits.deviceLocale(tag: "fr-CA", appleLocale: "uk_UA") == "fr_CA")

        // seedLanguage, from an explicit language as from the Mac's
        let skeleton = root.appendingPathComponent("var")
        let global = skeleton.appendingPathComponent(SystemEdits.globalPreferences)
        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["AppleLanguages": v322, "AppleLocale": "en_US"],
            format: .binary,
            options: 0
        ).write(to: global)
        let seeded = try #require(try SystemEdits.seedLanguage(skeleton, tag: "uk-UA", formats: formats))
        #expect(seeded.language == "en" && seeded.locale == "uk_UA")
        let g = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: global), format: nil) as? [String: Any]
        )
        #expect(g["AppleLocale"] as? String == "uk_UA" && g["AppleLanguages"] as? [String] == v322)
    }

    /// Each firmware's ICU data, read from its own rootfs: Ukrainian (Ukraine) is a region format from 1.0 on.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: [("7B500", "icudt42l.dat"), ("5H11a", "icudt36l.dat"), ("1A543a", "icudt34l.dat")]
    )
    func regionFormatsOfRealFirmware(build: String, icu: String) throws {
        guard Fixtures.hasRootfs(build) else {
            try FixtureRequirements.missing("SystemEditsTests.swift: Fixtures.hasRootfs(\(build))")
        }
        let dir = try Fixtures.tempDir("icu")
        let root = dir.appendingPathComponent("root/usr/share/icu")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dat = try Fixtures.extract(build: build, paths: ["usr/share/icu/" + icu], to: dir)[0]
        try FileManager.default.moveItem(at: dat, to: root.appendingPathComponent(icu))
        let formats = try #require(SystemEdits.regionFormats(dir.appendingPathComponent("root")))
        #expect(formats.isSuperset(of: ["uk_UA", "en_US", "fr_FR"]) && !formats.contains("en_UA"))
    }

    /// AppleKeyboards: the device language's keyboard first, then the Mac's keyboards as the firmware names them (its
    /// TextInput bundles), named as its own defaults name them, and nothing it lacks.
    @Test func keyboardsAreTheLanguagesThenTheMacsTheFirmwareHas() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ltm-kb-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        /// A TextInput directory of `bundles` (name: supported modes) and 5.x+'s language defaults.
        func catalog(
            _ name: String,
            _ bundles: [String: [String: [String: Any]]],
            defaults: [String: [String]] = [:]
        ) throws -> SystemEdits.KeyboardCatalog {
            let dir = root.appendingPathComponent(name)
            for (bundle, modes) in bundles {
                let b = dir.appendingPathComponent("TextInput_\(bundle).bundle")
                try fm.createDirectory(at: b, withIntermediateDirectories: true)
                let info: [String: Any] = [
                    "UIKeyboardSupportedInputModes": modes,
                    "UIKeyboardDefaultLanguageInputModes": defaults.filter { $0.key.hasPrefix(bundle) },
                ]
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                    .write(to: b.appendingPathComponent("Info.plist"))
            }
            return try #require(SystemEdits.KeyboardCatalog(dir))
        }
        // 3.1.3's shape: layout classes, two QWERTY variants of en_US.
        func layout(_ c: String) -> [String: Any] { ["UIKeyboardLayoutClass": ["Portrait": c, "Landscape": c + "L"]] }
        let v313 = try catalog(
            "313",
            [
                "en": ["en_GB": layout("QWERTY"), "en_US-BigBear": layout("QWERTY"), "en_US-Zephyr": layout("QWERTY")],
                "fr": ["fr_CA": layout("QWERTY"), "fr_CH": layout("QWERTY"), "fr_FR": layout("AZERTY")],
                "ja": ["ja_JP-Kana": layout("Japanese3x3"), "ja_JP-Romaji": layout("QWERTY_ja_JP")],
                "zh": ["zh_Hans-HWR": layout("HWR"), "zh_Hans-Pinyin": layout("Pinyin"), "zh_Hant-HWR": layout("HWR")],
                "emoji": ["emoji": layout("Emoji")],
            ]
        )
        // 7.1.2's shape: hardware and software layouts, and the language defaults.
        func hwsw(_ sw: [String], _ hw: [String] = [], _ hardware: String? = nil) -> [String: Any] {
            var m: [String: Any] = ["SWLayouts": sw]
            if !hw.isEmpty { m["HWLayouts"] = hw }
            if let hardware { m["Hardware"] = ["Layout": hardware, "USBCountry": 8] }
            return m
        }
        let v712 = try catalog(
            "712",
            [
                "en": [
                    "en_US": hwsw(["QWERTY", "AZERTY"], ["US", "British", "French"], "US"),
                    "en_GB": hwsw(["QWERTY"], ["British", "US"], "British"),
                ],
                "fr": [
                    "fr_FR": hwsw(["AZERTY-French", "AZERTY"], ["French", "French - numerical", "US"], "French"),
                    "fr_CA": hwsw(["QWERTY-Accents"], ["Canadian - CSA", "French", "US"], "Canadian - CSA"),
                ],
                "ja": [
                    "ja_JP": hwsw(["Kana", "Kana-Flick"]), "ja_JP-Kana": hwsw(["Kana"], ["US", "KANA"]),
                    "ja_JP-Romaji": hwsw(["QWERTY-Japanese"], ["US", "French"], "US"),
                ],
                "zh": ["zh_Hans-HWR": hwsw(["HWR"]), "zh_Hans-Pinyin": hwsw(["Pinyin"], ["US"], "US")],
                "emoji": ["emoji": hwsw(["Emoji"])],
            ],
            defaults: [
                "en": ["en_US"], "en_GB": ["en_GB"], "fr_FR": ["fr_FR"],
                "ja": ["ja_JP-Kana", "ja_JP-Romaji", "emoji", "en_US"],
            ]
        )
        typealias K = SystemEdits.MacKeyboard
        let french = K(id: "com.apple.keylayout.French", languages: ["fr", "acf"], layout: true)
        let swissFrench = K(id: "com.apple.keylayout.SwissFrench", languages: ["fr"], layout: true)
        let us = K(id: "com.apple.keylayout.US", languages: ["en", "fr"], layout: true)
        let british = K(id: "com.apple.keylayout.British", languages: ["en"], layout: true)
        let kana = K(id: "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese", languages: ["ja"], name: "Hiragana")
        let romaji = K(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese.Katakana", languages: ["ja"])
        let pinyin = K(id: "com.apple.inputmethod.SCIM.ITABC", languages: ["zh-Hans"], name: "Pinyin - Simplified")
        let korean = K(id: "com.apple.inputmethod.Korean.2SetKorean", languages: ["ko"], name: "2-Set Korean")
        let emoji = K(id: SystemEdits.emojiPalette, languages: ["en"])

        #expect(
            v313.keyboards(language: "fr", locale: "fr_FR", mac: [french, kana, us, korean, pinyin, emoji])
                == ["fr_FR", "ja_JP-Kana", "en_US", "zh_Hans-Pinyin", "emoji"]
        )
        #expect(
            v313.keyboards(language: "ja", locale: "ja_JP", mac: [romaji, us]) == [
                "ja_JP-Kana", "ja_JP-Romaji", "en_US",
            ]
        )
        #expect(
            v313.keyboards(language: "en", locale: "en_US", mac: []) == ["en_US"],
            "the built-in iPod: English only"
        )
        #expect(v313.keyboards(language: "fr", locale: "fr_CA", mac: []) == ["fr_CA"])
        // A region format in another language than the device's (3.2's English with uk_UA): the language's keyboard.
        #expect(v313.keyboards(language: "en", locale: "uk_UA", mac: []) == ["en_US"])
        #expect(v712.keyboards(language: "en", locale: "uk_UA", mac: [us]) == ["en_US@hw=US"])
        #expect(
            v712.keyboards(language: "fr", locale: "fr_FR", mac: [french, kana, us])
                == ["fr_FR@hw=French", "ja_JP-Kana", "en_US@hw=US"]
        )
        #expect(
            v712.keyboards(language: "en", locale: "en_US", mac: [british, us, pinyin, emoji, korean])
                == ["en_US@hw=US", "en_GB@hw=British", "zh_Hans-Pinyin", "emoji"]
        )
        #expect(
            v712.keyboards(language: "ja", locale: "ja_JP", mac: [french])
                == ["ja_JP-Kana", "ja_JP-Romaji", "emoji", "en_US", "fr_FR@hw=French"]
        )
        // A Mac layout the keyboard does not list as a hardware layout: the bare keyboard, its own.
        #expect(v712.keyboards(language: "en", locale: "en_US", mac: [swissFrench]) == ["en_US", "fr_FR"])

        // seedLanguage writes them beside the language, from the explicit keyboards (none here: the language's own).
        let skeleton = root.appendingPathComponent("var")
        let global = skeleton.appendingPathComponent(SystemEdits.globalPreferences)
        try fm.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["AppleLanguages": ["en", "fr", "ja"], "AppleLocale": "en_US"],
            format: .binary,
            options: 0
        ).write(to: global)
        let seeded = try #require(try SystemEdits.seedLanguage(skeleton, tag: "ja-JP", keyboards: [], catalog: v712))
        let g = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: global), format: nil) as? [String: Any]
        )
        #expect(g["AppleKeyboards"] as? [String] == seeded.keyboards && seeded.keyboards.first == "ja_JP-Kana")
    }

    @Test func plistEdits() throws {
        let real = NSMutableDictionary(dictionary: [
            "CurrentSet": "/Sets/S", "NetworkServices": ["W": ["Interface": ["DeviceName": "en0"]]],
            "Sets": ["S": ["Network": ["Global": ["IPv4": ["ServiceOrder": ["W"]]], "Service": ["W": [:]]]]],
        ])
        let d =
            try PropertyListSerialization.propertyList(
                from: PropertyListSerialization.data(fromPropertyList: real, format: .xml, options: 0),
                options: .mutableContainersAndLeaves,
                format: nil
            ) as! NSMutableDictionary
        SystemEdits.wifiProxyPrefs(d)
        SystemEdits.wifiProxyPrefs(d)
        let net = ((d["Sets"] as! NSDictionary)["S"] as! NSDictionary)["Network"] as! NSDictionary
        #expect(
            ((net["Global"] as! NSDictionary)["IPv4"] as! NSDictionary)["ServiceOrder"] as! [String]
                == [SystemEdits.wifiService, "W"]
        )
        let fresh = NSMutableDictionary()
        SystemEdits.wifiProxyPrefs(fresh)
        #expect(
            ((fresh["Sets"] as! NSDictionary)[SystemEdits.netSet] as? NSDictionary)?["UserDefinedName"] as? String
                == "Automatic"
        )
        let env = NSMutableDictionary(dictionary: [
            "EnvironmentVariables": NSMutableDictionary(dictionary: ["DYLD_INSERT_LIBRARIES": "/a.dylib"])
        ])
        SystemEdits.dyldInsert(env, "/b.dylib")
        SystemEdits.dyldInsert(env, "/b.dylib")
        #expect(
            (env["EnvironmentVariables"] as! NSDictionary)["DYLD_INSERT_LIBRARIES"] as? String == "/a.dylib:/b.dylib"
        )
    }

    /// GuestPackage.seed on a plain directory with the real armv7.itpack, for a shim image and a no-shim one: the
    /// record's GLES hook and family, and the seeded state.
    @Test(
        .enabled(if: FixtureRequirements.corpusEnabled, "Firmware corpus test; set FK_TEST_CORPUS=1 to run"),
        arguments: [("7B500", true), ("8C148", false), ("9B206", true)]
    ) func seed(_ build: String, _ gles: Bool) async throws {
        let itpack = Oracle.guestPackages.appendingPathComponent("armv7.itpack")
        guard Oracle.exists(itpack) else {
            try FixtureRequirements.missing(#"SystemEditsTests.swift: Oracle.exists(itpack)"#)
        }
        try await Oracle.withTemp { dir in
            // the firmware the seed's load checks read: its executables, libSystem, cache, and the mounter's job
            // inserting it_msmquiet as the bake leaves it
            let id = "k48ap-" + build
            guard
                let stock = try await FitFixture.volume(
                    id,
                    FitFixture.stock(id) + [FitFixture.mounter, SystemEdits.msmJob],
                    in: dir
                )
            else {
                try FixtureRequirements.missing(
                    #"SystemEditsTests.swift: let stock = try await FitFixture.volume(id, FitFixture.stock(id) + [FitFixture.mounter, SystemEdits.msmJob], in: dir)"#
                )
            }
            try FitFixture.insert("/usr/local/lib/it_msmquiet.dylib", into: SystemEdits.msmJob, at: stock)
            func volume(_ name: String) throws -> URL {
                let v = dir.appendingPathComponent(name)
                let sv = v.appendingPathComponent(GuestPackage.systemVersion)
                try FileManager.default.copyItem(at: stock, to: v)
                // the front end is installed before the seed
                for rel in [FitCheck.openGLES, "usr/local/lib/it_msmquiet.dylib"] {
                    try SystemEdits.mkdirs(v.appendingPathComponent(rel).deletingLastPathComponent())
                    try SystemEdits.put(Data("stock".utf8), v.appendingPathComponent(rel), mode: 0o755)
                }
                try SystemEdits.mkdirs(v.appendingPathComponent(SystemEdits.daemons))
                try SystemEdits.put(
                    Data("job".utf8),
                    v.appendingPathComponent(SystemEdits.daemons + "/com.qemu.it-pbd.plist")
                )
                try SystemEdits.mkdirs(sv.deletingLastPathComponent())
                try PropertyListSerialization.data(
                    fromPropertyList: ["ProductBuildVersion": build], format: .xml, options: 0
                ).write(to: sv)
                return v
            }
            let a = try volume("swift")
            let (written, record) = try GuestPackage.seed(volume: a, itpack: itpack, gles: gles)
            #expect(!written.isEmpty)
            #expect(record.gles == gles && record.hooks.contains("/" + FitCheck.openGLES) == gles)
            // "9*": 5.x's own family
            if build.hasPrefix("9") { #expect(record.family == "k48-ios5" && record.seed >= 8) }
            var st = stat()
            #expect(lstat(a.appendingPathComponent("usr/local/lighttouch/state").path, &st) == 0)
            // the baked it-pbd job is left alone since package serial 2 folded the pasteboard into it_agent
            #expect(
                try Data(contentsOf: a.appendingPathComponent(SystemEdits.daemons + "/com.qemu.it-pbd.plist"))
                    == Data("job".utf8)
            )
        }
    }

    @Test func activationRejectsInvalidInputWithoutChangingIt() throws {
        try Oracle.withTemp { dir in
            let target = dir.appendingPathComponent("t")
            let original = Data("not a mach-o".utf8)
            try original.write(to: target)
            #expect(throws: ActivationFailure.self) { try Activation.run(on: target) }
            #expect(try Data(contentsOf: target) == original)
        }
    }

    /// Level 2: the system and data volumes SystemEdits.buildK48 makes from the rootfs.dmg: the activation ran, the
    /// seed record, the network services, the seeded tree, the GLES front end with its original kept once, and
    /// lockdownd as the activation wrote it.
    @Test(arguments: HFSOracle.ipads) func volumes(_ fw: Oracle.Firmware) async throws {
        guard K48Oracle.available, let dmg = fw.cache?.appendingPathComponent("rootfs.dmg"), Oracle.exists(dmg)
        else { return }
        try await Oracle.withTemp { dir in
            let entry = try Oracle.entry(fw.entryID)
            let recipe = try #require(entry.recipe)
            let parts = K48NAND.partitions(mbr: [UInt8](K48NAND.makeMBR(systemMiB: recipe.systemMiB)))
            let swift = dir.appendingPathComponent("swift")
            try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
            let helpers = try K48Oracle.helpers(in: dir)
            let r = try await Oracle.time("SystemEdits.buildK48 \(fw.entryID)") {
                try await SystemEdits.buildK48(
                    rootfs: dmg,
                    work: swift,
                    systemBytes: parts[0].count * 4096,
                    dataBytes: Int64(parts[1].count) * 4096,
                    options: .init(recipe: recipe, version: entry.version),
                    helpers: helpers
                ) { print("  \($0)") }
            }
            #expect(r.activation != nil)
            #expect(r.guestPackage?.gles == true && r.engine == SystemEdits.Helpers.openGLES)

            // the seeded network services are there
            let dv = try HFSPlusVolume(swift.appendingPathComponent("data.img"))
            let prefs =
                try PropertyListSerialization.propertyList(
                    from: dv.contents(dv.record(at: "preferences/SystemConfiguration/preferences.plist")),
                    format: nil
                ) as! NSDictionary
            let order =
                ((((((prefs["Sets"] as? [String: Any])?[SystemEdits.netSet] as? [String: Any])?["Network"]
                    as? [String: Any])?["Global"] as? [String: Any])?["IPv4"] as? [String: Any])?["ServiceOrder"]
                    as? [String]) ?? []
            #expect(order.first == SystemEdits.wifiService)
            // the seed is there: loader, current -> pkgs/<serial>, its offer record, a hook and its .baked copy, no baked helper job
            let sv = try HFSPlusVolume(swift.appendingPathComponent("system.img"))
            let seed = try #require(r.guestPackage)
            let tree = Dictionary(uniqueKeysWithValues: try sv.listing(under: "usr/local").map { ($0.path, $0) })
            #expect(tree["usr/local/bin/it_boot"]?.mode == 0o100755 && tree["usr/local/bin/it_boot"]?.uid == 0)
            #expect(tree["usr/local/lighttouch/current"]?.link == "pkgs/\(seed.seed)")
            #expect(tree["usr/local/lighttouch/pkgs/\(seed.seed)/offer"]?.uid == 0)
            #expect(seed.hooks.contains("/" + FitCheck.openGLES))
            let engine = try sv.listing(under: FitCheck.openGLES).first
            let baked = (try? sv.listing(under: FitCheck.openGLES + ".baked"))?.first
            let absent = (try? sv.listing(under: FitCheck.openGLES + ".baked-absent"))?.first
            // The front end is installed over OpenGLES; the original is kept exactly once (126ba26): the firmware's file
            // as .baked (never the front end's bytes), or, when OpenGLES lives only in the dyld cache, an empty .baked-absent.
            #expect(engine?.sha256 != nil && engine?.uid == 0)
            #expect((baked != nil) != (absent != nil))
            if let baked { #expect(engine?.sha256 != baked.sha256 && baked.uid == 0) }
            if let absent {
                #expect(
                    absent.uid == 0
                        && absent.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                )
                #expect(
                    try sv.listing(under: SystemEdits.dyldOverride).first != nil,
                    "an absent original must be a cache-only OpenGLES"
                )
            }
            #expect(try sv.listing(under: SystemEdits.daemons + "/com.qemu.it-pbd.plist").isEmpty)
            #expect(try sv.listing(under: SystemEdits.daemons + "/com.qemu.it-boot.plist").first?.uid == 0)
            // the activation's output is lockdownd as installed (re-signed ad hoc, entitlements kept)
            let lockd = try HFSPlusVolume(swift.appendingPathComponent("system.img")).listing(
                under: "usr/libexec/lockdownd"
            )
            #expect(
                lockd.first?.sha256 == r.activation?.outputSHA256 && lockd.first?.mode == 0o100755
                    && lockd.first?.uid == 0
            )
        }
    }

    /// Two builds from the same inputs give the same system and data volumes, and the same store from them: the
    /// lock's built_listing_sha256 (the golden-lock oracle) relies on it. Dates, the data volume's identifier and
    /// the journals are normalized after the mount (HFSPlusVolume.normalize, VolumeMount.withMounted). A
    /// difference is reported by 4 KiB page, HFS+ region and its first differing bytes.
    @Test(arguments: HFSOracle.ipads) func volumesAreReproducible(_ fw: Oracle.Firmware) async throws {
        guard let cache = fw.cache, Oracle.exists(cache.appendingPathComponent("rootfs.dmg")),
            K48Oracle.guestTools != nil || K48Oracle.available
        else { return }
        try await Oracle.withTemp { dir in
            let entry = try Oracle.entry(fw.entryID)
            let recipe = try #require(entry.recipe)
            let mbr = dir.appendingPathComponent("mbr.bin")
            try K48NAND.makeMBR(systemMiB: recipe.systemMiB).write(to: mbr)
            let parts = K48NAND.partitions(mbr: [UInt8](try Data(contentsOf: mbr)))
            let helpers = try K48Oracle.guestTools ?? K48Oracle.helpers(in: dir)
            var volumes: [[URL]] = []
            for run in ["a", "b"] {
                let work = dir.appendingPathComponent(run)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let r = try await Oracle.time("SystemEdits.buildK48 \(fw.entryID) \(run)") {
                    try await SystemEdits.buildK48(
                        rootfs: cache.appendingPathComponent("rootfs.dmg"),
                        work: work,
                        systemBytes: parts[0].count * 4096,
                        dataBytes: Int64(parts[1].count) * 4096,
                        options: .init(recipe: recipe, version: entry.version),
                        helpers: helpers,
                        dataVolumeUUID: [1, 2, 3, 4, 5, 6, 7, 8]
                    ) { _ in }
                }
                volumes.append([r.system, r.data])
            }
            var same = true
            for (a, b) in zip(volumes[0], volumes[1]) {
                let diff = try Self.differingPages(a, b)
                same = same && diff.isEmpty
                #expect(
                    diff.isEmpty,
                    "\(fw.entryID) \(a.lastPathComponent): \(diff.count) differing pages: \(diff.prefix(16).joined(separator: "; "))"
                )
            }
            guard same else { return }
            let kv = try K48NAND.kernelVersion(kernelcache: cache.appendingPathComponent("kernelcache.mach"))
            var listings: [String] = []
            for run in ["a", "b"] {
                let store = dir.appendingPathComponent("store-" + run)
                try await K48NAND.build(
                    mbr: mbr,
                    kernelVersion: kv,
                    system: volumes[0][0],
                    data: .image(volumes[0][1]),
                    out: store
                )
                let files = try FileManager.default.contentsOfDirectory(atPath: store.path).sorted()
                listings.append(try Preparer.nandListing(store, files: files).sha256)
            }
            #expect(
                listings[0] == listings[1],
                "\(fw.entryID): the store differs between two builds from the same volumes"
            )
        }
    }

    /// "offset (region)" for every 4 KiB page that differs between two images of the same size; the region names
    /// the HFS+ structure at that offset of `a` (volume header, allocation/extents/catalog/attributes file, journal,
    /// or the file whose data fork covers it).
    static func differingPages(_ a: URL, _ b: URL) throws -> [String] {
        let da = try Data(contentsOf: a, options: .alwaysMapped)
        let db = try Data(contentsOf: b, options: .alwaysMapped)
        guard da.count == db.count else { return ["sizes differ: \(da.count) vs \(db.count)"] }
        let page = 4096
        var pages: [Int] = []
        da.withUnsafeBytes { pa in
            db.withUnsafeBytes { pb in
                var off = 0
                while off < da.count {
                    let n = min(page, da.count - off)
                    if memcmp(pa.baseAddress! + off, pb.baseAddress! + off, n) != 0 { pages.append(off) }
                    off += n
                }
            }
        }
        guard !pages.isEmpty else { return [] }
        let v = try HFSPlusVolume(a)
        var vh = [UInt8](repeating: 0, count: 512)
        _ = try Data(contentsOf: a, options: .alwaysMapped).withUnsafeBytes { memcpy(&vh, $0.baseAddress! + 1024, 512) }
        var regions: [(String, Int, Int)] = [
            ("volume header", 0, page), ("alternate volume header", v.totalBlocks * v.blockSize - 1024, 1024),
        ]
        if da.count - 1024 != v.totalBlocks * v.blockSize - 1024 {
            regions.append(("alternate volume header (file end)", da.count - 1024, 1024))
        }
        func forks(_ name: String, _ f: HFSPlusVolume.Fork) {
            for e in f.extents { regions.append((name, Int(e.start) * v.blockSize, Int(e.count) * v.blockSize)) }
        }
        forks("allocation file", HFSPlusVolume.Fork(vh, 112))
        forks("extents file", v.extentsFork)
        forks("catalog file", v.catalogFork)
        forks("attributes file", v.attributesFork)
        if let j = try v.journal() { regions.append(("journal", j.offset, j.size)) }
        let records = try v.catalog()
        let tree = try v.btree(v.catalogFork, fileID: HFSPlusVolume.catalogID)
        let catalogExtents = try v.extents(v.catalogFork, fileID: HFSPlusVolume.catalogID)
        return pages.map { off -> String in
            let at = (0..<page).first { da[off + $0] != db[off + $0] } ?? 0
            let hex = { (d: Data) in
                d[off + at..<min(off + at + 16, d.count)].map { String(format: "%02x", $0) }.joined()
            }
            let location = "\(off)+\(at) \(hex(da)) vs \(hex(db))"
            if let r = regions.first(where: { off >= $0.1 && off < $0.1 + $0.2 }) {
                guard r.0 == "catalog file" else { return "\(location) (\(r.0))" }
                // the catalog record (and the field offset in its body) at that byte
                var forkOff = 0
                var base = 0
                for e in catalogExtents {
                    let len = Int(e.count) * v.blockSize
                    let start = Int(e.start) * v.blockSize
                    if off + at >= start && off + at < start + len {
                        forkOff = base + (off + at - start)
                        break
                    }
                    base += len
                }
                let node = forkOff / tree.nodeSize
                let inNode = forkOff % tree.nodeSize
                let rec = records.first {
                    $0.node == node && inNode >= $0.bodyOffset && inNode < $0.bodyOffset + ($0.kind == .file ? 248 : 88)
                }
                return
                    "\(location) (catalog node \(node) byte \(inNode)\(rec.map { ": \($0.kind) \($0.name) cnid \($0.cnid) body+\(inNode - $0.bodyOffset)" } ?? ""))"
            }
            if let r = records.first(where: {
                $0.data?.extents.contains {
                    off >= Int($0.start) * v.blockSize && off < Int($0.start + $0.count) * v.blockSize
                } ?? false
            }) {
                return "\(location) (\(r.name))"
            }
            return location
        }
    }
}
