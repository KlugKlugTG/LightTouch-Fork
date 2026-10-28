package org.un1box.android

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.compose.runtime.*
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.util.UUID
import java.util.concurrent.CancellationException
import java.security.MessageDigest

internal data class GuestDeb(val name: String, val path: String, val bytes: Long)

/** Progress for a .deb transfer and its guest installation. */
internal data class CydiaTransferJob(val name: String, val phase: String, val progress: Float? = null, val error: String? = null,
                                     val done: Boolean = false, val cancellable: Boolean = false)

/** Transfers survive an activity recreation. Android holds only a temporary copy, removed after every attempt. */
internal object CydiaTransfers {
    private val handler = Handler(Looper.getMainLooper())
    var job by mutableStateOf<CydiaTransferJob?>(null); private set
    var active by mutableStateOf(false); private set
    var files by mutableStateOf<List<GuestDeb>>(emptyList()); private set
    var loading by mutableStateOf(false); private set
    var message by mutableStateOf(""); private set
    var installed by mutableStateOf<List<AptPackage>>(emptyList()); private set
    var installerMessage by mutableStateOf(""); private set
    @Volatile private var cancelled = false
    private var browseGeneration = 0

    fun cancel() { cancelled = true }
    fun dismissJob() { if (!active) job = null }

    fun refresh(context: Context, socket: String?) {
        val generation = ++browseGeneration
        files = emptyList(); installed = emptyList(); message = ""; installerMessage = ""; loading = socket != null
        if (socket == null) { message = "Start iOS to see its .deb files."; return }
        val app = context.applicationContext
        Thread({
            val outcome = runCatching {
                val rows = GuestApps(app).run(socket, listOf("deb-list"), 60).getJSONArray("files")
                (0 until rows.length()).map { index -> rows.getJSONObject(index).let { GuestDeb(it.getString("name"), it.getString("path"), it.getLong("bytes")) } }
            }
            val packages = runCatching { installedPackages(GuestApps(app), socket) }
            handler.post {
                if (generation != browseGeneration) return@post
                loading = false
                outcome.onSuccess { files = it.sortedBy { entry -> entry.name.lowercase() } }
                    .onFailure { message = it.message ?: "Could not read the iOS package folder." }
                packages.onSuccess { installed = it }.onFailure { installerMessage = it.message.orEmpty() }
            }
        }, "cydia-files").start()
    }

    private fun installedPackages(apps: GuestApps, socket: String): List<AptPackage> =
        AptControl.parse(apps.run(socket, listOf("deb-installed"), 60).getString("status")).map { AptPackage(it) }.filter { it.installed }

    fun installPackage(context: Context, socket: String, p: AptPackage) = transfer(context, socket, p.name, p) { _, target, report ->
        fetchPackage(p, target, report); DebArchive.name(p.download.substringBefore('?').substringAfterLast('/'))
    }

