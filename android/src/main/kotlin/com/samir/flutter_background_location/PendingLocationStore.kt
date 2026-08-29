package com.samir.flutter_background_location

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import org.json.JSONObject
import java.io.Closeable
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal data class PendingLocationPage(
    val events: List<Map<String, Any?>>,
    val nextCursor: String?,
    val hasMore: Boolean,
    val encodedBytes: Int,
    val remainingCount: Int,
) {
    fun toMap(): Map<String, Any?> = linkedMapOf(
        "events" to events,
        "nextCursor" to nextCursor,
        "hasMore" to hasMore,
        "encodedBytes" to encodedBytes,
        "remainingCount" to remainingCount,
    )
}

internal data class PendingLocationJournalStats(
    val pendingRows: Int,
    val pendingPayloadBytes: Long,
    val pageSizeBytes: Long,
    val pageCount: Long,
    val freelistPages: Long,
    val livePages: Long,
    val walBytes: Long,
    val maintenanceResult: String,
) {
    val liveDatabaseBytes: Long
        get() = livePages * pageSizeBytes

    fun toMap(): Map<String, Any?> = linkedMapOf(
        "pendingRows" to pendingRows,
        "pendingPayloadBytes" to pendingPayloadBytes,
        "pageSizeBytes" to pageSizeBytes,
        "pageCount" to pageCount,
        "freelistPages" to freelistPages,
        "livePages" to livePages,
        "liveDatabaseBytes" to liveDatabaseBytes,
        "walBytes" to walBytes,
        "maintenanceResult" to maintenanceResult,
    )
}

/**
 * A small native hand-off journal for fixes captured while no Flutter engine is
 * listening. The database lives in noBackupFilesDir because coordinates are
 * sensitive and must not enter Android Auto Backup.
 *
 * Rows are deleted only through [acknowledge]. When the explicit safety bound
 * is reached, [enqueue] throws and capture is stopped rather than silently
 * discarding an unacknowledged fix.
 */
internal class PendingLocationStore(context: Context) : Closeable {
    private val databaseFile = File(context.noBackupFilesDir, DATABASE_NAME)
    private val database: SQLiteDatabase

