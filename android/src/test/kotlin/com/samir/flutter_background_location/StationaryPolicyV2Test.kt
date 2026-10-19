package com.samir.flutter_background_location

import kotlin.math.PI
import kotlin.math.cos
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays the motion-policy-2 fixture shared with Dart and Swift. */
class StationaryPolicyV2Test {
    private val fixture = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("motion_policy_v2.json")) {
            "motion_policy_v2.json is missing from the test resources"
        }.readText(),
    )

    @Test
    fun replaysEveryAndroidScenario() {
        val config = fixture.getJSONObject("config")
        val origin = fixture.getJSONObject("origin")
        val originLatitude = origin.getDouble("latitude")
        val originLongitude = origin.getDouble("longitude")
        val start = 1_792_000_000_000L
        val scenarios = fixture.getJSONArray("scenarios")
        var replayed = 0
        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            val platforms = scenario.getJSONArray("platforms")
            if ((0 until platforms.length()).none { platforms.getString(it) == "android" }) continue
            val name = scenario.getString("name")
            val policy = StationaryPolicyV2(
                stationaryConfidenceThreshold = config.getInt("stationaryConfidenceThreshold"),
                movingConfidenceThreshold = config.getInt("movingConfidenceThreshold"),
                movingConfirmationCount = config.getInt("movingConfirmationCount"),
                confirmationMs = config.getLong("confirmationSeconds") * 1_000L,
                maximumAcceptedAccuracyMeters = config.getDouble("maximumAcceptedAccuracyMeters"),
            )
            val steps = scenario.getJSONArray("steps")
            for (stepIndex in 0 until steps.length()) {
                val step = steps.getJSONObject(stepIndex)
                val atMs = start + step.getLong("t") * 1_000L
                when {
                    step.has("reading") -> {
                        val reading = step.getJSONObject("reading")
                        policy.onReading(
                            StationaryPolicyV2.Reading(
                                nativeType(reading.getString("type")),
                                reading.getInt("confidence"),
                                atMs,
                                reading.getString("source"),
                            ),
                            atMs,
                        )
                    }
                    step.has("fix") -> {
                        val fix = step.getJSONObject("fix")
                        val metersPerDegree = 111_195.07973436875
                        policy.onFix(
                            StationaryPolicyV2.Fix(
                                latitude = originLatitude + fix.getDouble("north") / metersPerDegree,
                                longitude = originLongitude + fix.getDouble("east") /
                                    (metersPerDegree * cos(originLatitude * PI / 180.0)),
                                accuracyMeters = fix.optNullableDouble("accuracy"),
                                speed = fix.optNullableDouble("speed"),
                                speedAccuracy = fix.optNullableDouble("speedAccuracy"),
                                hasVerticalAccuracy = fix.getBoolean("vertical"),
                                mocked = false,
                                observedAtMs = atMs,
                            ),
                        )
                    }
                    else -> policy.evaluate(atMs)
                }
                val expectation = step.optJSONObject("expect") ?: continue
                val where = "$name at t=${step.getLong("t")}"
                if (expectation.has("episode")) {
                    assertEquals(where, expectation.getBoolean("episode"), policy.stillEpisodeActive)
                }
                if (expectation.has("profile")) {
                    val expected = when (expectation.getString("profile")) {
                        "stationary" -> StationaryPolicyV2.Profile.STATIONARY
                        else -> StationaryPolicyV2.Profile.MOVING
                    }
                    assertEquals(where, expected, policy.profile)
                }
            }
            replayed += 1
        }
        assertTrue("no Android scenario replayed", replayed >= 10)
    }

    @Test
    fun configurationWithoutTheKeyKeepsTheLegacyPolicy() {
        val legacy = TrackingConfiguration.fromMap(mapOf("captureIntent" to "adaptive"))
        assertEquals(TrackingConfiguration.LEGACY_MOTION_POLICY_VERSION, legacy.motionPolicyVersion)
        assertFalse(legacy.usesStationaryPolicyV2)

        val current = TrackingConfiguration.fromMap(
            mapOf("captureIntent" to "adaptive", "motionPolicyVersion" to 2),
        )
        assertTrue(current.usesStationaryPolicyV2)
        assertEquals(2, TrackingConfiguration.fromJson(current.toJson()).motionPolicyVersion)

        val newer = TrackingConfiguration.fromMap(mapOf("motionPolicyVersion" to 9))
        assertEquals(TrackingConfiguration.CURRENT_MOTION_POLICY_VERSION, newer.motionPolicyVersion)

        val explicit = TrackingConfiguration.fromMap(
            mapOf("captureIntent" to "walking", "motionPolicyVersion" to 2),
        )
        assertFalse(explicit.usesStationaryPolicyV2)
    }

    @Test
    fun dopplerConfirmsOnlyClearlyMeasuredSpeeds() {
        assertTrue(StationaryPolicyV2.dopplerConfirmsDeparture(3.4, 1.2))
        assertFalse(StationaryPolicyV2.dopplerConfirmsDeparture(1.7, 5.9))
        assertFalse(StationaryPolicyV2.dopplerConfirmsDeparture(1.1, 0.2))
        assertFalse(StationaryPolicyV2.dopplerConfirmsDeparture(null, 0.2))
        assertEquals(25.0, StationaryPolicyV2.holdRadiusMeters(2.0, 2.0), 1e-9)
    }

    @Test
    fun reportsWhyTheProfileChanged() {
        val policy = StationaryPolicyV2(
            stationaryConfidenceThreshold = 75,
            movingConfidenceThreshold = 60,
            movingConfirmationCount = 1,
            confirmationMs = 90_000L,
            maximumAcceptedAccuracyMeters = 20.0,
        )
        val start = 1_792_000_000_000L
        val source = "android_activity_recognition"
        policy.onReading(StationaryPolicyV2.Reading("stationary", 100, start, source), start)
        policy.onReading(
            StationaryPolicyV2.Reading("stationary", 99, start + 30_000L, source),
            start + 30_000L,
        )
        assertEquals(StationaryPolicyV2.Profile.STATIONARY, policy.evaluate(start + 180_000L))
        assertEquals(StationaryPolicyV2.REASON_ENTRY_WITHOUT_FIXES, policy.lastTransitionReason)

        policy.onFix(
            StationaryPolicyV2.Fix(
                latitude = 0.5,
                longitude = 0.5,
                accuracyMeters = 2.0,
                speed = 3.4,
                speedAccuracy = 1.2,
                hasVerticalAccuracy = true,
                mocked = false,
                observedAtMs = start + 600_000L,
            ),
        )
        assertEquals(StationaryPolicyV2.Profile.MOVING, policy.profile)
        assertEquals(StationaryPolicyV2.REASON_DOPPLER, policy.lastTransitionReason)
    }

    private fun nativeType(value: String): String = when (value) {
        "in_vehicle" -> "automotive"
        "on_bicycle" -> "cycling"
        else -> value
    }

    private fun JSONObject.optNullableDouble(key: String): Double? =
        if (isNull(key)) null else getDouble(key)
}
