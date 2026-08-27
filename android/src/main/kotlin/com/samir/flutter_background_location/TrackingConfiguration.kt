package com.samir.flutter_background_location

import org.json.JSONObject

internal data class TrackingConfiguration(
    val movingIntervalMs: Long = 15_000L,
    val movingDistanceFilterMeters: Float = 15f,
    val stationaryIntervalMs: Long = 120_000L,
    val stationaryDistanceFilterMeters: Float = 75f,
    val stationaryTimeoutMs: Long = 90_000L,
    val stationaryProbeDisplacementMeters: Float = 30f,
    val stationaryConfidenceThreshold: Int = 75,
    val movingConfidenceThreshold: Int = 60,
    val movingConfirmationCount: Int = 2,
    val activityRecognitionIntervalMs: Long = 10_000L,
    val desiredAccuracy: String = "high",
    val maximumAcceptedAccuracyMeters: Double = 60.0,
    val notificationChannelId: String = "active_location_tracking",
    val notificationChannelName: String = "Active location tracking",
    val notificationChannelDescription: String =
        "Shown while an active location track is being recorded.",
    val notificationTitle: String = "Location tracking active",
    val notificationText: String = "Recording location in the background",
) {
    fun toJson(): String = JSONObject().apply {
        put(KEY_MOVING_INTERVAL, movingIntervalMs)
        put(KEY_MOVING_DISTANCE, movingDistanceFilterMeters.toDouble())
        put(KEY_STATIONARY_INTERVAL, stationaryIntervalMs)
        put(KEY_STATIONARY_DISTANCE, stationaryDistanceFilterMeters.toDouble())
        put(KEY_STATIONARY_TIMEOUT, stationaryTimeoutMs)
        put(KEY_STATIONARY_PROBE_DISTANCE, stationaryProbeDisplacementMeters.toDouble())
        put(KEY_STATIONARY_CONFIDENCE, stationaryConfidenceThreshold)
        put(KEY_MOVING_CONFIDENCE, movingConfidenceThreshold)
        put(KEY_MOVING_CONFIRMATION_COUNT, movingConfirmationCount)
        put(KEY_ACTIVITY_INTERVAL, activityRecognitionIntervalMs)
        put(KEY_DESIRED_ACCURACY, desiredAccuracy)
        put(KEY_MAXIMUM_ACCEPTED_ACCURACY, maximumAcceptedAccuracyMeters)
        put(KEY_NOTIFICATION_CHANNEL_ID, notificationChannelId)
        put(KEY_NOTIFICATION_CHANNEL_NAME, notificationChannelName)
        put(KEY_NOTIFICATION_CHANNEL_DESCRIPTION, notificationChannelDescription)
        put(KEY_NOTIFICATION_TITLE, notificationTitle)
        put(KEY_NOTIFICATION_TEXT, notificationText)
    }.toString()

    companion object {
        private const val KEY_MOVING_INTERVAL = "movingIntervalMs"
        private const val KEY_MOVING_DISTANCE = "movingDistanceFilterMeters"
        private const val KEY_STATIONARY_INTERVAL = "stationaryIntervalMs"
        private const val KEY_STATIONARY_DISTANCE = "stationaryDistanceFilterMeters"
        private const val KEY_STATIONARY_TIMEOUT = "stationaryTimeoutMs"
        private const val KEY_STATIONARY_CONFIRMATION = "stationaryConfirmationMs"
        private const val KEY_STATIONARY_PROBE_DISTANCE = "stationaryProbeDisplacementMeters"
        private const val KEY_STATIONARY_CONFIDENCE = "stationaryConfidenceThreshold"
        private const val KEY_MOVING_CONFIDENCE = "movingConfidenceThreshold"
        private const val KEY_MOVING_CONFIRMATION_COUNT = "movingConfirmationCount"
        private const val KEY_ACTIVITY_INTERVAL = "activityRecognitionIntervalMs"
        private const val KEY_DESIRED_ACCURACY = "desiredAccuracy"
        private const val KEY_MAXIMUM_ACCEPTED_ACCURACY = "maximumAcceptedAccuracyMeters"
        private const val KEY_NOTIFICATION_CHANNEL_ID = "notificationChannelId"
        private const val KEY_NOTIFICATION_CHANNEL_NAME = "notificationChannelName"
        private const val KEY_NOTIFICATION_CHANNEL_DESCRIPTION = "notificationChannelDescription"
        private const val KEY_NOTIFICATION_TITLE = "notificationTitle"
        private const val KEY_NOTIFICATION_TEXT = "notificationText"

        fun fromMap(values: Map<*, *>?): TrackingConfiguration {
            if (values == null) return TrackingConfiguration()

            val defaults = TrackingConfiguration()
            return TrackingConfiguration(
                movingIntervalMs = values.long(KEY_MOVING_INTERVAL, defaults.movingIntervalMs)
                    .coerceAtLeast(1_000L),
                movingDistanceFilterMeters =
                    values.float(KEY_MOVING_DISTANCE, defaults.movingDistanceFilterMeters)
                        .coerceAtLeast(0f),
                stationaryIntervalMs =
                    values.long(KEY_STATIONARY_INTERVAL, defaults.stationaryIntervalMs)
                        .coerceAtLeast(5_000L),
                stationaryDistanceFilterMeters =
                    values.float(KEY_STATIONARY_DISTANCE, defaults.stationaryDistanceFilterMeters)
                        .coerceAtLeast(0f),
                stationaryTimeoutMs =
                    values.long(
                        KEY_STATIONARY_CONFIRMATION,
                        values.long(KEY_STATIONARY_TIMEOUT, defaults.stationaryTimeoutMs),
                    )
                        .coerceAtLeast(0L),
                stationaryProbeDisplacementMeters =
                    values.float(
                        KEY_STATIONARY_PROBE_DISTANCE,
                        defaults.stationaryProbeDisplacementMeters,
                    ).coerceAtLeast(0f),
                stationaryConfidenceThreshold =
                    values.int(KEY_STATIONARY_CONFIDENCE, defaults.stationaryConfidenceThreshold)
                        .coerceIn(0, 100),
                movingConfidenceThreshold =
                    values.int(KEY_MOVING_CONFIDENCE, defaults.movingConfidenceThreshold)
                        .coerceIn(0, 100),
                movingConfirmationCount =
                    values.int(KEY_MOVING_CONFIRMATION_COUNT, defaults.movingConfirmationCount)
                        .coerceAtLeast(1),
                activityRecognitionIntervalMs =
                    values.long(KEY_ACTIVITY_INTERVAL, defaults.activityRecognitionIntervalMs)
                        .coerceAtLeast(1_000L),
                desiredAccuracy = values.string(KEY_DESIRED_ACCURACY, defaults.desiredAccuracy),
                maximumAcceptedAccuracyMeters = values.double(
                    KEY_MAXIMUM_ACCEPTED_ACCURACY,
                    defaults.maximumAcceptedAccuracyMeters,
                ).coerceAtLeast(1.0),
                notificationChannelId =
                    values.string(KEY_NOTIFICATION_CHANNEL_ID, defaults.notificationChannelId)
                        .ifBlank { defaults.notificationChannelId },
                notificationChannelName =
                    values.string(KEY_NOTIFICATION_CHANNEL_NAME, defaults.notificationChannelName)
                        .ifBlank { defaults.notificationChannelName },
                notificationChannelDescription = values.string(
                    KEY_NOTIFICATION_CHANNEL_DESCRIPTION,
                    defaults.notificationChannelDescription,
                ),
                notificationTitle =
                    values.string(KEY_NOTIFICATION_TITLE, defaults.notificationTitle)
                        .ifBlank { defaults.notificationTitle },
                notificationText =
                    values.string(KEY_NOTIFICATION_TEXT, defaults.notificationText)
                        .ifBlank { defaults.notificationText },
            )
        }

        fun fromJson(value: String?): TrackingConfiguration {
            if (value.isNullOrBlank()) return TrackingConfiguration()
            return try {
                val json = JSONObject(value)
                fromMap(
                    buildMap<String, Any?> {
                        json.keys().forEach { key -> put(key, json.opt(key)) }
                    },
                )
            } catch (_: Exception) {
                TrackingConfiguration()
            }
        }

        private fun Map<*, *>.long(key: String, fallback: Long): Long =
            (this[key] as? Number)?.toLong() ?: fallback

        private fun Map<*, *>.float(key: String, fallback: Float): Float =
            (this[key] as? Number)?.toFloat() ?: fallback

        private fun Map<*, *>.double(key: String, fallback: Double): Double =
            (this[key] as? Number)?.toDouble() ?: fallback

        private fun Map<*, *>.int(key: String, fallback: Int): Int =
            (this[key] as? Number)?.toInt() ?: fallback

        private fun Map<*, *>.string(key: String, fallback: String): String =
            this[key]?.toString() ?: fallback
    }
}
