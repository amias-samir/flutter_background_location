package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DiagnosticsModeTest {
    @Test
    fun cleanDetailKeepsOnlyThePackagesOwnSentence() {
        val error = IllegalStateException("provider said something private")
        assertEquals(
            "Location updates failed.",
            DiagnosticsMode.detail("Location updates failed.", error, full = false),
        )
        assertEquals(
            "Location updates failed: provider said something private",
            DiagnosticsMode.detail("Location updates failed.", error, full = true),
        )
    }

    @Test
    fun errorsWithoutTextKeepTheSentence() {
        assertEquals(
            "Location updates failed.",
            DiagnosticsMode.detail("Location updates failed.", IllegalStateException(), full = true),
        )
        assertEquals(
            "Location updates failed.",
            DiagnosticsMode.detail("Location updates failed.", IllegalStateException(" "), full = true),
        )
        assertEquals(
            "Location updates failed.",
            DiagnosticsMode.detail("Location updates failed.", null, full = true),
        )
    }

    @Test
    fun onlyFullAndCleanAreAccepted() {
        assertEquals("full", DiagnosticsMode.parse("full"))
        assertEquals("clean", DiagnosticsMode.parse("clean"))
        assertNull(DiagnosticsMode.parse("automatic"))
        assertNull(DiagnosticsMode.parse(null))
        assertNull(DiagnosticsMode.parse(1))
    }

    @Test
    fun theDetailIsCleanUntilDartSendsOne() {
        // No context has been loaded or applied in this process.
        assertFalse(DiagnosticsMode.full)
        assertTrue(StepCounter.diagnostics().isEmpty())
    }

    @Test
    fun clearingTheRingDropsEveryEntry() {
        val ring = StepCounterDiagnosticsRing(capacity = 4)
        repeat(3) { index ->
            ring.add(
                StepCounterDiagnosticEntry(
                    at = index.toLong(),
                    event = "heartbeat",
                    sensorWakeUp = true,
                    sensorVendor = null,
                    sensorName = null,
                    fifoMax = null,
                    fifoReserved = null,
                    registered = true,
                    sinceDeliveryMs = null,
                    sinceEventMs = null,
                    sinceRiseMs = null,
                    flushAccepted = null,
                    flushCompletedMs = null,
                    reregistrations = 0,
                    replayOutcome = null,
                    watchdogState = StepCoverage.STATE_COUNTING,
                    evidenceSource = null,
                    wakeLockHeld = null,
                    screenOn = null,
                    deviceIdle = null,
                    standbyBucket = null,
                    sinceProfileSwitchMs = null,
                    sinceExitProbeMs = null,
                    sinceSignificantMotionMs = null,
                ),
            )
        }
        assertEquals(3, ring.snapshot().size)
        ring.clear()
        assertTrue(ring.snapshot().isEmpty())
    }
}
