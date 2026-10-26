package org.lighttouch.android

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Cydia's bootstrap: the archives a jailbroken preparation installs (`firmwarekit create --jailbreak`, the
 * SystemEdits.Cydia of Packages/FirmwareKit, which pins them and their SHA-1s). saurik's freeze.tar as Legacy iOS
 * Kit ships it (Cydia 1.1.30, apt, dpkg, bash and the base packages), Substrate's Safe Mode extension and Cydia
 * HTTPatch for iOS 3.
 *
 * The phone downloads them into the folder firmwarekit reads them from: the "Jailbreak" folder beside the cache it
 * prepares with (cacheDir/firmwarekit for FirmwareService, so cacheDir/Jailbreak here). firmwarekit checks each
 * SHA-1 and fetches only a file that is missing or other bytes, so on this phone a preparation needs no network.
 */
internal object CydiaBootstrap {
    /** Each archive and its SHA-1, as SystemEdits.Cydia.files pins them (Legacy-iOS-Kit 4b0a582f). */
    val files = linkedMapOf(
        "freeze.tar.gz" to "c943e5ece72b7b71da589c22663a8f9b3b3d1190",
        "cydiasubstrate.tar" to "264f47938acc09e6cc2890a3cc7c7988a6822da3",
        "cydiahttpatch.tar" to "3a1302c6294fe290c6d52186dd4fe56cda7fd661",
    )
    private const val source =
        "https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/4b0a582f4d53e105be373b495734c8ed639fd634/resources/jailbreak/"

    /** The download in progress, and the last error: what it is doing and how far it is, for the prepare screen. */
    var running by mutableStateOf(false); private set
    var status by mutableStateOf(""); private set
    var progress by mutableFloatStateOf(-1f); private set

    /**
     * Where firmwarekit keeps the bootstrap: the "Jailbreak" folder beside its --cache, which is cacheDir/firmwarekit
     * for FirmwareService (Cydia.bootstrap in SystemEdits, and firmwarekit edit --action jailbreak, read it there).
     */
    fun directory(context: Context) = File(context.cacheDir, "Jailbreak")

    /** iPhone OS 2.0 and later: firmwarekit refuses the option on 1.x, whose afcd serves no path through afc2. */
    fun offers(version: String) = (version.substringBefore('.').toIntOrNull() ?: 0) >= 2

    /** Whether every archive is in place and matches its pinned SHA-1; blocking, as it hashes 8 MB. */
    fun ready(context: Context): Boolean {
        val dir = directory(context)
        return files.all { (name, want) -> File(dir, name).takeIf { it.isFile }?.let { sha1(it) == want } == true }
    }

    /** Downloads what is missing in the background; [onDone] runs on that thread with "" or what went wrong. */
    fun start(context: Context, onDone: (String) -> Unit) {
        if (running) return
        val app = context.applicationContext
        running = true; status = "Downloading Cydia"; progress = -1f
        DownloadService.hold(app, "Downloading Cydia")
        Thread({
            val error = try { download(app); "" } catch (e: Exception) { e.message ?: "Cydia could not be downloaded" }
            status = error
            running = false; progress = -1f
            DownloadService.release(app)
            onDone(error)
        }, "cydia-download").start()
    }

    /**
     * Downloads every archive that is missing or other bytes and checks it against its SHA-1; blocking, so call it
     * off the main thread. Throws with the reason when the pinned bytes are not what came back.
     */
    fun download(context: Context) {
        val dir = directory(context).apply { mkdirs() }
        for ((index, entry) in files.entries.withIndex()) {
            val name = entry.key
            val want = entry.value
            val target = File(dir, name)
            if (!target.isFile || sha1(target) != want) {
                status = "Downloading $name"
                fetch(name, target, want, index)
            }
            progress = (index + 1).toFloat() / files.size
        }
        status = ""
    }

    /** One archive from the pinned source, checked before it replaces the cached copy. */
    private fun fetch(name: String, target: File, want: String, index: Int) {
        val url = URL(source + name)
        val partial = File(target.path + ".partial")
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000; connection.readTimeout = 30_000; connection.instanceFollowRedirects = true
        try {
            val code = connection.responseCode
            check(code == 200) { "${url.host}: HTTP $code" }
            val total = connection.contentLengthLong
            java.io.RandomAccessFile(partial, "rw").use { out ->
                out.setLength(0)
                connection.inputStream.use { input ->
                    val buffer = ByteArray(1 shl 16); var have = 0L
                    while (true) {
                        val n = input.read(buffer); if (n < 0) break
                        out.write(buffer, 0, n); have += n
                        if (total > 0) progress = (index + have.toFloat() / total) / files.size
                    }
                }
            }
            check(sha1(partial) == want) { "$name did not match its SHA-1; try again" }
            check(partial.renameTo(target)) { "Could not save $name" }
        } catch (e: Exception) {
            partial.delete()
            throw e
        } finally {
            connection.disconnect()
        }
    }

    fun sha1(file: File): String {
        val digest = MessageDigest.getInstance("SHA-1")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buffer); if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
