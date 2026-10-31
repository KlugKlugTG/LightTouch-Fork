// firmwarekit: the preparer. Its commands and their options are FirmwareSchema's FirmwareCommand types, which the
// app spawns it with; `firmwarekit help COMMAND` prints one's usage.
//
// create's stdout is JSON Lines only; diagnostics go to stderr. Exit 0 after done, 1 after an error event, 64 for a
// command line it doesn't take; SIGTERM, or the parent (the app) exiting, cancels (children stopped, images under
// --out detached, exit 143) and leaves --out to the caller. Closed command pipes cannot interrupt owned cleanup.
// --guest-tools defaults to ../Resources/guest-tools next to this executable (the app bundle's), --helper to the
// LightTouchDevice beside it.
//
// mount/export rebuild the device's HFS+ volumes from base + overlay into sparse images in --out (default: a new
// temp dir) and print one JSON line per volume: {volume, image, clean, repaired, seconds, and for mount device +
// mountPoint (attached read-only, visible in Finder)}. With --root, mount puts the device's one tree there instead,
// out of Finder's sidebar: system at DIR, data on DIR/private/var. unmount detaches them (data first) and deletes
// --out. An error prints {"error": ...} and exits 1.

import ArgumentParser
import CHostFast
import FirmwareKit
import FirmwareSchema
import Foundation
#if canImport(Android)
import Android
#endif
import HostRuntime

// A phone's little cores make preparation several times slower; the build-time boots inherit this.
lt_prefer_fast_cores()

let commandOutput = PipeOutput(fileDescriptor: STDOUT_FILENO)
@Sendable func emit(_ event: PrepareEvent) {
    commandOutput.write(Data((event.json + "\n").utf8))
}

/// `path` with ~ expanded, standardized.
func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

struct Firmwarekit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "firmwarekit",
        version: FirmwareKit.version,
        subcommands: FirmwareCommand.all.map { $0 }
    )

    func run() throws { throw ValidationError("a command is required") }
}

/// `operation` under a CommandLifetime (cancellation on SIGTERM or the parent exiting), then its status.
@MainActor func supervised(
    cleanup: (@Sendable () async throws -> Void)? = nil,
    _ operation: @escaping @Sendable () async -> Int32
) async -> Never {
    let lifetime = CommandLifetime(output: commandOutput, cleanup: cleanup, operation: operation)
    exit(await lifetime.wait())
}

let parsed: ParsableCommand
do { parsed = try Firmwarekit.parseAsRoot() } catch { Firmwarekit.exit(withError: error) }
switch parsed {
case let command as FirmwareCommand.Create: await createCommand(command)
case let command as FirmwareCommand.UnpackBase: await supervised { await unpackBaseCommand(command) }
case let command as FirmwareCommand.PackBase: packBaseCommand(command)
case let command as FirmwareCommand.BootAdmit: await supervised { await bootAdmissionCommand(command) }
case let command as FirmwareCommand.Edit: await supervised { await stoppedEditCommand(command) }
case let command as FirmwareCommand.Mount:
    await supervised {
        await volumeCommand(
            device: command.device,
            volume: command.volume,
            out: command.out,
            root: command.root,
            recordPolicy: command.recordPolicy
        )
    }
case let command as FirmwareCommand.Export:
    await supervised {
        await volumeCommand(
            device: command.device,
            volume: command.volume,
            out: command.out,
            root: nil,
            recordPolicy: command.recordPolicy,
            export: true
        )
    }
case let command as FirmwareCommand.Unmount: await supervised { await unmountCommand(command) }
case let command as FirmwareCommand.CachePrune: cacheCommand(command)
case let command as FirmwareCommand.DetachImages: await supervised { await detachImagesCommand(command) }
case let command as FirmwareCommand.VerifyKeys: verifyKeysCommand(command)
case let command as FirmwareCommand.Fit: fitCommand(command)
case let command as FirmwareCommand.Unwrap: unwrapCommand(command)
case let command as FirmwareCommand.Fetch: fetchCommand(command)
case let command as FirmwareCommand.DeveloperOffer: developerOfferCommand(command)
case let command as FirmwareCommand.DeveloperAudit: developerAuditCommand(command)
default:  // the root alone, or help
    do {
        var command = parsed
        try command.run()
        exit(0)
    } catch { Firmwarekit.exit(withError: error) }
}

@MainActor func createCommand(_ command: FirmwareCommand.Create) async -> Never {
    let staging = fileURL(command.out)
    @Sendable func fail(_ error: Error) async -> Never {
        FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
        emit(Preparer.errorEvent(error))
        _ = await commandOutput.finish()
        _ = await FirmwareDiagnostics.finish()
        exit(1)
    }
    var options: Preparer.Options
    do {
        // The app's packed guest tools (Resources/Guest/guest.aar), unpacked; --guest-tools names another directory.
        guard let executable = Bundle.main.executableURL else {
            throw FirmwareError(.internal, "cannot locate the firmwarekit executable")
        }
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let resources = directory.appendingPathComponent("../Resources").standardizedFileURL
        // The helper beside this executable (the app bundle's MacOS/, a build's products) unless --helper names one.
        let sibling = directory.appendingPathComponent("LightTouchDevice")
        let helper =
            command.helper.map(fileURL)
            ?? (FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil)
        let bundled =
            try command.guestTools == nil
            ? GuestArchive.unpacked(resources: resources)?.appendingPathComponent("guest-tools") : nil
        var entry =
            if let path = command.entry {
                try FirmwareEntry.load(from: fileURL(path))
            } else {
                try FirmwareEntry.load(id: command.id ?? "", fromCatalog: fileURL(command.catalog ?? ""))
            }
        if command.glTest { entry.recipe?.options["gl_test"] = true }
        if command.skipSetup { entry.recipe?.options["skip_setup"] = true }
        if command.jailbreak { entry.recipe?.options["jailbreak"] = true }
        let sibling: (entry: FirmwareEntry, ipsw: URL)? =
            if let siblingEntryPath = command.siblingEntry {
                (try FirmwareEntry.load(from: fileURL(siblingEntryPath)), fileURL(command.siblingIpsw ?? ""))
            } else if let siblingIpswPath = command.siblingIpsw,
                let siblingId = entry.recipe?.keybagRamdiskFrom,
                let catalogPath = command.catalog
            {
                (try FirmwareEntry.load(id: siblingId, fromCatalog: fileURL(catalogPath)), fileURL(siblingIpswPath))
            } else {
                nil
            }
        options = .init(
            entry: entry,
            ipsw: fileURL(command.ipsw),
            out: staging,
            seed: command.seed,
            helper: helper,
            guestTools: command.guestTools.map(fileURL) ?? bundled ?? resources.appendingPathComponent("guest-tools"),
            cache: command.cache.map(fileURL),
            sibling: sibling
        )
        options.stopAfterVolumes = command.stopAfter == .volumes
        options.builtListing = command.builtListing
        options.bootrom = command.bootrom.map(fileURL)
        options.language = command.language
        options.keyboards = command.keyboards.map { $0.split(separator: ",").map(String.init) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    } catch { await fail(error) }
    let selectedOptions = options
    await supervised(cleanup: { try await Preparer.cancel(staging: staging) }) {
        do {
            try await Preparer.create(selectedOptions, emit: emit)
            return 0
        } catch {
            if Task.isCancelled { return 143 }
            FirmwareDiagnostics.write(Data("firmwarekit: \(error)\n".utf8))
            emit(Preparer.errorEvent(error))
            return 1
        }
    }
}
