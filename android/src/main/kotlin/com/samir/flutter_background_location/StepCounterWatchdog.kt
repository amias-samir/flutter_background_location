package com.samir.flutter_background_location

/**
 * Notices a step counter that stops reporting while the person walks, and
 * chooses the repair to try. Only motion evidence feeds it (a fused step
 * cadence, a fresh walking reading, or a walking-pace Doppler speed): steps
 * never decide motion, and missing steps are never estimated.
 *
 * - counting: nothing suggests the counter missed steps.
 * - suspect: walking evidence at two evaluations at least
 *   [MINIMUM_STREAK_SPACING_MS] apart, and no rise for 90 s plus the report
 *   latency. Each later evaluation with evidence takes one repair step:
 *   flush, re-register the same sensor, switch to the other variant (a new
 *   baseline), then stalled. Doppler alone never goes past re-registering.
 * - stalled: the repairs failed. Walking time with step or activity evidence
 *   accrues as uncounted until a rise on the same baseline recovers it (the
 *   counter is cumulative). Every [RETRY_INTERVAL_MS] the repair restarts at
 *   re-registering, at most [MAXIMUM_RETRIES] times per capture generation.
 *
 * Any rise returns to counting. Pure Kotlin on the elapsed-realtime clock in
 * milliseconds; the service feeds it from its main and provider threads,
 * hence the locks.
 */
