package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MotionEvidenceWindowsTest {
    @Test
    fun aFewStepsAreNotMovement() {
        val window = StepCadenceWindow()

        val reported = (0 until 5).map { window.onStep(nowElapsed = it * 600L) }

        assertTrue(reported.none { it })
    }

    @Test
    fun sustainedSteppingIsReportedAtMostEveryInterval() {
        val window = StepCadenceWindow()

        val reported = (0 until 60).map { index -> index * 500L to window.onStep(index * 500L) }
            .filter { it.second }
            .map { it.first }

        // The sixth step, then every 10 s while the cadence holds.
        assertEquals(listOf(2_500L, 12_500L, 22_500L), reported)
    }

    @Test
    fun stepsOutsideTheWindowDoNotAccumulate() {
        val window = StepCadenceWindow()

        val reported = (0 until 12).map { window.onStep(nowElapsed = it * 20_000L) }

        assertTrue(reported.none { it })
    }

    @Test
    fun theProbeBudgetSlidesInsteadOfResettingHourly() {
        val budget = RollingProbeBudget(windowMs = 3_600_000L)
        val maximum = 180_000L
        // Spend the whole budget at the end of one clock hour.
        budget.record(startElapsed = 3_420_000L, endElapsed = 3_600_000L)

        // A fixed window would refill at 3 600 000; the sliding one does not.
        assertFalse(budget.allows(nowElapsed = 3_610_000L, durationMs = 4_000L, maximumMs = maximum))
        assertEquals(176_000L, budget.usedMs(nowElapsed = 7_024_000L))
        assertTrue(budget.allows(nowElapsed = 7_030_000L, durationMs = 4_000L, maximumMs = maximum))
        assertEquals(0L, budget.usedMs(nowElapsed = 7_300_000L))
    }
}