    init {
        databaseFile.parentFile?.mkdirs()
        database = SQLiteDatabase.openDatabase(
            databaseFile.absolutePath,
            null,
            SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY,
        )
        database.enableWriteAheadLogging()
        database.execSQL("PRAGMA auto_vacuum = INCREMENTAL")
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_PENDING_LOCATIONS (
                event_id TEXT PRIMARY KEY NOT NULL,
                track_id TEXT NOT NULL,
                captured_at INTEGER NOT NULL,
                payload TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                journal_sequence INTEGER NOT NULL UNIQUE
            )
            """.trimIndent(),
        )
        migrateToSequenceSchema()
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS pending_locations_sequence " +
                "ON $TABLE_PENDING_LOCATIONS($COLUMN_JOURNAL_SEQUENCE)",
        )
        database.version = JOURNAL_SCHEMA_VERSION
    }

    @Synchronized
    fun enqueue(event: Map<String, Any?>) {
        val eventId = event["eventId"] as? String
            ?: throw IllegalArgumentException("A pending fix requires an eventId.")
        val trackId = event["trackId"] as? String
            ?: throw IllegalArgumentException("A pending fix requires a trackId.")
        val capturedAt = (event["timestamp"] as? Number)?.toLong()
            ?: throw IllegalArgumentException("A pending fix requires a timestamp.")
        require(eventId.isNotBlank() && eventId.length <= MAX_IDENTIFIER_LENGTH)
        require(trackId.isNotBlank() && trackId.length <= MAX_IDENTIFIER_LENGTH)

        val payload = encode(event)
        if (payload.toByteArray(Charsets.UTF_8).size > MAX_PAYLOAD_BYTES) {
            throw PendingLocationCapacityException("A native location event exceeded its safety limit.")
        }

        // A duplicate UUID is already durable, so it does not consume another
        // row and may be emitted again safely for Dart-side de-duplication.
        if (contains(eventId)) return
        if (isAtCapacity(stats(performMaintenance = false)) &&
            isAtCapacity(stats(performMaintenance = true))
        ) {
            throw PendingLocationCapacityException(
                "The native pending-location queue is full; reconnect the app to persist pending fixes.",
            )
        }

        val values = ContentValues().apply {
            put(COLUMN_EVENT_ID, eventId)
            put(COLUMN_TRACK_ID, trackId)
            put(COLUMN_CAPTURED_AT, capturedAt)
            put(COLUMN_PAYLOAD, payload)
            put(COLUMN_CREATED_AT, System.currentTimeMillis())
            put(COLUMN_JOURNAL_SEQUENCE, nextJournalSequence())
        }
        database.beginTransaction()
        try {
            val rowId = database.insertWithOnConflict(
                TABLE_PENDING_LOCATIONS,
                null,
                values,
                SQLiteDatabase.CONFLICT_IGNORE,
            )
            if (rowId == -1L && !contains(eventId)) {
                throw IllegalStateException("The native pending-location fix could not be stored.")
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    @Synchronized
    fun pending(): List<Map<String, Any?>> {
        val events = ArrayList<Map<String, Any?>>()
        database.query(
            TABLE_PENDING_LOCATIONS,
            arrayOf(COLUMN_PAYLOAD),
            null,
            null,
            null,
            null,
            "$COLUMN_JOURNAL_SEQUENCE ASC",
        ).use { cursor ->
            val payloadIndex = cursor.getColumnIndexOrThrow(COLUMN_PAYLOAD)
            while (cursor.moveToNext()) {
                events += decode(cursor.getString(payloadIndex))
            }
        }
        return events
    }

    @Synchronized
    fun page(cursor: String?, maxRecords: Int, maxEncodedBytes: Int): PendingLocationPage {
        val afterSequence = when {
            cursor == null -> 0L
            cursor.toLongOrNull() == null || cursor.toLong() < 0L ->
                throw PendingLocationCursorException("The native journal cursor is invalid.")
            else -> cursor.toLong()
        }
        val recordLimit = maxRecords.coerceIn(1, MAX_PAGE_RECORDS)
        val byteLimit = maxEncodedBytes.coerceIn(MIN_PAGE_BYTES, MAX_PAGE_BYTES)
        val events = ArrayList<Map<String, Any?>>()
        var encodedBytes = 0
        var lastSequence = afterSequence
        var hasMore = false

        database.rawQuery(
            """
            SELECT $COLUMN_JOURNAL_SEQUENCE, $COLUMN_PAYLOAD
            FROM $TABLE_PENDING_LOCATIONS
            WHERE $COLUMN_JOURNAL_SEQUENCE > ?
            ORDER BY $COLUMN_JOURNAL_SEQUENCE ASC
            LIMIT ?
            """.trimIndent(),
            arrayOf(afterSequence.toString(), (recordLimit + 1).toString()),
        ).use { cursor ->
            val rowIdIndex = cursor.getColumnIndexOrThrow(COLUMN_JOURNAL_SEQUENCE)
            val payloadIndex = cursor.getColumnIndexOrThrow(COLUMN_PAYLOAD)
            while (cursor.moveToNext()) {
                val sequence = cursor.getLong(rowIdIndex)
                val payload = cursor.getString(payloadIndex)
                val payloadBytes = payload.toByteArray(Charsets.UTF_8).size
                if (events.size >= recordLimit ||
                    (events.isNotEmpty() && encodedBytes + payloadBytes > byteLimit)
                ) {
                    hasMore = true
                    break
                }

                events += decode(payload)
                encodedBytes += payloadBytes
                lastSequence = sequence
            }
        }

        val remaining = if (events.isEmpty()) {
            countAfter(afterSequence)
        } else {
            countAfter(lastSequence)
        }
        return PendingLocationPage(
            events = events,
            nextCursor = if (events.isEmpty()) null else lastSequence.toString(),
            hasMore = hasMore || remaining > 0,
            encodedBytes = encodedBytes,
            remainingCount = remaining,
        )
    }

    @Synchronized
    fun acknowledge(eventIds: Collection<String>): Int {
        val validIds = eventIds
            .asSequence()
            .filter { it.isNotBlank() && it.length <= MAX_IDENTIFIER_LENGTH }
            .distinct()
            .toList()
        if (validIds.isEmpty()) return 0

        var deleted = 0
        database.beginTransaction()
        try {
            validIds.chunked(MAX_SQL_ARGUMENTS).forEach { chunk ->
                val placeholders = List(chunk.size) { "?" }.joinToString(",")
                deleted += database.delete(
                    TABLE_PENDING_LOCATIONS,
                    "$COLUMN_EVENT_ID IN ($placeholders)",
                    chunk.toTypedArray(),
                )
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
        val remaining = count()
        if (remaining == 0) {
            stats(performMaintenance = true)
        }
        return deleted
    }

    /** Deletes only journal evidence owned by the explicitly selected track. */
    @Synchronized
    fun deleteTrack(trackId: String): Int {
        require(trackId.isNotBlank() && trackId.length <= MAX_IDENTIFIER_LENGTH) {
            "A valid trackId is required."
        }
        val deleted = database.delete(
            TABLE_PENDING_LOCATIONS,
            "$COLUMN_TRACK_ID = ?",
            arrayOf(trackId),
        )
        if (count() == 0) stats(performMaintenance = true)
        return deleted
    }

    @Synchronized
    fun count(): Int = database.rawQuery(
        "SELECT COUNT(*) FROM $TABLE_PENDING_LOCATIONS",
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getInt(0) else 0
    }

    @Synchronized
    fun stats(performMaintenance: Boolean = false): PendingLocationJournalStats {
        val maintenanceResult =
            if (performMaintenance) checkpointWal() else MAINTENANCE_NOT_RUN
        val pageSize = pragmaLong("page_size").coerceAtLeast(1L)
        val pageCount = pragmaLong("page_count").coerceAtLeast(0L)
        val freelistPages = pragmaLong("freelist_count").coerceAtLeast(0L)
            .coerceAtMost(pageCount)
        val livePages = (pageCount - freelistPages).coerceAtLeast(0L)
        return PendingLocationJournalStats(
            pendingRows = count(),
            pendingPayloadBytes = pendingPayloadBytes(),
            pageSizeBytes = pageSize,
            pageCount = pageCount,
            freelistPages = freelistPages,
            livePages = livePages,
            walBytes = walBytes(),
            maintenanceResult = maintenanceResult,
        )
    }

    @Synchronized
    fun diagnostic(performMaintenance: Boolean = false): Map<String, Any?> {
        val integrity = quickCheck()
        return linkedMapOf(
            "platform" to "android",
            "healthy" to (integrity == "ok"),
            "opened" to true,
            "databaseName" to DATABASE_NAME,
            "integrityCheck" to integrity,
            "stats" to stats(performMaintenance).toMap(),
            "usableSpaceBytes" to (databaseFile.parentFile?.usableSpace ?: databaseFile.usableSpace),
        )
    }

    private fun countAfter(sequence: Long): Int = database.rawQuery(
        "SELECT COUNT(*) FROM $TABLE_PENDING_LOCATIONS WHERE $COLUMN_JOURNAL_SEQUENCE > ?",
        arrayOf(sequence.toString()),
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getInt(0) else 0
    }

    @Synchronized
    override fun close() {
        if (database.isOpen) database.close()
    }

    private fun isAtCapacity(stats: PendingLocationJournalStats): Boolean =
        stats.pendingRows >= MAX_PENDING_ROWS ||
            stats.pendingPayloadBytes >= MAX_DATABASE_BYTES ||
            stats.liveDatabaseBytes >= MAX_DATABASE_BYTES

    private fun contains(eventId: String): Boolean = database.query(
        TABLE_PENDING_LOCATIONS,
        arrayOf(COLUMN_EVENT_ID),
        "$COLUMN_EVENT_ID = ?",
        arrayOf(eventId),
        null,
        null,
        null,
        "1",
    ).use { it.moveToFirst() }

    private fun nextJournalSequence(): Long = database.rawQuery(
        "SELECT COALESCE(MAX($COLUMN_JOURNAL_SEQUENCE), 0) + 1 FROM $TABLE_PENDING_LOCATIONS",
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else 1L
    }

    private fun migrateToSequenceSchema() {
        val columns = mutableSetOf<String>()
        database.rawQuery("PRAGMA table_info($TABLE_PENDING_LOCATIONS)", null).use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow("name")
            while (cursor.moveToNext()) columns += cursor.getString(nameIndex)
        }
        if (COLUMN_JOURNAL_SEQUENCE in columns) return

        database.beginTransaction()
        try {
            database.execSQL(
                "ALTER TABLE $TABLE_PENDING_LOCATIONS ADD COLUMN $COLUMN_JOURNAL_SEQUENCE INTEGER",
            )
            var sequence = 1L
            database.rawQuery(
                "SELECT rowid FROM $TABLE_PENDING_LOCATIONS " +
                    "ORDER BY $COLUMN_CAPTURED_AT ASC, $COLUMN_CREATED_AT ASC, rowid ASC",
                null,
            ).use { cursor ->
                while (cursor.moveToNext()) {
                    database.execSQL(
                        "UPDATE $TABLE_PENDING_LOCATIONS SET $COLUMN_JOURNAL_SEQUENCE = ? WHERE rowid = ?",
                        arrayOf(sequence, cursor.getLong(0)),
                    )
                    sequence += 1L
                }
            }
            database.setTransactionSuccessful()
        } finally {
            database.endTransaction()
        }
    }

    private fun pendingPayloadBytes(): Long = database.rawQuery(
        "SELECT COALESCE(SUM(length($COLUMN_PAYLOAD)), 0) FROM $TABLE_PENDING_LOCATIONS",
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else 0L
    }

    private fun pragmaLong(name: String): Long = database.rawQuery(
        "PRAGMA $name",
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getLong(0) else 0L
    }

    private fun checkpointWal(): String {
        val wal = File("${databaseFile.absolutePath}-wal")
        if (!wal.exists() || wal.length() == 0L) return "wal_empty"
        return database.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { cursor ->
            if (!cursor.moveToFirst()) return@use "wal_checkpoint_no_result"
            val busy = cursor.getInt(0)
            val logFrames = cursor.getInt(1)
            val checkpointedFrames = cursor.getInt(2)
            "wal_checkpoint_truncate_busy_${busy}_log_${logFrames}_checkpointed_$checkpointedFrames"
        }
    }

    private fun quickCheck(): String = database.rawQuery(
        "PRAGMA quick_check(1)",
        null,
    ).use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) ?: "empty_result" else "no_result"
    }

    private fun walBytes(): Long = File("${databaseFile.absolutePath}-wal").length()

    private fun encode(event: Map<String, Any?>): String = JSONObject().apply {
        event.forEach { (key, value) -> put(key, value ?: JSONObject.NULL) }
    }.toString()

    private fun decode(payload: String): Map<String, Any?> {
        val json = JSONObject(payload)
        return buildMap {
            json.keys().forEach { key ->
                val value = json.opt(key)
                put(key, if (value == JSONObject.NULL) null else value)
            }
        }
    }

    companion object {
        val databaseNameForDiagnostics: String = DATABASE_NAME

        private const val DATABASE_NAME = "flutter_background_location_pending.db"
        private const val TABLE_PENDING_LOCATIONS = "pending_locations"
        private const val COLUMN_EVENT_ID = "event_id"
        private const val COLUMN_TRACK_ID = "track_id"
        private const val COLUMN_CAPTURED_AT = "captured_at"
        private const val COLUMN_PAYLOAD = "payload"
        private const val COLUMN_CREATED_AT = "created_at"
        private const val COLUMN_JOURNAL_SEQUENCE = "journal_sequence"
        private const val MAX_IDENTIFIER_LENGTH = 256
        private const val MAX_PAYLOAD_BYTES = 64 * 1024
        private const val MAX_PENDING_ROWS = 25_000
        private const val MAX_DATABASE_BYTES = 64L * 1024L * 1024L
        private const val MIN_PAGE_BYTES = MAX_PAYLOAD_BYTES
        // Leaves conservative headroom for StandardMessageCodec map/list keys.
        private const val MAX_PAGE_BYTES = 900 * 1024
        private const val MAX_PAGE_RECORDS = 250
        private const val JOURNAL_SCHEMA_VERSION = 2
        private const val MAX_SQL_ARGUMENTS = 500
        private const val MAINTENANCE_NOT_RUN = "not_run"
    }
}

internal class PendingLocationCapacityException(message: String) : IllegalStateException(message)
internal class PendingLocationCursorException(message: String) : IllegalArgumentException(message)

internal object PendingLocationCoordinator {
    private val executor = ThreadPoolExecutor(
        1,
        1,
        0L,
        TimeUnit.MILLISECONDS,
        ArrayBlockingQueue(MAX_QUEUED_TASKS),
        { runnable -> Thread(runnable, "fbl-pending-locations").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
    )
    private val lock = Any()
    private var store: PendingLocationStore? = null

    fun execute(
        context: Context,
        onFailure: (Exception) -> Unit = {},
        action: (PendingLocationStore) -> Unit,
    ): Boolean {
        return executeForResult(
            context = context,
            onSuccess = {},
            onFailure = onFailure,
        ) { store ->
            action(store)
        }
    }

    fun <T> executeForResult(
        context: Context,
        onSuccess: (T) -> Unit,
        onFailure: (Exception) -> Unit = {},
        action: (PendingLocationStore) -> T,
    ): Boolean {
        val appContext = context.applicationContext
        return try {
            executor.execute {
                try {
                    onSuccess(action(storeFor(appContext)))
                } catch (error: Exception) {
                    onFailure(error)
                }
            }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    fun diagnose(
        context: Context,
        performMaintenance: Boolean = false,
        onDiagnostic: (Map<String, Any?>) -> Unit,
    ): Boolean {
        val appContext = context.applicationContext
        return try {
            executor.execute {
                val diagnostic = try {
                    storeFor(appContext).diagnostic(performMaintenance)
                } catch (error: Exception) {
                    failureDiagnostic(error)
                }
                onDiagnostic(diagnostic)
            }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    fun closeAsync(context: Context): Boolean {
        val appContext = context.applicationContext
        return try {
            executor.execute {
                synchronized(lock) {
                    store?.close()
                    store = null
                }
            }
            true
        } catch (_: RejectedExecutionException) {
            false
        }
    }

    private fun storeFor(context: Context): PendingLocationStore =
        synchronized(lock) {
            store ?: PendingLocationStore(context).also { store = it }
        }

    private fun failureDiagnostic(error: Exception): Map<String, Any?> = linkedMapOf(
        "platform" to "android",
        "healthy" to false,
        "opened" to false,
        "databaseName" to PendingLocationStore.databaseNameForDiagnostics,
        "errorType" to error.javaClass.simpleName,
        "errorMessage" to (error.message ?: "Native journal initialization failed."),
    )

    private const val MAX_QUEUED_TASKS = 512
}
