package com.samir.flutter_background_location

import java.util.UUID

/** Process-global lifecycle-command fencing shared by all Flutter engines. */
internal object NativeCommandCoordinator {
    data class Lease(
        val engineId: String,
        val engineLeaseToken: String,
        val trackId: String,
        val sessionControlToken: String,
    )

    data class Permit(
        val commandId: String,
        val sessionControlToken: String,
        val revision: Long,
        val replayed: Boolean,
    )

    class Rejection(val code: String, override val message: String) : Exception(message)

    private var lease: Lease? = null
    private var pendingCommandId: String? = null

    @Synchronized
    fun acquire(
        store: TrackingStateStore,
        engineId: String,
        trackId: String,
        sessionControlToken: String,
    ): Lease {
        if (trackId.isBlank() || sessionControlToken.isBlank()) {
            throw Rejection("native_command_lease_invalid", "Lease identity is incomplete.")
        }
        val activeTrackId = store.activeTrackId
        val activeSession = store.sessionControlToken
        if (activeTrackId != null && activeTrackId != trackId && store.state != TrackingStateStore.STATE_IDLE) {
            throw Rejection(
                "native_command_lease_conflict",
                "Another native tracking session currently owns lifecycle commands.",
            )
        }
        if (activeSession != null && activeSession != sessionControlToken &&
            store.state != TrackingStateStore.STATE_IDLE
        ) {
            throw Rejection(
                "native_command_lease_conflict",
                "The durable native session does not match this command session.",
            )
        }
        val current = lease
        if (current != null && current.engineId != engineId) {
            throw Rejection(
                "native_command_lease_conflict",
                "Another Flutter engine currently owns lifecycle commands.",
            )
        }
        if (current != null &&
            (current.trackId != trackId || current.sessionControlToken != sessionControlToken)
        ) {
            throw Rejection(
                "native_command_lease_conflict",
                "Release the current command lease before binding another session.",
            )
        }
        if (current != null) return current
        store.claimSessionControl(sessionControlToken)
        return Lease(
            engineId = engineId,
            engineLeaseToken = UUID.randomUUID().toString(),
            trackId = trackId,
            sessionControlToken = sessionControlToken,
        ).also { lease = it }
    }

    @Synchronized
    fun begin(
        store: TrackingStateStore,
        engineId: String,
        arguments: Map<*, *>,
    ): Permit {
        val current = lease ?: throw Rejection(
            "native_command_lease_conflict",
            "No Flutter engine owns the native command lease.",
        )
        val leaseToken = arguments["engineLeaseToken"] as? String
        val sessionToken = arguments["sessionControlToken"] as? String
        val trackId = arguments["trackId"] as? String
        val commandId = arguments["commandId"] as? String
        val expectedRevision = (arguments["expectedCommandRevision"] as? Number)?.toLong()
        if (current.engineId != engineId || current.engineLeaseToken != leaseToken ||
            current.sessionControlToken != sessionToken || current.trackId != trackId
        ) {
            throw Rejection(
                "native_command_lease_conflict",
                "The command does not own the current native lease.",
            )
        }
        if (commandId.isNullOrBlank() || expectedRevision == null || expectedRevision < 0L) {
            throw Rejection("native_command_invalid", "Command identity or revision is invalid.")
        }
        val revision = store.commandRevision
        if (store.lastCommandId == commandId) {
            return Permit(commandId, current.sessionControlToken, revision, replayed = true)
        }
        if (expectedRevision != revision) {
            throw Rejection(
                "native_command_revision_conflict",
                "The lifecycle command was based on a stale native revision.",
            )
        }
        if (pendingCommandId != null) {
            throw Rejection(
                "native_command_in_progress",
                "Another native lifecycle command is still being applied.",
            )
        }
        pendingCommandId = commandId
        return Permit(commandId, current.sessionControlToken, revision, replayed = false)
    }

    @Synchronized
    fun complete(store: TrackingStateStore, permit: Permit): Long {
        if (permit.replayed) return permit.revision
        if (pendingCommandId != permit.commandId) {
            throw Rejection("native_command_invalid", "The command reservation was lost.")
        }
        val next = permit.revision + 1L
        store.recordCommandResult(permit.sessionControlToken, permit.commandId, next)
        pendingCommandId = null
        return next
    }

    @Synchronized
    fun fail(permit: Permit) {
        if (!permit.replayed && pendingCommandId == permit.commandId) pendingCommandId = null
    }

    @Synchronized
    fun release(engineId: String, engineLeaseToken: String?) {
        val current = lease ?: return
        if (current.engineId == engineId &&
            (engineLeaseToken == null || current.engineLeaseToken == engineLeaseToken)
        ) {
            lease = null
            pendingCommandId = null
        }
    }

    @Synchronized
    fun hasLease(): Boolean = lease != null
}
