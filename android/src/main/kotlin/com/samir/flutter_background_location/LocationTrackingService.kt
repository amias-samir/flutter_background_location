package com.samir.flutter_background_location

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityRecognitionClient
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.DetectedActivity
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.Granularity
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import org.json.JSONObject
import java.util.UUID

class LocationTrackingService : Service() {
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var activityRecognitionClient: ActivityRecognitionClient
    private lateinit var stateStore: TrackingStateStore
    private lateinit var workerThread: HandlerThread
    private lateinit var motionSensorFusion: MotionSensorFusion
    private lateinit var stepCounter: StepCounter
    // Read by step-counter diagnostics on the worker thread.
    @Volatile
    private var captureWakeLock: PowerManager.WakeLock? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var workerHandler: Handler
    private var configuration = TrackingConfiguration()
    @Volatile
    private var captureStarted = false
    private var currentProfile = TrackingStateStore.PROFILE_IDLE
    private var requestGeneration = 0

    /**
     * Chooses the stream fixes to record while the moving profile captures
     * turns. Replaced on the main thread, read by the provider callback.
     */
    @Volatile
    private var turnSampler: TurnCaptureSampler? = null

    /**
     * Sampling policy 2 feeds the stationary policy every provider fix as it
     * arrives, not only the recorded ones after journaling.
     */
    @Volatile
    private var stationaryPolicyFedPerProviderFix = false
    private var lastPolicyFixNanos = 0L

    // Activity readings and profile switches journaled with the next fix.
    private val decisionInputs = DecisionInputJournal()

