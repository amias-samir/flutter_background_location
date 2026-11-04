package com.samir.flutter_background_location

import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Motion policy 2 for adaptive capture: when the moving request may relax to
 * the stationary profile, and when it must return.
 *
 * Mirrors Dart `MotionPolicyV2` and `MotionGate`; the shared fixture
 * `motion_policy_v2.json` keeps the Dart, Kotlin and Swift state machines in
 * step. Pure Kotlin, confined to the service's main thread.
 *
 * A still episode starts with confident still evidence and survives unknown,
 * tilting and low-confidence readings and silence: Google pauses Activity
 * Recognition while a device stays still. It ends on positive moving
 * evidence, a clearly measured Doppler speed, or sustained displacement, so
 * one optimistic indoor fix can't end a stop.
 */
internal class StationaryPolicyV2(
    private val stationaryConfidenceThreshold: Int,
    private val movingConfidenceThreshold: Int,
    private val movingConfirmationCount: Int,
    private val confirmationMs: Long,
    private val maximumAcceptedAccuracyMeters: Double,
) {
    enum class Profile { MOVING, STATIONARY }

    /** One activity reading; [type] uses the native activity names. */
    data class Reading(
        val type: String,
        val confidence: Int,
        val recordedAtMs: Long,
        val source: String,
    )

    /** One journaled provider fix. */
    data class Fix(
        val latitude: Double,
        val longitude: Double,
        val accuracyMeters: Double?,
        val speed: Double?,
        val speedAccuracy: Double?,
        val hasVerticalAccuracy: Boolean,
        val mocked: Boolean,
        val observedAtMs: Long,
    )

    private data class Evidence(
        val latitude: Double,
        val longitude: Double,
        val sigmaMeters: Double,
        val observedAtMs: Long,
    )

    var profile: Profile = Profile.MOVING
        private set

    /** Why [profile] last changed, one of the `REASON_` codes. */
    var lastTransitionReason: String? = null
        private set

    /** Whether a still episode is current. */
    val stillEpisodeActive: Boolean
        get() = episodeStartedAtMs != null

    private var candidateSinceMs: Long? = null
    private var episodeStartedAtMs: Long? = null
    private var endedAtMs: Long? = null
    private var movingRun = 0
    private val lastReadingAt = HashMap<String, Long>()
    private val window = ArrayDeque<Evidence>()
    private var lastEvidence: Evidence? = null
    private var anchor: Evidence? = null

    // After an entry without fixes: the first fix after the silence, waiting
    // for a second one that agrees before it can anchor the stop.
    private var pendingAnchor: Evidence? = null
    private var outsideSinceMs: Long? = null
    private var outsideFarthestMeters = 0.0

    fun onReading(reading: Reading, nowMs: Long): Profile {
        val previous = lastReadingAt[reading.source]
        if (previous != null && reading.recordedAtMs <= previous) return evaluate(nowMs)
        lastReadingAt[reading.source] = reading.recordedAtMs
        // Readings older than the last departure must not reopen the stop.
        val ended = endedAtMs
        if (ended != null && reading.recordedAtMs <= ended) return evaluate(nowMs)

        if (reading.source == TRANSITION_SOURCE) {
            return when {
                reading.type == STATIONARY && reading.confidence <= 0 ->
                    endEpisode(reading.recordedAtMs, REASON_TRANSITION_EXIT)
                reading.type in MOVING_TYPES && reading.confidence >= 100 ->
                    endEpisode(reading.recordedAtMs, REASON_MOVING_TRANSITION)
                reading.type == STATIONARY && reading.confidence >= 100 -> {
                    movingRun = 0
                    val since = candidateSinceMs ?: reading.recordedAtMs
                    candidateSinceMs = since
                    if (episodeStartedAtMs == null) episodeStartedAtMs = since
                    evaluate(nowMs)
                }
                // EXIT transitions of moving activities are not still evidence.
                else -> evaluate(nowMs)
            }
        }

        if (isMovingReading(reading)) {
            movingRun += 1
            return if (movingRun >= max(movingConfirmationCount, MOVING_CONFIRMATION_READINGS)) {
                endEpisode(reading.recordedAtMs, REASON_MOVING_READINGS)
            } else {
                evaluate(nowMs)
            }
        }
        // Any other reading interrupts a run of moving readings; unknown,
        // tilting and low-confidence readings are otherwise neutral.
        movingRun = 0
        if (reading.type == STATIONARY && reading.confidence >= stationaryConfidenceThreshold) {
            if (candidateSinceMs == null) candidateSinceMs = reading.recordedAtMs
        }
        return evaluate(nowMs)
    }

    /** Fused sensor evidence of movement, such as a step cadence. */
    fun onMovingEvidence(nowMs: Long): Profile = endEpisode(nowMs, REASON_MOVING_EVIDENCE)

    /** The activity source or its permission failed; fail open to moving. */
    fun onActivityUnavailable(nowMs: Long): Profile =
        endEpisode(nowMs, REASON_ACTIVITY_UNAVAILABLE)

    fun onFix(fix: Fix): Profile {
        val evidence = evidenceOf(fix)
        if (evidence != null) lastEvidence = evidence
        if (profile == Profile.STATIONARY) {
            if (evidence == null) return profile
            val reference = anchor
            when {
                reference != null -> checkDeparture(reference, evidence, fix)
                // Without an anchor only a measured speed can end the stop.
                dopplerConfirmsDeparture(fix.speed, fix.speedAccuracy) ->
                    endEpisode(fix.observedAtMs, REASON_DOPPLER)
                else -> anchorFrom(evidence)
            }
            return profile
        }
        if (evidence != null) window.addLast(evidence)
        return evaluate(fix.observedAtMs)
    }

    /** Advances time-based rules: episode promotion and stationary entry. */
    fun evaluate(nowMs: Long): Profile {
        while (window.isNotEmpty() && nowMs - window.first().observedAtMs > confirmationMs) {
            window.removeFirst()
        }
        val candidate = candidateSinceMs ?: return profile
        if (episodeStartedAtMs == null && nowMs - candidate >= STILL_EPISODE_MINIMUM_SPAN_MS) {
            episodeStartedAtMs = candidate
        }
        if (profile != Profile.MOVING || episodeStartedAtMs == null) return profile
        if (nowMs - candidate < confirmationMs) return profile
        val recent = window.filter { it.observedAtMs >= candidate }
        if (recent.isEmpty()) {
            // A still phone under the moving distance filter may deliver no fix
            // at all; the absence of movement is the evidence.
            if (nowMs - candidate >= ENTRY_WITHOUT_FIXES_MS) {
                enterStationary(
                    lastEvidence?.takeIf { it.observedAtMs >= candidate },
                    REASON_ENTRY_WITHOUT_FIXES,
                )
            }
        } else {
            val centre = centroid(recent)
            val consistent = recent.all { fix ->
                distanceMeters(centre, fix) <=
                    max(ENTRY_CONSISTENCY_FLOOR_METERS, ENTRY_CONSISTENCY_SIGMA_FACTOR * fix.sigmaMeters)
            }
            if (consistent) enterStationary(centre, REASON_STILL_EPISODE)
        }
        return profile
    }

    private fun checkDeparture(reference: Evidence, evidence: Evidence, fix: Fix) {
        val distance = distanceMeters(reference, evidence)
        val radius = holdRadiusMeters(reference.sigmaMeters, evidence.sigmaMeters)
        if (distance <= radius) {
            outsideSinceMs = null
            outsideFarthestMeters = 0.0
            return
        }
        if (dopplerConfirmsDeparture(fix.speed, fix.speedAccuracy)) {
            endEpisode(fix.observedAtMs, REASON_DOPPLER)
            return
        }
        val since = outsideSinceMs ?: fix.observedAtMs.also { outsideSinceMs = it }
        val sustained = fix.observedAtMs - since >= SUSTAINED_OUTSIDE_MS &&
            distance >= outsideFarthestMeters &&
            distance >= SUSTAINED_OUTSIDE_RADIUS_FACTOR * radius
        outsideFarthestMeters = max(outsideFarthestMeters, distance)
        if (sustained) endEpisode(fix.observedAtMs, REASON_SUSTAINED_DISPLACEMENT)
    }

    /**
     * Anchors a stop entered without fixes. The first fix after a long silence
     * is often a re-acquisition outlier tens of metres off, so two fixes must
     * agree within the hold radius; a lone disagreeing fix is replaced.
     */
    private fun anchorFrom(evidence: Evidence) {
        val pending = pendingAnchor
        if (pending != null &&
            distanceMeters(pending, evidence) <=
            holdRadiusMeters(pending.sigmaMeters, evidence.sigmaMeters)
        ) {
            anchor = centroid(listOf(pending, evidence))
            pendingAnchor = null
        } else {
            pendingAnchor = evidence
        }
    }

    private fun enterStationary(reference: Evidence?, reason: String) {
        profile = Profile.STATIONARY
        lastTransitionReason = reason
        anchor = reference
        pendingAnchor = null
        outsideSinceMs = null
        outsideFarthestMeters = 0.0
    }

    private fun endEpisode(atMs: Long, reason: String): Profile {
        if (profile == Profile.STATIONARY) lastTransitionReason = reason
        episodeStartedAtMs = null
        candidateSinceMs = null
        movingRun = 0
        endedAtMs = atMs
        window.clear()
        anchor = null
        pendingAnchor = null
        outsideSinceMs = null
        outsideFarthestMeters = 0.0
        profile = Profile.MOVING
        return profile
    }

    private fun isMovingReading(reading: Reading): Boolean {
        if (reading.type !in MOVING_TYPES) return false
        val threshold = if (reading.type == AUTOMOTIVE) {
            max(movingConfidenceThreshold, VEHICLE_CONFIDENCE_THRESHOLD)
        } else {
            movingConfidenceThreshold
        }
        return reading.confidence >= threshold
    }

    private fun evidenceOf(fix: Fix): Evidence? {
        val accuracy = fix.accuracyMeters ?: return null
        if (fix.mocked || !accuracy.isFinite() || accuracy <= 0.0) return null
        if (accuracy > max(maximumAcceptedAccuracyMeters, ENTRY_MAXIMUM_ACCURACY_METERS)) return null
        return Evidence(
            fix.latitude,
            fix.longitude,
            sigmaMeters(accuracy, fix.speedAccuracy != null, fix.hasVerticalAccuracy),
            fix.observedAtMs,
        )
    }

    internal companion object {
        /** Motion policy implemented here, checked by the quality ledger. */
        const val MOTION_POLICY_VERSION = 2

        const val TRANSITION_SOURCE = "android_activity_transition"
        const val STATIONARY = "stationary"
        const val AUTOMOTIVE = "automotive"
        val MOVING_TYPES = setOf("walking", "running", "cycling", AUTOMOTIVE)

        const val STILL_EPISODE_MINIMUM_SPAN_MS = 30_000L
        const val MOVING_CONFIRMATION_READINGS = 2
        const val VEHICLE_CONFIDENCE_THRESHOLD = 75
        const val HOLD_RADIUS_FLOOR_METERS = 25.0
        const val HOLD_CHI_SQUARE = 9.21
        const val DEPARTURE_SPEED_METERS_PER_SECOND = 1.2
        const val DEPARTURE_SPEED_ACCURACY_FACTOR = 2.0
        const val SUSTAINED_OUTSIDE_MS = 60_000L
        const val SUSTAINED_OUTSIDE_RADIUS_FACTOR = 2.0
        const val ENTRY_CONSISTENCY_FLOOR_METERS = 25.0
        const val ENTRY_CONSISTENCY_SIGMA_FACTOR = 3.0
        const val ENTRY_WITHOUT_FIXES_MS = 180_000L
        const val ENTRY_MAXIMUM_ACCURACY_METERS = 50.0

        // Coordinate-free reasons for a profile change, reported in status.
        const val REASON_STILL_EPISODE = "still_episode"
        const val REASON_ENTRY_WITHOUT_FIXES = "entry_without_fixes"
        const val REASON_MOVING_READINGS = "moving_readings"
        const val REASON_MOVING_TRANSITION = "moving_transition"
        const val REASON_TRANSITION_EXIT = "transition_exit"
        const val REASON_MOVING_EVIDENCE = "moving_evidence"
        const val REASON_DOPPLER = "doppler"
        const val REASON_SUSTAINED_DISPLACEMENT = "sustained_displacement"
        const val REASON_ACTIVITY_UNAVAILABLE = "activity_unavailable"

        // Uncertainty model v1, mirrored from Dart `UncertaintyModel`.
        private const val MINIMUM_SIGMA_METERS = 1.5
        private const val RADIUS_PER_SIGMA = 1.51
        private const val MAXIMUM_GNSS_ACCURACY_METERS = 25.0
        private const val EARTH_RADIUS_METERS = 6_371_008.8

        fun sigmaMeters(
            accuracyMeters: Double,
            hasSpeedAccuracy: Boolean,
            hasVerticalAccuracy: Boolean,
        ): Double {
            val originFactor = when {
                hasSpeedAccuracy && hasVerticalAccuracy &&
                    accuracyMeters <= MAXIMUM_GNSS_ACCURACY_METERS -> 1.0
                !hasSpeedAccuracy && !hasVerticalAccuracy -> 1.8
                else -> 1.2
            }
            return max(MINIMUM_SIGMA_METERS, accuracyMeters / RADIUS_PER_SIGMA) * originFactor
        }

        fun holdRadiusMeters(anchorSigmaMeters: Double, fixSigmaMeters: Double): Double = max(
            HOLD_RADIUS_FLOOR_METERS,
            sqrt(
                HOLD_CHI_SQUARE *
                    (anchorSigmaMeters * anchorSigmaMeters + fixSigmaMeters * fixSigmaMeters),
            ),
        )

        fun dopplerConfirmsDeparture(speed: Double?, speedAccuracy: Double?): Boolean {
            if (speed == null || speedAccuracy == null) return false
            if (!speed.isFinite() || !speedAccuracy.isFinite() || speedAccuracy < 0.0) return false
            return speed >= max(
                DEPARTURE_SPEED_METERS_PER_SECOND,
                DEPARTURE_SPEED_ACCURACY_FACTOR * speedAccuracy,
            )
        }

        private fun centroid(fixes: List<Evidence>): Evidence {
            val latitudes = fixes.map { it.latitude }.sorted()
            val longitudes = fixes.map { it.longitude }.sorted()
            val sigmas = fixes.map { it.sigmaMeters }.sorted()
            return Evidence(
                median(latitudes),
                median(longitudes),
                median(sigmas),
                fixes.maxOf { it.observedAtMs },
            )
        }

        private fun median(sorted: List<Double>): Double {
            val middle = sorted.size / 2
            return if (sorted.size % 2 == 1) {
                sorted[middle]
            } else {
                (sorted[middle - 1] + sorted[middle]) / 2.0
            }
        }

        private fun distanceMeters(from: Evidence, to: Evidence): Double {
            val phi1 = Math.toRadians(from.latitude)
            val phi2 = Math.toRadians(to.latitude)
            val deltaPhi = phi2 - phi1
            val deltaLambda = Math.toRadians(to.longitude - from.longitude)
            val h = sin(deltaPhi / 2) * sin(deltaPhi / 2) +
                cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
            return 2 * EARTH_RADIUS_METERS * asin(min(1.0, sqrt(h)))
        }
    }
}
