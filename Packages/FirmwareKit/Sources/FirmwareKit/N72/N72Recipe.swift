// N72Board: the iPod touch 2G (n72ap, recipe "n72") side of Recipe.create. Ports ipod2g_device.build/bake +
// build_nand.py (--epoch) over the other modules.
//
// Boot files: nor.bin, iBoot.bin (3.x+: the machine's direct-iboot), gid-blobs.bin. Volume: the IPSW rootfs
// grown to the recipe, fstab, the kernelcache at the path iBoot names, the shared bake (SystemEdits) plus the
// iPod's own pieces (sound defaults, guest-tools markers), owners patched in the catalog.
// Store: N72NAND's page directory. There is no seal boot: the legacy FTL store needs no clean halt.
// Data protection (4.x: FirmwareEntry.dataProtection, or options.data_protection) adds the restore-ramdisk keybag
// one-shot (N72Keybag) through --helper.
//
// The recipe: storage "8g" (model MB528; 16g MB531, 32g MB533; region LL/A), system_mib = the volume
// (7168 MiB = 1835008 blocks), options gles_shim / appsync / web_proxy / data_protection. --guest-tools
// holds OpenGLES (the GL front end, qemu-ios contrib/gles-public: every build, 2.x to 4.x) and gles-names.h, sblaunch,
// sbdlicon (optional), it_agent, it_typein.dylib, com.qemu.it-agent.plist, libappsync.dylib, armv6.itpack (the
// guest-package loader and seed package, as ipod2g_device.py bakes them; the package's it_prefs keeps the first-run
// "Edit Home Screen" tip down and sets Brightness at maximum and Auto-Lock Never once per device; without the
// helpers, the same SpringBoard preferences are baked instead: bakePrefs) and it_keybag-armv6
// (data protection). With gles_shim the front end replaces OpenGLES once FitCheck.glesFrontEnd fits (else the prepare
// fails) and SpringBoard gets CA_ENABLE_OGL=1.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

final class N72Board: Board {
    static let models = ["8g": "MB528", "16g": "MB531", "32g": "MB533"]
    static let kcPrefix = "/System/Library/Caches/com.apple.kernelcaches/"
    static let mbx = "System/Library/Frameworks/OpenGLES.framework/MBXGLEngine.bundle/MBXGLEngine"
    static let openGLES = "System/Library/Frameworks/OpenGLES.framework/OpenGLES"
    static let prefs = "private/var/mobile/Library/Preferences"
    static let agentJob = "System/Library/LaunchDaemons/com.qemu.it-agent.plist"
    static let fstabRW = "/dev/disk0s1 / hfs rw 0 1\n"
    /// set-sound-defaults.py: the five Sounds switches of a new device.
    static var soundDefaults: [(String, [String: Any])] {
        [
            ("com.apple.mobilemail.plist", ["PlayNewMailSound": true, "PlaySentMailSound": true]),
            (
                "com.apple.springboard.plist",
                ["calendar-alarm": "/Applications/MobileCal.app/alarm.aiff", "lock-unlock": true]
            ),
            ("com.apple.preferences.sounds.plist", ["keyboard": true]),
        ]
    }
    /// Paths the guest-tools bake creates (ipod2g_device.GUEST_TOOL_OWNERS), owner set in the catalog if present.
    static let guestToolOwners: [(UInt32, String)] = [
        (0, "usr/local"), (0, "usr/local/bin"), (0, "usr/local/bin/it_agent"), (0, "usr/local/bin/sblaunch"),
        (0, "usr/local/bin/sbdlicon"), (0, "usr/lib/it_typein.dylib"), (0, agentJob), (0, mbx + ".stock"),
        (501, prefs + "/com.apple.mobilemail.plist"), (501, prefs + "/com.apple.springboard.plist"),
        (501, prefs + "/com.apple.preferences.sounds.plist"), (501, "private/var/mobile/Media/.lt-guest-tools-v1"),
        (501, "private/var/mobile/Media/.lt-guest-tools-v2"), (501, "private/var/mobile/Media/.lt-guest-tools-v3"),
    ]

    /// The -machine options every device this recipe builds boots with (device.lock.json "machine"). hardware: the
    /// AES mode register reads back, so iBoot's UID derivation encrypts, as N72NOR wraps for; devices made with
    /// engine (a decrypt-wrapped NOR) keep booting with the engine their locks name.
    public static let machine = ["aes-uid": "hardware"]

