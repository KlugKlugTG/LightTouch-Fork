package org.un1box.android

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the app's own process running while it downloads or copies an IPSW, or works through the Legacy Store's
 * install queue. Without a foreground service Android freezes a backgrounded app within seconds, and the transfer
 * fails. Held for each transfer or queue, gone after.
 */
class DownloadService : Service() {
    private var awake: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        // A transfer can finish between startForegroundService() and onStartCommand() (for example when Cydia's
        // bootstrap is already cached). Android still requires every requested foreground service to promote
        // itself, even if stopService() won that race, so do it at the service's earliest lifecycle callback.
        startForeground(3, notification(this, "Starting transfer", null))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(3, notification(this, intent?.getStringExtra("text") ?: "Downloading iOS", null))
        if (intent?.action == stopAction) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // The screen may turn off during a long download.
        if (awake == null) awake = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Un1box:download").apply { acquire(3 * 60 * 60 * 1000L) }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()
    override fun onDestroy() { awake?.let { if (it.isHeld) it.release() }; awake = null; super.onDestroy() }
    override fun onBind(intent: Intent): IBinder? = null

    companion object {
        private const val stopAction = "org.un1box.android.STOP_DOWNLOAD_SERVICE"
        private var holders = 0

        private fun manager(context: Context): NotificationManager = context.getSystemService(NotificationManager::class.java).also {
            it.createNotificationChannel(NotificationChannel("download", "Downloads", NotificationManager.IMPORTANCE_LOW))
            it.createNotificationChannel(NotificationChannel("installed", "Finished installs", NotificationManager.IMPORTANCE_DEFAULT))
        }
        private fun launch(context: Context) = PendingIntent.getActivity(context, 3, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)

        /** The ongoing notification; [fraction] fills its bar, and null leaves the bar out. */
        private fun notification(context: Context, text: String, fraction: Float?): Notification {
            manager(context)
            return Notification.Builder(context, "download").setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("Un1box").setContentText(text).setContentIntent(launch(context)).setOngoing(true)
                .apply { if (fraction != null) setProgress(100, (fraction.coerceIn(0f, 1f) * 100).toInt(), false) }.build()
        }

        /** Call from the foreground (Android refuses to start a foreground service from the background). */
        fun hold(context: Context, text: String) = synchronized(this) {
            holders++
            // A refused start leaves the work running without the service's protection.
            runCatching { context.startForegroundService(Intent(context, DownloadService::class.java).putExtra("text", text)) }
            Unit
        }

        fun release(context: Context) = synchronized(this) {
            if (holders > 0 && --holders == 0) {
                // stopService() can cancel a start before onCreate(), but Android keeps that start's foreground
                // deadline and later kills the app. Queue the stop behind the start instead: the service first
                // promotes itself, then consumes this command and stops cleanly.
                runCatching {
                    context.startForegroundService(
                        Intent(context, DownloadService::class.java).setAction(stopAction)
                    )
                }
            }
        }

        /** New text and progress for the service's notification, while something holds it. */
        fun update(context: Context, text: String, fraction: Float?) = synchronized(this) {
            if (holders > 0) manager(context).notify(3, notification(context, text, fraction))
        }

        /** A notification that stays after the service is gone: how a queue of installs ended. */
        fun finished(context: Context, text: String) {
            manager(context).notify(4, Notification.Builder(context, "installed").setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("Un1box").setContentText(text).setContentIntent(launch(context)).setAutoCancel(true).build())
        }
    }
}
