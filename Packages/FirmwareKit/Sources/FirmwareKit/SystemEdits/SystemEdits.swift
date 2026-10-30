// SystemEdits: the edits a prepared system volume gets, shared by every board (the PAC, AppSync, the SpringBoard
// job, activation, the guest-package seed; helper names and the dyld cache by arch), and the k48 recipe's
// system and data volumes (buildK48). Ports ipad1_rootfs.py build (pristine base, no stash, no Lockdown) +
// bake --seal as ipad1_device.build drives them, in one mount of the system volume:
//
//   system.img  the IPSW rootfs, grown to partition 1; rw fstab; SpringBoard env (GL CoreAnimation or
//               CA_ENABLE_OGL=0) + stdio on /dev/console; [appsync] process-local libappsync.dylib injected into installd;
//               [ca_ogl] the GL front end as OpenGLES.framework/OpenGLES
//               (+ dyld's override switch: OpenGLES is cached); [web_proxy] the PAC; the guest helpers; storage_mounter loads
//               it_msmquiet; BTServer Disabled (unless the machine answers its HCI); lockdownd activated (Activation); the guest-package loader and
//               seed package from armv7.itpack (GuestPackage.seed), whose jobs it_boot loads.
//   data.img    fresh journaled HFSX "Data" (sparse) seeded with the system volume's /private/var skeleton
//               (+ [web_proxy] the en0 AirPort service with the PAC), owners
//               from the source catalog, else root / mobile by rule.
//
// Owners: the mount is noowners, so every file written lands as the host user; the catalog records are
// patched offline afterwards (HFSPlusVolume.setOwner), as the oracle does.
//
//   let r = try await SystemEdits.buildK48(rootfs: dmg, work: dir, systemBytes: p1 * 4096, dataBytes: p2 * 4096,
//                                    options: .init(recipe: entry.recipe!), helpers: guestTools) { print($0) }
//   r.system, r.data, r.activation
//
// `helpers` is a flat directory of prebuilt, signed files (the app bundles it; see `Helpers`).

public import FirmwareSchema
import Foundation
#if canImport(Android)
import Android
#endif

public enum SystemEdits {
    /// The recipe options SystemEdits reads (FirmwareEntry.Recipe.options), plus bake's switches.
    public struct Options: Sendable, Equatable {
        public var caOGL = true, appsync = false, webProxy = true
        /// A journaled data volume: data_journal, else FirmwareEntry.journaledData (unjournaled before 3.2).
        public var dataJournal = true
        /// bake --seal: the one-shot clean halt the seal step needs (always on for a prepared device).
        public var seal = true
        /// bake --gl-test: the GL fixture job (test devices only: recipe option gl_test, never set in the catalog).
        public var glTest = false
        /// Leave BTServer enabled: the board's machine answers the HCI (KBoot.Board.bluetoothHCI, which K48Board sets;
        /// never a recipe option). Off, BTServer is Disabled: with nothing on the UART, BlueTool's HCI_Reset never
        /// completes.
        public var bluetooth = false
        /// Bake the guest helpers, their jobs and the guest-package seed. Off for firmware whose dyld predates
        /// LC_DYLD_INFO (3.0, as the iPod 2G's 7A341): such a device gets no it_seal either, so no seal boot.
        public var guestTools = true
        /// A dated build (recipe rtc_epoch: a developer beta pinned inside its release window): the data ark says
        /// unbricked (seedData). Its clock holds because the machine's network tells its time (seedData).
        public var dated = false
        /// skip_setup (firmwarekit create --skip-setup, never set in the catalog): the data volume says Setup Assistant
        /// is finished (seedFinishedSetup), so an iOS 5 or later device starts at the Home screen.
        public var skipSetup = false
        /// jailbreak (firmwarekit create --jailbreak, never set in the catalog): what a jailbreak of the time leaves on
        /// the device: afc2 (installAFC2), lockdown's AFC over the whole file system, and Cydia with Substrate
        /// (installCydia) from `cydia`, the bootstrap Cydia.bootstrap fetched.
        public var jailbreak = false
        public var cydia: URL?
        /// The device's language, a BCP 47 tag ("fr-FR", its region the device's too); nil: the Mac's preferred
        /// languages and region (seedLanguage).
        public var language: String?
        /// The device's keyboards besides its language's, Mac input source IDs (com.apple.keylayout.French); nil: the
        /// Mac's enabled ones (seedLanguage).
        public var keyboards: [String]?
        /// Disable the jobs of services that cannot work on an emulated device (deadServiceJobs; recipe option
        /// quiet_services, default on): the first start and every boot are CPU-bound, and these ran at each.
        public var quietServices = true
        public init() {}
        /// `version`: the entry's iOS version, for the options its rules decide (FirmwareEntry.journaledData).
        public init(recipe: FirmwareEntry.Recipe, version: String) {
            let o = recipe.options
            caOGL = o["ca_ogl"] ?? true
            appsync = o["appsync"] ?? false
            webProxy = o["web_proxy"] ?? true
            glTest = o["gl_test"] ?? false
            dataJournal = o["data_journal"] ?? FirmwareEntry.journaledData(version: version)
            guestTools = o["guest_tools"] ?? true
            dated = recipe.rtcEpoch != nil
            skipSetup = o["skip_setup"] ?? false
            jailbreak = o["jailbreak"] ?? false
            quietServices = o["quiet_services"] ?? true
        }
    }

