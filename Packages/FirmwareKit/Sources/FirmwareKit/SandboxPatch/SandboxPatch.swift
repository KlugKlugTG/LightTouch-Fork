// SandboxPatch: the kernel patch a jailbroken device carries so Mobile Substrate's launcher, which inserts
// /Library/MobileSubstrate/MobileSubstrate.dylib into every job through DYLD_INSERT_LIBRARIES, does not get the
// inserted library's read denied inside a built-in sandbox profile (MobileSafari, MobileMail): the Seatbelt
// sandbox kext's sb_evaluate is made to allow (return 0), as the era's untethers patched it, so a sandboxed
// process may read the dylib dyld inserts. Applied only when the device is prepared jailbroken, to the decrypted
// kernelcache the boot runs: the kboot boards bake the patched Mach-O into kboot.bin; the iBoot board installs it
// as the kernelcache the fsboot chain loads.
//
// sb_evaluate is located by byte pattern, not a fixed offset: the Seatbelt kext's "bad opcode" string (the profile
// interpreter's bad-opcode report, inside sb_evaluate) is found, its reference in the kext text walked for (both
// the 4.x/5.x absolute literal-pool form and the 6.x/7.x PC-relative ldr/add form), and the function it sits in is
// taken as the Thumb push{..,lr} prologue nearest before it. The prologue's four bytes become `movs r0, #0; bx lr`.

import Foundation

public enum SandboxPatch {
    /// Return "allowed" at once, writing the decision the caller reads back. sb_evaluate(result, …) leaves its verdict
    /// in the caller's `result` struct (status at +0, filter at +4; 0 = allow) and returns 0; a bare `return 0` left
    /// that struct unwritten and the sandboxed daemons faulted. So: `movs r1,#0; str r1,[r0]; str r1,[r0,#4];
    /// movs r0,#0; bx lr` — allow, result cleared, return 0. r0 is the result pointer on entry (the caller's arg0).
    static let patch: [UInt8] = [0x00, 0x21, 0x01, 0x60, 0x41, 0x60, 0x00, 0x20, 0x70, 0x47]

    public struct Found: Sendable {
        /// The virtual address of sb_evaluate's prologue (the patch site).
        public let address: UInt32
        /// The bytes there before the patch (a push{..,lr} prologue), for the record.
        public let original: [UInt8]
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notMachO, noSandboxKext, noKextText, noString, noReference, noPrologue, badPatchSite
        public var description: String {
            switch self {
            case .notMachO: return "not a 32-bit Mach-O kernelcache"
            case .noSandboxKext: return "no com.apple.security.sandbox kext in the prelink info"
            case .noKextText: return "the sandbox kext has no __text"
            case .noString: return "the sandbox kext has no \"bad opcode\" string (sb_evaluate's report)"
            case .noReference: return "no reference to the \"bad opcode\" string in the kext text"
            case .noPrologue: return "no push{..,lr} prologue before the reference"
            case .badPatchSite: return "the patch site is not a push{..,lr} prologue"
            }
        }
    }

    /// Locate sb_evaluate in a decrypted, decompressed kernelcache Mach-O. Throws when the kernel has no Seatbelt
    /// kext (iOS before the prelinked sandbox) or the pattern does not resolve.
    public static func locate(_ kernel: [UInt8]) throws -> Found {
        try locate(Image(kernel))
    }

