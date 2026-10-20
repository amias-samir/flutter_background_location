package com.samir.flutter_background_location

import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Chooses the provider fixes a moving profile records: one per interval, and
 * one wherever the course has turned sharply since the last recorded fix, so
 * a junction or hairpin is not cut between fixes tens of metres apart.
 *
 * Shared with the Swift `TurnCaptureSampler` through
 * `test/fixtures/cross_language/turn_capture_v1.json`. The provider stream and
 * other capture origins call it from different threads.
 */
internal class TurnCaptureSampler(
    private val intervalMs: Long,
    private val turnDegrees: Float,
    private val minimumDistanceMeters: Float,
) {
    data class Fix(
        val elapsedMs: Long,
        val latitude: Double,
        val longitude: Double,
        val speedMetersPerSecond: Float?,
        val bearingDegrees: Float?,
        val bearingAccuracyDegrees: Float?,
    )

    private var lastRecorded: Fix? = null

    /** Course of the newest recorded fix that had a reliable one. */
    private var referenceCourse: Float? = null

    /** Whether to record [fix]; a recorded fix becomes the reference. */
    @Synchronized
    fun accept(fix: Fix): Boolean {
        val recorded = shouldRecord(fix)
        if (recorded) record(fix)
        return recorded
    }

    /** Whether [fix] meets the interval or turns, without recording it. */
    @Synchronized
    fun shouldRecord(fix: Fix): Boolean {
        val previous = lastRecorded ?: return true
        return fix.elapsedMs - previous.elapsedMs >= intervalMs - INTERVAL_TOLERANCE_MS ||
            isTurn(fix, previous)
    }

    /** Takes [fix], recorded for another reason, as the reference. */
    @Synchronized
    fun record(fix: Fix) {
        lastRecorded = fix
        reliableCourse(fix)?.let { referenceCourse = it }
    }

    private fun isTurn(fix: Fix, previous: Fix): Boolean {
        if (fix.elapsedMs <= previous.elapsedMs) return false
        val course = reliableCourse(fix) ?: return false
        val reference = referenceCourse ?: return false
        if (distanceMeters(previous, fix) < minimumDistanceMeters) return false
        return angleBetween(course, reference) >= turnDegrees
    }

    companion object {
        /** Slower fixes have no course worth a turn: walking turns are left to the interval. */
        const val MINIMUM_SPEED_METERS_PER_SECOND = 3f

        /** A course reported less precisely than this is not trusted for turns. */
        const val MAXIMUM_BEARING_ACCURACY_DEGREES = 30f

        /** Provider timestamps jitter; a fix this early still meets the interval. */
        const val INTERVAL_TOLERANCE_MS = 500L

        /** Provider interval the moving profile requests while it captures turns. */
        const val PROVIDER_INTERVAL_MS = 1_000L

        fun reliableCourse(fix: Fix): Float? {
            val speed = fix.speedMetersPerSecond ?: return null
            val bearing = fix.bearingDegrees ?: return null
            if (!speed.isFinite() || speed < MINIMUM_SPEED_METERS_PER_SECOND) return null
            if (!bearing.isFinite()) return null
            val accuracy = fix.bearingAccuracyDegrees
            if (accuracy != null && (!accuracy.isFinite() || accuracy > MAXIMUM_BEARING_ACCURACY_DEGREES)) {
                return null
            }
            return bearing
        }

        /** Smallest angle between two courses, in degrees. */
        fun angleBetween(first: Float, second: Float): Float =
            abs((((first - second) % 360f) + 540f) % 360f - 180f)

        fun distanceMeters(from: Fix, to: Fix): Double {
            val phi1 = Math.toRadians(from.latitude)
            val phi2 = Math.toRadians(to.latitude)
            val deltaPhi = phi2 - phi1
            val deltaLambda = Math.toRadians(to.longitude - from.longitude)
            val h = sin(deltaPhi / 2) * sin(deltaPhi / 2) +
                cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
            return 2 * EARTH_RADIUS_METERS * asin(min(1.0, sqrt(h)))
        }

        private const val EARTH_RADIUS_METERS = 6_371_008.8
    }
}
