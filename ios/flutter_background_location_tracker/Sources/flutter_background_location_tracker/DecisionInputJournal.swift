import Foundation

/// The decision inputs a journaled fix carries, so Dart decides from what the
/// journal kept instead of from live channel events: the activity readings
/// received since the previous journaled fix, the moving and stationary
/// profile switches in between, and the profile in effect when the fix was
/// captured.
///
/// Readings and switches share one arrival number (`seq`, from 1) per capture
/// generation, so their order survives. A fix takes the inputs that arrived
/// before its capture was marked; a switch its own evaluation causes goes
/// with the next journaled fix.
///
/// Reading compaction is shared with the Kotlin `DecisionInputJournal`
/// through `test/fixtures/cross_language/activity_reading_compaction_v1.json`.
/// Pure Swift, confined to the main queue.
struct DecisionInputJournal {
  /// Where a fix was captured in the arrival order, and under which profile.
  struct Mark {
    let seq: Int
    let trackingProfile: String
  }

  private struct RunKey: Equatable {
    let type: String
    let confidenceBucket: Int
  }

  static let maximumReadings = 64
  static let maximumReadingBytes = 16 * 1_024
  static let maximumTransitions = 8
  /// Transition readings and Core Motion's change-only readings are always
  /// kept and end a run; other readings are compacted in runs.
  static let alwaysKeptSources: Set<String> = [
    "android_activity_transition",
    "ios_core_motion_activity",
  ]

  private var nextSeq = 1
  /// Compacted readings not yet journaled, oldest first.
  private var readings: [[String: Any]] = []
  /// Readings in the run that ends `readings`; a run keeps its first and
  /// last, so it occupies at most two entries. 0 when no run is open.
  private var runLength = 0
  private var runKey: RunKey?
  private var droppedReadings = 0
  private var transitions: [[String: Any]] = []

  /// Starts a new capture generation: its arrival numbers start at 1.
  mutating func reset() {
    self = DecisionInputJournal()
  }

  /// Keeps an activity reading as it was emitted, numbered in arrival order.
  mutating func recordReading(_ event: [String: Any]) {
    var reading = event
    reading["seq"] = nextSeq
    nextSeq += 1
    if Self.alwaysKeptSources.contains(event["source"] as? String ?? "") {
      readings.append(reading)
      runLength = 0
      runKey = nil
    } else {
      let key = RunKey(
        type: event["type"] as? String ?? "unknown",
        confidenceBucket: Self.confidenceBucket(event["confidence"])
      )
      if runLength > 0, key == runKey {
        // The newest reading of a run replaces the run's previous last one.
        if runLength >= 2 {
          readings[readings.count - 1] = reading
        } else {
          readings.append(reading)
        }
        runLength += 1
      } else {
        readings.append(reading)
        runLength = 1
        runKey = key
      }
    }
    if readings.count > Self.maximumReadings {
      let excess = readings.count - Self.maximumReadings
      readings.removeFirst(excess)
      droppedReadings += excess
    }
  }

  /// Keeps a moving/stationary profile switch, numbered in arrival order.
  mutating func recordTransition(atMs: Int64, from: String, to: String, reason: String?) {
    var transition: [String: Any] = [
      "seq": nextSeq,
      "at": atMs,
      "from": from,
      "to": to,
    ]
    if let reason { transition["reason"] = reason }
    nextSeq += 1
    transitions.append(transition)
    // Only the newest are journaled; the margin keeps those that arrive
    // between a fix's mark and its journaling.
    let limit = 2 * Self.maximumTransitions
    if transitions.count > limit { transitions.removeFirst(transitions.count - limit) }
  }

  /// Marks a fix captured now under `trackingProfile`, before evaluating it
  /// can switch the profile.
  func mark(trackingProfile: String) -> Mark {
    Mark(seq: nextSeq, trackingProfile: trackingProfile)
  }

  /// The keys a journaled fix gains: its capture-time profile stamp, the
  /// readings and switches that arrived before `mark`, and how many readings
  /// the caps removed (only when some were). Later inputs wait for the next
  /// journaled fix.
  mutating func take(_ mark: Mark) -> [String: Any] {
    let readingSplit = readings.firstIndex { Self.seq(of: $0) >= mark.seq } ?? readings.count
    var taken = Array(readings[..<readingSplit])
    readings.removeFirst(readingSplit)
    // A run never spans two fixes: what remains of it starts over.
    if readings.count < min(runLength, 2) {
      runLength = readings.count
      if runLength == 0 { runKey = nil }
    }
    var dropped = droppedReadings
    droppedReadings = 0

    // Readings that can't be journaled would fail the whole fix.
    let encodable = taken.filter { JSONSerialization.isValidJSONObject($0) }
    dropped += taken.count - encodable.count
    taken = encodable
    var sizes = taken.map { Self.encodedSize($0) }
    var bytes = sizes.reduce(2, +) + max(0, taken.count - 1)
    while !taken.isEmpty, bytes > Self.maximumReadingBytes {
      bytes -= sizes.removeFirst() + (taken.count > 1 ? 1 : 0)
      taken.removeFirst()
      dropped += 1
    }

    let transitionSplit =
      transitions.firstIndex { Self.seq(of: $0) >= mark.seq } ?? transitions.count
    let takenTransitions = Array(transitions[..<transitionSplit].suffix(Self.maximumTransitions))
    transitions.removeFirst(transitionSplit)

    var inputs = Self.profileStamp(mark.trackingProfile)
    inputs["activityReadings"] = taken
    inputs["profileTransitions"] = takenTransitions
    if dropped > 0 { inputs["activityReadingsDropped"] = dropped }
    return inputs
  }

  /// The keys that stamp a fix with the profile it was captured under.
  static func profileStamp(_ trackingProfile: String) -> [String: Any] {
    let sampling = trackingProfile == "stationary" ? "stationary" : "moving"
    return [
      "trackingProfile": trackingProfile,
      "samplingProfile": sampling,
      "batteryMode": sampling,
      "motionState": sampling,
    ]
  }

  /// Below 60, 60 to 74, and 75 and above.
  static func confidenceBucket(_ value: Any?) -> Int {
    let confidence = (value as? NSNumber)?.doubleValue ?? 0
    if confidence < 60 { return 0 }
    return confidence < 75 ? 1 : 2
  }

  private static func seq(of input: [String: Any]) -> Int {
    (input["seq"] as? NSNumber)?.intValue ?? 0
  }

  private static func encodedSize(_ reading: [String: Any]) -> Int {
    (try? JSONSerialization.data(withJSONObject: reading).count) ?? 0
  }
}
