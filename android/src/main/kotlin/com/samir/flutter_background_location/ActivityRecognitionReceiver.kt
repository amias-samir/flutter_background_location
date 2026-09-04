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

        val serviceIntent = Intent(context, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_ACTIVITY_UPDATE
            putExtra(LocationTrackingService.EXTRA_TRACK_ID, trackId)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_GENERATION, generation)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_TYPE, activity.type)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_CONFIDENCE, activity.confidence)
            putExtra(
                LocationTrackingService.EXTRA_ACTIVITY_SOURCE,
                "android_activity_recognition",
            )
            putExtra(
                LocationTrackingService.EXTRA_ACTIVITY_PROBABILITIES,
                JSONObject(probabilities as Map<*, *>).toString(),
            )
            putExtra(
                LocationTrackingService.EXTRA_ACTIVITY_TIMESTAMP,
                result.time.takeIf { it > 0L } ?: System.currentTimeMillis(),
            )
        }

        runCatching { ContextCompat.startForegroundService(context, serviceIntent) }
    }

    private fun deliverTransition(context: Context, intent: Intent) {
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        val event = result.transitionEvents.lastOrNull() ?: return
        val store = TrackingStateStore(context)
        val trackId = intent.getStringExtra(LocationTrackingService.EXTRA_TRACK_ID)
        val generation = intent.getLongExtra(
            LocationTrackingService.EXTRA_ACTIVITY_GENERATION,
            0L,
        )
        if (!store.acceptsActivityRecognitionEvent(trackId, generation)) return
        val elapsedAgeNanos =
            (SystemClock.elapsedRealtimeNanos() - event.elapsedRealTimeNanos).coerceAtLeast(0L)
        val timestamp = System.currentTimeMillis() - elapsedAgeNanos / 1_000_000L
        val isEnter = event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
        val serviceIntent = Intent(context, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_ACTIVITY_UPDATE
            putExtra(LocationTrackingService.EXTRA_TRACK_ID, trackId)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_GENERATION, generation)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_TYPE, event.activityType)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_CONFIDENCE, if (isEnter) 100 else 0)
            putExtra(LocationTrackingService.EXTRA_ACTIVITY_TIMESTAMP, timestamp)
            putExtra(
                LocationTrackingService.EXTRA_ACTIVITY_SOURCE,
                "android_activity_transition",
            )
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