    let arch = "armv6", seedPrefix = "ipod2g"
    let bootStep = "Writing the identity, NOR and boot files", volumesStep = "Building the system volume",
        keybagStep = "Booting the restore ramdisk"
    let needsSeal = false
    let recipe: FirmwareEntry.Recipe, model: String, blocks: Int, dataProtection: Bool
    var helper: URL?, bootrom: URL?, ident: UnitIdentity?

    /// Cydia installs Substrate's launchd hook on the iPod touch 2G; after its first boot that hook hangs launchd.
    /// Keep ordinary preparation unaffected, but reject an explicitly requested jailbreak before reading the IPSW.
    static func jailbreakUnavailable(options: [String: Bool]) -> String? {
        guard options["jailbreak"] == true else { return nil }
        return "no jailbreak on the iPod touch 2G yet: Cydia's Substrate prevents later boots"
    }
    var epoch = 0, major = 0, kcPath = "", kcMember = "", prefix = ""
    var derived: [String: Any] = [:]
    var shipped: [String] { ["nor.bin", "gid-blobs.bin"] + (major >= 3 ? ["iBoot.bin"] : []) }
    var itKeybag: String { SystemEdits.Helpers.name("it_keybag", arch) }

    init(_ o: Preparer.Options) throws {
        guard let recipe = o.entry.recipe, let model = Self.models[recipe.storage] else {
            throw FirmwareError(
                .unsupported,
                "\(o.entry.id): no n72 recipe for storage \(o.entry.recipe?.storage ?? "none")"
            )
        }
        self.recipe = recipe
        self.model = model
        blocks = recipe.systemMiB * 256
        dataProtection = recipe.options["data_protection"] ?? FirmwareEntry.dataProtection(version: o.entry.version)
    }

    func check(_ c: Recipe.Context) throws {
        if let reason = Self.jailbreakUnavailable(options: recipe.options) {
            throw FirmwareError(.unsupported, "\(c.e.id): \(reason)")
        }
        let fm = FileManager.default
        helper = c.o.helper
        bootrom = c.o.bootrom.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? Self.bootromPath(helper: helper)
        if dataProtection {
            guard let helper, fm.isExecutableFile(atPath: helper.path) else {
                throw FirmwareError(
                    .internal,
                    "the keybag boot needs --helper (LightTouchDevice); got \(c.o.helper?.path ?? "none")"
                )
            }
            guard bootrom != nil else {
                throw FirmwareError(
                    .internal,
                    "the keybag boot needs the iPod touch 2G's boot ROM (iBoot-240.4): --bootrom, or bootrom_240_4 next to the helper"
                )
            }
            guard fm.fileExists(atPath: c.o.guestTools.appendingPathComponent(itKeybag).path) else {
                throw FirmwareError(.internal, "guest helper \(itKeybag) missing from \(c.o.guestTools.path)")
            }
        }
    }

    /// Restore.plist: the NAND epoch (DeviceMap SCEP) and the iOS major.
    func inspect(_ c: Recipe.Context) throws {
        guard
            let rp = try PropertyListSerialization.propertyList(from: try c.ipsw.read("Restore.plist"), format: nil)
                as? [String: Any],
            let epoch = ((rp["DeviceMap"] as? [[String: Any]])?.first?["SCEP"] as? NSNumber)?.intValue,
            let restore = c.restore,
            let major = Int(restore.productVersion.prefix { $0 != "." })
        else {
            throw FirmwareError(.unsupported, "Restore.plist has no DeviceMap SCEP (NAND epoch)")
        }
        self.epoch = epoch
        self.major = major
    }

    func identity(seed: String) throws -> UnitIdentity {
        let ident = try UnitIdentity.synthesizeIPod(
            seed: seed,
            modelNumber: model,
            regionInfo: UnitIdentity.iPadRegion
        )
        self.ident = ident
        return ident
    }

