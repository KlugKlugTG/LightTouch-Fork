// The iOS 7 kernel check that rejects launchd's `/` read-write remount (mount -u -o rw /).
// The jailbreak's fstab asks for a writable root so Cydia can update /Applications and /usr; without this patch,
// mount_hfs returns EPERM and launchd reboots. The patch is deliberately narrow: one exact Thumb-2 instruction
// sequence, one exact following branch, and one matching site in the decrypted kernelcache.

import Foundation

public enum RootFSPatch {
    /// `__mac_mount`'s rootfs branch: update/union flags, EPERM assignment and read-only test.
    public static let pattern: [UInt8] = [
        0x24, 0xF4, 0x80, 0x35, // bic r5, r4, #MNT_UPDATE
        0x14, 0xF0, 0x20, 0x0F, // tst.w r4, #MNT_UNION
        0x4F, 0xF0, 0x01, 0x0A, // mov.w r10, #EPERM
        0x08, 0xBF, // it eq
        0x44, 0xF4, 0x80, 0x35, // orreq r5, r4, #MNT_UPDATE
        0x15, 0xF0, 0x01, 0x0F, // tst.w r5, #MNT_RDONLY
    ]

    /// The stock `beq.w out`, taken for a read-write remount.
    public static let branch: [UInt8] = [0x01, 0xF0, 0x22, 0x80]
    /// Clear the pending EPERM after the branch is bypassed.
    public static let clearError: [UInt8] = [0x4F, 0xF0, 0x00, 0x0A]
    /// Two Thumb NOPs replace the exit branch.
    public static let skipExit: [UInt8] = [0x00, 0xBF, 0x00, 0xBF]
    public static let errorSlot = 8
    public static let branchSlot = pattern.count

    public struct Found: Sendable, Equatable {
        /// Virtual address of the rootfs remount branch.
        public let address: UInt32
        /// Original bytes at the pattern and branch, retained for diagnostics/tests.
        public let original: [UInt8]
    }

    public enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case notMachO, notFound, ambiguous, badBranch

        public var description: String {
            switch self {
            case .notMachO: return "not a 32-bit Mach-O kernelcache"
            case .notFound: return "no rootfs remount check (older iOS or different kernel)"
            case .ambiguous: return "the rootfs remount pattern occurs more than once"
            case .badBranch: return "the rootfs remount branch is not the expected beq.w out"
            }
        }
    }

    /// Locate the exact rootfs remount check in a decrypted, decompressed kernelcache.
    public static func locate(_ kernel: [UInt8]) throws -> Found {
        let (offset, found) = try site(kernel)
        _ = offset
        return found
    }

    /// Apply only the two instruction changes needed to let a read-write remount follow the stock read-only path.
    public static func apply(_ kernel: [UInt8]) throws -> (kernel: [UInt8], found: Found) {
        let (offset, found) = try site(kernel)
        var output = kernel
        output.replaceSubrange(offset + errorSlot..<offset + errorSlot + clearError.count, with: clearError)
        output.replaceSubrange(offset + branchSlot..<offset + branchSlot + skipExit.count, with: skipExit)
        return (output, found)
    }

    private static func site(_ kernel: [UInt8]) throws -> (Int, Found) {
        var hits: [Int] = []
        if kernel.count >= pattern.count {
            for offset in 0...(kernel.count - pattern.count)
            where kernel[offset..<offset + pattern.count].elementsEqual(pattern) {
                hits.append(offset)
            }
        }
        guard let offset = hits.first else { throw Error.notFound }
        guard hits.count == 1 else { throw Error.ambiguous }

        let branchOffset = offset + branchSlot
        guard branchOffset + branch.count <= kernel.count,
              Array(kernel[branchOffset..<branchOffset + branch.count]) == branch
        else { throw Error.badBranch }

        let image: Image
        do { image = try Image(kernel) } catch { throw Error.notMachO }
        guard let address = image.offToAddr(offset) else { throw Error.notMachO }
        return (offset, Found(address: address, original: Array(kernel[offset..<branchOffset + branch.count])))
    }
}
