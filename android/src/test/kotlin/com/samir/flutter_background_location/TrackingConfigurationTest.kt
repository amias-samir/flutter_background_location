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
                "stationaryDistanceFilterMeters" to 25,
                "maximumAcceptedAccuracyMeters" to 20,
            ),
        )

        assertEquals("precised", configuration.desiredAccuracy)
        assertEquals(5_000L, configuration.movingIntervalMs)
        assertEquals(5f, configuration.movingDistanceFilterMeters)
        assertEquals(30_000L, configuration.stationaryIntervalMs)
        assertEquals(25f, configuration.stationaryDistanceFilterMeters)
        assertEquals(20.0, configuration.maximumAcceptedAccuracyMeters, 0.0)
    }
}
