// K48IBoot: the iPad 1 (k48ap) real-iBoot boot chain (SecureROM -> LLB -> iBoot -> kernel), the artifacts the
// `ipad1,iboot=...,nor=...,gid-blobs=...` machine boots. Ports imgtools/ipad1_gid.py (gid_blobs,
// host_usb_devicetree), imgtools/build_nor.py's K48 parts and imgtools/ipad1_iboot.py (nor_base, nvram_bank,
// the iBoot32Patcher shell-out). iBoot32Patcher is invoked, not reimplemented: byte-equal output is the gate,
// and its Thumb pattern finders (RSA/debug/boot-args) are >200 lines and fragile to re-derive per iBoot build.
// The bundled build carries build-support/patches/iBoot32Patcher-ltm.patch (9A5220p boot-args xref, smoke #48).
//
//   let (blobs, names) = try K48IBoot.gidBlobs(ipsw, entry: e)                 // AES-256 GID records + gid-blobs.bin
//   let dt = try K48IBoot.hostUSBDeviceTree(img3: enc, plaintext: plain, gidBlobs: blobs)   // hsic-enabled, re-encrypted
//   let nor = try K48IBoot.buildNOR(identity: id, allFlash: imgs, order: order, bootArgs: args)
//   let iboot = try K48IBoot.patchIBoot(decrypted, patcher: url, bootArgs: args, log: log)

import Foundation
import zlib

public enum K48IBoot {
    /// The UID the emulated S5L8930 (iPad 1) reports: cdma_uid_key in hw/arm/s5l8930_cdma.c, an AES-256 key.
    static let uidKey = Data("K48AP-UID-S5L8930-iPad1-7B500-01".utf8)
    /// The 16 bytes iBoot runs through the UID key to get the SHSH wrapping key (build_nor.SHSH_KDF_CONST).
    static let kdfConst = Data(hexLiteral: "db1f5b33606c5f1c1934aa66589c0661")
    static let img3Header = 0x14, nvramOff = 0xFC000, norSize = 0x100000

    // MARK: - GID blobs (AES-256 catalog keys)

    /// Encrypted KBAG (48 bytes) || plaintext IV/key (48 bytes) for every IMG3 the entry has a key for, in IPSW
    /// member order, de-duplicated by KBAG (production and development KBAGs wrap the same DATA key). ipad1_gid.gid_blobs.
    public static func gidBlobs(_ ipsw: IPSWArchive, entry: FirmwareEntry) throws -> (Data, [String]) {
        var records: [(kbag: [UInt8], plain: [UInt8])] = []
        var seen = Set<[UInt8]>()
        var names: [String] = []
        for member in try ipsw.names() {
            let name = (member as NSString).lastPathComponent
            guard let k = entry.keys.values.first(where: { $0.file == name }),
                let ivHex = k.iv, let iv = Data(hex: ivHex), let key = Data(hex: k.key)
            else { continue }
            let plain = [UInt8](iv + key)
            let data = try ipsw.read(member)
            guard data.count >= img3Header, data.prefix(4).elementsEqual([0x33, 0x67, 0x6D, 0x49]) else { continue }
            let d = [UInt8](data)
            let full = Int(le32(d, 4))
            guard full >= img3Header, full <= d.count else {
                throw FirmwareError(.unsupported, "\(name): truncated IMG3")
            }
            var off = img3Header
            var bags: [[UInt8]] = []
            while off + 12 <= full {
                let total = Int(le32(d, off + 4))
                let size = Int(le32(d, off + 8))
                guard total >= 12, off + total <= full, size <= total - 12 else {
                    throw FirmwareError(.unsupported, "\(name): malformed IMG3 tag")
                }
                if d[off..<off + 4].elementsEqual([0x47, 0x41, 0x42, 0x4B]), size >= 8 {  // "GABK"
                    let state = le32(d, off + 12)
                    let bits = le32(d, off + 16)
                    if state == 1 || state == 2 {
                        guard bits == 256, size == 56, plain.count == 48 else {
                            throw FirmwareError(.unsupported, "\(name): invalid AES-256 KBAG/key")
                        }
                        bags.append(Array(d[off + 20..<off + 68]))
                    }
                }
                off += total
            }
            for kbag in bags where !seen.contains(kbag) {
                seen.insert(kbag)
                records.append((kbag, plain))
            }
            if !bags.isEmpty { names.append(member) }
        }
        guard !records.isEmpty else {
            throw FirmwareError(.keyMissing, "\(entry.id): no AES-256 IMG3 keys matched this IPSW")
        }
        return (Data(records.flatMap { $0.kbag + $0.plain }), names)
    }

