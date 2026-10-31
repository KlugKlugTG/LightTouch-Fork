package org.un1box.android

import android.app.*
import android.content.Intent
import android.os.*
import org.json.JSONObject
import java.io.File
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One preparation per process, independent of a running QEMU worker: firmwarekit (Packages/FirmwareKit, the
 * preparer every Un1box port shares) builds the device from its IPSW, with its build-time boots through
 * lighttouch-oneshot and the APK's engine, into a device folder that the device worker moves into its library.
 * Both ship as executables in nativeLibraryDir (libfirmwarekit.so, liblighttouch_oneshot.so).
 */
class FirmwareService : Service() {
    private val consumed = AtomicBoolean(false)
    @Volatile private var destination = ""
    @Volatile private var failure = ""
    @Volatile private var currentFirmwareId = ""
    @Volatile private var cancelling = false
    @Volatile private var state = "idle"
    @Volatile private var stage = ""
    @Volatile private var done = 0L
    @Volatile private var total = 0L
    /** Each finished step's name and seconds, a line each ("name\tseconds"), for the finished screen's details. */
    @Volatile private var timings = ""
    @Volatile private var process: java.lang.Process? = null

    private val binder = object : IFirmware.Stub() {
        override fun supports(firmwareId: String): Boolean {
            val libs = File(applicationInfo.nativeLibraryDir)
            if (!File(libs, "libfirmwarekit.so").canExecute() || !File(libs, "liblighttouch_oneshot.so").canExecute()) return false
            val entry = FirmwareCatalog.load(this@FirmwareService).firstOrNull { it.id == firmwareId } ?: return false
            return !entry.needsIBootPatcher || File(libs, "libiboot32patcher.so").canExecute()
        }
        override fun start(
            firmwareId: String, ipswPath: String, trustedToolsRoot: String, bootromPath: String, jailbreak: Boolean
        ): Bundle = startWithSibling(firmwareId, ipswPath, "", trustedToolsRoot, bootromPath, jailbreak)
        override fun startWithSibling(
            firmwareId: String, ipswPath: String, siblingIpswPath: String, trustedToolsRoot: String, bootromPath: String, jailbreak: Boolean
        ): Bundle {
            check(consumed.compareAndSet(false, true)) { "A fresh firmware worker is required" }
            foreground()
            currentFirmwareId = firmwareId
            state = "preparing"; stage = "Starting"
            val parent = File(filesDir, "prepared").apply { mkdirs() }
            val job = java.lang.Long.toHexString(SystemClock.uptimeMillis())
            destination = File(parent, "job-$job").absolutePath
            note("preparing")
            Thread({ prepare(firmwareId, ipswPath, siblingIpswPath, File(trustedToolsRoot), bootromPath, jailbreak) }, "firmwarekit").start()
            return status()
        }
        override fun status(): Bundle = Bundle().apply {
            val phase = when {
                failure.isNotEmpty() -> "failed"
                cancelling && state == "preparing" -> "cancelling"
                else -> state
            }
            putString("state", phase); putString("stage", stage)
            putBoolean("consumed", consumed.get())
            putLong("done", done); putLong("total", total); putInt("code", if (failure.isEmpty()) 0 else 1)
            putString("error", failure); putString("destination", destination); putString("timings", timings)
            putInt("uid", Process.myUid()); putInt("pid", Process.myPid()); putString("firmwareId", currentFirmwareId)
        }
        override fun jailbreak(devicePath: String): Bundle {
            check(consumed.compareAndSet(false, true)) { "A fresh firmware worker is required" }
            foreground("Jailbreaking the device")
            state = "preparing"; stage = "Starting"
            Thread({ editJailbreak(File(devicePath)) }, "firmwarekit-edit").start()
            return status()
        }
        override fun cancel() { cancelling = true; process?.destroy() }
        override fun finish() {
            check(state != "preparing") { "Cancel preparation and wait for a terminal result before closing the worker" }
            Handler(mainLooper).postDelayed({ stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); Process.killProcess(Process.myPid()) }, 200)
        }
    }

    /**
     * create into `destination`, the device folder the engine worker then moves into its library as it is
     * (adoptPrepared: no pack-base, no copy, no second hash). The IPSW is only read. With `jailbreak`, the Cydia
     * bootstrap the activity downloaded (CydiaBootstrap.directory) is read from beside the cache and installed.
     */
    private fun prepare(firmwareId: String, ipsw: String, siblingIpsw: String, tools: File, bootrom: String, jailbreak: Boolean) {
        // Preparation boots iOS (the keybag, the first start) against timeouts: the CPU stays awake while the phone
        // locks or the user switches away. The foreground service only keeps the process alive, not the CPU running.
        val awake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Un1box:preparation")
        awake.acquire(60 * 60 * 1000L)
        val libs = File(applicationInfo.nativeLibraryDir)
        val cache = File(cacheDir, "firmwarekit")
        val out = File(destination)
        try {
            // The bootstrap comes from the activity (CydiaBootstrap): firmwarekit checks it again and would download
            // it only on a host with a network, so a phone names the file it lacks instead.
            if (jailbreak) {
                stage = "Checking Cydia bootstrap"
                val bootstrap = CydiaBootstrap.directory(this)
                val missing = CydiaBootstrap.files.keys.firstOrNull { !File(bootstrap, it).isFile }
                check(missing == null) { "Cydia's bootstrap is missing ($missing); turn Cydia off and prepare again" }
            }
            val catalog = File(filesDir, "firmware-catalog.json")
            stage = "Loading firmware catalog"
            assets.open("firmware-catalog.json").use { input -> catalog.outputStream().use { input.copyTo(it) } }
            run(libs, listOf("create", "--catalog", catalog.path, "--id", firmwareId, "--ipsw", ipsw, "--out", out.path,
                "--helper", File(libs, "liblighttouch_oneshot.so").path, "--guest-tools", tools.path, "--cache", cache.path,
                "--language", Locale.getDefault().toLanguageTag(),
                // iOS 5 and later start at the Home screen, not Setup Assistant (ignored before 5, which has none)
                "--skip-setup") +
                (if (siblingIpsw.isNotEmpty()) listOf("--sibling-ipsw", siblingIpsw) else emptyList()) +
                // Cydia, Substrate and afc2 in the system volume, from the bootstrap the activity put in the cache
                (if (jailbreak) listOf("--jailbreak") else emptyList()) +
                // the iPod touch 2G's keybag boot (iOS 4) runs its SecureROM, which no IPSW carries
                (if (bootrom.isNotEmpty()) listOf("--bootrom", bootrom) else emptyList()))
            // create's own lease and boot logs; the device is the rest
            File(out, "work").let { writable(it); it.deleteRecursively() }
            done = total
            state = "complete"
            note("complete")
            foreground("Your device is prepared. Open Un1box to add it.")
        } catch (e: Exception) {
            if (cancelling) state = "cancelled" else { failure = e.message ?: "Firmware preparation failed"; state = "failed" }
            writable(out); out.deleteRecursively()
            if (cancelling) PreparationNote.clear(this) else note("failed")
        } finally {
            process = null
            if (awake.isHeld) awake.release()
            // Decrypted firmware is only worth keeping for another build of the same IPSW; it is large.
            cache.deleteRecursively()
        }
    }

    /**
     * `firmwarekit edit --device <folder> --action jailbreak`: Cydia, Substrate and afc2 into an existing device's
     * system volume through a stopped edit, so the device keeps its apps and data. Unlike a preparation, a failure
     * leaves the folder where it is: firmwarekit discards the edit it began, and the device stays as it was.
     */
    private fun editJailbreak(device: File) {
        val awake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Un1box:jailbreak")
        awake.acquire(60 * 60 * 1000L)
        val libs = File(applicationInfo.nativeLibraryDir)
        val cache = File(cacheDir, "firmwarekit")
        try {
            check(device.isDirectory) { "The device's folder is missing (${device.name})" }
            // The activity downloads and checks the bootstrap (CydiaBootstrap); firmwarekit reads it beside the
            // cache, as create does, and would download it only on a host with a network.
            val bootstrap = CydiaBootstrap.directory(this)
            val missing = CydiaBootstrap.files.keys.firstOrNull { !File(bootstrap, it).isFile }
            check(missing == null) { "Cydia's bootstrap is missing ($missing); download it again" }
            stage = "Editing the system volume"
            run(libs, listOf("edit", "--device", device.path, "--action", "jailbreak", "--cache", cache.path))
            done = total
            state = "complete"
            foreground("The device is jailbroken. Start it to finish installing Cydia.")
        } catch (e: Exception) {
            if (cancelling) state = "cancelled" else { failure = e.message ?: "The jailbreak failed"; state = "failed" }
        } finally {
            process = null
            if (awake.isHeld) awake.release()
        }
    }

    /**
     * Why a signal ended the child, as far as a probe can tell: the same binary, asked only for its usage, with
     * the loader's own trace on (LD_DEBUG is bionic's). A binary that cannot start dies in the probe as well,
     * and the last libraries it loaded say where; one that starts fine points at the command, not the build.
     */
    private fun startupProbe(libs: File, signal: Int): String {
        val out = File(cacheDir, "probe.log")
        return try {
            val builder = ProcessBuilder(listOf(File(libs, "libfirmwarekit.so").path, "--help"))
                .redirectErrorStream(true)
                .redirectOutput(out)
            builder.environment().apply {
                put("LTM_QEMU_DYLIB", File(libs, "libqemu-arm.so").path)
                put("LD_LIBRARY_PATH", libs.path)
                put("HOME", filesDir.path); put("TMPDIR", cacheDir.path)
                put("LD_DEBUG", "libs")
            }
            val probe = builder.start()
            if (!probe.waitFor(20, TimeUnit.SECONDS)) { probe.destroyForcibly(); probe.waitFor() }
            val tail = out.takeIf { it.isFile }?.readLines()?.filter { it.isNotBlank() }?.takeLast(3)?.joinToString(" · ")
            "a usage-only probe of the same binary ended ${probe.exitValue()}" +
                (if (tail.isNullOrBlank()) "" else ", the loader's last words: $tail")
        } catch (e: Exception) {
            "the probe could not run (${e.message})"
        }.let { "signal $signal; $it" }
    }

    /**
     * One firmwarekit command. Its stdout is a line of JSON per event (begin: each step's expected seconds; step;
     * progress: the step's fraction and what it is doing; error), turned into this worker's stage and a weighted done/total.
     */
    private fun run(libs: File, args: List<String>) {
        val builder = ProcessBuilder(listOf(File(libs, "libfirmwarekit.so").path) + args)
            .redirectError(File(cacheDir, "firmwarekit.log").apply { parentFile?.mkdirs() })
        builder.environment().apply {
            put("LTM_QEMU_DYLIB", File(libs, "libqemu-arm.so").path)
            File(libs, "libiboot32patcher.so").takeIf { it.canExecute() }?.let { put("FIRMWAREKIT_IBOOT_PATCHER", it.path) }
            put("LD_LIBRARY_PATH", libs.path)
            put("HOME", filesDir.path); put("TMPDIR", cacheDir.path)
            // A signal death (exit 139 is SIGSEGV) leaves no message of its own; the Swift runtime
            // prints a backtrace for it, into the log this worker reports from.
            put("SWIFT_BACKTRACE", "enable=yes,threads=all")
        }
        check(!cancelling) { "Cancelled" }
        stage = "Launching firmwarekit"
        val child = builder.start().also { process = it }
        var weights = listOf<Long>(); var step = 0
        var message = ""
        var stepName = ""; var stepStarted = 0L
        fun endStep() { if (stepName.isNotEmpty()) timings += "$stepName\t${(SystemClock.elapsedRealtime() - stepStarted) / 100 / 10.0}\n" }
        child.inputStream.bufferedReader().forEachLine { line ->
            val event = try { JSONObject(line) } catch (_: Exception) { return@forEachLine }
            when (event.optString("event")) {
                "begin" -> event.optJSONArray("seconds")?.let { a -> weights = (0 until a.length()).map { maxOf(1L, a.getLong(it)) * 1000 }; total = weights.sum() }
                "step" -> {
                    endStep(); stepName = event.optString("name"); stepStarted = SystemClock.elapsedRealtime()
                    step = event.optInt("index"); stage = stepName; done = weights.take(step - 1).sum()
                }
                "progress" -> {
                    if (step > 0 && step <= weights.size) done = weights.take(step - 1).sum() + (event.optDouble("fraction", 0.0) * weights[step - 1]).toLong()
                    // What the step is doing now, with its elapsed time: "Starting the Home screen — 45 s".
                    event.optString("detail").takeIf { it.isNotEmpty() }?.let { stage = it }
                }
                "error" -> message = event.optString("message")
            }
        }
        val exit = child.waitFor()
        endStep()
        check(!cancelling) { "Cancelled" }
        // firmwarekit's own words are in the log file; an exit code alone says nothing about why.
        val log = File(cacheDir, "firmwarekit.log")
        val detail = try {
            log.takeIf { it.isFile }?.readLines()?.filter { it.isNotBlank() }?.let { lines ->
                // A crash's backtrace is the useful part, and it is short: keep both ends of the log.
                (lines.take(2) + lines.takeLast(4)).distinct().joinToString(" · ")
            }
        } catch (_: Exception) { null }
        check(exit == 0) {
            val cause = message.ifEmpty { "firmwarekit ${args.first()} failed (exit $exit)" }
            cause + when {
                !detail.isNullOrBlank() -> " — $detail"
                // Nothing in the log and a signal: was it this command, or can the binary not start at all?
                exit > 128 -> " — killed by signal ${exit - 128}; ${startupProbe(libs, exit - 128)}"
                else -> ""
            }
        }
    }

    private fun note(phase: String) = PreparationNote.write(this, JSONObject().put("state", phase).put("pid", Process.myPid())
        .put("firmwareId", currentFirmwareId).put("destination", destination).put("timings", timings).put("error", failure))

    /** firmwarekit leaves its outputs read-only; delete needs the folders writable again. */
    private fun writable(root: File) { if (root.exists()) root.walkTopDown().forEach { it.setWritable(true, true) } }

    override fun onBind(intent: Intent): IBinder = binder
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        foreground(if (state == "complete") "Your device is prepared. Open Un1box to add it." else "Preparing a device; return to view progress or cancel")
        return START_NOT_STICKY
    }
    private fun foreground(text: String = "Preparing a device; return to view progress or cancel") {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("firmware", "Firmware preparation", NotificationManager.IMPORTANCE_LOW))
        val launch = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        startForeground(2, Notification.Builder(this, "firmware").setSmallIcon(android.R.drawable.ic_menu_upload)
            .setContentTitle("Un1box preparation").setContentText(text)
            .setContentIntent(launch).setOngoing(true).build())
    }
}

/**
 * The worker's own record of its run, so a Un1box that Android closed or restarted while preparation ran in the
 * background finds it again: still preparing (the worker's pid), complete (its output, waiting to be added), or
 * failed (why). The app clears it once it has shown or added the result.
 */
internal object PreparationNote {
    private fun file(context: android.content.Context) = File(context.filesDir, "prepared/current.json")
    fun write(context: android.content.Context, note: JSONObject) {
        val target = file(context).apply { parentFile?.mkdirs() }
        File(target.path + ".tmp").apply { writeText(note.toString()); renameTo(target) }
    }
    fun read(context: android.content.Context): JSONObject? = try { JSONObject(file(context).readText()) } catch (_: Exception) { null }
    fun clear(context: android.content.Context) { file(context).delete() }
}
