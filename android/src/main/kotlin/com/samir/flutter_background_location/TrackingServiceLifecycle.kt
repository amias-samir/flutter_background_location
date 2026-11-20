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

    /** What a boot or package-replaced broadcast does with a persisted route. */
    enum class BootRestore {
        /** No route was capturing; nothing to do. */
        SKIP,

        /** Start the service to resume capture. */
        RESTORE,

        /**
         * The route cannot be captured from the background, so it is marked
         * interrupted instead of starting a service that Android would refuse
         * (API 34+ throws on `startForeground`) or that would receive no fixes.
         */
        INTERRUPT,
    }

    /**
     * A location foreground service started from a boot broadcast runs in the
     * background, so it needs foreground location and, from API 29, background
     * location as well.
     */
    fun bootRestore(
        trackingEnabled: Boolean,
        isPaused: Boolean,
        hasTrackId: Boolean,
        sdkInt: Int,
        hasForegroundLocation: Boolean,
        hasBackgroundLocation: Boolean,
    ): BootRestore {
        if (!trackingEnabled || isPaused || !hasTrackId) return BootRestore.SKIP
        if (!hasForegroundLocation) return BootRestore.INTERRUPT
        if (sdkInt >= API_Q && !hasBackgroundLocation) return BootRestore.INTERRUPT
        return BootRestore.RESTORE
    }

    private const val API_Q = 29
}

/**
 * Retry policy for a failed fused-location request (REL-01). A Play services
 * update or a binder hiccup used to fail the route permanently; transient
 * failures are now retried with backoff and only an exhausted retry ends
 * capture, as a resumable interruption.
 */
internal object ProviderRetryPolicy {
    /** Delays before each retry; about two minutes in total. */
    private val delaysMs = longArrayOf(2_000L, 5_000L, 15_000L, 30_000L, 60_000L)

    val maximumAttempts: Int get() = delaysMs.size

    /**
     * Status codes of `ApiException` that describe a temporary state of Play
     * services rather than a permanent refusal (`CommonStatusCodes` and
     * `ConnectionResult.SERVICE_UPDATING`).
     */
    private val transientStatusCodes = setOf(
        7, // NETWORK_ERROR
        8, // INTERNAL_ERROR
        13, // ERROR
        14, // INTERRUPTED
        15, // TIMEOUT
        17, // API_NOT_CONNECTED
        18, // SERVICE_UPDATING
        19, // REMOTE_EXCEPTION
        20, // CONNECTION_SUSPENDED_DURING_CALL
        21, // RECONNECTION_TIMED_OUT_DURING_UPDATE
        22, // RECONNECTION_TIMED_OUT
    )

    /**
     * Whether a failure may be retried. [statusCode] is the `ApiException`
     * status, or null for any other exception. A revoked permission is never
     * transient.
     */
    fun isTransient(statusCode: Int?, securityFailure: Boolean): Boolean {
        if (securityFailure) return false
        return statusCode == null || statusCode in transientStatusCodes
    }

    /** Delay before retry number [attempt] (from 1), or null when exhausted. */
    fun delayMs(attempt: Int): Long? = delaysMs.getOrNull(attempt - 1)
}
