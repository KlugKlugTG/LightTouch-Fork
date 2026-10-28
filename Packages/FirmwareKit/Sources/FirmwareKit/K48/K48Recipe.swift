// K48Board: the A4 boards' side of Recipe.create: the iPad 1 (k48ap, recipe "k48") and the iPod touch 4G
// (n81ap, recipe "n81": kboot only, KBoot grafts the NOR it lacks, -M iPod-Touch-4G, model MC540) and the
// iPhone 4 (n90ap, recipe "n90": as n81, -M iPhone-4, 512 MiB, model MC603, its baseband node kept) and the S5L8920
// iPhone 3GS (n88ap, recipe "n88": kboot with its own NOR, -M n88, model MB715; its store unwhitened at the IPSW's
// SCEP epoch), and the S5L8922 iPod touch 3G (n18ap, recipe "n18": as n88, the NOR grafted, -M n18, model MC008).
// Ports ipad1_device.build's board steps,
// ipad1_keybag.py and ipad1_seal.py over the other modules; the build-time boots run through
// `LightTouchDevice` oneshot.
//
// Boot files by strategy: `iboot` (default) iBoot.bin (pattern-patched), nor.bin (packed, writable) and
// gid-blobs.bin; `kboot` (debugging, recipe.boot) kboot.bin and, for 4.x data protection, a blank nor.bin.
// Volumes: SystemEdits.buildK48 (system + data, the shared bake). Store: K48NAND. The keybag one-shot (4.x)
// and the seal (one clean halt) each boot once; a failure fails the preparation.

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import HostRuntime

final class K48Board: Board {
    let arch = "armv7"
    var seedPrefix: String {
        ["n81ap": "ipod4", "n90ap": "iphone4", "n88ap": "iphone3gs", "n18ap": "ipod3"][board] ?? "ipad1"
    }
    let board: String
    /// The kboot-only A4 boards (iPod touch 4G, iPhone 4): same SoC and pipeline; their KBoot.Board carries the DT differences.
    var kbootBoard: Bool { a4 != .k48 }
    var a4: KBoot.Board { ["n81ap": .n81, "n90ap": .n90, "n88ap": .n88, "n18ap": .n18][board] ?? .k48 }
    /// The S5L8920 family (-M n18, n88): the IPSW's NAND epoch.
    var s5l8920: Bool { a4.isS5L8920 }
    /// The emulator's facts about the board (its -M machine, modem, USB host), from the helper (check()).
    var hardware: DeviceInfo?
    let volumesStep = "Building the system and data volumes", keybagStep = "Creating the data-protection keybag"
    var bootStep: String { iboot ? "Writing the identity and boot chain" : "Writing the identity and boot image" }
    /// The seal boot halts through it_seal, a guest helper: none without them (guest_tools off).
    var needsSeal: Bool { systemOptions.guestTools }
    /// The recipe's options for the system and data volumes, with what the board decides: BTServer kept where the
    /// machine answers the HCI (KBoot.Board.bluetoothHCI).
    var systemOptions: SystemEdits.Options {
        var o = SystemEdits.Options(recipe: recipe, version: version)
        o.bluetooth = a4.bluetoothHCI
        #if os(Android)
        // On the Android n88 5.1.1 jailbreak boot, BTServer's sandboxed BlueTool keeps restarting, then
        // AppleSimpleUARTSync panics with "Assertion failed: _hwEnabled". Keep that guest job disabled
        // for this configuration until the controller survives those restarts.
        if o.jailbreak && board == "n88ap" && version == "5.1.1" { o.bluetooth = false }
        #endif
        return o
    }
    let recipe: FirmwareEntry.Recipe, version: String, strategy: String, iboot: Bool, dataProtection: Bool
    var helper: URL?, patcher: URL?, mbr: URL?, vols: SystemEdits.Result?
    var gidComponents: [String] = [], ramdisk: String?
    var shipped: [String] {
        iboot ? ["iBoot.bin", "nor.bin", "gid-blobs.bin"] : ["kboot.bin"] + (kbootNOR ? ["nor.bin"] : [])
    }
    /// A kboot device ships a writable NOR for 4.x data protection, and always on the N88, whose DT keeps its own
    /// NOR (blank on 3.x: NVRAM only).
    var kbootNOR: Bool { dataProtection || s5l8920 }
    var dieID: String { (ident?.dieID ?? []).joined(separator: ":") }
    /// What every boot of the device carries (the lock's "machine", which BootRecipe passes): the modem's IMEI (the
    /// identity's, which lockdownd/MobileGestalt hash into the UDID; a phone's lockdownd decides activation from
    /// CommCenter, and what the seal boot decides is what the store keeps), the recipe's pinned clock (a beta's
    /// lockdownd stops activating past its expiry date) and K48's BCM4329 CIS address (its wifi-mac property: the
    /// unit address KBoot/K48IBoot write to the device tree and NOR; the N81/N90 machines take theirs from /chosen).
    var machineOptions: [String: String] {
        var options: [String: String] = [:]
        options["imei"] = ident?["imei"]
        options["rtc-epoch"] = recipe.rtcEpoch.map(String.init)
        if board == "k48ap" { options["wifi-mac"] = ident?["wifi-mac"] }
        return options
    }
    var ident: UnitIdentity?
    /// The keybag and seal one-shots' limit. 7.x's launchd starts our RunAtLoad daemons (it_seal among them) about
    /// 170 s into the boot, and it_seal halts 40 s later: modem-on 7.0-7.0.6 seals took 118-229 s, 7.1.2's about
    /// 300 s, longer under host load. it_seal also waits out the first boot's data migration (up to 600 s past its
    /// settle): 6.1.6's took about 2 min on a Ryzen 7 3700X under TCG, so every release gets 900 s off the Mac's speed.
    var oneshotTimeout: Double = 900
    static func oneshotTimeout(productVersion: String) -> Double { 900 }

