import Foundation

/// Chooses the fixes a moving profile records: one per interval, and one
/// wherever the course has turned sharply since the last recorded fix, so a
/// junction or hairpin is not cut between fixes tens of metres apart.
///
/// Shared with the Kotlin `TurnCaptureSampler` through
/// `test/fixtures/cross_language/turn_capture_v1.json`.
struct TurnCaptureSampler {
  struct Fix {
    let elapsedMs: Double
    let latitude: Double
    let longitude: Double
    let speedMetersPerSecond: Double?
    let bearingDegrees: Double?
    let bearingAccuracyDegrees: Double?
  }

  /// Slower fixes have no course worth a turn: walking turns are left to the
  /// interval.
  static let minimumSpeedMetersPerSecond = 3.0
  /// A course reported less precisely than this is not trusted for turns.
  static let maximumBearingAccuracyDegrees = 30.0
  /// Provider timestamps jitter; a fix this early still meets the interval.
  static let intervalToleranceMs = 500.0

  let intervalMs: Double
  let turnDegrees: Double
  let minimumDistanceMeters: Double

  private var lastRecorded: Fix?
  /// Course of the newest recorded fix that had a reliable one.
  private var referenceCourse: Double?

  init(intervalMs: Double, turnDegrees: Double, minimumDistanceMeters: Double) {
    self.intervalMs = intervalMs
    self.turnDegrees = turnDegrees
    self.minimumDistanceMeters = minimumDistanceMeters
  }

  /// Whether to record `fix`; a recorded fix becomes the reference.
  mutating func accept(_ fix: Fix) -> Bool {
    let recorded = shouldRecord(fix)
    if recorded { record(fix) }
    return recorded
  }

  /// Whether `fix` meets the interval or turns, without recording it.
  func shouldRecord(_ fix: Fix) -> Bool {
    guard let previous = lastRecorded else { return true }
    return fix.elapsedMs - previous.elapsedMs >= intervalMs - Self.intervalToleranceMs
      || isTurn(fix, previous: previous)
  }

  /// Takes `fix`, recorded for another reason, as the reference.
  mutating func record(_ fix: Fix) {
    lastRecorded = fix
    if let course = Self.reliableCourse(fix) { referenceCourse = course }
  }

  private func isTurn(_ fix: Fix, previous: Fix) -> Bool {
    guard fix.elapsedMs > previous.elapsedMs,
      let course = Self.reliableCourse(fix),
      let reference = referenceCourse,
      Self.distanceMeters(previous, fix) >= minimumDistanceMeters
    else {
      return false
    }
    return Self.angleBetween(course, reference) >= turnDegrees
  }

  static func reliableCourse(_ fix: Fix) -> Double? {
    guard let speed = fix.speedMetersPerSecond, speed.isFinite,
      speed >= minimumSpeedMetersPerSecond,
      let bearing = fix.bearingDegrees, bearing.isFinite
    else {
      return nil
    }
    if let accuracy = fix.bearingAccuracyDegrees,
      !accuracy.isFinite || accuracy > maximumBearingAccuracyDegrees
    {
      return nil
    }
    return bearing
  }

  /// Smallest angle between two courses, in degrees.
  static func angleBetween(_ first: Double, _ second: Double) -> Double {
    let difference = (first - second).truncatingRemainder(dividingBy: 360)
    return abs((difference + 540).truncatingRemainder(dividingBy: 360) - 180)
  }

  static func distanceMeters(_ from: Fix, _ to: Fix) -> Double {
    let phi1 = from.latitude * .pi / 180
    let phi2 = to.latitude * .pi / 180
    let deltaPhi = phi2 - phi1
    let deltaLambda = (to.longitude - from.longitude) * .pi / 180
    let h =
      sin(deltaPhi / 2) * sin(deltaPhi / 2)
      + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
    return 2 * 6_371_008.8 * asin(min(1, sqrt(h)))
  }
}
