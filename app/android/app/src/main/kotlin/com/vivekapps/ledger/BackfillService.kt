package com.vivekapps.ledger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Carries the progress and the pages of a running backfill to Dart.
 *
 * Deliberately NOT durable, unlike [LiveMessageSpool]: a full import of a
 * 20,000-message inbox is tens of megabytes of message text, and spooling that
 * to disk to survive a process death would both double the storage and leave a
 * plaintext copy of the inbox lying around. Instead every progress event
 * carries `nextPageToken`, so the Dart side persists a resume point as it goes
 * and an interrupted import restarts from where it stopped rather than from
 * the beginning.
 */
internal object BackfillBridge {

    private const val TAG = "LedgerBackfillBridge"

    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    fun attach(newSink: EventChannel.EventSink) {
        synchronized(lock) { sink = newSink }
    }

    fun detach() {
        synchronized(lock) { sink = null }
    }

    fun hasSink(): Boolean = synchronized(lock) { sink != null }

    /** Returns false when nothing is listening. */
    fun emit(event: Map<String, Any?>): Boolean {
        val target = synchronized(lock) { sink } ?: return false
        mainHandler.post {
            try {
                target.success(event)
            } catch (t: Throwable) {
                Log.w(TAG, "progress sink rejected event: " + t.javaClass.simpleName)
            }
        }
        return true
    }
}

/**
 * Runs a whole-inbox backfill inside a foreground service.
 *
 * WHY A SERVICE AT ALL. [LedgerPlugin.backfillPage] already reads the inbox on
 * a worker thread, and for an import the user sits and watches that is enough.
 * It stops being enough the moment they switch apps: from Android 8 a
 * backgrounded process is a candidate for being killed within seconds, and the
 * import would die halfway with no notification and no explanation. A
 * foreground service is the only supported way to say "this work is on the
 * user's behalf, keep the process alive, and show them what it is doing".
 *
 * FOREGROUND SERVICE TYPE. `dataSync` is the honest classification: this is a
 * bounded, user-initiated transfer of data into local storage. From Android 14
 * the type is mandatory and must be backed by FOREGROUND_SERVICE_DATA_SYNC in
 * the manifest; from Android 15 `dataSync` services are capped at roughly 6
 * hours per 24, which a scan measured in seconds never approaches. `shortService`
 * was rejected: its 3-minute ceiling is genuinely too short for a 30,000-row
 * inbox on a slow eMMC device, and exceeding it is an immediate crash.
 *
 * ANDROID 12+ START RESTRICTION. A foreground service cannot be started while
 * the app is in the background. This service is therefore only ever started
 * from a user action in the running app ("Import history"), which is exactly
 * the case the platform permits. [start] still catches the refusal rather than
 * crashing, because a race between the tap and the app being backgrounded is
 * real.
 */