    /// A jailbroken device's kernel leaves code signatures to AMFI alone (amfi_get_out_of_my_way), as the
    /// jailbreaks' kernel patches did: with AMFI asking amfid about every ad hoc signed library, Substrate's launcher,
    /// once in launchd, puts its library into amfid too, amfid waits on itself and the boot stops before SpringBoard.
    static func bootArgs(jailbreak: Bool) -> String {
        KBoot.defaultBootArgs + (jailbreak ? " " + jailbreakBootArg : "")
    }
    static let jailbreakBootArg = "amfi_get_out_of_my_way=1"

    /// A prepared base's boot files (in the writable `base`) given a jailbroken base's boot-args (bootArgs): kboot.bin's
    /// boot_args command line, found through its trailer; or, on the iboot path, the string iBoot32Patcher wrote into
    /// iBoot.bin, extended over the certificate text it put it in, as the patcher does for the longer one. Returns
    /// the file it changed, nil when it already had them.
    static func jailbreakBootFiles(base: URL) throws -> String? {
        let fm = FileManager.default
        let kboot = base.appendingPathComponent("kboot.bin")
        if fm.fileExists(atPath: kboot.path) {
            var b = [UInt8](try Data(contentsOf: kboot))
            let t = b.count - 24
            guard t > 0, Array(b[t..<t + 8]) == Array("K48KBOOT".utf8) else {
                throw FirmwareError(.unsupported, "kboot.bin: no K48KBOOT trailer")
            }
            // boot_args: revision, version, 13 words, then the 256-byte command line (KBoot.build)
            let at = Int(le32(b, t + 16)) - Int(le32(b, t + 8)) + 56
            guard at > 0, at + 256 <= Int(le32(b, t + 20)) else {
                throw FirmwareError(.unsupported, "kboot.bin: boot_args outside the image")
            }
            let line = String(decoding: b[at..<at + 256].prefix { $0 != 0 }, as: UTF8.self)
            if line.split(separator: " ").contains(Substring(jailbreakBootArg)) { return nil }
            let new = Array((line + " " + jailbreakBootArg).utf8)
            guard new.count < 256 else { throw FirmwareError(.unsupported, "kboot.bin: boot-args too long") }
            b.replaceSubrange(at..<at + 256, with: new + [UInt8](repeating: 0, count: 256 - new.count))
            try Data(b).write(to: kboot)
            return kboot.lastPathComponent
        }
        let iboot = base.appendingPathComponent("iBoot.bin")
        var d = try Data(contentsOf: iboot)
        if d.range(of: Data((bootArgs(jailbreak: true) + "\0").utf8)) != nil { return nil }
        let old = Data((bootArgs(jailbreak: false) + "\0").utf8)
        let new = Data((bootArgs(jailbreak: true) + "\0").utf8)
        guard let r = d.range(of: old), d[r.upperBound...].range(of: old) == nil,
            r.lowerBound + new.count <= d.endIndex,
            d[r.upperBound..<r.lowerBound + new.count - 1].allSatisfy({ (0x20...0x7E).contains($0) })
        else {
            throw FirmwareError(.unsupported, "iBoot.bin: no boot-args string with room to grow")
        }
        d.replaceSubrange(r.lowerBound..<r.lowerBound + new.count, with: new)
        try d.write(to: iboot)
        return iboot.lastPathComponent
    }

