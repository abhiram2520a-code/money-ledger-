package com.vivekapps.ledger

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import java.io.File

/**
 * The durable handoff between [SmsReceiver] (which runs in whatever process
 * state the OS felt like, often with no Flutter engine alive) and the Dart
 * `incoming` stream.
 *
 * A manifest-registered receiver is started by the system even when the app
 * has been swiped out of recents - Android cold-starts the process just to run
 * `onReceive`. What it does NOT do is start a FlutterEngine, so there is
 * frequently nothing on the other end of the EventChannel at the moment a
 * message arrives. Writing it to disk here and draining when a sink attaches
 * is what makes "messages reach Dart even when the app is not in the
 * foreground" true rather than aspirational.
 *
 * ACCEPTED LOSS WINDOW, stated honestly: messages are emitted to the sink
 * first and removed from the spool afterwards. If the process dies between
 * those two steps the message is re-delivered (a duplicate, which the
 * `bodyHash` dedupe downstream absorbs). If it dies after the drop but before
 * Dart has committed its database transaction, that message is gone from the
 * spool - it is NOT gone from the phone, because `content://sms` still holds
 * it, and the next `backfill()` picks it up. The spool is a latency
 * optimisation; the inbox is the source of truth.
 */
internal object LiveMessageSpool {

    private const val TAG = "LedgerSpool"
    private const val MAX_LINES = 2_000
    private const val MAX_BYTES = 768L * 1024L

    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var sink: EventChannel.EventSink? = null
    private var cachedFile: File? = null

    // ---------------------------------------------------------------- sink

    /** Called on the platform thread when Dart starts listening. */
    fun attach(context: Context, newSink: EventChannel.EventSink) {
        synchronized(lock) { sink = newSink }
        drain(context)
    }

    /** Called on the platform thread when Dart stops listening. */
    fun detach() {
        synchronized(lock) { sink = null }
    }

    // ---------------------------------------------------------------- write

    /**
     * Appends one gated message. Safe to call from a receiver worker thread.
     * Never throws: a receiver that crashes silently loses real transactions.
     */
    fun append(context: Context, message: Map<String, Any?>) {
        val line = try {
            encode(message).toString()
        } catch (t: Throwable) {
            Log.w(TAG, "spool encode failed: " + t.javaClass.simpleName)
            return
        }
        synchronized(lock) {
            try {
                val file = fileLocked(context)
                file.appendText(line + "\n", Charsets.UTF_8)
                if (file.length() > MAX_BYTES) trimLocked(file)
            } catch (t: Throwable) {
                Log.w(TAG, "spool append failed: " + t.javaClass.simpleName)
                return
            }
        }
        drain(context)
    }

    /** How many gated messages are waiting for a listener. */
    fun pendingCount(context: Context): Int = synchronized(lock) {
        try {
            val file = fileLocked(context)
            if (!file.exists()) 0 else file.readLines(Charsets.UTF_8).count { it.isNotBlank() }
        } catch (t: Throwable) {
            0
        }
    }

    // ---------------------------------------------------------------- drain

