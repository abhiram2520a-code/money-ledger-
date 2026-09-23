package com.vivekapps.ledger

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteException
import android.os.CancellationSignal
import android.provider.Telephony
import android.util.Log

/**
 * Historical ingestion: reads `content://sms/inbox` so the ledger has the
 * user's last N months of spending on the day they install, instead of only
 * what happens to arrive afterwards.
 *
 * WHY IT IS BUILT THE WAY IT IS. A real Indian inbox is 10,000-30,000
 * messages. Three things follow, and each one is a decision in this file:
 *
 *  * NEVER hold the whole inbox. Rows are consumed in [WINDOW_ROWS]-row
 *    cursor windows and only the messages that pass the sender gate are kept,
 *    bounded by the caller's `limit`. A 20,000-message inbox costs the same
 *    peak memory as a 200-message one.
 *  * NEVER use OFFSET. `LIMIT ? OFFSET ?` makes SQLite re-walk the whole
 *    prefix for every page, turning a full backfill into O(n squared) - the
 *    classic way this feature ANRs at message 8,000. Paging here is keyset
 *    ("seek") pagination on `(date, _id)`, which is O(page) forever and, as a
 *    bonus, cannot skip or duplicate a row when a new SMS lands mid-scan.
 *  * NEVER on the main thread. Nothing in this class touches the UI thread;
 *    [LedgerPlugin] runs it on a worker and [BackfillService] runs it inside a
 *    foreground service so it survives the user leaving the app.
 *
 * PRIVACY: the sender gate is applied to the `address` column before `body` is
 * ever read out of the cursor. Personal SMS are counted in `scannedCount` and
 * discarded without their text being materialised.
 */
internal class SmsBackfill(context: Context) {

    private val resolver = context.applicationContext.contentResolver

    /** One page of results, mirroring the Dart `MessageBatch`. */
    class Page(
        val messages: List<Map<String, Any?>>,
        val nextPageToken: String?,
        val scannedCount: Int,
    )

    /**
     * Reads forward until [limit] gated messages are collected or the inbox is
     * exhausted.
     *
     * @param since inclusive lower bound on the received time, millis, or null
     * @param until inclusive upper bound on the received time, millis, or null
     * @param pageToken opaque cursor from a previous [Page], or null to start
     * @return a page whose `nextPageToken` is null only when the scan reached
     *         the end of the inbox
     */
    fun readPage(
        since: Long?,
        until: Long?,
        limit: Int,
        pageToken: String?,
        signal: CancellationSignal? = null,
    ): Page {
        val safeLimit = limit.coerceIn(1, MAX_LIMIT)
        var token = Token.decode(pageToken)
        val kept = ArrayList<Map<String, Any?>>(minOf(safeLimit, 256))
        var scanned = 0
        var reachedEnd = false

        while (kept.size < safeLimit) {
            if (signal?.isCanceled == true) break

            val window = readWindow(
                token = token,
                since = since,
                until = until,
                remaining = safeLimit - kept.size,
                signal = signal,
            )
            scanned += window.rowsRead
            kept.addAll(window.kept)

            if (window.rowsRead == 0) {
                reachedEnd = true
                break
            }
            token = Token(window.lastDate, window.lastId)

            // The window ended because the inbox ran out, not because we hit
            // the row cap or filled the caller's page.
            if (!window.windowFull && !window.stoppedEarly) {
                reachedEnd = true
                break
            }
        }

        return Page(
            messages = kept,
            nextPageToken = if (reachedEnd) null else token?.encode(),
            scannedCount = scanned,
        )
    }

    /**
     * Drives [readPage] to the end of the inbox, handing each page to
     * [onPage]. Returns the total number of inbox rows examined.
     *
     * [onPage] returns false to abort the scan (used when nothing is listening
     * any more - see [BackfillService]).
     */
    fun scanAll(
        since: Long?,
        until: Long?,
        pageSize: Int,
        signal: CancellationSignal?,
        onPage: (page: Page, cumulativeScanned: Int, cumulativeKept: Int) -> Boolean,
    ): Int {
        var token: String? = null
        var cumulativeScanned = 0
        var cumulativeKept = 0
        while (true) {
            if (signal?.isCanceled == true) return cumulativeScanned
            val page = readPage(since, until, pageSize, token, signal)
            cumulativeScanned += page.scannedCount
            cumulativeKept += page.messages.size
            if (!onPage(page, cumulativeScanned, cumulativeKept)) return cumulativeScanned
            token = page.nextPageToken ?: return cumulativeScanned
        }
    }

