package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Test

class TrackingConfigurationTest {
    @Test
    fun `desired accuracy from Dart is preserved for native priority selection`() {
        val configuration = TrackingConfiguration.fromMap(
            mapOf(
                "desiredAccuracy" to "precised",
                "movingIntervalMs" to 5_000,
                "movingDistanceFilterMeters" to 5,
                "stationaryIntervalMs" to 30_000,
                "stationaryDistanceFilterMeters" to 15,
                "maximumAcceptedAccuracyMeters" to 15,
            ),
        )

        assertEquals("precised", configuration.desiredAccuracy)
        assertEquals(5_000L, configuration.movingIntervalMs)
        assertEquals(5f, configuration.movingDistanceFilterMeters)
        assertEquals(30_000L, configuration.stationaryIntervalMs)
        assertEquals(15f, configuration.stationaryDistanceFilterMeters)
        assertEquals(15.0, configuration.maximumAcceptedAccuracyMeters, 0.0)
    }

    @Test
    fun `native fallback matches the public default high profile`() {
        val configuration = TrackingConfiguration.fromMap(null)

        assertEquals("precised", configuration.desiredAccuracy)
        assertEquals(5_000L, configuration.movingIntervalMs)
        assertEquals(5f, configuration.movingDistanceFilterMeters)
        assertEquals(20_000L, configuration.stationaryIntervalMs)
        assertEquals(20f, configuration.stationaryDistanceFilterMeters)
        assertEquals(5_000L, configuration.activityRecognitionIntervalMs)
        assertEquals(30_000L, configuration.activityFreshnessThresholdMs)
        assertEquals(30_000L, configuration.motionEvidenceFreshnessMs)
        assertEquals(20.0, configuration.maximumAcceptedAccuracyMeters, 0.0)
    }

    @Test
    fun `turn capture is parsed, persisted and off for older configurations`() {
        val configuration = TrackingConfiguration.fromMap(mapOf("turnCaptureDegrees" to 45.0))
        assertEquals(45f, configuration.turnCaptureDegrees)
        assertEquals(true, configuration.capturesTurns)
        assertEquals(
            45f,
            TrackingConfiguration.fromJson(configuration.toJson()).turnCaptureDegrees,
        )

        // Stored before the key existed: the route keeps its sampling.
        val legacy = TrackingConfiguration.fromMap(mapOf("movingIntervalMs" to 5_000L))
        assertEquals(0f, legacy.turnCaptureDegrees)
        assertEquals(false, legacy.capturesTurns)

        assertEquals(
            180f,
            TrackingConfiguration.fromMap(mapOf("turnCaptureDegrees" to 400.0)).turnCaptureDegrees,
        )
        assertEquals(
            0f,
            TrackingConfiguration.fromMap(mapOf("turnCaptureDegrees" to -5.0)).turnCaptureDegrees,
        )
    }

    @Test
    fun `sampling policy defaults to 1 and a custom version is parsed and persisted`() {
        assertEquals(1, TrackingConfiguration().samplingPolicyVersion)
        assertEquals(1, TrackingConfiguration.fromMap(null).samplingPolicyVersion)
        assertEquals(false, TrackingConfiguration.fromMap(null).usesSamplingPolicyV2)

        val custom = TrackingConfiguration.fromMap(mapOf("samplingPolicyVersion" to 2))
        assertEquals(2, custom.samplingPolicyVersion)
        assertEquals(true, custom.usesSamplingPolicyV2)
        // Resume and recovery read the persisted JSON.
        assertEquals(2, TrackingConfiguration.fromJson(custom.toJson()).samplingPolicyVersion)
        assertEquals(1, TrackingConfiguration.fromJson(TrackingConfiguration().toJson()).samplingPolicyVersion)
    }

    @Test
    fun `an invalid sampling policy keeps today's sampling and a newer one falls back`() {
        listOf<Any>(0, -3, "2", 1.0).forEach { value ->
            assertEquals(
                value.toString(),
                1,
                TrackingConfiguration.fromMap(mapOf("samplingPolicyVersion" to value)).samplingPolicyVersion,
            )
        }
        assertEquals(
            TrackingConfiguration.CURRENT_SAMPLING_POLICY_VERSION,
            TrackingConfiguration.fromMap(mapOf("samplingPolicyVersion" to 7)).samplingPolicyVersion,
        )
    }

    @Test
    fun `a configuration persisted before sampling policy 2 resumes with policy 1`() {
        // A stored configuration from the previous release has no key.
        val legacyJson = """
            {"movingIntervalMs":5000,"movingDistanceFilterMeters":5.0,
             "desiredAccuracy":"precised","turnCaptureDegrees":45.0,"motionPolicyVersion":2}
        """.trimIndent()
        val legacy = TrackingConfiguration.fromJson(legacyJson)
        assertEquals(1, legacy.samplingPolicyVersion)
        assertEquals(45f, legacy.turnCaptureDegrees)
        assertEquals(2, legacy.motionPolicyVersion)
    }
}
