package com.samir.flutter_background_location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The persisted step checkpoint and final behind status `stepFinal`. */
class StepRecordCodecTest {
    @Test
    fun aFinalRoundTripsIntoTheStatusMap() {
        val snapshot = StepSnapshot(
            generationId = "generation-1",
            steps = 2_175L,
            coverage = StepCoverage(
                state = StepCoverage.STATE_STALLED,
                countedThrough = 1_800_000_060_000L,
                lastRiseAt = 1_800_000_000_000L,
                uncountedMs = 240_000L,
                sensor = StepCoverage.SENSOR_NON_WAKE_UP,
                reregistrations = 3,
            ),
        )
        val decoded = StepRecordCodec.decode(StepRecordCodec.encode(snapshot))
        assertEquals(snapshot, decoded)
        assertEquals(
            linkedMapOf<String, Any?>(
                "captureGenerationId" to "generation-1",
                "stepCount" to 2_175L,
                "stepCoverage" to snapshot.coverage.toMap(),
            ),
            StepRecordCodec.toStatusMap(decoded!!),
        )
    }

    @Test
    fun unmeasuredStepsAndMissingTimesStayNull() {
        val snapshot = StepSnapshot("generation-2", null, StepCoverage.UNAVAILABLE)
        assertEquals(snapshot, StepRecordCodec.decode(StepRecordCodec.encode(snapshot)))
    }

    @Test
    fun corruptOrAnonymousRecordsAreIgnored() {
        assertNull(StepRecordCodec.decode(null))
        assertNull(StepRecordCodec.decode(""))
        assertNull(StepRecordCodec.decode("{not json"))
        assertNull(StepRecordCodec.decode("""{"stepCount":12}"""))
        // A record without coverage reads as unavailable coverage.
        assertEquals(
            StepSnapshot("generation-3", 12L, StepCoverage.UNAVAILABLE),
            StepRecordCodec.decode("""{"captureGenerationId":"generation-3","stepCount":12}"""),
        )
    }
}