    // MARK: - DeviceTree (hsic-enabled, re-encrypted with the catalog key)

    /// The NOR DeviceTree img3 with the emulated HSIC keyboard controller added and re-encrypted under the catalog
    /// key, so iBoot (which bypasses image signatures) loads it. ipad1_gid.host_usb_devicetree.
    public static func hostUSBDeviceTree(img3 image: Data, plaintext: Data, gidBlobs blobs: Data) throws -> Data {
        var tree = try DeviceTree(plaintext)
        guard tree.contains("arm-io/usb-complex") else {
            throw FirmwareError(.unsupported, "DeviceTree has no USB complex")
        }
        try tree.add("arm-io/usb-complex", "hsic-enabled")
        // No SGX model: unmatch the GPU node so IMGSGX535 never probes the unimplemented window, the same edit
        // KBoot makes on the direct-kernel path (qemu-ios 47fe75e824, ipad1_gid.host_usb_devicetree).
        if tree.contains("arm-io/sgx") { try tree.set("arm-io/sgx", "compatible", .string("none")) }
        let plain = tree.data
        // pairs: production/development KBAG -> its 48-byte IV/key. Find the production (state 1) KBAG here.
        let recs = [UInt8](blobs)
        var pairs: [[UInt8]: [UInt8]] = [:]
        for i in stride(from: 0, to: recs.count, by: 96) where i + 96 <= recs.count {
            pairs[Array(recs[i..<i + 48])] = Array(recs[i + 48..<i + 96])
        }
        let img = [UInt8](image)
        var off = img3Header
        var key: [UInt8]?
        while off + 12 <= img.count {
            let size = Int(le32(img, off + 4))
            let dlen = Int(le32(img, off + 8))
            if size < 12 { break }
            if img[off..<off + 4].elementsEqual([0x47, 0x41, 0x42, 0x4B]), dlen == 56, le32(img, off + 12) == 1 {
                key = pairs[Array(img[off + 20..<off + 68])]
                break
            }
            off += size
        }
        guard let key, key.count == 48 else {
            throw FirmwareError(.keyMissing, "DeviceTree production KBAG has no catalog key")
        }
        // Encrypt the modified plaintext (AES-256, IV = key[:16], key = key[16:]); rewrite the DATA tag.
        let padded = plain + Data(count: (16 - plain.count % 16) % 16)
        let enc = try AESCBC.crypt(padded, iv: Data(key[0..<16]), key: Data(key[16..<48]), decrypt: false)
        guard let dataTag = try IMG3.tags(image)["DATA"] else {
            throw FirmwareError(.unsupported, "DeviceTree img3 has no DATA tag")
        }
        var out = [UInt8](image)
        let oldSize = Int(le32(out, dataTag.offset + 4))
        let tag = Array("ATAD".utf8) + le32Bytes(UInt32(12 + enc.count)) + le32Bytes(UInt32(plain.count)) + [UInt8](enc)
        out.replaceSubrange(dataTag.offset..<dataTag.offset + oldSize, with: tag)
        let delta = tag.count - oldSize
        for field in [4, 8, 12] { put32(&out, field, le32(out, field) &+ UInt32(bitPattern: Int32(delta))) }
        return Data(out)
    }

    // MARK: - NOR

