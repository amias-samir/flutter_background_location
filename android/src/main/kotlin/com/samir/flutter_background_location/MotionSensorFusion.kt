package com.samir.flutter_background_location

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.TriggerEvent
import android.hardware.TriggerEventListener
import android.os.Handler
import android.os.SystemClock
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Active-capture-only motion collector.
 *
 * Continuous sensor values are reduced to one bounded feature window on the
 * service worker thread. Raw vectors never leave this class.
 */
internal class MotionSensorFusion(
    context: Context,
    private val workerHandler: Handler,
    private val onDecision: (Map<String, Any?>) -> Unit,
) : SensorEventListener {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var configuration = TrackingConfiguration()
    private var active = false
    private var generation = 0L
    private var probeActive = false
    private var probeStartedElapsed = 0L
    private var lastProbeCompletedElapsed = Long.MIN_VALUE
    private var probeDurationUsedInWindow = 0L
    private var probeDutyWindowStartedElapsed = 0L
    private var accelerationSamples = 0
    private var accelerationSquaredSum = 0.0
    private var gyroscopeSamples = 0
    private var gyroscopeSquaredSum = 0.0
    private var rotationVectorAvailable = false
    private var stepSensor: Sensor? = null
    private var accelerationSensor: Sensor? = null
    private var gyroscopeSensor: Sensor? = null
    private var rotationVectorSensor: Sensor? = null
    private var significantMotionSensor: Sensor? = null
    private var probeStationaryCandidate = false
    private val finishProbe = Runnable { finishProbe() }

    private val significantMotionListener = object : TriggerEventListener() {
        override fun onTrigger(event: TriggerEvent?) {
            if (!active) return
            emit(
                state = "moving",
                confidence = 85,
                supporting = listOf("significantMotion"),
                reason = "significant_motion",
                significantMotion = true,
            )
            armSignificantMotion()
        }
    }

    fun start(configuration: TrackingConfiguration) {
        stop()
        this.configuration = configuration
        active = true
        generation += 1L
        if (configuration.motionFusionMode == MODE_PLATFORM_ACTIVITY_ONLY) {
            emitUnavailable("sensor_fusion_disabled")
            return
        }
        stepSensor = sensors.getDefaultSensor(Sensor.TYPE_STEP_DETECTOR)
        significantMotionSensor = sensors.getDefaultSensor(Sensor.TYPE_SIGNIFICANT_MOTION)
        stepSensor?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL, workerHandler)
        }
        armSignificantMotion()
        emit(
            state = "unknown",
            confidence = 0,
            supporting = emptyList(),
            reason = if (stepSensor == null && significantMotionSensor == null) {
                "low_power_sensors_unavailable"
            } else {
                "sensor_fusion_ready"
            },
        )
    }

    fun stop() {
        active = false
        generation += 1L
        workerHandler.removeCallbacks(finishProbe)
        sensors.unregisterListener(this)
        significantMotionSensor?.let {
            sensors.cancelTriggerSensor(significantMotionListener, it)
        }
        probeActive = false
        stepSensor = null
        accelerationSensor = null
        gyroscopeSensor = null
        rotationVectorSensor = null
        significantMotionSensor = null
        resetProbeFeatures()
    }

    /** Starts one ambiguity probe if enhanced mode, cooldown, and duty allow. */
    fun requestAmbiguityProbe(stationaryCandidate: Boolean = false): Boolean {
        if (!active ||
            configuration.motionFusionMode != MODE_ENHANCED_SENSOR_FUSION ||
            probeActive
        ) {
            return false
        }
        val now = SystemClock.elapsedRealtime()
        if (lastProbeCompletedElapsed != Long.MIN_VALUE &&
            now - lastProbeCompletedElapsed < configuration.sensorProbeCooldownMs
        ) {
            return false
        }
        if (probeDutyWindowStartedElapsed == 0L ||
            now - probeDutyWindowStartedElapsed >= ONE_HOUR_MS
        ) {
            probeDutyWindowStartedElapsed = now
            probeDurationUsedInWindow = 0L
        }
        if (probeDurationUsedInWindow + configuration.sensorProbeDurationMs >
            configuration.sensorProbeMaximumDurationPerHourMs
        ) {
            return false
        }

        accelerationSensor = sensors.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyroscopeSensor = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        rotationVectorSensor = sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (accelerationSensor == null && gyroscopeSensor == null) {
            emitUnavailable("continuous_motion_sensors_unavailable")
            return false
        }
        resetProbeFeatures()
        probeStationaryCandidate = stationaryCandidate
        probeActive = true
        probeStartedElapsed = now
        accelerationSensor?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME, workerHandler)
        }
        gyroscopeSensor?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME, workerHandler)
        }
        rotationVectorSensor?.let {
            sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL, workerHandler)
        }
        workerHandler.postDelayed(finishProbe, configuration.sensorProbeDurationMs)
        return true
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (!active) return
        when (event.sensor.type) {
            Sensor.TYPE_STEP_DETECTOR -> emit(
                state = "moving",
                confidence = 95,
                supporting = listOf("step"),
                reason = "fresh_step",
                stepDetected = true,
            )

            Sensor.TYPE_LINEAR_ACCELERATION -> if (probeActive) {
                accumulateAcceleration(event.values, removeGravity = false)
            }

            Sensor.TYPE_ACCELEROMETER -> if (probeActive) {
                accumulateAcceleration(event.values, removeGravity = true)
            }

            Sensor.TYPE_GYROSCOPE -> if (probeActive) {
                val magnitude = vectorMagnitude(event.values)
                gyroscopeSamples += 1
                gyroscopeSquaredSum += magnitude * magnitude
            }

            Sensor.TYPE_ROTATION_VECTOR -> if (probeActive) {
                rotationVectorAvailable = true
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun accumulateAcceleration(values: FloatArray, removeGravity: Boolean) {
        var magnitude = vectorMagnitude(values)
        if (removeGravity) magnitude = abs(magnitude - SensorManager.GRAVITY_EARTH)
        accelerationSamples += 1
        accelerationSquaredSum += magnitude * magnitude
    }

    private fun finishProbe() {
        if (!probeActive) return
        probeActive = false
        accelerationSensor?.let { sensors.unregisterListener(this, it) }
        gyroscopeSensor?.let { sensors.unregisterListener(this, it) }
        rotationVectorSensor?.let { sensors.unregisterListener(this, it) }
        val now = SystemClock.elapsedRealtime()
        val duration = (now - probeStartedElapsed).coerceAtLeast(0L)
        probeDurationUsedInWindow += duration
        lastProbeCompletedElapsed = now
        val accelerationEnergy = rootMeanSquare(accelerationSquaredSum, accelerationSamples)
        val rotationEnergy = rootMeanSquare(gyroscopeSquaredSum, gyroscopeSamples)
        val quiet = probeStationaryCandidate &&
            accelerationSamples > 0 && accelerationEnergy < 0.18 &&
            (gyroscopeSamples == 0 || rotationEnergy < 0.20)
        emit(
            state = if (quiet) "stationary" else "unknown",
            confidence = if (quiet) 80 else 0,
            supporting = if (quiet) listOf("accelerometer", "gyroscope") else emptyList(),
            conflicting = buildList {
                if (accelerationEnergy >= 0.35) add("accelerometer")
                if (rotationEnergy >= 0.50) add("gyroscope")
            },
            reason = if (quiet) "bounded_probe_quiet" else "bounded_probe_ambiguous",
            sensorProbeUsed = true,
            extra = mapOf(
                "probeDurationMs" to duration,
                "accelerometerSampleCount" to accelerationSamples,
                "accelerationMotionEnergy" to accelerationEnergy,
                "gyroscopeSampleCount" to gyroscopeSamples,
                "rotationEnergy" to rotationEnergy,
                "compassAvailable" to rotationVectorAvailable,
                "probeDutyUsedMs" to probeDurationUsedInWindow,
            ),
        )
        resetProbeFeatures()
    }

    private fun armSignificantMotion() {
        val sensor = significantMotionSensor ?: return
        if (active) sensors.requestTriggerSensor(significantMotionListener, sensor)
    }

    private fun emitUnavailable(reason: String) {
        emit(
            state = "unknown",
            confidence = 0,
            supporting = emptyList(),
            reason = reason,
            extra = mapOf(
                "stepDetectorAvailable" to (stepSensor != null),
                "significantMotionAvailable" to (significantMotionSensor != null),
            ),
        )
    }

    private fun emit(
        state: String,
        confidence: Int,
        supporting: List<String>,
        reason: String,
        conflicting: List<String> = emptyList(),
        stepDetected: Boolean = false,
        significantMotion: Boolean = false,
        sensorProbeUsed: Boolean = false,
        extra: Map<String, Any?> = emptyMap(),
    ) {
        if (!active) return
        onDecision(
            linkedMapOf<String, Any?>(
                "state" to state,
                "confidence" to confidence.coerceIn(0, 100),
                "observedAt" to System.currentTimeMillis(),
                "supportingSources" to supporting,
                "conflictingSources" to conflicting,
                "stepDetected" to stepDetected,
                "significantMotionDetected" to significantMotion,
                "sensorProbeUsed" to sensorProbeUsed,
                "policyVersion" to POLICY_VERSION,
                "reason" to reason,
                "generation" to generation,
            ).apply { putAll(extra) },
        )
    }

    private fun resetProbeFeatures() {
        accelerationSamples = 0
        accelerationSquaredSum = 0.0
        gyroscopeSamples = 0
        gyroscopeSquaredSum = 0.0
        rotationVectorAvailable = false
        probeStationaryCandidate = false
    }

    private fun vectorMagnitude(values: FloatArray): Double {
        var sum = 0.0
        for (index in 0 until minOf(3, values.size)) {
            sum += values[index] * values[index]
        }
        return sqrt(sum)
    }

    private fun rootMeanSquare(sum: Double, count: Int): Double =
        if (count <= 0) 0.0 else sqrt(sum / count)

    companion object {
        private const val POLICY_VERSION = 1
        private const val ONE_HOUR_MS = 3_600_000L
        private const val MODE_PLATFORM_ACTIVITY_ONLY = "platformActivityOnly"
        private const val MODE_ENHANCED_SENSOR_FUSION = "enhancedSensorFusion"
    }
}
