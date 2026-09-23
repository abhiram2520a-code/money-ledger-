package com.vivekapps.ledger

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The bridge between the Android ingestion layer and
 * `lib/native/message_source.dart`.
 *
 * Three channels, and nothing else crosses this boundary:
 *
 *  * `com.vivekapps.ledger/methods`  - permissions, live on/off, paged
 *                                      backfill, import service control
 *  * `com.vivekapps.ledger/live`     - gated messages as they arrive, plus
 *                                      everything [LiveMessageSpool] buffered
 *                                      while Dart was not listening
 *  * `com.vivekapps.ledger/backfill` - progress and pages from
 *                                      [BackfillService]
 *
 * NO NETWORK CODE EXISTS IN THIS MODULE. Grep it: there is no HTTP client, no
 * socket, no URL. Everything here reads the device and hands the result to the
 * local database. That is what makes the app work with the config server
 * permanently unreachable.
 */
class LedgerPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private var methodChannel: MethodChannel? = null
    private var liveChannel: EventChannel? = null
    private var backfillChannel: EventChannel? = null

    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var pendingPermissionResult: MethodChannel.Result? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var worker: ExecutorService? = null

    /** Cancels an in-flight [backfillPage] when Dart calls `cancelBackfill`. */
    @Volatile
    private var pageSignal: CancellationSignal? = null

    // ------------------------------------------------------------- lifecycle

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val appContext = binding.applicationContext
        context = appContext
        worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "ledger-plugin-io").apply { isDaemon = true }
        }

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }

        liveChannel = EventChannel(binding.binaryMessenger, LIVE_CHANNEL).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events == null) return
                    LiveMessageSpool.attach(appContext, events)
                }

                override fun onCancel(arguments: Any?) {
                    LiveMessageSpool.detach()
                }
            })
        }

        backfillChannel = EventChannel(binding.binaryMessenger, BACKFILL_CHANNEL).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events == null) return
                    BackfillBridge.attach(events)
                }

                override fun onCancel(arguments: Any?) {
                    BackfillBridge.detach()
                }
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        liveChannel?.setStreamHandler(null)
        backfillChannel?.setStreamHandler(null)
        methodChannel = null
        liveChannel = null
        backfillChannel = null
        LiveMessageSpool.detach()
        BackfillBridge.detach()
        pageSignal?.cancel()
        pageSignal = null
        worker?.shutdownNow()
        worker = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    /**
     * A rotation behind the permission dialog is NOT a lost request: the
     * dialog survives and the new Activity will deliver the result. Only the
     * listener is detached here; the pending reply is deliberately left alone.
     */
    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        // A permission dialog whose Activity is really gone can never answer,
        // and a MethodChannel.Result that is never called leaks the Dart
        // future forever. Answering "unknown" makes the caller re-query.
        pendingPermissionResult?.let { reply(it, PermissionWire.UNKNOWN) }
        pendingPermissionResult = null
    }

    /** Replies without letting a torn-down engine turn into a crash. */
    private fun reply(result: MethodChannel.Result, value: Any?) {
        try {
            result.success(value)
        } catch (t: Throwable) {
            Log.w(TAG, "reply dropped, engine gone: " + t.javaClass.simpleName)
        }
    }

    // ---------------------------------------------------------------- methods

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val appContext = context
        if (appContext == null) {
            result.error("state_error", "Plugin is not attached to an engine", null)
            return
        }

        when (call.method) {
            "isSupported" -> result.success(true)

            "hasPermissions" -> result.success(permissionState(appContext))

            "requestPermissions" -> requestPermissions(appContext, result)

            "openAppSettings" -> result.success(openAppSettings(appContext))

            "startLive" -> {
                if (!hasAll(appContext, LIVE_PERMISSIONS)) {
                    result.error("permission_denied", "RECEIVE_SMS is not granted", null)
                    return
                }
                setReceiverEnabled(appContext, true)
                LiveMessageSpool.drain(appContext)
                result.success(true)
            }

            "stopLive" -> {
                setReceiverEnabled(appContext, false)
                result.success(true)
            }

            "isLiveEnabled" -> result.success(isReceiverEnabled(appContext))

            "pendingLiveCount" -> result.success(LiveMessageSpool.pendingCount(appContext))

            "drainLive" -> {
                LiveMessageSpool.drain(appContext)
                result.success(true)
            }

            "backfillPage" -> backfillPage(appContext, call, result)

            "startBackfill" -> {
                if (!hasAll(appContext, READ_PERMISSIONS)) {
                    result.error("permission_denied", "READ_SMS is not granted", null)
                    return
                }
                val started = BackfillService.start(
                    appContext,
                    call.argument<Number>("since")?.toLong(),
                    call.argument<Number>("until")?.toLong(),
                    call.argument<Number>("pageSize")?.toInt(),
                )
                result.success(started)
            }

            "cancelBackfill" -> {
                pageSignal?.cancel()
                result.success(BackfillService.cancel(appContext))
            }

            "isBackfillRunning" -> result.success(BackfillService.isRunning())

            else -> result.notImplemented()
        }
    }

    /**
     * Reads one page of the inbox off the platform thread.
     *
     * Every byte of this work happens on [worker]; a 500-row cursor window on
     * the main thread is precisely how an inbox import ANRs.
     */
    private fun backfillPage(appContext: Context, call: MethodCall, result: MethodChannel.Result) {
        if (!hasAll(appContext, READ_PERMISSIONS)) {
            result.error("permission_denied", "READ_SMS is not granted", null)
            return
        }
        val executor = worker
        if (executor == null) {
            result.error("state_error", "Plugin is shutting down", null)
            return
        }

        val since = call.argument<Number>("since")?.toLong()
        val until = call.argument<Number>("until")?.toLong()
        val limit = call.argument<Number>("limit")?.toInt() ?: 200
        val pageToken = call.argument<String>("pageToken")

        val signal = CancellationSignal()
        pageSignal = signal

        executor.execute {
            val response = try {
                val page = SmsBackfill(appContext).readPage(since, until, limit, pageToken, signal)
                mapOf(
                    "messages" to page.messages,
                    "nextPageToken" to page.nextPageToken,
                    "scannedCount" to page.scannedCount,
                )
            } catch (t: Throwable) {
                Log.w(TAG, "backfill page failed: " + t.javaClass.simpleName)
                null
            }

            mainHandler.post {
                if (pageSignal === signal) pageSignal = null
                try {
                    when {
                        signal.isCanceled ->
                            result.error("cancelled", "Backfill was cancelled", null)
                        response == null ->
                            result.error("io", "The SMS provider could not be read", null)
                        else -> result.success(response)
                    }
                } catch (t: Throwable) {
                    // The engine detached while the cursor was being read.
                    Log.w(TAG, "page reply dropped: " + t.javaClass.simpleName)
                }
            }
        }
    }

    // ------------------------------------------------------------ permissions

    private fun requestPermissions(appContext: Context, result: MethodChannel.Result) {
        if (hasAll(appContext, ALL_PERMISSIONS)) {
            result.success(PermissionWire.GRANTED)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            // Install-time permissions: whatever the manifest asked for is what
            // the app already has.
            result.success(PermissionWire.GRANTED)
            return
        }
        val host = activity
        if (host == null) {
            result.error("state_error", "No Activity to show the permission prompt", null)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("conflict", "A permission prompt is already showing", null)
            return
        }

        pendingPermissionResult = result
        prefs(appContext).edit().putBoolean(KEY_ASKED, true).apply()
        try {
            host.requestPermissions(requestedPermissions(), PERMISSION_REQUEST_CODE)
        } catch (t: Throwable) {
            pendingPermissionResult = null
            result.error("state_error", "Could not show the permission prompt", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        val appContext = context
        if (appContext == null) {
            reply(pending, PermissionWire.UNKNOWN)
            return true
        }
        val state = permissionState(appContext)
        // The receiver is only useful once RECEIVE_SMS exists, and enabling it
        // here means the user never has to find a second switch.
        if (state == PermissionWire.GRANTED) {
            setReceiverEnabled(appContext, true)
            LiveMessageSpool.drain(appContext)
        }
        reply(pending, state)
        return true
    }

    /**
     * The wire form of `PermissionState`.
     *
     * "Permanently denied" is not something Android reports directly: the only
     * signal is `shouldShowRequestPermissionRationale` returning false, which
     * is ALSO what a never-asked permission looks like. The stored
     * [KEY_ASKED] flag is what separates the two, and it is the standard way
     * to do this - there is no API.
     */
    private fun permissionState(appContext: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return PermissionWire.GRANTED
        if (hasAll(appContext, ALL_PERMISSIONS)) return PermissionWire.GRANTED

        val host = activity ?: return PermissionWire.DENIED
        val asked = prefs(appContext).getBoolean(KEY_ASKED, false)
        if (!asked) return PermissionWire.DENIED

        val rationale = ALL_PERMISSIONS.any { host.shouldShowRequestPermissionRationale(it) }
        return if (rationale) PermissionWire.DENIED else PermissionWire.PERMANENTLY_DENIED
    }

    private fun requestedPermissions(): Array<String> {
        val wanted = ArrayList<String>(ALL_PERMISSIONS.size + 1)
        wanted.addAll(ALL_PERMISSIONS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Asked alongside SMS so the import service can show its progress.
            // Its absence never blocks ingestion.
            wanted.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        return wanted.toTypedArray()
    }

    private fun hasAll(appContext: Context, permissions: Array<String>): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return permissions.all {
            appContext.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun openAppSettings(appContext: Context): Boolean = try {
        val intent = android.content.Intent(
            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            android.net.Uri.fromParts("package", appContext.packageName, null),
        ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        (activity ?: appContext).startActivity(intent)
        true
    } catch (t: Throwable) {
        Log.w(TAG, "could not open app settings: " + t.javaClass.simpleName)
        false
    }

    // -------------------------------------------------------------- receiver

    /**
     * `stop()` has to actually stop. The receiver is declared in the manifest,
     * so the only way to silence it is to disable the component - which also
     * means the setting survives reboots and process death, exactly like the
     * user's "pause SMS reading" switch should.
     *
     * Note that `dispose()` on the Dart side deliberately does NOT call this:
     * disposing a page must not switch off ingestion forever.
     */
    private fun setReceiverEnabled(appContext: Context, enabled: Boolean) {
        try {
            val component = ComponentName(appContext, SmsReceiver::class.java)
            val state = if (enabled) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            } else {
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            }
            appContext.packageManager.setComponentEnabledSetting(
                component,
                state,
                PackageManager.DONT_KILL_APP,
            )
        } catch (t: Throwable) {
            Log.w(TAG, "could not toggle receiver: " + t.javaClass.simpleName)
        }
    }

    private fun isReceiverEnabled(appContext: Context): Boolean = try {
        val component = ComponentName(appContext, SmsReceiver::class.java)
        when (appContext.packageManager.getComponentEnabledSetting(component)) {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED -> false
            else -> true
        }
    } catch (t: Throwable) {
        true
    }

    private fun prefs(appContext: Context): SharedPreferences =
        appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Wire values, identical to `PermissionState.wire` in `enums.dart`. */
    private object PermissionWire {
        const val GRANTED = "granted"
        const val DENIED = "denied"
        const val PERMANENTLY_DENIED = "permanently_denied"
        const val UNKNOWN = "unknown"
    }

    companion object {
        private const val TAG = "LedgerPlugin"

        const val METHOD_CHANNEL = "com.vivekapps.ledger/methods"
        const val LIVE_CHANNEL = "com.vivekapps.ledger/live"
        const val BACKFILL_CHANNEL = "com.vivekapps.ledger/backfill"

        private const val PERMISSION_REQUEST_CODE = 0x1ED6

        private const val PREFS = "ledger_native"
        private const val KEY_ASKED = "sms_permission_asked"

        private val LIVE_PERMISSIONS = arrayOf(Manifest.permission.RECEIVE_SMS)
        private val READ_PERMISSIONS = arrayOf(Manifest.permission.READ_SMS)
        private val ALL_PERMISSIONS = arrayOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
        )
    }
}
