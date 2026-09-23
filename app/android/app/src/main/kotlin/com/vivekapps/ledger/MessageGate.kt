package com.vivekapps.ledger

import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale

/**
 * The privacy gate every ingested message passes through, and the one place
 * that turns a platform SMS into the map the Dart side deserialises into a
 * `RawMessage`.
 *
 * PRIVACY CONTRACT (mirrors the Dart `MessageSource` doc, and is enforced
 * HERE because here is the earliest point at which it can be):
 *
 *  * [senderHeader] is evaluated BEFORE the body is copied anywhere. When it
 *    returns null the message is a personal SMS or an unregistered numeric
 *    sender: [build] returns null, nothing is written to the spool, nothing
 *    crosses the method channel, and nothing is persisted. The body exists
 *    only as the transient `SmsMessage` the OS handed us, which is garbage
 *    two statements later.
 *  * Nothing in this file logs a body, a sender, or a hash.
 *
 * WHY A STRUCTURAL GATE AND NOT A BANK WHITELIST: in India only a registered
 * DLT entity can send from an alphanumeric header; person-to-person SMS always
 * arrive from a phone number. Rejecting numeric senders therefore drops 100%
 * of personal SMS without needing to know a single bank name. Deciding which
 * of the surviving commercial headers is actually a bank is the parser's job,
 * driven by `rules/parser_rules.json` - putting a bank list in Kotlin would
 * fork the source of truth and could only be changed by shipping a new APK.
 */
internal object MessageGate {

    const val SOURCE_REALTIME = "sms_realtime"
    const val SOURCE_BACKFILL = "sms_backfill"

    /** Soft-hyphen, bidi controls, zero-width joiners, BOM. */
    private val INVISIBLE =
        Regex("[\u00AD\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]")

    private val WHITESPACE = Regex("\\s+")

    /** A phone number, short code or any other purely numeric sender. */
    private val NUMERIC_SENDER = Regex("^\\+?[0-9]{2,}$")

    /** `HDFCBK`, `ICICIT`, `SBIINB`, `ATMSBI`, `PAYTMB`, `IPBMSG`, ... */
    private val HEADER_SHAPE = Regex("^[A-Z][A-Z0-9]{2,10}$")

    /** Messages dated before this are a broken SMSC clock, not history. */
    private const val EPOCH_FLOOR_MILLIS = 946_684_800_000L // 2000-01-01T00:00Z

    /** Tolerance for an SMSC clock that runs ahead of the handset. */
    private const val FUTURE_SLACK_MILLIS = 24L * 60L * 60L * 1000L

    /**
     * Normalises a TRAI/TCCCPR sender to its bare header, or returns null when
     * the sender is not a registered alphanumeric header at all.
     *
     * `AX-HDFCBK-S` -> `HDFCBK`, `VM-ICICIB` -> `ICICIB`, `+919876543210` ->
     * null, `121` -> null.
     */
    fun senderHeader(senderRaw: String?): String? {
        val trimmed = senderRaw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null

        val normalised = Normalizer.normalize(trimmed, Normalizer.Form.NFKC)
            .replace(INVISIBLE, "")
            .replace(WHITESPACE, "")
            .uppercase(Locale.ROOT)
        if (normalised.isEmpty()) return null
        if (NUMERIC_SENDER.matches(normalised)) return null

        val parts = normalised.split('-', '.', '_').filter { it.isNotBlank() }
        if (parts.isEmpty()) return null

        // TCCCPR headers are `<2-letter operator>-<header>[-<1-letter category>]`.
        val candidate = when {
            parts.size >= 3 &&
                parts[0].length == 2 && parts[0].all { it.isLetter() } &&
                parts[2].length == 1 && parts[2][0].isLetter() -> parts[1]

            parts.size == 2 &&
                parts[0].length == 2 && parts[0].all { it.isLetter() } -> parts[1]

            parts.size == 1 -> parts[0]

            else -> parts.maxByOrNull { it.length } ?: return null
        }

        val cleaned = candidate.filter { it.isLetterOrDigit() }
        if (!HEADER_SHAPE.matches(cleaned)) return null
        // `A12345` is a numeric sender with a stray letter, not a bank header.
        if (cleaned.count { it.isLetter() } < 2) return null
        return cleaned
    }

    /**
     * The form of the body that is hashed. NFKC-folded so a bank that sends
     * `₹` as a compatibility codepoint hashes the same as one that does not,
     * invisible characters stripped (some issuers pad with zero-width spaces,
     * which would otherwise defeat dedupe), whitespace runs collapsed.
     *
     * Case is deliberately preserved: two different messages should not
     * collide, and no Indian issuer varies only by case.
     */
    fun normalizeBody(body: String?): String {
        val raw = body.orEmpty()
        if (raw.isEmpty()) return ""
        return Normalizer.normalize(raw, Normalizer.Form.NFKC)
            .replace(INVISIBLE, "")
            .replace(WHITESPACE, " ")
            .trim()
    }

    /** Lower-case hex SHA-256. The only form of a message that may be logged. */
    fun sha256Hex(input: String): String {
        val bytes = MessageDigest.getInstance("SHA-256")
            .digest(input.toByteArray(Charsets.UTF_8))
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append(HEX[v ushr 4])
            out.append(HEX[v and 0x0F])
        }
        return out.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()

    /**
     * A locally generated, lexicographically sortable id.
     *
     * Deterministic in (timestamp, body) so the same message re-read by a
     * backfill produces the same id - but the live SMSC timestamp and the
     * provider's `date` column are different clocks, so the authoritative
     * dedupe key downstream is `bodyHash`, with `providerId` as the tiebreak.
     * That is exactly what `RawMessage` documents.
     */
    fun localId(receivedAtMillis: Long, bodyHash: String): String {
        val stamp = receivedAtMillis.coerceAtLeast(0L).toString().padStart(13, '0')
        val suffix = if (bodyHash.length >= 16) bodyHash.substring(0, 16) else bodyHash
        return "$stamp-$suffix"
    }

    /**
     * Clamps a sender-supplied timestamp. A handful of Indian circles deliver
     * SMSC timestamps years out (or at the Unix epoch) on roaming SIMs, which
     * would drop the transaction into the wrong month forever.
     */
    fun saneTimestamp(candidateMillis: Long, nowMillis: Long): Long {
        if (candidateMillis < EPOCH_FLOOR_MILLIS) return nowMillis
        if (candidateMillis > nowMillis + FUTURE_SLACK_MILLIS) return nowMillis
        return candidateMillis
    }

    /**
     * Builds the channel payload, or returns null when the sender gate
     * rejects the message. A null return means the body was never copied.
     */
    fun build(
        senderRaw: String?,
        body: String?,
        receivedAtMillis: Long,
        source: String,
        simSlot: Int?,
        providerId: Long?,
    ): Map<String, Any?>? {
        val header = senderHeader(senderRaw) ?: return null
        val normalised = normalizeBody(body)
        if (normalised.isEmpty()) return null
        val hash = sha256Hex(normalised)
        return mapOf(
            "id" to localId(receivedAtMillis, hash),
            "senderRaw" to senderRaw.orEmpty(),
            "senderHeader" to header,
            "body" to body.orEmpty(),
            "receivedAt" to receivedAtMillis,
            "source" to source,
            "bodyHash" to hash,
            "simSlot" to simSlot,
            "providerId" to providerId,
        )
    }
}