    /// What the helpers directory holds, by file name (flat).
    public enum Helpers {
        /// guest tool -> (install path, mode); ipad1_rootfs.TOOLS (+ SEAL_TOOL, GLTEST_TOOL).
        public static let tools: [(name: String, path: String, mode: mode_t)] = [
            ("it_pbd", "usr/local/bin/it_pbd", 0o755), ("it_prefs", "usr/local/bin/it_prefs", 0o755),
            msmQuiet,
        ]
        public static let msmQuiet: (name: String, path: String, mode: mode_t) = (
            "it_msmquiet.dylib", "usr/local/lib/it_msmquiet.dylib", 0o755
        )
        public static let seal = ("it_seal", "usr/local/bin/it_seal", mode_t(0o755))
        public static let glTest = ("it_gltest", "usr/local/bin/it_gltest", mode_t(0o755))
        /// launchd job file names baked into System/Library/LaunchDaemons (mode 0644). The helpers' own jobs
        /// (it-pbd, it-prefs) are the seed package's, loaded by it_boot.
        public static let jobs: [String] = []
        /// The guest packages and the loader (qemu-ios contrib/guest-package/build.sh), one per arch.
        public static let itpack = "armv7.itpack"
        public static func itpack(_ arch: String) -> String { arch + ".itpack" }
        /// A helper built for `arch`: the armv7 build keeps the bare name, the others carry the arch
        /// (it_keybag-armv6).
        public static func name(_ base: String, _ arch: String) -> String { arch == "armv7" ? base : base + "-" + arch }
        /// The legacy-linked build of a helper (it_pbd-legacy, libappsync-legacy.dylib): what a firmware whose dyld
        /// predates LC_DYLD_INFO_ONLY (armv7 on 3.0) loads.
        public static func legacy(_ name: String) -> String {
            name.hasSuffix(".dylib") ? String(name.dropLast(6)) + "-legacy.dylib" : name + "-legacy"
        }
        public static let sealJob = "com.qemu.it-seal.plist", glTestJob = "com.qemu.it-gltest.plist"
        /// The fat armv6+armv7 AppSync dylib.
        public static let appsync = "libappsync.dylib", appsyncLauncher = "appsync-launch"
        /// The GL front end (qemu-ios contrib/gles-public: one fat armv6 + armv7 OpenGLES.framework/OpenGLES for
        /// every firmware), and the name table it and the host speak (the fit check proves a 5.x firmware's
        /// dispatch fields are all rows of it).
        public static let openGLES = "OpenGLES", glesNames = "gles-names.h"
    }

    public struct Result: Sendable {
        public var system: URL, data: URL
        public var activation: Activation.Result?
        /// The GL front end installed (helpers file name), if any.
        public var engine: String?
        /// The seed package baked (GuestPackage.seed's record: the lock's guest_package).
        public var guestPackage: GuestPackage.Record?
        public var notes: [String] = []
    }

    // Volume paths (ipad1_rootfs constants).
    static let fstab = "private/etc/fstab"
    static let fstabRW = "/dev/disk0s1 / hfs rw 0 1\n/dev/disk0s2 /private/var hfs rw,nosuid,nodev 0 2\n"
    static let fstabRO = fstabRW.replacingOccurrences(of: "/ hfs rw 0", with: "/ hfs ro 0")
    static let daemons = "System/Library/LaunchDaemons"
    static let springBoardJob = daemons + "/com.apple.SpringBoard.plist"
    static let msmJob = daemons + "/com.apple.mobile.storage_mounter.plist"
    /// The stock jobs that raise the USB "not supported" notice for a device nothing claims (the emulated keyboard):
    /// MobileStorageMounter through 4.x; 5.x moved it to USBDeviceArbitrator, LaunchBuddy's catch-all for IOUSBDevice;
    /// 7.x to DeviceOMatic, which launchd starts for a removable IOUSBDevice.
    static let noticeJobs = [
        (msmJob, "com.apple.mobile.storage_mounter"),
        (daemons + "/com.apple.mobile.usb_device_arbitrator.plist", "com.apple.mobile.usb_device_arbitrator"),
        (daemons + "/com.apple.device-o-matic.plist", "com.apple.device-o-matic"),
    ]
    static let btJob = daemons + "/com.apple.BTServer.plist"
    /// Jobs launchd starts at boot for services an emulated device has no use for, each Disabled where present: Apple's
    /// servers for them are gone or refuse these releases, or the hardware is absent. Traced on n81ap 6.1.6 (it_seal
    /// per-process CPU): together ~12% of the first start's guest CPU and a share of every boot's.
    /// Not usbptpd: every USB configuration carries PTP, and the device stack starts no USB until each function has
    /// registered, so without it usbmux never enumerates (iPhone 4 4.2.1 and 4.3.5: the host's SETUP is NAKed).
    static let deadServiceJobs = [
        "com.apple.imagent", "com.apple.imavagent",  // iMessage, FaceTime
        "com.apple.itunescloudd",  // iTunes in the Cloud
        "com.apple.mediastream.mstreamd",  // Photo Stream
        "com.apple.ubd", "com.apple.syncdefaultsd",  // iCloud documents, key-value store (not backupd: MobileBackup
        // raises without it, and DataMigrator and atc abort)
        "com.apple.apsd",  // push notifications
        "com.apple.AOSNotification",  // Find My iPhone
        "com.apple.mobile.fud",  // accessory firmware updates
        "com.apple.mobile.softwareupdated", "com.apple.softwareupdateservicesd",  // software update
        "com.apple.OTATaskingAgent", "com.apple.OTACrashCopier",
    ].map { daemons + "/" + $0 + ".plist" }
    static let installdJob = daemons + "/com.apple.mobile.installd.plist"
    static let appsyncPath = "usr/lib/libappsync.dylib", appsyncLauncherPath = "usr/libexec/appsync-launch"
    static func dyldCache(_ arch: String) -> String { "System/Library/Caches/com.apple.dyld/dyld_shared_cache_" + arch }
    static let dyldOverride = "System/Library/Caches/com.apple.dyld/enable-dylibs-to-override-cache"
    static let lockdownd = "usr/libexec/lockdownd"
    static let retired = ["usr/local/bin/it_notip", daemons + "/com.qemu.it-notip.plist"]
    /// Under /usr/share, not /usr/local: 4.x's MobileSafari sandbox (builtin profile "MobileSafari") can't read
    /// /usr/local, so its CFNetwork found no PAC and went DIRECT, while every unsandboxed client used the proxy.
    static let pacPath = "usr/share/ltm/proxy.pac"
    /// On the Mac the PAC sends public hosts to the app's proxy (the 10.0.2.100 guestfwd the frontend
    /// installs). The phone has no such proxy, so there the same file goes DIRECT: otherwise every host
    /// costs one connection to a dead proxy before CFNetwork falls back, which some clients never do.
    static let pac: String = {
        #if os(Android)
            return """
                function FindProxyForURL(url, host) { return "DIRECT"; }

                """
        #else
            return """
                function FindProxyForURL(url, host) {
                    if (isPlainHostName(host)) return "DIRECT";
                    if (/^\\d+\\.\\d+\\.\\d+\\.\\d+$/.test(host) &&
                        (isInNet(host, "10.0.0.0", "255.0.0.0") || isInNet(host, "172.16.0.0", "255.240.0.0") ||
                         isInNet(host, "192.168.0.0", "255.255.0.0") || isInNet(host, "169.254.0.0", "255.255.0.0") ||
                         isInNet(host, "127.0.0.0", "255.0.0.0"))) return "DIRECT";
                    return "PROXY 10.0.2.100:3128; DIRECT";
                }

                """
        #endif
    }()
    static let sbEnv = ["CA_ENABLE_OGL": "0", "MBX2D_PAGE_FLIP": "0"]
    static let sbEnvCAOGL = ["MBX2D_PAGE_FLIP": "0"]
    static let mobileTop: Set<String> = ["mobile", "ea"]  // uid 501 on the real unit; the rest of /var is root

