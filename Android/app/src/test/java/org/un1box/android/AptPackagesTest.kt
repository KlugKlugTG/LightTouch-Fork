package org.un1box.android

import org.junit.Assert.*
import org.junit.Test

class AptPackagesTest {
    private fun p(id: String, version: String = "1.0", depends: String = "", installed: Boolean = false, provides: String = "") =
        AptPackage(mapOf("Package" to id, "Version" to version, "Architecture" to "iphoneos-arm", "Depends" to depends,
            "Provides" to provides, "Status" to if (installed) "install ok installed" else ""), "repo", "https://example.org/$id.deb")
    @Test fun continuationsAndFinalStanza() {
        val records = AptControl.parse("Package: a\r\nDescription: First\r\n second\r\n .\r\n third\r\n\r\nPackage: b\r\nVersion: 1")
        assertEquals(2, records.size); assertEquals("First\nsecond\n\nthird", records[0]["Description"]); assertEquals("b", records[1]["Package"])
    }
    @Test fun versionsFollowDpkgOrdering() {
        for ((a, b) in listOf("1.0~rc1" to "1.0", "1.9" to "1.10", "1.0-2" to "1.0-10", "9.0" to "1:1.0", "1.0" to "1.0+a", "1.0~~" to "1.0~")) {
            assertTrue("$a < $b", DebianVersion.compare(a,b) < 0); assertTrue(DebianVersion.compare(b,a) > 0)
        }
        assertEquals(0, DebianVersion.compare("1.01", "1.1")); assertEquals(0, DebianVersion.compare("1.0", "1.0-0"))
    }
    @Test fun alternativesVersionsAndDependencyOrder() {
        val app = p("app", depends = "firmware (>= 4.0), missing | lib (>= 2.0)")
        val lib = p("lib", "2.1", "base")
        assertEquals(listOf("base", "lib", "app"), AptDependencies.resolve(app, listOf(lib,p("lib","1.0"),p("base")), emptyList(),"5.1.1").map { it.id })
    }
    @Test fun installedAndVirtualDependenciesDoNotDownload() {
        val app = p("app", depends = "virtual, lib (>= 2.0)")
        assertEquals(listOf("app"), AptDependencies.resolve(app, emptyList(), listOf(p("provider",installed=true,provides="virtual"),p("lib","2.0",installed=true)),"5.1.1").map { it.id })
    }
    @Test fun newerFirmwareAndMissingDependenciesFailBeforeTransfer() {
        for (app in listOf(p("app",depends="firmware (>= 9.0)"),p("app",depends="missing (>= 2.0)"))) {
            try { AptDependencies.resolve(app,emptyList(),emptyList(),"5.1.1"); fail("Must reject incompatible/missing prerequisite") } catch (_: IllegalStateException) { }
        }
    }
    @Test fun cyclesAreReported() {
        try { AptDependencies.resolve(p("a",depends="b"),listOf(p("b",depends="a"),p("a",depends="b")),emptyList(),"5.1.1"); fail("Must report cycle") } catch (_: IllegalStateException) { }
    }
}