    // A stop waiting for the step counter's final reading; see stopAfterFinalSteps.
    private var pendingStop: PendingStop? = null
    private var pendingStopToken = 0
    private var stepFinalPersistedFor: String? = null
    private var currentActivityPendingIntent: PendingIntent? = null
    private var currentActivityTransitionPendingIntent: PendingIntent? = null
    private val monotonicDomainId = "android_process_${UUID.randomUUID()}"
    private var latestActivity: Map<String, Any?>? = null
    // Newest handled reading per source; periodic samples and transitions
    // have separate clocks, so neither may discard the other as "older".
    private val latestActivityTimestamps = HashMap<String, Long>()
    private var lastLocation: Location? = null
    private var lastLocationObservedAt: Long? = null
    private var stationaryReferenceLocation: Location? = null
    private val stationaryDisplacementWindow = StationaryDisplacementWindow()
    private var stillSince: Long? = null
    private var movingEvidence = 0
    // Motion policy 2 state machine; null when motion policy 1 applies.
    private var stationaryPolicy: StationaryPolicyV2? = null
    private var lastNotificationUpdateAt = 0L
    private var journalPrepareInProgress = false
    private var journalPrepareGeneration = 0
    private var nextCaptureStartReason = CAPTURE_REASON_PROCESS_RECOVERY
    private val recentFixDeduplicator = RecentFixDeduplicator()
    private val stationaryExitProbeCoordinator = StationaryExitProbeCoordinator()
    private var stationaryExitProbeCancellation: CancellationTokenSource? = null
    private var stationaryExitProbeTimeout: Runnable? = null
    private var stationaryExitFlushWait: Runnable? = null
    private var batteryLow = false
    @Volatile
    private var lastPrerequisiteCheckPassedAt = Long.MIN_VALUE / 2
    private var lastFixStatusEmittedAt = Long.MIN_VALUE / 2
    private var powerReceiverRegistered = false
    private val powerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SHUTDOWN, ACTION_QUICKBOOT_POWEROFF -> onDeviceShutdown(goAsync())
                Intent.ACTION_BATTERY_LOW -> onBatteryLowChanged(true)
                Intent.ACTION_BATTERY_OKAY -> onBatteryLowChanged(false)
            }
        }
    }

    // Newest provider fix journaled in the current capture generation.
    private var deliveryHighWaterGeneration: String? = null
    private var deliveryHighWaterNanos = Long.MIN_VALUE

    private val stationaryTransition = Runnable {
        tryEnterStationaryProfile()
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            if (!captureStarted) return
            stateStore.markServiceHeartbeat(captureActive = true)
            // Entry can come due while neither fixes nor readings arrive.
            stationaryPolicy?.let { applyStationaryPolicy(it.evaluate(System.currentTimeMillis())) }
            evaluateStepCounter()
            stateStore.emitCurrentStatus()
            mainHandler.postDelayed(this, SERVICE_HEARTBEAT_INTERVAL_MS)
        }
    }

    // The extra step-counter check after a stationary exit.
    private val stepCounterEvaluation = Runnable { evaluateStepCounter() }

    private val prerequisiteMonitor = object : Runnable {
        override fun run() {
            if (!captureStarted) return
            if (!checkActivePrerequisites()) return
            // Activity permission granted while capturing starts the count.
            startStepCounter()
            mainHandler.postDelayed(this, PREREQUISITE_MONITOR_INTERVAL_MS)
        }
    }

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            if (!captureStarted) return
            val sampler = turnSampler
            // A delivery proves the provider alive even when no fix of it is
            // recorded.
            if (sampler != null) stateStore.markProviderCallback(System.currentTimeMillis())
            val feedsPolicy = stationaryPolicyFedPerProviderFix
            // Batched and flushed deliveries are not guaranteed to be in
            // capture order; journal them oldest first.
            result.locations.sortedBy { it.elapsedRealtimeNanos }.forEach { location ->
                noteStepWatchdogFix(location)
                if (sampler == null || sampler.accept(location.toTurnFix())) {
                    handleLocation(location)
                }
                // After the fix's event is built: a switch this fix causes is
                // journaled with the next one.
                if (feedsPolicy) {
                    val delivered = Location(location)
                    mainHandler.post { feedStationaryPolicyOnDelivery(delivered) }
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        workerThread = HandlerThread("fbl-location-service").apply { start() }
        workerHandler = Handler(workerThread.looper)
        motionSensorFusion = MotionSensorFusion(this, workerHandler) { evidence ->
            mainHandler.post {
                if (!captureStarted) return@post
                TrackingEventBus.emitMotionEvidence(evidence)
                // Motion evidence for the step-counter watchdog, ahead of any
                // profile switch it causes. Steps never decide motion.
                when (evidence["reason"]) {
                    MotionSensorFusion.REASON_FRESH_STEP -> stepCounter.onFusionStep()
                    MotionSensorFusion.REASON_SIGNIFICANT_MOTION -> stepCounter.onSignificantMotion()
                }
                val policy = stationaryPolicy
                if (policy != null && evidence["state"] == "moving") {
                    applyStationaryPolicy(policy.onMovingEvidence(System.currentTimeMillis()))
                } else if (evidence["state"] == "moving") {
                    stillSince = null
                    stationaryDisplacementWindow.reset()
                    mainHandler.removeCallbacks(stationaryTransition)
                    switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_LEGACY_POLICY)
                } else if (evidence["state"] == "stationary") {
                    tryEnterStationaryProfile()
                }
                stateStore.emitCurrentStatus()
            }
        }
        stepCounter = StepCounter(this, workerHandler, mainHandler, ::stepCounterEnvironment)
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        activityRecognitionClient = ActivityRecognition.getClient(this)
        isServiceAliveNow = true
        isCaptureAliveNow = false
        liveService = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action

        try {
            ensureForeground()
            ensureStateStore()
            when (action) {
                ACTION_START -> startNewTrack(intent)
                ACTION_RESUME -> resumeTrack(intent)
                ACTION_PAUSE -> pauseTrack(intent)
                ACTION_STOP -> stopTrack(intent)
                ACTION_UPDATE_CONFIG -> updateConfiguration(intent)
                ACTION_ACTIVITY_UPDATE -> receiveActivity(intent)
                ACTION_RESTORE, null -> restoreTrack()
                else -> restoreTrack()
            }
        } catch (error: SecurityException) {
            handleStartCommandFailure(
                "Tracking permission is unavailable: ${error.message.orEmpty()}",
            )
        } catch (error: IllegalStateException) {
            handleStartCommandFailure(
                "Unable to start background tracking: ${error.message.orEmpty()}",
            )
        }

        return if (shouldRemainStarted()) {
            START_STICKY
        } else {
            // Pause, completion, invalid commands, and failed starts must not
            // leave Android with permission to recreate an idle service.
            START_NOT_STICKY
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!shouldRemainStarted()) {
            removeForegroundNotification()
            stopSelf()
        }
        // Active capture deliberately survives removal from Recents.
        // START_STICKY and persisted logical state let Android recreate it
        // where the OS/OEM permits.
        super.onTaskRemoved(rootIntent)
    }

    private fun shouldRemainStarted(): Boolean =
        if (!::stateStore.isInitialized) {
            false
        } else {
            // A stop waiting for the final steps must not be undone by a restart.
            pendingStop == null && TrackingServiceLifecycle.shouldRemainStarted(
                captureStarted = captureStarted || journalPrepareInProgress,
                trackingEnabled = stateStore.trackingEnabled,
                isPaused = stateStore.isPaused,
                hasTrackId = stateStore.activeTrackId != null,
            )
        }

    override fun onDestroy() {
        if (::stateStore.isInitialized) {
            // A stop still waiting for the step counter's final reading ends
            // now with the steps counted so far, as does a capture destroyed
            // without a stop (best effort).
            val pending = pendingStop
            if (pending != null) {
                pendingStop = null
                pendingStopToken += 1
                persistUnflushedStepFinal()
                pending.stop()
            } else if (captureStarted) {
                persistUnflushedStepFinal()
            }
        }
        mainHandler.removeCallbacks(stationaryTransition)
        mainHandler.removeCallbacks(heartbeat)
        mainHandler.removeCallbacks(prerequisiteMonitor)
        mainHandler.removeCallbacks(stepCounterEvaluation)
        requestGeneration += 1
        captureStarted = false
        isCaptureAliveNow = false
        isServiceAliveNow = false
        if (liveService === this) liveService = null
        stationaryDisplacementWindow.reset()
        runCatching { fusedLocationClient.removeLocationUpdates(locationCallback) }
        removeCurrentActivityUpdates(clearGeneration = false)
        motionSensorFusion.stop()
        stepCounter.stop()
        unregisterPowerReceiver()
        releaseCaptureWakeLock()
        TrackingEventBus.clearMotionEvidence()
        if (::stateStore.isInitialized) {
            stateStore.markServiceStopped()
        }
        workerThread.quitSafely()
        super.onDestroy()
    }

    private fun ensureStateStore() {
        if (::stateStore.isInitialized) return
        stateStore = TrackingStateStore(this)
        configuration = stateStore.configuration
        stateStore.markServiceHeartbeat(captureActive = false)
    }

    private fun handleStartCommandFailure(message: String) {
        if (::stateStore.isInitialized) {
            failCapture(message)
        } else {
            captureStarted = false
            isCaptureAliveNow = false
            runCatching { removeForegroundNotification() }
            stopSelf()
        }
    }

    private fun startNewTrack(intent: Intent) {
        val trackId = intent.getStringExtra(EXTRA_TRACK_ID)?.trim().orEmpty()
        configuration = TrackingConfiguration.fromJson(intent.getStringExtra(EXTRA_CONFIGURATION))

        // A startForegroundService call must be promoted promptly even if the
        // caller passed invalid data. This prevents Android's five-second FGS
        // timeout while still producing a useful failure state.
        ensureForeground()
        if (trackId.isEmpty()) {
            failCapture("A non-empty trackId is required.")
            return
        }

        stopCapture()
        stateStore.begin(trackId, configuration)
        nextCaptureStartReason = CAPTURE_REASON_NEW_TRACK
        stateStore.emitCurrentStatus()
        startCapture()
    }

    private fun resumeTrack(intent: Intent) {
        val requestedTrackId = intent.getStringExtra(EXTRA_TRACK_ID)?.trim()
        val persistedTrackId = stateStore.activeTrackId
        val trackId = requestedTrackId?.takeIf { it.isNotEmpty() } ?: persistedTrackId
        configuration = intent.getStringExtra(EXTRA_CONFIGURATION)
            ?.let(TrackingConfiguration::fromJson)
            ?: stateStore.configuration

        ensureForeground()
        if (trackId == null) {
            failCapture("There is no paused track to resume.")
            return
        }
        if (persistedTrackId != null && requestedTrackId != null && persistedTrackId != requestedTrackId) {
            failCapture("The requested track does not match the paused track.")
            return
        }

        stopCapture()
        if (persistedTrackId == null) {
            stateStore.begin(trackId, configuration)
            nextCaptureStartReason = CAPTURE_REASON_NEW_TRACK
        } else {
            stateStore.resume()
            nextCaptureStartReason = CAPTURE_REASON_RESUME
        }
        stateStore.emitCurrentStatus()
        startCapture()
    }

    private fun restoreTrack() {
        if (!stateStore.trackingEnabled || stateStore.isPaused || stateStore.activeTrackId == null) {
            stopCapture()
            removeForegroundNotification()
            stopSelf()
            return
        }

        configuration = stateStore.configuration
        ensureForeground()
        if (captureStarted) return
        stateStore.markState(
            TrackingStateStore.STATE_STARTING,
            TrackingStateStore.PROFILE_MOVING,
            "Tracking service restored by Android.",
        )
        nextCaptureStartReason = CAPTURE_REASON_PROCESS_RECOVERY
        stateStore.emitCurrentStatus()
        startCapture()
    }

    private fun pauseTrack(intent: Intent) {
        // A pause or stop already waiting for the final steps covers this one.
        if (pendingStop?.let { it.kind >= STOP_KIND_PAUSE } == true) return
        recordNotificationActionIfNeeded(intent, action = "pause", fallbackReason = "notification_paused")
        ensureForeground()
        stateStore.markState(TrackingStateStore.STATE_STOPPING, currentProfile)
        stateStore.emitCurrentStatus()
        stopAfterFinalSteps(STOP_KIND_PAUSE) {
            stopCapture()
            stateStore.pause()
            stateStore.emitCurrentStatus()
            removeForegroundNotification()
            stopSelf()
        }
    }

    private fun stopTrack(intent: Intent) {
        // A stop already waiting for the final steps covers this one; a
        // waiting pause becomes this stop.
        if (pendingStop?.let { it.kind >= STOP_KIND_STOP } == true) return
        val reason = intent.getStringExtra(EXTRA_STOP_REASON) ?: "user_stopped"
        recordNotificationActionIfNeeded(intent, action = "stop", fallbackReason = reason)
        ensureForeground()
        stateStore.markState(TrackingStateStore.STATE_STOPPING, currentProfile)
        stateStore.emitCurrentStatus()
        stopAfterFinalSteps(STOP_KIND_STOP) {
            stopCapture()
            stateStore.stop(reason)
            stateStore.emitCurrentStatus()
            removeForegroundNotification()
            stopSelf()
        }
    }

    /**
     * Runs [stop] once the step counter has delivered the generation's final
     * reading and the final steps are durable: about a second at most, while
     * capture runs on. A later request of a higher [kind] (stop over pause
     * over failure) replaces the waiting one; a start or resume cancels it
     * through [stopCapture].
     */
    private fun stopAfterFinalSteps(kind: Int, stop: () -> Unit) {
        val pending = pendingStop
        if (pending != null) {
            if (kind > pending.kind) pendingStop = PendingStop(kind, stop)
            return
        }
        if (!captureStarted || !stepCounter.isCounting(stateStore.captureGenerationId)) {
            // A generation whose process died left its checkpoint behind.
            runCatching { stateStore.endUnflushedSteps() }
            stop()
            return
        }
        val token = ++pendingStopToken
        pendingStop = PendingStop(kind, stop)
        stepCounter.finalize { snapshot ->
            if (token != pendingStopToken) return@finalize
            val waiting = pendingStop ?: return@finalize
            pendingStop = null
            persistStepFinal(snapshot)
            waiting.stop()
        }
    }

    private fun persistStepFinal(snapshot: StepSnapshot?) {
        snapshot ?: return
        runCatching { stateStore.finalizeSteps(snapshot) }
        stepFinalPersistedFor = snapshot.generationId
    }

    /** A generation ending without its final flush keeps the steps counted so far. */
    private fun persistUnflushedStepFinal() {
        val generationId = stateStore.captureGenerationId ?: return
        if (stepFinalPersistedFor == generationId) return
        persistStepFinal(stepCounter.snapshot(generationId))
    }

    private fun receiveActivity(intent: Intent) {
        if (!stateStore.trackingEnabled || stateStore.isPaused) {
            stopCapture()
            removeForegroundNotification()
            stopSelf()
            return
        }

        val trackId = intent.getStringExtra(EXTRA_TRACK_ID)
        val generation = intent.getLongExtra(EXTRA_ACTIVITY_GENERATION, 0L)
        if (!stateStore.acceptsActivityRecognitionEvent(trackId, generation)) {
            return
        }

        configuration = stateStore.configuration
        ensureForeground()
        if (!captureStarted) startCapture()

        val activityType = intent.getIntExtra(EXTRA_ACTIVITY_TYPE, -1)
        val confidence = intent.getIntExtra(EXTRA_ACTIVITY_CONFIDENCE, 0)
        val timestamp = intent.getLongExtra(EXTRA_ACTIVITY_TIMESTAMP, System.currentTimeMillis())
        handleActivity(
            activityType,
            confidence,
            timestamp,
            intent.getStringExtra(EXTRA_ACTIVITY_PROBABILITIES),
            intent.getStringExtra(EXTRA_ACTIVITY_SOURCE)
                ?: "android_activity_recognition",
            intent.getLongExtra(EXTRA_ACTIVITY_EPISODE_STARTED_AT, -1L).takeIf { it > 0L },
        )
    }

    /**
     * Handles an activity result in process while capture runs. Results reach
     * the receiver on the main thread every few seconds; restarting the
     * service for each one rebuilt the notification and re-read the
     * configuration. Returns false when capture is not running, so the caller
     * falls back to starting the service.
     */
    internal fun deliverActivityInProcess(
        trackId: String?,
        generation: Long,
        activityType: Int,
        confidence: Int,
        timestamp: Long,
        probabilitiesJson: String?,
        source: String,
        episodeStartedAt: Long?,
    ): Boolean {
        if (!captureStarted) return false
        if (!stateStore.trackingEnabled || stateStore.isPaused) return false
        if (!stateStore.acceptsActivityRecognitionEvent(trackId, generation)) return true
        handleActivity(activityType, confidence, timestamp, probabilitiesJson, source, episodeStartedAt)
        return true
    }

    private fun updateConfiguration(intent: Intent) {
        val trackId = intent.getStringExtra(EXTRA_TRACK_ID)
        if (trackId == null || trackId != stateStore.activeTrackId) {
            ensureForeground()
            failCapture("The configuration update did not match the active track.")
            return
        }
        configuration = TrackingConfiguration.fromJson(intent.getStringExtra(EXTRA_CONFIGURATION))
        stateStore.updateConfiguration(configuration)
        ensureForeground()
        if (!captureStarted) {
            startCapture()
        } else {
            replaceStationaryPolicy()
            motionSensorFusion.start(configuration)
            startStepCounter()
            requestLocationUpdates(currentProfile)
        }
        stateStore.emitCurrentStatus()
        updateNotification(force = true)
    }

    private fun startCapture() {
        if (captureStarted || journalPrepareInProgress) return
        if (!hasLocationPermission()) {
            failCapture("Foreground location permission is required.")
            return
        }
        if (!TrackingStateStore.isLocationServiceEnabled(this)) {
            failCapture("Location services are disabled.")
            return
        }

        journalPrepareInProgress = true
        val prepareGeneration = ++journalPrepareGeneration
        val accepted = PendingLocationCoordinator.diagnose(
            this,
            performMaintenance = false,
        ) { diagnostic ->
            mainHandler.post {
                if (prepareGeneration != journalPrepareGeneration) return@post
                journalPrepareInProgress = false
                if (captureStarted) return@post
                if (!stateStore.trackingEnabled || stateStore.isPaused || stateStore.activeTrackId == null) {
                    return@post
                }
                if (diagnostic["healthy"] != true) {
                    failCapture(
                        "The native location journal could not be prepared: " +
                            diagnosticMessage(diagnostic),
                    )
                    return@post
                }
                startCaptureAfterJournalReady()
            }
        }
        if (!accepted) {
            journalPrepareInProgress = false
            failCapture("The native pending-location worker is overloaded.")
        }
    }

    private fun startCaptureAfterJournalReady() {
        if (captureStarted) return
        if (!hasLocationPermission()) {
            failCapture("Foreground location permission is required.")
            return
        }
        if (!TrackingStateStore.isLocationServiceEnabled(this)) {
            failCapture("Location services are disabled.")
            return
        }

        captureStarted = true
        isCaptureAliveNow = true
        lastPrerequisiteCheckPassedAt = Long.MIN_VALUE / 2
        lastFixStatusEmittedAt = Long.MIN_VALUE / 2
        acquireCaptureWakeLock()
        currentProfile = TrackingStateStore.PROFILE_MOVING
        stillSince = null
        movingEvidence = 0
        latestActivity = null
        lastLocation = null
        lastLocationObservedAt = null
        stationaryReferenceLocation = null
        stationaryDisplacementWindow.reset()
        stationaryPolicy = newStationaryPolicy()

        // This commit precedes every provider subscription. Request/profile
        // replacements below deliberately keep the same durable generation.
        stateStore.beginCaptureGeneration(nextCaptureStartReason)
        nextCaptureStartReason = CAPTURE_REASON_PROCESS_RECOVERY
        recentFixDeduplicator.clear()
        decisionInputs.reset(currentProfile)
        lastPolicyFixNanos = 0L

        registerPowerReceiver()
        requestActivityUpdates()
        motionSensorFusion.start(configuration)
        startStepCounter()
        requestLocationUpdates(currentProfile)
        requestStationaryExitProbe()
        stateStore.markServiceHeartbeat(captureActive = true)
        mainHandler.removeCallbacks(heartbeat)
        mainHandler.postDelayed(heartbeat, SERVICE_HEARTBEAT_INTERVAL_MS)
        mainHandler.removeCallbacks(prerequisiteMonitor)
        mainHandler.postDelayed(prerequisiteMonitor, PREREQUISITE_MONITOR_INTERVAL_MS)
        stateStore.markState(TrackingStateStore.STATE_TRACKING, currentProfile)
        stateStore.emitCurrentStatus()
        updateNotification(force = true)
    }

    private fun stopCapture() {
        val wasCapturing = captureStarted
        // A start or resume replaces a stop still waiting for the final steps.
        if (pendingStop != null) {
            pendingStop = null
            pendingStopToken += 1
        }
        if (wasCapturing) persistUnflushedStepFinal()
        journalPrepareGeneration += 1
        journalPrepareInProgress = false
        captureStarted = false
        isCaptureAliveNow = false
        requestGeneration += 1
        mainHandler.removeCallbacks(stationaryTransition)
        mainHandler.removeCallbacks(heartbeat)
        mainHandler.removeCallbacks(prerequisiteMonitor)
        mainHandler.removeCallbacks(stepCounterEvaluation)
        if (wasCapturing) {
            runCatching { fusedLocationClient.removeLocationUpdates(locationCallback) }
        }
        removeCurrentActivityUpdates(clearGeneration = true)
        motionSensorFusion.stop()
        stepCounter.stop()
        decisionInputs.reset(TrackingStateStore.PROFILE_MOVING)
        lastPolicyFixNanos = 0L
        unregisterPowerReceiver()
        releaseCaptureWakeLock()
        TrackingEventBus.clearMotionEvidence()
        currentProfile = TrackingStateStore.PROFILE_IDLE
        stillSince = null
        movingEvidence = 0
        latestActivity = null
        latestActivityTimestamps.clear()
        lastLocation = null
        lastLocationObservedAt = null
        stationaryReferenceLocation = null
        stationaryDisplacementWindow.reset()
        stationaryPolicy = null
        stationaryExitProbeCoordinator.cancel()
        stationaryExitProbeCancellation?.cancel()
        stationaryExitProbeCancellation = null
        stationaryExitProbeTimeout?.let(mainHandler::removeCallbacks)
        stationaryExitProbeTimeout = null
        stationaryExitFlushWait?.let(mainHandler::removeCallbacks)
        stationaryExitFlushWait = null
        recentFixDeduplicator.clear()
        stateStore.markServiceHeartbeat(captureActive = false)
        PendingLocationCoordinator.closeAsync(this)
    }

    private fun diagnosticMessage(diagnostic: Map<String, Any?>): String =
        diagnostic["errorMessage"] as? String
            ?: diagnostic["integrityCheck"] as? String
            ?: "journal diagnostic failed"

    /**
     * Keeps the service worker and sensor callbacks runnable while the screen
     * is locked. This lock exists only for an active capture session; all
     * paused, completed, failed, and destroyed paths release it.
     */
    private fun acquireCaptureWakeLock() {
        val existing = captureWakeLock
        if (existing?.isHeld == true) return
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        captureWakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:flutter_background_location:active_capture",
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseCaptureWakeLock() {
        val wakeLock = captureWakeLock ?: return
        if (wakeLock.isHeld) runCatching { wakeLock.release() }
        captureWakeLock = null
    }

    private fun requestLocationUpdates(profile: String) {
        if (!captureStarted) return
        val generation = ++requestGeneration
        // The request, and the sampler choosing which stream fixes to record,
        // follow the configuration's sampling policy (LocationRequestPlan).
        val plan = LocationRequestPlan.forProfile(profile, configuration, batteryLow)
        turnSampler = plan.sampler?.create()
        stationaryPolicyFedPerProviderFix = configuration.usesSamplingPolicyV2
        val request = LocationRequest.Builder(plan.priority, plan.providerIntervalMs)
            .setMinUpdateIntervalMillis(plan.minUpdateIntervalMs)
            .setMaxUpdateDelayMillis(plan.maxUpdateDelayMs)
            .setMaxUpdateAgeMillis(plan.maxUpdateAgeMs)
            .setMinUpdateDistanceMeters(plan.minUpdateDistanceMeters)
            .setGranularity(plan.granularity)
            .setWaitForAccurateLocation(plan.waitForAccurateLocation)
            .build()

        // Requesting again with the same callback replaces the active request
        // in place. Removing it first left a gap that could restart the
        // location engine on every profile switch.
        try {
            fusedLocationClient.requestLocationUpdates(
                request,
                locationCallback,
                workerThread.looper,
            ).addOnFailureListener { error ->
                if (captureStarted && generation == requestGeneration) {
                    failCapture("Location updates failed: ${error.message.orEmpty()}")
                }
            }
        } catch (error: SecurityException) {
            failCapture("Location permission was revoked: ${error.message.orEmpty()}")
        }
    }

    private fun requestActivityUpdates() {
        val trackId = stateStore.activeTrackId
        if (!hasActivityRecognitionPermission()) {
            val event = linkedMapOf<String, Any?>(
                "type" to "unknown",
                "rawType" to "permissionUnavailable",
                "confidence" to 0,
                "timestamp" to System.currentTimeMillis(),
                "available" to false,
                "source" to "android_activity_recognition",
                "evidenceState" to "unavailable",
                "isStationary" to false,
                "isWalking" to false,
                "isRunning" to false,
                "isCycling" to false,
                "isAutomotive" to false,
            )
            latestActivity = event
            publishActivity(event)
            return
        }
        if (trackId == null) return

        var pendingIntent: PendingIntent? = null
        try {
            val previousGeneration = stateStore.activityRecognitionGeneration
            if (previousGeneration != null) {
                activityRecognitionClient.removeActivityUpdates(
                    activityPendingIntent(trackId, previousGeneration),
                )
                activityRecognitionClient.removeActivityTransitionUpdates(
                    activityTransitionPendingIntent(trackId, previousGeneration),
                )
            }
            val generation = stateStore.nextActivityRecognitionGeneration()
            val registeredPendingIntent = activityPendingIntent(trackId, generation)
            pendingIntent = registeredPendingIntent
            currentActivityPendingIntent = registeredPendingIntent
            activityRecognitionClient.requestActivityUpdates(
                configuration.activityRecognitionIntervalMs,
                registeredPendingIntent,
            ).addOnFailureListener {
                // Motion gating is an optimization. Location capture continues
                // in the moving profile when the activity source is unavailable.
                val event = linkedMapOf<String, Any?>(
                    "type" to "unknown",
                    "rawType" to "sourceUnavailable",
                    "confidence" to 0,
                    "timestamp" to System.currentTimeMillis(),
                    "available" to false,
                    "source" to "android_activity_recognition",
                    "evidenceState" to "unavailable",
                )
                latestActivity = event
                publishActivity(event)
                stationaryPolicy?.let {
                    applyStationaryPolicy(it.onActivityUnavailable(System.currentTimeMillis()))
                }
                if (currentActivityPendingIntent == registeredPendingIntent) {
                    currentActivityPendingIntent = null
                    runCatching { stateStore.clearActivityRecognitionGeneration() }
                }
            }
            requestActivityTransitionUpdates(trackId, generation)
        } catch (_: SecurityException) {
            // Permission may be revoked between the check and API call. Tracking
            // remains active with the moving location profile.
            if (currentActivityPendingIntent == pendingIntent) {
                currentActivityPendingIntent = null
            }
            pendingIntent?.cancel()
            runCatching { stateStore.clearActivityRecognitionGeneration() }
        }
    }

    /** Emits an activity reading and journals it with the next fix. */
    private fun publishActivity(event: Map<String, Any?>) {
        decisionInputs.onActivityReading(event)
        TrackingEventBus.emitActivity(event)
    }

    /** Doppler speed of every provider fix, as step-counter watchdog evidence. */
    private fun noteStepWatchdogFix(location: Location) {
        stepCounter.onFix(
            speed = location.speed.toDouble().takeIf { location.hasSpeed() },
            speedAccuracy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                location.hasSpeedAccuracy()
            ) {
                location.speedAccuracyMetersPerSecond.toDouble()
            } else {
                null
            },
            observedAtMs = location.elapsedRealtimeNanos.takeIf { it > 0L }
                ?.div(1_000_000L)
                ?: SystemClock.elapsedRealtime(),
        )
    }

    /**
     * Sampling policy 2: the stationary policy sees every provider fix as it
     * arrives, in capture order and once, whether or not it is recorded.
     */
    private fun feedStationaryPolicyOnDelivery(location: Location) {
        if (!captureStarted) return
        val policy = stationaryPolicy ?: return
        val capturedAt = location.elapsedRealtimeNanos
        if (capturedAt > 0L) {
            if (capturedAt <= lastPolicyFixNanos) return
            lastPolicyFixNanos = capturedAt
        }
        handleStationaryPolicyFix(policy, location)
    }

    private fun Location.toTurnFix() = TurnCaptureSampler.Fix(
        elapsedMs = elapsedRealtimeNanos / 1_000_000L,
        latitude = latitude,
        longitude = longitude,
        speedMetersPerSecond = if (hasSpeed()) speed else null,
        bearingDegrees = if (hasBearing()) bearing else null,
        bearingAccuracyDegrees = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            hasBearingAccuracy()
        ) {
            bearingAccuracyDegrees
        } else {
            null
        },
    )

    private fun handleLocation(
        location: Location,
        captureOrigin: String = CAPTURE_ORIGIN_PROVIDER_STREAM,
        onDurablyHandled: (() -> Unit)? = null,
    ) {
        if (!captureStarted) return
        // A fix recorded outside the stream is the turn reference too.
        if (captureOrigin != CAPTURE_ORIGIN_PROVIDER_STREAM) {
            turnSampler?.record(location.toTurnFix())
        }
        if (!checkActivePrerequisitesForFix()) return
        val trackId = stateStore.activeTrackId ?: return
        val captureGenerationId = stateStore.captureGenerationId ?: run {
            failCapture("Native capture generation is unavailable.")
            return
        }
        val nativeReceivedAt = System.currentTimeMillis()
        stateStore.markProviderCallback(nativeReceivedAt)
        val monotonicReceivedNanos = SystemClock.elapsedRealtimeNanos()
        val timestamp = location.time.takeIf { it > 0L } ?: nativeReceivedAt
        val mocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }

        val eventId = NativeLocationFixIdentity.eventId(
            captureGenerationId = captureGenerationId,
            provider = location.provider,
            providerTimestampMs = timestamp,
            elapsedRealtimeNanos = location.elapsedRealtimeNanos,
            latitude = location.latitude,
            longitude = location.longitude,
        )
        if (!recentFixDeduplicator.accept(eventId)) {
            onDurablyHandled?.invoke()
            return
        }

        val (activityEvidenceState, activityAgeMs) = activityEvidenceAt(nativeReceivedAt)
        // The profile in effect when the fix was captured: a batch delivered
        // after a switch holds fixes from before it.
        val capturedProfile = decisionInputs.profileAt(location.elapsedRealtimeNanos)
        // Readings and switches since the previous journaled fix, so a route
        // replayed from the journal decides as live capture did.
        val inputs = decisionInputs.drain()
        val event = linkedMapOf<String, Any?>(
            "eventId" to eventId,
            "trackId" to trackId,
            "lat" to location.latitude,
            "lon" to location.longitude,
            "altitude" to location.altitude.takeIf { location.hasAltitude() },
            "accuracy" to location.accuracy.toDouble().takeIf { location.hasAccuracy() },
            "verticalAccuracy" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                location.hasVerticalAccuracy()
            ) {
                location.verticalAccuracyMeters.toDouble()
            } else {
                null
            },
            "heading" to location.bearing.toDouble().takeIf { location.hasBearing() },
            "headingAccuracy" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                location.hasBearingAccuracy()
            ) {
                location.bearingAccuracyDegrees.toDouble()
            } else {
                null
            },
            "speed" to location.speed.toDouble().takeIf { location.hasSpeed() },
            "speedAccuracy" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                location.hasSpeedAccuracy()
            ) {
                location.speedAccuracyMetersPerSecond.toDouble()
            } else {
                null
            },
            "timestamp" to timestamp,
            "nativeReceivedAt" to nativeReceivedAt,
            "providerTimeDeltaMsAtReceipt" to (nativeReceivedAt - timestamp),
            "monotonicFixNanos" to location.elapsedRealtimeNanos,
            "monotonicReceivedNanos" to monotonicReceivedNanos,
            "monotonicDomainId" to monotonicDomainId,
            "captureGenerationId" to captureGenerationId,
            "nativeSessionStartedAt" to stateStore.nativeSessionStartedAt,
            "nativeLifecycle" to TrackingStateStore.STATE_TRACKING,
            "captureOrigin" to captureOrigin,
            "deliveryOrder" to deliveryOrder(captureGenerationId, location.elapsedRealtimeNanos),
            "isMocked" to mocked,
            "mockDetectionAvailable" to TrackingStateStore.MOCK_DETECTION_AVAILABLE,
            "mockEvidence" to if (mocked) {
                "android_location_is_mock"
            } else {
                "android_location_mock_flag_clear"
            },
            "activityType" to latestActivity?.get("type"),
            "activityConfidence" to latestActivity?.get("confidence"),
            "activityTimestamp" to latestActivity?.get("timestamp"),
            "activitySource" to latestActivity?.get("source"),
            "activityRawType" to latestActivity?.get("rawType"),
            "activityEvidenceState" to activityEvidenceState,
            "activityAgeMs" to activityAgeMs,
            "activityProbabilities" to latestActivity?.get("probabilities"),
            "motionEvidence" to TrackingEventBus.lastMotionEvidence,
            "stepCount" to stepCounter.steps(captureGenerationId),
            "stepCoverage" to stepCounter.coverage(captureGenerationId)?.toMap(),
            "motionState" to if (capturedProfile == TrackingStateStore.PROFILE_STATIONARY) {
                "stationary"
            } else {
                "moving"
            },
            "trackingProfile" to capturedProfile,
            "samplingProfile" to capturedProfile,
            "batteryMode" to capturedProfile,
            "provider" to location.provider,
            "activityReadings" to inputs.activityReadings,
            "profileTransitions" to inputs.profileTransitions,
        )
        if (inputs.activityReadingsDropped > 0) {
            event["activityReadingsDropped"] = inputs.activityReadingsDropped
        }

        val locationCopy = Location(location)
        val accepted = PendingLocationCoordinator.execute(
            applicationContext,
            onFailure = { error ->
                recentFixDeduplicator.forget(eventId)
                mainHandler.post {
                    if (captureStarted && stateStore.activeTrackId == trackId) {
                        failCapture(
                            "A location fix could not be journaled safely: ${error.message.orEmpty()}",
                        )
                    }
                }
            },
        ) { store ->
            val inserted = store.enqueue(event)
            mainHandler.post {
                if (inserted) {
                    handleJournaledLocation(trackId, locationCopy, timestamp, event)
                }
                onDurablyHandled?.invoke()
            }
        }
        if (!accepted) {
            recentFixDeduplicator.forget(eventId)
            failCapture("The native pending-location worker is overloaded.")
        }
    }

    private fun handleJournaledLocation(
        trackId: String,
        location: Location,
        timestamp: Long,
        event: Map<String, Any?>,
    ) {
        if (!captureStarted || stateStore.activeTrackId != trackId) return
        TrackingEventBus.emitLocation(event)
        // Dart publishes its own status after each commit, so the native
        // status (binder calls plus a channel message) is a liveness tick
        // here rather than a per-fix echo.
        val nowElapsed = SystemClock.elapsedRealtime()
        if (nowElapsed - lastFixStatusEmittedAt >= FIX_STATUS_LIVENESS_INTERVAL_MS) {
            lastFixStatusEmittedAt = nowElapsed
            stateStore.emitCurrentStatus()
        }

        val policy = stationaryPolicy
        if (policy != null) {
            // Sampling policy 2 fed the policy when the fix arrived.
            if (!stationaryPolicyFedPerProviderFix) handleStationaryPolicyFix(policy, location)
            updateNotification(force = false, pointTimestamp = timestamp)
            return
        }

        val observedAt = System.currentTimeMillis()
        if (!isMotionEvidenceEligible(location)) {
            updateNotification(force = false, pointTimestamp = timestamp)
            return
        }
        lastLocation = Location(location)
        lastLocationObservedAt = observedAt
        if (currentProfile == TrackingStateStore.PROFILE_STATIONARY) {
            val reference = stationaryReferenceLocation
            if (reference == null) {
                stationaryReferenceLocation = Location(location)
            } else {
                val certainDisplacement = reference.distanceTo(location) -
                    reference.accuracy.coerceAtLeast(0f) - location.accuracy.coerceAtLeast(0f)
                if (certainDisplacement >= configuration.stationaryProbeDisplacementMeters) {
                movingEvidence = MOVING_EVIDENCE_REQUIRED
                switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_LEGACY_POLICY)
                }
            }
        } else if (hasHighConfidenceStillActivity()) {
            stationaryDisplacementWindow.add(
                StationaryGpsFix(
                    location.latitude,
                    location.longitude,
                    observedAt,
                    location.accuracy.toDouble(),
                ),
                configuration.stationaryTimeoutMs,
            )
            tryEnterStationaryProfile()
        }

        updateNotification(force = false, pointTimestamp = timestamp)
    }

    private fun isMotionEvidenceEligible(location: Location): Boolean {
        if (!location.hasAccuracy()) return false
        val accuracy = location.accuracy.toDouble()
        if (!accuracy.isFinite() || accuracy <= 0.0 ||
            accuracy > configuration.maximumAcceptedAccuracyMeters
        ) {
            return false
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            !location.isMock
        } else {
            @Suppress("DEPRECATION")
            !location.isFromMockProvider
        }
    }

    /**
     * Evidence state and age of the latest activity reading at a fix. A
     * reading is aged at the fix, not at its own delivery; readings that were
     * never available keep their state.
     */
    private fun activityEvidenceAt(fixReceivedAt: Long): Pair<Any?, Any?> {
        val activity = latestActivity ?: return null to null
        val state = activity["evidenceState"]
        val observedAt = activity["timestamp"] as? Long
        if (observedAt == null || (state != "fresh" && state != "stale")) {
            return state to activity["ageMs"]
        }
        val age = (fixReceivedAt - observedAt).coerceAtLeast(0L)
        val fresh = age <= configuration.activityFreshnessThresholdMs
        return (if (fresh) "fresh" else "stale") to age
    }

    private fun handleActivity(
        activityType: Int,
        confidence: Int,
        timestamp: Long,
        probabilitiesJson: String? = null,
        source: String = "android_activity_recognition",
        episodeStartedAt: Long? = null,
    ) {
        if (timestamp < (latestActivityTimestamps[source] ?: 0L)) return
        latestActivityTimestamps[source] = timestamp
        val now = System.currentTimeMillis()
        val age = (now - timestamp).coerceAtLeast(0L)
        val fresh = age <= configuration.activityFreshnessThresholdMs
        val event = LinkedHashMap(ActivityMapper.event(activityType, confidence, timestamp)).apply {
            put("available", true)
            put("source", source)
            put("evidenceState", if (fresh) "fresh" else "stale")
            put("ageMs", age)
            put("probabilities", parseActivityProbabilities(probabilitiesJson))
            if (episodeStartedAt != null) put("episodeStartedAt", episodeStartedAt)
        }
        latestActivity = event
        publishActivity(event)

        val type = event["type"] as String
        // Walking and vehicle readings are step-counter watchdog evidence,
        // fed before any profile switch the reading causes.
        stepCounter.onActivity(
            type,
            confidence.coerceIn(0, 100),
            SystemClock.elapsedRealtime() - age,
        )
        val policy = stationaryPolicy
        if (policy != null) {
            val confidentStill =
                type == "stationary" && confidence >= configuration.stationaryConfidenceThreshold
            if (confidentStill) {
                motionSensorFusion.requestAmbiguityProbe(stationaryCandidate = true)
            } else if (type !in MOVING_ACTIVITY_TYPES) {
                motionSensorFusion.requestAmbiguityProbe()
            }
            applyStationaryPolicy(
                policy.onReading(
                    StationaryPolicyV2.Reading(type, confidence, timestamp, source),
                    now,
                ),
            )
            return
        }
        if (!fresh) {
            stillSince = null
            stationaryDisplacementWindow.reset()
            movingEvidence = 0
            mainHandler.removeCallbacks(stationaryTransition)
            motionSensorFusion.requestAmbiguityProbe()
            if (configuration.staleActivityFallback == "keepMovingProfile" ||
                configuration.captureIntent != "adaptive"
            ) {
                switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_LEGACY_POLICY)
            }
            return
        }
        when {
            type == "stationary" && confidence >= configuration.stationaryConfidenceThreshold -> {
                // An explicit travel intent is a fidelity contract. Activity
                // recognition can report stationary while a pocketed rider is
                // moving, so only adaptive capture may reduce GPS sampling.
                if (configuration.captureIntent != "adaptive") {
                    stillSince = null
                    stationaryDisplacementWindow.reset()
                    mainHandler.removeCallbacks(stationaryTransition)
                    switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_LEGACY_POLICY)
                    return
                }
                movingEvidence = 0
                if (stillSince == null) {
                    val now = System.currentTimeMillis()
                    stillSince = now
                    val baseline = recentStationaryBaseline(now)
                    stationaryDisplacementWindow.begin(now, baseline)
                    mainHandler.removeCallbacks(stationaryTransition)
                    mainHandler.postDelayed(
                        stationaryTransition,
                        configuration.stationaryTimeoutMs,
                    )
                }
                motionSensorFusion.requestAmbiguityProbe(stationaryCandidate = true)
                tryEnterStationaryProfile()
            }

            type in MOVING_ACTIVITY_TYPES && confidence >= configuration.movingConfidenceThreshold -> {
                stillSince = null
                stationaryDisplacementWindow.reset()
                mainHandler.removeCallbacks(stationaryTransition)
                movingEvidence += 1
                if (movingEvidence >= configuration.movingConfirmationCount) {
                    movingEvidence = 0
                    switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_LEGACY_POLICY)
                }
            }

            else -> {
                stillSince = null
                stationaryDisplacementWindow.reset()
                movingEvidence = 0
                mainHandler.removeCallbacks(stationaryTransition)
                motionSensorFusion.requestAmbiguityProbe()
                if (configuration.unknownMotionFallback == "keepMovingProfile" ||
                    configuration.captureIntent != "adaptive"
                ) {
                    switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_LEGACY_POLICY)
                }
            }
        }
    }

    private fun parseActivityProbabilities(value: String?): Map<String, Int> {
        if (value.isNullOrBlank()) return emptyMap()
        return runCatching {
            val json = JSONObject(value)
            buildMap {
                json.keys().forEach { key ->
                    put(key, json.optInt(key, 0).coerceIn(0, 100))
                }
            }
        }.getOrDefault(emptyMap())
    }

    private fun newStationaryPolicy(): StationaryPolicyV2? =
        if (configuration.usesStationaryPolicyV2) {
            StationaryPolicyV2(
                stationaryConfidenceThreshold = configuration.stationaryConfidenceThreshold,
                movingConfidenceThreshold = configuration.movingConfidenceThreshold,
                movingConfirmationCount = configuration.movingConfirmationCount,
                confirmationMs = configuration.stationaryTimeoutMs,
                maximumAcceptedAccuracyMeters = configuration.maximumAcceptedAccuracyMeters,
            )
        } else {
            null
        }

    /**
     * Installs the state machine for a configuration applied mid-capture. Its
     * evidence starts over, so a stationary route fails open to moving.
     */
    private fun replaceStationaryPolicy() {
        stationaryPolicy = newStationaryPolicy()
        if (currentProfile == TrackingStateStore.PROFILE_STATIONARY) {
            switchProfile(TrackingStateStore.PROFILE_MOVING, PROFILE_REASON_CONFIGURATION_UPDATE)
        }
    }

    private fun handleStationaryPolicyFix(policy: StationaryPolicyV2, location: Location) {
        val mocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }
        val hasSpeedAccuracy = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasSpeedAccuracy()
        val hasVerticalAccuracy = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            location.hasVerticalAccuracy()
        if (location.hasAccuracy() && !mocked &&
            location.accuracy.toDouble() <= configuration.maximumAcceptedAccuracyMeters
        ) {
            lastLocation = Location(location)
            lastLocationObservedAt = System.currentTimeMillis()
        }
        applyStationaryPolicy(
            policy.onFix(
                StationaryPolicyV2.Fix(
                    latitude = location.latitude,
                    longitude = location.longitude,
                    accuracyMeters = location.accuracy.toDouble().takeIf { location.hasAccuracy() },
                    speed = location.speed.toDouble().takeIf { location.hasSpeed() },
                    speedAccuracy = if (hasSpeedAccuracy) {
                        location.speedAccuracyMetersPerSecond.toDouble()
                    } else {
                        null
                    },
                    hasVerticalAccuracy = hasVerticalAccuracy,
                    mocked = mocked,
                    // The fix's own time, so batched deliveries keep their spacing.
                    observedAtMs = location.time,
                ),
            ),
        )
    }

    private fun applyStationaryPolicy(profile: StationaryPolicyV2.Profile) {
        val target = if (profile == StationaryPolicyV2.Profile.STATIONARY) {
            TrackingStateStore.PROFILE_STATIONARY
        } else {
            TrackingStateStore.PROFILE_MOVING
        }
        if (captureStarted && target != currentProfile) {
            switchProfile(target, stationaryPolicy?.lastTransitionReason)
        }
    }

    private fun switchProfile(profile: String, reason: String?) {
        if (!captureStarted || profile == currentProfile) return
        val previousProfile = currentProfile
        currentProfile = profile
        val exitedStationary = previousProfile == TrackingStateStore.PROFILE_STATIONARY &&
            profile == TrackingStateStore.PROFILE_MOVING
        // Journaled with the next fix; fixes captured before now keep the
        // previous profile.
        decisionInputs.onProfileSwitch(
            atElapsedNanos = SystemClock.elapsedRealtimeNanos(),
            atEpochMs = System.currentTimeMillis(),
            from = previousProfile,
            to = profile,
            reason = reason,
        )
        stepCounter.onProfileSwitch(exitedStationary)
        if (exitedStationary) scheduleStepCounterEvaluation()
        if (profile == TrackingStateStore.PROFILE_STATIONARY) {
            stationaryReferenceLocation = lastLocation?.let(::Location)
            stationaryDisplacementWindow.reset()
            stateStore.markState(
                TrackingStateStore.STATE_STATIONARY,
                profile,
                transitionReason = reason,
            )
        } else {
            stationaryReferenceLocation = null
            stillSince = null
            stationaryDisplacementWindow.reset()
            mainHandler.removeCallbacks(stationaryTransition)
            stateStore.markState(
                TrackingStateStore.STATE_TRACKING,
                profile,
                transitionReason = reason,
            )
        }
        stateStore.emitCurrentStatus()
        requestLocationUpdates(profile)
        if (exitedStationary) requestStationaryExitProbe()
        updateNotification(force = true)
    }

    private fun requestStationaryExitProbe() {
        if (!captureStarted || !hasLocationPermission()) return
        val token = stationaryExitProbeCoordinator.begin()
        stateStore.markStationaryExitProbeRequested()
        stateStore.emitCurrentStatus()
        // Some step counters went silent after this AP-waking request.
        stepCounter.onExitProbe()
        scheduleStepCounterEvaluation()

        // Deliver batched fixes before asking for a fresh one. A fresh fix
        // journaled ahead of older flushed fixes made Dart reject those as
        // non-monotonic. The probe starts when the flush completes, or after
        // a short wait if the flush is slow.
        val requestFreshFix = object : Runnable {
            private var requested = false

            override fun run() {
                if (requested) return
                requested = true
                // A newer probe may already own the wait slot.
                if (stationaryExitFlushWait === this) stationaryExitFlushWait = null
                requestFreshProbeFix(token)
            }
        }
        stationaryExitFlushWait?.let(mainHandler::removeCallbacks)
        stationaryExitFlushWait = requestFreshFix
        mainHandler.postDelayed(requestFreshFix, STATIONARY_EXIT_FLUSH_WAIT_MS)
        fusedLocationClient.flushLocations()
            .addOnSuccessListener {
                if (captureStarted) stateStore.markStationaryExitFlushOutcome("succeeded")
            }
            .addOnFailureListener { error ->
                if (captureStarted) {
                    stateStore.markStationaryExitFlushOutcome("failed")
                    stateStore.markLocationRequestFailure(
                        "Stationary-exit flush failed: ${error.message.orEmpty()}",
                    )
                }
            }
            .addOnCompleteListener {
                mainHandler.removeCallbacks(requestFreshFix)
                requestFreshFix.run()
            }
    }

    /**
     * Requests one fresh, fine fix for [token]: never a cached location, and
     * bounded by the probe timeout.
     */
    /**
     * `late` when a fix arrives behind a newer fix of the same capture
     * generation (out-of-order batch or flush delivery). Late fixes are still
     * journaled; the tag only explains why Dart rejects them as non-monotonic.
     * Provider callbacks arrive on the worker looper and probe fixes on the
     * main thread, hence the lock.
     */
    private fun registerPowerReceiver() {
        if (powerReceiverRegistered) return
        batteryLow = isBatteryLowNow()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SHUTDOWN)
            addAction(ACTION_QUICKBOOT_POWEROFF)
            addAction(Intent.ACTION_BATTERY_LOW)
            addAction(Intent.ACTION_BATTERY_OKAY)
        }
        // System broadcasts only; nothing outside the app may send them here.
        ContextCompat.registerReceiver(this, powerReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        powerReceiverRegistered = true
    }

    private fun unregisterPowerReceiver() {
        if (!powerReceiverRegistered) return
        powerReceiverRegistered = false
        runCatching { unregisterReceiver(powerReceiver) }
    }

    private fun isBatteryLowNow(): Boolean {
        val status = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return status.getBooleanExtra(BatteryManager.EXTRA_BATTERY_LOW, false)
        }
        val level = status.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = status.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        return level >= 0 && scale > 0 && level * 100 <= scale * LOW_BATTERY_PERCENT
    }

    private fun onBatteryLowChanged(low: Boolean) {
        if (!captureStarted || batteryLow == low) return
        batteryLow = low
        requestLocationUpdates(currentProfile)
    }

    /**
     * The device is shutting down. Hand batched fixes to the callback, then
     * wait until the journal has committed every write queued before the fence,
     * so a dying phone loses no captured fix. Android allows a receiver only a
     * few seconds here, so the wait is bounded.
     */
    private fun onDeviceShutdown(pending: BroadcastReceiver.PendingResult) {
        var finished = false
        val finish = Runnable {
            if (finished) return@Runnable
            finished = true
            pending.finish()
        }
        if (!captureStarted) {
            finish.run()
            return
        }
        stateStore.markShutdownObserved()
        mainHandler.postDelayed(finish, SHUTDOWN_FLUSH_WAIT_MS)
        // The final steps and the journal fence both complete inside the same
        // bounded wait.
        var partsLeft = 2
        val partDone = Runnable { if (--partsLeft == 0) finish.run() }
        stepCounter.finalize { snapshot ->
            persistStepFinal(snapshot)
            partDone.run()
        }
        fusedLocationClient.flushLocations().addOnCompleteListener {
            // Flushed deliveries are already queued on the worker looper; the
            // journal fence follows the writes they enqueue.
            workerHandler.post {
                val fenced = PendingLocationCoordinator.execute(
                    applicationContext,
                    onFailure = { mainHandler.post(partDone) },
                ) { mainHandler.post(partDone) }
                if (!fenced) mainHandler.post(partDone)
            }
        }
    }

    @Synchronized
    private fun deliveryOrder(generationId: String, elapsedRealtimeNanos: Long): String {
        if (generationId != deliveryHighWaterGeneration) {
            deliveryHighWaterGeneration = generationId
            deliveryHighWaterNanos = Long.MIN_VALUE
        }
        if (elapsedRealtimeNanos < deliveryHighWaterNanos) return "late"
        deliveryHighWaterNanos = elapsedRealtimeNanos
        return "inOrder"
    }

    private fun requestFreshProbeFix(token: Long) {
        if (!captureStarted) return
        if (!hasLocationPermission()) {
            completeStationaryExitProbe(token, "permission_unavailable")
            return
        }
        if (!stationaryExitProbeCoordinator.beginCurrentFixRequest(token)) return
        stationaryExitProbeCancellation?.cancel()
        val cancellation = CancellationTokenSource()
        stationaryExitProbeCancellation = cancellation

        val timeout = Runnable {
            if (!stationaryExitProbeCoordinator.complete(token)) return@Runnable
            cancellation.cancel()
            stationaryExitProbeCancellation = null
            stationaryExitProbeTimeout = null
            stateStore.markStationaryExitProbeCompleted("timed_out")
            stateStore.emitCurrentStatus()
        }
        stationaryExitProbeTimeout?.let(mainHandler::removeCallbacks)
        stationaryExitProbeTimeout = timeout
        mainHandler.postDelayed(timeout, STATIONARY_EXIT_PROBE_TIMEOUT_MS)

        try {
            fusedLocationClient.getCurrentLocation(
                CurrentLocationRequest.Builder()
                    .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
                    .setMaxUpdateAgeMillis(0)
                    .setGranularity(Granularity.GRANULARITY_FINE)
                    .setDurationMillis(STATIONARY_EXIT_PROBE_TIMEOUT_MS)
                    .build(),
                cancellation.token,
            ).addOnSuccessListener { location ->
                if (location == null) {
                    completeStationaryExitProbe(token, "no_fix")
                } else {
                    noteStepWatchdogFix(location)
                    handleLocation(location, CAPTURE_ORIGIN_EXIT_PROBE) {
                        completeStationaryExitProbe(token, "succeeded")
                    }
                    if (stationaryPolicyFedPerProviderFix) feedStationaryPolicyOnDelivery(location)
                }
            }.addOnFailureListener { error ->
                stateStore.markLocationRequestFailure(
                    "Stationary-exit probe failed: ${error.message.orEmpty()}",
                )
                completeStationaryExitProbe(token, "failed")
            }
        } catch (error: SecurityException) {
            stateStore.markLocationRequestFailure(
                "Stationary-exit probe permission failure: ${error.message.orEmpty()}",
            )
            completeStationaryExitProbe(token, "permission_unavailable")
        }
    }

    private fun completeStationaryExitProbe(token: Long, outcome: String) {
        if (!stationaryExitProbeCoordinator.complete(token)) return
        stationaryExitProbeTimeout?.let(mainHandler::removeCallbacks)
        stationaryExitProbeTimeout = null
        stationaryExitFlushWait?.let(mainHandler::removeCallbacks)
        stationaryExitFlushWait = null
        stationaryExitProbeCancellation = null
        stateStore.markStationaryExitProbeCompleted(outcome)
        stateStore.emitCurrentStatus()
    }

    private fun failCapture(message: String) {
        if (deferredToMainThread { failCapture(message) }) return
        // Capture is already ending; the waiting stop decides how.
        if (pendingStop != null) return
        stopAfterFinalSteps(STOP_KIND_FAILURE) {
            stopCapture()
            stateStore.fail(message)
            stateStore.emitCurrentStatus()
            runCatching { removeForegroundNotification() }
            stopSelf()
        }
    }

    private fun interruptCapture(message: String) {
        if (deferredToMainThread { interruptCapture(message) }) return
        if (pendingStop != null) return
        stopAfterFinalSteps(STOP_KIND_FAILURE) {
            stopCapture()
            stateStore.interrupt(message)
            stateStore.emitCurrentStatus()
            runCatching { removeForegroundNotification() }
            stopSelf()
        }
    }

    /**
     * Failures found on the provider thread end capture on the main thread,
     * which owns the stop path; [action] runs there only if the same capture
     * generation is still running. False when already on the main thread.
     */
    private fun deferredToMainThread(action: () -> Unit): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return false
        val generationId = stateStore.captureGenerationId
        mainHandler.post {
            if (captureStarted && stateStore.captureGenerationId == generationId) action()
        }
        return true
    }

    /**
     * The per-fix prerequisite check, reused for 30 s once it passes. Each
     * check costs binder calls; the 60 s prerequisite monitor and the provider
     * itself still catch revocations between checks.
     */
    private fun checkActivePrerequisitesForFix(): Boolean {
        val now = SystemClock.elapsedRealtime()
        if (now - lastPrerequisiteCheckPassedAt < PREREQUISITE_FIX_CHECK_INTERVAL_MS) return true
        val passed = checkActivePrerequisites()
        if (passed) lastPrerequisiteCheckPassedAt = now
        return passed
    }

    private fun checkActivePrerequisites(): Boolean {
        if (!hasLocationPermission()) {
            interruptCapture("tracking_interrupted_location_permission_revoked")
            return false
        }
        if (!TrackingStateStore.isLocationServiceEnabled(this)) {
            interruptCapture("tracking_interrupted_location_services_disabled")
            return false
        }
        return true
    }

    private fun removeForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun ensureForeground() {
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification(force: Boolean, pointTimestamp: Long? = null) {
        val now = System.currentTimeMillis()
        if (!force && now - lastNotificationUpdateAt < NOTIFICATION_UPDATE_INTERVAL_MS) return
        lastNotificationUpdateAt = now

        val suffix = when (currentProfile) {
            TrackingStateStore.PROFILE_STATIONARY -> " · Stationary battery mode"
            TrackingStateStore.PROFILE_MOVING -> " · Moving"
            else -> ""
        }
        val timeSuffix = pointTimestamp?.let {
            " · Updated ${android.text.format.DateFormat.format("HH:mm", it)}"
        }.orEmpty()
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(
            NOTIFICATION_ID,
            buildNotification("${configuration.notificationText}$suffix$timeSuffix"),
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            configuration.notificationChannelId,
            configuration.notificationChannelName,
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = configuration.notificationChannelDescription
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String = configuration.notificationText): android.app.Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                REQUEST_OPEN_APP,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val pauseIntent = PendingIntent.getService(
            this,
            REQUEST_PAUSE,
            Intent(this, LocationTrackingService::class.java).apply {
                action = ACTION_PAUSE
                putExtra(EXTRA_COMMAND_SOURCE, COMMAND_SOURCE_NOTIFICATION)
                putExtra(EXTRA_ACTION_REASON, "notification_paused")
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            REQUEST_STOP,
            Intent(this, LocationTrackingService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_COMMAND_SOURCE, COMMAND_SOURCE_NOTIFICATION)
                putExtra(EXTRA_ACTION_REASON, "notification_stopped")
                putExtra(EXTRA_STOP_REASON, "notification_stopped")
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, configuration.notificationChannelId)
            .setSmallIcon(R.drawable.ic_location_tracking)
            .setContentTitle(configuration.notificationTitle)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(R.drawable.ic_location_tracking, "Pause", pauseIntent)
            .addAction(R.drawable.ic_location_tracking, "Stop", stopIntent)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()
    }

    private fun removeCurrentActivityUpdates(clearGeneration: Boolean) {
        val pendingIntent = currentActivityPendingIntent
        if (pendingIntent != null) {
            runCatching { activityRecognitionClient.removeActivityUpdates(pendingIntent) }
            pendingIntent.cancel()
            currentActivityPendingIntent = null
        } else if (::stateStore.isInitialized) {
            val trackId = stateStore.activeTrackId
            val generation = stateStore.activityRecognitionGeneration
            if (trackId != null && generation != null) {
                runCatching {
                    activityRecognitionClient.removeActivityUpdates(
                        activityPendingIntent(trackId, generation),
                    )
                }
                runCatching {
                    activityRecognitionClient.removeActivityTransitionUpdates(
                        activityTransitionPendingIntent(trackId, generation),
                    )
                }
            }
        }
        val transitionPendingIntent = currentActivityTransitionPendingIntent
        if (transitionPendingIntent != null) {
            runCatching {
                activityRecognitionClient.removeActivityTransitionUpdates(
                    transitionPendingIntent,
                )
            }
            transitionPendingIntent.cancel()
            currentActivityTransitionPendingIntent = null
        }
        if (clearGeneration && ::stateStore.isInitialized) {
            runCatching { stateStore.clearActivityRecognitionGeneration() }
        }
    }

    private fun requestActivityTransitionUpdates(trackId: String, generation: Long) {
        val activities = intArrayOf(
            DetectedActivity.STILL,
            DetectedActivity.WALKING,
            DetectedActivity.RUNNING,
            DetectedActivity.ON_BICYCLE,
            DetectedActivity.IN_VEHICLE,
        )
        val transitions = activities.flatMap { activityType ->
            listOf(
                ActivityTransition.Builder()
                    .setActivityType(activityType)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                    .build(),
                ActivityTransition.Builder()
                    .setActivityType(activityType)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                    .build(),
            )
        }
        val pendingIntent = activityTransitionPendingIntent(trackId, generation)
        currentActivityTransitionPendingIntent = pendingIntent
        activityRecognitionClient.requestActivityTransitionUpdates(
            ActivityTransitionRequest(transitions),
            pendingIntent,
        ).addOnFailureListener {
            if (currentActivityTransitionPendingIntent == pendingIntent) {
                currentActivityTransitionPendingIntent = null
                pendingIntent.cancel()
            }
        }
    }

    private fun activityPendingIntent(trackId: String, generation: Long): PendingIntent {
        val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val requestCode = (
            REQUEST_ACTIVITY_RECOGNITION +
                (generation % ACTIVITY_RECOGNITION_REQUEST_CODE_SPAN)
            ).toInt()
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            Intent(this, ActivityRecognitionReceiver::class.java).apply {
                action = ActivityRecognitionReceiver.ACTION_ACTIVITY_RECOGNITION
                data = Uri.parse("flutter-background-location://activity/$generation")
                putExtra(EXTRA_TRACK_ID, trackId)
                putExtra(EXTRA_ACTIVITY_GENERATION, generation)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
        )
    }

    private fun activityTransitionPendingIntent(
        trackId: String,
        generation: Long,
    ): PendingIntent {
        val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val requestCode = (
            REQUEST_ACTIVITY_TRANSITION +
                (generation % ACTIVITY_RECOGNITION_REQUEST_CODE_SPAN)
            ).toInt()
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            Intent(this, ActivityRecognitionReceiver::class.java).apply {
                action = ActivityRecognitionReceiver.ACTION_ACTIVITY_TRANSITION
                data = Uri.parse("flutter-background-location://activity-transition/$generation")
                putExtra(EXTRA_TRACK_ID, trackId)
                putExtra(EXTRA_ACTIVITY_GENERATION, generation)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
        )
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasActivityRecognitionPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Counts the capture generation's steps when the device has a step
     * counter and, from Android 10, activity recognition is granted. Called
     * again by the prerequisite monitor, which retries a failed registration.
     */
    private fun startStepCounter() {
        val generationId = stateStore.captureGenerationId ?: return
        if (captureStarted && hasActivityRecognitionPermission()) {
            stepCounter.start(generationId, configuration.movingConfidenceThreshold)
        }
    }

    /**
     * Flushes the step counter as a liveness probe, lets its watchdog compare
     * it with the motion evidence, and checkpoints the generation's steps so
     * a process death leaves them behind.
     */
    private fun evaluateStepCounter() {
        if (!captureStarted) return
        stepCounter.evaluate(flushFirst = FLUSH_STEPS_ON_HEARTBEAT) { snapshot ->
            if (captureStarted &&
                snapshot.generationId == stateStore.captureGenerationId &&
                snapshot.generationId != stepFinalPersistedFor
            ) {
                stateStore.checkpointSteps(snapshot)
            }
        }
    }

    /** Checks the step counter again 60 s after a stationary exit or exit probe. */
    private fun scheduleStepCounterEvaluation() {
        mainHandler.removeCallbacks(stepCounterEvaluation)
        mainHandler.postDelayed(stepCounterEvaluation, STEP_COUNTER_EVALUATION_DELAY_MS)
    }

    /** Device state for step-counter diagnostics; read on the worker thread. */
    private fun stepCounterEnvironment(): StepCounterEnvironment {
        val power = getSystemService(POWER_SERVICE) as PowerManager
        return StepCounterEnvironment(
            wakeLockHeld = captureWakeLock?.isHeld == true,
            screenOn = power.isInteractive,
            deviceIdle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                power.isDeviceIdleMode
            } else {
                null
            },
            standbyBucket = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                (getSystemService(USAGE_STATS_SERVICE) as? UsageStatsManager)?.appStandbyBucket
            } else {
                null
            },
        )
    }

    private fun hasHighConfidenceStillActivity(): Boolean {
        val type = latestActivity?.get("type") as? String
        val confidence = (latestActivity?.get("confidence") as? Number)?.toInt() ?: 0
        return type == "stationary" &&
            confidence >= configuration.stationaryConfidenceThreshold
    }

    private fun recentStationaryBaseline(now: Long): StationaryGpsFix? {
        val location = lastLocation ?: return null
        val observedAt = lastLocationObservedAt ?: return null
        val freshnessWindow = configuration.movingIntervalMs
            .coerceAtMost(Long.MAX_VALUE / 2L)
            .times(2L)
            .coerceAtLeast(MINIMUM_BASELINE_FRESHNESS_MS)
        if (now < observedAt || now - observedAt > freshnessWindow) return null
        return StationaryGpsFix(
            location.latitude,
            location.longitude,
            now,
            location.accuracy.toDouble().coerceAtLeast(0.0),
        )
    }

    private fun tryEnterStationaryProfile() {
        stationaryPolicy?.let {
            applyStationaryPolicy(it.evaluate(System.currentTimeMillis()))
            return
        }
        val beganAt = stillSince ?: return
        if (!captureStarted || currentProfile != TrackingStateStore.PROFILE_MOVING) return
        if (configuration.captureIntent != "adaptive") return
        if (!hasHighConfidenceStillActivity()) return
        if (configuration.motionFusionMode == "enhancedSensorFusion") {
            val evidence = TrackingEventBus.lastMotionEvidence ?: return
            val observedAt = (evidence["observedAt"] as? Number)?.toLong() ?: return
            val age = (System.currentTimeMillis() - observedAt).coerceAtLeast(0L)
            if (evidence["state"] != "stationary" ||
                age > configuration.motionEvidenceFreshnessMs
            ) {
                return
            }
        }
        if (System.currentTimeMillis() - beganAt < configuration.stationaryTimeoutMs) return
        if (!stationaryDisplacementWindow.hasLowDisplacement(
                configuration.stationaryTimeoutMs,
                configuration.stationaryProbeDisplacementMeters,
            )
        ) {
            return
        }
        switchProfile(TrackingStateStore.PROFILE_STATIONARY, PROFILE_REASON_LEGACY_POLICY)
    }

    private fun recordNotificationActionIfNeeded(
        intent: Intent,
        action: String,
        fallbackReason: String,
    ) {
        if (intent.getStringExtra(EXTRA_COMMAND_SOURCE) != COMMAND_SOURCE_NOTIFICATION) return
        val trackId = stateStore.activeTrackId ?: return
        val reason = intent.getStringExtra(EXTRA_ACTION_REASON) ?: fallbackReason
        stateStore.recordPendingUserAction(trackId, action, reason)
    }

    /** A stop path of [kind] waiting for the final steps. */
    private class PendingStop(val kind: Int, val stop: () -> Unit)

    companion object {
        internal const val ACTION_START =
            "com.samir.flutter_background_location.action.START"
        internal const val ACTION_RESUME =
            "com.samir.flutter_background_location.action.RESUME"
        internal const val ACTION_PAUSE =
            "com.samir.flutter_background_location.action.PAUSE"
        internal const val ACTION_STOP =
            "com.samir.flutter_background_location.action.STOP"
        internal const val ACTION_RESTORE =
            "com.samir.flutter_background_location.action.RESTORE"
        internal const val ACTION_UPDATE_CONFIG =
            "com.samir.flutter_background_location.action.UPDATE_CONFIG"
        internal const val ACTION_ACTIVITY_UPDATE =
            "com.samir.flutter_background_location.action.ACTIVITY_UPDATE"

        internal const val EXTRA_TRACK_ID = "track_id"
        internal const val EXTRA_CONFIGURATION = "tracking_configuration"
        internal const val EXTRA_STOP_REASON = "stop_reason"
        internal const val EXTRA_COMMAND_SOURCE = "command_source"
        internal const val EXTRA_ACTION_REASON = "action_reason"
        internal const val EXTRA_ACTIVITY_TYPE = "activity_type"
        internal const val EXTRA_ACTIVITY_CONFIDENCE = "activity_confidence"
        internal const val EXTRA_ACTIVITY_TIMESTAMP = "activity_timestamp"
        internal const val EXTRA_ACTIVITY_GENERATION = "activity_generation"
        internal const val EXTRA_ACTIVITY_PROBABILITIES = "activity_probabilities"
        internal const val EXTRA_ACTIVITY_SOURCE = "activity_source"
        internal const val EXTRA_ACTIVITY_EPISODE_STARTED_AT = "activity_episode_started_at"

        private const val NOTIFICATION_ID = 45_001
        private const val REQUEST_OPEN_APP = 45_001
        private const val REQUEST_PAUSE = 45_002
        private const val REQUEST_STOP = 45_003
        private const val REQUEST_ACTIVITY_RECOGNITION = 45_004
        private const val REQUEST_ACTIVITY_TRANSITION = 55_004
        private const val ACTIVITY_RECOGNITION_REQUEST_CODE_SPAN = 10_000L
        private const val NOTIFICATION_UPDATE_INTERVAL_MS = 60_000L
        private const val SERVICE_HEARTBEAT_INTERVAL_MS = 60_000L
        private const val PREREQUISITE_MONITOR_INTERVAL_MS = 60_000L
        private const val MINIMUM_BASELINE_FRESHNESS_MS = 30_000L
        private const val STATIONARY_EXIT_PROBE_TIMEOUT_MS = 15_000L
        private const val STATIONARY_EXIT_FLUSH_WAIT_MS = 2_000L
        private const val SHUTDOWN_FLUSH_WAIT_MS = 4_000L
        private const val PREREQUISITE_FIX_CHECK_INTERVAL_MS = 30_000L
        private const val FIX_STATUS_LIVENESS_INTERVAL_MS = 10_000L
        private const val STEP_COUNTER_EVALUATION_DELAY_MS = 60_000L

        // Kill switch for the heartbeat's step-counter flush (a liveness probe).
        private const val FLUSH_STEPS_ON_HEARTBEAT = true

        // Stop paths by rank: a waiting stop is replaced only by a higher one.
        private const val STOP_KIND_FAILURE = 0
        private const val STOP_KIND_PAUSE = 1
        private const val STOP_KIND_STOP = 2
        private const val LOW_BATTERY_PERCENT = 15
        // Fast-boot power-off on some OEM builds instead of ACTION_SHUTDOWN.
        private const val ACTION_QUICKBOOT_POWEROFF = "android.intent.action.QUICKBOOT_POWEROFF"
        private const val CAPTURE_ORIGIN_PROVIDER_STREAM = "providerStream"
        private const val CAPTURE_ORIGIN_EXIT_PROBE = "exitProbe"

        // Profile changes outside motion policy 2, reported in status.
        private const val PROFILE_REASON_LEGACY_POLICY = "legacy_policy"
        private const val PROFILE_REASON_CONFIGURATION_UPDATE = "configuration_update"
        private const val CAPTURE_REASON_NEW_TRACK = "new_track"
        private const val CAPTURE_REASON_RESUME = "resume"
        private const val CAPTURE_REASON_PROCESS_RECOVERY = "process_recovery"
        private const val COMMAND_SOURCE_NOTIFICATION = "notification"
        private const val MOVING_EVIDENCE_REQUIRED = 2
        private val MOVING_ACTIVITY_TYPES = setOf("walking", "running", "cycling", "automotive")

        @Volatile
        internal var isServiceAliveNow: Boolean = false
            private set

        @Volatile
        internal var isCaptureAliveNow: Boolean = false
            private set

        /** The running service, for in-process activity hand-off. */
        @Volatile
        internal var liveService: LocationTrackingService? = null
            private set

        /** Steps of capture generation [generationId]; null when not counted. */
        internal fun stepCount(generationId: String?): Long? =
            liveService?.takeIf { it.captureStarted }?.stepCounter?.steps(generationId)

        /** The `stepCoverage` map of live generation [generationId]; null when not capturing. */
        internal fun stepCoverage(generationId: String?): Map<String, Any?>? =
            liveService?.takeIf { it.captureStarted }?.stepCounter?.coverage(generationId)?.toMap()

        /**
         * Delivers the step counter's batched readings, then runs [then] on
         * the main thread, so a status read before a pause has every step.
         */
        internal fun flushStepCount(then: () -> Unit) {
            val counter = liveService?.takeIf { it.captureStarted }?.stepCounter
            if (counter == null) then() else counter.flush(then)
        }
    }
}
