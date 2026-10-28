package org.un1box.android

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

class DebArchiveTest {
    private fun archive(vararg entries: Pair<String, ByteArray>): ByteArray {
        val output = ByteArrayOutputStream()
        output.write("!<arch>\n".toByteArray())
        for ((name, bytes) in entries) {
            val header = (name + "/").padEnd(16) + "0".padEnd(12) + "0".padEnd(6) + "0".padEnd(6) +
                "100644".padEnd(8) + bytes.size.toString().padEnd(10) + "`\n"
            output.write(header.toByteArray()); output.write(bytes)
            if (bytes.size % 2 != 0) output.write('\n'.code)
        }
        return output.toByteArray()
    }

    private fun check(bytes: ByteArray) {
        val file = File.createTempFile("cydia-test-", ".deb")
        try { file.writeBytes(bytes); DebArchive.check(file) } finally { file.delete() }
    }

    private val version = "debian-binary" to "2.0\n".toByteArray()
    private val control = "control.tar.gz" to ByteArray(13) { 7 }
    private val data = "data.tar.xz" to ByteArray(16) { 9 }

    @Test fun acceptsStandardDebianContainerAndCompressedMembers() { check(archive(version, control, data)) }
    @Test fun rejectsHtmlAndTruncatedDownloads() {
        assertThrows(IllegalArgumentException::class.java) { check("<html>error</html>".toByteArray()) }
        assertThrows(IllegalArgumentException::class.java) { check(archive(version, control, data).dropLast(1).toByteArray()) }
    }
    @Test fun requiresDebianVersionAndBothArchives() {
        assertThrows(IllegalArgumentException::class.java) { check(archive(control, data)) }
        assertThrows(IllegalArgumentException::class.java) { check(archive(version, control)) }
        assertThrows(IllegalArgumentException::class.java) { check(archive("debian-binary" to "1.0\n".toByteArray(), control, data)) }
    }
    @Test fun rejectsDuplicateMembersAndWrongPadding() {
        assertThrows(IllegalArgumentException::class.java) { check(archive(version, control, control, data)) }
        val bytes = archive(version, control, data)
        bytes[8 + 60 + 4 + 60 + 13] = 0
        assertThrows(IllegalArgumentException::class.java) { check(bytes) }
    }
    @Test fun acceptsLegacyHttpAndRejectsNonWebAddressesOrCredentials() {
        for (address in listOf("file:///p.deb", "javascript:alert(1)", "https://name:secret@example.org/p.deb", "https://example.org:0/p.deb", "https://example.org/p.deb#fragment"))
            assertThrows(IllegalArgumentException::class.java) { DebArchive.address(address) }
        assertEquals("example.org", DebArchive.address("https://example.org/p.deb?token=123").host)
        assertEquals("http", DebArchive.address("http://apt.saurik.com/example.deb").scheme)
    }
    @Test fun filenamesStayInsideTheGuestPackageDirectory() {
        assertEquals("evil.deb", DebArchive.name("../../evil.deb"))
        assertEquals("my_package.deb", DebArchive.name("C:\\Downloads\\my package.DEB"))
        assertEquals("package.deb", DebArchive.name(""))
        assertTrue(DebArchive.name("x".repeat(1000)).length <= 84)
    }
}
