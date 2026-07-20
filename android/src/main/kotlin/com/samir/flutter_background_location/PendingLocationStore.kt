package com.samir.flutter_background_location

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import org.json.JSONObject
import java.io.Closeable
import java.io.File

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
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS $TABLE_PENDING_LOCATIONS (
                event_id TEXT PRIMARY KEY NOT NULL,
                track_id TEXT NOT NULL,
                captured_at INTEGER NOT NULL,
                payload TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """.trimIndent(),
        )
        database.execSQL(
            "CREATE INDEX IF NOT EXISTS pending_locations_order " +
                "ON $TABLE_PENDING_LOCATIONS(captured_at, created_at)",
        )
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
        if (count() >= MAX_PENDING_ROWS || databaseBytes() >= MAX_DATABASE_BYTES) {
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
            "$COLUMN_CAPTURED_AT ASC, $COLUMN_CREATED_AT ASC, rowid ASC",
        ).use { cursor ->
            val payloadIndex = cursor.getColumnIndexOrThrow(COLUMN_PAYLOAD)
            while (cursor.moveToNext()) {
                events += decode(cursor.getString(payloadIndex))
            }
        }
        return events
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
    override fun close() {
        if (database.isOpen) database.close()
    }

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

    private fun databaseBytes(): Long =
        databaseFile.length() +
            File("${databaseFile.absolutePath}-wal").length() +
            File("${databaseFile.absolutePath}-shm").length()

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
        private const val DATABASE_NAME = "flutter_background_location_pending.db"
        private const val TABLE_PENDING_LOCATIONS = "pending_locations"
        private const val COLUMN_EVENT_ID = "event_id"
        private const val COLUMN_TRACK_ID = "track_id"
        private const val COLUMN_CAPTURED_AT = "captured_at"
        private const val COLUMN_PAYLOAD = "payload"
        private const val COLUMN_CREATED_AT = "created_at"
        private const val MAX_IDENTIFIER_LENGTH = 256
        private const val MAX_PAYLOAD_BYTES = 64 * 1024
        private const val MAX_PENDING_ROWS = 25_000
        private const val MAX_DATABASE_BYTES = 64L * 1024L * 1024L
        private const val MAX_SQL_ARGUMENTS = 500
    }
}

internal class PendingLocationCapacityException(message: String) : IllegalStateException(message)
