package com.samir.flutter_background_location

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognitionResult
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import org.json.JSONObject

internal object ActivityMapper {
    fun normalizedType(activityType: Int): String = when (activityType) {
        DetectedActivity.STILL -> "stationary"
        DetectedActivity.WALKING, DetectedActivity.ON_FOOT -> "walking"
        DetectedActivity.RUNNING -> "running"
        DetectedActivity.ON_BICYCLE -> "cycling"
        DetectedActivity.IN_VEHICLE -> "automotive"
        else -> "unknown"
    }

    fun rawType(activityType: Int): String = when (activityType) {
        DetectedActivity.IN_VEHICLE -> "inVehicle"
        DetectedActivity.ON_BICYCLE -> "onBicycle"
        DetectedActivity.ON_FOOT -> "onFoot"
        DetectedActivity.STILL -> "still"
        DetectedActivity.UNKNOWN -> "unknown"
        DetectedActivity.TILTING -> "tilting"
        DetectedActivity.WALKING -> "walking"
        DetectedActivity.RUNNING -> "running"
        else -> "unknown"
    }

    fun event(activityType: Int, confidence: Int, timestamp: Long): Map<String, Any?> {
        val type = normalizedType(activityType)
        return linkedMapOf(
            "type" to type,
            "rawType" to rawType(activityType),
            "confidence" to confidence.coerceIn(0, 100),
            "timestamp" to timestamp,
            "isStationary" to (type == "stationary"),
            "isWalking" to (type == "walking"),
            "isRunning" to (type == "running"),
            "isCycling" to (type == "cycling"),
            "isAutomotive" to (type == "automotive"),
        )
    }
}

class ActivityRecognitionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_ACTIVITY_TRANSITION &&
            ActivityTransitionResult.hasResult(intent)
        ) {
            deliverTransition(context, intent)
            return
        }
        if (intent.action != ACTION_ACTIVITY_RECOGNITION ||
            !ActivityRecognitionResult.hasResult(intent)) return

        val result = ActivityRecognitionResult.extractResult(intent) ?: return
        val activity = result.mostProbableActivity
        val probabilities = linkedMapOf<String, Int>()
        result.probableActivities.forEach { probable ->
            val rawType = ActivityMapper.rawType(probable.type)
            probabilities[rawType] = maxOf(
                probabilities[rawType] ?: 0,
                probable.confidence.coerceIn(0, 100),
            )
        }
        val store = TrackingStateStore(context)
        val trackId = intent.getStringExtra(LocationTrackingService.EXTRA_TRACK_ID)
        val generation = intent.getLongExtra(
            LocationTrackingService.EXTRA_ACTIVITY_GENERATION,
            0L,
        )
        if (!store.acceptsActivityRecognitionEvent(trackId, generation)) return

        deliver(
            context = context,
            trackId = trackId,
            generation = generation,
            activityType = activity.type,
            confidence = activity.confidence,
            timestamp = result.time.takeIf { it > 0L } ?: System.currentTimeMillis(),
            probabilitiesJson = JSONObject(probabilities as Map<*, *>).toString(),
            source = "android_activity_recognition",
            episodeStartedAt = null,
        )
    }

    /**
     * Delivers every transition of one result, oldest first. A transition is
     * observed when it is delivered, so its freshness is measured from
     * receipt; the transition time is kept as `episodeStartedAt`. Reporting
     * the transition time itself made a late ENTER look stale and lose to the
     * newest periodic sample.
     */
    private fun deliverTransition(context: Context, intent: Intent) {
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        if (result.transitionEvents.isEmpty()) return
        val store = TrackingStateStore(context)
        val trackId = intent.getStringExtra(LocationTrackingService.EXTRA_TRACK_ID)
        val generation = intent.getLongExtra(
            LocationTrackingService.EXTRA_ACTIVITY_GENERATION,
            0L,
        )
        if (!store.acceptsActivityRecognitionEvent(trackId, generation)) return
        val receivedAt = System.currentTimeMillis()
        val nowElapsedNanos = SystemClock.elapsedRealtimeNanos()
        for (event in result.transitionEvents.sortedBy { it.elapsedRealTimeNanos }) {
            val elapsedAgeNanos = (nowElapsedNanos - event.elapsedRealTimeNanos).coerceAtLeast(0L)
            val isEnter = event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
            deliver(
                context = context,
                trackId = trackId,
                generation = generation,
                activityType = event.activityType,
                confidence = if (isEnter) 100 else 0,
                timestamp = receivedAt,
                probabilitiesJson = null,
                source = "android_activity_transition",
                episodeStartedAt = receivedAt - elapsedAgeNanos / 1_000_000L,
            )
        }
    }

    /**
     * Hands a result to the running service in process; starts the service
     * only when capture is not running.
     */
    private fun deliver(
        context: Context,
        trackId: String?,
        generation: Long,
        activityType: Int,
        confidence: Int,
        timestamp: Long,
        probabilitiesJson: String?,
        source: String,
        episodeStartedAt: Long?,
    ) {
        val handled = LocationTrackingService.liveService?.deliverActivityInProcess(
            trackId = trackId,
            generation = generation,
            activityType = activityType,
            confidence = confidence,
            timestamp = timestamp,
            probabilitiesJson = probabilitiesJson,
            source = source,
            episodeStartedAt = episodeStartedAt,
        ) == true
        if (handled) return
        val serviceIntent = Intent(context, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_ACTIVITY_UPDATE
            putExtra(LocationTrackingService.EXTRA_TRACK_ID, trackId)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_GENERATION, generation)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_TYPE, activityType)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_CONFIDENCE, confidence)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_TIMESTAMP, timestamp)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_SOURCE, source)
            probabilitiesJson?.let {
                putExtra(LocationTrackingService.EXTRA_ACTIVITY_PROBABILITIES, it)
            }
            episodeStartedAt?.let {
                putExtra(LocationTrackingService.EXTRA_ACTIVITY_EPISODE_STARTED_AT, it)
            }
        }
        runCatching { ContextCompat.startForegroundService(context, serviceIntent) }
    }

    companion object {
        const val ACTION_ACTIVITY_RECOGNITION =
            "com.samir.flutter_background_location.ACTIVITY_RECOGNITION"
        const val ACTION_ACTIVITY_TRANSITION =
            "com.samir.flutter_background_location.ACTIVITY_TRANSITION"
    }
}
