import Foundation
import zlib

extension SystemEdits {
    /// Read hard links from tar headers. OEM toybox versions disagree on how `tar -tv` prints them.
    /// gzread also accepts an uncompressed tar; only headers and GNU/PAX names are kept in memory.
    static func bootstrapArchiveHardLinks(_ archive: URL) throws -> [(path: String, target: String)] {
        guard let stream = gzopen(archive.path, "rb") else {
            throw FirmwareError(.internal, "Cydia: cannot open \(archive.lastPathComponent)")
        }
        defer { gzclose(stream) }
        func corrupt(_ detail: String) -> FirmwareError {
            FirmwareError(.internal, "Cydia: \(archive.lastPathComponent): \(detail)")
        }
        func read(_ count: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let got = bytes.withUnsafeMutableBytes {
                    gzread(stream, $0.baseAddress!.advanced(by: offset), UInt32(count - offset))
                }
                guard got > 0 else { throw corrupt("truncated or invalid tar stream") }
                offset += Int(got)
            }
            return bytes
        }
        func text(_ bytes: ArraySlice<UInt8>) throws -> String {
            guard let result = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) else {
                throw corrupt("invalid archive filename")
            }
            return result
        }
        func octal(_ bytes: ArraySlice<UInt8>) throws -> Int {
            let value = try text(bytes).trimmingCharacters(in: .whitespaces)
            guard let number = Int(value.isEmpty ? "0" : value, radix: 8), number >= 0 else {
                throw corrupt("invalid tar header number")
            }
            return number
        }
        func safe(_ raw: String) throws -> String {
            guard !raw.hasPrefix("/") else { throw corrupt("absolute hard-link path") }
            var name = raw
            while name.hasPrefix("./") { name.removeFirst(2) }
            guard !name.isEmpty, !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            }) else { throw corrupt("invalid hard-link path") }
            return name
        }
        var links: [(path: String, target: String)] = []
        var longName: String?, longTarget: String?
        var pax: [String: String] = [:]
        while true {
            let header = try read(512)
            if header.allSatisfy({ $0 == 0 }) { return links }
            let checksum = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard checksum == (try octal(header[148..<156])) else { throw corrupt("invalid tar header checksum") }
            let size = try octal(header[124..<136])
            guard size <= Int.max - 511 else { throw corrupt("invalid tar member size") }
            let padded = (size + 511) / 512 * 512
            let type = header[156]
            if type == 76 || type == 75 || type == 120 { // GNU long name/link or per-member PAX header
                guard padded <= 1 << 20 else { throw corrupt("oversized archive filename metadata") }
                let body = try read(padded)
                if type == 120 {
                    var offset = 0
                    while offset < size {
                        guard let space = body[offset..<size].firstIndex(of: 32),
                            let length = Int(String(decoding: body[offset..<space], as: UTF8.self)),
                            length > space - offset + 1, length <= size - offset
                        else { throw corrupt("invalid PAX record") }
                        let record = String(decoding: body[(space + 1)..<(offset + length - 1)], as: UTF8.self)
                        if let equals = record.firstIndex(of: "=") {
                            pax[String(record[..<equals])] = String(record[record.index(after: equals)...])
                        }
                        offset += length
                    }
                } else if type == 76 { longName = try text(body[0..<size]) }
                else { longTarget = try text(body[0..<size]) }
                continue
            }
            if type == 49 { // POSIX hard link, distinct from a symbolic link (type 2)
                var name = try text(header[0..<100])
                if header[257..<263].elementsEqual([117, 115, 116, 97, 114, 0]) {
                    let prefix = try text(header[345..<500])
                    if !prefix.isEmpty { name = prefix + "/" + name }
                }
                let target = try text(header[157..<257])
                links.append((try safe(pax["path"] ?? longName ?? name), try safe(pax["linkpath"] ?? longTarget ?? target)))
            }
            longName = nil; longTarget = nil; pax.removeAll()
            if padded > 0, gzseek(stream, numericCast(padded), SEEK_CUR) < 0 {
                throw corrupt("cannot read tar member")
            }
        }
    }
}
