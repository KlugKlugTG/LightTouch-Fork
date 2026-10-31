package org.un1box.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Cydia option: offered from iPhone OS 2.0 on (firmwarekit refuses 1.x, whose afcd serves no path through afc2),
 * and the three archives it installs, pinned with their SHA-1s as SystemEdits.Cydia pins them.
 */
class CydiaBootstrapTest {
    @Test fun theJailbreakIsOfferedFromIPhoneOS2() {
        for (version in listOf("1.0", "1.1.1", "1.1.4", "1.1.5")) assertFalse(version, CydiaBootstrap.offers(version))
        for (version in listOf("2.0", "2.2.1", "3.1.3", "4.2.1", "5.1.1", "6.1.6", "7.1.2")) {
            assertTrue(version, CydiaBootstrap.offers(version))
        }
        assertFalse("no version", CydiaBootstrap.offers(""))
    }

    @Test fun theArchivesAreTheOnesThePreparerInstalls() {
        assertEquals(
            listOf("freeze.tar.gz", "cydiasubstrate.tar", "cydiahttpatch.tar"),
            CydiaBootstrap.files.keys.toList(),
        )
        // SHA-1, as Legacy-iOS-Kit's pinned files: firmwarekit checks these again and downloads nothing itself.
        assertEquals("c943e5ece72b7b71da589c22663a8f9b3b3d1190", CydiaBootstrap.files["freeze.tar.gz"])
        assertEquals("264f47938acc09e6cc2890a3cc7c7988a6822da3", CydiaBootstrap.files["cydiasubstrate.tar"])
        assertEquals("3a1302c6294fe290c6d52186dd4fe56cda7fd661", CydiaBootstrap.files["cydiahttpatch.tar"])
    }
}
