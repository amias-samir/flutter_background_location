package com.samir.flutter_background_location

/**
 * The decision inputs journaled with each fix, so a route drained from the
 * journal hours later decides as it did live: the activity readings received
 * since the previous journaled fix, the profile switches since then, and the
 * profile in effect when each fix was captured.
 *
 * Readings keep the keys the activity channel emits, plus `seq`. `seq` counts
 * readings and switches together in arrival order within a capture
 * generation, so a gap marks compacted or dropped readings. Readings are
 * compacted as `test/fixtures/cross_language/activity_reading_compaction_v1.json`
 * describes, shared with the Swift `DecisionInputJournal`: transition and
 * change-only readings are always kept and end a run; other readings form
 * runs of one type and confidence bucket (below 60, 60 to 74, 75 and above),
 * and a run keeps its first and last reading. The newest [maximumReadings]
 * survive, then the oldest are dropped until the list fits
 * [maximumReadingBytes] of JSON; both caps count as dropped.
 *
 * Pure Kotlin. Readings and switches arrive on the main thread and fixes on
 * the provider thread, hence the locks.
 */
internal class DecisionInputJournal(
    private val maximumReadings: Int = MAXIMUM_READINGS,
    private val maximumReadingBytes: Int = MAXIMUM_READING_BYTES,
    private val maximumTransitions: Int = MAXIMUM_TRANSITIONS,
    private val profileHistorySize: Int = PROFILE_HISTORY_SIZE,
) {
    /** What one journaled fix carries. */
    data class Attachment(
        val activityReadings: List<Map<String, Any?>>,
        val activityReadingsDropped: Int,
        val profileTransitions: List<Map<String, Any?>>,
    )

    private data class RunKey(val type: Any?, val bucket: Int)

    private class Kept(val reading: Map<String, Any?>, val bytes: Int)

    private class Switch(val atElapsedNanos: Long, val from: String, val to: String)

    private var nextSeq = 1L
    private val readings = ArrayList<Kept>()
    private var openRun: RunKey? = null
    private var openRunHasLast = false
    private var dropped = 0
    private val transitions = ArrayDeque<Map<String, Any?>>()
    private val switches = ArrayDeque<Switch>()
    private var initialProfile = TrackingStateStore.PROFILE_MOVING

    /** Starts a capture generation in [initialProfile]. */
    @Synchronized
    fun reset(initialProfile: String) {
        this.initialProfile = initialProfile
        nextSeq = 1L
        readings.clear()
        closeRun()
        dropped = 0
        transitions.clear()
        switches.clear()
    }

    /** An activity reading as emitted on the activity channel. */
    @Synchronized
    fun onActivityReading(reading: Map<String, Any?>) {
        val entry = LinkedHashMap(reading).apply { put("seq", nextSeq++) }
        val kept = Kept(entry, jsonLength(entry))
        if (reading["source"] in ALWAYS_KEPT_SOURCES) {
            closeRun()
            append(kept)
            return
        }
        val key = RunKey(reading["type"], confidenceBucket(reading["confidence"]))
        when {
            key != openRun -> {
                openRun = key
                openRunHasLast = false
                append(kept)
            }
            // The open run is always at the tail; its newest reading replaces
            // the previous last one.
            openRunHasLast -> readings[readings.lastIndex] = kept
            else -> {
                openRunHasLast = true
                append(kept)
            }
        }
    }

    /** A moving/stationary switch at [atElapsedNanos] (elapsed realtime). */
    @Synchronized
    fun onProfileSwitch(
        atElapsedNanos: Long,
        atEpochMs: Long,
        from: String,
        to: String,
        reason: String?,
    ) {
        switches.addLast(Switch(atElapsedNanos, from, to))
        while (switches.size > profileHistorySize) switches.removeFirst()
        transitions.addLast(
            linkedMapOf(
                "seq" to nextSeq++,
                "at" to atEpochMs,
                "from" to from,
                "to" to to,
                "reason" to reason,
            ),
        )
        while (transitions.size > maximumTransitions) transitions.removeFirst()
    }

    /**
     * The profile in effect when a fix was captured at [elapsedRealtimeNanos];
     * a batch delivered after a switch holds fixes captured before it.
     */
    @Synchronized
    fun profileAt(elapsedRealtimeNanos: Long): String {
        if (switches.isEmpty()) return initialProfile
        if (elapsedRealtimeNanos <= 0L) return switches.last().to
        for (index in switches.indices.reversed()) {
            val switch = switches[index]
            if (elapsedRealtimeNanos >= switch.atElapsedNanos) return switch.to
        }
        return switches.first().from
    }

    /** The inputs since the previous journaled fix; the next fix starts empty. */
    @Synchronized
    fun drain(): Attachment {
        var bytes = listBytes()
        while (readings.isNotEmpty() && bytes > maximumReadingBytes) {
            readings.removeAt(0)
            dropped += 1
            bytes = listBytes()
        }
        val attachment = Attachment(
            activityReadings = readings.map { it.reading },
            activityReadingsDropped = dropped,
            profileTransitions = transitions.toList(),
        )
        readings.clear()
        closeRun()
        dropped = 0
        transitions.clear()
        return attachment
    }

    private fun append(kept: Kept) {
        readings.add(kept)
        while (readings.size > maximumReadings) {
            readings.removeAt(0)
            dropped += 1
        }
    }

    private fun closeRun() {
        openRun = null
        openRunHasLast = false
    }

    private fun listBytes(): Int =
        2 + readings.sumOf { it.bytes } + (readings.size - 1).coerceAtLeast(0)

    internal companion object {
        const val MAXIMUM_READINGS = 64
        const val MAXIMUM_READING_BYTES = 16 * 1024
        const val MAXIMUM_TRANSITIONS = 8
        const val PROFILE_HISTORY_SIZE = 16

        /** Sources whose every reading is kept: transitions and change-only readings. */
        val ALWAYS_KEPT_SOURCES = setOf("android_activity_transition", "ios_core_motion_activity")

        fun confidenceBucket(confidence: Any?): Int {
            val value = (confidence as? Number)?.toInt() ?: 0
            return when {
                value < 60 -> 0
                value < 75 -> 1
                else -> 2
            }
        }

        /** UTF-8 length of [value] as compact JSON; strings are counted unescaped. */
        fun jsonLength(value: Any?): Int = when (value) {
            null -> 4
            is Boolean -> if (value) 4 else 5
            is Number -> value.toString().length
            is String -> quotedLength(value)
            is Map<*, *> -> 2 + value.entries.sumOf { (key, nested) ->
                quotedLength(key.toString()) + 1 + jsonLength(nested)
            } + (value.size - 1).coerceAtLeast(0)
            is Collection<*> -> 2 + value.sumOf { jsonLength(it) } +
                (value.size - 1).coerceAtLeast(0)
            else -> quotedLength(value.toString())
        }

        private fun quotedLength(text: String): Int = 2 + text.toByteArray(Charsets.UTF_8).size
    }
}
