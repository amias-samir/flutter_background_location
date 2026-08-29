package com.samir.flutter_background_location

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

internal data class StationaryGpsFix(
    val latitude: Double,
    val longitude: Double,
    val observedAtMs: Long,
    val horizontalAccuracyMeters: Double = 0.0,
)

/**
 * Maintains a rolling GPS evidence window for stationary-mode entry.
 *
 * Activity Recognition is only a hint. A transition is allowed only when at
 * least two fixes cover the full confirmation interval and every pair of fixes
 * in that interval remains within the configured displacement radius.
 */
internal class StationaryDisplacementWindow {
    private var stillStartedAtMs: Long? = null
    private val fixes = mutableListOf<StationaryGpsFix>()

    fun begin(startedAtMs: Long, baseline: StationaryGpsFix? = null) {
        stillStartedAtMs = startedAtMs
        fixes.clear()
        baseline?.let {
            add(
                it.copy(observedAtMs = it.observedAtMs.coerceAtLeast(startedAtMs)),
                confirmationMs = Long.MAX_VALUE,
            )
        }
    }

    fun reset() {
        stillStartedAtMs = null
        fixes.clear()
    }

    fun add(fix: StationaryGpsFix, confirmationMs: Long) {
        val startedAt = stillStartedAtMs ?: return
        if (fix.observedAtMs < startedAt) return

        fixes += fix
        fixes.sortBy(StationaryGpsFix::observedAtMs)
        prune(fix.observedAtMs, confirmationMs.coerceAtLeast(0L), startedAt)
    }

    fun hasLowDisplacement(
        confirmationMs: Long,
        maximumDisplacementMeters: Float,
    ): Boolean {
        val startedAt = stillStartedAtMs ?: return false
        if (fixes.size < MINIMUM_FIX_COUNT) return false

        val duration = confirmationMs.coerceAtLeast(0L)
        val latest = fixes.last()
        if (latest.observedAtMs - startedAt < duration) return false

        val targetStart = latest.observedAtMs - duration
        val anchorIndex = if (duration == 0L) {
            0
        } else {
            fixes.indexOfLast { it.observedAtMs <= targetStart }
        }
        if (anchorIndex < 0 || fixes.size - anchorIndex < MINIMUM_FIX_COUNT) return false

        val limit = maximumDisplacementMeters.coerceAtLeast(0f).toDouble()
        for (firstIndex in anchorIndex until fixes.lastIndex) {
            for (secondIndex in firstIndex + 1..fixes.lastIndex) {
                val maximumPlausibleDisplacement =
                    distanceMeters(fixes[firstIndex], fixes[secondIndex]) +
                        fixes[firstIndex].horizontalAccuracyMeters.coerceAtLeast(0.0) +
                        fixes[secondIndex].horizontalAccuracyMeters.coerceAtLeast(0.0)
                if (maximumPlausibleDisplacement > limit) {
                    return false
                }
            }
        }
        return true
    }

    private fun prune(newestAtMs: Long, confirmationMs: Long, startedAtMs: Long) {
        if (confirmationMs == Long.MAX_VALUE || fixes.size < 3) return
        val cutoff = maxOf(startedAtMs, newestAtMs - confirmationMs)
        val anchorIndex = fixes.indexOfLast { it.observedAtMs <= cutoff }
        if (anchorIndex > 0) fixes.subList(0, anchorIndex).clear()
    }

    private fun distanceMeters(first: StationaryGpsFix, second: StationaryGpsFix): Double {
        val latitudeDelta = Math.toRadians(second.latitude - first.latitude)
        val longitudeDelta = Math.toRadians(second.longitude - first.longitude)
        val firstLatitude = Math.toRadians(first.latitude)
        val secondLatitude = Math.toRadians(second.latitude)
        val haversine = sin(latitudeDelta / 2.0) * sin(latitudeDelta / 2.0) +
            cos(firstLatitude) * cos(secondLatitude) *
            sin(longitudeDelta / 2.0) * sin(longitudeDelta / 2.0)
        val angularDistance = 2.0 * atan2(
            sqrt(haversine.coerceIn(0.0, 1.0)),
            sqrt((1.0 - haversine).coerceIn(0.0, 1.0)),
        )
        return EARTH_RADIUS_METERS * angularDistance
    }

    companion object {
        private const val MINIMUM_FIX_COUNT = 2
        private const val EARTH_RADIUS_METERS = 6_371_000.0
    }
}
