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
}
