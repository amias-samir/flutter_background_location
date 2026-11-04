package com.samir.flutter_background_location

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class JournalPayloadCodecTest {
    private val event = linkedMapOf<String, Any?>(
        "eventId" to "event-1",
        "trackId" to "track-1",
        "timestamp" to 1_784_534_400_000L,
        "lat" to 0.0015,
        "accuracy" to 4.5,
        "isMocked" to false,
        "altitude" to null,
        "activityProbabilities" to mapOf("still" to 80, "walking" to 20),
        "motionEvidence" to mapOf(
            "state" to "moving",
            "sources" to listOf("steps", "activity"),
            "steps" to mapOf("delta" to 7, "windowMs" to 30_000L),
        ),
    )

    @Test
    fun nestedValuesSurviveARoundTrip() {
        val decoded = JournalPayloadCodec.decode(JournalPayloadCodec.encode(event))

        // JSON narrows small longs to ints; the Flutter codec sends both as a
        // Dart int, so compare numbers by value.
        assertEquals(normalized(event), normalized(decoded))
        assertFalse(decoded.containsKey(JournalPayloadCodec.NESTED_KEYS))
    }

    private fun normalized(value: Any?): Any? = when (value) {
        is Map<*, *> -> value.entries.associate { (key, nested) -> key to normalized(nested) }
        is List<*> -> value.map(::normalized)
        is Int -> value.toLong()
        is Float -> value.toDouble()
        else -> value
    }

    @Test
    fun nestedValuesAreStoredAsJsonStringsForRollback() {
        // A format-1 decoder reads each value with opt(); it must see strings,
        // never JSON objects that the Flutter codec cannot send.
        val stored = JSONObject(JournalPayloadCodec.encode(event))

        assertTrue(stored.opt("motionEvidence") is String)
        assertTrue(stored.opt("activityProbabilities") is String)
        assertEquals(
            setOf("activityProbabilities", "motionEvidence"),
            stored.getJSONArray(JournalPayloadCodec.NESTED_KEYS).let { keys ->
                (0 until keys.length()).map(keys::getString).toSet()
            },
        )
    }

    @Test
    fun formatOneRowsDecodeWithoutInventingStructure() {
        val legacy = """{"eventId":"event-1","motionEvidence":"{state=moving}","altitude":null}"""

        val decoded = JournalPayloadCodec.decode(legacy)

        assertEquals("{state=moving}", decoded["motionEvidence"])
        assertTrue(decoded.containsKey("altitude"))
        assertNull(decoded["altitude"])
    }

    @Test
    fun scalarOnlyEventsCarryNoMarker() {
        val stored = JSONObject(JournalPayloadCodec.encode(mapOf("eventId" to "event-2")))

        assertFalse(stored.has(JournalPayloadCodec.NESTED_KEYS))
    }
}
