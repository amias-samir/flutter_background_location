package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class JournalCountersTest {
    @Test
    fun insertsAndDeletesKeepTheCountersInStep() {
        val counters = JournalCounters(maximumRows = 10, maximumPayloadLength = 1_000)
        counters.load(rows = 2, payloadLength = 300, maximumSequence = 7)

        val sequence = counters.nextSequence()
        counters.recordInsert(sequence, payloadLength = 120)
        counters.recordDelete(rows = 1, payloadLength = 100)

        assertEquals(8L, sequence)
        assertEquals(2, counters.rows)
        assertEquals(320L, counters.payloadLength)
        assertEquals(8L, counters.lastSequence)
    }

    @Test
    fun anEmptyQueueHasNoPayloadAndSequencesNeverRewind() {
        val counters = JournalCounters(maximumRows = 10, maximumPayloadLength = 1_000)
        counters.load(rows = 1, payloadLength = 50, maximumSequence = 41)

        counters.recordDelete(rows = 1, payloadLength = 49)
        // Diagnostics reload from an empty table; MAX(sequence) is then 0.
        counters.load(rows = 0, payloadLength = 0, maximumSequence = 0)

        assertEquals(0, counters.rows)
        assertEquals(0L, counters.payloadLength)
        assertEquals(42L, counters.nextSequence())
    }

    @Test
    fun capacityUsesRowsAndPayloadAndPagesOnlyNearTheBound() {
        val counters = JournalCounters(maximumRows = 3, maximumPayloadLength = 1_000)

        counters.load(rows = 2, payloadLength = 400, maximumSequence = 2)
        assertFalse(counters.isFull())
        assertFalse(counters.needsPageCheck())

        counters.recordInsert(sequence = 3, payloadLength = 100)
        assertTrue(counters.isFull())
        assertTrue(counters.needsPageCheck())

        counters.load(rows = 1, payloadLength = 1_000, maximumSequence = 3)
        assertTrue(counters.isFull())
    }
}
