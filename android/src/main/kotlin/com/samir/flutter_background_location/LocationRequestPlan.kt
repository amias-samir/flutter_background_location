package com.samir.flutter_background_location

import com.google.android.gms.location.Granularity
import com.google.android.gms.location.Priority

/**
 * The provider request and fix sampler for one capture profile. Decided from
 * the profile, the configuration and the battery state alone, so the service
 * only turns it into a `LocationRequest`.
 *
 * Sampling policy 1 is the request routes used before policy 2. Policy 2
 * (`samplingPolicyVersion` 2) changes only the high-accuracy moving profile
 * with an interval above one second: an unfiltered 1 Hz stream, sampled to
 * one fix per interval or a turn whatever the distance moved, so walking,
 * standing and driving all record at the interval. The stationary profile and
 * the balanced and low-power accuracies keep policy 1.
 */
internal data class LocationRequestPlan(
    val priority: Int,
    val providerIntervalMs: Long,
    val minUpdateIntervalMs: Long,
    val maxUpdateDelayMs: Long,
    val maxUpdateAgeMs: Long,
    val minUpdateDistanceMeters: Float,
    val granularity: Int,
    val waitForAccurateLocation: Boolean,
    /** Chooses the stream fixes to record; null records every fix. */
    val sampler: Sampler?,
) {
    data class Sampler(
        val intervalMs: Long,
        val turnDegrees: Float,
        val minimumDistanceMeters: Float,
    ) {
        fun create(): TurnCaptureSampler =
            TurnCaptureSampler(intervalMs, turnDegrees, minimumDistanceMeters)
    }

    companion object {
        fun forProfile(
            profile: String,
            configuration: TrackingConfiguration,
            batteryLow: Boolean,
        ): LocationRequestPlan {
            val stationary = profile == TrackingStateStore.PROFILE_STATIONARY
            val priority = priorityFor(configuration.desiredAccuracy)
            val movingInterval = configuration.movingIntervalMs
            if (configuration.usesSamplingPolicyV2 && !stationary &&
                priority == Priority.PRIORITY_HIGH_ACCURACY &&
                movingInterval > TurnCaptureSampler.PROVIDER_INTERVAL_MS
            ) {
                // Every provider fix reaches the sampler and the stationary
                // policy; the distance filter only qualifies turns.
                return LocationRequestPlan(
                    priority = priority,
                    providerIntervalMs = TurnCaptureSampler.PROVIDER_INTERVAL_MS,
                    minUpdateIntervalMs = TurnCaptureSampler.PROVIDER_INTERVAL_MS,
                    maxUpdateDelayMs = movingInterval,
                    maxUpdateAgeMs = 0L,
                    minUpdateDistanceMeters = 0f,
                    granularity = Granularity.GRANULARITY_FINE,
                    waitForAccurateLocation = true,
                    sampler = Sampler(
                        intervalMs = movingInterval,
                        turnDegrees = configuration.turnCaptureDegrees,
                        minimumDistanceMeters = configuration.movingDistanceFilterMeters,
                    ),
                )
            }
            return policyOne(stationary, priority, configuration, batteryLow)
        }

        fun priorityFor(desiredAccuracy: String): Int = when (desiredAccuracy.lowercase()) {
            "best", "high", "navigation", "precise", "precised" ->
                Priority.PRIORITY_HIGH_ACCURACY
            "low", "lowpower", "low_power" -> Priority.PRIORITY_LOW_POWER
            "passive" -> Priority.PRIORITY_PASSIVE
            else -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
        }

        private fun policyOne(
            stationary: Boolean,
            priority: Int,
            configuration: TrackingConfiguration,
            batteryLow: Boolean,
        ): LocationRequestPlan {
            val interval = if (stationary) {
                configuration.stationaryIntervalMs
            } else {
                configuration.movingIntervalMs
            }
            val distance = if (stationary) {
                configuration.stationaryDistanceFilterMeters
            } else {
                configuration.movingDistanceFilterMeters
            }
            val highFidelity = !stationary &&
                (priority == Priority.PRIORITY_HIGH_ACCURACY ||
                    configuration.captureIntent != "adaptive")
            // Turn capture asks for a fix every second, batched up to the moving
            // interval where the device supports it, and records the regular
            // fixes and those where the course turns sharply.
            val captureTurns = !stationary &&
                priority == Priority.PRIORITY_HIGH_ACCURACY &&
                configuration.capturesTurns &&
                interval > TurnCaptureSampler.PROVIDER_INTERVAL_MS
            val providerInterval =
                if (captureTurns) TurnCaptureSampler.PROVIDER_INTERVAL_MS else interval
            return LocationRequestPlan(
                priority = priority,
                providerIntervalMs = providerInterval,
                minUpdateIntervalMs =
                    if (captureTurns) providerInterval else (interval / 2L).coerceAtLeast(1_000L),
                // Live walking capture must not be hidden in a long provider batch,
                // and on a low battery a batch could die with the phone.
                maxUpdateDelayMs = if (highFidelity || batteryLow) interval else (interval * 2L),
                // Never satisfy a new high-fidelity request with a cached fix.
                maxUpdateAgeMs = if (highFidelity) 0L else interval,
                minUpdateDistanceMeters = distance,
                granularity = if (highFidelity) {
                    Granularity.GRANULARITY_FINE
                } else {
                    Granularity.GRANULARITY_PERMISSION_LEVEL
                },
                waitForAccurateLocation = highFidelity,
                sampler = if (captureTurns) {
                    Sampler(
                        intervalMs = interval,
                        turnDegrees = configuration.turnCaptureDegrees,
                        minimumDistanceMeters = distance,
                    )
                } else {
                    null
                },
            )
        }
    }
}