    /**
     * Best-effort count of the inbox rows in range, for a progress bar. The
     * projection is `_id` only so the cursor window stays tiny. Returns null
     * when the provider refuses the query, which some OEM ROMs do - the caller
     * must render indeterminate progress rather than fail the import.
     */
    fun estimateTotal(since: Long?, until: Long?): Int? {
        val predicate = buildPredicate(token = null, since = since, until = until)
        return try {
            resolver.query(
                Telephony.Sms.Inbox.CONTENT_URI,
                arrayOf(Telephony.Sms._ID),
                predicate.selection,
                predicate.args,
                null,
            )?.use { it.count }
        } catch (t: Throwable) {
            Log.w(TAG, "inbox count unavailable: " + t.javaClass.simpleName)
            null
        }
    }

    // ------------------------------------------------------------- windows

    private class Window(
        val kept: List<Map<String, Any?>>,
        val rowsRead: Int,
        val lastDate: Long,
        val lastId: Long,
        /** Stopped because the caller's page filled up. */
        val stoppedEarly: Boolean,
        /** Stopped because the row cap was hit, so there is probably more. */
        val windowFull: Boolean,
    )

    private fun readWindow(
        token: Token?,
        since: Long?,
        until: Long?,
        remaining: Int,
        signal: CancellationSignal?,
    ): Window {
        val predicate = buildPredicate(token, since, until)
        val sort = Telephony.Sms.DATE + " ASC, " + Telephony.Sms._ID + " ASC LIMIT " + WINDOW_ROWS

        val cursor = openCursor(predicate, sort, signal)
            ?: return Window(emptyList(), 0, token?.date ?: 0L, token?.id ?: 0L, false, false)

        val kept = ArrayList<Map<String, Any?>>(minOf(remaining, WINDOW_ROWS))
        var rowsRead = 0
        var lastDate = token?.date ?: 0L
        var lastId = token?.id ?: 0L
        var stoppedEarly = false

        cursor.use { c ->
            val idIndex = c.getColumnIndex(Telephony.Sms._ID)
            val addressIndex = c.getColumnIndex(Telephony.Sms.ADDRESS)
            val bodyIndex = c.getColumnIndex(Telephony.Sms.BODY)
            val dateIndex = c.getColumnIndex(Telephony.Sms.DATE)
            val subIndex = c.getColumnIndex(SUBSCRIPTION_ID)
            if (idIndex < 0 || dateIndex < 0) {
                Log.w(TAG, "sms provider is missing _id/date, backfill unavailable")
                return Window(emptyList(), 0, lastDate, lastId, false, false)
            }

            while (c.moveToNext()) {
                rowsRead++
                lastId = c.getLong(idIndex)
                lastDate = c.getLong(dateIndex)

                val address = if (addressIndex >= 0) safeString(c, addressIndex) else null
                // Gate first. A personal SMS is counted and dropped without
                // its body ever being read out of the cursor window.
                if (MessageGate.senderHeader(address) == null) continue

                val body = if (bodyIndex >= 0) safeString(c, bodyIndex) else null
                if (body.isNullOrEmpty()) continue

                // `sub_id` is a SUBSCRIPTION id, not a slot index. Translating
                // one to the other needs SubscriptionManager and therefore
                // READ_PHONE_STATE, which this app deliberately does not hold.
                // On a typical dual-SIM handset the two subscription ids are
                // small and ordered, so a value in 0..3 is a usable proxy for
                // the slot; anything larger is reported as unknown rather than
                // written to the ledger as a wrong number.
                val simSlot = if (subIndex >= 0) {
                    val raw = c.getInt(subIndex)
                    if (raw in 0..3) raw else null
                } else {
                    null
                }

                val message = MessageGate.build(
                    senderRaw = address,
                    body = body,
                    receivedAtMillis = lastDate,
                    source = MessageGate.SOURCE_BACKFILL,
                    simSlot = simSlot,
                    providerId = lastId,
                ) ?: continue

                kept.add(message)
                if (kept.size >= remaining) {
                    stoppedEarly = true
                    break
                }
            }
        }

        return Window(
            kept = kept,
            rowsRead = rowsRead,
            lastDate = lastDate,
            lastId = lastId,
            stoppedEarly = stoppedEarly,
            windowFull = rowsRead >= WINDOW_ROWS,
        )
    }