    static func locate(_ img: Image) throws -> Found {
        guard let klo = img.sandboxKextLoadAddr() else { throw Error.noSandboxKext }
        guard let (taddr, tsize) = img.kextText(klo) else { throw Error.noKextText }
        guard let so = img.findCString("bad opcode"), let saddr = img.offToAddr(so) else { throw Error.noString }
        guard let toff = img.addrToOff(taddr) else { throw Error.noKextText }

        // Resilient Thumb walk of the kext text: collect push{..,lr} prologues and references to saddr.
        var prologues: [UInt32] = []
        var refs: [UInt32] = []
        var regWord: [Int: UInt32] = [:]  // register -> last pc-relative word loaded
        var pos = 0
        while pos + 1 < tsize {
            let at = toff + pos
            let addr = taddr &+ UInt32(pos)
            let hw1 = img.u16(at)
            let len = (hw1 & 0xF800) >= 0xE800 ? 4 : 2
            if len == 4 && pos + 3 >= tsize { break }
            let hw2 = len == 4 ? img.u16(at + 2) : 0

            if len == 2, hw1 & 0xFE00 == 0xB400, hw1 & 0x0100 != 0 {
                prologues.append(addr)  // push {.., lr}
            } else if len == 4, hw1 == 0xE92D, hw2 & 0x4000 != 0 {
                prologues.append(addr)  // push.w {.., lr}
            } else if len == 2, hw1 & 0xF800 == 0x4800 {
                // ldr rT, [pc, #imm]  (T1)
                let rt = Int((hw1 >> 8) & 7)
                let base = (addr &+ 4) & ~3
                let la = base &+ UInt32((hw1 & 0xFF)) &* 4
                reference(img, la: la, saddr: saddr, rt: rt, at: addr, regWord: &regWord, refs: &refs)
            } else if len == 4, hw1 & 0xFF7F == 0xF85F {
                // ldr.w rT, [pc, #imm12]  (T2)
                let rt = Int((hw2 >> 12) & 0xF)
                let base = (addr &+ 4) & ~3
                let imm = UInt32(hw2 & 0xFFF)
                let la = (hw1 & 0x0080) != 0 ? base &+ imm : base &- imm
                reference(img, la: la, saddr: saddr, rt: rt, at: addr, regWord: &regWord, refs: &refs)
            } else if len == 2, hw1 & 0xFFF8 == 0x4478 {
                // add rD, pc  (Rm == pc): resolve a PC-relative delta loaded earlier
                let rd = Int(hw1 & 7)
                if let w = regWord[rd] {
                    let resolved = addr &+ 4 &+ w
                    if resolved == saddr { refs.append(addr) }
                }
            }
            pos += len
        }
        guard let x = refs.min() else { throw Error.noReference }
        guard let entry = prologues.filter({ $0 <= x }).max() else { throw Error.noPrologue }
        guard let eo = img.addrToOff(entry) else { throw Error.noPrologue }
        let orig = Array(img.bytes[eo..<eo + 4])
        // A real prologue: push {..,lr} (0xB5xx) or push.w {..,lr} (0xE92D, lr bit set).
        let hw = UInt16(orig[0]) | UInt16(orig[1]) << 8
        let isPush16 = hw & 0xFE00 == 0xB400 && hw & 0x0100 != 0
        let isPush32 = hw == 0xE92D && (UInt16(orig[2]) | UInt16(orig[3]) << 8) & 0x4000 != 0
        guard isPush16 || isPush32 else { throw Error.badPatchSite }
        return Found(address: entry, original: orig)
    }

    /// Apply the patch in place, returning the patched kernelcache and where it landed.
    public static func apply(_ kernel: [UInt8]) throws -> (kernel: [UInt8], found: Found) {
        let img = try Image(kernel)
        let found = try locate(img)
        var out = kernel
        guard let o = img.addrToOff(found.address) else { throw Error.badPatchSite }
        out.replaceSubrange(o..<o + patch.count, with: patch)
        return (out, found)
    }

    /// Apply the patch in place inside a flat-mapped KBoot image (`0..<imageBytes` of `kboot.bin`, where segments sit
    /// at `vmaddr - vbase`).
    public static func applyLoaded(_ kboot: inout [UInt8], imageBytes: Int) throws -> Found {
        guard imageBytes > 0, imageBytes <= kboot.count else { throw Error.notMachO }
        let img = try Image(loaded: Array(kboot[0..<imageBytes]))
        let found = try locate(img)
        guard let o = img.addrToOff(found.address), o + patch.count <= imageBytes else { throw Error.badPatchSite }
        kboot.replaceSubrange(o..<o + patch.count, with: patch)
        return found
    }

    // MARK: - The real-iBoot kernelcache (k48)

