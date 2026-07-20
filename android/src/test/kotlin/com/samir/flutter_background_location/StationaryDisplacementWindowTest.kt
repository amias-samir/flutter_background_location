package com.samir.flutter_background_location

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StationaryDisplacementWindowTest {
    @Test
    fun lowDisplacementAcrossFullWindowAllowsStationaryEntry() {
        val evidence = StationaryDisplacementWindow()
        evidence.begin(0L, fix(0.0, 0L))
        evidence.add(fix(0.00005, 45_000L), CONFIRMATION_MS)
        evidence.add(fix(0.00010, 90_000L), CONFIRMATION_MS)

        assertTrue(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))
    }

    @Test
    fun oneFixIsInsufficientEvenAfterConfirmationTime() {
        val evidence = StationaryDisplacementWindow()
        evidence.begin(0L)
        evidence.add(fix(0.0, 90_000L), CONFIRMATION_MS)

        assertFalse(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))
    }

    @Test
    fun lateFirstFixMustItselfBeObservedForTheFullWindow() {
        val evidence = StationaryDisplacementWindow()
        evidence.begin(0L)
        evidence.add(fix(0.0, 30_000L), CONFIRMATION_MS)
        evidence.add(fix(0.00005, 90_000L), CONFIRMATION_MS)

        assertFalse(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))

        evidence.add(fix(0.00005, 120_000L), CONFIRMATION_MS)
        assertTrue(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))
    }

    @Test
    fun displacementBeyondThresholdKeepsMovingProfile() {
        val evidence = StationaryDisplacementWindow()
        evidence.begin(0L, fix(0.0, 0L))
        evidence.add(fix(0.001, 45_000L), CONFIRMATION_MS)
        evidence.add(fix(0.0, 90_000L), CONFIRMATION_MS)

        assertFalse(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))
    }

    @Test
    fun rollingWindowCanRecoverAfterEarlierMovement() {
        val evidence = StationaryDisplacementWindow()
        evidence.begin(0L, fix(0.0, 0L))
        evidence.add(fix(0.001, 30_000L), CONFIRMATION_MS)
        evidence.add(fix(0.001, 90_000L), CONFIRMATION_MS)
        assertFalse(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))

        evidence.add(fix(0.00105, 120_000L), CONFIRMATION_MS)
        assertTrue(evidence.hasLowDisplacement(CONFIRMATION_MS, 30f))
    }

    private fun fix(latitude: Double, timestamp: Long): StationaryGpsFix =
        StationaryGpsFix(latitude, 0.0, timestamp)

    companion object {
        private const val CONFIRMATION_MS = 90_000L
    }
}
