// The Cydia bootstrap's tar archives, read without the host's tar.
//
// Android has no /usr/bin/tar, and the tar a phone does have (toybox) fails on this bootstrap: it can't make hard
// links in an app's storage (SELinux refuses link(2) with "Permission denied"), and with -k it reports every entry
// that already exists, symbolic links included, as an error, so one "File exists" fails the whole preparation. This
// reader does what installCydia needs the same way on every platform: an existing file, link or directory is kept
// (tar -k), a hard link becomes a copy of its target, and a set-user-ID or set-group-ID bit is reported by
// specialModes but not applied (the catalog sets those, with the root owner).
//
// It reads plain tar, ustar name prefixes, GNU long names and pax headers, and inflates gzip while it reads.

import Foundation
import zlib

enum TarExtract {
    /// One member of the archive: its header, with any long-name or pax header before it applied.
    struct Member {
        var path: String
        var type: UInt8
        var mode: UInt16
        var size: Int
        var link: String
    }

    /// Every member's path as a volume path (no leading ./, no trailing /), in archive order.
    static func paths(_ archive: URL) throws -> [String] {
        var result: [String] = []
        try walk(archive) { member, _ in result.append(volumePath(member.path)) }
        return result
    }

    /// The regular files with the set-user-ID or set-group-ID bit: their volume paths and permission bits.
    static func specialModes(_ archive: URL) throws -> [(path: String, mode: UInt16)] {
        var result: [(path: String, mode: UInt16)] = []
        try walk(archive) { member, _ in
            guard isRegular(member.type), member.mode & 0o6000 != 0 else { return }
            result.append((volumePath(member.path), member.mode & 0o6777))
        }
        return result
    }

