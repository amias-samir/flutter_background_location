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
 * becomes the new baseline: steps are never invented.
 */
internal class StepCountSession(val generationId: String) {
    /** Steps since the baseline; null until the counter first reports. */
    @Volatile
    var steps: Long? = null
        private set
    private var lastCounter = 0L
    private var lastElapsedMs = 0L

    /** Applies the counter value [counter] delivered at [elapsedMs]. */
    fun onCounter(counter: Long, elapsedMs: Long) {
        if (counter < 0L) return
        val counted = steps
        if (counted == null) {
            steps = 0L
        } else {
            val rise = counter - lastCounter
            val windowMs = (elapsedMs - lastElapsedMs).coerceAtLeast(0L) +
                REPORT_LATENCY_SLACK_MS
            if (rise > 0L && rise <= windowMs * MAXIMUM_STEPS_PER_SECOND / 1_000L) {
                steps = counted + rise
            }
        }
        lastCounter = counter
        lastElapsedMs = elapsedMs
    }

    companion object {
        /** Faster than any running cadence. */
        const val MAXIMUM_STEPS_PER_SECOND = 8L

        /** A batched reading may count steps taken this long before delivery. */
        const val REPORT_LATENCY_SLACK_MS = 15_000L
    }
}

/**
 * Counts steps while capture is active, in every motion fusion mode.
 *
 * Needs the step counter sensor and, from Android 10, the activity
 * recognition permission; without them nothing is counted and steps stay
 * unmeasured. The sensor is non-wake-up and batches its readings for at most
 * [MAXIMUM_REPORT_LATENCY_US]; [flush] delivers a batch early. Readings
 * arrive on [workerHandler]; [start], [stop] and [flush] are called on the
 * main thread.
 */
internal class StepCounter(
    context: Context,
    private val workerHandler: Handler,
    private val mainHandler: Handler,
) : SensorEventListener2 {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val sensor: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)

    @Volatile
    private var session: StepCountSession? = null
    private var failedGenerationId: String? = null

    // Worker thread only.
    private val flushWaiters = ArrayList<() -> Unit>()

    /** Starts counting [generationId]'s steps; its running session continues. */
    fun start(generationId: String) {
        val sensor = sensor ?: return
        if (session?.generationId == generationId || failedGenerationId == generationId) return
        stop()
        session = StepCountSession(generationId)
        val registered = sensors.registerListener(
            this,
            sensor,
            SensorManager.SENSOR_DELAY_NORMAL,
            MAXIMUM_REPORT_LATENCY_US,
            workerHandler,
        )
        if (!registered) {
            session = null
            failedGenerationId = generationId
        }
    }

    fun stop() {
        failedGenerationId = null
        if (session == null) return
        session = null
        sensors.unregisterListener(this)
        workerHandler.post { releaseFlushWaiters() }
    }

    /** [generationId]'s steps; null when they are not counted. */
    fun steps(generationId: String?): Long? =
        session?.takeIf { it.generationId == generationId }?.steps

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
        workerHandler.post {
            if (session == null || !sensors.flush(this)) {
                mainHandler.post(finish)
            } else {
                flushWaiters += { mainHandler.post(finish) }
            }
        }
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_STEP_COUNTER || event.values.isEmpty()) return
        session?.onCounter(event.values[0].toLong(), SystemClock.elapsedRealtime())
    }

    override fun onFlushCompleted(sensor: Sensor?) = releaseFlushWaiters()

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun releaseFlushWaiters() {
        val waiters = flushWaiters.toList()
        flushWaiters.clear()
        waiters.forEach { it() }
    }

    companion object {
        const val MAXIMUM_REPORT_LATENCY_US = 10_000_000
        const val FLUSH_TIMEOUT_MS = 500L

        fun isAvailable(context: Context): Boolean =
            (context.getSystemService(Context.SENSOR_SERVICE) as SensorManager)
                .getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null
    }
}
