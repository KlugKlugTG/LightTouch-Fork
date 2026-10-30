package org.un1box.android

import android.app.*
import android.content.Intent
import android.os.*
import org.json.JSONObject
import java.io.File
import java.util.Locale
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
        override fun supports(firmwareId: String): Boolean =
            File(applicationInfo.nativeLibraryDir, "libfirmwarekit.so").canExecute() &&
                FirmwareCatalog.load(this@FirmwareService).any { it.id == firmwareId }
        override fun start(firmwareId: String, ipswPath: String, trustedToolsRoot: String, bootromPath: String, jailbreak: Boolean): Bundle {
            check(consumed.compareAndSet(false, true)) { "A fresh firmware worker is required" }
            foreground()
            currentFirmwareId = firmwareId
            state = "preparing"; stage = "Starting"
            val parent = File(filesDir, "prepared").apply { mkdirs() }
            val job = java.lang.Long.toHexString(SystemClock.uptimeMillis())
            destination = File(parent, "job-$job").absolutePath
            note("preparing")
            Thread({ prepare(firmwareId, ipswPath, File(trustedToolsRoot), bootromPath, jailbreak) }, "firmwarekit").start()
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
        override fun cancel() { cancelling = true; process?.destroy() }
        override fun finish() {
            check(state != "preparing") { "Cancel preparation and wait for a terminal result before closing the worker" }
            Handler(mainLooper).postDelayed({ stopForeground(STOP_FOREGROUND_REMOVE); stopSelf(); Process.killProcess(Process.myPid()) }, 200)
        }
    }

    /**
     * create into `destination`, the device folder the engine worker then moves into its library as it is
     * (adoptPrepared: no pack-base, no copy, no second hash). The IPSW is only read.
     */
    private fun prepare(firmwareId: String, ipsw: String, tools: File, bootrom: String, jailbreak: Boolean) {
        // Preparation boots iOS (the keybag, the first start) against timeouts: the CPU stays awake while the phone
        // locks or the user switches away. The foreground service only keeps the process alive, not the CPU running.
        val awake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Un1box:preparation")
        awake.acquire(60 * 60 * 1000L)
        val libs = File(applicationInfo.nativeLibraryDir)
        val cache = File(cacheDir, "firmwarekit")
        val out = File(destination)
        try {
            val catalog = File(filesDir, "firmware-catalog.json")
            assets.open("firmware-catalog.json").use { input -> catalog.outputStream().use { input.copyTo(it) } }
            run(libs, listOf("create", "--catalog", catalog.path, "--id", firmwareId, "--ipsw", ipsw, "--out", out.path,
                "--helper", File(libs, "liblighttouch_oneshot.so").path, "--guest-tools", tools.path, "--cache", cache.path,
                "--language", Locale.getDefault().toLanguageTag(),
                // iOS 5 and later start at the Home screen, not Setup Assistant (ignored before 5, which has none)
                "--skip-setup") +
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
     * One firmwarekit command. Its stdout is a line of JSON per event (begin: each step's expected seconds; step;
     * progress: the step's fraction and what it is doing; error), turned into this worker's stage and a weighted done/total.
     */
    private fun run(libs: File, args: List<String>) {
        val builder = ProcessBuilder(listOf(File(libs, "libfirmwarekit.so").path) + args)
            .redirectError(File(cacheDir, "firmwarekit.log").apply { parentFile?.mkdirs() })
        builder.environment().apply {
            put("LTM_QEMU_DYLIB", File(libs, "libqemu-arm.so").path)
            put("LD_LIBRARY_PATH", libs.path)
            put("HOME", filesDir.path); put("TMPDIR", cacheDir.path)
        }
        check(!cancelling) { "Cancelled" }
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
        check(exit == 0) { message.ifEmpty { "firmwarekit ${args.first()} failed (exit $exit)" } }
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