internal class StepCounterWatchdog(
    movingConfidenceThreshold: Int,
    private val hasAlternateSensor: Boolean,
    reportLatencyMs: Long = DEFAULT_REPORT_LATENCY_MS,
) {
    enum class State(val code: String) {
        COUNTING(StepCoverage.STATE_COUNTING),
        SUSPECT(StepCoverage.STATE_SUSPECT),
        STALLED(StepCoverage.STATE_STALLED),
    }

    enum class Action { NONE, FLUSH, REREGISTER, SWITCH_SENSOR }

    /** The strongest walking evidence at an evaluation, reported in diagnostics. */
    enum class Evidence(val code: String?) {
        NONE(null),
        DOPPLER("doppler"),
        ACTIVITY("activity"),
        FUSION_STEP("fusion_step"),
        ;

        /** Evidence that may switch sensors and mark time uncounted; Doppler alone may not. */
        val decisive: Boolean
            get() = this == ACTIVITY || this == FUSION_STEP
    }

    @Volatile
    var movingConfidenceThreshold: Int = movingConfidenceThreshold

    private val silenceMs = SILENCE_BEFORE_LATENCY_MS + reportLatencyMs

    var state: State = State.COUNTING
        @Synchronized get
        private set

    /** Evidence found by the newest evaluation. */
    var lastEvidence: Evidence = Evidence.NONE
        @Synchronized get
        private set

    var retries: Int = 0
        @Synchronized get
        private set

    var lastProfileSwitchAtMs: Long? = null
        @Synchronized get
        private set

    var lastExitProbeAtMs: Long? = null
        @Synchronized get
        private set

    var lastSignificantMotionAtMs: Long? = null
        @Synchronized get
        private set

    private var registeredAtMs: Long? = null
    private var lastRiseAtMs: Long? = null
    private var walkingReadingAtMs: Long? = null
    private var vehicleReadingAtMs: Long? = null
    private var fusionStepAtMs: Long? = null
    private var lastFixAtMs: Long? = null
    private var lastFixAtWalkingPace = false
    private var streak = 0
    private var lastStreakPointAtMs: Long? = null
    private var step = STEP_NONE
    private var lastActionAtMs: Long? = null
    private var stalledSinceMs: Long? = null
    private var lastRetryAtMs: Long? = null
    private var lastEvaluationAtMs: Long? = null
    private var committedUncountedMs = 0L
    private var pendingUncountedMs = 0L

    /** Stalled walking time no rise has recovered, including the current stall. */
    val uncountedMs: Long
        @Synchronized get() = committedUncountedMs + pendingUncountedMs

    /** The counter was (re)registered: silence is measured from here. */
    @Synchronized
    fun onRegistered(nowMs: Long) {
        registeredAtMs = nowMs
    }

    @Synchronized
    fun onActivity(type: String, confidence: Int, observedAtMs: Long) {
        when (type) {
            in WALKING_TYPES -> if (confidence >= movingConfidenceThreshold) {
                walkingReadingAtMs = newest(walkingReadingAtMs, observedAtMs)
            }
            in VEHICLE_TYPES -> vehicleReadingAtMs = newest(vehicleReadingAtMs, observedAtMs)
        }
    }

    /** A sustained step cadence from the fused step detector. */
    @Synchronized
    fun onFusionStep(observedAtMs: Long) {
        fusionStepAtMs = newest(fusionStepAtMs, observedAtMs)
    }

    /** Recorded for diagnostics: an AP-waking event, not walking evidence. */
    @Synchronized
    fun onSignificantMotion(observedAtMs: Long) {
        lastSignificantMotionAtMs = newest(lastSignificantMotionAtMs, observedAtMs)
    }

    /** Any provider fix; only the newest one's Doppler speed is evidence. */
    @Synchronized
    fun onFix(speed: Double?, speedAccuracy: Double?, observedAtMs: Long) {
        val last = lastFixAtMs
        if (last != null && observedAtMs < last) return
        lastFixAtMs = observedAtMs
        lastFixAtWalkingPace = isWalkingPace(speed, speedAccuracy)
    }

    /**
     * Some counters went silent right after a switch from the stationary
     * profile; the evidence at the switch counts towards a suspicion.
     */
    @Synchronized
    fun onProfileSwitch(nowMs: Long, exitedStationary: Boolean) {
        lastProfileSwitchAtMs = nowMs
        if (exitedStationary) noteStreakPoint(nowMs, evidenceAt(nowMs))
    }

    @Synchronized
    fun onExitProbe(nowMs: Long) {
        lastExitProbeAtMs = nowMs
        noteStreakPoint(nowMs, evidenceAt(nowMs))
    }

    /**
     * An accepted rise read at [atMs]. A reading from after the stall began
     * carries the steps taken during it, so that time is recovered.
     */
    @Synchronized
    fun onRise(atMs: Long) {
        val stalledSince = stalledSinceMs
        if (stalledSince != null && atMs < stalledSince) {
            committedUncountedMs += pendingUncountedMs
        }
        pendingUncountedMs = 0L
        lastRiseAtMs = newest(lastRiseAtMs, atMs)
        state = State.COUNTING
        step = STEP_NONE
        stalledSinceMs = null
    }

    /** The count continues from a new baseline; earlier stalled time can no longer be recovered. */
    @Synchronized
    fun onBaselineReset() {
        committedUncountedMs += pendingUncountedMs
        pendingUncountedMs = 0L
    }

    /** The capture generation ended after its final reading. */
    @Synchronized
    fun finish() = onBaselineReset()

    /** A heartbeat or scheduled check: at most one repair action. */
    @Synchronized
    fun evaluate(nowMs: Long): Action {
        val evidence = evidenceAt(nowMs)
        lastEvidence = evidence
        noteStreakPoint(nowMs, evidence)
        if (state == State.STALLED) accrueStalledTime(nowMs, evidence)
        lastEvaluationAtMs = nowMs
        if (state == State.COUNTING && streak >= 2 && silentFor(nowMs) >= silenceMs) {
            state = State.SUSPECT
            step = STEP_NONE
        }
        if (state == State.COUNTING || evidence == Evidence.NONE) return Action.NONE
        val lastAction = lastActionAtMs
        if (lastAction != null && nowMs - lastAction < MINIMUM_ACTION_SPACING_MS) return Action.NONE
        return if (state == State.SUSPECT) escalate(nowMs, evidence) else repairStall(nowMs, evidence)
    }

    private fun escalate(nowMs: Long, evidence: Evidence): Action = when (step) {
        STEP_NONE -> act(nowMs, Action.FLUSH, STEP_FLUSHED)
        STEP_FLUSHED -> act(nowMs, Action.REREGISTER, STEP_REREGISTERED)
        STEP_REREGISTERED -> when {
            !evidence.decisive -> Action.NONE
            hasAlternateSensor -> act(nowMs, Action.SWITCH_SENSOR, STEP_SWITCHED)
            else -> stall(nowMs)
        }
        else -> if (evidence.decisive) stall(nowMs) else Action.NONE
    }

    /** A retry restarts at re-registering, then switches once more where it may. */
    private fun repairStall(nowMs: Long, evidence: Evidence): Action {
        if (step == STEP_REREGISTERED) {
            step = STEP_DONE
            if (evidence.decisive && hasAlternateSensor) {
                return act(nowMs, Action.SWITCH_SENSOR, STEP_DONE)
            }
        }
        val since = lastRetryAtMs ?: stalledSinceMs ?: nowMs
        if (retries >= MAXIMUM_RETRIES || nowMs - since < RETRY_INTERVAL_MS) return Action.NONE
        retries += 1
        lastRetryAtMs = nowMs
        return act(nowMs, Action.REREGISTER, STEP_REREGISTERED)
    }

    private fun stall(nowMs: Long): Action {
        state = State.STALLED
        stalledSinceMs = nowMs
        step = STEP_DONE
        return Action.NONE
    }

    private fun act(nowMs: Long, action: Action, nextStep: Int): Action {
        step = nextStep
        lastActionAtMs = nowMs
        return action
    }

    private fun accrueStalledTime(nowMs: Long, evidence: Evidence) {
        if (!evidence.decisive) return
        val from = maxOf(lastEvaluationAtMs ?: nowMs, stalledSinceMs ?: nowMs)
        pendingUncountedMs += (nowMs - from).coerceIn(0L, MAXIMUM_ACCRUAL_MS)
    }

    private fun silentFor(nowMs: Long): Long {
        val reference = listOfNotNull(lastRiseAtMs, registeredAtMs).maxOrNull() ?: return 0L
        return nowMs - reference
    }

    private fun noteStreakPoint(nowMs: Long, evidence: Evidence) {
        val last = lastStreakPointAtMs
        when {
            evidence == Evidence.NONE -> streak = 0
            streak == 0 || last == null -> {
                streak = 1
                lastStreakPointAtMs = nowMs
            }
            nowMs - last >= MINIMUM_STREAK_SPACING_MS -> {
                streak += 1
                lastStreakPointAtMs = nowMs
            }
            // Too soon after the last counted point to show sustained walking.
        }
    }

    private fun evidenceAt(nowMs: Long): Evidence = when {
        isFresh(fusionStepAtMs, nowMs) -> Evidence.FUSION_STEP
        isFresh(walkingReadingAtMs, nowMs) -> Evidence.ACTIVITY
        lastFixAtWalkingPace && isFresh(lastFixAtMs, nowMs) &&
            !isFresh(vehicleReadingAtMs, nowMs) -> Evidence.DOPPLER
        else -> Evidence.NONE
    }

    private fun isFresh(atMs: Long?, nowMs: Long): Boolean =
        atMs != null && nowMs - atMs <= EVIDENCE_FRESHNESS_MS

    private fun newest(current: Long?, candidate: Long): Long =
        if (current == null || candidate > current) candidate else current

    internal companion object {
        const val DEFAULT_REPORT_LATENCY_MS = 30_000L
        const val SILENCE_BEFORE_LATENCY_MS = 90_000L
        const val EVIDENCE_FRESHNESS_MS = 30_000L
        const val MINIMUM_STREAK_SPACING_MS = 50_000L
        const val MINIMUM_ACTION_SPACING_MS = 50_000L
        const val RETRY_INTERVAL_MS = 600_000L
        const val MAXIMUM_RETRIES = 6
        const val MAXIMUM_ACCRUAL_MS = 120_000L
        const val WALKING_PACE_MINIMUM_METERS_PER_SECOND = 0.7
        const val WALKING_PACE_MAXIMUM_METERS_PER_SECOND = 2.5
        const val WALKING_PACE_MAXIMUM_SPEED_ACCURACY = 0.5

        /** Native activity types; on-foot readings map to walking. */
        val WALKING_TYPES = setOf("walking", "running")
        val VEHICLE_TYPES = setOf("automotive", "cycling")

        private const val STEP_NONE = 0
        private const val STEP_FLUSHED = 1
        private const val STEP_REREGISTERED = 2
        private const val STEP_SWITCHED = 3
        private const val STEP_DONE = 4

        fun isWalkingPace(speed: Double?, speedAccuracy: Double?): Boolean {
            if (speed == null || speedAccuracy == null) return false
            if (!speed.isFinite() || !speedAccuracy.isFinite() || speedAccuracy < 0.0) return false
            return speed >= WALKING_PACE_MINIMUM_METERS_PER_SECOND &&
                speed <= WALKING_PACE_MAXIMUM_METERS_PER_SECOND &&
                speedAccuracy <= WALKING_PACE_MAXIMUM_SPEED_ACCURACY
        }
    }
}

