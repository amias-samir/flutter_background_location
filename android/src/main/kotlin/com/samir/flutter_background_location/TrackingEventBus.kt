package com.samir.flutter_background_location

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArraySet

internal object TrackingEventBus {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val locationListeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private val activityListeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private val statusListeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()

    @Volatile
    var lastLocation: Map<String, Any?>? = null
        private set

    @Volatile
    var lastActivity: Map<String, Any?>? = null
        private set

    @Volatile
    var lastStatus: Map<String, Any?>? = null
        private set

    fun addLocationListener(listener: (Map<String, Any?>) -> Unit) {
        locationListeners.add(listener)
        lastLocation?.let { dispatch(listener, it) }
    }

    fun removeLocationListener(listener: (Map<String, Any?>) -> Unit) {
        locationListeners.remove(listener)
    }

    fun addActivityListener(listener: (Map<String, Any?>) -> Unit) {
        activityListeners.add(listener)
        lastActivity?.let { dispatch(listener, it) }
    }

    fun removeActivityListener(listener: (Map<String, Any?>) -> Unit) {
        activityListeners.remove(listener)
    }

    fun addStatusListener(listener: (Map<String, Any?>) -> Unit) {
        statusListeners.add(listener)
        lastStatus?.let { dispatch(listener, it) }
    }

    fun removeStatusListener(listener: (Map<String, Any?>) -> Unit) {
        statusListeners.remove(listener)
    }

    fun emitLocation(event: Map<String, Any?>) {
        val immutableEvent = LinkedHashMap(event)
        lastLocation = immutableEvent
        dispatch(locationListeners, immutableEvent)
    }

    fun emitActivity(event: Map<String, Any?>) {
        val immutableEvent = LinkedHashMap(event)
        lastActivity = immutableEvent
        dispatch(activityListeners, immutableEvent)
    }

    fun emitStatus(event: Map<String, Any?>) {
        val immutableEvent = LinkedHashMap(event)
        lastStatus = immutableEvent
        dispatch(statusListeners, immutableEvent)
    }

    private fun dispatch(
        listeners: Set<(Map<String, Any?>) -> Unit>,
        event: Map<String, Any?>,
    ) {
        runOnMain {
            listeners.forEach { listener ->
                runCatching { listener(event) }
            }
        }
    }

    private fun dispatch(
        listener: (Map<String, Any?>) -> Unit,
        event: Map<String, Any?>,
    ) {
        runOnMain { runCatching { listener(event) } }
    }

    private fun runOnMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            action()
        } else {
            mainHandler.post(action)
        }
    }
}

