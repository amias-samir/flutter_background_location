package com.samir.flutter_background_location

/**
 * In-memory capacity bookkeeping for the pending-location journal.
 *
 * The journal used to rescan every row (`COUNT(*)`, `SUM(length(payload))`,
 * `MAX(sequence)`) for each fix and each acknowledgement. These counters are
 * loaded once, updated after each committed write, and resynchronized by
 * diagnostics. Sequences only grow while the store is open, so a page cursor
 * is never overtaken by a reused sequence.
 */
internal class JournalCounters(
    private val maximumRows: Int,
    private val maximumPayloadLength: Long,
) {
    var rows: Int = 0
        private set
    var payloadLength: Long = 0L
        private set
    var lastSequence: Long = 0L
        private set

    /** Replaces the counters with values read from the table. */
    fun load(rows: Int, payloadLength: Long, maximumSequence: Long) {
        this.rows = rows.coerceAtLeast(0)
        this.payloadLength = payloadLength.coerceAtLeast(0L)
        lastSequence = maxOf(lastSequence, maximumSequence)
    }

    fun nextSequence(): Long = lastSequence + 1

    fun recordInsert(sequence: Long, payloadLength: Int) {
        rows += 1
        this.payloadLength += payloadLength
        lastSequence = maxOf(lastSequence, sequence)
    }

    fun recordDelete(rows: Int, payloadLength: Long) {
        this.rows = (this.rows - rows).coerceAtLeast(0)
        this.payloadLength = if (this.rows == 0) {
            0L
        } else {
            (this.payloadLength - payloadLength).coerceAtLeast(0L)
        }
    }

    /** Whether the row or payload bound is already reached. */
    fun isFull(): Boolean = rows >= maximumRows || payloadLength >= maximumPayloadLength

    /**
     * Whether page counts are worth reading. Payload text dominates the file,
     * so the page bound cannot be reached while payloads use less than half
     * of it.
     */
    fun needsPageCheck(): Boolean = payloadLength >= maximumPayloadLength / 2
}