    init(_ o: Preparer.Options) throws {
        guard let recipe = o.entry.recipe else { throw FirmwareError(.unsupported, "\(o.entry.id): no recipe") }
        self.recipe = recipe
        version = o.entry.version
        oneshotTimeout = Self.oneshotTimeout(productVersion: o.entry.version)
        board = o.entry.board
        let kbootOnly = o.entry.board != "k48ap"
        strategy = recipe.boot ?? (kbootOnly ? "kboot" : "iboot")
        guard strategy == "iboot" || strategy == "kboot" else {
            throw FirmwareError(.unsupported, "\(o.entry.id): unknown boot strategy \(strategy)")
        }
        guard !(kbootOnly && strategy == "iboot") else {
            throw FirmwareError(
                .unsupported,
                "\(o.entry.id): the \(HostRuntime.Board(rawValue: o.entry.board)?.marketingName ?? o.entry.board) boots by kboot only (no NAND boot chain yet)"
            )
        }
        iboot = strategy == "iboot"
        dataProtection = recipe.options["writable_nor"] ?? FirmwareEntry.dataProtection(version: version)
    }

    func check(_ c: Recipe.Context) throws {
        guard recipe.storage == "16g", recipe.dataSize == "partition" else {
            throw FirmwareError(.unsupported, "\(c.e.id): storage \(recipe.storage), data_size \(recipe.dataSize)")
        }
        guard let helper = c.o.helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw FirmwareError(
                .internal,
                "the seal boots need --helper (LightTouchDevice); got \(c.o.helper?.path ?? "none")"
            )
        }
        self.helper = helper
        patcher = K48IBoot.patcher(helper: helper)
        Machines.helper = helper
        guard let hardware = HostRuntime.Board(rawValue: board)?.hardware else {
            throw FirmwareError(.internal, "\(helper.lastPathComponent)'s emulator library has no machine for \(board)")
        }
        self.hardware = hardware
    }

    /// The iBoot names exactly one kernelcache path (N72Board.kernelcachePath) and it is SystemEdits.kernelcachePath.
    static func kernelcacheFit(iboot: Data) -> FitCheck.Fit {
        let piece = "kernelcache at the path iBoot loads"
        do {
            let path = try N72Board.kernelcachePath(iboot)
            return FitCheck.Fit(
                piece,
                fits: path == SystemEdits.kernelcachePath,
                path == SystemEdits.kernelcachePath
                    ? "iBoot names /\(path)" : "iBoot names /\(path), the bake installs /\(SystemEdits.kernelcachePath)"
            )
        } catch {
            return FitCheck.Fit(piece, fits: false, "\(error)")
        }
    }

    func identity(seed: String) throws -> UnitIdentity {
        var ident = try UnitIdentity.synthesize(
            seed: seed,
            storage: recipe.storage,
            modelNumber: kbootBoard ? a4.modelNumber : nil
        )
        // The radio boards: the modem reports the IMEI, and lockdownd/MobileGestalt hash it into the UDID.
        if HostRuntime.Board(rawValue: board)?.kbootPhone == true { ident = ident.addingIMEI(seed: seed) }
        self.ident = ident
        return ident
    }

    /// iboot: iBoot.bin, nor.bin, gid-blobs.bin; kboot: kboot.bin.
    func bootFiles(_ c: Recipe.Context) throws {
        let ident = try self.ident.filled("the identity")
        let e = c.e
        let ipsw = c.ipsw
        let bootArgs = Self.bootArgs(jailbreak: c.cydia != nil)
        let kernel = try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped)
        try FitCheck.checkBootArgs(c.fit, kernel: kernel, args: bootArgs)
        // A jailbroken device's kernel is sandbox-patched so Substrate's inserted library loads inside the built-in
        // app profiles; recorded here, applied to the boot kernel (kboot.bin below, or the iBoot kernelcache in volumes).
        var jailbreakKernel: Data?
        if c.cydia != nil {
            try c.fit.check(FitCheck.sandboxPatch(kernel), required: false)
            jailbreakKernel = (try? SandboxPatch.apply([UInt8](kernel)).kernel).map { Data($0) }
        }
        // both chains add it
        try c.fit.check(FitCheck.deviceTreeProperty(kernel, "arm-io/usb-complex", "hsic-enabled"), required: false)
        if iboot {
            // fsboot: the kernelcache goes where this iBoot loads it from, which must be the path the volumes step installs to
            try c.fit.check(Self.kernelcacheFit(iboot: try Data(contentsOf: c.decFile("iBoot.bin"))), required: true)
            // The real iBoot chain: catalog GID records, a re-encrypted hsic-enabled DeviceTree, the pattern-patched
            // iBoot, and the packed NOR (ipad1_device build's "iBoot + NOR" step; ipad1_gid + ipad1_iboot).
            let (blobs, names) = try K48IBoot.gidBlobs(ipsw, entry: e)
            gidComponents = names
            try blobs.write(to: c.file("gid-blobs.bin"))
            let prefix = "Firmware/all_flash/all_flash.\(e.board).production/"
            var allFlash: [String: Data] = [:]
            for m in try ipsw.names() where m.hasPrefix(prefix) && m.hasSuffix(".img3") {
                let d = try ipsw.read(m)
                let t = try N72NOR.type(of: d)
                guard allFlash[t] == nil else {
                    throw FirmwareError(.unsupported, "duplicate img3 type \(t) in all_flash")
                }
                allFlash[t] = d
            }
            guard let dtImg3 = allFlash["dtre"] else {
                throw FirmwareError(.unsupported, "\(e.id): all_flash has no DeviceTree")
            }
            allFlash["dtre"] = try K48IBoot.hostUSBDeviceTree(
                img3: dtImg3,
                plaintext: try Data(contentsOf: c.decFile("DeviceTree.bin")),
                gidBlobs: blobs
            )
            let manifest = String(decoding: try ipsw.read(prefix + "manifest"), as: UTF8.self).split(
                whereSeparator: \.isWhitespace
            )
            let order = try manifest.map { try N72NOR.type(of: ipsw.read(prefix + String($0))) }
            let patched = try K48IBoot.patchIBoot(
                try Data(contentsOf: c.decFile("iBoot.bin")),
                patcher: patcher.filled("iBoot32Patcher"),
                bootArgs: bootArgs,
                log: c.log
            )
            try patched.write(to: c.file("iBoot.bin"))
            try K48IBoot.buildNOR(identity: ident, allFlash: allFlash, order: order, bootArgs: bootArgs).write(
                to: c.file("nor.bin")
            )
        } else {
            try KBoot.write(
                decrypted: c.decrypted(), to: c.file("kboot.bin"), identity: ident, bootArgs: bootArgs,
                kernelOverride: jailbreakKernel
            )
            if kbootNOR && !dataProtection { try Data(repeating: 0xFF, count: 1 << 20).write(to: c.file("nor.bin")) }
        }
    }

    /// MBR, system + data volumes (+ activation); the iBoot fsboot kernelcache goes in the system volume.
    /// The store geometry: the part's default, or the recipe's nand_vendor_type variant (iOS 3.0: one VFL bank per CE).
    var geometry: K48NAND.Geometry { recipe.nandVendorType == 0x10001 ? .k48With16GBV1 : .k48With16GB }

    nonisolated(nonsending) func volumes(_ c: Recipe.Context) async throws {
        let mbr = c.work.appendingPathComponent("mbr.bin")
        self.mbr = mbr
        // At least what a restore gives this unit (MinimumSystemPartition + padding). The catalog's 1280 MiB left an
        // iPhone 4 6.1.3 (a 1212 MiB rootfs) 5.0 % free on its writable root, at HFS's root very-low-disk limit
        // (5 %): a fresh unit showed "Storage Almost Full". The restore's 1372 MiB leaves 11.4 %.
        let stockMiB = try RestoreInfo(c.ipsw).systemPartitionMiB(storage: recipe.storage) ?? 0
        let systemMiB = max(recipe.systemMiB, stockMiB)
        c.log("system partition \(systemMiB) MiB (catalog \(recipe.systemMiB), restore \(stockMiB))")
        try K48NAND.makeMBR(geometry: geometry, systemMiB: systemMiB).write(to: mbr)
        let parts = K48NAND.partitions(mbr: [UInt8](try Data(contentsOf: mbr)))
        var kernelcacheImg3: Data?
        if iboot {
            guard let kc = try BuildComponents.load(c.ipsw, board: c.e.board)["KernelCache"] else {
                throw FirmwareError(.unsupported, "\(c.e.id): the IPSW names no KernelCache")
            }
            let raw = try c.ipsw.read(kc)
            // A jailbroken iBoot-chain device boots a sandbox-patched kernelcache: patch the plaintext and put it back
            // in the IMG3 iBoot loads, re-encrypted with the component's key so iBoot decrypts it as it does the stock
            // one. Unresolved kernels keep the stock kernelcache; bootFiles' sandbox-patch fit records it.
            if c.cydia != nil {
                let k = try c.e.key(forPath: kc)
                if let ivHex = k.iv, let iv = Data(hex: ivHex), let key = Data(hex: k.key),
                    let plain = try? Data(contentsOf: c.decFile("kernelcache.mach")),
                    let patched = try? SandboxPatch.rewrapKernelcache(
                        original: raw, plaintextKernel: [UInt8](plain), iv: iv, key: key)
                {
                    c.log("[sandbox] kernelcache re-wrapped with sb_evaluate patched at 0x\(String(patched.found.address, radix: 16))")
                    kernelcacheImg3 = patched.img3
                }
            }
            kernelcacheImg3 = kernelcacheImg3 ?? raw
        }
        var options = systemOptions
        options.cydia = c.cydia
        options.language = c.o.language
        options.keyboards = c.o.keyboards
        let vols = try await SystemEdits.buildK48(
            rootfs: c.decFile("rootfs.dmg"),
            work: c.work,
            systemBytes: parts[0].count * 4096,
            dataBytes: Int64(parts[1].count) * 4096,
            options: options,
            helpers: c.o.guestTools,
            kernelcache: kernelcacheImg3,
            kernel: try Data(contentsOf: c.decFile("kernelcache.mach"), options: .alwaysMapped),
            dataVolumeUUID: Array(SHA256.hash(data: Data("k48 data volume \(c.seed)".utf8)).prefix(8)),
            fit: c.fit,
            log: c.log
        )
        self.vols = vols
        for n in vols.notes { c.emit(.warning(n)) }
        c.activation = vols.activation
        c.guestPackage = vols.guestPackage
        c.engine = vols.engine
    }

    nonisolated(nonsending) func store(_ c: Recipe.Context) async throws {
        let mbr = try self.mbr.filled("the MBR")
        let vols = try self.vols.filled("the volumes")
        var epoch = try K48NAND.signatureEpoch(kernelcache: c.decFile("kernelcache.mach"))
        // WMR refuses a whitened store on a board whose DT does not ask for one ("Metadata whitening not supported").
        let whitening = try DeviceTree(Data(contentsOf: c.decFile("DeviceTree.bin"))).props.values.contains {
            $0["metadata-whitening"] != nil
        }
        c.log("NAND metadata whitening \(whitening ? "on" : "off") (the DT's)")
        if s5l8920, let scep = try K48NAND.restoreEpoch(c.ipsw, board: c.e.board) {
            epoch = scep  // a store behind it waits for an epoch roll only restored performs
            c.log("NAND signature epoch \(epoch) (Restore.plist SCEP)")
        } else {
            c.log("NAND signature epoch \(epoch) (this kernel's FIL)")
        }
        try await K48NAND.build(
            geometry: geometry,
            mbr: mbr,
            kernelVersion: K48NAND.kernelVersion(kernelcache: c.decFile("kernelcache.mach")),
            epoch: epoch,
            system: vols.system,
            data: .image(vols.data),
            out: c.nand,
            whitening: whitening,
            sigFlags: recipe.nandSigFlags.map(UInt32.init),
            log: c.log
        )
        try? FileManager.default.removeItem(at: vols.system)
        try? FileManager.default.removeItem(at: vols.data)
    }

    func norURL(_ c: Recipe.Context) -> URL? { iboot || kbootNOR ? c.file("nor.bin") : nil }

    /// 4.x data protection: effaceable + system keybag from the IPSW's own Update ramdisk (ipad1_keybag): the
    /// ramdisk with it_keybag as restored_external, booted once as md0 on the store + NOR. One attempt: a panic fails
    /// the preparation, which starts over (a new device has nothing to keep).
    nonisolated(nonsending) func keybag(_ c: Recipe.Context) async throws {
        let fm = FileManager.default
        // keybag runs only with dataProtection, which ships a NOR on either chain
        let nor = try norURL(c).filled("the NOR")
        if !iboot { try Data(repeating: 0xFF, count: 1 << 20).write(to: nor) }  // iboot already built the packed NOR
        let (source, name) = try await Recipe.keybagRamdisk(c)
        ramdisk = name
        let work = c.work
        let rd = try await Preparer.ramdiskWithHelper(
            source,
            helper: c.o.guestTools.appendingPathComponent(SystemEdits.Helpers.name("it_keybag", arch)),
            work: work
        )
        let kboot = work.appendingPathComponent("kboot-restore.bin")
        try KBoot.write(decrypted: c.decrypted(), to: kboot, identity: ident.filled("the identity"), ramdisk: rd)
        let norBefore = try Data(contentsOf: nor)
        let (r, text) = try oneshot(
            c,
            .kernel(image: kboot.path, writableNOR: nor.path),
            store: c.nand,
            overlay: nil,
            serial: work.appendingPathComponent("keybag-1.log"),
            stop: "panic(",
            timeout: oneshotTimeout
        )
        for line in text.split(separator: "\n") where line.contains("it_keybag:") { c.log(String(line)) }
        guard r.exited, text.contains(Preparer.keybagDone) else {
            let why =
                text.split(separator: "\n").lazy.compactMap { line in
                    line.range(of: "panic(").map { String(line[$0.lowerBound...].prefix(160)) }
                }.first
                ?? (r.exited ? "halted without the keybag" : "no halt")
            throw FirmwareError(.oneshotFailed, "keybag boot: \(why)")
        }
        guard try Data(contentsOf: nor) != norBefore else {
            throw FirmwareError(.oneshotFailed, "keybag boot: effaceable was not written to the NOR")
        }
        for u in [rd, kboot] { try? fm.removeItem(at: u) }
    }

    /// ipad1_seal: boot the store until the guest halts (it_seal); the clean halt writes the FTL context. No check
    /// boot after it: the lock's hashes are the sanity check, and a bad seal fails the device's first start.
    func seal(_ c: Recipe.Context) throws {
        let work = c.work
        let store = c.nand
        let nor = norURL(c)
        // ipad1_seal --iboot: enter the patched iBoot with the catalog keys; the writable NOR is where this boot's
        // effaceable/NVRAM writes land (no base nor=). die-id must be non-zero or iBoot rejects it.
        let boot: BootRecipe.IPadBoot =
            iboot
            ? .iBoot(
                image: c.file("iBoot.bin").path,
                writableNOR: c.file("nor.bin").path,
                gidBlobs: c.file("gid-blobs.bin").path
            )
            : .kernel(image: c.file("kboot.bin").path, writableNOR: nor?.path)
        let serial = work.appendingPathComponent("seal.log")
        let (r, text) = try oneshot(
            c,
            boot,
            store: store,
            overlay: nil,
            serial: serial,
            stop: nil,
            timeout: oneshotTimeout
        )
        guard r.exited, text.contains(Preparer.halting) else {
            throw FirmwareError(
                .oneshotFailed,
                "seal boot: \(r.exited ? "QEMU exited without it_seal" : "no clean halt") after \(Int(r.seconds)) s"
            )
        }
    }

    /// One `LightTouchDevice` oneshot boot of the store as the device boots (BootRecipe.iPad, the lock's machine
    /// options), with no keyboard and no reboot: the one-shot ends when the guest shuts down, and a restart is a
    /// shutdown too (4.3's launchd turns it_seal's reboot(RB_HALT) into its own clean reboot(RB_AUTOBOOT); 5.x's halt
    /// restarts through the PMU), as qemu-ios imgtools/ipad1_seal.py (8edc395979). `overlay` nil writes the store.
    func oneshot(
        _ c: Recipe.Context,
        _ boot: BootRecipe.IPadBoot,
        store: URL,
        overlay: URL?,
        serial: URL,
        stop: String?,
        stopPattern: String? = nil,
        timeout: Double
    ) throws -> (Preparer.OneShot, String) {
        let ipad = BootRecipe.IPad(
            boot: boot,
            nand: store.path,
            overlay: overlay?.path,
            dieID: dieID,
            usbAddress: nil,
            wifi: true,
            machineOptions: machineOptions,
            oneShot: true
        )
        let config = try BootRecipe.iPad(
            ipad,
            hardware: hardware.filled("the board's hardware"),
            serial: "file:\(serial.path)",
            audio: ["-audio", "driver=none"],
            netdev: nil,
            restore: []
        )
        return try Preparer.oneshot(
            helper.filled("the helper"),
            argv: config.argv,
            machine: config.machine,
            serial: serial,
            stop: stop,
            stopPattern: stopPattern,
            timeout: timeout,
            work: c.work,
            log: c.log
        )
    }

    func lock(_ c: Recipe.Context) throws -> [String: Any] {
        let helper = try self.helper.filled("the helper")
        let patcher = try self.patcher.filled("iBoot32Patcher")
        let mbr = try self.mbr.filled("the MBR")
        let vols = try self.vols.filled("the volumes")
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        var outputs: [String: Any] = ["nand": ["files": c.nandHashes]]
        if iboot {
            for (k, n) in [("iboot", "iBoot.bin"), ("gid_blobs", "gid-blobs.bin"), ("nor", "nor.bin")] {
                outputs[k] = try Recipe.fileRecord(c, n)
            }
        } else {
            outputs["kboot"] = try Recipe.fileRecord(c, "kboot.bin")
            outputs["nor"] = opt(kbootNOR ? try Recipe.fileRecord(c, "nor.bin") : nil)
        }
        return [
            "boot_strategy": strategy,
            "gid_components": iboot ? gidComponents : NSNull(),
            "iboot_signature_checks": iboot ? "pattern-patched" : NSNull(),
            "tool": [
                "helper": helper.path, "helper_sha256": try Preparer.digest(helper, SHA256()),
                "iboot32patcher": opt(
                    iboot
                        ? ["path": patcher.path, "sha256": try Preparer.digest(patcher, SHA256())] as [String: Any]
                        : nil
                ),
                "built": ["OpenGLES": opt(vols.engine)],
            ],
            "inputs": [
                "kernelcache": "kernelcache.mach", "devicetree": "DeviceTree.bin", "restore_ramdisk": opt(ramdisk),
                "mbr": ["sha256": try Preparer.digest(mbr, SHA256())], "stash": NSNull(),
            ],
            "identity": ["die_id": dieID],
            "outputs": outputs,
            "gl_test": systemOptions.glTest,
            "skip_setup": systemOptions.skipSetup,
            "machine": machineOptions,
        ]
    }
}
