package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureContinuityTest {
    @Test
    fun providerFixIdentityIsStableWithinGeneration() {
        val first = NativeLocationFixIdentity.eventId(
            captureGenerationId = "generation-a",
            provider = "fused",
            providerTimestampMs = 1_000L,
            elapsedRealtimeNanos = 2_000L,
            latitude = 27.0,
            longitude = 85.0,
        )
        val duplicate = NativeLocationFixIdentity.eventId(
            captureGenerationId = "generation-a",
            provider = "fused",
            providerTimestampMs = 1_000L,
            elapsedRealtimeNanos = 2_000L,
            latitude = 27.0,
            longitude = 85.0,
        )
        val resumed = NativeLocationFixIdentity.eventId(
            captureGenerationId = "generation-b",
            provider = "fused",
            providerTimestampMs = 1_000L,
            elapsedRealtimeNanos = 2_000L,
            latitude = 27.0,
            longitude = 85.0,
        )

        assertEquals(first, duplicate)
        assertNotEquals(first, resumed)
    }

    @Test
    fun recentFixDeduplicatorIsBoundedAndResettable() {
        val deduplicator = RecentFixDeduplicator(capacity = 2)

        assertTrue(deduplicator.accept("a"))
        assertFalse(deduplicator.accept("a"))
        assertTrue(deduplicator.accept("b"))
        assertTrue(deduplicator.accept("c"))
        assertTrue(deduplicator.accept("a"))
        deduplicator.clear()
        assertTrue(deduplicator.accept("a"))
    }

    @Test
    fun stationaryExitProbeCompletesOnlyOnce() {
        val coordinator = StationaryExitProbeCoordinator()
        val token = coordinator.begin()

        assertTrue(coordinator.beginCurrentFixRequest(token))
        assertFalse(coordinator.beginCurrentFixRequest(token))
        assertTrue(coordinator.complete(token))
        assertFalse(coordinator.complete(token))

        val next = coordinator.begin()
        assertNotEquals(token, next)
        assertFalse(coordinator.complete(token))
        assertTrue(coordinator.complete(next))
    }
}
