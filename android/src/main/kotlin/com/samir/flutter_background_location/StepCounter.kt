package com.samir.flutter_background_location

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener2
import android.hardware.SensorManager
import android.os.Handler
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Steps of one capture generation, from the cumulative hardware step counter
 * (steps since boot, counted while a listener keeps it active).
 *
 * The first reading is the baseline and later readings add their increase.
 * A reading below the previous one, or a rise faster than anyone walks,
 * becomes the new baseline: steps are never invented. Readings of another
 * counter (a sensor variant switch) start a new baseline too, keeping the
 * steps already counted, so two counters' values are never compared.
 *
 * Rises are checked over the readings' own times when the sensor's
 * timestamps are usable, otherwise over delivery times; both are elapsed
 * realtime in milliseconds.
 */
internal class StepCountSession(val generationId: String) {
    enum class Outcome { BASELINE, ROSE, SAME, RESET }

    /** Steps since the baseline; null until the counter first reports. */
    @Volatile
    var steps: Long? = null
        private set

    /** Time of the newest reading, or completed flush, the count accounts for. */
    @Volatile
    var countedThroughMs: Long? = null
        private set

    /** Time of the newest reading that added steps. */
    @Volatile
    var lastRiseMs: Long? = null
        private set

    private var baselinePending = true
    private var lastCounter = 0L
    private var lastDeliveredMs = 0L
    private var lastEventMs: Long? = null

    /** Applies the counter value [counter] delivered at [elapsedMs]. */
    fun onCounter(counter: Long, elapsedMs: Long): Outcome? =
        onCounter(counter, deliveredMs = elapsedMs, eventMs = null)

    /**
     * Applies the counter value [counter] delivered at [deliveredMs]; [eventMs]
     * is the reading's own time when the sensor reports one. A timestamp later
     * than delivery, or not newer than the previous one, is not trusted.
     */
    @Synchronized
    fun onCounter(counter: Long, deliveredMs: Long, eventMs: Long?): Outcome? {
        if (counter < 0L) return null
        val previousEventMs = lastEventMs
        val trustedEventMs = eventMs?.takeIf {
            it <= deliveredMs && (baselinePending || previousEventMs == null || it > previousEventMs)
        }
        val readingMs = trustedEventMs ?: deliveredMs
        val outcome = if (baselinePending) {
            baselinePending = false
            if (steps == null) steps = 0L
            Outcome.BASELINE
        } else {
            val rise = counter - lastCounter
            val elapsedMs = if (trustedEventMs != null && previousEventMs != null) {
                trustedEventMs - previousEventMs
            } else {
                (deliveredMs - lastDeliveredMs).coerceAtLeast(0L)
            }
            val windowMs = elapsedMs + REPORT_LATENCY_SLACK_MS
            when {
                rise == 0L -> Outcome.SAME
                rise > 0L && rise <= windowMs * MAXIMUM_STEPS_PER_SECOND / 1_000L -> {
                    steps = (steps ?: 0L) + rise
                    lastRiseMs = readingMs
                    Outcome.ROSE
                }
                else -> Outcome.RESET
            }
        }
        lastCounter = counter
        lastDeliveredMs = deliveredMs
        if (trustedEventMs != null) lastEventMs = trustedEventMs
        countedThroughMs = maxOf(countedThroughMs ?: readingMs, readingMs)
        return outcome
    }

    /** The next reading comes from another counter: it is a new baseline. */
    @Synchronized
    fun startNewBaseline() {
        baselinePending = true
        lastEventMs = null
    }

    /** Every reading up to [elapsedMs] has arrived (a completed flush). */
    @Synchronized
    fun accountedThrough(elapsedMs: Long) {
        if (steps == null) return
        countedThroughMs = maxOf(countedThroughMs ?: elapsedMs, elapsedMs)
    }

    companion object {
        /** Faster than any running cadence. */
        const val MAXIMUM_STEPS_PER_SECOND = 8L

        /**
         * A batched reading may count steps taken this long before delivery:
         * the 30 s report latency and a margin.
         */
        const val REPORT_LATENCY_SLACK_MS = 35_000L
    }
}

/** A capture generation's steps and their coverage, for checkpoints and finals. */
internal data class StepSnapshot(
    val generationId: String,
    val steps: Long?,
    val coverage: StepCoverage,
)

