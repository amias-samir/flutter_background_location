package com.samir.flutter_background_location

import android.content.Context
import android.content.SharedPreferences
import android.location.LocationManager
import android.os.Build
import android.os.PowerManager
import java.util.UUID
import org.json.JSONException
import org.json.JSONObject

internal class TrackingStateStore(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    @Volatile
    private var latestProviderCallbackAt =
        preferences.getLong(KEY_LAST_PROVIDER_CALLBACK_AT, 0L).takeIf { it > 0L }
    private var persistedProviderCallbackAt = latestProviderCallbackAt

    val activeTrackId: String?
        get() = preferences.getString(KEY_TRACK_ID, null)?.takeIf { it.isNotBlank() }

    val trackingEnabled: Boolean
        get() = preferences.getBoolean(KEY_TRACKING_ENABLED, false)

    val isPaused: Boolean
        get() = preferences.getBoolean(KEY_PAUSED, false)

    val state: String
        get() = preferences.getString(KEY_STATE, STATE_IDLE) ?: STATE_IDLE

    val profile: String
        get() = preferences.getString(KEY_PROFILE, PROFILE_IDLE) ?: PROFILE_IDLE

    val serviceStartedAt: Long?
        get() = preferences.getLong(KEY_SERVICE_STARTED_AT, 0L).takeIf { it > 0L }

    val serviceHeartbeatAt: Long?
        get() = preferences.getLong(KEY_SERVICE_HEARTBEAT_AT, 0L).takeIf { it > 0L }

    val captureGenerationId: String?
        get() = preferences.getString(KEY_CAPTURE_GENERATION_ID, null)
            ?.takeIf { it.isNotBlank() }

    val nativeSessionStartedAt: Long?
        get() = preferences.getLong(KEY_NATIVE_SESSION_STARTED_AT, 0L).takeIf { it > 0L }

    val captureStartReason: String?
        get() = preferences.getString(KEY_CAPTURE_START_REASON, null)
            ?.takeIf { it.isNotBlank() }

    val lastProviderCallbackAt: Long?
        get() = latestProviderCallbackAt

    val lastProfileTransitionAt: Long?
        get() = preferences.getLong(KEY_LAST_PROFILE_TRANSITION_AT, 0L).takeIf { it > 0L }

    /** Coordinate-free reason for the last moving/stationary profile change. */
    val lastProfileTransitionReason: String?
        get() = preferences.getString(KEY_LAST_PROFILE_TRANSITION_REASON, null)
            ?.takeIf { it.isNotBlank() }

    val stationaryExitProbeRequestedAt: Long?
        get() = preferences.getLong(KEY_STATIONARY_EXIT_PROBE_REQUESTED_AT, 0L)
            .takeIf { it > 0L }

    val stationaryExitProbeCompletedAt: Long?
        get() = preferences.getLong(KEY_STATIONARY_EXIT_PROBE_COMPLETED_AT, 0L)
            .takeIf { it > 0L }

    val stationaryExitProbeOutcome: String?
        get() = preferences.getString(KEY_STATIONARY_EXIT_PROBE_OUTCOME, null)
            ?.takeIf { it.isNotBlank() }

    val stationaryExitFlushOutcome: String?
        get() = preferences.getString(KEY_STATIONARY_EXIT_FLUSH_OUTCOME, null)
            ?.takeIf { it.isNotBlank() }

    val configuration: TrackingConfiguration
        get() = TrackingConfiguration.fromJson(preferences.getString(KEY_CONFIGURATION, null))

    val activityRecognitionGeneration: Long?
        get() = preferences.getLong(KEY_ACTIVITY_RECOGNITION_GENERATION, 0L)
            .takeIf { it > 0L }

    val sessionControlToken: String?
        get() = preferences.getString(KEY_SESSION_CONTROL_TOKEN, null)
            ?.takeIf { it.isNotBlank() }

    val commandRevision: Long
        get() = preferences.getLong(KEY_COMMAND_REVISION, 0L).coerceAtLeast(0L)

    val lastCommandId: String?
        get() = preferences.getString(KEY_LAST_COMMAND_ID, null)
            ?.takeIf { it.isNotBlank() }

    fun claimSessionControl(sessionControlToken: String) {
        require(sessionControlToken.isNotBlank()) { "Session-control token must not be empty." }
        val existing = this.sessionControlToken
        val editor = preferences.edit()
            .putString(KEY_SESSION_CONTROL_TOKEN, sessionControlToken)
        if (existing != sessionControlToken) {
            editor.putLong(KEY_COMMAND_REVISION, 0L)
                .remove(KEY_LAST_COMMAND_ID)
        }
        editor.commitOrThrow("claim native session control")
    }

    fun recordCommandResult(
        sessionControlToken: String,
        commandId: String,
        revision: Long,
    ) {
        require(revision > 0L) { "Command revision must be positive." }
        preferences.edit()
            .putString(KEY_SESSION_CONTROL_TOKEN, sessionControlToken)
            .putString(KEY_LAST_COMMAND_ID, commandId)
            .putLong(KEY_COMMAND_REVISION, revision)
            .commitOrThrow("record native command result")
    }

    fun begin(trackId: String, configuration: TrackingConfiguration) {
        val now = System.currentTimeMillis()
        preferences.edit()
            .clearActiveCaptureEvidence()
            .putString(KEY_TRACK_ID, trackId)
            .putString(KEY_CONFIGURATION, configuration.toJson())
            .putBoolean(KEY_TRACKING_ENABLED, true)
            .putBoolean(KEY_PAUSED, false)
            .putString(KEY_STATE, STATE_STARTING)
            .putString(KEY_PROFILE, PROFILE_MOVING)
            .putLong(KEY_SERVICE_STARTED_AT, now)
            .putLong(KEY_LAST_PROFILE_TRANSITION_AT, now)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .remove(KEY_MESSAGE)
            .commitOrThrow("begin tracking")
        latestProviderCallbackAt = null
        persistedProviderCallbackAt = null
    }

    fun resume() {
        val now = System.currentTimeMillis()
        preferences.edit()
            .clearActiveCaptureEvidence()
            .putBoolean(KEY_TRACKING_ENABLED, true)
            .putBoolean(KEY_PAUSED, false)
            .putString(KEY_STATE, STATE_STARTING)
            .putString(KEY_PROFILE, PROFILE_MOVING)
            .putLong(KEY_SERVICE_STARTED_AT, now)
            .putLong(KEY_LAST_PROFILE_TRANSITION_AT, now)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .remove(KEY_MESSAGE)
            .commitOrThrow("resume tracking")
        latestProviderCallbackAt = null
        persistedProviderCallbackAt = null
    }

    fun markState(
        state: String,
        profile: String,
        message: String? = null,
        timestamp: Long = System.currentTimeMillis(),
        transitionReason: String? = null,
    ) {
        val profileChanged = this.profile != profile
        preferences.edit()
            .putString(KEY_STATE, state)
            .putString(KEY_PROFILE, profile)
            .apply {
                if (profileChanged) {
                    putLong(KEY_LAST_PROFILE_TRANSITION_AT, timestamp)
                    if (transitionReason == null) {
                        remove(KEY_LAST_PROFILE_TRANSITION_REASON)
                    } else {
                        putString(KEY_LAST_PROFILE_TRANSITION_REASON, transitionReason)
                    }
                }
            }
            .apply {
                if (message == null) remove(KEY_MESSAGE) else putString(KEY_MESSAGE, message)
            }
            .commitOrThrow("mark tracking state")
    }

    /** Commits a new capture boundary before the first native request is installed. */
    fun beginCaptureGeneration(
        startReason: String,
        timestamp: Long = System.currentTimeMillis(),
        generationId: String = UUID.randomUUID().toString(),
    ): CaptureSessionEvidence {
        val evidence = CaptureSessionEvidence.create(
            startReason = startReason,
            startedAt = timestamp,
            generationId = generationId,
        )
        preferences.edit()
            .endUnflushedStepCheckpoint(evidence.generationId)
            .putString(KEY_CAPTURE_GENERATION_ID, evidence.generationId)
            .putLong(KEY_NATIVE_SESSION_STARTED_AT, evidence.startedAt)
            .putString(KEY_CAPTURE_START_REASON, evidence.startReason)
            .putLong(KEY_LAST_PROFILE_TRANSITION_AT, evidence.startedAt)
            .remove(KEY_LAST_PROFILE_TRANSITION_REASON)
            .remove(KEY_LAST_PROVIDER_CALLBACK_AT)
            .remove(KEY_STATIONARY_EXIT_PROBE_REQUESTED_AT)
            .remove(KEY_STATIONARY_EXIT_PROBE_COMPLETED_AT)
            .remove(KEY_STATIONARY_EXIT_PROBE_OUTCOME)
            .remove(KEY_STATIONARY_EXIT_FLUSH_OUTCOME)
            .remove(KEY_LAST_LOCATION_REQUEST_FAILURE_AT)
            .remove(KEY_LAST_LOCATION_REQUEST_FAILURE)
            .commitOrThrow("begin native capture generation")
        latestProviderCallbackAt = null
        persistedProviderCallbackAt = null
        return evidence
    }

    /** Records coordinate-free provider health without forcing a disk write for every fix. */
    @Synchronized
    fun markProviderCallback(timestamp: Long = System.currentTimeMillis()) {
        if (timestamp <= 0L) return
        val latest = latestProviderCallbackAt
        if (latest != null && timestamp < latest) return
        latestProviderCallbackAt = timestamp
        val lastPersisted = persistedProviderCallbackAt
        if (lastPersisted != null && timestamp >= lastPersisted &&
            timestamp - lastPersisted < PROVIDER_CALLBACK_PERSIST_INTERVAL_MS
        ) {
            return
        }
        preferences.edit()
            .putLong(KEY_LAST_PROVIDER_CALLBACK_AT, timestamp)
            .apply()
        persistedProviderCallbackAt = timestamp
    }

    /**
     * The running generation's steps, saved every heartbeat so a process
     * death leaves them behind. Asynchronous, like the heartbeat.
     */
    fun checkpointSteps(snapshot: StepSnapshot) {
        preferences.edit()
            .putString(KEY_STEP_CHECKPOINT, StepRecordCodec.encode(snapshot))
            .apply()
    }

    /** An ended generation's final steps, durable before capture stops. */
    fun finalizeSteps(snapshot: StepSnapshot) {
        preferences.edit()
            .putString(KEY_STEP_FINAL, StepRecordCodec.encode(snapshot))
            .remove(KEY_STEP_CHECKPOINT)
            .commitOrThrow("persist final steps")
    }

    /**
     * `{captureGenerationId, stepCount, stepCoverage}` of the newest ended
     * generation: its final flush, or the checkpoint its process left behind
     * (`ended_unflushed`). Kept until a newer generation ends.
     */
    fun stepFinal(): Map<String, Any?>? =
        StepRecordCodec.decode(preferences.getString(KEY_STEP_FINAL, null))
            ?.let(StepRecordCodec::toStatusMap)

    /**
     * Capture ends with no live step count: a checkpoint left behind belongs
     * to a generation whose process died, and becomes its final now.
     */
    fun endUnflushedSteps() {
        if (!preferences.contains(KEY_STEP_CHECKPOINT)) return
        preferences.edit()
            .endUnflushedStepCheckpoint(newGenerationId = null)
            .commitOrThrow("end unflushed steps")
    }

    fun markLocationRequestFailure(
        message: String,
        timestamp: Long = System.currentTimeMillis(),
    ) {
        preferences.edit()
            .putLong(KEY_LAST_LOCATION_REQUEST_FAILURE_AT, timestamp)
            .putString(KEY_LAST_LOCATION_REQUEST_FAILURE, message)
            .commitOrThrow("record location request failure")
    }

    fun markStationaryExitProbeRequested(timestamp: Long = System.currentTimeMillis()) {
        preferences.edit()
            .putLong(KEY_STATIONARY_EXIT_PROBE_REQUESTED_AT, timestamp)
            .remove(KEY_STATIONARY_EXIT_PROBE_COMPLETED_AT)
            .putString(KEY_STATIONARY_EXIT_PROBE_OUTCOME, PROBE_OUTCOME_PENDING)
            .remove(KEY_STATIONARY_EXIT_FLUSH_OUTCOME)
            .commitOrThrow("record stationary-exit probe request")
    }

    fun markStationaryExitFlushOutcome(outcome: String) {
        require(outcome.isNotBlank())
        preferences.edit()
            .putString(KEY_STATIONARY_EXIT_FLUSH_OUTCOME, outcome)
            .commitOrThrow("record stationary-exit flush outcome")
    }

    fun markStationaryExitProbeCompleted(
        outcome: String,
        timestamp: Long = System.currentTimeMillis(),
    ) {
        require(outcome.isNotBlank())
        preferences.edit()
            .putLong(KEY_STATIONARY_EXIT_PROBE_COMPLETED_AT, timestamp)
            .putString(KEY_STATIONARY_EXIT_PROBE_OUTCOME, outcome)
            .commitOrThrow("record stationary-exit probe outcome")
    }

    fun updateConfiguration(configuration: TrackingConfiguration) {
        preferences.edit()
            .putString(KEY_CONFIGURATION, configuration.toJson())
            .commitOrThrow("update tracking configuration")
    }

    fun pause() {
        preferences.edit()
            .putBoolean(KEY_TRACKING_ENABLED, false)
            .putBoolean(KEY_PAUSED, true)
            .putString(KEY_STATE, STATE_PAUSED)
            .putString(KEY_PROFILE, PROFILE_PAUSED)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .remove(KEY_ACTIVITY_RECOGNITION_GENERATION)
            .remove(KEY_MESSAGE)
            .commitOrThrow("pause tracking")
    }

    fun stop(reason: String?) {
        preferences.edit()
            .clearActiveCaptureEvidence()
            .putBoolean(KEY_TRACKING_ENABLED, false)
            .putBoolean(KEY_PAUSED, false)
            .putString(KEY_STATE, STATE_IDLE)
            .putString(KEY_PROFILE, PROFILE_IDLE)
            .putString(KEY_MESSAGE, reason)
            .remove(KEY_TRACK_ID)
            .remove(KEY_CONFIGURATION)
            .remove(KEY_SERVICE_STARTED_AT)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .remove(KEY_ACTIVITY_RECOGNITION_GENERATION)
            .commitOrThrow("stop tracking")
        latestProviderCallbackAt = null
        persistedProviderCallbackAt = null
    }

    fun fail(message: String) {
        preferences.edit()
            .putBoolean(KEY_TRACKING_ENABLED, false)
            .putBoolean(KEY_PAUSED, false)
            .putString(KEY_STATE, STATE_FAILED)
            .putString(KEY_PROFILE, PROFILE_IDLE)
            .putString(KEY_MESSAGE, message)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .remove(KEY_ACTIVITY_RECOGNITION_GENERATION)
            .commitOrThrow("fail tracking")
    }

    fun interrupt(message: String) {
        preferences.edit()
            .putBoolean(KEY_TRACKING_ENABLED, true)
            .putBoolean(KEY_PAUSED, false)
            .putString(KEY_STATE, STATE_INTERRUPTED)
            .putString(KEY_PROFILE, PROFILE_PAUSED)
            .putString(KEY_MESSAGE, message)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .remove(KEY_ACTIVITY_RECOGNITION_GENERATION)
            .commitOrThrow("interrupt tracking")
    }

    fun nextActivityRecognitionGeneration(): Long {
        val generation = (preferences.getLong(KEY_ACTIVITY_RECOGNITION_GENERATION_COUNTER, 0L) + 1L)
            .takeIf { it > 0L }
            ?: 1L
        preferences.edit()
            .putLong(KEY_ACTIVITY_RECOGNITION_GENERATION_COUNTER, generation)
            .putLong(KEY_ACTIVITY_RECOGNITION_GENERATION, generation)
            .commitOrThrow("register activity recognition generation")
        return generation
    }

    fun clearActivityRecognitionGeneration() {
        preferences.edit()
            .remove(KEY_ACTIVITY_RECOGNITION_GENERATION)
            .commitOrThrow("clear activity recognition generation")
    }

    fun acceptsActivityRecognitionEvent(trackId: String?, generation: Long): Boolean {
        if (trackId.isNullOrBlank() || generation <= 0L) return false
        return trackingEnabled &&
            !isPaused &&
            activeTrackId == trackId &&
            activityRecognitionGeneration == generation
    }

    /**
     * Persists the service producer's most recent proof of life. The in-process
     * flags remain the authoritative live signal; this timestamp makes a hard
     * OEM/process kill observable after a later process launch.
     */
    fun markServiceHeartbeat(captureActive: Boolean, timestamp: Long = System.currentTimeMillis()) {
        preferences.edit()
            .putLong(KEY_SERVICE_HEARTBEAT_AT, timestamp)
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, captureActive)
            .apply()
    }

    /**
     * Records that the device began shutting down during capture, so the gap
     * before the next boot can be explained. Synchronous: shutdown leaves no
     * time for an asynchronous write.
     */
    fun markShutdownObserved(timestamp: Long = System.currentTimeMillis()) {
        preferences.edit().putLong(KEY_LAST_SHUTDOWN_OBSERVED_AT, timestamp).commit()
    }

    fun markServiceStopped() {
        preferences.edit()
            .putBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
            .remove(KEY_SERVICE_HEARTBEAT_AT)
            .commitOrThrow("mark service stopped")
    }

    /**
     * Notification actions can arrive while Dart is detached. Keep the action
     * independently of the active-track fields so stop() cannot erase the
     * track identity before Dart has reconciled its durable track record.
     */
    fun recordPendingUserAction(
        trackId: String,
        action: String,
        reason: String,
        timestamp: Long = System.currentTimeMillis(),
    ): Map<String, Any?> {
        val current = pendingUserAction()
        if (current?.get("trackId") == trackId && current["action"] == action) {
            return current
        }

        val actionId = UUID.randomUUID().toString()
        // commit() is intentional: the service may stop immediately after a
        // notification command, so this handoff must be on disk first.
        preferences.edit()
            .putString(KEY_PENDING_ACTION_ID, actionId)
            .putString(KEY_PENDING_ACTION_TRACK_ID, trackId)
            .putString(KEY_PENDING_ACTION, action)
            .putString(KEY_PENDING_ACTION_REASON, reason)
            .putLong(KEY_PENDING_ACTION_TIMESTAMP, timestamp)
            .commitOrThrow("record pending notification action")
        return pendingUserAction() ?: linkedMapOf(
            "actionId" to actionId,
            "trackId" to trackId,
            "action" to action,
            "reason" to reason,
            "timestamp" to timestamp,
        )
    }

    fun pendingUserAction(): Map<String, Any?>? {
        val actionId = preferences.getString(KEY_PENDING_ACTION_ID, null)
            ?.takeIf { it.isNotBlank() }
            ?: return null
        val trackId = preferences.getString(KEY_PENDING_ACTION_TRACK_ID, null)
            ?.takeIf { it.isNotBlank() }
            ?: return null
        val action = preferences.getString(KEY_PENDING_ACTION, null)
            ?.takeIf { it.isNotBlank() }
            ?: return null
        return linkedMapOf(
            "actionId" to actionId,
            "trackId" to trackId,
            "action" to action,
            "reason" to preferences.getString(KEY_PENDING_ACTION_REASON, null),
            "timestamp" to preferences.getLong(KEY_PENDING_ACTION_TIMESTAMP, 0L)
                .takeIf { it > 0L },
        )
    }

    fun acknowledgePendingUserAction(actionId: String): Boolean {
        val pending = pendingUserAction() ?: return false
        if (pending["actionId"] != actionId) return false
        return preferences.edit()
            .remove(KEY_PENDING_ACTION_ID)
            .remove(KEY_PENDING_ACTION_TRACK_ID)
            .remove(KEY_PENDING_ACTION)
            .remove(KEY_PENDING_ACTION_REASON)
            .remove(KEY_PENDING_ACTION_TIMESTAMP)
            .commit()
    }

    /**
     * Legacy/API running signal. A freshly-dispatched STARTING request counts
     * during its bounded launch grace so callers can immediately pause/stop it;
     * unlike the old persisted flag, it becomes false if the producer never
     * starts or is killed.
     */
    fun isActuallyTracking(now: Long = System.currentTimeMillis()): Boolean {
        if (LocationTrackingService.isServiceAliveNow && LocationTrackingService.isCaptureAliveNow) {
            return true
        }
        val startedAt = serviceStartedAt ?: return false
        return trackingEnabled &&
            !isPaused &&
            activeTrackId != null &&
            state == STATE_STARTING &&
            now >= startedAt &&
            now - startedAt <= SERVICE_START_GRACE_MS
    }

    fun statusMap(): Map<String, Any?> {
        val now = System.currentTimeMillis()
        val locationServicesEnabled = isLocationServiceEnabled(appContext)
        val trackingRequested = trackingEnabled && !isPaused && activeTrackId != null
        val serviceAlive = LocationTrackingService.isServiceAliveNow
        val captureAlive = serviceAlive && LocationTrackingService.isCaptureAliveNow
        val heartbeatAt = serviceHeartbeatAt
        val heartbeatFresh = heartbeatAt != null &&
            now >= heartbeatAt &&
            now - heartbeatAt <= SERVICE_HEARTBEAT_STALE_AFTER_MS
        val heartbeatCaptureActive =
            preferences.getBoolean(KEY_HEARTBEAT_CAPTURE_ACTIVE, false)
        val startFresh = serviceStartedAt?.let {
            now >= it && now - it <= SERVICE_START_GRACE_MS
        } == true
        val apiTracking = captureAlive ||
            (trackingRequested && state == STATE_STARTING && startFresh)
        val actualState = when {
            captureAlive -> ACTUAL_STATE_LIVE
            isPaused -> STATE_PAUSED
            state == STATE_FAILED -> STATE_FAILED
            !trackingRequested -> ACTUAL_STATE_STOPPED
            serviceAlive -> STATE_STARTING
            state == STATE_STARTING && startFresh -> STATE_STARTING
            else -> STATE_INTERRUPTED
        }
        val lifecycle = when (actualState) {
            ACTUAL_STATE_LIVE -> STATE_TRACKING
            ACTUAL_STATE_STOPPED -> STATE_IDLE
            else -> actualState
        }
        val motionState = when (profile) {
            PROFILE_STATIONARY -> "stationary"
            PROFILE_MOVING -> "moving"
            else -> "unknown"
        }
        return linkedMapOf(
            "platform" to "android",
            "lifecycle" to lifecycle,
            "nativeLifecycle" to lifecycle,
            "state" to state,
            "actualState" to actualState,
            "isTracking" to apiTracking,
            "trackingRequested" to trackingRequested,
            "serviceAlive" to serviceAlive,
            "captureAlive" to captureAlive,
            "captureGenerationId" to captureGenerationId,
            "stepCount" to LocationTrackingService.stepCount(captureGenerationId),
            "stepCoverage" to LocationTrackingService.stepCoverage(captureGenerationId),
            "stepFinal" to stepFinal(),
            "nativeSessionStartedAt" to nativeSessionStartedAt,
            "captureStartReason" to captureStartReason,
            "serviceHeartbeatAt" to heartbeatAt,
            "lastShutdownObservedAt" to preferences.getLong(KEY_LAST_SHUTDOWN_OBSERVED_AT, 0L)
                .takeIf { it > 0L },
            "heartbeatFresh" to heartbeatFresh,
            "heartbeatCaptureActive" to heartbeatCaptureActive,
            "lastProviderCallbackAt" to lastProviderCallbackAt,
            "lastProfileTransitionAt" to lastProfileTransitionAt,
            "profileTransitionReason" to lastProfileTransitionReason,
            "stationaryExitProbeRequestedAt" to stationaryExitProbeRequestedAt,
            "stationaryExitProbeCompletedAt" to stationaryExitProbeCompletedAt,
            "stationaryExitProbeOutcome" to stationaryExitProbeOutcome,
            "stationaryExitFlushOutcome" to stationaryExitFlushOutcome,
            "lastLocationRequestFailureAt" to preferences.getLong(
                KEY_LAST_LOCATION_REQUEST_FAILURE_AT,
                0L,
            ).takeIf { it > 0L },
            "lastLocationRequestFailure" to preferences.getString(
                KEY_LAST_LOCATION_REQUEST_FAILURE,
                null,
            ),
            "isPaused" to isPaused,
            "trackId" to activeTrackId,
            "lastLocation" to TrackingEventBus.lastLocation,
            "lastActivity" to TrackingEventBus.lastActivity,
            "trackingProfile" to profile,
            "samplingProfile" to profile,
            "batteryMode" to profile,
            "motionState" to motionState,
            "motionEvidence" to TrackingEventBus.lastMotionEvidence,
            "lastPointAt" to TrackingEventBus.lastLocation?.get("timestamp"),
            "serviceStartedAt" to serviceStartedAt,
            "pendingUserAction" to pendingUserAction(),
            "commandRevision" to commandRevision,
            "message" to preferences.getString(KEY_MESSAGE, null),
            "mockDetectionAvailable" to MOCK_DETECTION_AVAILABLE,
            "locationServicesEnabled" to locationServicesEnabled,
            "locationServiceEnabled" to locationServicesEnabled,
            "batteryOptimizationIgnored" to isBatteryOptimizationIgnored(appContext),
            "timestamp" to now,
        )
    }

    fun emitCurrentStatus() {
        TrackingEventBus.emitStatus(statusMap())
    }

    private fun SharedPreferences.Editor.commitOrThrow(operation: String) {
        if (!commit()) {
            throw IllegalStateException("Could not durably persist $operation.")
        }
    }

    /**
     * A checkpoint of another generation was never finalized: its process
     * died. Its last heartbeat becomes that generation's final.
     */
    private fun SharedPreferences.Editor.endUnflushedStepCheckpoint(
        newGenerationId: String?,
    ): SharedPreferences.Editor {
        val checkpoint = preferences.getString(KEY_STEP_CHECKPOINT, null) ?: return this
        val snapshot = StepRecordCodec.decode(checkpoint) ?: return remove(KEY_STEP_CHECKPOINT)
        if (snapshot.generationId == newGenerationId) return this
        val ended = snapshot.copy(
            coverage = snapshot.coverage.copy(state = StepCoverage.STATE_ENDED_UNFLUSHED),
        )
        return putString(KEY_STEP_FINAL, StepRecordCodec.encode(ended))
            .remove(KEY_STEP_CHECKPOINT)
    }

    private fun SharedPreferences.Editor.clearActiveCaptureEvidence(): SharedPreferences.Editor =
        remove(KEY_CAPTURE_GENERATION_ID)
            .remove(KEY_NATIVE_SESSION_STARTED_AT)
            .remove(KEY_CAPTURE_START_REASON)
            .remove(KEY_LAST_PROVIDER_CALLBACK_AT)
            .remove(KEY_LAST_PROFILE_TRANSITION_AT)
            .remove(KEY_LAST_PROFILE_TRANSITION_REASON)
            .remove(KEY_STATIONARY_EXIT_PROBE_REQUESTED_AT)
            .remove(KEY_STATIONARY_EXIT_PROBE_COMPLETED_AT)
            .remove(KEY_STATIONARY_EXIT_PROBE_OUTCOME)
            .remove(KEY_STATIONARY_EXIT_FLUSH_OUTCOME)
            .remove(KEY_LAST_LOCATION_REQUEST_FAILURE_AT)
            .remove(KEY_LAST_LOCATION_REQUEST_FAILURE)

    companion object {
        const val STATE_IDLE = "idle"
        const val STATE_STARTING = "starting"
        const val STATE_TRACKING = "tracking"
        const val STATE_STATIONARY = "stationary"
        const val STATE_PAUSED = "paused"
        const val STATE_STOPPING = "stopping"
        const val STATE_FAILED = "failed"
        const val STATE_INTERRUPTED = "interrupted"

        const val ACTUAL_STATE_LIVE = "live"
        const val ACTUAL_STATE_STOPPED = "stopped"

        const val PROFILE_IDLE = "idle"
        const val PROFILE_MOVING = "moving"
        const val PROFILE_STATIONARY = "stationary"
        const val PROFILE_PAUSED = "paused"

        // Location.isFromMockProvider is available from API 18; this plugin's
        // minSdk is 21. The signal is useful evidence, not proof of authenticity.
        const val MOCK_DETECTION_AVAILABLE = true

        private const val PREFERENCES_NAME = "flutter_background_location_state"
        private const val KEY_TRACK_ID = "active_track_id"
        private const val KEY_TRACKING_ENABLED = "tracking_enabled"
        private const val KEY_PAUSED = "tracking_paused"
        private const val KEY_STATE = "tracking_state"
        private const val KEY_PROFILE = "tracking_profile"
        private const val KEY_CONFIGURATION = "tracking_configuration"
        private const val KEY_SERVICE_STARTED_AT = "service_started_at"
        private const val KEY_SERVICE_HEARTBEAT_AT = "service_heartbeat_at"
        private const val KEY_LAST_SHUTDOWN_OBSERVED_AT = "last_shutdown_observed_at"
        private const val KEY_HEARTBEAT_CAPTURE_ACTIVE = "heartbeat_capture_active"
        private const val KEY_CAPTURE_GENERATION_ID = "capture_generation_id"
        private const val KEY_NATIVE_SESSION_STARTED_AT = "native_session_started_at"
        private const val KEY_CAPTURE_START_REASON = "capture_start_reason"
        private const val KEY_LAST_PROVIDER_CALLBACK_AT = "last_provider_callback_at"
        private const val KEY_LAST_PROFILE_TRANSITION_AT = "last_profile_transition_at"
        private const val KEY_LAST_PROFILE_TRANSITION_REASON = "last_profile_transition_reason"
        private const val KEY_STATIONARY_EXIT_PROBE_REQUESTED_AT =
            "stationary_exit_probe_requested_at"
        private const val KEY_STATIONARY_EXIT_PROBE_COMPLETED_AT =
            "stationary_exit_probe_completed_at"
        private const val KEY_STATIONARY_EXIT_PROBE_OUTCOME =
            "stationary_exit_probe_outcome"
        private const val KEY_STATIONARY_EXIT_FLUSH_OUTCOME =
            "stationary_exit_flush_outcome"
        private const val KEY_LAST_LOCATION_REQUEST_FAILURE_AT =
            "last_location_request_failure_at"
        private const val KEY_LAST_LOCATION_REQUEST_FAILURE =
            "last_location_request_failure"
        private const val KEY_MESSAGE = "status_message"
        private const val KEY_ACTIVITY_RECOGNITION_GENERATION =
            "activity_recognition_generation"
        private const val KEY_ACTIVITY_RECOGNITION_GENERATION_COUNTER =
            "activity_recognition_generation_counter"
        private const val KEY_PENDING_ACTION_ID = "pending_user_action_id"
        private const val KEY_PENDING_ACTION_TRACK_ID = "pending_user_action_track_id"
        private const val KEY_PENDING_ACTION = "pending_user_action"
        private const val KEY_PENDING_ACTION_REASON = "pending_user_action_reason"
        private const val KEY_PENDING_ACTION_TIMESTAMP = "pending_user_action_timestamp"
        private const val KEY_SESSION_CONTROL_TOKEN = "session_control_token"
        private const val KEY_COMMAND_REVISION = "command_revision"
        private const val KEY_LAST_COMMAND_ID = "last_command_id"
        private const val KEY_STEP_CHECKPOINT = "step_checkpoint"
        private const val KEY_STEP_FINAL = "step_final"
        private const val SERVICE_START_GRACE_MS = 90_000L
        private const val SERVICE_HEARTBEAT_STALE_AFTER_MS = 180_000L
        private const val PROVIDER_CALLBACK_PERSIST_INTERVAL_MS = 15_000L
        private const val PROBE_OUTCOME_PENDING = "pending"

        fun isLocationServiceEnabled(context: Context): Boolean {
            val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                manager.isLocationEnabled
            } else {
                @Suppress("DEPRECATION")
                manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
        }

        fun isBatteryOptimizationIgnored(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
            val manager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            return manager.isIgnoringBatteryOptimizations(context.packageName)
        }
    }
}

