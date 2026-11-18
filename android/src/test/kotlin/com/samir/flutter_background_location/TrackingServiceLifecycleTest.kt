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

class BootRestoreDecisionTest {
    private fun decide(
        trackingEnabled: Boolean = true,
        isPaused: Boolean = false,
        hasTrackId: Boolean = true,
        sdkInt: Int = 34,
        foreground: Boolean = true,
        background: Boolean = true,
    ) = TrackingServiceLifecycle.bootRestore(
        trackingEnabled = trackingEnabled,
        isPaused = isPaused,
        hasTrackId = hasTrackId,
        sdkInt = sdkInt,
        hasForegroundLocation = foreground,
        hasBackgroundLocation = background,
    )

    @Test
    fun `only a capturing route is restored`() {
        org.junit.Assert.assertEquals(TrackingServiceLifecycle.BootRestore.RESTORE, decide())
        org.junit.Assert.assertEquals(
            TrackingServiceLifecycle.BootRestore.SKIP,
            decide(trackingEnabled = false),
        )
        org.junit.Assert.assertEquals(TrackingServiceLifecycle.BootRestore.SKIP, decide(isPaused = true))
        org.junit.Assert.assertEquals(TrackingServiceLifecycle.BootRestore.SKIP, decide(hasTrackId = false))
    }

    @Test
    fun `while-in-use permission interrupts instead of starting from boot`() {
        org.junit.Assert.assertEquals(
            TrackingServiceLifecycle.BootRestore.INTERRUPT,
            decide(sdkInt = 34, background = false),
        )
        org.junit.Assert.assertEquals(
            TrackingServiceLifecycle.BootRestore.INTERRUPT,
            decide(sdkInt = 29, background = false),
        )
        org.junit.Assert.assertEquals(
            TrackingServiceLifecycle.BootRestore.RESTORE,
            decide(sdkInt = 28, background = false),
        )
        org.junit.Assert.assertEquals(
            TrackingServiceLifecycle.BootRestore.INTERRUPT,
            decide(foreground = false),
        )
    }
}

class ProviderRetryPolicyTest {
    @Test
    fun `play services updates and binder failures are retried`() {
        assertTrue(ProviderRetryPolicy.isTransient(statusCode = 18, securityFailure = false))
        assertTrue(ProviderRetryPolicy.isTransient(statusCode = 17, securityFailure = false))
        assertTrue(ProviderRetryPolicy.isTransient(statusCode = 8, securityFailure = false))
        assertTrue(ProviderRetryPolicy.isTransient(statusCode = null, securityFailure = false))
    }

    @Test
    fun `permanent refusals and revoked permission are not retried`() {
        assertFalse(ProviderRetryPolicy.isTransient(statusCode = 10, securityFailure = false))
        assertFalse(ProviderRetryPolicy.isTransient(statusCode = 16, securityFailure = false))
        assertFalse(ProviderRetryPolicy.isTransient(statusCode = null, securityFailure = true))
    }

    @Test
    fun `retries back off and end after about two minutes`() {
        var total = 0L
        for (attempt in 1..ProviderRetryPolicy.maximumAttempts) {
            val delay = ProviderRetryPolicy.delayMs(attempt)
            org.junit.Assert.assertNotNull(delay)
            total += delay!!
        }
        org.junit.Assert.assertNull(ProviderRetryPolicy.delayMs(ProviderRetryPolicy.maximumAttempts + 1))
        assertTrue(total in 90_000L..150_000L)
    }
}