/** Device state recorded with each step-counter diagnostic. */
internal data class StepCounterEnvironment(
    val wakeLockHeld: Boolean?,
    val screenOn: Boolean?,
    val deviceIdle: Boolean?,
    val standbyBucket: Int?,
)

/** One step-counter diagnostic. No coordinates and no step counts. */
internal data class StepCounterDiagnosticEntry(
    val at: Long,
    val event: String,
    val sensorWakeUp: Boolean?,
    val sensorVendor: String?,
    val sensorName: String?,
    val fifoMax: Int?,
    val fifoReserved: Int?,
    val registered: Boolean,
    val sinceDeliveryMs: Long?,
    val sinceEventMs: Long?,
    val sinceRiseMs: Long?,
    val flushAccepted: Boolean?,
    val flushCompletedMs: Long?,
    val reregistrations: Int,
    val replayOutcome: String?,
    val watchdogState: String,
    val evidenceSource: String?,
    val wakeLockHeld: Boolean?,
    val screenOn: Boolean?,
    val deviceIdle: Boolean?,
    val standbyBucket: Int?,
    val sinceProfileSwitchMs: Long?,
    val sinceExitProbeMs: Long?,
    val sinceSignificantMotionMs: Long?,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "at" to at,
        "event" to event,
        "sensorWakeUp" to sensorWakeUp,
        "sensorVendor" to sensorVendor,
        "sensorName" to sensorName,
        "fifoMax" to fifoMax,
        "fifoReserved" to fifoReserved,
        "registered" to registered,
        "sinceDeliveryMs" to sinceDeliveryMs,
        "sinceEventMs" to sinceEventMs,
        "sinceRiseMs" to sinceRiseMs,
        "flushAccepted" to flushAccepted,
        "flushCompletedMs" to flushCompletedMs,
        "reregistrations" to reregistrations,
        "replayOutcome" to replayOutcome,
        "watchdogState" to watchdogState,
        "evidenceSource" to evidenceSource,
        "wakeLockHeld" to wakeLockHeld,
        "screenOn" to screenOn,
        "deviceIdle" to deviceIdle,
        "standbyBucket" to standbyBucket,
        "sinceProfileSwitchMs" to sinceProfileSwitchMs,
        "sinceExitProbeMs" to sinceExitProbeMs,
        "sinceSignificantMotionMs" to sinceSignificantMotionMs,
    )
}

/** The newest [capacity] diagnostics; process-wide so they outlive the service. */
internal class StepCounterDiagnosticsRing(private val capacity: Int) {
    private val entries = ArrayDeque<StepCounterDiagnosticEntry>()

    @Synchronized
    fun add(entry: StepCounterDiagnosticEntry) {
        entries.addLast(entry)
        while (entries.size > capacity) entries.removeFirst()
    }

    @Synchronized
    fun snapshot(): List<StepCounterDiagnosticEntry> = entries.toList()
}

/**
 * Counts steps while capture is active, in every motion fusion mode.
 *
 * Needs the step counter sensor and, from Android 10, the activity
 * recognition permission; without them nothing is counted and steps stay
 * unmeasured. The wake-up counter is preferred: some non-wake-up counters
 * stopped reporting for good after AP-waking events. Readings are batched for
 * at most [MAXIMUM_REPORT_LATENCY_US]; [flush] delivers a batch early.
 *
 * A [StepCounterWatchdog] checks the counter against motion evidence at every
 * [evaluate] and repairs a silent one: flush, re-register, switch variant.
 * [finalize] delivers the last reading before capture stops.
 *
 * Sensor registration and readings happen on [workerHandler]; the public
 * methods may be called on the main thread. Results are posted to
 * [mainHandler].
 */
