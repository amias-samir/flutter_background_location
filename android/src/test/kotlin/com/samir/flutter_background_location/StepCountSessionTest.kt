package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StepCountSessionTest {
    @Test
    fun theFirstReadingIsTheBaselineAndLaterReadingsAddTheirRise() {
        val session = StepCountSession("generation")
        assertNull("not measured before the counter reports", session.steps)

        session.onCounter(counter = 52_000, elapsedMs = 1_000)
        assertEquals(0L, session.steps)
        session.onCounter(counter = 52_012, elapsedMs = 11_000)
        session.onCounter(counter = 52_030, elapsedMs = 21_000)

        assertEquals(30L, session.steps)
    }

    @Test
    fun aLowerReadingStartsANewBaselineWithoutInventingSteps() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 9_000, elapsedMs = 0)
        session.onCounter(counter = 9_040, elapsedMs = 30_000)
        // The counter restarted from zero.
        session.onCounter(counter = 15, elapsedMs = 40_000)
        assertEquals(40L, session.steps)

        session.onCounter(counter = 35, elapsedMs = 50_000)
        assertEquals(60L, session.steps)
    }

    @Test
    fun aRiseNoOneCouldWalkIsANewBaseline() {
        val session = StepCountSession("generation")
        // A stale first reading, then the real total.
        session.onCounter(counter = 100, elapsedMs = 0)
        session.onCounter(counter = 48_100, elapsedMs = 2_000)
        assertEquals(0L, session.steps)

        session.onCounter(counter = 48_120, elapsedMs = 12_000)
        assertEquals(20L, session.steps)
    }

    @Test
    fun batchedReadingsAndLongQuietSpellsStillCount() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 0, elapsedMs = 0)
        // A batch delivers several readings at once.
        session.onCounter(counter = 20, elapsedMs = 10_000)
        session.onCounter(counter = 38, elapsedMs = 10_000)
        session.onCounter(counter = 55, elapsedMs = 10_000)
        // An hour sitting still, then a short walk.
        session.onCounter(counter = 80, elapsedMs = 3_610_000)

        assertEquals(80L, session.steps)
    }

    @Test
    fun repeatedAndNegativeReadingsChangeNothing() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 500, elapsedMs = 0)
        session.onCounter(counter = 510, elapsedMs = 5_000)
        session.onCounter(counter = 510, elapsedMs = 6_000)
        session.onCounter(counter = -1, elapsedMs = 7_000)

        assertEquals(10L, session.steps)
        assertEquals("generation", session.generationId)
    }

    @Test
    fun aVariantSwitchStartsANewBaselineAndKeepsTheStepsCounted() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 1_000, deliveredMs = 0, eventMs = 0)
        session.onCounter(counter = 1_050, deliveredMs = 60_000, eventMs = 59_000)
        assertEquals(50L, session.steps)

        // The other counter happens to read just above the first one's value;
        // its readings are never compared with the first counter's.
        session.startNewBaseline()
        assertEquals(
            StepCountSession.Outcome.BASELINE,
            session.onCounter(counter = 1_070, deliveredMs = 61_000, eventMs = 60_500),
        )
        assertEquals(50L, session.steps)

        session.onCounter(counter = 1_100, deliveredMs = 90_000, eventMs = 89_000)
        assertEquals(80L, session.steps)
    }

    @Test
    fun risesAreBoundedByTheReadingsOwnTimesWhenTheyAreUsable() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 0, deliveredMs = 0, eventMs = 0)
        // Delivered 100 s later but counted within one second: no one walks
        // 500 steps in 36 s, so it becomes a new baseline.
        assertEquals(
            StepCountSession.Outcome.RESET,
            session.onCounter(counter = 500, deliveredMs = 100_000, eventMs = 1_000),
        )
        assertEquals(0L, session.steps)

        // A batch: one delivery, readings spread over 25 s.
        session.onCounter(counter = 520, deliveredMs = 130_000, eventMs = 105_000)
        session.onCounter(counter = 540, deliveredMs = 130_000, eventMs = 115_000)
        session.onCounter(counter = 560, deliveredMs = 130_000, eventMs = 125_000)
        assertEquals(60L, session.steps)
        assertEquals(125_000L, session.lastRiseMs)
        assertEquals(125_000L, session.countedThroughMs)
    }

    @Test
    fun untrustedEventTimesFallBackToDeliveryTime() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 0, deliveredMs = 50_000, eventMs = 50_000)
        // Not newer than the previous timestamp: the delivery window applies.
        assertEquals(
            StepCountSession.Outcome.ROSE,
            session.onCounter(counter = 300, deliveredMs = 100_000, eventMs = 50_000),
        )
        // Later than its own delivery: the delivery window applies.
        assertEquals(
            StepCountSession.Outcome.ROSE,
            session.onCounter(counter = 700, deliveredMs = 160_000, eventMs = 400_000),
        )
        assertEquals(700L, session.steps)
        assertEquals(160_000L, session.lastRiseMs)
    }

    @Test
    fun aThirtyMinuteStallIsRecoveredExactlyOnce() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 1_000, deliveredMs = 0, eventMs = 0)
        session.onCounter(counter = 1_100, deliveredMs = 60_000, eventMs = 58_000)

        // Thirty minutes of silence; the re-registered counter replays its
        // cumulative value with the timestamp of its last delivered reading.
        val stallEndMs = 58_000L + 30 * 60_000L
        assertEquals(
            StepCountSession.Outcome.ROSE,
            session.onCounter(counter = 4_100, deliveredMs = stallEndMs, eventMs = 58_000),
        )
        assertEquals(3_100L, session.steps)

        // The flush and a second registration replay the same value.
        assertEquals(
            StepCountSession.Outcome.SAME,
            session.onCounter(counter = 4_100, deliveredMs = stallEndMs + 500, eventMs = 58_000),
        )
        assertEquals(
            StepCountSession.Outcome.SAME,
            session.onCounter(counter = 4_100, deliveredMs = stallEndMs + 900, eventMs = null),
        )
        session.onCounter(counter = 4_110, deliveredMs = stallEndMs + 10_000, eventMs = stallEndMs + 8_000)
        assertEquals(3_110L, session.steps)
    }

    @Test
    fun neverInventsStepsFromImplausibleReadings() {
        val session = StepCountSession("generation")
        session.onCounter(counter = 10, deliveredMs = 0, eventMs = 0)
        session.onCounter(counter = 100_000, deliveredMs = 1_000, eventMs = 1_000)
        session.onCounter(counter = 5, deliveredMs = 2_000, eventMs = 2_000)
        session.onCounter(counter = 70_000, deliveredMs = 3_000, eventMs = 3_000)
        assertEquals(0L, session.steps)
        assertNull(session.lastRiseMs)
    }

    @Test
    fun aCompletedFlushAccountsForTheCountWithoutAddingSteps() {
        val session = StepCountSession("generation")
        session.accountedThrough(5_000)
        assertNull("nothing is accounted before the first reading", session.countedThroughMs)

        session.onCounter(counter = 40, deliveredMs = 10_000, eventMs = 9_000)
        session.accountedThrough(70_000)
        assertEquals(70_000L, session.countedThroughMs)
        session.accountedThrough(60_000)
        assertEquals(70_000L, session.countedThroughMs)
        assertEquals(0L, session.steps)
    }
}