    /// Patch the plaintext kernel, then put it back in the IMG3 the fsboot iBoot loads: complzss-wrap and re-encrypt
    /// with the component's own key so iBoot decrypts it through the same KBAG as the stock one, and rebuild the IMG3
    /// around the original's tags (TYPE/KBAG/SHSH/… unchanged). The patched iBoot does not check the signature.
    public static func rewrapKernelcache(
        original raw: Data, plaintextKernel kernel: [UInt8], iv: Data, key: Data
    ) throws -> (img3: Data, found: Found) {
        let patched = try apply(kernel)
        var payload = complzssWrap(patched.kernel)
        if payload.count % 16 != 0 { payload.append(contentsOf: repeatElement(0, count: 16 - payload.count % 16)) }
        let cipher = try AESCBC.crypt(Data(payload), iv: iv, key: key, decrypt: false)
        return (try rebuildIMG3(raw, data: [UInt8](cipher)), patched.found)
    }

    /// A valid Apple-LZSS stream of all literals (flag byte 0xFF then eight bytes), so no compressor is needed: iBoot's
    /// decompressor reproduces the kernel. Larger than a real compression, which the system volume has room for.
    static func literalLZSS(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 8 + 1)
        var i = 0
        while i < data.count {
            let n = min(8, data.count - i)
            out.append(UInt8((1 << n) - 1))  // n low bits set: n literals follow
            out.append(contentsOf: data[i..<i + n])
            i += n
        }
        return out
    }

    /// The complzss container a decrypted kernelcache is (LZSS.complzss reads it back): "complzss", adler32, ulen,
    /// clen big-endian in a 0x180 header, the LZSS body after it.
    static func complzssWrap(_ kernel: [UInt8]) -> Data {
        let body = literalLZSS(kernel)
        var h = [UInt8](repeating: 0, count: 0x180)
        h.replaceSubrange(0..<8, with: "complzss".utf8)
        func beAt(_ o: Int, _ v: UInt32) { for k in 0..<4 { h[o + k] = UInt8(truncatingIfNeeded: v >> (8 * (3 - k))) } }
        beAt(8, Adler32.checksum(Data(kernel)))
        beAt(12, UInt32(kernel.count))
        beAt(16, UInt32(body.count))
        return Data(h) + Data(body)
    }

    /// Rebuild an IMG3 with a new DATA payload, every other tag kept, the header sizes recomputed.
    static func rebuildIMG3(_ raw: Data, data newData: [UInt8]) throws -> Data {
        let d = [UInt8](raw)
        guard d.count >= 0x14, d[0..<4] == [0x33, 0x67, 0x6D, 0x49] else {
            throw FirmwareError(.unsupported, "not an img3")
        }
        let full = Int(le32(d, 4))
        var body: [UInt8] = []
        var signedEnd = 0  // tags before SHSH are the signed area
        var off = 0x14
        while off + 12 <= full, off + 12 <= d.count {
            let magic = String(decoding: d[off..<off + 4].reversed(), as: UTF8.self)
            let total = Int(le32(d, off + 4))
            guard total >= 12 else { break }
            if magic == "DATA" {
                var tag = Array(d[off..<off + 4])  // file magic bytes, as stored
                tag += le(UInt32(12 + newData.count)) + le(UInt32(newData.count)) + newData
                body += tag
            } else {
                body += Array(d[off..<off + total])
            }
            if magic != "SHSH" && magic != "CERT" { signedEnd = body.count }
            off += total
        }
        var out = Array(d[0..<0x14])
        putLE(&out, 4, UInt32(0x14 + body.count))  // fullSize
        putLE(&out, 8, UInt32(body.count))  // size without the header
        putLE(&out, 12, UInt32(signedEnd))  // signed area (tags up to SHSH)
        return Data(out + body)
    }

    private static func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    private static func putLE(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        for k in 0..<4 { b[o + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
    }

    private static func reference(
        _ img: Image, la: UInt32, saddr: UInt32, rt: Int, at: UInt32, regWord: inout [Int: UInt32], refs: inout [UInt32]
    ) {
        guard let lo = img.addrToOff(la), lo + 4 <= img.bytes.count else { return }
        let w = img.u32(lo)
        if w == saddr {
            refs.append(at)  // absolute literal-pool reference (4.x/5.x)
        } else {
            regWord[rt] = w  // a delta, to be resolved by a later add rD, pc (6.x/7.x)
        }
    }
}

/// A read view over the kernelcache Mach-O: outer segments for address<->offset, the prelink info, and the kext
/// Mach-O's own __text. Kept small and local to the patch; FitCheck's MachO32 reads commands, not segment maps.
struct Image {
    let bytes: [UInt8]
    // (vmaddr, vmsize, fileoff, filesize) per outer LC_SEGMENT.
    let segs: [(UInt32, UInt32, UInt32, UInt32)]
    // (sectname, segname, addr, size, off) per outer section.
    let sects: [(String, String, UInt32, UInt32, UInt32)]

    init(_ b: [UInt8]) throws {
        guard b.count >= 28, le32(b, 0) == 0xFEED_FACE, le32(b, 4) == 12 else { throw SandboxPatch.Error.notMachO }
        bytes = b
        var sg: [(UInt32, UInt32, UInt32, UInt32)] = []
        var sc: [(String, String, UInt32, UInt32, UInt32)] = []
        var off = 28
        for _ in 0..<le32(b, 16) {
            guard off + 8 <= b.count else { break }
            let cmd = le32(b, off), size = Int(le32(b, off + 4))
            guard size >= 8, off + size <= b.count else { break }
            if cmd == 1 {  // LC_SEGMENT
                sg.append((le32(b, off + 24), le32(b, off + 28), le32(b, off + 32), le32(b, off + 36)))
                let nsects = Int(le32(b, off + 48))
                var so = off + 56
                for _ in 0..<nsects where so + 68 <= off + size {
                    sc.append(
                        (Image.cstr(b, so, 16), Image.cstr(b, so + 16, 16), le32(b, so + 32), le32(b, so + 36),
                            le32(b, so + 40)))
                    so += 68
                }
            }
            off += size
        }
        segs = sg
        sects = sc
    }

    /// View a flat-loaded KBoot image (`KBoot.build`), where Mach-O segments sit at `vmaddr - vbase` and the `__TEXT`
    /// header lands on a 4 KiB page near the start of the image.
    init(loaded b: [UInt8]) throws {
        var headerOff: Int?
        var off = 0
        while off + 28 <= b.count, off < 0x10000 {
            if le32(b, off) == 0xFEED_FACE, le32(b, off + 4) == 12 {
                headerOff = off
                break
            }
            off += 0x1000
        }
        guard let hdr = headerOff else { throw SandboxPatch.Error.notMachO }
        bytes = b
        var rawSegs: [(String, UInt32, UInt32, UInt32)] = []
        var rawSects: [(String, String, UInt32, UInt32)] = []
        var pos = hdr + 28
        for _ in 0..<le32(b, hdr + 16) {
            guard pos + 8 <= b.count else { break }
            let cmd = le32(b, pos), size = Int(le32(b, pos + 4))
            guard size >= 8, pos + size <= b.count else { break }
            if cmd == 1 {
                let segName = Image.cstr(b, pos + 8, 16)
                rawSegs.append((segName, le32(b, pos + 24), le32(b, pos + 28), le32(b, pos + 36)))
                let nsects = Int(le32(b, pos + 48))
                var so = pos + 56
                for _ in 0..<nsects where so + 68 <= pos + size {
                    rawSects.append(
                        (Image.cstr(b, so, 16), Image.cstr(b, so + 16, 16), le32(b, so + 32), le32(b, so + 36))
                    )
                    so += 68
                }
            }
            pos += size
        }
        let nonZero = rawSegs.filter { $0.0 != "__PAGEZERO" }
        guard let lowest = nonZero.map(\.1).min() else { throw SandboxPatch.Error.notMachO }
        let vbase = lowest & 0xF000_0000
        segs = nonZero.compactMap { (_, vmaddr, vmsize, filesize) in
            guard vmaddr >= vbase else { return nil }
            let fileoff = vmaddr &- vbase
            let mapped = min(filesize, vmsize)
            guard Int(fileoff) + Int(mapped) <= b.count else { return nil }
            return (vmaddr, vmsize, fileoff, mapped)
        }
        sects = rawSects.compactMap { (sect, seg, addr, size) in
            guard addr >= vbase else { return nil }
            return (sect, seg, addr, size, addr &- vbase)
        }
    }

    static func cstr(_ b: [UInt8], _ o: Int, _ n: Int) -> String {
        let end = (o..<o + n).first { b[$0] == 0 } ?? o + n
        return String(decoding: b[o..<end], as: UTF8.self)
    }

    func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { le32(bytes, o) }

    func addrToOff(_ a: UInt32) -> Int? {
        for (vmaddr, vmsize, fileoff, filesize) in segs
        where a >= vmaddr && a < vmaddr &+ vmsize && (a &- vmaddr) < filesize {
            return Int(fileoff &+ (a &- vmaddr))
        }
        return nil
    }
    func offToAddr(_ o: Int) -> UInt32? {
        for (vmaddr, _, fileoff, filesize) in segs
        where o >= Int(fileoff) && o < Int(fileoff &+ filesize) {
            return vmaddr &+ UInt32(o - Int(fileoff))
        }
        return nil
    }

    func findCString(_ s: String) -> Int? {
        let needle = [UInt8]((s + "\0").utf8)
        guard let r = bytes.firstRange(of: needle) else { return nil }
        return r.lowerBound
    }

    /// The load address of the com.apple.security.sandbox kext: the _PrelinkExecutableLoadAddr in the same kext dict
    /// as the bundle id in __PRELINK_INFO. The key sits ahead of the id on 5.x-7.x but after it on 4.x, so take the
    /// occurrence nearest the id (its own dict's) rather than the last one before it (which on 4.x is the prior kext's).
    func sandboxKextLoadAddr() -> UInt32? {
        guard let (_, _, _, size, off) = sects.first(where: { $0.0 == "__info" && $0.1 == "__PRELINK_INFO" })
        else { return nil }
        let info = String(decoding: bytes[Int(off)..<min(bytes.count, Int(off) + Int(size))], as: UTF8.self)
        guard let idRange = info.range(of: "com.apple.security.sandbox") else { return nil }
        let anchor = idRange.lowerBound
        let key = "_PrelinkExecutableLoadAddr</key><integer"
        var before: (Range<String.Index>, UInt32)?  // last occurrence before the id
        var after: (Range<String.Index>, UInt32)?  // first occurrence at or after the id
        var search = info.startIndex
        while let k = info.range(of: key, range: search..<info.endIndex) {
            if let gt = info.range(of: ">", range: k.upperBound..<info.endIndex),
                let lt = info.range(of: "<", range: gt.upperBound..<info.endIndex)
            {
                let hex = info[gt.upperBound..<lt.lowerBound].trimmingCharacters(in: .whitespaces)
                if hex.hasPrefix("0x"), let v = UInt32(hex.dropFirst(2), radix: 16) {
                    if k.lowerBound < anchor { before = (k, v) } else if after == nil { after = (k, v) }
                }
            }
            search = k.upperBound
        }
        guard let before else { return after?.1 }
        guard let after else { return before.1 }
        let distBefore = info.distance(from: before.0.upperBound, to: anchor)
        let distAfter = info.distance(from: anchor, to: after.0.lowerBound)
        return distBefore <= distAfter ? before.1 : after.1
    }

    /// The kext Mach-O's own __text (addr, size) given its load address.
    func kextText(_ kaddr: UInt32) -> (UInt32, UInt32)? {
        guard let koff = addrToOff(kaddr), koff + 28 <= bytes.count, le32(bytes, koff) == 0xFEED_FACE else { return nil }
        var off = koff + 28
        for _ in 0..<le32(bytes, koff + 16) {
            guard off + 8 <= bytes.count else { break }
            let cmd = le32(bytes, off), size = Int(le32(bytes, off + 4))
            guard size >= 8 else { break }
            if cmd == 1 {
                let nsects = Int(le32(bytes, off + 48))
                var so = off + 56
                for _ in 0..<nsects where so + 68 <= off + size {
                    if Image.cstr(bytes, so, 16) == "__text" { return (le32(bytes, so + 32), le32(bytes, so + 36)) }
                    so += 68
                }
            }
            off += size
        }
        return nil
    }
}
