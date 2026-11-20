package com.samir.flutter_background_location

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

class TrackingBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        DiagnosticsMode.load(context)
        val store = TrackingStateStore(context)
        val decision = TrackingServiceLifecycle.bootRestore(
            trackingEnabled = store.trackingEnabled,
            isPaused = store.isPaused,
            hasTrackId = store.activeTrackId != null,
            sdkInt = Build.VERSION.SDK_INT,
            hasForegroundLocation = granted(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
                granted(context, Manifest.permission.ACCESS_COARSE_LOCATION),
            hasBackgroundLocation = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION),
        )
        when (decision) {
            TrackingServiceLifecycle.BootRestore.SKIP -> return
            TrackingServiceLifecycle.BootRestore.INTERRUPT -> {
                // Starting a location service from the background without
                // background location would be refused or receive no fixes;
                // the route waits, resumable, for the app to open.
                runCatching {
                    store.interrupt("Background location is required to restore tracking after a restart.")
                    store.emitCurrentStatus()
                }
                return
            }
            TrackingServiceLifecycle.BootRestore.RESTORE -> Unit
        }

        val serviceIntent = Intent(context, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_RESTORE
        }
        runCatching {
            ContextCompat.startForegroundService(context, serviceIntent)
        }.onFailure { error ->
            // The route was capturing and can be resumed; it is interrupted,
            // never failed, by a restart Android would not allow.
            runCatching {
                store.interrupt(DiagnosticsMode.detail("Android could not restore tracking.", error))
                store.emitCurrentStatus()
            }
        }
    }

    private fun granted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
