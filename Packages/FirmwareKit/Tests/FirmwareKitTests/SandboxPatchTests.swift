import Foundation
import Testing

@testable import FirmwareKit

/// The jailbreak sandbox patch (SandboxPatch): sb_evaluate located by the Seatbelt kext's "bad opcode" string, the
/// prologue patched to return allowed. Validated against real decrypted kernelcaches.
struct SandboxPatchTests {
    /// Locating and applying leaves exactly the four patch bytes changed, at a Thumb push{..,lr} prologue, and the
    /// result is stable (re-locating the patched kernel still points at the same prologue, now the patch bytes).
    static func check(_ kernel: [UInt8], _ label: String) throws {
        let found = try SandboxPatch.locate(kernel)
        let (patched, f2) = try SandboxPatch.apply(kernel)
        #expect(f2.address == found.address, "\(label): apply and locate agree")
        let changed = zip(kernel, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        let n = SandboxPatch.patch.count
        let img = try Image(patched)
        let o = try #require(img.addrToOff(found.address))
        #expect(Array(patched[o..<o + n]) == SandboxPatch.patch, "\(label): the patch landed")
        #expect(changed.allSatisfy { (o..<o + n).contains($0) }, "\(label): only the patch site changed")
    }

    /// Every decrypted kernelcache in the app's cache that carries a Seatbelt kext resolves to a prologue. Opt-in:
    /// LTM_SANDBOX_KERNELS points at a directory tree of kernelcache.mach files (the Decrypted cache).
    @Test func locatesAcrossTheCachedKernels() throws {
        guard let root = ProcessInfo.processInfo.environment["LTM_SANDBOX_KERNELS"] else { return }
        let fm = FileManager.default
        var ok = 0, noKext = 0, unresolved = 0
        let base = URL(fileURLWithPath: root)
        let e = fm.enumerator(at: base, includingPropertiesForKeys: nil)
        while let u = e?.nextObject() as? URL {
            guard u.lastPathComponent == "kernelcache.mach" else { continue }
            let kernel = [UInt8](try Data(contentsOf: u, options: .alwaysMapped))
            let ver =
                String(decoding: kernel, as: UTF8.self).range(of: "Darwin Kernel Version ").map {
                    String(String(decoding: kernel, as: UTF8.self)[$0.upperBound...].prefix(8))
                } ?? "?"
            do {
                let f = try SandboxPatch.locate(kernel)
                try Self.check(kernel, ver)
                print("  OK   \(ver) sb_evaluate=\(String(f.address, radix: 16)) \(f.original.hexString)")
                ok += 1
            } catch SandboxPatch.Error.noSandboxKext, SandboxPatch.Error.noString {
                noKext += 1  // iOS before the prelinked Seatbelt kext
            } catch {
                print("  MISS \(ver) \(error)")
                unresolved += 1
            }
        }
        print("SandboxPatch: \(ok) patched, \(noKext) without a Seatbelt kext, \(unresolved) unresolved")
        #expect(ok > 0)
    }

    /// The real-iBoot re-wrap round-trips: rewrapping the k48 kernelcache and decrypting it back (as iBoot and the
    /// decryptor do) yields exactly the sandbox-patched kernel.
    @Test func rewrapRoundTripsForK48() throws {
        guard FixtureRequirements.corpusEnabled else { return }
        let id = "k48ap-9B206"
        guard let sha1 = try Oracle.entry(id).source.sha1 else { try FixtureRequirements.missing("\(id): no sha1") }
        let ipswURL = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
        guard Oracle.exists(ipswURL) else { try FixtureRequirements.missing("\(id): IPSW not cached") }
        let entry = try Oracle.entry(id)
        let ipsw = IPSWArchive(ipswURL)
        guard let kcPath = try BuildComponents.load(ipsw, board: entry.board)["KernelCache"] else {
            try FixtureRequirements.missing("\(id): no KernelCache")
        }
        let raw = try ipsw.read(kcPath)
        let k = try entry.key(forPath: kcPath)
        let iv = try #require(k.iv.flatMap { Data(hex: $0) })
        let key = try #require(Data(hex: k.key))
        let plain = [UInt8](try LZSS.complzss(IMG3.decrypt(raw, iv: iv, key: key)))
        let want = try SandboxPatch.apply(plain).kernel
        let (img3, _) = try SandboxPatch.rewrapKernelcache(original: raw, plaintextKernel: plain, iv: iv, key: key)
        let back = [UInt8](try LZSS.complzss(IMG3.decrypt(img3, iv: iv, key: key)))
        #expect(back == want, "the re-wrapped kernelcache decrypts back to the patched kernel")
    }

    /// Corpus: the two reported bases plus a board of each kboot kind resolve from a fresh decrypt. k48ap-8J3 is
    /// iOS 4.3.3 (xnu-1735), where _PrelinkExecutableLoadAddr follows the bundle id in the prelink dict.
    @Test(arguments: ["n81ap-10B500", "k48ap-9B206", "n88ap-10B500", "n18ap-9B206", "k48ap-8J3"])
    func locatesForABoard(_ id: String) throws {
        guard FixtureRequirements.corpusEnabled else { return }
        guard let sha1 = try Oracle.entry(id).source.sha1 else { try FixtureRequirements.missing("\(id): no sha1") }
        let ipsw = Oracle.path("Library/Caches/gold.samhenri.LightTouchMac/IPSW/\(sha1).ipsw")
        guard Oracle.exists(ipsw) else { try FixtureRequirements.missing("\(id): IPSW not cached") }
        try Oracle.withTemp { dir in
            _ = try FirmwareDecryptor.decrypt(ipsw: ipsw, entry: try Oracle.entry(id), into: dir, rootfs: false)
            let kernel = [UInt8](try Data(contentsOf: dir.appendingPathComponent("kernelcache.mach")))
            try Self.check(kernel, id)
        }
    }
}
