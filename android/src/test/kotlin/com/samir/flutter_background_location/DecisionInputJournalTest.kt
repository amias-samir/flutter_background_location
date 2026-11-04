package com.samir.flutter_background_location

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Replays the activity-reading compaction fixture shared with Swift. */
class DecisionInputJournalTest {
    private val fixture = JSONObject(
        requireNotNull(javaClass.classLoader?.getResource("activity_reading_compaction_v1.json")) {
            "activity_reading_compaction_v1.json is missing from the test resources"
        }.readText(),
    )

    private val moving = TrackingStateStore.PROFILE_MOVING
    private val stationary = TrackingStateStore.PROFILE_STATIONARY

    @Test
    fun replaysEveryCompactionScenario() {
        val maximumReadings = fixture.getJSONObject("config").getInt("maxReadings")
        val scenarios = fixture.getJSONArray("scenarios")
        for (index in 0 until scenarios.length()) {
            val scenario = scenarios.getJSONObject(index)
            val name = scenario.getString("name")
            val journal = DecisionInputJournal(maximumReadings = maximumReadings)
            journal.reset(moving)
            val readings = scenario.getJSONArray("readings")
            val inputs = (0 until readings.length()).map { reading(readings.getJSONObject(it)) }
            inputs.forEach(journal::onActivityReading)

            val attachment = journal.drain()
            val expected = scenario.getJSONArray("kept")
            val keptIndices = attachment.activityReadings.map { (it["seq"] as Long).toInt() - 1 }
            assertEquals(name, (0 until expected.length()).map { expected.getInt(it) }, keptIndices)
            assertEquals(name, scenario.getInt("dropped"), attachment.activityReadingsDropped)
            // A kept reading is the emitted map plus its sequence number.
            attachment.activityReadings.forEach { kept ->
                val input = inputs[(kept["seq"] as Long).toInt() - 1]
                assertEquals(name, input + ("seq" to kept["seq"]), kept)
            }
        }
        assertTrue(scenarios.length() >= 7)
    }

    @Test
    fun seqCountsReadingsAndSwitchesTogetherWithinAGeneration() {
        val journal = DecisionInputJournal()
        journal.reset(moving)
        journal.onActivityReading(periodic("stationary", 100, 0))
        journal.onProfileSwitch(1_000L, 1_800_000_001_000L, moving, stationary, "still_episode")
        journal.onActivityReading(periodic("walking", 90, 2))
        val first = journal.drain()
        assertEquals(listOf(1L, 3L), first.activityReadings.map { it["seq"] })
        assertEquals(
            listOf(
                linkedMapOf<String, Any?>(
                    "seq" to 2L,
                    "at" to 1_800_000_001_000L,
                    "from" to "moving",
                    "to" to "stationary",
                    "reason" to "still_episode",
                ),
            ),
            first.profileTransitions,
        )

        journal.onActivityReading(periodic("walking", 90, 3))
        assertEquals(listOf(4L), journal.drain().activityReadings.map { it["seq"] })

        // A new capture generation counts from one again.
        journal.reset(moving)
        journal.onActivityReading(periodic("walking", 90, 4))
        assertEquals(listOf(1L), journal.drain().activityReadings.map { it["seq"] })
    }

    @Test
    fun aDrainStartsTheNextFixEmptyAndRunsDoNotSpanFixes() {
        val journal = DecisionInputJournal()
        journal.reset(moving)
        repeat(3) { journal.onActivityReading(periodic("stationary", 100, it)) }
        assertEquals(listOf(1L, 3L), journal.drain().activityReadings.map { it["seq"] })

        val empty = journal.drain()
        assertTrue(empty.activityReadings.isEmpty())
        assertTrue(empty.profileTransitions.isEmpty())
        assertEquals(0, empty.activityReadingsDropped)

        // The same run continuing after a fix starts a run of its own.
        journal.onActivityReading(periodic("stationary", 100, 3))
        assertEquals(listOf(4L), journal.drain().activityReadings.map { it["seq"] })
    }

    @Test
    fun theByteBudgetDropsTheOldestReadings() {
        val journal = DecisionInputJournal()
        journal.reset(moving)
        repeat(64) { index ->
            journal.onActivityReading(
                periodic("walking", 90, index) + mapOf(
                    "source" to "android_activity_transition",
                    "rawType" to "x".repeat(500),
                ),
            )
        }
        val attachment = journal.drain()
        val serialized = JSONArray(attachment.activityReadings).toString().toByteArray(Charsets.UTF_8)
        assertTrue(serialized.size <= DecisionInputJournal.MAXIMUM_READING_BYTES)
        assertTrue(attachment.activityReadings.size in 20..40)
        assertEquals(64, attachment.activityReadings.size + attachment.activityReadingsDropped)
        // The newest readings survive.
        assertEquals(64L, attachment.activityReadings.last()["seq"])
        assertEquals(
            serialized.size,
            DecisionInputJournal.jsonLength(attachment.activityReadings),
        )
    }