class BackfillService : Service() {

    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "ledger-backfill").apply { isDaemon = true }
    }
    @Volatile
    private var signal: CancellationSignal? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            requestCancel()
            return START_NOT_STICKY
        }

        if (!running.compareAndSet(false, true)) {
            // Already scanning; a second tap must not start a second scan.
            return START_NOT_STICKY
        }

        val started = enterForeground()
        if (!started) {
            running.set(false)
            BackfillBridge.emit(
                mapOf(
                    "event" to EVENT_ERROR,
                    "code" to "foreground_service_denied",
                    "message" to "Android refused to start the import service",
                ),
            )
            stopSelf()
            return START_NOT_STICKY
        }

        val since = intent?.takeIf { it.hasExtra(EXTRA_SINCE) }?.getLongExtra(EXTRA_SINCE, 0L)
        val until = intent?.takeIf { it.hasExtra(EXTRA_UNTIL) }?.getLongExtra(EXTRA_UNTIL, 0L)
        val pageSize = intent?.getIntExtra(EXTRA_PAGE_SIZE, DEFAULT_PAGE_SIZE) ?: DEFAULT_PAGE_SIZE

        cancelRequested = false
        val cancellation = CancellationSignal()
        signal = cancellation

        worker.execute { runScan(since, until, pageSize, cancellation) }

        // START_NOT_STICKY: if the OS kills the process mid-import, do NOT
        // silently restart the scan with no UI attached. The Dart side resumes
        // from its persisted page token when the user next opens the app.
        return START_NOT_STICKY
    }

    private fun runScan(since: Long?, until: Long?, pageSize: Int, cancellation: CancellationSignal) {
        try {
            if (!hasReadPermission()) {
                BackfillBridge.emit(
                    mapOf(
                        "event" to EVENT_ERROR,
                        "code" to "permission_denied",
                        "message" to "READ_SMS is not granted",
                    ),
                )
                return
            }

            val backfill = SmsBackfill(this)
            val total = backfill.estimateTotal(since, until)
            BackfillBridge.emit(
                mapOf("event" to EVENT_STARTED, "total" to total),
            )

            var aborted = false
            backfill.scanAll(since, until, pageSize, cancellation) { page, scanned, kept ->
                if (cancelRequested) return@scanAll false
                if (!awaitSink(cancellation)) {
                    aborted = true
                    return@scanAll false
                }
                updateNotification(scanned, total)
                BackfillBridge.emit(
                    mapOf(
                        "event" to EVENT_PAGE,
                        "messages" to page.messages,
                        "nextPageToken" to page.nextPageToken,
                        "scanned" to scanned,
                        "kept" to kept,
                        "total" to total,
                    ),
                )
                true
            }

            val finalEvent = when {
                cancelRequested -> EVENT_CANCELLED
                aborted -> EVENT_DETACHED
                else -> EVENT_COMPLETED
            }
            BackfillBridge.emit(mapOf("event" to finalEvent))
        } catch (t: Throwable) {
            Log.w(TAG, "backfill failed: " + t.javaClass.simpleName)
            BackfillBridge.emit(
                mapOf(
                    "event" to EVENT_ERROR,
                    "code" to "io",
                    "message" to t.javaClass.simpleName,
                ),
            )
        } finally {
            running.set(false)
            signal = null
            leaveForeground()
            stopSelf()
        }
    }

    /**
     * Blocks the worker (never the main thread) while the Dart side is
     * detached - the user backgrounded the app and Flutter tore the engine's
     * listener down, or the import screen was popped. Giving up after
     * [SINK_WAIT_MS] stops a headless service from scanning an inbox nobody is
     * waiting for.
     */
    private fun awaitSink(cancellation: CancellationSignal): Boolean {
        if (BackfillBridge.hasSink()) return true
        var waited = 0L
        while (waited < SINK_WAIT_MS) {
            if (cancelRequested || cancellation.isCanceled) return false
            try {
                Thread.sleep(SINK_POLL_MS)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
            waited += SINK_POLL_MS
            if (BackfillBridge.hasSink()) return true
        }
        Log.w(TAG, "no listener for " + SINK_WAIT_MS + "ms, stopping import")
        return false
    }

    private fun requestCancel() {
        cancelRequested = true
        try {
            signal?.cancel()
        } catch (t: Throwable) {
            Log.w(TAG, "cancel failed: " + t.javaClass.simpleName)
        }
    }

    private fun hasReadPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(android.Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED
    }

    // ------------------------------------------------------------ foreground

    private fun enterForeground(): Boolean = try {
        ensureChannel(this)
        val notification = buildNotification(0, null)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        true
    } catch (t: Throwable) {
        // API 31+ throws ForegroundServiceStartNotAllowedException when the app
        // slipped into the background between the tap and this call, and API 34
        // throws SecurityException when the type permission is missing.
        Log.w(TAG, "startForeground refused: " + t.javaClass.simpleName)
        false
    }

    private fun leaveForeground() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "stopForeground failed: " + t.javaClass.simpleName)
        }
    }

    private fun updateNotification(scanned: Int, total: Int?) {
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return
            manager.notify(NOTIFICATION_ID, buildNotification(scanned, total))
        } catch (t: Throwable) {
            Log.w(TAG, "notification update failed: " + t.javaClass.simpleName)
        }
    }

    private fun buildNotification(scanned: Int, total: Int?): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val text = when {
            total != null && total > 0 -> "Read " + scanned + " of " + total + " messages"
            scanned > 0 -> "Read " + scanned + " messages"
            else -> "Starting"
        }

        builder
            .setContentTitle("Importing your transaction history")
            .setContentText(text)
            // A framework drawable, so the service does not depend on a
            // res/drawable this module would otherwise have to ship.
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)

        if (total != null && total > 0) {
            builder.setProgress(total, scanned.coerceAtMost(total), false)
        } else {
            builder.setProgress(0, 0, true)
        }

        contentIntent()?.let { builder.setContentIntent(it) }
        return builder.build()
    }

    private fun contentIntent(): PendingIntent? = try {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch == null) {
            null
        } else {
            launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            PendingIntent.getActivity(this, 0, launch, flags)
        }
    } catch (t: Throwable) {
        null
    }

    companion object {
        private const val TAG = "LedgerBackfillService"

        private const val CHANNEL_ID = "ledger_backfill"
        private const val NOTIFICATION_ID = 4711

        const val ACTION_START = "com.vivekapps.ledger.action.START_BACKFILL"
        const val ACTION_CANCEL = "com.vivekapps.ledger.action.CANCEL_BACKFILL"

        const val EXTRA_SINCE = "since"
        const val EXTRA_UNTIL = "until"
        const val EXTRA_PAGE_SIZE = "pageSize"

        const val EVENT_STARTED = "started"
        const val EVENT_PAGE = "page"
        const val EVENT_COMPLETED = "completed"
        const val EVENT_CANCELLED = "cancelled"
        const val EVENT_DETACHED = "detached"
        const val EVENT_ERROR = "error"

        private const val DEFAULT_PAGE_SIZE = 200
        private const val SINK_WAIT_MS = 30_000L
        private const val SINK_POLL_MS = 250L

        val running = AtomicBoolean(false)

        @Volatile
        private var cancelRequested = false

        fun isRunning(): Boolean = running.get()

        /**
         * Starts the import. Returns false when the platform refused, which on
         * Android 12+ means the app was not in the foreground.
         */
        fun start(context: Context, since: Long?, until: Long?, pageSize: Int?): Boolean {
            val intent = Intent(context, BackfillService::class.java).apply {
                action = ACTION_START
                if (since != null) putExtra(EXTRA_SINCE, since)
                if (until != null) putExtra(EXTRA_UNTIL, until)
                if (pageSize != null) putExtra(EXTRA_PAGE_SIZE, pageSize)
            }
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (t: Throwable) {
                Log.w(TAG, "could not start import service: " + t.javaClass.simpleName)
                false
            }
        }

        fun cancel(context: Context): Boolean {
            cancelRequested = true
            if (!running.get()) return false
            return try {
                context.startService(
                    Intent(context, BackfillService::class.java).setAction(ACTION_CANCEL),
                )
                true
            } catch (t: Throwable) {
                Log.w(TAG, "could not deliver cancel: " + t.javaClass.simpleName)
                // The volatile flag above still stops the scan at the next page.
                true
            }
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "History import",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while past bank messages are read into the ledger."
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }
}
