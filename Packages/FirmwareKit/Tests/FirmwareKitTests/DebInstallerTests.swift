import Foundation
import Testing
@testable import FirmwareKit

struct DebInstallerTests {
    @Test func launchdWorkerUsesAtomicQueueAndRootDpkg() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("un1box-installer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("System/Library/LaunchDaemons"), withIntermediateDirectories: true)
        let installed = try SystemEdits.installDebInstaller(root)
        let job = try #require(NSDictionary(contentsOf: root.appendingPathComponent("System/Library/LaunchDaemons/org.un1box.deb-install.plist")))
        #expect(job["UserName"] as? String == "root")
        #expect(job["QueueDirectories"] as? [String] == ["/var/root/Media/Un1box/InstallQueue"])
        #expect(job["ProgramArguments"] as? [String] == ["/bin/bash", "/usr/libexec/un1box-deb-install"])
        let script = try String(contentsOf: root.appendingPathComponent("usr/libexec/un1box-deb-install"), encoding: .utf8)
        #expect(script.contains("dpkg --force-confold -i"))
        #expect(script.contains("mv -f \"$result.status.tmp\" \"$result.status\""))
        #expect(!script.contains("--force-depends"))
        #expect(installed.modes.contains { $0.path == "usr/libexec/un1box-deb-install" && $0.mode == 0o755 })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("private/var/root/Media/Un1box/InstallQueue").path))
    }
}