    private fun fetchPackage(p: AptPackage, target: File, report: (CydiaTransferJob) -> Unit) {
        try { AptNetwork.fetch(p.download) { input, total, _ -> copy(input, target, total, "Downloading ${p.name}", report) } }
        catch (failure: Exception) { throw IllegalStateException("${p.name}: ${failure.message}", failure) }
        p.fields["Size"]?.toLongOrNull()?.let { check(target.length() == it) { "${p.name}: package size does not match the repository index." } }
        val hash = listOf("SHA256" to "SHA-256", "SHA1" to "SHA-1", "MD5sum" to "MD5").firstOrNull { p.fields[it.first]?.isNotBlank() == true }
        if (hash != null) {
            val digest = MessageDigest.getInstance(hash.second)
            target.inputStream().use { input -> val buffer = ByteArray(65536); while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) } }
            check(digest.digest().joinToString("") { "%02x".format(it) }.equals(p.fields[hash.first], true)) { "${p.name}: package checksum does not match the repository index." }
        }
    }

    private fun installSaved(apps: GuestApps, socket: String, name: String, label: String, report: (CydiaTransferJob) -> Unit): String {
        val token = UUID.randomUUID().toString().replace("-", "")
        apps.run(socket, listOf("deb-queue", "--deb-name", name, "--token", token), 60)
        val deadline = System.nanoTime() + 900_000_000_000L
        var transientFailures = 0
        while (System.nanoTime() < deadline) {
            report(CydiaTransferJob(label, "Installing in iOS"))
            val attempt = runCatching { apps.run(socket, listOf("deb-status", "--token", token), 30) }
            if (attempt.isFailure) {
                check(++transientFailures < 6) { "Lost connection to iOS. Installation result is unconfirmed; refresh Installed after reconnecting." }
                Thread.sleep(2000); continue
            }
            transientFailures = 0
            val status = attempt.getOrThrow(); val phase = status.getString("status").trim()
            if (phase == "installed") return status.optString("log")
            check(!phase.startsWith("failed:")) { "dpkg ${phase.substringAfter(':')}:\n${status.optString("log").takeLast(12000)}" }
            Thread.sleep(1500)
        }
        error("iOS did not finish the installation in 15 minutes. Result is unconfirmed; refresh Installed. The request remains in iOS.")
    }

    fun installFile(context: Context, socket: String, file: GuestDeb) {
        if (active) return
        val app = context.applicationContext
        active = true; job = CydiaTransferJob(file.name, "Connecting to iOS")
        Thread({
            val report: (CydiaTransferJob) -> Unit = { next -> handler.post { job = next } }
            val outcome = runCatching {
                DownloadService.hold(app, "Installing .deb in iOS")
                val log = installSaved(GuestApps(app), socket, file.name, file.name, report)
                CydiaTransferJob(file.name, "Installed in iOS" + if (log.contains("Icon cache refresh failed")) ". Restart iOS to refresh icons." else "", 1f, done = true)
            }.getOrElse { CydiaTransferJob(file.name, "", error = it.message) }
            DownloadService.release(app)
            handler.post { active = false; job = outcome; refresh(app, socket) }
        }, "cydia-install-saved").start()
    }

    fun import(context: Context, socket: String, uri: Uri) = transfer(context, socket, "Local .deb") { app, target, report ->
        var name = "package.deb"
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
        }
        app.contentResolver.openInputStream(uri)?.use { input -> copy(input, target, -1, "Reading selected file", report) }
            ?: error("Cannot read the selected .deb file.")
        DebArchive.name(name)
    }

    fun download(context: Context, socket: String, link: String) {
        val address = try { DebArchive.address(link) } catch (failure: Exception) {
            if (!active) job = CydiaTransferJob("Download .deb", "", error = failure.message)
            return
        }
        transfer(context, socket, "Download .deb") { _, target, report ->
            var addressNow = address
            var connection: HttpURLConnection? = null
            try {
                for (attempt in 0..5) {
                    connection = addressNow.toURL().openConnection() as HttpURLConnection
                    connection.connectTimeout = 20_000; connection.readTimeout = 30_000
                    connection.instanceFollowRedirects = false
                    connection.setRequestProperty("Accept-Encoding", "identity")
                    val code = connection.responseCode
                    if (code in listOf(301, 302, 303, 307, 308)) {
                        val location = connection.getHeaderField("Location") ?: error("The download redirect has no address.")
                        check(attempt < 5) { "Too many download redirects." }
                        val redirect = DebArchive.address(addressNow.resolve(location).toString())
                        check(!addressNow.scheme.equals("https", ignoreCase = true) || redirect.scheme.equals("https", ignoreCase = true)) {
                            "The server redirected an HTTPS download to an insecure address. Use the package's direct link."
                        }
                        addressNow = redirect
                        connection.disconnect(); connection = null
                    } else {
                        check(code == 200) { "${addressNow.host}: HTTP $code" }
                        val total = connection.contentLengthLong
                        check(total <= DebArchive.LIMIT) { "The .deb is larger than 512 MB." }
                        connection.inputStream.use { copy(it, target, total, "Downloading", report) }
                        return@transfer DebArchive.name(addressNow.path.substringAfterLast('/').ifEmpty { "package.deb" })
                    }
                }
                error("Too many download redirects.")
            } finally { connection?.disconnect() }
        }
    }

    private fun copy(input: InputStream, target: File, total: Long, phase: String, report: (CydiaTransferJob) -> Unit) {
        target.outputStream().use { output ->
            val buffer = ByteArray(64 * 1024)
            var copied = 0L; var lastReport = 0L
            while (true) {
                if (cancelled) throw CancellationException("Cancelled")
                val count = input.read(buffer); if (count < 0) break
                copied += count
                check(copied <= DebArchive.LIMIT) { "The .deb is larger than 512 MB." }
                output.write(buffer, 0, count)
                val now = System.nanoTime()
                if (now - lastReport > 100_000_000) {
                    report(CydiaTransferJob(target.name, "$phase · ${byteSize(copied)}",
                        if (total > 0) (copied.toFloat() / total).coerceIn(0f, 1f) else null, cancellable = true))
                    lastReport = now
                }
            }
            check(total < 0 || copied == total) { "The download ended before the entire package arrived." }
        }
    }

    private fun transfer(context: Context, socket: String, label: String, expected: AptPackage? = null,
                         source: (Context, File, (CydiaTransferJob) -> Unit) -> String) {
        if (active) return
        val app = context.applicationContext
        active = true; cancelled = false; job = CydiaTransferJob(label, "Connecting to iOS")
        try { DownloadService.hold(app, "Sending .deb to iOS") } catch (failure: Exception) {
            DownloadService.release(app)
            active = false; job = CydiaTransferJob(label, "", error = failure.message ?: "Could not start the transfer.")
            return
        }
        Thread({
            val directory = File(app.cacheDir, "cydia-transfers/${UUID.randomUUID()}")
            val file = File(directory, "package.deb")
            val report: (CydiaTransferJob) -> Unit = { next -> handler.post { job = next } }
            var outcome: CydiaTransferJob
            try {
                val apps = GuestApps(app)
                apps.run(socket, listOf("deb-probe"), 60)
                val target = apps.target(socket)
                val present = installedPackages(apps, socket)
                val planned = expected?.let { AptDependencies.resolve(it, CydiaSources.packages.toList(), present, target.ios) }
                check(directory.mkdirs()) { "Cannot create the temporary package folder." }
                val name = source(app, file, report)
                if (cancelled) throw CancellationException("Cancelled")
                report(CydiaTransferJob(name, "Checking .deb"))
                val metadata = DebArchive.metadata(file)
                if (expected != null) check(metadata.id == expected.id && metadata.version == expected.version) { "The downloaded .deb does not match the selected package." }
                val plan = planned ?: AptDependencies.resolve(metadata, CydiaSources.packages.toList(), present, target.ios)
                for ((index, dep) in plan.dropLast(1).withIndex()) {
                    if (cancelled) throw CancellationException("Cancelled")
                    val dependencyFile = File(directory, "dependency-$index.deb")
                    try {
                        fetchPackage(dep, dependencyFile, report)
                        val info = DebArchive.metadata(dependencyFile)
                        check(info.id == dep.id && info.version == dep.version) { "Dependency metadata does not match ${dep.name}." }
                        val uploaded = apps.uploadDeb(socket, dependencyFile, DebArchive.name("${dep.id}_${dep.version}.deb")) {}
                        check(uploaded.optBoolean("uploaded") && uploaded.getLong("bytes") == dependencyFile.length()) { "Dependency upload is unconfirmed." }
                        installSaved(apps, socket, uploaded.getString("path").substringAfterLast('/'), dep.name, report)
                    } finally { dependencyFile.delete() }
                }
                if (cancelled) throw CancellationException("Cancelled")
                report(CydiaTransferJob(name, "Sending to iOS", 0f))
                val result = apps.uploadDeb(socket, file, name) { event ->
                    if (event.optString("phase") == "upload") report(CydiaTransferJob(name, "Sending to iOS", event.optInt("percent") / 100f))
                }
                check(result.optBoolean("uploaded") && result.getLong("bytes") == file.length()) { "The iOS transfer could not be confirmed." }
                val log = installSaved(apps, socket, result.getString("path").substringAfterLast('/'), metadata.name, report)
                check(installedPackages(apps, socket).any { it.id == metadata.id && it.version == metadata.version }) { "dpkg finished, but the package is absent from Installed. Installation is unconfirmed." }
                outcome = CydiaTransferJob(metadata.name, "Installed ${metadata.version} in iOS" + if (log.contains("Icon cache refresh failed")) ". Restart iOS to refresh icons." else "", 1f, done = true)
            } catch (_: CancellationException) {
                outcome = CydiaTransferJob(label, "Cancelled", done = true)
            } catch (failure: Exception) {
                outcome = CydiaTransferJob(label, "", error = failure.message ?: "Could not send the package to iOS.")
            } finally {
                file.delete(); directory.delete()
                DownloadService.release(app)
            }
            handler.post { active = false; job = outcome; refresh(app, socket) }
        }, "cydia-transfer").start()
    }
}
