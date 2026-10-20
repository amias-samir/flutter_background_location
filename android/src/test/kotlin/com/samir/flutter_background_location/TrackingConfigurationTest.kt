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
}
