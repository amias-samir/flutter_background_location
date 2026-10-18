package com.samir.flutter_background_location

import java.math.BigDecimal
import java.math.BigInteger
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Encodes native location events for the durable pending-location journal.
 *
 * Payload format 2 stores nested maps and lists as JSON strings and lists
 * their keys under [NESTED_KEYS]; decoding inflates them back to maps and
 * lists. Two reasons:
 * - Android's org.json stores a nested Map through `toString()` (`{a=1}`), and
 *   its decoded `JSONObject` values cannot cross the Flutter codec, so motion
 *   evidence and activity probabilities were lost on replay.
 * - Strings keep rows readable after a rollback: an older plugin decodes them
 *   as plain strings, which Dart ignores, instead of failing on JSON objects.
 *
 * Format 1 rows carry the old `toString()` text, which cannot be parsed
 * reliably; it is returned unchanged and Dart treats it as absent evidence.
 */
internal object JournalPayloadCodec {
    /** Recorded as `android_journal_payload_format` in the quality ledger. */
    const val PAYLOAD_FORMAT = 2
    const val NESTED_KEYS = "_nestedJsonKeys"

    fun encode(event: Map<String, Any?>): String {
        val json = JSONObject()
        val nestedKeys = JSONArray()
        for ((key, value) in event) {
            when (value) {
                null -> json.put(key, JSONObject.NULL)
                is Map<*, *>, is Collection<*>, is Array<*> -> {
                    json.put(key, toJson(value).toString())
                    nestedKeys.put(key)
                }
                else -> json.put(key, scalar(value))
            }
        }
        if (nestedKeys.length() > 0) json.put(NESTED_KEYS, nestedKeys)
        return json.toString()
    }

    fun decode(payload: String): Map<String, Any?> {
        val json = JSONObject(payload)
        val nestedKeys = json.optJSONArray(NESTED_KEYS)?.let { keys ->
            (0 until keys.length()).map(keys::optString).toSet()
        }.orEmpty()
        return buildMap {
            for (key in json.keys()) {
                if (key == NESTED_KEYS) continue
                val value = json.opt(key)
                put(
                    key,
                    if (key in nestedKeys && value is String) inflate(value) else fromJson(value),
                )
            }
        }
    }

    private fun inflate(text: String): Any? =
        runCatching { fromJson(JSONTokener(text).nextValue()) }.getOrNull()

    private fun toJson(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().apply {
            for ((key, nested) in value) put(key.toString(), toJson(nested))
        }
        is Collection<*> -> JSONArray().apply { value.forEach { put(toJson(it)) } }
        is Array<*> -> JSONArray().apply { value.forEach { put(toJson(it)) } }
        else -> scalar(value)
    }

    private fun scalar(value: Any): Any = when (value) {
        is Boolean, is Int, is Long, is Float, is Double, is String -> value
        is Byte -> value.toInt()
        is Short -> value.toInt()
        is Number -> value.toDouble()
        else -> value.toString()
    }

    /**
     * Converts parsed JSON into values the Flutter codec can send. Some org.json
     * builds parse decimals as BigDecimal and large integers as BigInteger;
     * Android's parses them as Double and Long.
     */
    private fun fromJson(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> buildMap<String, Any?> {
            for (key in value.keys()) put(key, fromJson(value.opt(key)))
        }
        is JSONArray -> List(value.length()) { index -> fromJson(value.opt(index)) }
        is BigDecimal -> value.toDouble()
        is BigInteger -> value.toLong()
        else -> value
    }
}
