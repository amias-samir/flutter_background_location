package com.samir.flutter_background_location

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityRecognitionClient
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.Granularity
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import java.util.UUID

class LocationTrackingService : Service() {
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private lateinit var activityRecognitionClient: ActivityRecognitionClient
    private lateinit var stateStore: TrackingStateStore
    private lateinit var workerThread: HandlerThread

    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var workerHandler: Handler
    private var configuration = TrackingConfiguration()
    @Volatile
    private var captureStarted = false
    private var currentProfile = TrackingStateStore.PROFILE_IDLE
    private var requestGeneration = 0
    private var currentActivityPendingIntent: PendingIntent? = null
    private val monotonicDomainId = "android_process_${UUID.randomUUID()}"
    private var latestActivity: Map<String, Any?>? = null
    private var lastLocation: Location? = null
    private var lastLocationObservedAt: Long? = null
    private var stationaryReferenceLocation: Location? = null
    private val stationaryDisplacementWindow = StationaryDisplacementWindow()
    private var stillSince: Long? = null
    private var movingEvidence = 0
    private var lastNotificationUpdateAt = 0L
    private var journalPrepareInProgress = false
    private var journalPrepareGeneration = 0

    private val stationaryTransition = Runnable {
        tryEnterStationaryProfile()
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            if (!captureStarted) return
            stateStore.markServiceHeartbeat(captureActive = true)
            stateStore.emitCurrentStatus()
            mainHandler.postDelayed(this, SERVICE_HEARTBEAT_INTERVAL_MS)
        }
    }

    private val prerequisiteMonitor = object : Runnable {
        override fun run() {
            if (!captureStarted) return
            if (!checkActivePrerequisites()) return
            mainHandler.postDelayed(this, PREREQUISITE_MONITOR_INTERVAL_MS)
        }
    }

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            if (!captureStarted) return
            result.locations.forEach(::handleLocation)
        }
    }

    override fun onCreate() {
        super.onCreate()
        workerThread = HandlerThread("fbl-location-service").apply { start() }
        workerHandler = Handler(workerThread.looper)
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)
        activityRecognitionClient = ActivityRecognition.getClient(this)
        isServiceAliveNow = true
        isCaptureAliveNow = false
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
            TrackingServiceLifecycle.shouldRemainStarted(
                captureStarted = captureStarted || journalPrepareInProgress,
                trackingEnabled = stateStore.trackingEnabled,
                isPaused = stateStore.isPaused,
                hasTrackId = stateStore.activeTrackId != null,
            )
        }

    override fun onDestroy() {
        mainHandler.removeCallbacks(stationaryTransition)
        mainHandler.removeCallbacks(heartbeat)
        mainHandler.removeCallbacks(prerequisiteMonitor)
        requestGeneration += 1
        captureStarted = false
        isCaptureAliveNow = false
        isServiceAliveNow = false
        stationaryDisplacementWindow.reset()
        runCatching { fusedLocationClient.removeLocationUpdates(locationCallback) }
        removeCurrentActivityUpdates(clearGeneration = false)
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
        } else {
            stateStore.resume()
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
        stateStore.emitCurrentStatus()
        startCapture()
    }

    private fun pauseTrack(intent: Intent) {
        recordNotificationActionIfNeeded(intent, action = "pause", fallbackReason = "notification_paused")
        ensureForeground()
        stateStore.markState(TrackingStateStore.STATE_STOPPING, currentProfile)
        stateStore.emitCurrentStatus()
        stopCapture()
        stateStore.pause()
        stateStore.emitCurrentStatus()
        removeForegroundNotification()
        stopSelf()
    }

    private fun stopTrack(intent: Intent) {
        val reason = intent.getStringExtra(EXTRA_STOP_REASON) ?: "user_stopped"
        recordNotificationActionIfNeeded(intent, action = "stop", fallbackReason = reason)
        ensureForeground()
        stateStore.markState(TrackingStateStore.STATE_STOPPING, currentProfile)
        stateStore.emitCurrentStatus()
        stopCapture()
        stateStore.stop(reason)
        stateStore.emitCurrentStatus()
        removeForegroundNotification()
        stopSelf()
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
        handleActivity(activityType, confidence, timestamp)
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
        if (!captureStarted) startCapture() else requestLocationUpdates(currentProfile)
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
        currentProfile = TrackingStateStore.PROFILE_MOVING
        stillSince = null
        movingEvidence = 0
        latestActivity = null
        lastLocation = null
        lastLocationObservedAt = null
        stationaryReferenceLocation = null
        stationaryDisplacementWindow.reset()

        requestActivityUpdates()
        requestLocationUpdates(currentProfile)
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
        journalPrepareGeneration += 1
        journalPrepareInProgress = false
        captureStarted = false
        isCaptureAliveNow = false
        requestGeneration += 1
        mainHandler.removeCallbacks(stationaryTransition)
        mainHandler.removeCallbacks(heartbeat)
        mainHandler.removeCallbacks(prerequisiteMonitor)
        if (wasCapturing) {
            runCatching { fusedLocationClient.removeLocationUpdates(locationCallback) }
        }
        removeCurrentActivityUpdates(clearGeneration = true)
        currentProfile = TrackingStateStore.PROFILE_IDLE
        stillSince = null
        movingEvidence = 0
        latestActivity = null
        lastLocation = null
        lastLocationObservedAt = null
        stationaryReferenceLocation = null
        stationaryDisplacementWindow.reset()
        stateStore.markServiceHeartbeat(captureActive = false)
        PendingLocationCoordinator.closeAsync(this)
    }

    private fun diagnosticMessage(diagnostic: Map<String, Any?>): String =
        diagnostic["errorMessage"] as? String
            ?: diagnostic["integrityCheck"] as? String
            ?: "journal diagnostic failed"

    private fun requestLocationUpdates(profile: String) {
        if (!captureStarted) return
        val generation = ++requestGeneration
        val interval = if (profile == TrackingStateStore.PROFILE_STATIONARY) {
            configuration.stationaryIntervalMs
        } else {
            configuration.movingIntervalMs
        }
        val distance = if (profile == TrackingStateStore.PROFILE_STATIONARY) {
            configuration.stationaryDistanceFilterMeters
        } else {
            configuration.movingDistanceFilterMeters
        }
        val priority = when (configuration.desiredAccuracy.lowercase()) {
            "best", "high", "navigation", "precise", "precised" ->
                Priority.PRIORITY_HIGH_ACCURACY
            "low", "lowpower", "low_power" -> Priority.PRIORITY_LOW_POWER
            "passive" -> Priority.PRIORITY_PASSIVE
            else -> Priority.PRIORITY_BALANCED_POWER_ACCURACY
        }

        val request = LocationRequest.Builder(priority, interval)
            .setMinUpdateIntervalMillis((interval / 2L).coerceAtLeast(1_000L))
            .setMaxUpdateDelayMillis((interval * 2L).coerceAtLeast(interval))
            .setMinUpdateDistanceMeters(distance)
            .setGranularity(Granularity.GRANULARITY_PERMISSION_LEVEL)
            .setWaitForAccurateLocation(false)
            .build()

        fusedLocationClient.removeLocationUpdates(locationCallback).addOnCompleteListener {
            if (!captureStarted || generation != requestGeneration) return@addOnCompleteListener
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
                "isStationary" to false,
                "isWalking" to false,
                "isRunning" to false,
                "isCycling" to false,
                "isAutomotive" to false,
            )
            latestActivity = event
            TrackingEventBus.emitActivity(event)
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
                )
                latestActivity = event
                TrackingEventBus.emitActivity(event)
                if (currentActivityPendingIntent == registeredPendingIntent) {
                    currentActivityPendingIntent = null
                    runCatching { stateStore.clearActivityRecognitionGeneration() }
                }
            }
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

    private fun handleLocation(location: Location) {
        if (!captureStarted) return
        if (!checkActivePrerequisites()) return
        val trackId = stateStore.activeTrackId ?: return
        val nativeReceivedAt = System.currentTimeMillis()
        val monotonicReceivedNanos = SystemClock.elapsedRealtimeNanos()
        val timestamp = location.time.takeIf { it > 0L } ?: nativeReceivedAt
        val mocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            location.isMock
        } else {
            @Suppress("DEPRECATION")
            location.isFromMockProvider
        }

        val event = linkedMapOf<String, Any?>(
            "eventId" to UUID.randomUUID().toString(),
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
            "motionState" to if (currentProfile == TrackingStateStore.PROFILE_STATIONARY) {
                "stationary"
            } else {
                "moving"
            },
            "trackingProfile" to currentProfile,
            "samplingProfile" to currentProfile,
            "batteryMode" to currentProfile,
            "provider" to location.provider,
        )

        val locationCopy = Location(location)
        val accepted = PendingLocationCoordinator.execute(
            applicationContext,
            onFailure = { error ->
                mainHandler.post {
                    if (captureStarted && stateStore.activeTrackId == trackId) {
                        failCapture(
                            "A location fix could not be journaled safely: ${error.message.orEmpty()}",
                        )
                    }
                }
            },
        ) { store ->
            store.enqueue(event)
            mainHandler.post {
                handleJournaledLocation(trackId, locationCopy, timestamp, event)
            }
        }
        if (!accepted) {
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
        stateStore.emitCurrentStatus()

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
                switchProfile(TrackingStateStore.PROFILE_MOVING)
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

    private fun handleActivity(activityType: Int, confidence: Int, timestamp: Long) {
        val event = LinkedHashMap(ActivityMapper.event(activityType, confidence, timestamp)).apply {
            put("available", true)
        }
        latestActivity = event
        TrackingEventBus.emitActivity(event)

        val type = event["type"] as String
        when {
            type == "stationary" && confidence >= configuration.stationaryConfidenceThreshold -> {
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
                tryEnterStationaryProfile()
            }

            type in MOVING_ACTIVITY_TYPES && confidence >= configuration.movingConfidenceThreshold -> {
                stillSince = null
                stationaryDisplacementWindow.reset()
                mainHandler.removeCallbacks(stationaryTransition)
                movingEvidence += 1
                if (movingEvidence >= configuration.movingConfirmationCount) {
                    movingEvidence = 0
                    switchProfile(TrackingStateStore.PROFILE_MOVING)
                }
            }

            else -> {
                stillSince = null
                stationaryDisplacementWindow.reset()
                movingEvidence = 0
                mainHandler.removeCallbacks(stationaryTransition)
            }
        }
    }

    private fun switchProfile(profile: String) {
        if (!captureStarted || profile == currentProfile) return
        currentProfile = profile
        if (profile == TrackingStateStore.PROFILE_STATIONARY) {
            stationaryReferenceLocation = lastLocation?.let(::Location)
            stationaryDisplacementWindow.reset()
            stateStore.markState(TrackingStateStore.STATE_STATIONARY, profile)
        } else {
            stationaryReferenceLocation = null
            stillSince = null
            stationaryDisplacementWindow.reset()
            mainHandler.removeCallbacks(stationaryTransition)
            stateStore.markState(TrackingStateStore.STATE_TRACKING, profile)
        }
        stateStore.emitCurrentStatus()
        requestLocationUpdates(profile)
        updateNotification(force = true)
    }

    private fun failCapture(message: String) {
        stopCapture()
        stateStore.fail(message)
        stateStore.emitCurrentStatus()
        runCatching { removeForegroundNotification() }
        stopSelf()
    }

    private fun interruptCapture(message: String) {
        stopCapture()
        stateStore.interrupt(message)
        stateStore.emitCurrentStatus()
        runCatching { removeForegroundNotification() }
        stopSelf()
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
            }
        }
        if (clearGeneration && ::stateStore.isInitialized) {
            runCatching { stateStore.clearActivityRecognitionGeneration() }
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

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasActivityRecognitionPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACTIVITY_RECOGNITION) ==
            PackageManager.PERMISSION_GRANTED

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
        val beganAt = stillSince ?: return
        if (!captureStarted || currentProfile != TrackingStateStore.PROFILE_MOVING) return
        if (!hasHighConfidenceStillActivity()) return
        if (System.currentTimeMillis() - beganAt < configuration.stationaryTimeoutMs) return
        if (!stationaryDisplacementWindow.hasLowDisplacement(
                configuration.stationaryTimeoutMs,
                configuration.stationaryProbeDisplacementMeters,
            )
        ) {
            return
        }
        switchProfile(TrackingStateStore.PROFILE_STATIONARY)
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

        private const val NOTIFICATION_ID = 45_001
        private const val REQUEST_OPEN_APP = 45_001
        private const val REQUEST_PAUSE = 45_002
        private const val REQUEST_STOP = 45_003
        private const val REQUEST_ACTIVITY_RECOGNITION = 45_004
        private const val ACTIVITY_RECOGNITION_REQUEST_CODE_SPAN = 10_000L
        private const val NOTIFICATION_UPDATE_INTERVAL_MS = 60_000L
        private const val SERVICE_HEARTBEAT_INTERVAL_MS = 60_000L
        private const val PREREQUISITE_MONITOR_INTERVAL_MS = 60_000L
        private const val MINIMUM_BASELINE_FRESHNESS_MS = 30_000L
        private const val COMMAND_SOURCE_NOTIFICATION = "notification"
        private const val MOVING_EVIDENCE_REQUIRED = 2
        private val MOVING_ACTIVITY_TYPES = setOf("walking", "running", "cycling", "automotive")

        @Volatile
        internal var isServiceAliveNow: Boolean = false
            private set

        @Volatile
        internal var isCaptureAliveNow: Boolean = false
            private set
    }
}
