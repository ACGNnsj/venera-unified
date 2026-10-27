package com.github.cyrilpeng.veneranext

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Generic background-task keep-alive: while follow-up checks, imports, syncs
 * or source updates run, pins the process at foreground priority so the OS
 * neither freezes it when the screen turns off nor when the app goes to the
 * background and suspends the Flutter task loops.
 *
 * Like [DownloadService] it touches no business logic — tasks run entirely on
 * the Dart side; this service only shows one non-dismissible progress
 * notification per running task kind and holds a CPU wake lock. Dart (the
 * [venera/background_keepalive] channel) reports status while a kind is alive
 * and removes it when idle.
 *
 * Independent from the download service on purpose: downloads keep their
 * single-tag service untouched with zero regression, and two foreground
 * services can coexist on Android.
 */
class BackgroundKeepAliveService : Service() {

    private var cpuLock: PowerManager.WakeLock? = null

    // tag -> notification body. LinkedHashMap keeps insertion order so the
    // choice of the foreground-carrying notification stays stable.
    private val statuses = LinkedHashMap<String, String>()

    // Tag currently carried by startForeground. Replaced by a surviving
    // notification when it is removed.
    private var foregroundTag: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val tag = intent?.getStringExtra(KEY_TAG)
        if (tag != null) {
            val stopTag = intent.getBooleanExtra(KEY_STOP, false)
            if (stopTag) {
                statuses.remove(tag)
                // Notifications that are not the foreground carrier are neither
                // owned by startForeground nor in the surviving set of
                // refreshNotifications — leaving them here would strand an
                // ongoing card in the shade with no task behind it. The carrier
                // is revoked when swapped, or removed with stopForeground when
                // the last task ends.
                if (tag != foregroundTag) {
                    NotificationManagerCompat.from(this).cancel(notificationId(tag))
                }
            } else {
                statuses[tag] = intent.getStringExtra(KEY_STATUS).orEmpty()
            }
        }
        if (statuses.isEmpty()) {
            // Nothing running; stand down, removing the foreground notice.
            // A cold-start teardown (a remove delivered after the task ended)
            // must still call startForeground once to satisfy the
            // startForegroundService contract, or the system throws
            // ForegroundServiceDidNotStartInTimeException. stopForeground
            // removes that placeholder notice immediately after.
            if (foregroundTag == null) {
                ensureChannelRegistered()
                startForegroundCompat(BASE_NOTE_ID, composeNotification("", ""))
            }
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        refreshNotifications()
        keepCpuAwake()
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The main isolate is gone with the swiped-away app; nothing left to protect.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        cpuLock?.takeIf { it.isHeld }?.release()
        cpuLock = null
        // Clear this service's accessory notifications on exit (the foreground
        // one is handled by stopForeground).
        val manager = NotificationManagerCompat.from(this)
        for (tag in statuses.keys) {
            if (tag != foregroundTag) manager.cancel(notificationId(tag))
        }
        super.onDestroy()
    }

    private fun refreshNotifications() {
        ensureChannelRegistered()
        // Pick a foreground carrier: keep the current one when it is still
        // alive to avoid startForeground churn.
        val nextForeground = foregroundTag?.takeIf { statuses.containsKey(it) }
            ?: statuses.keys.first()

        startForegroundCompat(
            notificationId(nextForeground),
            composeNotification(nextForeground, statuses[nextForeground].orEmpty()),
        )

        val manager = NotificationManagerCompat.from(this)
        // A demoted previous carrier becomes an accessory notification when
        // still alive, or is revoked when already removed.
        foregroundTag?.let { prev ->
            if (prev != nextForeground) {
                if (statuses.containsKey(prev)) {
                    manager.notify(
                        notificationId(prev),
                        composeNotification(prev, statuses[prev].orEmpty()),
                    )
                } else {
                    manager.cancel(notificationId(prev))
                }
            }
        }
        foregroundTag = nextForeground

        // Refresh every other surviving tag's independent notification.
        for ((tag, status) in statuses) {
            if (tag == nextForeground) continue
            manager.notify(notificationId(tag), composeNotification(tag, status))
        }
    }

    /** Via ServiceCompat for systems below API 29 without the typed startForeground overload. */
    private fun startForegroundCompat(noteId: Int, notification: Notification) {
        val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, noteId, notification, serviceType)
    }

    private fun stopForegroundCompat() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        foregroundTag = null
    }

    private fun composeNotification(tag: String, status: String): Notification {
        val resume = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val openApp = PendingIntent.getActivity(
            this, notificationId(tag), resume,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val body = status.ifBlank { getString(R.string.background_notification_default) }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(titleFor(tag))
            .setContentText(body)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .build()
    }

    private fun titleFor(tag: String): String {
        val resId = when (tag) {
            TAG_FOLLOW_UPDATE -> R.string.background_title_follow_update
            TAG_IMPORT -> R.string.background_title_import
            TAG_SYNC -> R.string.background_title_sync
            TAG_SOURCE_UPDATE -> R.string.background_title_source_update
            else -> R.string.background_notification_default
        }
        return getString(resId)
    }

    private fun ensureChannelRegistered() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        // Recreating an existing channel is a no-op, but refreshes the
        // localized channel name after upgrades.
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.background_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.background_channel_desc)
                setShowBadge(false)
            }
        )
    }

    private fun keepCpuAwake() {
        if (cpuLock?.isHeld == true) return
        val power = getSystemService(POWER_SERVICE) as PowerManager
        cpuLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    companion object {
        private const val CHANNEL_ID = "background.tasks"
        private const val KEY_TAG = "tag"
        private const val KEY_STATUS = "status"
        private const val KEY_STOP = "stop"
        private const val WAKE_TAG = "venera:bg-keepalive"

        // Each tag owns a fixed notification slot so one task kind always
        // reuses its own notice. DownloadService uses id 107; no overlap.
        private const val BASE_NOTE_ID = 1200

        const val TAG_FOLLOW_UPDATE = "follow_update"
        const val TAG_IMPORT = "import"
        const val TAG_SYNC = "sync"
        const val TAG_SOURCE_UPDATE = "source_update"

        private fun notificationId(tag: String): Int = when (tag) {
            TAG_FOLLOW_UPDATE -> BASE_NOTE_ID + 1
            TAG_IMPORT -> BASE_NOTE_ID + 2
            TAG_SYNC -> BASE_NOTE_ID + 3
            TAG_SOURCE_UPDATE -> BASE_NOTE_ID + 4
            else -> BASE_NOTE_ID + (tag.hashCode() and 0x3F) + 5
        }

        /** Reports a task kind's latest status, or refreshes it while running. Idempotent. */
        fun update(context: Context, tag: String, status: String) {
            val intent = Intent(context, BackgroundKeepAliveService::class.java)
                .putExtra(KEY_TAG, tag)
                .putExtra(KEY_STATUS, status)
            ContextCompat.startForegroundService(context, intent)
        }

        /** Removes a task kind; the service stops itself with the last one. Safe unstarted. */
        fun remove(context: Context, tag: String) {
            val intent = Intent(context, BackgroundKeepAliveService::class.java)
                .putExtra(KEY_TAG, tag)
                .putExtra(KEY_STOP, true)
            ContextCompat.startForegroundService(context, intent)
        }
    }
}