    @Test
    fun profileTransitionsKeepTheNewestEight() {
        val journal = DecisionInputJournal()
        journal.reset(moving)
        repeat(10) { index ->
            val (from, to) = if (index % 2 == 0) moving to stationary else stationary to moving
            journal.onProfileSwitch(index * 1_000L, 1_800_000_000_000L + index, from, to, "doppler")
        }
        val transitions = journal.drain().profileTransitions
        assertEquals(8, transitions.size)
        assertEquals((3L..10L).toList(), transitions.map { it["seq"] })
    }

    @Test
    fun aFixIsStampedWithTheProfileInEffectWhenItWasCaptured() {
        val journal = DecisionInputJournal()
        journal.reset(moving)
        assertEquals(moving, journal.profileAt(5_000L))

        journal.onProfileSwitch(10_000L, 1L, moving, stationary, "still_episode")
        journal.onProfileSwitch(20_000L, 2L, stationary, moving, "doppler")
        // One batch delivered after both switches straddles them.
        assertEquals(moving, journal.profileAt(9_999L))
        assertEquals(stationary, journal.profileAt(10_000L))
        assertEquals(stationary, journal.profileAt(19_999L))
        assertEquals(moving, journal.profileAt(20_000L))
        // Without a capture time, the current profile.
        assertEquals(moving, journal.profileAt(0L))
    }

    @Test
    fun aFixOlderThanTheSwitchHistoryGetsTheProfileBeforeIt() {
        val journal = DecisionInputJournal(profileHistorySize = 2)
        journal.reset(moving)
        journal.onProfileSwitch(10_000L, 1L, moving, stationary, null)
        journal.onProfileSwitch(20_000L, 2L, stationary, moving, null)
        journal.onProfileSwitch(30_000L, 3L, moving, stationary, null)
        assertEquals(moving, journal.profileAt(25_000L))
        // The first switch left the history; the oldest kept one says what
        // came before it.
        assertEquals(stationary, journal.profileAt(15_000L))
        assertEquals(stationary, journal.profileAt(40_000L))
    }

    @Test
    fun theInputsSurviveTheJournalPayloadCodec() {
        val journal = DecisionInputJournal()
        journal.reset(moving)
        journal.onActivityReading(periodic("stationary", 100, 0) + ("episodeStartedAt" to 1_799_999_990_000L))
        journal.onActivityReading(periodic("walking", 85, 1))
        journal.onProfileSwitch(1_000L, 1_800_000_006_000L, stationary, moving, null)
        val inputs = journal.drain()
        val event = linkedMapOf<String, Any?>(
            "eventId" to "event-1",
            "trackId" to "track-1",
            "timestamp" to 1_800_000_007_000L,
            "stepCoverage" to StepCoverage.UNAVAILABLE.toMap(),
            "activityReadings" to inputs.activityReadings,
            "profileTransitions" to inputs.profileTransitions,
        )

        val decoded = JournalPayloadCodec.decode(JournalPayloadCodec.encode(event))
        // JSON narrows small longs to ints; Dart reads both as int.
        assertEquals(normalized(event), normalized(decoded))
    }

    private fun normalized(value: Any?): Any? = when (value) {
        is Map<*, *> -> value.entries.associate { (key, nested) -> key to normalized(nested) }
        is List<*> -> value.map(::normalized)
        is Int -> value.toLong()
        else -> value
    }

    private fun reading(json: JSONObject): Map<String, Any?> = linkedMapOf(
        "type" to json.getString("type"),
        "confidence" to json.getInt("confidence"),
        "timestamp" to json.getLong("timestamp"),
        "source" to json.getString("source"),
    )

    private fun periodic(type: String, confidence: Int, index: Int): Map<String, Any?> = linkedMapOf(
        "type" to type,
        "rawType" to type,
        "confidence" to confidence,
        "timestamp" to 1_800_000_000_000L + index * 5_000L,
        "available" to true,
        "source" to "android_activity_recognition",
        "evidenceState" to "fresh",
        "ageMs" to 120L,
        "probabilities" to mapOf(type to confidence),
    )
}
