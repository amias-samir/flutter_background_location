package com.samir.flutter_background_location

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackingServiceLifecycleTest {
    @Test
    fun `service remains started only during active capture`() {
        assertTrue(
            TrackingServiceLifecycle.shouldRemainStarted(
                captureStarted = true,
                trackingEnabled = true,
                isPaused = false,
                hasTrackId = true,
            ),
        )

        assertFalse(
            TrackingServiceLifecycle.shouldRemainStarted(
                captureStarted = false,
                trackingEnabled = true,
                isPaused = false,
                hasTrackId = true,
            ),
        )
        assertFalse(
            TrackingServiceLifecycle.shouldRemainStarted(
                captureStarted = false,
                trackingEnabled = false,
                isPaused = true,
                hasTrackId = true,
            ),
        )
        assertFalse(
            TrackingServiceLifecycle.shouldRemainStarted(
                captureStarted = false,
                trackingEnabled = false,
                isPaused = false,
                hasTrackId = false,
            ),
        )
    }
}
