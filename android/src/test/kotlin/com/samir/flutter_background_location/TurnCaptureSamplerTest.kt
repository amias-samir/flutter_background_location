package com.samir.flutter_background_location

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays the turn-capture fixture shared with Swift. */
class TurnCaptureSamplerTest {
    private val fixture = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("turn_capture_v1.json")) {
            "turn_capture_v1.json is missing from the test resources"
        }.readText(),
    )

    @Test
    fun replaysEveryScenario() {
        val config = fixture.getJSONObject("config")
        val scenarios = fixture.getJSONArray("scenarios")
        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            val sampler = TurnCaptureSampler(
                intervalMs = config.getLong("intervalMs"),
                turnDegrees = config.getDouble("turnDegrees").toFloat(),
                minimumDistanceMeters = config.getDouble("minimumDistanceMeters").toFloat(),
            )
            val fixes = scenario.getJSONArray("fixes")
            val recorded = mutableListOf<Int>()
            for (step in 0 until fixes.length()) {
                val fix = fixes.getJSONObject(step)
                val accepted = sampler.accept(
                    TurnCaptureSampler.Fix(
                        elapsedMs = fix.getLong("t") * 1_000L,
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
        assertTrue(scenarios.length() >= 8)
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
}