    /// The 1 MiB NOR the iBoot path boots: an IMG2 superblock, SysCfg (Mod#/Regn/SrNm/MLB#), two NVRAM banks
    /// (debug-uarts, auto-boot, boot-command=fsboot, boot-args, wifiaddr, btaddr) and the all_flash img3s packed at
    /// 0x8000 in the manifest order, each SHSH-wrapped under the S5L8930 UID so iBoot's in-place unwrap recovers it.
    /// ipad1_iboot.nor_base + build_nor.build (K48). `allFlash` is the img3 by type (its DeviceTree already re-encrypted).
    public static func buildNOR(identity id: UnitIdentity, allFlash: [String: Data], order: [String], bootArgs: String)
        throws -> Data
    {
        var nor = try norBase(id, bootArgs: bootArgs)
        let gran = 0x40
        let imageStart = gran * 0x200  // 64 * (0 + 0x200) = 0x8000
        // The SHSH wrapping key: AES-256 encrypt of the KDF const with the 256-bit UID; the 16-byte result is
        // the AES-128 wrapping key (build_nor.shsh_wrap_key, S5L8930 branch).
        let wrapKey = try AESCBC.crypt(kdfConst, iv: Data(count: 16), key: uidKey, decrypt: false)
        var off = imageStart
        for type in order {
            guard var img = allFlash[type].map({ [UInt8]($0) }) else {
                throw FirmwareError(.unsupported, "all_flash has no img3 of type \(type)")
            }
            guard try N72NOR.wrapSHSH(&img, key: wrapKey) else {
                throw FirmwareError(.unsupported, "\(type): no SHSH tag to wrap, or its length is not a multiple of 16")
            }
            let padded = (img.count + gran - 1) & ~(gran - 1)
            img += [UInt8](repeating: 0, count: padded - img.count)
            put32(&img, 4, UInt32(padded))
            guard off + padded <= nvramOff else {
                throw FirmwareError(.unsupported, "NOR image area overflows the nvram partition (\(type))")
            }
            nor.replaceSubrange(off..<off + padded, with: img)
            off += padded
        }
        // build_nor keeps the stock convention (over-counts by image_start)
        put32(&nor, 0x10, UInt32((off + gran - 1) / gran))
        put32(&nor, 0x30, crc(nor[0..<0x30]))
        return Data(nor)
    }

    /// ipad1_iboot.nor_base: IMG2 + SysCfg + two NVRAM banks, an empty image area (buildNOR fills it).
    static func norBase(_ id: UnitIdentity, bootArgs: String) throws -> [UInt8] {
        func need(_ k: String) throws -> String {
            guard let v = id[k] else { throw FirmwareError(.unsupported, "identity: missing \(k)") }
            return v
        }
        var nor = [UInt8](repeating: 0, count: norSize)
        nor.replaceSubrange(0..<4, with: Array("2GMI".utf8))
        for (i, v) in [UInt32(64), 0, 0x200, 0x3D00].enumerated() { put32(&nor, 4 + 4 * i, v) }
        put32(&nor, 0x30, crc(nor[0..<0x30]))
        // SysCfg ('gfCS'): 20-byte records, a 4-byte tag then a 16-byte inline value.
        let entries: [(String, String)] = [
            ("Mod#", try need("model-number")), ("Regn", try need("region-info")),
            ("SrNm", try need("serial-number")), ("MLB#", try need("mlb-serial-number")),
        ]
        nor.replaceSubrange(0x4000..<0x4004, with: Array("gfCS".utf8))
        for (i, v) in [UInt32(24 + 20 * entries.count), 8192, 0x10001, 0, UInt32(entries.count)].enumerated() {
            put32(&nor, 0x4004 + 4 * i, v)
        }
        for (i, (key, value)) in entries.enumerated() {
            let bytes = Array(value.utf8)
            guard bytes.count <= 16 else { throw FirmwareError(.unsupported, "invalid SysCfg value for \(key)") }
            let o = 0x4018 + i * 20
            nor.replaceSubrange(o..<o + 4, with: Array(key.utf8).reversed())
            nor.replaceSubrange(o + 4..<o + 4 + bytes.count, with: bytes)
        }
        let values: [(String, String)] = [
            ("debug-uarts", "1"), ("auto-boot", "true"), ("boot-command", "fsboot"),
            ("boot-args", bootArgs), ("wifiaddr", try need("wifi-mac")), ("btaddr", try need("bt-mac")),
        ]
        let bank = try nvramBank(values)
        nor.replaceSubrange(0xFC000..<0xFE000, with: bank)
        nor.replaceSubrange(0xFE000..<0x100000, with: bank)
        return nor
    }

    /// One 8 KiB NVRAM bank as iBoot writes it (ipad1_iboot.nvram_bank): "nvram" wrapper (generation, adler32 of the
    /// rest), a "common" partition of NUL-separated key=value, and the free-space partition.
    static func nvramBank(_ values: [(String, String)]) throws -> [UInt8] {
        var bank = [UInt8](repeating: 0, count: 8192)
        bank.replaceSubrange(0..<16, with: chrp(0x5A, "nvram", 32))
        put32(&bank, 20, 1)  // generation
        bank.replaceSubrange(32..<48, with: chrp(0x70, "common", 2048))
        let data: [UInt8] = values.flatMap { Array("\($0.0)=\($0.1)".utf8) + [0] } + [0]
        guard data.count <= 2032, values.allSatisfy({ !$0.0.contains("\0") && !$0.1.contains("\0") }) else {
            throw FirmwareError(.unsupported, "invalid NVRAM variables")
        }
        bank.replaceSubrange(48..<48 + data.count, with: data)
        bank.replaceSubrange(2080..<2096, with: chrp(0x7F, "free", 8192 - 2080))
        put32(&bank, 16, Adler32.checksum(Data(bank[20...])))
        return bank
    }

