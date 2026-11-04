package com.samir.flutter_background_location

import kotlin.math.roundToLong
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays the turn-capture fixtures shared with Swift. */
class TurnCaptureSamplerTest {
    private fun fixture(name: String) = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource(name)) {
            "$name is missing from the test resources"
        }.readText(),
    )

    @Test
    fun replaysEveryScenario() {
        assertTrue(replay(fixture("turn_capture_v1.json")) >= 8)
    }

    @Test
    fun replaysEverySamplingPolicyTwoScenario() {
        val fixture = fixture("turn_capture_v2.json")
        assertEquals(2, fixture.getInt("version"))
        assertTrue(replay(fixture) >= 11)
    }

    /** Replays [fixture]'s scenarios; a scenario's config overrides the shared one. */
    private fun replay(fixture: JSONObject): Int {
        val shared = fixture.getJSONObject("config")
        val scenarios = fixture.getJSONArray("scenarios")
        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            val config = scenario.optJSONObject("config")
            fun setting(key: String): Double =
                if (config != null && config.has(key)) config.getDouble(key) else shared.getDouble(key)
            val sampler = TurnCaptureSampler(
                intervalMs = setting("intervalMs").toLong(),
                turnDegrees = setting("turnDegrees").toFloat(),
                minimumDistanceMeters = setting("minimumDistanceMeters").toFloat(),
            )
            val fixes = scenario.getJSONArray("fixes")
            val recorded = mutableListOf<Int>()
            for (step in 0 until fixes.length()) {
                val fix = fixes.getJSONObject(step)
                val accepted = sampler.accept(
                    TurnCaptureSampler.Fix(
                        elapsedMs = (fix.getDouble("t") * 1_000.0).roundToLong(),
                        latitude = fix.getDouble("latitude"),
                        longitude = fix.getDouble("longitude"),
                        speedMetersPerSecond = fix.optDouble("speed", Double.NaN)
                            .takeUnless { it.isNaN() }?.toFloat(),
                        bearingDegrees = fix.optDouble("bearing", Double.NaN)
                            .takeUnless { it.isNaN() }?.toFloat(),
                        bearingAccuracyDegrees = fix.optDouble("bearingAccuracy", Double.NaN)
                            .takeUnless { it.isNaN() }?.toFloat(),
                    ),
                )
                if (accepted) recorded += step
            }
            val expected = scenario.getJSONArray("recorded")
            assertEquals(
                scenario.getString("name"),
                (0 until expected.length()).map { expected.getInt(it) },
                recorded,
            )
        }
        return scenarios.length()
    }

    @Test
    fun anglesWrapAroundNorth() {
        assertEquals(20f, TurnCaptureSampler.angleBetween(10f, 350f), 0.001f)
        assertEquals(20f, TurnCaptureSampler.angleBetween(350f, 10f), 0.001f)
        assertEquals(180f, TurnCaptureSampler.angleBetween(0f, 180f), 0.001f)
    }

    @Test
    fun anExternallyRecordedFixBecomesTheReference() {
        val sampler = TurnCaptureSampler(5_000L, 45f, 5f)
        val start = TurnCaptureSampler.Fix(0L, 0.5, 0.5, 10f, 0f, 5f)
        sampler.record(start)
        // One second later, 10 m north: neither interval nor turn.
        assertEquals(
            false,
            sampler.accept(TurnCaptureSampler.Fix(1_000L, 0.50009, 0.5, 10f, 0f, 5f)),
        )
    }

    @Test
    fun zeroDegreesNeverRecordsATurn() {
        val sampler = TurnCaptureSampler(5_000L, 0f, 0f)
        assertEquals(true, sampler.accept(TurnCaptureSampler.Fix(0L, 0.5, 0.5, 10f, 0f, 5f)))
        // A sharp, reliable turn one second later is left to the interval.
        assertEquals(
            false,
            sampler.accept(TurnCaptureSampler.Fix(1_000L, 0.50009, 0.5, 10f, 90f, 5f)),
        )
        assertEquals(
            true,
            sampler.accept(TurnCaptureSampler.Fix(4_600L, 0.5004, 0.5, 10f, 90f, 5f)),
        )
    }
}
