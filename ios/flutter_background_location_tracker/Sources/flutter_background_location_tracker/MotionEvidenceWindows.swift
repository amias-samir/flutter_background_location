import Foundation

/// Turns cumulative pedometer counts into movement evidence.
///
/// `CMPedometer` reports the total since updates started, so "more than zero"
/// stays true for the rest of the session. Movement needs at least
/// `minimumSteps` within `window`, and is reported at most every
/// `emitInterval` while the cadence holds.
struct StepCadenceWindow {
  let minimumSteps: Int
  let window: TimeInterval
  let emitInterval: TimeInterval
  private var samples: [(time: TimeInterval, total: Int)]
  private var lastReportedAt: TimeInterval?

  init(
    startedAt: TimeInterval,
    minimumSteps: Int = 6,
    window: TimeInterval = 30,
    emitInterval: TimeInterval = 10
  ) {
    self.minimumSteps = minimumSteps
    self.window = window
    self.emitInterval = emitInterval
    samples = [(startedAt, 0)]
  }

  /// Records the cumulative step count; true when movement should be reported.
  mutating func observe(totalSteps: Int, at time: TimeInterval) -> Bool {
    samples.append((time, totalSteps))
    // Keep the newest sample at or before the window start as the baseline.
    let windowStart = time - window
    while samples.count > 2, samples[1].time <= windowStart {
      samples.removeFirst()
    }
    guard totalSteps - samples[0].total >= minimumSteps else { return false }
    if let last = lastReportedAt, time - last < emitInterval { return false }
    lastReportedAt = time
    return true
  }
}

/// Sensor-probe time used in the trailing `window`. A sliding window, so
/// probes on both sides of a fixed hour boundary cannot spend twice the budget.
struct RollingProbeBudget {
  let window: TimeInterval
  private var probes: [(start: TimeInterval, end: TimeInterval)] = []

  init(window: TimeInterval = 3_600) {
    self.window = window
  }

  mutating func used(at now: TimeInterval) -> TimeInterval {
    let windowStart = now - window
    probes.removeAll { $0.end <= windowStart }
    return probes.reduce(0) { total, probe in
      total + max(0, min(probe.end, now) - max(probe.start, windowStart))
    }
  }

  mutating func allows(at now: TimeInterval, duration: TimeInterval, maximum: TimeInterval) -> Bool {
    used(at: now) + duration <= maximum
  }

  mutating func record(start: TimeInterval, end: TimeInterval) {
    if end > start { probes.append((start, end)) }
  }
}