    /// Extracts `archive` into the directory `root`, leaving out the volume paths in `excluded` and what is under
    /// them. Directories made here end up with their archive modes (owner access kept); files get theirs without
    /// the set-ID bits.
    static func extract(_ archive: URL, into root: URL, excluding excluded: [String]) throws {
        let fm = FileManager.default
        let top = root.resolvingSymlinksInPath().path
        var made: [(path: String, mode: mode_t)] = []
        try walk(archive) { member, source in
            let rel = volumePath(member.path)
            guard !rel.isEmpty, !excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) else { return }
            guard !rel.split(separator: "/").contains("..") else {
                throw FirmwareError(.internal, "tar: \(member.path) is outside the volume")
            }
            let url = root.appendingPathComponent(rel)
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            guard (parent.resolvingSymlinksInPath().path + "/").hasPrefix(top + "/") else {
                throw FirmwareError(.internal, "tar: \(rel) would be written outside the volume")
            }
            var info = stat()
            let exists = lstat(url.path, &info) == 0
            switch member.type {
            case UInt8(ascii: "5"):
                guard !exists else { return }
                guard mkdir(url.path, 0o755) == 0 else { throw posix("mkdir", url) }
                made.append((url.path, mode_t(member.mode & 0o777)))
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                guard !exists else { return }
                try store(source, size: member.size, to: url, mode: member.mode)
            case UInt8(ascii: "2"):
                guard !exists else { return }
                guard symlink(member.link, url.path) == 0 else { throw posix("symlink", url) }
            case UInt8(ascii: "1"):
                guard !exists else { return }
                let target = root.appendingPathComponent(volumePath(member.link))
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return }
                if isDirectory.boolValue {
                    // A directory can't be hard-linked; the bootstrap means a link such as ./etc -> private/etc.
                    guard symlink(member.link, url.path) == 0 else { throw posix("symlink", url) }
                } else {
                    try fm.copyItem(at: target, to: url)
                }
            default:
                return
            }
        }
        for directory in made {
            guard chmod(directory.path, directory.mode | 0o700) == 0 else {
                throw posix("chmod", URL(fileURLWithPath: directory.path))
            }
        }
    }

    /// A member name as a volume path: no leading ./, no trailing /.
    static func volumePath(_ name: String) -> String {
        var path = Substring(name)
        while path.hasPrefix("./") { path = path.dropFirst(2) }
        return String(path).trimmingCharacters(in: ["/"])
    }

    // MARK: - Writing

    /// Writes the next `size` bytes of `source` to a new file `url`, with the permission bits of `mode`.
    private static func store(_ source: Source, size: Int, to url: URL, mode: UInt16) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw posix("open", url) }
        defer { close(fd) }
        var left = size
        while left > 0 {
            let chunk = try source.readExactly(min(left, 1 << 16))
            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress.map { $0 + offset }, raw.count - offset)
                    guard n > 0 else { throw posix("write", url) }
                    offset += n
                }
            }
            left -= chunk.count
        }
        guard fchmod(fd, mode_t(mode & 0o777)) == 0 else { throw posix("chmod", url) }
    }

    private static func posix(_ what: String, _ url: URL) -> FirmwareError {
        FirmwareError(.internal, "tar: \(what) \(url.path): \(String(cString: strerror(errno)))")
    }

    // MARK: - Reading

    /// Calls `body` for each member, with `source` at the start of its data; whatever `body` leaves unread is
    /// skipped.
    private static func walk(_ archive: URL, _ body: (Member, Source) throws -> Void) throws {
        let source = try Source(archive)
        var longName: String?
        var longLink: String?
        var pax: [String: String] = [:]
        while true {
            let block = try source.read(512)
            if block.count < 512 || block.allSatisfy({ $0 == 0 }) { return }
            var member = try header(block)
            switch member.type {
            case UInt8(ascii: "L"):
                longName = cString(try source.readExactly(member.size)[...])
                try source.skip(padding(member.size))
            case UInt8(ascii: "K"):
                longLink = cString(try source.readExactly(member.size)[...])
                try source.skip(padding(member.size))
            case UInt8(ascii: "x"):
                pax.merge(paxRecords(try source.readExactly(member.size))) { _, new in new }
                try source.skip(padding(member.size))
            case UInt8(ascii: "g"):
                try source.skip(member.size + padding(member.size))
            default:
                if let longName { member.path = longName }
                if let longLink { member.link = longLink }
                if let path = pax["path"] { member.path = path }
                if let link = pax["linkpath"] { member.link = link }
                if let size = pax["size"].flatMap({ Int($0) }) { member.size = size }
                if member.type == UInt8(ascii: "2") || member.type == UInt8(ascii: "5") { member.size = 0 }
                longName = nil
                longLink = nil
                pax = [:]
                let before = source.position
                try body(member, source)
                let used = source.position - before
                guard used <= member.size else { throw FirmwareError(.internal, "tar: read past \(member.path)") }
                try source.skip(member.size - used + padding(member.size))
            }
        }
    }

    private static func header(_ block: [UInt8]) throws -> Member {
        guard let size = octal(block[124..<136]), let mode = octal(block[100..<108]) else {
            throw FirmwareError(.internal, "tar: a header with a bad number")
        }
        var path = cString(block[0..<100])
        if block[257..<262].elementsEqual("ustar".utf8), block[262] == 0 {
            let prefix = cString(block[345..<500])
            if !prefix.isEmpty { path = prefix + "/" + path }
        }
        return Member(
            path: path,
            type: block[156],
            mode: UInt16(truncatingIfNeeded: mode & 0o7777),
            size: size,
            link: cString(block[157..<257])
        )
    }

    /// A header number: octal digits, or GNU's big-endian binary when the top bit is set.
    private static func octal(_ field: ArraySlice<UInt8>) -> Int? {
        if let first = field.first, first & 0x80 != 0 {
            return field.dropFirst().reduce(Int(first & 0x7F)) { $0 << 8 | Int($1) }
        }
        var value = 0
        var seen = false
        for byte in field {
            if byte == 0 || byte == 0x20 {
                if seen { break }
                continue
            }
            guard byte >= 0x30, byte <= 0x37 else { return nil }
            value = value * 8 + Int(byte - 0x30)
            seen = true
        }
        return value
    }

    private static func cString(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// A pax extended header's records ("<length> <key>=<value>\n", the length counting the whole record).
    private static func paxRecords(_ data: [UInt8]) -> [String: String] {
        var records: [String: String] = [:]
        var at = 0
        while at < data.count {
            guard let space = data[at...].firstIndex(of: 0x20),
                let length = Int(String(decoding: data[at..<space], as: UTF8.self)),
                length > space - at + 1, at + length <= data.count
            else { break }
            let record = data[(space + 1)..<(at + length - 1)]
            if let equals = record.firstIndex(of: UInt8(ascii: "=")) {
                records[String(decoding: record[record.startIndex..<equals], as: UTF8.self)] =
                    String(decoding: record[(equals + 1)...], as: UTF8.self)
            }
            at += length
        }
        return records
    }

    private static func padding(_ size: Int) -> Int { (512 - size % 512) % 512 }

    private static func isRegular(_ type: UInt8) -> Bool {
        type == 0 || type == UInt8(ascii: "0") || type == UInt8(ascii: "7")
    }

    // MARK: - The bytes

    /// The archive's bytes in order, inflated as they are read when the file is gzip.
    private final class Source {
        private let handle: FileHandle
        private var stream = z_stream()
        private var gzip = false
        private var input = Data()
        private var inputAt = 0
        private var finished = false
        /// How many bytes have been handed out.
        private(set) var position = 0

        init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
            let head = try handle.read(upToCount: 2) ?? Data()
            try handle.seek(toOffset: 0)
            if head.count == 2, head[head.startIndex] == 0x1F, head[head.startIndex + 1] == 0x8B {
                guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw FirmwareError(.internal, "tar: zlib did not start")
                }
                gzip = true
            }
        }

        deinit {
            if gzip { inflateEnd(&stream) }
            try? handle.close()
        }

        /// Exactly `count` bytes, or an error when the archive ends first.
        func readExactly(_ count: Int) throws -> [UInt8] {
            let bytes = try read(count)
            guard bytes.count == count else { throw FirmwareError(.internal, "tar: the archive ends inside a member") }
            return bytes
        }

        /// Up to `count` bytes, fewer only at the end of the archive.
        func read(_ count: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            var filled = 0
            while filled < count {
                let n = try fill(&bytes, from: filled)
                if n == 0 { break }
                filled += n
            }
            position += filled
            return filled == count ? bytes : Array(bytes[0..<filled])
        }

        func skip(_ count: Int) throws {
            var left = count
            while left > 0 {
                let got = try read(min(left, 1 << 16)).count
                guard got > 0 else { throw FirmwareError(.internal, "tar: the archive ends inside a member") }
                left -= got
            }
        }

        /// Puts some bytes at `offset` of `bytes`, up to its end; 0 at the end of the archive.
        private func fill(_ bytes: inout [UInt8], from offset: Int) throws -> Int {
            let wanted = bytes.count - offset
            guard gzip else {
                let data = try handle.read(upToCount: wanted) ?? Data()
                bytes.replaceSubrange(offset..<offset + data.count, with: data)
                return data.count
            }
            while !finished {
                if inputAt >= input.count {
                    input = try handle.read(upToCount: 1 << 16) ?? Data()
                    inputAt = 0
                    if input.isEmpty { return 0 }
                }
                var produced = 0
                var status = Z_OK
                input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    bytes.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                        guard let source = raw.baseAddress, let target = out.baseAddress else { return }
                        let next = source.assumingMemoryBound(to: Bytef.self) + inputAt
                        stream.next_in = UnsafeMutablePointer(mutating: next)
                        stream.avail_in = uInt(raw.count - inputAt)
                        stream.next_out = target.assumingMemoryBound(to: Bytef.self) + offset
                        stream.avail_out = uInt(wanted)
                        status = inflate(&stream, Z_NO_FLUSH)
                        inputAt = raw.count - Int(stream.avail_in)
                        produced = wanted - Int(stream.avail_out)
                    }
                }
                if status == Z_STREAM_END {
                    finished = true
                } else if status != Z_OK && status != Z_BUF_ERROR {
                    throw FirmwareError(.internal, "tar: the gzip data is damaged (zlib \(status))")
                }
                if produced > 0 { return produced }
            }
            return 0
        }
    }
}
