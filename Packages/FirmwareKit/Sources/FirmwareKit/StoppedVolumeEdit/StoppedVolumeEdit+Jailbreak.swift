import Foundation
import HostRuntime

extension StoppedVolumeEdit {
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
        guard !lock.jailbroken else { throw FirmwareError(.unsupported, "this device is jailbroken already") }
        let session = try await begin(device: device, policy: policy, log: log)
        do {
            guard let point = try await mount(device: device, id: session.id, policy: policy).mountPoint else {
                throw FirmwareError(.internal, "jailbreak: the volume isn't mounted")
            }
            let jb = try SystemEdits.installJailbreak(
                URL(fileURLWithPath: point),
                bootstrap: bootstrap,
                typeinBySubstrate: lock.board == "n72ap"
            )
            log(jb.afc2)
            log(jb.cydia)
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