/**
 * The `stepCoverage` map on location events and status: how complete a
 * capture generation's step count is. Times are epoch milliseconds. Holds no
 * step count, so it may appear in diagnostics.
 */
internal data class StepCoverage(
    val state: String,
    /** The newest reading, or completed flush, the count accounts for. */
    val countedThrough: Long?,
    val lastRiseAt: Long?,
    val uncountedMs: Long,
    val sensor: String?,
    val reregistrations: Int,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "state" to state,
        "countedThrough" to countedThrough,
        "lastRiseAt" to lastRiseAt,
        "uncountedMs" to uncountedMs,
        "sensor" to sensor,
        "reregistrations" to reregistrations,
    )

    companion object {
        const val STATE_COUNTING = "counting"
        const val STATE_SUSPECT = "suspect"
        const val STATE_STALLED = "stalled"
        const val STATE_UNAVAILABLE = "unavailable"

        /** A checkpoint left by a process that died before its final flush. */
        const val STATE_ENDED_UNFLUSHED = "ended_unflushed"

        const val SENSOR_WAKE_UP = "wake_up"
        const val SENSOR_NON_WAKE_UP = "non_wake_up"

        /** No counter, no permission, or a registration that failed. */
        val UNAVAILABLE = StepCoverage(STATE_UNAVAILABLE, null, null, 0L, null, 0)
    }
}