/** JSON for the persisted step checkpoint and final; no Android types. */
internal object StepRecordCodec {
    fun encode(snapshot: StepSnapshot): String = JSONObject().apply {
        put("captureGenerationId", snapshot.generationId)
        put("stepCount", snapshot.steps ?: JSONObject.NULL)
        put(
            "stepCoverage",
            JSONObject().apply {
                val coverage = snapshot.coverage
                put("state", coverage.state)
                put("countedThrough", coverage.countedThrough ?: JSONObject.NULL)
                put("lastRiseAt", coverage.lastRiseAt ?: JSONObject.NULL)
                put("uncountedMs", coverage.uncountedMs)
                put("sensor", coverage.sensor ?: JSONObject.NULL)
                put("reregistrations", coverage.reregistrations)
            },
        )
    }.toString()

    fun decode(text: String?): StepSnapshot? {
        if (text.isNullOrBlank()) return null
        return try {
            val json = JSONObject(text)
            val generationId = json.stringOrNull("captureGenerationId")
                ?.takeIf { it.isNotBlank() }
                ?: return null
            val coverage = json.optJSONObject("stepCoverage")
            StepSnapshot(
                generationId = generationId,
                steps = json.longOrNull("stepCount"),
                coverage = StepCoverage(
                    state = coverage?.stringOrNull("state") ?: StepCoverage.STATE_UNAVAILABLE,
                    countedThrough = coverage?.longOrNull("countedThrough"),
                    lastRiseAt = coverage?.longOrNull("lastRiseAt"),
                    uncountedMs = coverage?.longOrNull("uncountedMs") ?: 0L,
                    sensor = coverage?.stringOrNull("sensor"),
                    reregistrations = coverage?.longOrNull("reregistrations")?.toInt() ?: 0,
                ),
            )
        } catch (_: JSONException) {
            null
        }
    }

    /** The `stepFinal` status map. */
    fun toStatusMap(snapshot: StepSnapshot): Map<String, Any?> = linkedMapOf(
        "captureGenerationId" to snapshot.generationId,
        "stepCount" to snapshot.steps,
        "stepCoverage" to snapshot.coverage.toMap(),
    )

    private fun JSONObject.longOrNull(key: String): Long? =
        if (isNull(key)) null else (opt(key) as? Number)?.toLong()

    private fun JSONObject.stringOrNull(key: String): String? =
        if (isNull(key)) null else opt(key) as? String
}