    /// The k48 system + data volumes into `work` (system.img, data.img; scratch next to them).
    /// `rootfs` is the decrypted rootfs DMG (or a bare HFS volume); `systemBytes`/`dataBytes` are partition
    /// 1 and 2 of the MBR in bytes. `kernel`: the decrypted kernelcache the fit checks read.
    /// The path the K48 iBoot loads the kernel from (fsboot); the raw IPSW img3 kernelcache is installed there
    /// for the real-iBoot chain (ipad1_rootfs.build --kernelcache). kboot omits it (the kernel is in the bundle).
    public static let kernelcachePath = "System/Library/Caches/com.apple.kernelcaches/kernelcache"

    nonisolated(nonsending) public static func buildK48(
        rootfs: URL,
        work: URL,
        systemBytes: Int,
        dataBytes: Int64,
        options o: Options,
        helpers: URL,
        kernelcache: Data? = nil,
        kernel: Data? = nil,
        dataVolumeUUID: [UInt8]? = nil,
        fit: FitCheck.Log = FitCheck.Log(),
        log: (String) -> Void = { _ in }
    ) async throws -> Result {
        let fm = FileManager.default
        let system = work.appendingPathComponent("system.img")
        let data = work.appendingPathComponent("data.img")
        var result = Result(system: system, data: data)
        func helper(_ name: String) throws -> URL {
            let u = helpers.appendingPathComponent(name)
            guard fm.fileExists(atPath: u.path) else {
                throw FirmwareError(.internal, "guest helper \(name) missing from \(helpers.path)")
            }
            return u
        }

        // Check every helper before touching a volume.
        var tools = o.guestTools ? Helpers.tools : []
        var jobs = o.guestTools ? Helpers.jobs : []
        if o.seal && o.guestTools {
            tools.append(Helpers.seal)
            jobs.append(Helpers.sealJob)
        }
        if o.glTest {
            tools.append(Helpers.glTest)
            jobs.append(Helpers.glTestJob)
        }
        for t in tools {
            if let why = MachOSignature.guestToolProblem(try helper(t.name)) {
                throw FirmwareError(.internal, "\(helpers.path)/\(t.name): \(why)")
            }
        }
        for j in jobs { _ = try helper(j) }
        if o.guestTools { _ = try helper(Helpers.itpack("armv7")) }
        if o.appsync, let why = MachOSignature.appSyncProblem(try helper(Helpers.appsync)) {
            throw FirmwareError(.internal, "\(helpers.path)/\(Helpers.appsync): \(why)")
        }

        log("system volume from \(rootfs.lastPathComponent)")
        try await UDIF.extractRootfs(dmg: rootfs, to: system)
        let newest: UInt32  // the IPSW's newest file: everything the recipe writes gets dated as of it
        do {
            let v = try HFSPlusVolume(system)
            guard v.totalBlocks * v.blockSize <= systemBytes else {
                throw FirmwareError(
                    .unsupported,
                    "system volume (\(v.totalBlocks * v.blockSize) bytes) is larger than partition 1 (\(systemBytes))"
                )
            }
            log(
                "\(v.signature) \(v.totalBlocks) x \(v.blockSize) B blocks, \(v.freeBlocks) free; partition 1 is \(systemBytes >> 20) MiB"
            )
            newest = try v.newestDate()
        }
        try await VolumeMount.grow(system, toBytes: systemBytes)

        log("editing the system volume")
        let skeleton = work.appendingPathComponent("var-skeleton")
        try? fm.removeItem(at: skeleton)
        var rootOwned: [String] = []
        var rootModes: [(path: String, mode: UInt16)] = []
        var mobileOwned: [String] = []
        var productMajor = 0
        var productVersion = "", productBuild = ""
        var keyboards: KeyboardCatalog?
        var formats: Set<String>?
        try await VolumeMount.withMounted(system, at: work.appendingPathComponent("mnt-system")) { m in
            let at = { (rel: String) in m.appendingPathComponent(rel) }
            keyboards = KeyboardCatalog(at("System/Library/TextInput"))
            formats = regionFormats(m)
            // every baked helper proven to load on this firmware (FitCheck.loads), read before any edit
            let fw = FitCheck.Firmware(root: m, arch: "armv7", kernelcache: kernel)
            // a dyld without LC_DYLD_INFO_ONLY (3.0's: none of its own executables carry one) takes the legacy builds
            let legacy = fw.precedent[MachO32.lcDyldInfoOnly] == nil
            let pick = { (n: String) in legacy ? Helpers.legacy(n) : n }
            if legacy { log("this dyld predates LC_DYLD_INFO_ONLY: the legacy-linked helpers and AppSync") }
            // it_msmquiet only in the jobs that raise the notice it recognizes; else left out, jobs untouched (3.1.x
            // has no storage_mounter job at all). One job raises it per version, so the others' misfits are no warning.
            let msm = Helpers.msmQuiet
            let candidates = noticeJobs.filter { o.guestTools && fm.fileExists(atPath: at($0.0).path) }
            let quietFits = fit.checkAny(
                try candidates.map { job, label in
                    FitCheck.msmQuiet(
                        fw,
                        program: try stockProgram(m, job, label: label),
                        dylib: try Data(contentsOf: helper(pick(msm.name)))
                    )
                }
            )
            let quietJobs = zip(candidates, quietFits).filter(\.1).map(\.0)
            let quiet = !quietJobs.isEmpty
            if !quiet { tools.removeAll { $0.name == msm.name } }
            if o.guestTools {
                for f in FitCheck.prefs(fw, FitCheck.itPrefs) {
                    try fit.check(f, required: false, outcome: "kept: it_prefs skips the key at boot")
                }
            } else {
                fit.notInstalled("guest helpers", "guest_tools off")
            }
            for t in tools where t.name != msm.name {
                try fit.check(
                    FitCheck.loads(pick(t.name), Data(contentsOf: try helper(pick(t.name))), on: fw),
                    required: true
                )
            }
            if o.appsync {
                try FitCheck.checkAppSync(fit, fw, helpers: helpers, name: pick(Helpers.appsync))
            } else {
                fit.notInstalled("AppSync", "appsync off")
            }
            if let kernelcache {  // real-iBoot fsboot: the raw IPSW img3 kernelcache in the system volume
                try mkdirs(at(kernelcachePath).deletingLastPathComponent())
                try put(kernelcache, at(kernelcachePath), mode: 0o644)
            }
            let systemVersion = NSDictionary(contentsOf: at("System/Library/CoreServices/SystemVersion.plist"))
            productVersion = systemVersion?["ProductVersion"] as? String ?? ""
            productBuild = systemVersion?["ProductBuildVersion"] as? String ?? ""
            productMajor = Int(productVersion.split(separator: ".").first ?? "") ?? 0
            // 7.x's launchd cannot remount / rw (mount_hfs: Operation not permitted) and reboots; keep its stock ro root
            try put(Data((productMajor >= 7 ? fstabRO : fstabRW).utf8), at(fstab))
            if o.webProxy {
                try fit.check(
                    FitCheck.webProxy(FitCheck.Firmware(root: m, arch: "armv7")),
                    required: false,
                    outcome: "kept: the PAC is unused"
                )
                rootOwned += try installPAC(m)
            }
            if o.caOGL {  // GL first
                let (engine, owned) = try installCAOGL(m, helpers: helpers, arch: "armv7", fw: fw, fit: fit, log: log)
                result.engine = engine
                rootOwned += owned
            }
            let env = o.caOGL ? sbEnvCAOGL : sbEnv
            try fit.check(
                FitCheck.environment(
                    fw,
                    env.keys.sorted().map { [$0] },
                    also: result.engine != nil
                        ? [(Helpers.openGLES, try Data(contentsOf: helper(Helpers.openGLES)))] : []
                ),
                required: false,
                outcome: "kept: a switch nothing reads is inert"
            )
            try editSpringBoardJob(m) { env, d in
                env.addEntries(from: o.caOGL ? sbEnvCAOGL : sbEnv)
                d["StandardOutPath"] = "/dev/console"
                d["StandardErrorPath"] = "/dev/console"
            }
            if o.jailbreak {
                guard let bootstrap = o.cydia else { throw FirmwareError(.internal, "jailbreak: no Cydia bootstrap") }
                let jb = try installJailbreak(m, bootstrap: bootstrap, typeinBySubstrate: false)
                log(jb.afc2)
                log(jb.cydia)
                rootOwned += jb.root
                mobileOwned += jb.mobile
                rootModes += jb.modes
            }
            if o.appsync {
                _ = try installAppSync(
                    m,
                    helper: try helper(pick(Helpers.appsync)),
                    cache: dyldCache("armv7"),
                    log: log
                )
                rootOwned.append(appsyncPath)
            }
            // bake
            for rel in retired
            where (try? fm.destinationOfSymbolicLink(atPath: at(rel).path)) != nil
                || fm.fileExists(atPath: at(rel).path)
            {
                try fm.removeItem(at: at(rel))
            }
            for t in tools {
                try mkdirs(at(t.path).deletingLastPathComponent())
                try put(Data(contentsOf: try helper(pick(t.name))), at(t.path), mode: t.mode)
            }
            for j in jobs { try put(Data(contentsOf: try helper(j)), at(daemons + "/" + j), mode: 0o644) }
            for (job, label) in quietJobs {
                try rewritePlist(at(job)) { d in
                    guard d["Label"] as? String == label else {
                        throw FirmwareError(.unsupported, "\(job): not \(label)'s job")
                    }
                    dict(d, "EnvironmentVariables")["DYLD_INSERT_LIBRARIES"] = "/" + msm.path
                }
            }
            if !o.bluetooth { try rewritePlist(at(btJob)) { $0["Disabled"] = true } }
            if o.quietServices {
                let quieted = deadServiceJobs.filter { fm.fileExists(atPath: at($0).path) }
                for job in quieted { try rewritePlist(at(job)) { $0["Disabled"] = true } }
                log("quiet services: \(quieted.count) jobs disabled")
            }
            do {
                result.activation = try activate(m, log: log)
            } catch let e as ActivationFailure {
                guard let r = Activation.dataArkRoute(lockdownd: try Data(contentsOf: at(lockdownd))) else { throw e }
                log(
                    "lockdownd: no binary strategy; activation by the data ark (\((r.dataArk?.keys.sorted() ?? []).joined(separator: ", ")))"
                )
                result.activation = r
            }
            rootOwned.append(lockdownd)
            // what this bake left out on purpose: AppSync when off, it_msmquiet where it does not fit
            let omitted = Set((o.appsync ? [] : ["/" + appsyncPath]) + (quiet ? [] : ["/" + msm.path]))
            if o.guestTools {
                let (seeded, record) = try seedGuestPackage(
                    m,
                    helpers: helpers,
                    arch: "armv7",
                    gles: result.engine != nil,
                    omitted: omitted,
                    fit: fit,
                    log: log
                )
                result.guestPackage = record
                rootOwned += seeded
            }
            rootOwned +=
                ["usr/local", "usr/local/bin", "usr/local/lib"].filter { fm.fileExists(atPath: at($0).path) }
                + jobs.map { daemons + "/" + $0 } + tools.map(\.path)

            // /private/var skeleton for the data volume
            try copyTree(at("private/var"), skeleton)
        }
        let sys = try HFSPlusVolume(system, writable: true)
        var n = try sys.setOwner(rootOwned, uid: 0, gid: 0) + sys.setOwner(mobileOwned, uid: 501, gid: 501)
        for (path, mode) in rootModes { n += try sys.setOwner([path], uid: 0, gid: 0, mode: mode) }
        let owners = try sys.owners(under: "private/var")
        let dated = try sys.normalize(after: newest, to: newest)
        log("system volume: \(n) catalog records set to root, \(dated) dated as of the IPSW's newest file")

        log("data volume (\(dataBytes / 1_000_000) MB, sparse) seeded from /private/var")
        defer { try? fm.removeItem(at: skeleton) }
        try seedData(
            skeleton,
            o,
            productMajor: productMajor,
            dataArk: result.activation?.dataArk,
            keyboards: keyboards,
            formats: formats,
            log: log
        )
        if let installed = try seedPreinstalledAssets(
            skeleton,
            major: productMajor,
            version: productVersion,
            build: productBuild,
            region: String(UnitIdentity.iPadRegion.prefix { $0 != "/" })
        ) {
            log("preinstalled assets: \(installed.count) installed as mobileassetd would at the first boot")
        }
        try? fm.removeItem(at: data)
        try await VolumeMount.makeHFS(data, size: dataBytes, journaled: o.dataJournal)
        var byOwner: [[UInt32]: [String]] = [:]
        try await VolumeMount.withMounted(data, at: work.appendingPathComponent("mnt-data")) { m in
            try copyTree(skeleton, m)  // merges into the root, which takes /private/var's mode
            try walk(m) { rel in
                let own: [UInt32] =
                    owners[rel].map { [$0.uid, $0.gid] }
                    ?? (mobileTop.contains(String(rel.prefix { $0 != "/" })) ? [501, 501] : [0, 0])
                byOwner[own, default: []].append(rel)
            }
        }
        let dv = try HFSPlusVolume(data, writable: true)
        var patched = 0
        for (own, paths) in byOwner.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            patched += try dv.setOwner(paths, uid: own[0], gid: own[1])
        }
        let summary = byOwner.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map {
            "\($0.key[0]):\($0.key[1]) x\($0.value.count)"
        }
        log(
            "owners from the skeleton, else root / mobile by rule: \(summary.joined(separator: ", ")) (\(patched) catalog records patched)"
        )
        try dv.normalize(after: newest, to: newest, uuid: dataVolumeUUID)
        if productMajor >= 5 {
            // A restore formats the data volume with content protection. From 5.0 installd gives each app's tmp
            // protection class 4 and, refused, leaves the container without Documents (Library and tmp only).
            try dv.setContentProtection()
            log("data volume: content protection on")
        }
        for d in ["mnt-system", "mnt-data"] { try? fm.removeItem(at: work.appendingPathComponent(d)) }
        return result
    }

    // MARK: - The shared bake (every board's system volume)

    /// The web-proxy PAC at /usr/share/ltm/proxy.pac; `dirs` are created too (the iPod's SystemConfiguration
    /// on the system volume). Returns the paths to make root-owned.
    static func installPAC(_ m: URL, dirs: [String] = []) throws -> [String] {
        var owned: [String] = []
        for rel in ["usr/share/ltm"] + dirs {
            try mkdirs(m.appendingPathComponent(rel))
            owned.append(rel)
        }
        try put(Data(pac.utf8), m.appendingPathComponent(pacPath))
        return owned + [pacPath]
    }

    /// Inject the helper into the firmware's installation service
    /// (installd or mobile_installation_proxy), retaining stock libmis and its cache.
    static func installAppSync(_ m: URL, helper: URL, cache: String, log: (String) -> Void) throws -> (
        status: String, job: String
    ) {
        let fm = FileManager.default
        let cached = fm.fileExists(atPath: m.appendingPathComponent(cache).path)
        if !cached, let why = MachOSignature.earlyARMProblem(helper) {
            throw FirmwareError(.unsupported, "AppSync: \(why)")
        }
        let line = "stock libmis retained; installation-service interposition"
        log(line)
        try mkdirs(m.appendingPathComponent(appsyncPath).deletingLastPathComponent())
        try put(Data(contentsOf: helper), m.appendingPathComponent(appsyncPath), mode: 0o644)
        let job = ["com.apple.mobile.installd.plist", "com.apple.installd.plist"].map {
            m.appendingPathComponent(daemons + "/" + $0)
        }
        .first { fm.fileExists(atPath: $0.path) }
        if let job {
            try rewritePlist(job) { dyldInsert($0, "/" + appsyncPath) }
            return (line, job.lastPathComponent)
        }
        // 2.x installs in the Lockdown-launched mobile_installation_proxy, before installd existed.
        let services = m.appendingPathComponent("System/Library/Lockdown/Services.plist")
        try rewritePlist(services) { root in
            // dict(): off Apple platforms a nested dictionary reads back as a Swift value, never an NSMutableDictionary.
            guard root["com.apple.mobile.installation_proxy"] != nil,
                case let service = dict(root, "com.apple.mobile.installation_proxy"),
                let arguments = service["ProgramArguments"] as? [String],
                arguments.first == "/usr/libexec/mobile_installation_proxy"
            else {
                throw FirmwareError(.unsupported, "no supported installation service")
            }
            let launcher = helper.deletingLastPathComponent().appendingPathComponent(Helpers.appsyncLauncher)
            if let why = MachOSignature.earlyARMProblem(launcher) {
                throw FirmwareError(.unsupported, "AppSync launcher: \(why)")
            }
            try put(Data(contentsOf: launcher), m.appendingPathComponent(appsyncLauncherPath), mode: 0o755)
            service["ProgramArguments"] = ["/" + appsyncLauncherPath] + arguments
        }
        return (line, "Services.plist:com.apple.mobile.installation_proxy")
    }

    static let lockdownServices = "System/Library/Lockdown/Services.plist"
    static let afcd = "usr/libexec/afcd", afc2d = "usr/libexec/afc2d", afc2Job = daemons + "/com.apple.afc2.plist"
    /// afc2, as the jailbreaks of the time added it: a com.apple.afc2 lockdown service serving "/" as root, so the Mac
    /// can browse the whole file system over USB. Through 7.0 it is the stock afcd under old-style lockdown at "/".
    /// 7.1's afcd (afc-218) takes neither --lockdown nor -d: it is only an XPC service at the media folder and exits
    /// on those options (Files: device connection lost). There afc2 is a copy of it, afc2d, serving "/" as its own
    /// XPC service com.apple.afc2 from a launchd job without the stock job's user (so as root); afcd's own sandbox
    /// profile still applies, and the root extension it issues itself covers "/". Returns the log line and the files it added (root's).
    static func installAFC2(_ m: URL) throws -> (line: String, root: [String]) {
        let stock = try Data(contentsOf: m.appendingPathComponent(afcd))
        let oldStyle = stock.range(of: Data("--lockdown".utf8)) != nil
        try rewritePlist(m.appendingPathComponent(lockdownServices)) { services in
            guard services["com.apple.afc"] != nil else {
                throw FirmwareError(.unsupported, "\(lockdownServices) has no com.apple.afc service")
            }
            services["com.apple.afc2"] =
                oldStyle
                ? [
                    "AllowUnactivatedService": true, "Label": "com.apple.afc2",
                    "ProgramArguments": ["/usr/libexec/afcd", "--lockdown", "-d", "/"],
                ]
                : ["AllowUnactivatedService": true, "Label": "com.apple.afc2", "XPCServiceName": "com.apple.afc2"]
        }
        if oldStyle { return ("afc2: com.apple.afc2 runs afcd at / (Lockdown/Services.plist)", []) }
        try put(try afc2Copy(stock), m.appendingPathComponent(afc2d), mode: 0o755)
        let jobURL = m.appendingPathComponent(daemons + "/com.apple.afcd.plist")
        guard let job = PlistBridge.mutableDictionary(contentsOf: jobURL), job["Label"] as? String == "com.apple.afcd"
        else {
            throw FirmwareError(.unsupported, "\(jobURL.lastPathComponent): not com.apple.afcd's job")
        }
        job["Label"] = "com.apple.afc2"
        job["MachServices"] = ["com.apple.afc2": true]
        job["ProgramArguments"] = ["/" + afc2d]
        job.removeObject(forKey: "UserName")
        try put(
            PropertyListSerialization.data(fromPropertyList: PlistBridge.native(job), format: .xml, options: 0),
            m.appendingPathComponent(afc2Job)
        )
        return (
            "afc2: com.apple.afc2 is afc2d, afcd at / as an XPC service (Lockdown/Services.plist)", [afc2d, afc2Job]
        )
    }

    /// 7.1's afcd serving "/" as the XPC service com.apple.afc2: its root and service name replaced in place (each
    /// string by one no longer, padded with NULs), then signed again ad hoc, keeping its entitlements.
    static func afc2Copy(_ afcd: Data) throws -> Data {
        var d = afcd
        for (from, to) in [("/private/var/mobile/Media", "/"), ("com.apple.afcd", "com.apple.afc2")] {
            let f = Data((from + "\0").utf8)
            let t = Data((to + "\0").utf8) + Data(count: f.count - to.utf8.count - 1)
            var found = false
            while let r = d.range(of: f) {
                d.replaceSubrange(r, with: t)
                found = true
            }
            guard found else { throw FirmwareError(.unsupported, "afcd: no \(from)") }
        }
        return try Activation.signed(d)
    }

    /// The program of the stock job `job` (volume-relative), checked by label.
    static func stockProgram(_ m: URL, _ job: String, label: String) throws -> String {
        guard let d = NSDictionary(contentsOf: m.appendingPathComponent(job)), d["Label"] as? String == label,
            let program = (d["ProgramArguments"] as? [String])?.first ?? d["Program"] as? String
        else {
            throw FirmwareError(.unsupported, "\(job): not \(label)'s job")
        }
        return program
    }

    /// SpringBoard's launchd job, checked by label: `edit` gets its EnvironmentVariables and the job.
    static func editSpringBoardJob(_ m: URL, _ edit: (NSMutableDictionary, NSMutableDictionary) throws -> Void) throws {
        try rewritePlist(m.appendingPathComponent(springBoardJob)) { d in
            guard d["Label"] as? String == "com.apple.SpringBoard" else {
                throw FirmwareError(.unsupported, "\(springBoardJob): not SpringBoard's job")
            }
            try edit(dict(d, "EnvironmentVariables"), d)
        }
    }

    /// lockdownd activated in place (Activation); the caller makes it root-owned.
    static func activate(_ m: URL, log: (String) -> Void) throws -> Activation.Result {
        log("Activating device")
        return try Activation.run(on: m.appendingPathComponent(lockdownd))
    }

    /// The guest-package loader and the arch's seed package (GuestPackage.seed of <arch>.itpack).
    static func seedGuestPackage(
        _ m: URL,
        helpers: URL,
        arch: String,
        gles: Bool,
        omitted: Set<String> = [],
        fit: FitCheck.Log,
        log: (String) -> Void
    ) throws -> ([String], GuestPackage.Record) {
        let (seeded, record) = try GuestPackage.seed(
            volume: m,
            itpack: helpers.appendingPathComponent(Helpers.itpack(arch)),
            gles: gles,
            omitted: omitted,
            fit: fit
        )
        log("seed package \(record.family) serial \(record.seed), hooks \(record.hooks)")
        return (seeded, record)
    }

    /// [ca_ogl] the GL front end (qemu-ios contrib/gles-public) as OpenGLES.framework/OpenGLES, + dyld's override
    /// switch where the stock OpenGLES is in the shared cache, once FitCheck.glesFrontEnd has proven, from the pristine
    /// firmware, everything it looks up at run time: a misfit fails the prepare rather than quietly producing a
    /// software-CoreAnimation device. Nothing under OpenGLES (GLEngine, libGFXShared, a gld plugin) is touched.
    /// Returns the helper name and the files to own by root.
    static func installCAOGL(
        _ m: URL,
        helpers: URL,
        arch: String,
        fw: FitCheck.Firmware,
        fit: FitCheck.Log,
        log: (String) -> Void
    ) throws -> (engine: String, owned: [String]) {
        let src = helpers.appendingPathComponent(Helpers.openGLES)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw FirmwareError(.internal, "\(src.path) missing")
        }
        let bin = try Data(contentsOf: src)
        let names = (try? String(contentsOf: helpers.appendingPathComponent(Helpers.glesNames), encoding: .utf8)) ?? ""
        do {
            try fit.check(FitCheck.glesFrontEnd(fw, binary: bin, names: names), required: true)
        } catch let e as FirmwareError where e.code == .unsupported {
            throw FirmwareError(
                .unsupported,
                "the recipe asks for GL CoreAnimation (ca_ogl) and this firmware cannot "
                    + "composite through the GL bridge: \(e.message)"
            )
        }
        let cached = fw.cache?.image("/" + FitCheck.openGLES) != nil
        let backup = try GuestPackage.preserveHook(volume: m, target: FitCheck.openGLES)
        if cached { try setOverrideSwitch(m, image: FitCheck.openGLES) }
        log(
            "GL front end \(Helpers.openGLES) as OpenGLES.framework/OpenGLES; \(cached ? "cached OpenGLES overridden by the file" : "the stock file replaced")"
        )
        try put(bin, m.appendingPathComponent(FitCheck.openGLES), mode: 0o755)
        return (Helpers.openGLES, [FitCheck.openGLES, backup] + (cached ? [dyldOverride] : []))
    }

    /// ipad1_rootfs.gli_dispatch_info: the sanity line about what the shim will find at load (the firmware's
    /// dispatch slot count, and the fields the shipped name table, gles-names.h in the helpers, does not name).
    static func glesSanity(_ cache: Data, helpers: URL) -> String {
        guard let have = GLIDispatch.fields(in: cache) else {
            return "no __GLIFunctionDispatchRec @encode in the shared cache: the shim will read OpenGLES's trampolines"
        }
        let names = (try? String(contentsOf: helpers.appendingPathComponent(Helpers.glesNames), encoding: .utf8)) ?? ""
        let known = Set(names.matches(of: /(?m)^GLES_FN\(\w+,\s*(\w+),/).map { String($0.1) })
        let unknown = have.filter { !known.contains($0) }
        return "GLI dispatch: \(have.count) slots, \(unknown.count) unknown to the name table"
            + (unknown.isEmpty ? "" : " (\(unknown.prefix(8).joined(separator: ", ")))")
    }

    /// ipad1_rootfs.gli_uncache: when `image` is in the volume's shared cache `cache`, create dyld's
    /// enable-dylibs-to-override-cache switch so the file installed over it loads. Returns the status line.
    static func overrideCachedImage(_ m: URL, image: String, cache: String) throws -> String {
        let name = (image as NSString).lastPathComponent
        guard try DyldSharedCache(contentsOf: m.appendingPathComponent(cache)).image("/" + image) != nil else {
            return "no cached \(name)"
        }
        try setOverrideSwitch(m, image: image)
        return "cached \(name) overridden by the file (enable-dylibs-to-override-cache)"
    }

    /// Fails closed if this dyld has no such switch.
    static func setOverrideSwitch(_ m: URL, image: String) throws {
        let dyld = try Data(contentsOf: m.appendingPathComponent("usr/lib/dyld"))
        guard dyld.range(of: Data(("/" + dyldOverride + "\0").utf8)) != nil else {
            throw FirmwareError(
                .unsupported,
                "\((image as NSString).lastPathComponent) is in the shared cache and this dyld has no enable-dylibs-to-override-cache switch: the GL shim cannot load"
            )
        }
        let dir = m.appendingPathComponent(dyldOverride).deletingLastPathComponent().path
        var st = stat()
        guard stat(dir, &st) == 0, chmod(dir, st.st_mode & 0o7777 | 0o200) == 0 else {
            throw FirmwareError(.internal, "chmod \(dir)")
        }
        try put(Data(), m.appendingPathComponent(dyldOverride))
        chmod(dir, st.st_mode & 0o7777)
    }

    // MARK: - Plist edits (ipad1_rootfs.springboard_env, dyld_insert, wifi_proxy_prefs)

    /// d[k] as a mutable dictionary, inserting `def` when absent (Python's setdefault).
    @discardableResult
    static func dict(
        _ d: NSMutableDictionary,
        _ k: String,
        _ def: @autoclosure () -> NSMutableDictionary = NSMutableDictionary()
    ) -> NSMutableDictionary {
        if let v = d[k] as? NSMutableDictionary { return v }
        let v = (d[k] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary ?? def()
        d[k] = v
        return v
    }

    static func moveFirst(_ d: NSMutableDictionary, _ k: String, _ item: String) {
        d[k] = [item] + ((d[k] as? [Any]) ?? []).filter { ($0 as? String) != item }
    }

    static func dyldInsert(_ d: NSMutableDictionary, _ lib: String) {
        let env = dict(d, "EnvironmentVariables")
        var libs = ((env["DYLD_INSERT_LIBRARIES"] as? String) ?? "").split(separator: ":").map(String.init)
        if !libs.contains(lib) { libs.append(lib) }
        env["DYLD_INSERT_LIBRARIES"] = libs.joined(separator: ":")
    }

    static let netSet = "4C54E7A1-0B5E-4D6B-9A1C-534554000001"
    static let wifiService = "4C54E7A1-0B5E-4D6B-9A1C-574946490000"
    /// The current set's Network dict, creating CurrentSet / Sets / the set as Python's setdefault chain does.
    static func currentNetwork(_ d: NSMutableDictionary) -> NSMutableDictionary {
        if d["CurrentSet"] == nil { d["CurrentSet"] = "/Sets/" + netSet }
        let cur = String(
            (d["CurrentSet"] as? String ?? "").split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        )
        return dict(
            dict(dict(d, "Sets"), cur, NSMutableDictionary(dictionary: ["UserDefinedName": "Automatic"])),
            "Network"
        )
    }

    /// preferences.plist: the AirPort service on en0 (the unit's own shape) carrying the proxy PAC, first.
    /// A network service's Proxies: the web proxy's PAC.
    static var pacProxies: NSDictionary {
        [
            "ExceptionsList": ["*.local", "169.254/16"], "FTPPassive": 1, "ProxyAutoConfigEnable": 1,
            "ProxyAutoConfigURLString": "file:///" + pacPath,
        ]
    }
    /// What the /private/var skeleton gets before it becomes the data volume: the web proxy, the language, Setup finished, the data
    /// ark. Nothing for timed, dated or not: a dated machine's network answers NTP in the device's own time (qemu-ios
    /// net/slirp.c), so automatic time and zone stay on, as a real unit has them, and timed takes lockdown's zone
    /// (with "Set Automatically" off, 6.x and 7.x timed drop every zone change, lockdown's included).
    static func seedData(
        _ skeleton: URL,
        _ o: Options,
        productMajor: Int,
        dataArk: [String: String]?,
        keyboards: KeyboardCatalog? = nil,
        formats: Set<String>? = nil,
        log: (String) -> Void
    ) throws {
        let sc = skeleton.appendingPathComponent("preferences/SystemConfiguration")
        if o.webProxy { try seedPlist(sc.appendingPathComponent("preferences.plist"), wifiProxyPrefs) }
        let language = try seedLanguage(
            skeleton,
            tag: o.language,
            keyboards: o.keyboards,
            catalog: keyboards,
            formats: formats
        )
        if let language {
            log("language \(language.language), region \(language.locale), keyboards \(language.keyboards)")
        }
        if o.skipSetup, productMajor >= 5 {
            let (l, locale) = language.map { ($0.language, $0.locale) } ?? ("en", "en_US")
            try seedFinishedSetup(skeleton, major: productMajor, language: l, locale: locale)
            log("Setup Assistant: seeded as finished (iOS \(productMajor))")
        }
        if let dataArk {
            // 7.0 beta 1's lockdownd turns the brick state on for an ark without one and lifts it only for a valid
            // activation record, which this route has none of (Setup then insists on activating online). A dated
            // build says unbricked, as lockdownd's own "factoryactivation unbricks by default".
            try seedPlist(skeleton.appendingPathComponent("root/Library/Lockdown/data_ark.plist")) { d in
                d.addEntries(from: dataArk)
                if o.dated { d["-BrickState"] = false }
            }
        }
    }

    static func wifiProxyPrefs(_ d: NSMutableDictionary) {
        let svc = dict(
            dict(d, "NetworkServices"),
            wifiService,
            NSMutableDictionary(dictionary: [
                "Interface": [
                    "DeviceName": "en0", "Hardware": "AirPort", "Type": "Ethernet", "UserDefinedName": "AirPort",
                ],
                "IPv4": ["ConfigMethod": "DHCP"], "IPv6": ["ConfigMethod": "Automatic"], "DNS": [String: Any](),
                "UserDefinedName": "AirPort",
            ])
        )
        svc["Proxies"] = pacProxies
        let net = currentNetwork(d)
        dict(net, "Service")[wifiService] = ["__LINK__": "/NetworkServices/" + wifiService]
        dict(dict(net, "Interface"), "en0", NSMutableDictionary(dictionary: ["AirPort": ["JoinMode": "Automatic"]]))
        moveFirst(dict(dict(net, "Global"), "IPv4"), "ServiceOrder", wifiService)
    }

    /// Applies `edit` to the plist at `url` in place (keeping its binary/XML format and its catalog record).
    static func rewritePlist(_ url: URL, _ edit: (NSMutableDictionary) throws -> Void) throws {
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        guard
            let d = PlistBridge.mutable(
                try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: url),
                    options: .mutableContainersAndLeaves,
                    format: &fmt
                )
            ) as? NSMutableDictionary
        else {
            throw FirmwareError(.unsupported, "\(url.lastPathComponent) is not a dictionary plist")
        }
        try edit(d)
        try put(
            PropertyListSerialization.data(
                fromPropertyList: PlistBridge.native(d),
                format: fmt == .binary ? .binary : .xml,
                options: 0
            ),
            url
        )
    }

    /// Edits the plist in place, or creates it (XML, as configd writes) from an empty dictionary.
    static func seedPlist(_ url: URL, _ edit: (NSMutableDictionary) throws -> Void) throws {
        if FileManager.default.fileExists(atPath: url.path) { return try rewritePlist(url, edit) }
        try mkdirs(url.deletingLastPathComponent())
        let d = NSMutableDictionary()
        try edit(d)
        try put(PropertyListSerialization.data(fromPropertyList: PlistBridge.native(d), format: .xml, options: 0), url)
    }

    // MARK: - Files (in place, umask-default modes, as the oracle's open()/makedirs())

    /// Writes `data` into `url` in place (truncating an existing file, so it keeps its catalog record), creating
    /// it 0666 & ~umask if absent; with `mode`, then sets the permission bits.
    static func put(_ data: Data, _ url: URL, mode: mode_t? = nil) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o666)
        guard fd >= 0 else { throw FirmwareError(.internal, "open \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let n = data.withUnsafeBytes { data.isEmpty ? 0 : write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else {
            throw FirmwareError(.internal, "write \(url.path): \(String(cString: strerror(errno)))")
        }
        if let mode, fchmod(fd, mode) != 0 { throw FirmwareError(.internal, "chmod \(url.path)") }
    }

    /// mkdir -p with 0777 & ~umask for each directory created.
    static func mkdirs(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) { return }
        try mkdirs(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o777) == 0 || errno == EEXIST else {
            throw FirmwareError(.internal, "mkdir \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    static func permissions(_ url: URL) throws -> mode_t {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw FirmwareError(.internal, "stat \(url.path)") }
        return st.st_mode & 0o7777
    }

    /// shutil.copytree(symlinks=True, dirs_exist_ok=True) with copy2: symlinks as symlinks, file content
    /// written plainly (an HFS-compressed source lands uncompressed), then mode and mtime. No xattrs or flags.
    static func copyTree(_ src: URL, _ dst: URL) throws {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: src.path)
        let keep: [FileAttributeKey: Any] = [
            .posixPermissions: attrs[.posixPermissions] ?? 0o644, .modificationDate: attrs[.modificationDate] ?? Date(),
        ]
        switch attrs[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            try fm.createSymbolicLink(
                atPath: dst.path,
                withDestinationPath: fm.destinationOfSymbolicLink(atPath: src.path)
            )
            return
        case .typeDirectory?:
            if !fm.fileExists(atPath: dst.path) {
                guard mkdir(dst.path, 0o777) == 0 else {
                    throw FirmwareError(.internal, "mkdir \(dst.path): \(String(cString: strerror(errno)))")
                }
            }
            for n in try fm.contentsOfDirectory(atPath: src.path) {
                try copyTree(src.appendingPathComponent(n), dst.appendingPathComponent(n))
            }
        default:
            try put(Data(contentsOf: src), dst)
        }
        try fm.setAttributes(keep, ofItemAtPath: dst.path)
    }

    /// Every path under `root` (relative, directories and symlinks included), skipping macOS junk at any level.
    static func walk(_ root: URL, _ body: (String) throws -> Void) throws {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return }
        while let rel = e.nextObject() as? String {
            if VolumeMount.junk.contains((rel as NSString).lastPathComponent) {
                if (e.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { e.skipDescendants() }
                continue
            }
            try body(rel)
        }
    }
}
