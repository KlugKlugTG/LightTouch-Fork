import FirmwareSchema
import Foundation
import HostRuntime

extension StoppedVolumeEdit {
    /// On the real-iBoot K48 chain (`boot_strategy == "iboot"`), decrypt `/System/Library/Caches/.../kernelcache`
    /// with the entry's key from `device.lock.json`, apply the Seatbelt `sb_evaluate` patch, and re-wrap the IMG3 so
    /// Substrate's out-of-container dylib loads succeed just as on a freshly jailbroken preparation.
    static func patchMountedKernelcacheIfNeeded(mount: URL, lock: DeviceLock, log: (String) -> Void) throws {
        guard lock.bootStrategy == "iboot" else { return }
        let kcURL = mount.appendingPathComponent(SystemEdits.kernelcachePath)
        guard FileManager.default.fileExists(atPath: kcURL.path) else { return }
        guard case .object(let entryObj) = lock.entry,
            let content = entryObj["content"],
            let contentData = try? JSONEncoder().encode(content),
            let entry = try? JSONDecoder().decode(FirmwareEntry.self, from: contentData),
            let kcKey = entry.keys["kernelcache"] ?? entry.keys["KernelCache"],
            let ivHex = kcKey.iv,
            let iv = Data(hex: ivHex),
            let key = Data(hex: kcKey.key)
        else { return }
        let raw = try Data(contentsOf: kcURL)
        guard let plain = try? LZSS.complzss(IMG3.decrypt(raw, iv: iv, key: key)),
            let patched = try? SandboxPatch.rewrapKernelcache(
                original: raw,
                plaintextKernel: [UInt8](plain),
                iv: iv,
                key: key
            )
        else { return }
        try patched.img3.write(to: kcURL)
        log("[sandbox] kernelcache re-wrapped with sb_evaluate patched at 0x\(String(patched.found.address, radix: 16))")
    }

    /// The jailbreak option on an existing, stopped device (firmwarekit edit --action jailbreak): the edits a
    /// jailbroken preparation makes (SystemEdits.installJailbreak from `bootstrap`, Cydia.bootstrap's), in one stopped
    /// edit, so the device keeps its apps and data. The new generation's lock says `jailbroken` (DeviceLock.jailbroken),
    /// and on the K48 family its boot files carry the jailbroken boot-args (K48Board.jailbreakBootFiles).
    nonisolated(nonsending) public static func jailbreak(
        device: URL,
        bootstrap: URL,
        policy: StorageRecordPolicy = .standalone,
        log: (String) -> Void = { _ in }
    ) async throws {
        let lock = try {
            let owner = try OwnedStorageRecord.acquire(device: device, policy: policy)
            defer { withExtendedLifetime(owner) {} }
            return try DeviceLock.read(base: VolumeExport.ResolvedSource(owner: owner).base.deletingLastPathComponent())
        }()
        guard let lock, (Int(lock.productVersion?.split(separator: ".").first ?? "") ?? 0) >= 2 else {
            throw FirmwareError(.unsupported, "the jailbreak needs iPhone OS 2.0 or later")
        }
        let session = try await begin(device: device, policy: policy, log: log)
        do {
            guard let point = try await mount(device: device, id: session.id, policy: policy).mountPoint else {
                throw FirmwareError(.internal, "jailbreak: the volume isn't mounted")
            }
            let mount = URL(fileURLWithPath: point)
            let jb = try SystemEdits.installJailbreak(
                mount,
                bootstrap: bootstrap,
                typeinBySubstrate: lock.board == "n72ap"
            )
            log(jb.afc2)
            log(jb.cydia)
            try patchMountedKernelcacheIfNeeded(mount: mount, lock: lock, log: log)
            #if os(Android)
            if lock.board == "n88ap", lock.productVersion == "5.1.1" {
                let job = mount.appendingPathComponent("System/Library/LaunchDaemons/com.apple.BTServer.plist")
                if FileManager.default.fileExists(atPath: job.path) {
                    try SystemEdits.rewritePlist(job) { $0["Disabled"] = true }
                }
            }
            #endif
            var bootFile: String?
            try await commit(device: device, id: session.id, policy: policy, log: log) { system, base in
                let volume = try HFSPlusVolume(system, writable: true)
                for (path, mode) in jb.modes { try volume.setOwner([path], uid: 0, gid: 0, mode: mode) }
                // The N72 machine boots every device with what Substrate needs; the K48 family's boot-args say it.
                if lock.board != "n72ap" { bootFile = try K48Board.jailbreakBootFiles(base: base) }
                return ["jailbroken": true]
            }
            if let bootFile { log("\(bootFile): boot-args += \(K48Board.jailbreakBootArg)") }
        } catch {
            try? await discard(device: device, id: session.id, policy: policy)
            throw error
        }
    }
}
