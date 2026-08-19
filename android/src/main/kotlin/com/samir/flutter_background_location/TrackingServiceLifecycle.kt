package com.samir.flutter_background_location

/** Pure lifecycle policy shared by service restart and task-removal handling. */
internal object TrackingServiceLifecycle {
    fun shouldRemainStarted(
        captureStarted: Boolean,
        trackingEnabled: Boolean,
        isPaused: Boolean,
        hasTrackId: Boolean,
    ): Boolean =
        captureStarted && trackingEnabled && !isPaused && hasTrackId
}
