package com.samir.flutter_background_location

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class FlutterBackgroundLocationPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var applicationContext: Context
    private lateinit var stateStore: TrackingStateStore
    private lateinit var pendingLocationStore: PendingLocationStore
    private lateinit var queueExecutor: ExecutorService
    private var methodChannel: MethodChannel? = null
    private var locationChannel: EventChannel? = null
    private var activityChannel: EventChannel? = null
    private var statusChannel: EventChannel? = null
    private var locationStreamHandler: TrackingStreamHandler? = null
    private var activityStreamHandler: TrackingStreamHandler? = null
    private var statusStreamHandler: TrackingStreamHandler? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionOptions: PermissionRequestOptions? = null
    private var permissionRequestStage = PermissionRequestStage.NONE

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        stateStore = TrackingStateStore(applicationContext)
        pendingLocationStore = PendingLocationStore(applicationContext)
        queueExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "fbl-pending-locations").apply { isDaemon = true }
        }

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }

        locationStreamHandler = TrackingStreamHandler(
            StreamKind.LOCATION,
            { stateStore.statusMap() },
            pendingLocationStore,
            queueExecutor,
        )
        activityStreamHandler = TrackingStreamHandler(
            kind = StreamKind.ACTIVITY,
            currentStatus = { stateStore.statusMap() },
        )
        statusStreamHandler = TrackingStreamHandler(
            kind = StreamKind.STATUS,
            currentStatus = { stateStore.statusMap() },
        )

        locationChannel = EventChannel(binding.binaryMessenger, LOCATION_EVENT_CHANNEL).also {
            it.setStreamHandler(locationStreamHandler)
        }
        activityChannel = EventChannel(binding.binaryMessenger, ACTIVITY_EVENT_CHANNEL).also {
            it.setStreamHandler(activityStreamHandler)
        }
        statusChannel = EventChannel(binding.binaryMessenger, STATUS_EVENT_CHANNEL).also {
            it.setStreamHandler(statusStreamHandler)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        locationChannel?.setStreamHandler(null)
        activityChannel?.setStreamHandler(null)
        statusChannel?.setStreamHandler(null)
        locationStreamHandler?.dispose()
        activityStreamHandler?.dispose()
        statusStreamHandler?.dispose()
        queueExecutor.shutdownNow()
        pendingLocationStore.close()
        methodChannel = null
        locationChannel = null
        activityChannel = null
        statusChannel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(call, result)
            "requestPermissions" -> requestPermissions(call, result)
            "getPermissionStatus" -> result.success(permissionStatus())
            "startTracking" -> startTracking(call, result)
            "pauseTracking" -> pauseTracking(call, result)
            "resumeTracking" -> resumeTracking(call, result)
            "stopTracking" -> stopTracking(call, result)
            "updateConfig" -> updateConfig(call, result)
            "isTracking" -> result.success(stateStore.isActuallyTracking())
            "getState" -> result.success(stateStore.statusMap())
            "getLastLocation" -> result.success(TrackingEventBus.lastLocation)
            "getPendingLocations" -> pendingLocations(result)
            "acknowledgeLocations" -> acknowledgeLocations(call, result)
            "acknowledgePendingUserAction" -> acknowledgePendingUserAction(call, result)
            "getCapabilities" -> result.success(capabilities())
            "getBatteryOptimizationStatus" -> result.success(batteryOptimizationStatus())
            "openBatteryOptimizationSettings" -> openSettings(
                Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
                result,
            )
            "openAppSettings" -> openAppSettings(result)
            "openLocationSettings" -> openSettings(Settings.ACTION_LOCATION_SOURCE_SETTINGS, result)
            "exportToDownloads" -> exportToDownloads(call, result)
            "deleteDownloadExport" -> deleteDownloadExport(call, result)
            else -> result.notImplemented()
        }
    }

    private fun exportToDownloads(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val directoryName = safeExportPart(arguments?.get("directoryName") as? String)
            ?: "flutter_background_location"
        val fileName = safeExportPart(arguments?.get("fileName") as? String)
        val contents = arguments?.get("contents") as? String
        val mimeType = arguments?.get("mimeType") as? String ?: "application/octet-stream"
        if (fileName == null || contents == null) {
            result.error("invalid_export", "Export requires fileName and contents.", null)
            return
        }

        val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$directoryName"
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val displayName = uniqueMediaStoreExportName(relativePath, fileName)
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val resolver = applicationContext.contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                if (uri == null) {
                    result.error("export_failed", "Could not create the export file.", null)
                    return
                }
                try {
                    resolver.openOutputStream(uri, "w")?.use { stream ->
                        stream.write(contents.toByteArray(Charsets.UTF_8))
                    } ?: throw IllegalStateException("Could not open export output stream.")
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    resolver.update(uri, values, null, null)
                    result.success("/storage/emulated/0/$relativePath/$displayName")
                } catch (error: Throwable) {
                    resolver.delete(uri, null, null)
                    throw error
                }
            } else {
                val directory = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    directoryName,
                )
                if (!directory.exists() && !directory.mkdirs()) {
                    result.error("export_failed", "Could not create the export directory.", null)
                    return
                }
                val file = uniqueExportFile(directory, fileName)
                file.writeText(contents, Charsets.UTF_8)
                result.success(file.absolutePath)
            }
        } catch (error: Throwable) {
            result.error("export_failed", error.localizedMessage, null)
        }
    }

    private fun deleteDownloadExport(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val directoryName = safeExportPart(arguments?.get("directoryName") as? String)
            ?: "flutter_background_location"
        val fileName = safeExportPart(arguments?.get("fileName") as? String)
        if (fileName == null) {
            result.error("invalid_export", "Delete requires fileName.", null)
            return
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$directoryName/"
                val deleted = applicationContext.contentResolver.delete(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                    arrayOf(fileName, relativePath),
                )
                result.success(deleted > 0)
            } else {
                val file = File(
                    File(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                        directoryName,
                    ),
                    fileName,
                )
                result.success(!file.exists() || file.delete())
            }
        } catch (error: Throwable) {
            result.error("delete_export_failed", error.localizedMessage, null)
        }
    }

    private fun uniqueMediaStoreExportName(relativePath: String, requestedName: String): String {
        val resolver = applicationContext.contentResolver
        val relativePathWithSlash = "$relativePath/"
        val dot = requestedName.lastIndexOf('.')
        val base = if (dot > 0) requestedName.substring(0, dot) else requestedName
        val extension = if (dot > 0) requestedName.substring(dot) else ""
        var candidate = requestedName
        var counter = 1
        while (mediaStoreExportExists(resolver, relativePathWithSlash, candidate)) {
            candidate = "${base}_${counter}${extension}"
            counter += 1
        }
        return candidate
    }

    private fun mediaStoreExportExists(
        resolver: android.content.ContentResolver,
        relativePath: String,
        displayName: String,
    ): Boolean {
        resolver.query(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
            arrayOf(displayName, relativePath),
            null,
        )?.use { cursor ->
            return cursor.moveToFirst()
        }
        return false
    }

    private fun safeExportPart(value: String?): String? {
        val trimmed = value?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val name = File(trimmed).name
        if (name == "." || name == ".." || name.contains(File.separatorChar)) return null
        return name.replace(Regex("""[\\/:*?"<>|\u0000-\u001F]"""), "_")
    }

    private fun uniqueExportFile(directory: File, requestedName: String): File {
        var destination = File(directory, requestedName)
        val dot = requestedName.lastIndexOf('.')
        val base = if (dot > 0) requestedName.substring(0, dot) else requestedName
        val extension = if (dot > 0) requestedName.substring(dot) else ""
        var counter = 1
        while (destination.exists()) {
            destination = File(directory, "${base}_${counter}${extension}")
            counter += 1
        }
        return destination
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val configuration = TrackingConfiguration.fromMap(arguments?.get("config") as? Map<*, *>)
        createNotificationChannel(configuration)
        stateStore.emitCurrentStatus()
        result.success(stateStore.statusMap())
    }

    private fun startTracking(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val trackId = arguments?.get("trackId") as? String
        if (trackId.isNullOrBlank()) {
            result.error("invalid_track_id", "startTracking requires a non-empty trackId.", null)
            return
        }
        if (!hasForegroundLocationPermission()) {
            result.error(
                "location_permission_denied",
                "Foreground location permission is required before tracking starts.",
                permissionStatus(),
            )
            return
        }
        if (!notificationsGranted()) {
            result.error(
                "notification_permission_denied",
                "Notification permission is required for visible background tracking.",
                permissionStatus(),
            )
            return
        }
        if (!TrackingStateStore.isLocationServiceEnabled(applicationContext)) {
            result.error("location_services_disabled", "Location services are disabled.", null)
            return
        }

        val existingTrackId = stateStore.activeTrackId
        if (existingTrackId != null && existingTrackId != trackId && stateStore.state != TrackingStateStore.STATE_IDLE) {
            if (!stateStore.isActuallyTracking()) {
                stateStore.stop("stale_native_session_replaced")
            } else {
                result.error(
                    "tracking_already_active",
                    "Track $existingTrackId must be stopped before a different track starts.",
                    stateStore.statusMap(),
                )
                return
            }
        }

        val configuration = TrackingConfiguration.fromMap(arguments["config"] as? Map<*, *>)
        createNotificationChannel(configuration)
        stateStore.begin(trackId, configuration)
        stateStore.emitCurrentStatus()
        val intent = Intent(applicationContext, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_START
            putExtra(LocationTrackingService.EXTRA_TRACK_ID, trackId)
            putExtra(LocationTrackingService.EXTRA_CONFIGURATION, configuration.toJson())
        }
        if (!startForegroundService(intent, result)) return
        result.success(stateStore.statusMap())
    }

    private fun pauseTracking(call: MethodCall, result: MethodChannel.Result) {
        if (stateStore.isPaused) {
            result.success(stateStore.statusMap())
            return
        }
        val activeTrackId = stateStore.activeTrackId
        if (activeTrackId == null) {
            result.error("no_active_track", "There is no active track to pause.", null)
            return
        }
        val requestedTrackId = (call.arguments as? Map<*, *>)?.get("trackId") as? String
        if (requestedTrackId != null && requestedTrackId != activeTrackId) {
            result.error("track_mismatch", "The requested track is not active.", stateStore.statusMap())
            return
        }

        stateStore.markState(TrackingStateStore.STATE_STOPPING, stateStore.profile)
        stateStore.emitCurrentStatus()
        val intent = Intent(applicationContext, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_PAUSE
        }
        if (!startForegroundService(intent, result)) return
        result.success(stateStore.statusMap())
    }

    private fun resumeTracking(call: MethodCall, result: MethodChannel.Result) {
        if (!hasForegroundLocationPermission()) {
            result.error(
                "location_permission_denied",
                "Foreground location permission is required before tracking resumes.",
                permissionStatus(),
            )
            return
        }
        if (!notificationsGranted()) {
            result.error(
                "notification_permission_denied",
                "Notification permission is required for visible background tracking.",
                permissionStatus(),
            )
            return
        }
        if (!TrackingStateStore.isLocationServiceEnabled(applicationContext)) {
            result.error("location_services_disabled", "Location services are disabled.", null)
            return
        }

        val arguments = call.arguments as? Map<*, *>
        val requestedTrackId = arguments?.get("trackId") as? String
        val persistedTrackId = stateStore.activeTrackId
        val trackId = requestedTrackId?.takeIf { it.isNotBlank() } ?: persistedTrackId
        if (trackId == null) {
            result.error("no_paused_track", "There is no paused track to resume.", null)
            return
        }
        if (persistedTrackId != null && requestedTrackId != null && persistedTrackId != requestedTrackId) {
            result.error(
                "track_mismatch",
                "The requested track does not match the paused track.",
                stateStore.statusMap(),
            )
            return
        }

        val configurationMap = arguments?.get("config") as? Map<*, *>
        val configuration = if (configurationMap == null) {
            stateStore.configuration
        } else {
            TrackingConfiguration.fromMap(configurationMap)
        }
        createNotificationChannel(configuration)
        if (persistedTrackId == null) {
            stateStore.begin(trackId, configuration)
        } else {
            stateStore.resume()
        }
        stateStore.emitCurrentStatus()

        val intent = Intent(applicationContext, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_RESUME
            putExtra(LocationTrackingService.EXTRA_TRACK_ID, trackId)
            putExtra(LocationTrackingService.EXTRA_CONFIGURATION, configuration.toJson())
        }
        if (!startForegroundService(intent, result)) return
        result.success(stateStore.statusMap())
    }

    private fun stopTracking(call: MethodCall, result: MethodChannel.Result) {
        if (stateStore.activeTrackId == null) {
            stateStore.stop((call.arguments as? Map<*, *>)?.get("reason") as? String)
            stateStore.emitCurrentStatus()
            result.success(stateStore.statusMap())
            return
        }

        val arguments = call.arguments as? Map<*, *>
        val requestedTrackId = arguments?.get("trackId") as? String
        if (requestedTrackId != null && requestedTrackId != stateStore.activeTrackId) {
            result.error("track_mismatch", "The requested track is not active.", stateStore.statusMap())
            return
        }
        val reason = arguments?.get("reason") as? String
            ?: "user_stopped"
        stateStore.markState(TrackingStateStore.STATE_STOPPING, stateStore.profile)
        stateStore.emitCurrentStatus()
        val intent = Intent(applicationContext, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_STOP
            putExtra(LocationTrackingService.EXTRA_STOP_REASON, reason)
        }
        if (!startForegroundService(intent, result)) return
        result.success(stateStore.statusMap())
    }

    private fun updateConfig(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val trackId = arguments?.get("trackId") as? String
        if (trackId.isNullOrBlank() || trackId != stateStore.activeTrackId) {
            result.error("track_mismatch", "The requested track is not active or paused.", stateStore.statusMap())
            return
        }
        val configuration = TrackingConfiguration.fromMap(arguments["config"] as? Map<*, *>)
        stateStore.updateConfiguration(configuration)
        createNotificationChannel(configuration)

        if (stateStore.trackingEnabled && !stateStore.isPaused) {
            val intent = Intent(applicationContext, LocationTrackingService::class.java).apply {
                action = LocationTrackingService.ACTION_UPDATE_CONFIG
                putExtra(LocationTrackingService.EXTRA_TRACK_ID, trackId)
                putExtra(LocationTrackingService.EXTRA_CONFIGURATION, configuration.toJson())
            }
            if (!startForegroundService(intent, result)) return
        }
        stateStore.emitCurrentStatus()
        result.success(stateStore.statusMap())
    }

    private fun startForegroundService(intent: Intent, result: MethodChannel.Result): Boolean {
        return try {
            ContextCompat.startForegroundService(applicationContext, intent)
            true
        } catch (error: Exception) {
            val message = error.message ?: "Android rejected the foreground-service start."
            stateStore.fail(message)
            stateStore.emitCurrentStatus()
            result.error("foreground_service_start_failed", message, permissionStatus())
            false
        }
    }

    private fun pendingLocations(result: MethodChannel.Result) {
        queueExecutor.execute {
            try {
                result.success(pendingLocationStore.pending())
            } catch (error: Exception) {
                result.error(
                    "pending_locations_unavailable",
                    error.message ?: "The native pending-location queue could not be read.",
                    null,
                )
            }
        }
    }

    private fun acknowledgeLocations(call: MethodCall, result: MethodChannel.Result) {
        val values = (call.arguments as? Map<*, *>)?.get("eventIds") as? List<*>
        val eventIds = values?.filterIsInstance<String>().orEmpty()
        queueExecutor.execute {
            try {
                val acknowledged = pendingLocationStore.acknowledge(eventIds)
                result.success(
                    mapOf(
                        "acknowledged" to acknowledged,
                        "pendingCount" to pendingLocationStore.count(),
                    ),
                )
            } catch (error: Exception) {
                result.error(
                    "pending_location_ack_failed",
                    error.message ?: "Pending locations could not be acknowledged.",
                    null,
                )
            }
        }
    }

    private fun acknowledgePendingUserAction(call: MethodCall, result: MethodChannel.Result) {
        val actionId = (call.arguments as? Map<*, *>)?.get("actionId") as? String
        if (actionId.isNullOrBlank()) {
            result.error(
                "invalid_action_id",
                "acknowledgePendingUserAction requires a non-empty actionId.",
                stateStore.statusMap(),
            )
            return
        }

        val acknowledged = stateStore.acknowledgePendingUserAction(actionId)
        stateStore.emitCurrentStatus()
        result.success(
            linkedMapOf(
                "acknowledged" to acknowledged,
                "pendingUserAction" to stateStore.pendingUserAction(),
            ),
        )
    }

    private fun requestPermissions(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPermissionResult != null) {
            result.error("permission_request_in_progress", "Another permission request is active.", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error(
                "activity_unavailable",
                "Permissions must be requested while a Flutter activity is visible.",
                permissionStatus(),
            )
            return
        }

        val arguments = call.arguments as? Map<*, *>
        val options = PermissionRequestOptions(
            location = arguments.boolean("location", true),
            backgroundLocation = arguments.boolean("backgroundLocation", true),
            activityRecognition = arguments.boolean("activityRecognition", true),
            notifications = arguments.boolean("notifications", true),
        )
        pendingPermissionResult = result
        pendingPermissionOptions = options

        val permissions = mutableListOf<String>()
        if (options.location && !hasForegroundLocationPermission()) {
            permissions += Manifest.permission.ACCESS_COARSE_LOCATION
            permissions += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (
            options.activityRecognition &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            !activityRecognitionGranted()
        ) {
            permissions += Manifest.permission.ACTIVITY_RECOGNITION
        }
        if (
            options.notifications &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !notificationsGranted()
        ) {
            permissions += Manifest.permission.POST_NOTIFICATIONS
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && permissions.isNotEmpty()) {
            permissionRequestStage = PermissionRequestStage.INITIAL
            ActivityCompat.requestPermissions(activity, permissions.distinct().toTypedArray(), PERMISSION_REQUEST_CODE)
        } else {
            continuePermissionRequest()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE || pendingPermissionResult == null) return false
        if (permissionRequestStage == PermissionRequestStage.INITIAL) {
            continuePermissionRequest()
        } else {
            finishPermissionRequest()
        }
        return true
    }

    private fun continuePermissionRequest() {
        val activity = activityBinding?.activity
        val options = pendingPermissionOptions
        if (
            activity != null &&
            options?.backgroundLocation == true &&
            Build.VERSION.SDK_INT == Build.VERSION_CODES.Q &&
            hasForegroundLocationPermission() &&
            !backgroundLocationGranted()
        ) {
            permissionRequestStage = PermissionRequestStage.BACKGROUND
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION),
                PERMISSION_REQUEST_CODE,
            )
            return
        }
        finishPermissionRequest()
    }

    private fun finishPermissionRequest() {
        val result = pendingPermissionResult
        pendingPermissionResult = null
        pendingPermissionOptions = null
        permissionRequestStage = PermissionRequestStage.NONE
        result?.success(permissionStatus())
    }

    private fun permissionStatus(): Map<String, Any?> {
        val foregroundGranted = hasForegroundLocationPermission()
        val backgroundGranted = backgroundLocationGranted()
        val precise = ContextCompat.checkSelfPermission(
            applicationContext,
            Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        val locationStatus = when {
            backgroundGranted -> "always"
            foregroundGranted -> "whileInUse"
            else -> "denied"
        }

        return linkedMapOf(
            "platform" to "android",
            "location" to locationStatus,
            "foregroundLocation" to foregroundGranted,
            "backgroundLocation" to backgroundGranted,
            "preciseLocation" to precise,
            "locationServicesEnabled" to TrackingStateStore.isLocationServiceEnabled(applicationContext),
            "locationServiceEnabled" to TrackingStateStore.isLocationServiceEnabled(applicationContext),
            "activityRecognition" to activityRecognitionGranted(),
            "activityRecognitionGranted" to activityRecognitionGranted(),
            "notifications" to notificationsGranted(),
            "notificationGranted" to notificationsGranted(),
            "canRequestBackground" to (
                Build.VERSION.SDK_INT == Build.VERSION_CODES.Q &&
                    foregroundGranted &&
                    !backgroundGranted
                ),
            "backgroundSettingsRequired" to (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    foregroundGranted &&
                    !backgroundGranted
                ),
            "requiresSettings" to (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    foregroundGranted &&
                    !backgroundGranted
                ),
            "mockDetectionAvailable" to TrackingStateStore.MOCK_DETECTION_AVAILABLE,
        )
    }

    private fun capabilities(): Map<String, Any?> = linkedMapOf(
        "platform" to "android",
        "backgroundTracking" to true,
        "activityRecognition" to true,
        "mockDetectionAvailable" to TrackingStateStore.MOCK_DETECTION_AVAILABLE,
        "mockDetection" to TrackingStateStore.MOCK_DETECTION_AVAILABLE,
        "mockDetectionSignal" to "platformSignal",
        "pauseResume" to true,
        "adaptiveSampling" to true,
        "terminatedRecovery" to true,
        "rebootRestartBestEffort" to true,
        "durablePendingLocations" to true,
        "durablePendingUserActions" to true,
        "minApi" to 21,
    )

    private fun batteryOptimizationStatus(): Map<String, Any?> = linkedMapOf(
        "supported" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M),
        "isIgnoringBatteryOptimizations" to
            TrackingStateStore.isBatteryOptimizationIgnored(applicationContext),
        "packageName" to applicationContext.packageName,
    )

    private fun openAppSettings(result: MethodChannel.Result) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${applicationContext.packageName}"),
        )
        launchSettingsIntent(intent, result)
    }

    private fun openSettings(action: String, result: MethodChannel.Result) {
        launchSettingsIntent(Intent(action), result)
    }

    private fun launchSettingsIntent(intent: Intent, result: MethodChannel.Result) {
        try {
            val activity = activityBinding?.activity
            if (activity != null) {
                activity.startActivity(intent)
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                applicationContext.startActivity(intent)
            }
            result.success(true)
        } catch (error: Exception) {
            result.error("settings_unavailable", error.message, null)
        }
    }

    private fun createNotificationChannel(configuration: TrackingConfiguration) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                configuration.notificationChannelId,
                configuration.notificationChannelName,
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = configuration.notificationChannelDescription
                setShowBadge(false)
            },
        )
    }

    private fun hasForegroundLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun backgroundLocationGranted(): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            hasForegroundLocationPermission()
        } else {
            ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
        }

    private fun activityRecognitionGranted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.ACTIVITY_RECOGNITION,
            ) == PackageManager.PERMISSION_GRANTED

    private fun notificationsGranted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED

    private fun attachActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        if (pendingPermissionResult != null) {
            pendingPermissionResult?.error(
                "activity_detached",
                "The activity detached before the permission request completed.",
                permissionStatus(),
            )
            pendingPermissionResult = null
            pendingPermissionOptions = null
            permissionRequestStage = PermissionRequestStage.NONE
        }
    }

    private data class PermissionRequestOptions(
        val location: Boolean,
        val backgroundLocation: Boolean,
        val activityRecognition: Boolean,
        val notifications: Boolean,
    )

    private enum class PermissionRequestStage { NONE, INITIAL, BACKGROUND }

    companion object {
        const val METHOD_CHANNEL = "flutter_background_location/methods"
        const val LOCATION_EVENT_CHANNEL = "flutter_background_location/location"
        const val ACTIVITY_EVENT_CHANNEL = "flutter_background_location/activity"
        const val STATUS_EVENT_CHANNEL = "flutter_background_location/status"
        private const val PERMISSION_REQUEST_CODE = 45_101

        private fun Map<*, *>?.boolean(key: String, fallback: Boolean): Boolean =
            this?.get(key) as? Boolean ?: fallback
    }
}

