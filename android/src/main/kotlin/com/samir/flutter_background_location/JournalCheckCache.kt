package com.samir.flutter_background_location

import java.io.File

/** Size and modification time of the journal database and its WAL. */
internal data class JournalFileIdentity(
    val databaseBytes: Long,
    val databaseModifiedAt: Long,
    val walBytes: Long,
    val walModifiedAt: Long,
) {
    companion object {
        fun of(database: File): JournalFileIdentity? {
            if (!database.exists()) return null
            val wal = File("${database.absolutePath}-wal")
            return JournalFileIdentity(
                databaseBytes = database.length(),
                databaseModifiedAt = database.lastModified(),
                walBytes = if (wal.exists()) wal.length() else -1L,
                walModifiedAt = if (wal.exists()) wal.lastModified() else -1L,
            )
        }
    }
}

/**
 * Remembers, for this process only, that the journal passed `quick_check`
 * and was closed unchanged since (REL-05 B9). Every stop closed the journal
 * and every start re-read the whole file to check it, including a second
 * time right after the plugin's own check. A reopen of the identical file the
 * same process verified and closed skips the scan; any difference, failure
 * or new process checks again. Host-requested diagnostics always check.
 */
internal class JournalCheckCache {
    private var verifiedAtClose: JournalFileIdentity? = null
    private var verifiedSinceOpen = false

    /** The open store passed (or was trusted to pass) its integrity check. */
    fun markVerified() {
        verifiedSinceOpen = true
    }

    /** A check failed or the store could not be used. */
    fun forget() {
        verifiedSinceOpen = false
        verifiedAtClose = null
    }

    /** Called with the file identity right after the store closed. */
    fun onClosed(identity: JournalFileIdentity?) {
        verifiedAtClose = if (verifiedSinceOpen) identity else null
        verifiedSinceOpen = false
    }

    /** Whether a reopen of a file with [identity] may skip the scan. */
    fun canSkip(identity: JournalFileIdentity?): Boolean {
        val verified = verifiedAtClose ?: return false
        return identity != null && identity == verified
    }

    /** A new store was opened; the closed-file record no longer applies. */
    fun onOpened() {
        verifiedAtClose = null
        verifiedSinceOpen = false
    }
}
