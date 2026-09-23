package com.vivekapps.ledger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SmsMessage
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Live SMS ingestion.
 *
 * Declared in the manifest (not registered at runtime) so the OS will start
 * this app's process to deliver a message even when no Activity exists. It is
 * hardened with `android:permission="android.permission.BROADCAST_SMS"`, which
 * means that despite `exported="true"` only the system can invoke it - no
 * other app can forge a transaction into the ledger.
 *
 * WHAT HAPPENS WHEN THE APP IS NOT RUNNING - the honest version:
 *
 *  1. App in foreground or backgrounded: the process is alive, the Flutter
 *     engine is alive, the message reaches Dart in milliseconds.
 *  2. App swiped out of recents: the process is dead. Android cold-starts it
 *     to run this receiver, so the message IS captured, but there is no
 *     FlutterEngine to receive it. It goes into [LiveMessageSpool] on disk and
 *     is delivered the next time Dart attaches. Nothing is lost.
 *  3. App force-stopped (Settings > Force stop), or put in the "restricted"
 *     App Battery Usage bucket: the system sets FLAG_STOPPED on the package
 *     and applies FLAG_EXCLUDE_STOPPED_PACKAGES to every broadcast. THIS
 *     RECEIVER WILL NEVER FIRE until the user manually opens the app again.
 *     There is no API that fixes this and no workaround; it is by design.
 *  4. OEM battery managers - THE REAL RISK, unsolved and unsolvable in code:
 *     Xiaomi/MIUI ("Autostart" off by default, plus "Battery saver >
 *     Restrict background activity"), Oppo/ColorOS and Realme ("Startup
 *     Manager"), Vivo/Funtouch ("High background power consumption"), and to a
 *     lesser degree OnePlus and Samsung ("Put unused apps to sleep") will
 *     force-stop a backgrounded app after a few hours or days and land it in
 *     state 3. On those devices live capture degrades to "whatever arrives
 *     while the app is open", silently.
 *
 * The mitigation is structural, not clever: because the app also holds
 * READ_SMS, every message the live path misses is still sitting in
 * `content://sms/inbox`, and [SmsBackfill] re-reads from the last known
 * watermark on next launch. Live delivery is a latency feature. Correctness
 * comes from the inbox. Any design that relies solely on this receiver is
 * wrong on roughly half of the Indian Android market.
 *
 * The UI should surface this: on Xiaomi/Oppo/Vivo, prompt the user once to
 * allow autostart and disable battery optimisation, and never claim "real-time
 * tracking" as a guarantee.
 */
class SmsReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        val appContext = context.applicationContext
        val pending = goAsync()
        val finished = AtomicBoolean(false)

        fun finish() {
            if (finished.compareAndSet(false, true)) {
                try {
                    pending.finish()
                } catch (t: Throwable) {
                    Log.w(TAG, "pendingResult.finish failed: " + t.javaClass.simpleName)
                }
            }
        }

        // A BroadcastReceiver that never finishes its PendingResult is an ANR
        // and, worse, gets the app blamed for it. The watchdog guarantees the
        // result is released even if the disk write hangs.
        // Runnable is explicit: schedule() is overloaded for Runnable and
        // Callable, and a bare Kotlin lambda is ambiguous between them.
        val watchdog = watchdogExecutor.schedule(
            Runnable { finish() },
            WORK_BUDGET_MS,
            TimeUnit.MILLISECONDS,
        )

        worker.execute {
            try {
                handle(appContext, intent)
            } catch (t: Throwable) {
                // Deliberately swallowed and never rethrown: a crash here kills
                // ingestion for every future message until the user notices.
                // The class of failure is logged; the message never is.
                Log.w(TAG, "live ingest failed: " + t.javaClass.simpleName)
            } finally {
                watchdog.cancel(false)
                finish()
            }
        }
    }

    private fun handle(context: Context, intent: Intent) {
        val parts: Array<SmsMessage> =
            Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (parts.isEmpty()) return

        // Multipart SMS arrive as several SmsMessage segments in one intent,
        // in order. Grouping by originating address also covers the OEMs that
        // batch two unrelated messages into a single broadcast.
        val joined = LinkedHashMap<String, StringBuilder>()
        for (part in parts) {
            val sender = part.originatingAddress ?: continue
            val segment = part.displayMessageBody ?: part.messageBody ?: continue
            joined.getOrPut(sender) { StringBuilder() }.append(segment)
        }
        if (joined.isEmpty()) return

        val now = System.currentTimeMillis()
        val simSlot = simSlotOf(intent)

        for ((sender, builder) in joined) {
            // The sender gate runs BEFORE the body goes anywhere. A personal
            // SMS produces null here and its text is never written to disk,
            // never crosses the channel and never reaches the database.
            if (MessageGate.senderHeader(sender) == null) continue

            val timestamp = MessageGate.saneTimestamp(
                parts.firstOrNull { it.originatingAddress == sender }?.timestampMillis ?: now,
                now,
            )
            val message = MessageGate.build(
                senderRaw = sender,
                body = builder.toString(),
                receivedAtMillis = timestamp,
                source = MessageGate.SOURCE_REALTIME,
                simSlot = simSlot,
                providerId = null,
            ) ?: continue

            LiveMessageSpool.append(context, message)
        }
    }

    /**
     * Best-effort dual-SIM slot. There is no public constant for this on
     * SMS_RECEIVED; every OEM picked a different extra, and several report a
     * subscription id rather than a slot index. Reading it would otherwise
     * need READ_PHONE_STATE, which this app deliberately does not hold, so an
     * unknown slot is reported as null rather than guessed.
     */
    private fun simSlotOf(intent: Intent): Int? {
        for (key in SLOT_EXTRA_KEYS) {
            if (!intent.hasExtra(key)) continue
            val value = intent.getIntExtra(key, -1)
            if (value in 0..3) return value
        }
        return null
    }

    companion object {
        private const val TAG = "LedgerSmsReceiver"

        /**
         * A BroadcastReceiver has ~10s before the system declares an ANR.
         * Finishing at 8s leaves headroom for the finish() itself.
         */
        private const val WORK_BUDGET_MS = 8_000L

        private val SLOT_EXTRA_KEYS = arrayOf(
            "android.telephony.extra.SLOT_INDEX",
            "slot",
            "simSlot",
            "simId",
            "phone",
            "slot_id",
        )

        /**
         * Single-threaded on purpose: SMS arrive one at a time, the spool is
         * append-ordered, and a thread pool would let two cold-start receivers
         * interleave their writes for no benefit. Process-wide, so a cold
         * start pays for it once.
         */
        private val worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "ledger-sms-ingest").apply { isDaemon = true }
        }

        private val watchdogExecutor: ScheduledExecutorService =
            Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "ledger-sms-watchdog").apply { isDaemon = true }
            }
    }
}