internal class StepCounter(
    context: Context,
    private val workerHandler: Handler,
    private val mainHandler: Handler,
    private val environment: () -> StepCounterEnvironment,
) : SensorEventListener2 {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val preferredSensor: Sensor? = preferredSensor(sensors)
    private val alternateSensor: Sensor? = alternateSensor(sensors, preferredSensor)

    @Volatile
    private var session: StepCountSession? = null

    @Volatile
    private var watchdog: StepCounterWatchdog? = null

    /** The registered sensor; null while nothing is registered. */
    @Volatile
    private var activeSensor: Sensor? = null

    @Volatile
    private var reregistrations = 0

    // Worker thread only.
    private var sessionSensor: Sensor? = null
    private val flushWaiters = ArrayList<(Boolean) -> Unit>()
    private val readingWaiters = ArrayList<() -> Unit>()
    private var finalizing = false
    private var lastDeliveryMs: Long? = null
    private var lastEventMs: Long? = null
    private var flushAccepted: Boolean? = null
    private var flushCompletedMs: Long? = null
    private var replayOutcome: String? = null
    private var replayPending = false

    /**
     * Counts [generationId]'s steps; its running session continues, and a
     * registration that failed is tried again.
     */
    fun start(generationId: String, movingConfidenceThreshold: Int) {
        if (preferredSensor == null) return
        workerHandler.post { startOnWorker(generationId, movingConfidenceThreshold) }
    }

    fun stop() {
        workerHandler.post { stopOnWorker() }
    }

    /** [generationId]'s steps; null when they are not counted. */
    fun steps(generationId: String?): Long? =
        session?.takeIf { it.generationId == generationId }?.steps

    /** Whether a session counts [generationId], even while unregistered. */
    fun isCounting(generationId: String?): Boolean =
        generationId != null && session?.generationId == generationId

    /** [generationId]'s coverage; unavailable when nothing counts it. */
    fun coverage(generationId: String?): StepCoverage? {
        generationId ?: return null
        val session = session?.takeIf { it.generationId == generationId }
            ?: return StepCoverage.UNAVAILABLE
        return coverageOf(session)
    }

    /** [generationId]'s steps and coverage now, without a flush. */
    fun snapshot(generationId: String?): StepSnapshot? {
        val session = session?.takeIf { it.generationId == generationId } ?: return null
        return StepSnapshot(session.generationId, session.steps, coverageOf(session))
    }

    fun onActivity(type: String, confidence: Int, observedAtMs: Long) {
        watchdog?.onActivity(type, confidence, observedAtMs)
    }

    fun onFusionStep() {
        watchdog?.onFusionStep(SystemClock.elapsedRealtime())
    }

    fun onSignificantMotion() {
        watchdog?.onSignificantMotion(SystemClock.elapsedRealtime())
    }

    fun onFix(speed: Double?, speedAccuracy: Double?, observedAtMs: Long) {
        watchdog?.onFix(speed, speedAccuracy, observedAtMs)
    }

    fun onProfileSwitch(exitedStationary: Boolean) {
        watchdog?.onProfileSwitch(SystemClock.elapsedRealtime(), exitedStationary)
    }

    fun onExitProbe() {
        watchdog?.onExitProbe(SystemClock.elapsedRealtime())
    }

    /**
     * Delivers batched readings, then runs [then] on the main thread: at once
     * when nothing is counted, and after [FLUSH_TIMEOUT_MS] at the latest.
     */
    fun flush(then: () -> Unit) {
        if (session == null) {
            then()
            return
        }
        val done = AtomicBoolean(false)
        val finish = Runnable { if (done.compareAndSet(false, true)) then() }
        mainHandler.postDelayed(finish, FLUSH_TIMEOUT_MS)
        workerHandler.post { flushOnWorker { mainHandler.post(finish) } }
    }

    /**
     * Checks the counter against the motion evidence and takes at most one
     * repair step; flushes first when [flushFirst], so batched readings count.
     * Posts the generation's snapshot to [onSnapshot] on the main thread.
     */
    fun evaluate(flushFirst: Boolean, onSnapshot: (StepSnapshot) -> Unit) {
        workerHandler.post {
            if (session == null) return@post
            if (flushFirst) {
                flushOnWorker { evaluateOnWorker(onSnapshot) }
            } else {
                evaluateOnWorker(onSnapshot)
            }
        }
    }

    /**
     * Delivers the generation's last reading, then posts its snapshot to
     * [then] on the main thread: a flush of at most [FLUSH_TIMEOUT_MS], then,
     * for a suspect or stalled counter, a re-registration given
     * [FINAL_READING_TIMEOUT_MS] to report. Runs [then] at once with null when
     * nothing is counted.
     */
    fun finalize(then: (StepSnapshot?) -> Unit) {
        if (session == null) {
            then(null)
            return
        }
        workerHandler.post { finalizeOnWorker(then) }
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_STEP_COUNTER || event.values.isEmpty()) return
        val sensor = activeSensor ?: return
        // A reading queued by a registration that was since replaced.
        if (!isSameSensor(event.sensor, sensor)) return
        val session = session ?: return
        val deliveredMs = SystemClock.elapsedRealtime()
        val eventMs = if (event.timestamp > 0L) event.timestamp / 1_000_000L else null
        val outcome = session.onCounter(event.values[0].toLong(), deliveredMs, eventMs) ?: return
        lastDeliveryMs = deliveredMs
        lastEventMs = eventMs
        val watchdog = watchdog
        val before = watchdog?.state
        when (outcome) {
            StepCountSession.Outcome.ROSE -> watchdog?.onRise(session.lastRiseMs ?: deliveredMs)
            StepCountSession.Outcome.RESET -> watchdog?.onBaselineReset()
            else -> Unit
        }
        if (replayPending) {
            replayPending = false
            replayOutcome = if (outcome == StepCountSession.Outcome.ROSE) REPLAY_ROSE else REPLAY_SAME
        }
        releaseReadingWaiters()
        if (watchdog != null && watchdog.state != before) record(EVENT_TRANSITION)
    }

    override fun onFlushCompleted(sensor: Sensor?) = releaseFlushWaiters(completed = true)

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun startOnWorker(generationId: String, movingConfidenceThreshold: Int) {
        val preferred = preferredSensor ?: return
        val current = session
        if (current?.generationId == generationId) {
            watchdog?.movingConfidenceThreshold = movingConfidenceThreshold
            if (activeSensor == null) register(sessionSensor ?: preferred)
            return
        }
        stopOnWorker()
        session = StepCountSession(generationId)
        watchdog = StepCounterWatchdog(
            movingConfidenceThreshold = movingConfidenceThreshold,
            hasAlternateSensor = alternateSensor != null,
        )
        reregistrations = 0
        register(preferred)
    }

    private fun stopOnWorker() {
        if (session == null && activeSensor == null) return
        session = null
        watchdog = null
        sensors.unregisterListener(this)
        activeSensor = null
        sessionSensor = null
        finalizing = false
        lastDeliveryMs = null
        lastEventMs = null
        flushAccepted = null
        flushCompletedMs = null
        replayOutcome = null
        replayPending = false
        releaseFlushWaiters(completed = false)
        releaseReadingWaiters()
    }

    private fun register(sensor: Sensor): Boolean {
        sessionSensor = sensor
        val registered = runCatching {
            sensors.registerListener(
                this,
                sensor,
                SensorManager.SENSOR_DELAY_NORMAL,
                MAXIMUM_REPORT_LATENCY_US,
                workerHandler,
            )
        }.getOrDefault(false)
        activeSensor = if (registered) sensor else null
        if (registered) watchdog?.onRegistered(SystemClock.elapsedRealtime())
        return registered
    }

    /** Registers [sensor] afresh; a silent listener sometimes reports again. */
    private fun reregister(sensor: Sensor, newBaseline: Boolean) {
        replayPending = true
        replayOutcome = null
        sensors.unregisterListener(this)
        activeSensor = null
        reregistrations += 1
        if (newBaseline) {
            session?.startNewBaseline()
            watchdog?.onBaselineReset()
        }
        register(sensor)
    }

    private fun flushOnWorker(onDone: () -> Unit) {
        if (activeSensor == null) {
            onDone()
            return
        }
        val requestedAtMs = SystemClock.elapsedRealtime()
        val accepted = runCatching { sensors.flush(this) }.getOrDefault(false)
        flushAccepted = accepted
        flushCompletedMs = null
        if (!accepted) {
            onDone()
            return
        }
        var finished = false
        val timeout = Runnable {
            if (finished) return@Runnable
            finished = true
            onDone()
        }
        workerHandler.postDelayed(timeout, FLUSH_TIMEOUT_MS)
        flushWaiters += { completed ->
            if (!finished) {
                finished = true
                workerHandler.removeCallbacks(timeout)
                if (completed) {
                    flushCompletedMs = SystemClock.elapsedRealtime() - requestedAtMs
                    // Every reading batched before the flush has arrived; a
                    // suspect counter's silence proves nothing.
                    if (watchdog?.state == StepCounterWatchdog.State.COUNTING) {
                        session?.accountedThrough(requestedAtMs)
                    }
                }
                onDone()
            }
        }
    }

    private fun evaluateOnWorker(onSnapshot: (StepSnapshot) -> Unit) {
        val session = session ?: return
        val watchdog = watchdog ?: return
        if (!finalizing && activeSensor != null) {
            if (replayPending) {
                replayPending = false
                replayOutcome = REPLAY_NONE
            }
            val before = watchdog.state
            val action = watchdog.evaluate(SystemClock.elapsedRealtime())
            record(EVENT_HEARTBEAT)
            if (watchdog.state != before) record(EVENT_TRANSITION)
            perform(action)
        }
        val snapshot = StepSnapshot(session.generationId, session.steps, coverageOf(session))
        mainHandler.post { onSnapshot(snapshot) }
    }

    private fun perform(action: StepCounterWatchdog.Action) {
        val sensor = sessionSensor ?: return
        when (action) {
            StepCounterWatchdog.Action.NONE -> Unit
            StepCounterWatchdog.Action.FLUSH -> {
                replayPending = true
                replayOutcome = null
                flushOnWorker {}
                record(EVENT_FLUSH)
            }
            StepCounterWatchdog.Action.REREGISTER -> {
                reregister(sensor, newBaseline = false)
                record(EVENT_REREGISTER)
            }
            StepCounterWatchdog.Action.SWITCH_SENSOR -> {
                val other = if (sensor === preferredSensor) alternateSensor else preferredSensor
                if (other != null) {
                    reregister(other, newBaseline = true)
                    record(EVENT_SWITCH_VARIANT)
                }
            }
        }
    }

    private fun finalizeOnWorker(then: (StepSnapshot?) -> Unit) {
        val session = session
        if (session == null) {
            mainHandler.post { then(null) }
            return
        }
        finalizing = true
        flushOnWorker {
            val sensor = sessionSensor
            val suspect = watchdog?.state.let {
                it == StepCounterWatchdog.State.SUSPECT || it == StepCounterWatchdog.State.STALLED
            }
            if (this.session === session && suspect && sensor != null) {
                awaitReading(FINAL_READING_TIMEOUT_MS) { finishFinalize(session, then) }
                reregister(sensor, newBaseline = false)
            } else {
                finishFinalize(session, then)
            }
        }
    }

    private fun finishFinalize(session: StepCountSession, then: (StepSnapshot?) -> Unit) {
        if (this.session !== session) {
            mainHandler.post { then(null) }
            return
        }
        finalizing = false
        if (replayPending) {
            replayPending = false
            replayOutcome = REPLAY_NONE
        }
        watchdog?.finish()
        record(EVENT_FINALIZE)
        val snapshot = StepSnapshot(session.generationId, session.steps, coverageOf(session))
        mainHandler.post { then(snapshot) }
    }

    /** Runs [onDone] on the next reading, or after [timeoutMs]. */
    private fun awaitReading(timeoutMs: Long, onDone: () -> Unit) {
        var finished = false
        val timeout = Runnable {
            if (finished) return@Runnable
            finished = true
            onDone()
        }
        workerHandler.postDelayed(timeout, timeoutMs)
        readingWaiters += {
            if (!finished) {
                finished = true
                workerHandler.removeCallbacks(timeout)
                onDone()
            }
        }
    }

    private fun releaseFlushWaiters(completed: Boolean) {
        val waiters = flushWaiters.toList()
        flushWaiters.clear()
        waiters.forEach { it(completed) }
    }

    private fun releaseReadingWaiters() {
        val waiters = readingWaiters.toList()
        readingWaiters.clear()
        waiters.forEach { it() }
    }

    private fun coverageOf(session: StepCountSession): StepCoverage {
        val watchdog = watchdog
        val sensor = activeSensor
        if (watchdog == null || sensor == null) {
            return StepCoverage.UNAVAILABLE.copy(reregistrations = reregistrations)
        }
        return StepCoverage(
            state = watchdog.state.code,
            countedThrough = session.countedThroughMs?.let(::toEpochMs),
            lastRiseAt = session.lastRiseMs?.let(::toEpochMs),
            uncountedMs = watchdog.uncountedMs,
            sensor = sensorCode(sensor),
            reregistrations = reregistrations,
        )
    }

    /** Appends a diagnostic: timings, sensor and device state, no step counts. */
    private fun record(event: String) {
        val nowMs = SystemClock.elapsedRealtime()
        val watchdog = watchdog
        val sensor = activeSensor ?: sessionSensor
        val device = runCatching(environment).getOrNull()
        diagnosticsRing.add(
            StepCounterDiagnosticEntry(
                at = System.currentTimeMillis(),
                event = event,
                sensorWakeUp = sensor?.isWakeUpSensor,
                sensorVendor = sensor?.vendor,
                sensorName = sensor?.name,
                fifoMax = sensor?.fifoMaxEventCount,
                fifoReserved = sensor?.fifoReservedEventCount,
                registered = activeSensor != null,
                sinceDeliveryMs = lastDeliveryMs?.let { nowMs - it },
                sinceEventMs = lastEventMs?.let { nowMs - it },
                sinceRiseMs = session?.lastRiseMs?.let { nowMs - it },
                flushAccepted = flushAccepted,
                flushCompletedMs = flushCompletedMs,
                reregistrations = reregistrations,
                replayOutcome = replayOutcome,
                watchdogState = watchdog?.state?.code ?: StepCoverage.STATE_UNAVAILABLE,
                evidenceSource = watchdog?.lastEvidence?.code,
                wakeLockHeld = device?.wakeLockHeld,
                screenOn = device?.screenOn,
                deviceIdle = device?.deviceIdle,
                standbyBucket = device?.standbyBucket,
                sinceProfileSwitchMs = watchdog?.lastProfileSwitchAtMs?.let { nowMs - it },
                sinceExitProbeMs = watchdog?.lastExitProbeAtMs?.let { nowMs - it },
                sinceSignificantMotionMs = watchdog?.lastSignificantMotionAtMs?.let { nowMs - it },
            ),
        )
    }

    companion object {
        const val MAXIMUM_REPORT_LATENCY_US = 30_000_000
        const val FLUSH_TIMEOUT_MS = 500L
        const val FINAL_READING_TIMEOUT_MS = 500L
        const val DIAGNOSTICS_CAPACITY = 512

        private const val EVENT_HEARTBEAT = "heartbeat"
        private const val EVENT_TRANSITION = "transition"
        private const val EVENT_FLUSH = "flush"
        private const val EVENT_REREGISTER = "reregister"
        private const val EVENT_SWITCH_VARIANT = "switch_variant"
        private const val EVENT_FINALIZE = "finalize"
        private const val REPLAY_ROSE = "rose"
        private const val REPLAY_SAME = "same"
        private const val REPLAY_NONE = "none"

        private val diagnosticsRing = StepCounterDiagnosticsRing(DIAGNOSTICS_CAPACITY)

        fun isAvailable(context: Context): Boolean =
            preferredSensor(context.getSystemService(Context.SENSOR_SERVICE) as SensorManager) != null

        /** The newest diagnostics, oldest first. */
        fun diagnostics(): List<Map<String, Any?>> = diagnosticsRing.snapshot().map { it.toMap() }

        private fun preferredSensor(sensors: SensorManager): Sensor? =
            sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER, true)
                ?: sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)

        /** The other variant of the counter, when the device has both. */
        private fun alternateSensor(sensors: SensorManager, preferred: Sensor?): Sensor? {
            preferred ?: return null
            return sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER, !preferred.isWakeUpSensor)
                ?.takeUnless { it === preferred }
        }

        private fun isSameSensor(candidate: Sensor, active: Sensor): Boolean =
            candidate === active || (
                candidate.isWakeUpSensor == active.isWakeUpSensor &&
                    candidate.name == active.name &&
                    candidate.vendor == active.vendor
                )

        private fun sensorCode(sensor: Sensor): String =
            if (sensor.isWakeUpSensor) StepCoverage.SENSOR_WAKE_UP else StepCoverage.SENSOR_NON_WAKE_UP

        private fun toEpochMs(elapsedMs: Long): Long =
            System.currentTimeMillis() - (SystemClock.elapsedRealtime() - elapsedMs)
    }
}
