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
                "maximumAcceptedAccuracyMeters" to 10,
            ),
        )

        assertEquals("precised", configuration.desiredAccuracy)
        assertEquals(5_000L, configuration.movingIntervalMs)
        assertEquals(5f, configuration.movingDistanceFilterMeters)
        assertEquals(30_000L, configuration.stationaryIntervalMs)
        assertEquals(15f, configuration.stationaryDistanceFilterMeters)
        assertEquals(10.0, configuration.maximumAcceptedAccuracyMeters, 0.0)
    }

    @Test
    fun `native fallback matches the public default high profile`() {
        val configuration = TrackingConfiguration.fromMap(null)

        assertEquals("precised", configuration.desiredAccuracy)
        assertEquals(10_000L, configuration.movingIntervalMs)
        assertEquals(5f, configuration.movingDistanceFilterMeters)
        assertEquals(30_000L, configuration.stationaryIntervalMs)
        assertEquals(25f, configuration.stationaryDistanceFilterMeters)
        assertEquals(20.0, configuration.maximumAcceptedAccuracyMeters, 0.0)
    }
}
