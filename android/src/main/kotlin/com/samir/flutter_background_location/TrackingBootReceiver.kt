package com.samir.flutter_background_location

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class TrackingBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        val store = TrackingStateStore(context)
        if (!store.trackingEnabled || store.isPaused || store.activeTrackId == null) return

        val serviceIntent = Intent(context, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_RESTORE
        }
        runCatching {
            ContextCompat.startForegroundService(context, serviceIntent)
        }.onFailure { error ->
            store.fail("Android could not restore tracking: ${error.message.orEmpty()}")
            store.emitCurrentStatus()
        }
    }
}