private enum class StreamKind { LOCATION, ACTIVITY, STATUS }

private class TrackingStreamHandler(
    private val kind: StreamKind,
    private val currentStatus: () -> Map<String, Any?>,
    private val pendingLocationStore: PendingLocationStore? = null,
    private val queueExecutor: ExecutorService? = null,
) : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var replayGeneration = 0
    private var replayInProgress = false
    private val bufferedLocations = ArrayList<Map<String, Any?>>()
    private val listener: (Map<String, Any?>) -> Unit = { event ->
        if (kind == StreamKind.LOCATION && replayInProgress) {
            bufferedLocations += event
        } else {
            eventSink?.success(event)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        dispose()
        eventSink = events
        when (kind) {
            StreamKind.LOCATION -> {
                val store = pendingLocationStore
                val executor = queueExecutor
                if (store == null || executor == null) {
                    TrackingEventBus.addLocationListener(listener)
                } else {
                    replayInProgress = true
                    bufferedLocations.clear()
                    val generation = ++replayGeneration
                    TrackingEventBus.addLocationListener(listener)
                    executor.execute {
                        try {
                            val pending = store.pending()
                            mainHandler.post {
                                if (generation != replayGeneration || eventSink !== events) return@post
                                val live = bufferedLocations.toList()
                                bufferedLocations.clear()
                                replayInProgress = false
                                val emittedIds = HashSet<String>()
                                (pending + live).forEach { event ->
                                    val eventId = event["eventId"] as? String
                                    if (eventId == null || emittedIds.add(eventId)) events.success(event)
                                }
                            }
                        } catch (error: Exception) {
                            mainHandler.post {
                                if (generation != replayGeneration || eventSink !== events) return@post
                                val live = bufferedLocations.toList()
                                bufferedLocations.clear()
                                replayInProgress = false
                                events.error(
                                    "pending_location_replay_failed",
                                    error.message ?: "Pending locations could not be replayed.",
                                    null,
                                )
                                live.forEach(events::success)
                            }
                        }
                    }
                }
            }
            StreamKind.ACTIVITY -> TrackingEventBus.addActivityListener(listener)
            StreamKind.STATUS -> {
                TrackingEventBus.addStatusListener(listener)
                events.success(currentStatus())
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        dispose()
    }

    fun dispose() {
        replayGeneration += 1
        replayInProgress = false
        bufferedLocations.clear()
        when (kind) {
            StreamKind.LOCATION -> TrackingEventBus.removeLocationListener(listener)
            StreamKind.ACTIVITY -> TrackingEventBus.removeActivityListener(listener)
            StreamKind.STATUS -> TrackingEventBus.removeStatusListener(listener)
        }
        eventSink = null
    }
}