    /**
     * `sub_id` exists from API 22 but a few OEM SMS providers still reject it.
     * Rather than lose the whole backfill over a dual-SIM nicety, the query is
     * retried without it once and the reduced projection is remembered.
     */
    private fun openCursor(
        predicate: Predicate,
        sort: String,
        signal: CancellationSignal?,
    ): Cursor? {
        if (!subscriptionColumnUsable) {
            return query(BASE_PROJECTION, predicate, sort, signal)
        }
        return try {
            query(FULL_PROJECTION, predicate, sort, signal)
        } catch (e: SQLiteException) {
            Log.w(TAG, "sms provider rejected sub_id, retrying without it")
            subscriptionColumnUsable = false
            query(BASE_PROJECTION, predicate, sort, signal)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "sms provider rejected sub_id, retrying without it")
            subscriptionColumnUsable = false
            query(BASE_PROJECTION, predicate, sort, signal)
        }
    }

    private fun query(
        projection: Array<String>,
        predicate: Predicate,
        sort: String,
        signal: CancellationSignal?,
    ): Cursor? = resolver.query(
        Telephony.Sms.Inbox.CONTENT_URI,
        projection,
        predicate.selection,
        predicate.args,
        sort,
        signal,
    )

    private class Predicate(val selection: String?, val args: Array<String>?)

    private fun buildPredicate(token: Token?, since: Long?, until: Long?): Predicate {
        val clauses = ArrayList<String>(3)
        val args = ArrayList<String>(4)
        if (since != null) {
            clauses.add(Telephony.Sms.DATE + " >= ?")
            args.add(since.toString())
        }
        if (until != null) {
            clauses.add(Telephony.Sms.DATE + " <= ?")
            args.add(until.toString())
        }
        if (token != null) {
            clauses.add(
                "(" + Telephony.Sms.DATE + " > ? OR (" +
                    Telephony.Sms.DATE + " = ? AND " + Telephony.Sms._ID + " > ?))",
            )
            args.add(token.date.toString())
            args.add(token.date.toString())
            args.add(token.id.toString())
        }
        return if (clauses.isEmpty()) {
            Predicate(null, null)
        } else {
            Predicate(clauses.joinToString(" AND "), args.toTypedArray())
        }
    }

    private fun safeString(cursor: Cursor, index: Int): String? = try {
        cursor.getString(index)
    } catch (t: Throwable) {
        null
    }

    /** The keyset cursor: the `(date, _id)` of the last row already consumed. */
    private class Token(val date: Long, val id: Long) {
        fun encode(): String = date.toString() + ":" + id.toString()

        companion object {
            fun decode(raw: String?): Token? {
                if (raw.isNullOrBlank()) return null
                val parts = raw.split(':')
                if (parts.size != 2) return null
                val date = parts[0].toLongOrNull() ?: return null
                val id = parts[1].toLongOrNull() ?: return null
                return Token(date, id)
            }
        }
    }

    companion object {
        private const val TAG = "LedgerBackfill"

        /**
         * Rows per cursor window. 500 five-column SMS rows sit comfortably
         * inside the 2MB CursorWindow; a null projection or a much larger
         * window is how "Row too big to fit into CursorWindow" happens.
         */
        const val WINDOW_ROWS = 500

        /** Upper bound on messages returned by one [readPage]. */
        const val MAX_LIMIT = 2_000

        private const val SUBSCRIPTION_ID = "sub_id"

        private val BASE_PROJECTION = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
        )

        private val FULL_PROJECTION = BASE_PROJECTION + SUBSCRIPTION_ID

        @Volatile
        private var subscriptionColumnUsable = true
    }
}
