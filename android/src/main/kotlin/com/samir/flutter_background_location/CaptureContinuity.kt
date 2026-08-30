package com.samir.flutter_background_location

import java.util.UUID

/** Durable identity for one uninterrupted native capture generation. */
internal data class CaptureSessionEvidence(
    val generationId: String,
    val startedAt: Long,
    val startReason: String,
) {
    init {
        require(generationId.isNotBlank()) { "Capture generation ID must not be blank." }
        require(startedAt > 0L) { "Native session start time must be positive." }
        require(startReason.isNotBlank()) { "Capture start reason must not be blank." }
    }

    companion object {
        fun create(
            startReason: String,
            startedAt: Long = System.currentTimeMillis(),
            generationId: String = UUID.randomUUID().toString(),
        ): CaptureSessionEvidence = CaptureSessionEvidence(
            generationId = generationId,
            startedAt = startedAt,
            startReason = startReason,
        )
    }
}

/**
 * Produces the same opaque event ID when Fused Location delivers one provider
 * fix through overlapping subscriptions, a batch flush, and getCurrentLocation.
 */
internal object NativeLocationFixIdentity {
    fun eventId(
        captureGenerationId: String,
        provider: String?,
        providerTimestampMs: Long,
        elapsedRealtimeNanos: Long,
        latitude: Double,
        longitude: Double,
    ): String {
        require(captureGenerationId.isNotBlank())
        val providerIdentity = provider.orEmpty()
        val fixIdentity = if (elapsedRealtimeNanos > 0L) {
            "elapsed:$elapsedRealtimeNanos"
        } else {
            // elapsedRealtimeNanos is normally present on Android. Coordinates
            // are used only as a legacy-provider fallback and never enter
            // health/status evidence.
            "fallback:${java.lang.Double.doubleToLongBits(latitude)}:" +
                java.lang.Double.doubleToLongBits(longitude)
        }
        val material = listOf(
            "android-native-fix-v1",
            captureGenerationId,
            providerIdentity,
            providerTimestampMs.toString(),
            fixIdentity,
        ).joinToString(separator = "\u001f")
        return UUID.nameUUIDFromBytes(material.toByteArray(Charsets.UTF_8)).toString()
    }
}

/** A small process-local guard complementing the durable journal primary key. */
internal class RecentFixDeduplicator(private val capacity: Int = 512) {
    private val eventIds = LinkedHashSet<String>()

    init {
        require(capacity > 0) { "Recent-fix capacity must be positive." }
    }

    @Synchronized
    fun accept(eventId: String): Boolean {
        if (!eventIds.add(eventId)) return false
        while (eventIds.size > capacity) {
            val oldest = eventIds.iterator()
            oldest.next()
            oldest.remove()
        }
        return true
    }

    @Synchronized
    fun forget(eventId: String) {
        eventIds.remove(eventId)
    }

    @Synchronized
    fun clear() {
        eventIds.clear()
    }
}

/**
 * Arbitrates the flush completion/fallback and current-fix timeout callbacks so
 * exactly one bounded probe is requested and exactly one outcome is recorded.
 */
internal class StationaryExitProbeCoordinator {
    private var nextToken = 0L
    private var activeToken: Long? = null
    private var currentFixRequested = false

    @Synchronized
    fun begin(): Long {
        nextToken = if (nextToken == Long.MAX_VALUE) 1L else nextToken + 1L
        activeToken = nextToken
        currentFixRequested = false
        return nextToken
    }

    @Synchronized
    fun beginCurrentFixRequest(token: Long): Boolean {
        if (activeToken != token || currentFixRequested) return false
        currentFixRequested = true
        return true
    }

    @Synchronized
    fun complete(token: Long): Boolean {
        if (activeToken != token) return false
        activeToken = null
        currentFixRequested = false
        return true
    }

    @Synchronized
    fun cancel() {
        activeToken = null
        currentFixRequested = false
    }
}
