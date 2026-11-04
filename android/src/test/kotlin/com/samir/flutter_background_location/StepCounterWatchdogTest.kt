package com.samir.flutter_background_location

import com.samir.flutter_background_location.StepCounterWatchdog.Action
import com.samir.flutter_background_location.StepCounterWatchdog.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StepCounterWatchdogTest {
    private fun watchdog(hasAlternateSensor: Boolean = true) = StepCounterWatchdog(
        movingConfidenceThreshold = 60,
        hasAlternateSensor = hasAlternateSensor,
    ).apply { onRegistered(0L) }

    /** One heartbeat with a fresh walking reading. */
    private fun StepCounterWatchdog.walkingHeartbeat(atMs: Long): Action {
        onActivity("walking", 80, atMs)
        return evaluate(atMs)
    }

    @Test
    fun escalatesOneStepPerHeartbeatFlushReregisterSwitchThenStalled() {
        val watchdog = watchdog()
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(60_000))
        assertEquals(State.COUNTING, watchdog.state)

        // Walking on two heartbeats and no rise for 90 s plus the latency.
        assertEquals(Action.FLUSH, watchdog.walkingHeartbeat(120_000))
        assertEquals(State.SUSPECT, watchdog.state)
        assertEquals(Action.REREGISTER, watchdog.walkingHeartbeat(180_000))
        assertEquals(Action.SWITCH_SENSOR, watchdog.walkingHeartbeat(240_000))
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(300_000))
        assertEquals(State.STALLED, watchdog.state)
        assertEquals("activity", watchdog.lastEvidence.code)
    }

    @Test
    fun withoutAnotherVariantTheCounterStallsAfterReregistering() {
        val watchdog = watchdog(hasAlternateSensor = false)
        watchdog.walkingHeartbeat(60_000)
        assertEquals(Action.FLUSH, watchdog.walkingHeartbeat(120_000))
        assertEquals(Action.REREGISTER, watchdog.walkingHeartbeat(180_000))
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(240_000))
        assertEquals(State.STALLED, watchdog.state)
    }

    @Test
    fun aStalledCounterIsRetriedEveryTenMinutesAtMostSixTimes() {
        val watchdog = watchdog()
        val actions = (1..180).map { minute -> watchdog.walkingHeartbeat(minute * 60_000L) }

        // The first pass, then six retries that re-register and switch again.
        assertEquals(1, actions.count { it == Action.FLUSH })
        assertEquals(7, actions.count { it == Action.REREGISTER })
        assertEquals(7, actions.count { it == Action.SWITCH_SENSOR })
        assertEquals(6, watchdog.retries)
        assertEquals(State.STALLED, watchdog.state)
        // Retries are ten minutes apart, each followed by a switch.
        val retryMinutes = actions.withIndex()
            .filter { it.value == Action.REREGISTER }
            .map { it.index + 1 }
        assertEquals(listOf(3, 15, 25, 35, 45, 55, 65), retryMinutes)
        retryMinutes.forEach { minute -> assertEquals(Action.SWITCH_SENSOR, actions[minute]) }
    }

    @Test
    fun vehicleReadingsOrNoEvidenceNeverSuspect() {
        val inVehicle = watchdog()
        val quiet = watchdog()
        val vehicleDoppler = watchdog()
        for (minute in 1..30) {
            val atMs = minute * 60_000L
            inVehicle.onActivity("automotive", 90, atMs)
            assertEquals(Action.NONE, inVehicle.evaluate(atMs))
            assertEquals(Action.NONE, quiet.evaluate(atMs))
            // Walking-pace Doppler in traffic, with a fresh in-vehicle reading.
            vehicleDoppler.onActivity("automotive", 40, atMs - 5_000)
            vehicleDoppler.onFix(speed = 1.4, speedAccuracy = 0.3, observedAtMs = atMs)
            assertEquals(Action.NONE, vehicleDoppler.evaluate(atMs))
        }
        listOf(inVehicle, quiet, vehicleDoppler).forEach {
            assertEquals(State.COUNTING, it.state)
            assertEquals(StepCounterWatchdog.Evidence.NONE, it.lastEvidence)
        }
    }

    @Test
    fun dopplerAloneStopsAtReregisteringAndNeverMarksTimeUncounted() {
        val watchdog = watchdog()
        val actions = (1..30).map { minute ->
            val atMs = minute * 60_000L
            watchdog.onFix(speed = 1.3, speedAccuracy = 0.3, observedAtMs = atMs)
            watchdog.evaluate(atMs)
        }
        assertEquals(listOf(Action.NONE, Action.FLUSH, Action.REREGISTER), actions.take(3))
        assertTrue(actions.drop(3).all { it == Action.NONE })
        assertEquals(State.SUSPECT, watchdog.state)
        assertEquals(0L, watchdog.uncountedMs)
        assertEquals("doppler", watchdog.lastEvidence.code)
    }

    @Test
    fun aRiseRecoversStalledTimeAndABaselineResetCommitsIt() {
        val watchdog = watchdog(hasAlternateSensor = false)
        watchdog.walkingHeartbeat(60_000)
        watchdog.walkingHeartbeat(120_000)
        watchdog.walkingHeartbeat(180_000)
        watchdog.walkingHeartbeat(240_000)
        assertEquals(State.STALLED, watchdog.state)
        watchdog.walkingHeartbeat(300_000)
        watchdog.walkingHeartbeat(360_000)
        assertEquals(120_000L, watchdog.uncountedMs)

        // The cumulative counter carried the stalled steps.
        watchdog.onRise(365_000)
        assertEquals(State.COUNTING, watchdog.state)
        assertEquals(0L, watchdog.uncountedMs)

        // Stalled again; this time the count restarts from a new baseline.
        assertEquals(Action.FLUSH, watchdog.walkingHeartbeat(490_000))
        assertEquals(Action.REREGISTER, watchdog.walkingHeartbeat(550_000))
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(610_000))
        assertEquals(State.STALLED, watchdog.state)
        watchdog.walkingHeartbeat(670_000)
        watchdog.onBaselineReset()
        watchdog.walkingHeartbeat(730_000)
        assertEquals(120_000L, watchdog.uncountedMs)
        watchdog.onRise(735_000)
        assertEquals(60_000L, watchdog.uncountedMs)
    }

    @Test
    fun aRiseReadBeforeTheStallDoesNotRecoverIt() {
        val watchdog = watchdog(hasAlternateSensor = false)
        (1..6).forEach { minute -> watchdog.walkingHeartbeat(minute * 60_000L) }
        assertEquals(120_000L, watchdog.uncountedMs)
        // A late batch of readings counted before the stall began.
        watchdog.onRise(200_000)
        assertEquals(State.COUNTING, watchdog.state)
        assertEquals(120_000L, watchdog.uncountedMs)
    }

    @Test
    fun finishingKeepsTheUnrecoveredTime() {
        val watchdog = watchdog(hasAlternateSensor = false)
        (1..5).forEach { minute -> watchdog.walkingHeartbeat(minute * 60_000L) }
        assertEquals(60_000L, watchdog.uncountedMs)
        watchdog.finish()
        watchdog.onRise(400_000)
        assertEquals(60_000L, watchdog.uncountedMs)
    }

    @Test
    fun evaluationsTooCloseTogetherDoNotShowSustainedWalking() {
        val watchdog = watchdog()
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(200_000))
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(210_000))
        assertEquals(State.COUNTING, watchdog.state)
        assertEquals(Action.FLUSH, watchdog.walkingHeartbeat(260_000))
    }

    @Test
    fun aStationaryExitCountsTowardsASuspicionCheckedAMinuteLater() {
        val withExit = watchdog()
        val withoutExit = watchdog()
        listOf(withExit, withoutExit).forEach { it.onActivity("walking", 90, 600_000) }
        withExit.onProfileSwitch(600_000, exitedStationary = true)

        assertEquals(Action.FLUSH, withExit.walkingHeartbeat(660_000))
        assertEquals(Action.NONE, withoutExit.walkingHeartbeat(660_000))
    }

    @Test
    fun aRecentRiseOrRegistrationIsNotSilence() {
        val watchdog = watchdog()
        watchdog.walkingHeartbeat(60_000)
        watchdog.onRise(100_000)
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(120_000))
        assertEquals(Action.NONE, watchdog.walkingHeartbeat(180_000))
        assertEquals(State.COUNTING, watchdog.state)
        // More than 120 s after the rise, walking throughout.
        assertEquals(Action.FLUSH, watchdog.walkingHeartbeat(240_000))
    }

    @Test
    fun fusedStepsAreEvidenceAndAStaleReadingIsNot() {
        val watchdog = watchdog()
        watchdog.onFusionStep(55_000)
        watchdog.evaluate(60_000)
        assertEquals("fusion_step", watchdog.lastEvidence.code)

        watchdog.onActivity("walking", 80, 60_000)
        watchdog.evaluate(100_000)
        assertEquals(StepCounterWatchdog.Evidence.NONE, watchdog.lastEvidence)

        // Below the moving confidence threshold.
        watchdog.onActivity("running", 59, 160_000)
        watchdog.evaluate(160_000)
        assertEquals(StepCounterWatchdog.Evidence.NONE, watchdog.lastEvidence)
    }

    @Test
    fun walkingPaceDopplerNeedsAPreciseSpeed() {
        assertTrue(StepCounterWatchdog.isWalkingPace(0.7, 0.5))
        assertTrue(StepCounterWatchdog.isWalkingPace(2.5, 0.1))
        assertFalse(StepCounterWatchdog.isWalkingPace(0.69, 0.1))
        assertFalse(StepCounterWatchdog.isWalkingPace(2.6, 0.1))
        assertFalse(StepCounterWatchdog.isWalkingPace(1.3, 0.51))
        assertFalse(StepCounterWatchdog.isWalkingPace(1.3, null))
        assertFalse(StepCounterWatchdog.isWalkingPace(null, 0.2))
        assertFalse(StepCounterWatchdog.isWalkingPace(Double.NaN, 0.2))
    }

    @Test
    fun diagnosticsKeepTheNewestEntriesAndNoStepCounts() {
        val ring = StepCounterDiagnosticsRing(capacity = 3)
        (1..5).forEach { ring.add(entry(at = it.toLong())) }
        assertEquals(listOf(3L, 4L, 5L), ring.snapshot().map { it.at })

        assertEquals(
            setOf(
                "at", "event", "sensorWakeUp", "sensorVendor", "sensorName", "fifoMax",
                "fifoReserved", "registered", "sinceDeliveryMs", "sinceEventMs", "sinceRiseMs",
                "flushAccepted", "flushCompletedMs", "reregistrations", "replayOutcome",
                "watchdogState", "evidenceSource", "wakeLockHeld", "screenOn", "deviceIdle",
                "standbyBucket", "sinceProfileSwitchMs", "sinceExitProbeMs",
                "sinceSignificantMotionMs",
            ),
            entry(at = 1L).toMap().keys,
        )
    }

    @Test
    fun coverageMapsCarryTheContractKeys() {
        val coverage = StepCoverage(
            state = StepCoverage.STATE_STALLED,
            countedThrough = 1_800_000_000_000L,
            lastRiseAt = 1_799_999_990_000L,
            uncountedMs = 120_000L,
            sensor = StepCoverage.SENSOR_WAKE_UP,
            reregistrations = 2,
        )
        assertEquals(
            linkedMapOf<String, Any?>(
                "state" to "stalled",
                "countedThrough" to 1_800_000_000_000L,
                "lastRiseAt" to 1_799_999_990_000L,
                "uncountedMs" to 120_000L,
                "sensor" to "wake_up",
                "reregistrations" to 2,
            ),
            coverage.toMap(),
        )
        assertEquals("unavailable", StepCoverage.UNAVAILABLE.toMap()["state"])
    }

    private fun entry(at: Long) = StepCounterDiagnosticEntry(
        at = at,
        event = "heartbeat",
        sensorWakeUp = true,
        sensorVendor = "vendor",
        sensorName = "step counter",
        fifoMax = 100,
        fifoReserved = 0,
        registered = true,
        sinceDeliveryMs = 1_000L,
        sinceEventMs = 1_500L,
        sinceRiseMs = 1_500L,
        flushAccepted = true,
        flushCompletedMs = 12L,
        reregistrations = 0,
        replayOutcome = null,
        watchdogState = "counting",
        evidenceSource = null,
        wakeLockHeld = true,
        screenOn = false,
        deviceIdle = false,
        standbyBucket = 10,
        sinceProfileSwitchMs = null,
        sinceExitProbeMs = null,
        sinceSignificantMotionMs = null,
    )
}