    /// nor.bin, gid-blobs.bin, iBoot.bin (3.x+), and the derived facts the lock records.
    func bootFiles(_ c: Recipe.Context) throws {
        let ident = try self.ident.filled("the identity")
        let e = c.e
        let ipsw = c.ipsw
        let iboot = try Data(contentsOf: c.decFile("iBoot.bin"))
        kcPath = try Self.kernelcachePath(iboot)
        let components = try BuildComponents.load(ipsw, board: c.e.board)
        guard let kc = components["KernelCache"] else {
            throw FirmwareError(.unsupported, "\(e.id): the IPSW names no KernelCache")
        }
        kcMember = kc
        // the machine boots every n72 device with the AMFI pair (qemu-ios ipod_touch_2g.c; N72Keybag.bootArgs)
        let kernel = try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped)
        try FitCheck.checkBootArgs(
            c.fit,
            kernel: kernel,
            args: FitCheck.amfiArgs.sorted().map { $0 + "=1" }.joined(separator: " ")
        )
        derived = [
            "storage_layout": "n72-generated-v1", "nand_epoch": epoch, "wrap_shsh": major >= 3,
            "kernelcache_path": kcPath, "kernelcache_member": kcMember,
            "kernel": Self.firstMatch(
                try Data(contentsOf: c.decFile("kernelcache.mach")),
                /Darwin Kernel Version [^\x00]+/
            ) ?? NSNull(),
            "iboot": Self.firstMatch(iboot, /iBoot-[0-9.]+/) ?? "?", "direct_iboot": major >= 3,
        ]
        prefix = "Firmware/all_flash/all_flash.\(e.board).production/"
        let img3Members = try ipsw.names().filter { $0.hasPrefix(prefix) && $0.hasSuffix(".img3") }
        var images: [String: Data] = [:]
        for n in img3Members {
            let d = try ipsw.read(n)
            let t = try N72NOR.type(of: d)
            guard images[t] == nil else { throw FirmwareError(.unsupported, "duplicate img3 type \(t) in all_flash") }
            images[t] = d
        }
        let manifest = String(decoding: try ipsw.read(prefix + "manifest"), as: UTF8.self).split(
            whereSeparator: \.isWhitespace
        )
        let shipped = Set(try manifest.map { try N72NOR.type(of: ipsw.read(prefix + $0)) })
        let norTypes = N72NOR.order.filter(shipped.contains)
        derived["nor_images"] = norTypes
        // Whose SHSH is wrapped under the emulated UID, as a restore leaves the NOR: 3.x+ every image (the machine
        // enters iBoot directly). 2.x boots SecureROM -> LLB -> iBoot, and the SecureROM verifies the LLB raw; past
        // it, the epoch-1 chain (iBoot-385.22, 2.1.1) unwraps only iBoot (its LLB does) and verifies the rest raw,
        // while the epoch-2 chain (385.49, 2.2/2.2.1) unwraps every image it loads ("load_macho_image: failed to
        // load device tree" with a raw DeviceTree). The epoch is Restore.plist SCEP, as for the NAND.
        let wrap = major >= 3 ? norTypes : epoch >= 2 ? norTypes.filter { $0 != "illb" } : ["ibot"]
        derived["wrap_shsh_types"] = wrap
        try N72NOR.build(identity: ident, images: images, types: norTypes, wrapTypes: major >= 3 ? nil : wrap).write(
            to: c.file("nor.bin")
        )
        // Stock DFU/recovery also decrypts the restore ramdisks and boot images.
        // Their silicon-bound GID inputs belong in the same per-IPSW table.
        let (blobs, blobNames) = try Self.gidBlobs(ipsw, entry: e)
        derived["gid_blobs"] = blobNames
        try blobs.write(to: c.file("gid-blobs.bin"))
        if major >= 3 { try iboot.write(to: c.file("iBoot.bin")) }
    }

    var volume: URL?

    /// The system volume: IPSW rootfs grown to the recipe, fstab, kernelcache, the bake; owners and dates patched.
    nonisolated(nonsending) func volumes(_ c: Recipe.Context) async throws {
        let volume = c.work.appendingPathComponent("volume.img")
        self.volume = volume
        try await UDIF.extractRootfs(dmg: c.decFile("rootfs.dmg"), to: volume)
        try await VolumeMount.grow(volume, toBytes: blocks * 4096)
        let newest: UInt32  // the IPSW's newest file: everything the recipe writes gets dated as of it
        do {
            let v = try HFSPlusVolume(volume)
            c.log(
                "\(v.signature) blocksize=\(v.blockSize) total=\(v.totalBlocks) free=\(v.freeBlocks) files=\(v.fileCount) dirs=\(v.folderCount)"
            )
            guard v.totalBlocks == blocks, v.blockSize == 4096 else {
                throw FirmwareError(
                    .internal,
                    "resize produced \(v.totalBlocks) x \(v.blockSize) B blocks, wanted \(blocks) x 4096"
                )
            }
            newest = try v.newestDate()
        }
        var owners: [(UInt32, String)] = [(0, kcPath)]
        let report = try await VolumeMount.withMounted(volume, at: c.work.appendingPathComponent("mnt")) {
            m -> [String: Any] in
            try SystemEdits.put(Data(Self.fstabRW.utf8), m.appendingPathComponent(SystemEdits.fstab))
            let kc = m.appendingPathComponent(kcPath)
            try SystemEdits.mkdirs(kc.deletingLastPathComponent())
            try c.ipsw.extract(kcMember, to: kc)
            return try bake(m, c, owners: &owners)
        }
        c.activation = report["activation"] as? Activation.Result
        c.guestPackage = report["guest_package"] as? GuestPackage.Record
        for (k, v) in report where !["guest_package", "activation", "cydia_modes"].contains(k) { derived[k] = v }
        let hfs = try HFSPlusVolume(volume, writable: true)
        for uid in Set(owners.map(\.0)).sorted() {
            let n = try hfs.setOwner(owners.filter { $0.0 == uid }.map(\.1), uid: uid, gid: uid)
            c.log("\(uid):\(uid) patched \(n) catalog record(s)")
        }
        for (path, mode) in report["cydia_modes"] as? [(path: String, mode: UInt16)] ?? [] {
            _ = try hfs.setOwner([path], uid: 0, gid: 0, mode: mode)
        }
        c.log("\(try hfs.normalize(after: newest, to: newest)) catalog records dated as of the IPSW's newest file")
    }

    nonisolated(nonsending) func store(_ c: Recipe.Context) async throws {
        let volume = try self.volume.filled("the system volume")
        let (written, meta) = try N72NAND.write(volume: volume, blocks: blocks, epoch: epoch, out: c.nand)
        c.log("\(written) filesystem pages, \(meta) metadata pages generated (epoch \(epoch))")
        try FileManager.default.removeItem(at: volume)
    }

    /// 4.x data protection: effaceable + system keybag from the IPSW's own Update ramdisk (a restore-only build such
    /// as 8A293 ships just the Restore one; restored_external runs first on either).
    nonisolated(nonsending) func keybag(_ c: Recipe.Context) async throws {
        let (source, name) = try await Recipe.keybagRamdisk(c)
        try await N72Keybag.run(
            out: c.o.out,
            dec: c.decrypted(),
            ramdisk: source,
            itKeybag: c.o.guestTools.appendingPathComponent(itKeybag),
            bootrom: bootrom.filled("the iPod bootrom"),
            helper: helper.filled("the helper"),
            work: c.work,
            log: c.log
        )
        derived["keybag_ramdisk"] = name
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        let ident = try self.ident.filled("the identity")
        guard let mac = ident["wifi-mac"], let bt = ident["bt-mac"], let ecid = ident["unique-chip-id"] else {
            throw FirmwareError(.internal, "\(c.e.id): the identity has no Wi-Fi MAC, Bluetooth MAC or ECID")
        }
        return [
            "inputs": ["kernelcache": kcMember, "iboot": "iBoot.bin", "all_flash": prefix],
            "outputs": [
                "nand": ["pages": c.nandHashes.count],
                "nor": try Recipe.fileRecord(c, "nor.bin"),
                "iboot": major >= 3 ? try Recipe.fileRecord(c, "iBoot.bin") as Any : NSNull(),
                "gid_blobs": try Recipe.fileRecord(c, "gid-blobs.bin"),
            ],
            "derived": derived,
            // 3.x+ enters its decrypted iBoot directly (the bootrom rejects a personalized LLB); 2.x runs the real
            // bootrom -> NOR LLB -> iBoot chain and ships no iBoot.bin (ipod2g_device.py direct_iboot)
            "boot_strategy": major >= 3 ? "iboot" : "bootrom",
            // The BCM4325 CIS and NOR wifiaddr belong to the same unit. Older drivers
            // obtain the card's address before downloading its firmware.
            "machine": Self.machine.merging([
                "wifi-mac": mac, "bt-mac": bt, "ecid": ecid,
            ]) { _, card in card },
        ]
    }

    /// The iPod bootrom the keybag boot's machine loads: LTM_FILES, then the app bundle's Resources/Device next to
    /// the helper (Contents/MacOS), then the development assets.
    static func bootromPath(helper: URL?) -> URL? {
        let env = ProcessInfo.processInfo.environment["LTM_FILES"].map { URL(fileURLWithPath: $0) }
        let bundled = helper?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(
            "../Resources/Device"
        ).standardizedFileURL
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/qemu-ios-files")
        return [env, bundled, dev].compactMap { $0?.appendingPathComponent("bootrom_240_4") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func firstMatch(_ d: Data, _ r: Regex<Substring>) -> String? {
        String(decoding: d, as: UTF8.self).firstMatch(of: r).map { String($0.output) }
    }

    /// The volume path the decrypted iBoot loads the kernelcache from (its one kcPrefix string), without the "/".
    static func kernelcachePath(_ iboot: Data) throws -> String {
        let b = [UInt8](iboot)
        let p = Array(kcPrefix.utf8)
        var hits = Set<String>()
        var i = 0
        while let r = b[i...].firstRange(of: p) {
            var j = r.upperBound
            while j < b.count, (0x21...0x7E).contains(b[j]) { j += 1 }
            if j > r.upperBound { hits.insert(String(decoding: b[r.lowerBound + 1..<j], as: UTF8.self)) }
            i = r.upperBound
        }
        guard hits.count == 1, let path = hits.first else {
            throw FirmwareError(
                .unsupported,
                "iBoot names \(hits.count) kernelcache paths (\(hits.sorted())); expected exactly one"
            )
        }
        return path
    }

    /// KBAG || IV-key for NOR, normal boot and stock restore (the emulated AES engine's GID table).
    static func gidBlobs(_ ipsw: IPSWArchive, entry: FirmwareEntry) throws -> (Data, [String]) {
        let prefix = "Firmware/all_flash/all_flash.\(entry.board).production/"
        let images = try ipsw.names().filter { $0.hasPrefix(prefix) && $0.hasSuffix(".img3") }
        let components = try BuildComponents.load(ipsw, board: entry.board)
        let members = images + Set(components.values).subtracting(images).sorted()
        var out = Data()
        var names: [String] = []
        for n in members {
            let name = (n as NSString).lastPathComponent
            guard let k = entry.keys.values.first(where: { $0.file == name }), let iv = k.iv.flatMap({ Data(hex: $0) }),
                let key = Data(hex: k.key), iv.count + key.count == 32
            else { continue }
            let d = try ipsw.read(n)
            guard let t = try IMG3.tags(d)["KBAG"], t.dataLength >= 40 else { continue }
            let b = [UInt8](d)
            guard le32(b, t.offset + 12) == 1, le32(b, t.offset + 16) == 128 else { continue }  // production, AES-128
            out += b[t.offset + 20..<t.offset + 52] + iv + key
            names.append(name)
        }
        return (out, names)
    }

    /// ipod2g_device.bake over the mounted volume `m` (bake-guest-tools.sh, patch-appsync-dylib.sh,
    /// install_web_proxy, activation) with the shared pieces of SystemEdits. Appends the owners to patch;
    /// returns the report (the lock's `derived`, plus activation and guest_package).
    func bake(_ m: URL, _ c: Recipe.Context, owners: inout [(UInt32, String)]) throws -> [String: Any] {
        let fm = FileManager.default
        let opt = recipe.options
        let helpers = c.o.guestTools
        let cache = SystemEdits.dyldCache(arch)
        let at = { (rel: String) in m.appendingPathComponent(rel) }
        // The guest helpers (it_agent, it_typein DYLD_INSERTed into SpringBoard, sblaunch, it_prefs, the loader and
        // its seed package) are checked against the volume's dyld and imports. The exported armv6 set is now
        // legacy-linked for 2.x through 4.x; old helper directories with LC_DYLD_INFO_ONLY still fail the fit
        // check on 2.x/3.0 and are left out with a warning. Never infer compatibility from the version or cache.
        func helper(_ n: String) throws -> Data {
            let u = helpers.appendingPathComponent(n)
            guard fm.fileExists(atPath: u.path) else {
                throw FirmwareError(.internal, "guest helper \(n) missing from \(helpers.path)")
            }
            return try Data(contentsOf: u)
        }
        let fw = FitCheck.Firmware(root: m, arch: arch)
        let toolsFit = try Self.guestToolsFit(fw, helpers: helpers)
        let tools = try c.fit.check(toolsFit, required: false)
        if opt["appsync"] == true {
            try FitCheck.checkAppSync(c.fit, fw, helpers: helpers)
        } else {
            c.fit.notInstalled("AppSync", "appsync off")
        }
        // the reorder tip's key: set by it_prefs at boot (tools) or baked below; either way only if SpringBoard reads it
        try c.fit.check(
            FitCheck.prefs(fw, [FitCheck.itPrefs[0]])[0],
            required: false,
            outcome: tools ? "kept: it_prefs skips the key at boot" : "not baked"
        )
        // the GL front end (qemu-ios contrib/gles-public): one OpenGLES.framework/OpenGLES for every build, 2.x's EGL
        // compositor and 3.x/4.x's EAGL one alike, once FitCheck.glesFrontEnd proves this firmware has what it looks up
        var report: [String: Any] = [:]
        var gles = false
        if opt["gles_shim"] ?? true {
            let (engine, owned) = try SystemEdits.installCAOGL(
                m,
                helpers: helpers,
                arch: arch,
                fw: fw,
                fit: c.fit,
                log: c.log
            )
            gles = true
            owners += owned.map { (UInt32(0), $0) }
            report["gles"] = "GL front end \(engine) as OpenGLES; CoreAnimation composites through it (CA_ENABLE_OGL=1)"
        } else {
            report["gles"] = "stock OpenGLES, software CA: options.gles_shim off"
        }
        report["gles_shim"] = gles
        report["gles_engine"] = gles ? SystemEdits.Helpers.openGLES : NSNull() as Any
        report["guest_tools"] = tools ? "installed" : "omitted: " + toolsFit.proof

        // bake-guest-tools.sh
        if tools {
            try SystemEdits.mkdirs(at("usr/local/bin"))
            try SystemEdits.put(helper("sblaunch"), at("usr/local/bin/sblaunch"), mode: 0o755)
            if fm.fileExists(atPath: helpers.appendingPathComponent("sbdlicon").path) {
                try SystemEdits.put(helper("sbdlicon"), at("usr/local/bin/sbdlicon"), mode: 0o755)
            }
            try SystemEdits.put(helper("it_agent"), at("usr/local/bin/it_agent"), mode: 0o755)
            try SystemEdits.put(helper("it_typein.dylib"), at("usr/lib/it_typein.dylib"), mode: 0o755)
        }
        try c.fit.check(
            FitCheck.environment(fw, Self.sbSwitches),
            required: false,
            outcome: "kept: a switch nothing reads is inert"
        )
        try SystemEdits.editSpringBoardJob(m) { env, _ in
            for k in ["CA_ENABLE_OGL", "LK_ENABLE_OGL"] { env[k] = gles ? "1" : "0" }
            for k in ["CA_AUTO_ENABLE_OGL", "LK_AUTO_ENABLE_OGL"] { env[k] = "0" }
            let old = (env["DYLD_INSERT_LIBRARIES"] as? String ?? "").split(separator: ":").map(String.init)
            let libs =
                old.filter { !["/usr/lib/it_kbd_agent.dylib", "/usr/lib/it_typein.dylib"].contains($0) }
                + (tools ? ["/usr/lib/it_typein.dylib"] : [])
            env["DYLD_INSERT_LIBRARIES"] = libs.isEmpty ? nil : libs.joined(separator: ":")
        }
        if tools { try SystemEdits.put(helper("com.qemu.it-agent.plist"), at(Self.agentJob), mode: 0o644) }
        try? fm.removeItem(at: at("System/Library/LaunchDaemons/com.qemu.it-pbd.plist"))
        let sbp = at(Self.prefs + "/com.apple.springboard.plist")
        if fm.fileExists(atPath: sbp.path),
            let d = try PropertyListSerialization.propertyList(from: Data(contentsOf: sbp), format: nil)
                as? [String: Any],
            d["SBDontLockEver"] != nil || d["SBDisableCABlanking"] != nil
        {
            try SystemEdits.rewritePlist(sbp) { $0.removeObjects(forKeys: ["SBDontLockEver", "SBDisableCABlanking"]) }
        }
        for (name, changes) in Self.soundDefaults {
            try SystemEdits.seedPlist(at(Self.prefs + "/" + name)) { $0.addEntries(from: changes) }
        }
        if let l = try SystemEdits.seedLanguage(
            at("private/var"),
            tag: c.o.language,
            keyboards: c.o.keyboards,
            catalog: SystemEdits.KeyboardCatalog(at("System/Library/TextInput")),
            formats: SystemEdits.regionFormats(m)
        ) {
            report["language"] = "\(l.language), region \(l.locale), keyboards \(l.keyboards)"
        }
        let media = at("private/var/mobile/Media")
        if tools {
            try SystemEdits.mkdirs(media)
            for v in 1...3 {
                try SystemEdits.put(Data("v\(v)\n".utf8), media.appendingPathComponent(".lt-guest-tools-v\(v)"))
            }
        } else {
            for rel in [Self.agentJob] + (1...3).map({ "private/var/mobile/Media/.lt-guest-tools-v\($0)" }) {
                try? fm.removeItem(at: at(rel))
            }
        }

        if opt["jailbreak"] == true {
            guard let bootstrap = c.cydia else { throw FirmwareError(.internal, "jailbreak: no Cydia bootstrap") }
            let jb = try SystemEdits.installJailbreak(m, bootstrap: bootstrap, typeinBySubstrate: tools)
            report["afc2"] = jb.afc2
            report["cydia"] = jb.cydia
            report["cydia_modes"] = jb.modes
            owners += jb.root.map { (0, $0) } + jb.mobile.map { (501, $0) }
        }
        if opt["appsync"] == true {  // patch-appsync-dylib.sh
            let (line, job) = try SystemEdits.installAppSync(
                m,
                helper: helpers.appendingPathComponent(SystemEdits.Helpers.appsync),
                cache: cache,
                log: c.log
            )
            report["appsync"] = [
                line, "installation service (\(job)) DYLD_INSERT_LIBRARIES += /\(SystemEdits.appsyncPath)",
            ]
            owners.append((0, SystemEdits.appsyncPath))
            if FileManager.default.fileExists(atPath: m.appendingPathComponent(SystemEdits.appsyncLauncherPath).path) {
                owners.append((0, SystemEdits.appsyncLauncherPath))
            }
        }
        if tools {  // the seed package's it_prefs (its com.qemu.guest-prefs job), as on every later package
            report["prefs"] =
                "it_prefs (guest package): SBDidShowReorderText, then Brightness and Auto-Lock once, at first boot"
        } else {  // Older incompatible helper inputs: bake its keys into mobile’s SpringBoard preferences
            report["prefs"] = try Self.bakePrefs(m, dir: Self.prefs)
        }
        // install_web_proxy: the PAC, and the Wi-Fi service on the system volume's /private/var
        if opt["web_proxy"] ?? true {
            try c.fit.check(FitCheck.webProxy(fw), required: false, outcome: "kept: the PAC is unused")
            let sc = "private/var/preferences/SystemConfiguration"
            owners += try SystemEdits.installPAC(m, dirs: [sc]).map { (UInt32(0), $0) }
            try SystemEdits.seedPlist(at(sc + "/preferences.plist"), SystemEdits.wifiProxyPrefs)
            owners.append((0, sc + "/preferences.plist"))
            report["web_proxy"] = "PAC /\(SystemEdits.pacPath) on the en0 Wi-Fi service"
        }
        report["activation"] = try SystemEdits.activate(m, log: c.log)
        owners.append((0, SystemEdits.lockdownd))
        // mkpkg.seed: the loader and the seed package; it_boot loads the package's jobs (com.qemu.it-agent), so
        // the baked copies it provides are removed. Owners after it, for only what is left.
        // On 2.x and 3.0 the package carries only the GL front end's hook.
        if tools || gles {
            let (seeded, record) = try SystemEdits.seedGuestPackage(
                m,
                helpers: helpers,
                arch: arch,
                gles: gles,
                omitted: opt["appsync"] == true ? [] : ["/" + SystemEdits.appsyncPath],
                fit: c.fit,
                log: c.log
            )
            report["guest_package"] = record
            owners += seeded.map { (UInt32(0), $0) }
        }
        owners += Self.guestToolOwners.filter {
            (try? fm.destinationOfSymbolicLink(atPath: at($0.1).path)) != nil || fm.fileExists(atPath: at($0.1).path)
        }
        c.log("bake: \(report.filter { $0.key != "activation" && $0.key != "guest_package" })")
        return report
    }
}

extension N72Board {
    /// The switches the bake sets in SpringBoard's job, each under its 3.x+ (CoreAnimation) and 1.x/2.x (LayerKit) name.
    static let sbSwitches = [
        ["CA_ENABLE_OGL", "LK_ENABLE_OGL"], ["CA_AUTO_ENABLE_OGL", "LK_AUTO_ENABLE_OGL"],
    ]

    /// The baked guest tools (and it_typein in SpringBoard) that must all load for any to be installed.
    static let guestTools = ["it_agent", "it_typein.dylib", "sblaunch", "sbdlicon"]

    /// One Fit for the iPod's baked guest tools: each proven with FitCheck.loads (sbdlicon only if the helpers have it).
    static func guestToolsFit(_ fw: FitCheck.Firmware, helpers: URL) throws -> FitCheck.Fit {
        var fits: [FitCheck.Fit] = []
        for n in guestTools {
            let u = helpers.appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: u.path) else {
                if n == "sbdlicon" { continue }
                throw FirmwareError(.internal, "guest helper \(n) missing from \(helpers.path)")
            }
            fits.append(
                FitCheck.loads(
                    n,
                    try Data(contentsOf: u),
                    on: fw,
                    host: n == "it_typein.dylib" ? "/" + springBoard : nil
                )
            )
        }
        let piece = "guest tools (\(fits.map(\.piece).joined(separator: ", ")))"
        let lost = fits.filter { !$0.fits }
        guard lost.isEmpty else {
            return FitCheck.Fit(piece, fits: false, lost.map { "\($0.piece): \($0.proof)" }.joined(separator: "; "))
        }
        return FitCheck.Fit(piece, fits: true, "each loads (\(fits[0].piece): \(fits[0].proof))")
    }

    /// SpringBoard's first-run "Edit Home Screen" tip stays down once com.apple.springboard SBDidShowReorderText is true.
    static let reorderTip = "SBDidShowReorderText"
    static let springBoard = "System/Library/CoreServices/SpringBoard.app/SpringBoard"

    /// contrib/it-prefs offline, where it cannot run (no helpers: 1.x, 2.x/3.0 helper sets that do not load): what it
    /// writes into the user's com.apple.springboard.plist in `dir`, each key only if SpringBoard names it (it_prefs'
    /// rule: the key and its NUL): the reorder tip, and its once-only defaults, Brightness at maximum (SBBacklightLevel2,
    /// 1.x SBBacklightLevel) and Auto-Lock Never (SBAutoLockTime -1, where Settings keeps it through 3.x, with
    /// SBAutoDimTime -1: SpringBoard resets both to its defaults when the dim time is above the lock time). Baked once
    /// at prepare, so the user's later choices stand. Returns the report line.
    static func bakePrefs(_ m: URL, dir: String) throws -> String {
        guard let sb = try? Data(contentsOf: m.appendingPathComponent(springBoard), options: .alwaysMapped) else {
            return "no SpringBoard: left alone"
        }
        let named = prefsBaked.filter { sb.range(of: Data(($0.key + "\0").utf8)) != nil }
        guard !named.isEmpty else {
            return "SpringBoard names none of \(prefsBaked.map(\.key).joined(separator: ", ")): left alone"
        }
        try SystemEdits.seedPlist(m.appendingPathComponent(dir + "/com.apple.springboard.plist")) { d in
            for (k, v) in named { d[k] = v }
        }
        return named.map(\.key).joined(separator: ", ") + " baked (no helpers)"
    }

    /// bakePrefs' keys and values, it_prefs' SETTINGS and defaults() for SpringBoard: also the AC-power UI hidden
    /// (SBHideACPower: no charging chime, plug or charging lock screen; the emulated cable is always in),
    /// Auto-Brightness off (SBEnableALS) and Battery % off (SBShowBatteryPercentage, 3.x+).
    static var prefsBaked: [(key: String, value: Any)] {
        [
            (reorderTip, true), ("SBBacklightLevel2", 1.0), ("SBBacklightLevel", 1.0),
            ("SBAutoLockTime", -1), ("SBAutoDimTime", -1), ("SBHideACPower", true),
            ("SBEnableALS", false), ("SBShowBatteryPercentage", false),
        ]
    }

    /// ipod2g_device.gles2x_front_end (ipod1g_device's for 1.x): (true, line) if the stock OpenGLES exports exactly
    /// the names in `exports` (contrib/it-gles/opengles-<1x|2x>.exports), so the package's hook may replace it;
    /// else (false, why), stock kept.
    static func frontEnd(_ stock: URL, exports: URL) throws -> (Bool, String) {
        guard FileManager.default.fileExists(atPath: stock.path) else { return (false, "no \(openGLES)") }
        guard let list = try? String(contentsOf: exports, encoding: .utf8) else {
            throw FirmwareError(
                .internal,
                "guest helper \(exports.lastPathComponent) missing from \(exports.deletingLastPathComponent().path)"
            )
        }
        let want = Set(
            list.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        let got = Set(try exportedSymbols(Data(contentsOf: stock)))
        guard want == got else {
            return (
                false,
                "stock OpenGLES exports differ from \(exports.lastPathComponent) (missing \(want.subtracting(got).sorted().prefix(4)), extra \(got.subtracting(want).sorted().prefix(4))): stock kept"
            )
        }
        return (true, "GL front end replaces OpenGLES (\(got.count) exports, the firmware's own)")
    }

    /// gles2x_exports.scan: the defined external symbols of a thin (or the ARM slice of a fat) 32-bit Mach-O,
    /// without the leading _.
    static func exportedSymbols(_ data: Data) throws -> [String] {
        guard let m = (MachO32.slice(data, arch: "armv6") ?? MachO32.slice(data, arch: "armv7"))?.image else {
            throw FirmwareError(.unsupported, "OpenGLES: not a 32-bit Mach-O")
        }
        return m.symbols().filter { MachO32.isExport($0.type) }
            .map { $0.name.hasPrefix("_") ? String($0.name.dropFirst()) : $0.name }.sorted()
    }
}
