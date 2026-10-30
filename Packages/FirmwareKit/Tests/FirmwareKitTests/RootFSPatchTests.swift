import Foundation
import Testing

@testable import FirmwareKit

struct RootFSPatchTests {
    private static func synthetic(patternAt: Int = 0x1010, branch: [UInt8] = RootFSPatch.branch) -> [UInt8] {
        var kernel = [UInt8](repeating: 0, count: 0x2000)
        put32(0xFEED_FACE, at: 0, in: &kernel) // MH_MAGIC, little-endian
        put32(12, at: 4, in: &kernel) // ARM
        put32(1, at: 16, in: &kernel) // ncmds
        put32(56, at: 20, in: &kernel) // sizeofcmds
        put32(1, at: 28, in: &kernel) // LC_SEGMENT
        put32(56, at: 32, in: &kernel)
        Array("__TEXT".utf8).enumerated().forEach { kernel[36 + $0.offset] = $0.element }
        put32(0x8000_2000, at: 52, in: &kernel) // vmaddr
        put32(0x1000, at: 56, in: &kernel) // vmsize
        put32(0x1000, at: 60, in: &kernel) // fileoff
        put32(0x1000, at: 64, in: &kernel) // filesize
        kernel.replaceSubrange(patternAt..<patternAt + RootFSPatch.pattern.count, with: RootFSPatch.pattern)
        let branchAt = patternAt + RootFSPatch.branchSlot
        kernel.replaceSubrange(branchAt..<branchAt + branch.count, with: branch)
        return kernel
    }

    private static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    @Test func patchesOnlyTheErrorAndExitSlots() throws {
        let original = synthetic()
        let found = try RootFSPatch.locate(original)
        #expect(found.address == 0x8000_2010)
        #expect(found.original.count == RootFSPatch.pattern.count + RootFSPatch.branch.count)

        let (patched, applied) = try RootFSPatch.apply(original)
        #expect(applied == found)
        let offset = 0x1010
        #expect(Array(patched[offset + RootFSPatch.errorSlot..<offset + RootFSPatch.errorSlot + 4]) == RootFSPatch.clearError)
        #expect(Array(patched[offset + RootFSPatch.branchSlot..<offset + RootFSPatch.branchSlot + 4]) == RootFSPatch.skipExit)
        let changed = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed.count == 5)
        #expect(changed.allSatisfy {
            (offset + RootFSPatch.errorSlot..<offset + RootFSPatch.errorSlot + 4).contains($0)
                || (offset + RootFSPatch.branchSlot..<offset + RootFSPatch.branchSlot + 4).contains($0)
        })
    }

    @Test func missingPatternIsTreatedAsUnpatchedFirmware() throws {
        do {
            _ = try RootFSPatch.locate([])
            Issue.record("empty kernel unexpectedly had a rootfs patch site")
        } catch let error as RootFSPatch.Error {
            #expect(error == .notFound)
        }
    }

    @Test func duplicatePatternIsRejectedRatherThanGuessed() throws {
        var kernel = synthetic()
        let second = 0x1100
        kernel.replaceSubrange(second..<second + RootFSPatch.pattern.count, with: RootFSPatch.pattern)
        let branchAt = second + RootFSPatch.branchSlot
        kernel.replaceSubrange(branchAt..<branchAt + RootFSPatch.branch.count, with: RootFSPatch.branch)
        do {
            _ = try RootFSPatch.locate(kernel)
            Issue.record("ambiguous rootfs patch site was accepted")
        } catch let error as RootFSPatch.Error {
            #expect(error == .ambiguous)
        }
    }

    @Test func unexpectedBranchIsRejected() throws {
        let kernel = synthetic(branch: [0x00, 0xBF, 0x00, 0xBF])
        do {
            _ = try RootFSPatch.locate(kernel)
            Issue.record("unexpected branch was accepted")
        } catch let error as RootFSPatch.Error {
            #expect(error == .badBranch)
        }
    }

    /// Optional integration check against a decrypted iOS 7.1.2 kernelcache (`LTM_ROOTFS_KERNEL`).
    @Test func patchesTheKnownIOS712KernelWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["LTM_ROOTFS_KERNEL"] else { return }
        let kernel = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped))
        let (patched, found) = try RootFSPatch.apply(kernel)
        #expect(found.address == 0x8013_252E)
        let changed = zip(kernel, patched).filter { $0.0 != $0.1 }.count
        #expect(changed == 5)
    }
}
