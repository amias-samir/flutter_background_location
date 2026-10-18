package com.samir.flutter_background_location

/**
 * Turns step events into movement evidence. A single step (a weight shift,
 * picking up the phone) is not movement; sustained stepping is. Reports at
 * most once per [emitIntervalMs] while the cadence holds, instead of once per
 * step.
 */
internal class StepCadenceWindow(
    private val minimumSteps: Int = 6,
    private val windowMs: Long = 30_000L,
    private val emitIntervalMs: Long = 10_000L,
) {
    private val steps = ArrayDeque<Long>()
    private var lastReportedAt: Long? = null

    /** Records one step at [nowElapsed]; true when movement should be reported. */
    fun onStep(nowElapsed: Long): Boolean {
        steps.addLast(nowElapsed)
        while (steps.isNotEmpty() && nowElapsed - steps.first() > windowMs) steps.removeFirst()
        if (steps.size < minimumSteps) return false
        val last = lastReportedAt
        if (last != null && nowElapsed - last < emitIntervalMs) return false
        lastReportedAt = nowElapsed
        return true
    }

    fun reset() {
        steps.clear()
        lastReportedAt = null
    }
}

/**
 * Sensor-probe time used in the trailing [windowMs]. A sliding window, so
 * probes on both sides of a fixed hour boundary cannot spend twice the
 * budget.
 */
internal class RollingProbeBudget(private val windowMs: Long = 3_600_000L) {
    private val probes = ArrayDeque<LongArray>()

    fun usedMs(nowElapsed: Long): Long {
        val windowStart = nowElapsed - windowMs
        while (probes.isNotEmpty() && probes.first()[1] <= windowStart) probes.removeFirst()
        return probes.sumOf { (start, end) ->
            (minOf(end, nowElapsed) - maxOf(start, windowStart)).coerceAtLeast(0L)
        }
    }

    fun allows(nowElapsed: Long, durationMs: Long, maximumMs: Long): Boolean =
        usedMs(nowElapsed) + durationMs <= maximumMs

    fun record(startElapsed: Long, endElapsed: Long) {
        if (endElapsed > startElapsed) probes.addLast(longArrayOf(startElapsed, endElapsed))
    }
}

private operator fun LongArray.component1() = this[0]

private operator fun LongArray.component2() = this[1]