    /// A CHRP nvram partition header: signature, folded checksum, length in 16-byte units, 12-byte name.
    static func chrp(_ sig: UInt8, _ name: String, _ size: Int) -> [UInt8] {
        var h: [UInt8] =
            [sig, 0, UInt8((size / 16) & 0xFF), UInt8((size / 16) >> 8)] + Array(name.utf8)
            + [UInt8](repeating: 0, count: 12 - name.utf8.count)
        var total = h.reduce(0) { $0 + Int($1) }
        while total > 255 { total = (total & 255) + (total >> 8) }
        h[1] = UInt8(total)
        return h
    }

    // MARK: - iBoot patching

    static let patcherNames = ["iBoot32Patcher", "libiboot32patcher.so", "iBoot32Patcher.exe"]

    /// Locate iBoot32Patcher: the bundled copy first (next to firmwarekit itself, then next to the helper; macOS/Linux
    /// ship `iBoot32Patcher`, Android packages `libiboot32patcher.so` in nativeLibraryDir), then
    /// FIRMWAREKIT_IBOOT_PATCHER / IBOOT32PATCHER, then a copy resolved on PATH.
    public static func patcher(helper: URL?) -> URL {
        let fm = FileManager.default
        for dir in [Bundle.main.executableURL, helper].compactMap({
            $0?.resolvingSymlinksInPath().deletingLastPathComponent()
        }) {
            for name in patcherNames {
                let u = dir.appendingPathComponent(name)
                if fm.isExecutableFile(atPath: u.path) { return u }
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let p = (env["FIRMWAREKIT_IBOOT_PATCHER"] ?? env["IBOOT32PATCHER"])?.trimmingCharacters(in: .whitespaces),
            !p.isEmpty
        {
            return URL(fileURLWithPath: p)
        }
        if let pathEnv = env["PATH"] {
            #if os(Windows)
            let sep: Character = ";"
            #else
            let sep: Character = ":"
            #endif
            for raw in pathEnv.split(separator: sep) where !raw.isEmpty {
                let dir = URL(fileURLWithPath: String(raw))
                for name in patcherNames {
                    let u = dir.appendingPathComponent(name)
                    if fm.isExecutableFile(atPath: u.path) { return u }
                }
            }
        }
        return URL(fileURLWithPath: "iBoot32Patcher")
    }

    /// A pattern-patched iBoot (RSA/personalization bypass, debug boot, the boot-args string), byte-for-byte what
    /// `iBoot32Patcher --rsa --debug -b <boot-args>` produces. `-a` (environment boot args) crashes 817.29, so `-b`.
    /// Invokes `tool` directly rather than `/usr/bin/env` (absent on Android). The patcher returns status 1 even on
    /// success; the output existing, keeping its size and differing is the check.
    public static func patchIBoot(_ iboot: Data, patcher tool: URL, bootArgs: String, log: (String) -> Void) throws
        -> Data
    {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("k48-iboot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("iBoot.in")
        let dst = tmp.appendingPathComponent("iBoot.out")
        try iboot.write(to: src)
        let p = Process()
        let out = Pipe()
        p.executableURL = tool
        p.arguments = [src.path, dst.path, "--rsa", "--debug", "-b", bootArgs]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch {
            throw FirmwareError(.internal, "iBoot32Patcher (\(tool.path)) not runnable: \(error.localizedDescription)")
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 || p.terminationStatus == 1, FileManager.default.fileExists(atPath: dst.path)
        else {
            throw FirmwareError(.internal, "iBoot32Patcher failed (exit \(p.terminationStatus)):\n\(text)")
        }
        let patched = try Data(contentsOf: dst)
        guard patched.count == iboot.count, patched != iboot else {
            throw FirmwareError(
                .internal,
                "iBoot32Patcher produced \(patched.count) bytes (input \(iboot.count)), or no change; boot-args bypass not applied"
            )
        }
        log("iBoot patched (\(tool.lastPathComponent)): --rsa --debug -b")
        return patched
    }

    // MARK: - Bytes

    static func le32Bytes(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
}