    /**
     * Hands everything spooled to the current sink, oldest first. Posts to the
     * platform thread because an [EventChannel.EventSink] may only be touched
     * there.
     */
    fun drain(context: Context) {
        mainHandler.post {
            val snapshot: Pair<EventChannel.EventSink, List<String>>? = synchronized(lock) {
                val target = sink
                if (target == null) {
                    null
                } else {
                    try {
                        val file = fileLocked(context)
                        val lines = if (!file.exists()) {
                            emptyList()
                        } else {
                            file.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
                        }
                        Pair(target, lines)
                    } catch (t: Throwable) {
                        Log.w(TAG, "spool read failed: " + t.javaClass.simpleName)
                        null
                    }
                }
            }
            if (snapshot == null) return@post
            val target = snapshot.first
            val lines = snapshot.second
            if (lines.isEmpty()) return@post

            var delivered = 0
            for (line in lines) {
                val decoded = decode(line)
                if (decoded == null) {
                    // A corrupt line must not wedge the queue forever: count it
                    // as delivered so compaction drops it.
                    delivered++
                    continue
                }
                try {
                    target.success(decoded)
                    delivered++
                } catch (t: Throwable) {
                    // The engine went away mid-drain. Keep what is undelivered.
                    Log.w(TAG, "sink rejected event: " + t.javaClass.simpleName)
                    break
                }
            }
            if (delivered > 0) {
                synchronized(lock) {
                    try {
                        dropFirstLocked(fileLocked(context), delivered)
                    } catch (t: Throwable) {
                        Log.w(TAG, "spool compaction failed: " + t.javaClass.simpleName)
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------------- file

    private fun fileLocked(context: Context): File {
        val existing = cachedFile
        if (existing != null) return existing
        val dir = File(context.applicationContext.filesDir, "ledger")
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, "live_spool.jsonl")
        cachedFile = file
        return file
    }

    /** Removes the [count] oldest lines, keeping anything appended meanwhile. */
    private fun dropFirstLocked(file: File, count: Int) {
        if (!file.exists()) return
        val remaining = file.readLines(Charsets.UTF_8).filter { it.isNotBlank() }.drop(count)
        if (remaining.isEmpty()) {
            file.delete()
        } else {
            file.writeText(remaining.joinToString("\n", postfix = "\n"), Charsets.UTF_8)
        }
    }

    /**
     * Bounds the spool. Dropping the OLDEST is the right trade: the newest
     * transactions are the ones the user is looking at, and anything dropped
     * is still recoverable from `content://sms` by a backfill.
     */
    private fun trimLocked(file: File) {
        val lines = file.readLines(Charsets.UTF_8).filter { it.isNotBlank() }
        if (lines.size <= MAX_LINES) return
        val kept = lines.takeLast(MAX_LINES)
        file.writeText(kept.joinToString("\n", postfix = "\n"), Charsets.UTF_8)
        Log.w(TAG, "spool trimmed, dropped " + (lines.size - kept.size) + " oldest entries")
    }

    // ----------------------------------------------------------------- json

    private fun encode(message: Map<String, Any?>): JSONObject {
        val json = JSONObject()
        json.put("id", message["id"] as? String ?: "")
        json.put("senderRaw", message["senderRaw"] as? String ?: "")
        json.put("senderHeader", message["senderHeader"] as? String ?: "")
        json.put("body", message["body"] as? String ?: "")
        json.put("receivedAt", (message["receivedAt"] as? Number)?.toLong() ?: 0L)
        json.put("source", message["source"] as? String ?: MessageGate.SOURCE_REALTIME)
        json.put("bodyHash", message["bodyHash"] as? String ?: "")
        val slot = (message["simSlot"] as? Number)?.toInt()
        if (slot != null) json.put("simSlot", slot)
        val provider = (message["providerId"] as? Number)?.toLong()
        if (provider != null) json.put("providerId", provider)
        return json
    }

    private fun decode(line: String): Map<String, Any?>? {
        return try {
            val json = JSONObject(line)
            mapOf(
                "id" to json.optString("id"),
                "senderRaw" to json.optString("senderRaw"),
                "senderHeader" to json.optString("senderHeader"),
                "body" to json.optString("body"),
                "receivedAt" to json.optLong("receivedAt"),
                "source" to json.optString("source", MessageGate.SOURCE_REALTIME),
                "bodyHash" to json.optString("bodyHash"),
                "simSlot" to if (json.isNull("simSlot")) null else json.optInt("simSlot"),
                "providerId" to if (json.isNull("providerId")) null else json.optLong("providerId"),
            )
        } catch (t: Throwable) {
            Log.w(TAG, "spool line unreadable, discarding: " + t.javaClass.simpleName)
            null
        }
    }
}
