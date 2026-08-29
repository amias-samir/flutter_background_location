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
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class FlutterBackgroundLocationPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var applicationContext: Context
    private lateinit var stateStore: TrackingStateStore
    private val mainHandler = Handler(Looper.getMainLooper())
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
    private val exportExecutor = Executors.newSingleThreadExecutor()
    private val activeExports = ConcurrentHashMap<String, ActiveExport>()
    private val engineInstanceId = UUID.randomUUID().toString()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        stateStore = TrackingStateStore(applicationContext)

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }

        locationStreamHandler = TrackingStreamHandler(
            StreamKind.LOCATION,
            { stateStore.statusMap() },
            applicationContext,
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
        NativeCommandCoordinator.release(engineInstanceId, null)
        methodChannel?.setMethodCallHandler(null)
        locationChannel?.setStreamHandler(null)
        activityChannel?.setStreamHandler(null)
        statusChannel?.setStreamHandler(null)
        locationStreamHandler?.dispose()
        activityStreamHandler?.dispose()
        statusStreamHandler?.dispose()
        methodChannel = null
        locationChannel = null
        activityChannel = null
        statusChannel = null
        exportExecutor.execute {
            activeExports.values.forEach { abortActiveExport(it, deleteCommitted = true) }
            activeExports.clear()
        }
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
            "acquireCommandLease" -> acquireCommandLease(call, result)
            "releaseCommandLease" -> releaseCommandLease(call, result)
            "startTrackingV2" -> executeLeasedCommand(call, result) { leasedResult ->
                startTracking(call, leasedResult)
            }
            "pauseTrackingV2" -> executeLeasedCommand(call, result) { leasedResult ->
                pauseTracking(call, leasedResult)
            }
            "resumeTrackingV2" -> executeLeasedCommand(call, result) { leasedResult ->
                resumeTracking(call, leasedResult)
            }
            "stopTrackingV2" -> executeLeasedCommand(call, result) { leasedResult ->
                stopTracking(call, leasedResult)
            }
            "updateConfigV2" -> executeLeasedCommand(call, result) { leasedResult ->
                updateConfig(call, leasedResult)
            }
            "startTracking" -> executeLegacyCommand(result) { startTracking(call, result) }
            "pauseTracking" -> executeLegacyCommand(result) { pauseTracking(call, result) }
            "resumeTracking" -> executeLegacyCommand(result) { resumeTracking(call, result) }
            "stopTracking" -> executeLegacyCommand(result) { stopTracking(call, result) }
            "updateConfig" -> executeLegacyCommand(result) { updateConfig(call, result) }
            "isTracking" -> result.success(stateStore.isActuallyTracking())
            "getState" -> result.success(stateStore.statusMap())
            "getLastLocation" -> result.success(TrackingEventBus.lastLocation)
            "getPendingLocations" -> pendingLocations(result)
            "getPendingLocationsPage" -> pendingLocationsPage(call, result)
            "getNativeJournalDiagnostic" -> nativeJournalDiagnostic(call, result)
            "acknowledgeLocations" -> acknowledgeLocations(call, result)
            "clearNativeTrackData" -> clearNativeTrackData(call, result)
            "acknowledgePendingUserAction" -> acknowledgePendingUserAction(call, result)
            "getProtocolInfo" -> result.success(protocolInfo())
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
            "beginExportToDownloadsV2" -> beginExportToDownloadsV2(call, result)
            "appendExportToDownloadsV2" -> appendExportToDownloadsV2(call, result)
            "commitExportToDownloadsV2" -> commitExportToDownloadsV2(call, result)
            "abortExportToDownloadsV2" -> abortExportToDownloadsV2(call, result)
            "copyExportToCacheV2" -> copyExportToCacheV2(call, result)
            "deleteExportDestinationV2" -> deleteExportDestinationV2(call, result)
            else -> result.notImplemented()
        }
    }

    private fun acquireCommandLease(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val trackId = arguments?.get("trackId") as? String
        val sessionControlToken = arguments?.get("sessionControlToken") as? String
        if (trackId.isNullOrBlank() || sessionControlToken.isNullOrBlank()) {
            result.error(
                "native_command_lease_invalid",
                "A track ID and session-control token are required.",
                null,
            )
            return
        }
        try {
            val lease = NativeCommandCoordinator.acquire(
                stateStore,
                engineInstanceId,
                trackId,
                sessionControlToken,
            )
            result.success(
                mapOf(
                    "engineLeaseToken" to lease.engineLeaseToken,
                    "commandRevision" to stateStore.commandRevision,
                ),
            )
        } catch (error: NativeCommandCoordinator.Rejection) {
            result.error(error.code, error.message, redactedCommandState())
        } catch (error: Exception) {
            result.error(
                "native_state_persistence_failed",
                error.message ?: "Could not persist the native command lease.",
                redactedCommandState(),
            )
        }
    }

    private fun releaseCommandLease(call: MethodCall, result: MethodChannel.Result) {
        val token = (call.arguments as? Map<*, *>)?.get("engineLeaseToken") as? String
        NativeCommandCoordinator.release(engineInstanceId, token)
        result.success(true)
    }

    private fun executeLegacyCommand(
        result: MethodChannel.Result,
        operation: () -> Unit,
    ) {
        if (NativeCommandCoordinator.hasLease()) {
            result.error(
                "native_command_lease_conflict",
                "A negotiated command lease owns native lifecycle changes.",
                redactedCommandState(),
            )
            return
        }
        operation()
    }

    private fun executeLeasedCommand(
        call: MethodCall,
        result: MethodChannel.Result,
        operation: (MethodChannel.Result) -> Unit,
    ) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        val permit = try {
            NativeCommandCoordinator.begin(stateStore, engineInstanceId, arguments)
        } catch (error: NativeCommandCoordinator.Rejection) {
            result.error(error.code, error.message, redactedCommandState())
            return
        }
        if (permit.replayed) {
            result.success(stateStore.statusMap() + ("commandRevision" to permit.revision))
            return
        }
        operation(object : MethodChannel.Result {
            override fun success(value: Any?) {
                try {
                    val revision = NativeCommandCoordinator.complete(stateStore, permit)
                    val response = when (value) {
                        is Map<*, *> -> value.entries.associate { it.key.toString() to it.value } +
                            ("commandRevision" to revision)
                        else -> mapOf("value" to value, "commandRevision" to revision)
                    }
                    result.success(response)
                } catch (error: NativeCommandCoordinator.Rejection) {
                    result.error(error.code, error.message, redactedCommandState())
                } catch (error: Exception) {
                    result.error(
                        "native_state_persistence_failed",
                        error.message ?: "Could not persist the native command result.",
                        redactedCommandState(),
                    )
                }
            }

            override fun error(code: String, message: String?, details: Any?) {
                NativeCommandCoordinator.fail(permit)
                result.error(code, message, details)
            }

            override fun notImplemented() {
                NativeCommandCoordinator.fail(permit)
                result.notImplemented()
            }
        })
    }

    private fun redactedCommandState(): Map<String, Any?> = mapOf(
        "state" to stateStore.state,
        "isTracking" to stateStore.isActuallyTracking(),
        "isPaused" to stateStore.isPaused,
        "commandRevision" to stateStore.commandRevision,
    )

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
                if (!hasLegacyPublicExportPermission()) {
                    result.error(
                        "export_storage_permission_required",
                        "Writing exports to public Downloads on Android 9 and lower requires WRITE_EXTERNAL_STORAGE. Request it from the user's Export action or provide a custom ExportFileWriter.",
                        mapOf("apiLevel" to Build.VERSION.SDK_INT),
                    )
                    return
                }
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

    private fun beginExportToDownloadsV2(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val directoryName = safeExportPart(arguments?.get("directoryName") as? String)
            ?: "flutter_background_location"
        val fileName = safeExportPart(arguments?.get("fileName") as? String)
        val mimeType = (arguments?.get("mimeType") as? String)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: "application/octet-stream"
        if (fileName == null) {
            result.error("invalid_export", "Export requires a safe fileName.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q && !hasLegacyPublicExportPermission()) {
            result.error(
                "export_storage_permission_required",
                "Public Downloads export requires WRITE_EXTERNAL_STORAGE on Android 9 and lower.",
                mapOf("apiLevel" to Build.VERSION.SDK_INT),
            )
            return
        }

        exportExecutor.execute {
            try {
                val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/$directoryName"
                val handleId = UUID.randomUUID().toString()
                val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val displayName = uniqueMediaStoreExportName(relativePath, fileName)
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
                        put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                        put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                        put(MediaStore.MediaColumns.IS_PENDING, 1)
                    }
                    val resolver = applicationContext.contentResolver
                    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                        ?: throw IllegalStateException("Could not create the export destination.")
                    try {
                        val output = resolver.openOutputStream(uri, "w")
                            ?: throw IllegalStateException("Could not open the export destination.")
                        ActiveExport(
                            handleId = handleId,
                            output = output,
                            contentUri = uri,
                            temporaryFile = null,
                            destinationFile = null,
                            displayName = displayName,
                            mimeType = mimeType,
                            displayPath = "$relativePath/$displayName",
                            userVisible = true,
                        )
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
                        throw IllegalStateException("Could not create the export directory.")
                    }
                    val destination = uniqueExportFile(directory, fileName)
                    val temporary = File(
                        directory,
                        ".${destination.name}.${UUID.randomUUID()}.tmp",
                    )
                    ActiveExport(
                        handleId = handleId,
                        output = FileOutputStream(temporary),
                        contentUri = null,
                        temporaryFile = temporary,
                        destinationFile = destination,
                        displayName = destination.name,
                        mimeType = mimeType,
                        displayPath = destination.absolutePath,
                        userVisible = true,
                    )
                }
                activeExports[handleId] = active
                exportSuccess(result, mapOf("handleId" to handleId))
            } catch (error: Throwable) {
                exportFailure(result, "export_failed", error)
            }
        }
    }

    private fun appendExportToDownloadsV2(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val handleId = arguments?.get("handleId") as? String
        val bytes = arguments?.get("bytes") as? ByteArray
        if (handleId.isNullOrBlank() || bytes == null || bytes.size > MAX_EXPORT_CHUNK_BYTES) {
            result.error(
                "invalid_export_chunk",
                "Export append requires a handle and at most 1 MiB of bytes.",
                null,
            )
            return
        }
        exportExecutor.execute {
            val active = activeExports[handleId]
            if (active == null || active.committed) {
                exportError(result, "export_handle_not_found", "The export handle is not active.")
                return@execute
            }
            try {
                active.output?.write(bytes)
                    ?: throw IllegalStateException("The export output is closed.")
                exportSuccess(result, true)
            } catch (error: Throwable) {
                activeExports.remove(handleId)
                abortActiveExport(active, deleteCommitted = true)
                exportFailure(result, "export_failed", error)
            }
        }
    }

    private fun commitExportToDownloadsV2(call: MethodCall, result: MethodChannel.Result) {
        val handleId = (call.arguments as? Map<*, *>)?.get("handleId") as? String
        if (handleId.isNullOrBlank()) {
            result.error("invalid_export", "Export commit requires a handle.", null)
            return
        }
        exportExecutor.execute {
            val active = activeExports.remove(handleId)
            if (active == null || active.committed) {
                exportError(result, "export_handle_not_found", "The export handle is not active.")
                return@execute
            }
            try {
                active.output?.flush()
                active.output?.close()
                active.output = null
                val contentUri = active.contentUri
                val destinationFile = active.destinationFile
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && contentUri != null) {
                    val values = ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }
                    val updated = applicationContext.contentResolver.update(
                        contentUri,
                        values,
                        null,
                        null,
                    )
                    if (updated < 1) throw IllegalStateException("Could not publish the export.")
                } else if (destinationFile != null) {
                    val temporary = active.temporaryFile
                        ?: throw IllegalStateException("The temporary export is missing.")
                    if (!temporary.renameTo(destinationFile)) {
                        throw IllegalStateException("Could not atomically publish the export.")
                    }
                }
                active.committed = true
                exportSuccess(result, active.destinationMap())
            } catch (error: Throwable) {
                abortActiveExport(active, deleteCommitted = true)
                exportFailure(result, "export_failed", error)
            }
        }
    }

    private fun abortExportToDownloadsV2(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val handleId = arguments?.get("handleId") as? String
        if (handleId.isNullOrBlank()) {
            result.error("invalid_export", "Export abort requires a handle.", null)
            return
        }
        val deleteCommitted = arguments?.get("deleteCommitted") as? Boolean ?: false
        val suppliedUri = (arguments?.get("contentUri") as? String)?.let(Uri::parse)
        val suppliedPath = arguments?.get("localFilePath") as? String
        exportExecutor.execute {
            try {
                val active = activeExports.remove(handleId)
                if (active != null) {
                    abortActiveExport(active, deleteCommitted)
                } else if (deleteCommitted) {
                    if (suppliedUri != null && isManagedDownloadUri(suppliedUri)) {
                        applicationContext.contentResolver.delete(suppliedUri, null, null)
                    } else if (suppliedPath != null) {
                        deleteSafePublicExportPath(suppliedPath)
                    }
                }
                exportSuccess(result, true)
            } catch (error: Throwable) {
                exportFailure(result, "delete_export_failed", error)
            }
        }
    }

    private fun copyExportToCacheV2(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val rawUri = arguments?.get("contentUri") as? String
        val destinationPath = arguments?.get("destinationPath") as? String
        if (rawUri.isNullOrBlank() || destinationPath.isNullOrBlank()) {
            result.error("invalid_export", "Share copy requires a URI and destination.", null)
            return
        }
        exportExecutor.execute {
            var destination: File? = null
            try {
                val uri = Uri.parse(rawUri)
                if (uri.scheme != "content") throw IllegalArgumentException("A content URI is required.")
                destination = File(destinationPath).canonicalFile
                val cacheRoot = applicationContext.cacheDir.canonicalFile
                if (!destination.path.startsWith(cacheRoot.path + File.separator)) {
                    throw SecurityException("Share copy destination is outside app cache.")
                }
                destination.parentFile?.mkdirs()
                applicationContext.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(destination).use { output ->
                        val buffer = ByteArray(MAX_EXPORT_CHUNK_BYTES)
                        while (true) {
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                        }
                        output.flush()
                    }
                } ?: throw IllegalStateException("The export URI is not readable.")
                exportSuccess(result, true)
            } catch (error: Throwable) {
                destination?.delete()
                exportFailure(result, "share_copy_failed", error)
            }
        }
    }

    private fun deleteExportDestinationV2(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *>
        val contentUri = (arguments?.get("contentUri") as? String)?.let(Uri::parse)
        val localFilePath = arguments?.get("localFilePath") as? String
        if ((contentUri == null) == (localFilePath == null)) {
            result.error(
                "invalid_export",
                "Delete requires exactly one managed export access handle.",
                null,
            )
            return
        }
        exportExecutor.execute {
            try {
                val removed = if (contentUri != null) {
                    if (!isManagedDownloadUri(contentUri)) {
                        throw SecurityException("Export URI is outside MediaStore Downloads.")
                    }
                    applicationContext.contentResolver.delete(contentUri, null, null) > 0
                } else {
                    val candidate = File(localFilePath!!).canonicalFile
                    val existed = candidate.exists()
                    deleteSafePublicExportPath(candidate.path)
                    existed
                }
                exportSuccess(result, removed)
            } catch (error: Throwable) {
                exportFailure(result, "delete_export_failed", error)
            }
        }
    }

    private fun abortActiveExport(active: ActiveExport, deleteCommitted: Boolean) {
        try {
            active.output?.close()
        } catch (_: Throwable) {
            // Continue cleanup.
        }
        active.output = null
        active.temporaryFile?.delete()
        if (!active.committed || deleteCommitted) {
            active.contentUri?.let {
                applicationContext.contentResolver.delete(it, null, null)
            }
            if (deleteCommitted) active.destinationFile?.delete()
        }
    }

    private fun deleteSafePublicExportPath(rawPath: String) {
        val candidate = File(rawPath).canonicalFile
        val downloads = Environment
            .getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            .canonicalFile
        if (!candidate.path.startsWith(downloads.path + File.separator)) {
            throw SecurityException("Export path is outside public Downloads.")
        }
        candidate.delete()
    }

    private fun isManagedDownloadUri(uri: Uri): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val root = MediaStore.Downloads.EXTERNAL_CONTENT_URI.toString().trimEnd('/')
        return uri.scheme == "content" && uri.toString().startsWith("$root/")
    }

    private fun exportSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post { result.success(value) }
    }

    private fun exportError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun exportFailure(
        result: MethodChannel.Result,
        code: String,
        error: Throwable,
    ) {
        mainHandler.post { result.error(code, error.localizedMessage ?: messageFor(error), null) }
    }

    private fun messageFor(error: Throwable): String =
        error::class.java.simpleName.takeIf { it.isNotBlank() } ?: "Export failed."

    private fun clearNativeTrackData(call: MethodCall, result: MethodChannel.Result) {
        val trackId = (call.arguments as? Map<*, *>)?.get("trackId") as? String
        if (trackId.isNullOrBlank()) {
            result.error("invalid_track_id", "Native cleanup requires a trackId.", null)
            return
        }
        val accepted = PendingLocationCoordinator.executeForResult(
            context = applicationContext,
            onSuccess = { deleted -> mainHandler.post { result.success(deleted) } },
            onFailure = { error ->
                mainHandler.post {
                    result.error("native_clear_failed", error.localizedMessage, null)
                }
            },
        ) { store ->
            store.deleteTrack(trackId)
        }
        if (!accepted) {
            result.error(
                "pending_location_backpressure",
                "The native pending-location worker is overloaded.",
                null,
            )
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
                if (!hasLegacyPublicExportPermission()) {
                    result.error(
                        "export_storage_permission_required",
                        "Deleting exports from public Downloads on Android 9 and lower requires WRITE_EXTERNAL_STORAGE.",
                        mapOf("apiLevel" to Build.VERSION.SDK_INT),
                    )
                    return
                }
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

    private fun hasLegacyPublicExportPermission(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED

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

        val configuration = TrackingConfiguration.fromMap(arguments["config"] as? Map<*, *>)
        val accepted = PendingLocationCoordinator.diagnose(
            applicationContext,
            performMaintenance = false,
        ) { diagnostic ->
            mainHandler.post {
                if (diagnostic["healthy"] != true) {
                    result.error(
                        "native_journal_unavailable",
                        "The native location journal could not be prepared.",
                        diagnostic,
                    )
                    return@post
                }
                startTrackingAfterJournalReady(trackId, configuration, result)
            }
        }
        if (!accepted) {
            result.error(
                "pending_location_backpressure",
                "The native pending-location worker is overloaded.",
                null,
            )
        }
    }

    private fun startTrackingAfterJournalReady(
        trackId: String,
        configuration: TrackingConfiguration,
        result: MethodChannel.Result,
    ) {
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

        createNotificationChannel(configuration)
        try {
            stateStore.begin(trackId, configuration)
            stateStore.emitCurrentStatus()
        } catch (error: Exception) {
            result.error(
                "native_state_persistence_failed",
                error.message ?: "The native tracking state could not be persisted.",
                stateStore.statusMap(),
            )
            return
        }
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

        // A paused route has no running LocationTrackingService. Completing it
        // is a persisted state transition and must not start an idle foreground
        // service merely to stop it again.
        if (stateStore.isPaused) {
            stateStore.stop(reason)
            stateStore.emitCurrentStatus()
            result.success(stateStore.statusMap())
            return
        }

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
        val accepted = PendingLocationCoordinator.execute(
            applicationContext,
            onFailure = { error ->
                mainHandler.post {
                    result.error(
                        "pending_locations_unavailable",
                        error.message ?: "The native pending-location queue could not be read.",
                        null,
                    )
                }
            },
        ) { store ->
            val pending = store.pending()
            mainHandler.post { result.success(pending) }
        }
        if (!accepted) {
            result.error(
                "pending_location_backpressure",
                "The native pending-location worker is overloaded.",
                null,
            )
        }
    }

    private fun pendingLocationsPage(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
        val cursor = arguments["cursor"] as? String
        val maxRecords = (arguments["maxRecords"] as? Number)?.toInt() ?: 100
        val maxEncodedBytes =
            (arguments["maxEncodedBytes"] as? Number)?.toInt() ?: (256 * 1024)
        val accepted = PendingLocationCoordinator.execute(
            applicationContext,
            onFailure = { error ->
                mainHandler.post {
                    result.error(
                        if (error is PendingLocationCursorException) {
                            "native_journal_cursor_invalid"
                        } else {
                            "pending_locations_unavailable"
                        },
                        error.message ?: "The native pending-location queue could not be read.",
                        null,
                    )
                }
            },
        ) { store ->
            val page = store.page(
                cursor = cursor,
                maxRecords = maxRecords,
                maxEncodedBytes = maxEncodedBytes,
            )
            mainHandler.post { result.success(page.toMap()) }
        }
        if (!accepted) {
            result.error(
                "pending_location_backpressure",
                "The native pending-location worker is overloaded.",
                null,
            )
        }
    }

    private fun nativeJournalDiagnostic(call: MethodCall, result: MethodChannel.Result) {
        val arguments = call.arguments as? Map<*, *> ?: emptyMap<Any?, Any?>()
        val performMaintenance = arguments["performMaintenance"] as? Boolean ?: false
        val accepted = PendingLocationCoordinator.diagnose(
            applicationContext,
            performMaintenance = performMaintenance,
        ) { diagnostic ->
            mainHandler.post { result.success(diagnostic) }
        }
        if (!accepted) {
            result.error(
                "pending_location_backpressure",
                "The native pending-location worker is overloaded.",
                null,
            )
        }
    }

    private fun acknowledgeLocations(call: MethodCall, result: MethodChannel.Result) {
        val values = (call.arguments as? Map<*, *>)?.get("eventIds") as? List<*>
        val eventIds = values?.filterIsInstance<String>().orEmpty()
        val accepted = PendingLocationCoordinator.execute(
            applicationContext,
            onFailure = { error ->
                mainHandler.post {
                    result.error(
                        "pending_location_ack_failed",
                        error.message ?: "Pending locations could not be acknowledged.",
                        null,
                    )
                }
            },
        ) { store ->
            val acknowledged = store.acknowledge(eventIds)
            val pendingCount = store.count()
            mainHandler.post {
                result.success(
                    mapOf(
                        "acknowledged" to acknowledged,
                        "pendingCount" to pendingCount,
                    ),
                )
            }
        }
        if (!accepted) {
            result.error(
                "pending_location_backpressure",
                "The native pending-location worker is overloaded.",
                null,
            )
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

    private fun protocolInfo(): Map<String, Any?> = linkedMapOf(
        "version" to 2,
        "capabilityCodes" to listOf(
            "location_settings",
            "battery_optimization_settings",
            "shared_pending_location_coordinator",
            "checked_lifecycle_persistence",
            "paused_stop_expected_track",
            "legacy_public_export_permission_gate",
            "staged_permission_requests",
            "active_prerequisite_monitor",
            "paged_journal",
            "byte_bounded_journal",
            "native_journal_diagnostics",
            "streaming_export_v2",
            "track_scoped_native_clear",
            "command_lease",
        ),
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

    private data class ActiveExport(
        val handleId: String,
        var output: OutputStream?,
        val contentUri: Uri?,
        val temporaryFile: File?,
        val destinationFile: File?,
        val displayName: String,
        val mimeType: String,
        val displayPath: String?,
        val userVisible: Boolean,
        var committed: Boolean = false,
    ) {
        fun destinationMap(): Map<String, Any?> = linkedMapOf(
            "displayName" to displayName,
            "mimeType" to mimeType,
            "contentUri" to contentUri?.toString(),
            "localFilePath" to destinationFile?.absolutePath,
            "displayPath" to displayPath,
            "userVisible" to userVisible,
        )
    }

    private enum class PermissionRequestStage { NONE, INITIAL, BACKGROUND }

    companion object {
        const val METHOD_CHANNEL = "flutter_background_location/methods"
        const val LOCATION_EVENT_CHANNEL = "flutter_background_location/location"
        const val ACTIVITY_EVENT_CHANNEL = "flutter_background_location/activity"
        const val STATUS_EVENT_CHANNEL = "flutter_background_location/status"
        private const val PERMISSION_REQUEST_CODE = 45_101
        private const val MAX_EXPORT_CHUNK_BYTES = 1024 * 1024

        private fun Map<*, *>?.boolean(key: String, fallback: Boolean): Boolean =
            this?.get(key) as? Boolean ?: fallback
    }
}

private enum class StreamKind { LOCATION, ACTIVITY, STATUS }

private class TrackingStreamHandler(
    private val kind: StreamKind,
    private val currentStatus: () -> Map<String, Any?>,
    private val context: Context? = null,
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
                val replayContext = context
                if (replayContext == null) {
                    TrackingEventBus.addLocationListener(listener)
                } else {
                    replayInProgress = true
                    bufferedLocations.clear()
                    val generation = ++replayGeneration
                    TrackingEventBus.addLocationListener(listener)
                    val accepted = PendingLocationCoordinator.execute(
                        replayContext,
                        onFailure = { error ->
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
                        },
                    ) { store ->
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
                    }
                    if (!accepted) {
                        replayInProgress = false
                        events.error(
                            "pending_location_backpressure",
                            "The native pending-location worker is overloaded.",
                            null,
                        )
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
