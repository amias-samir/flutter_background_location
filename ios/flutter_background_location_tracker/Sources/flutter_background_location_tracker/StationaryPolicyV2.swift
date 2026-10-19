import Foundation

/// Motion policy 2 for adaptive capture: when the moving request may relax to
/// the stationary profile, and when it must return.
///
/// Mirrors Dart `MotionPolicyV2` and `MotionGate` and Kotlin
/// `StationaryPolicyV2`; the shared fixture `motion_policy_v2.json` keeps the
/// three in step. Pure Swift, confined to the main queue.
///
/// A still episode starts with confident still evidence and survives unknown
/// and low-confidence readings and silence: Core Motion reports only changes,
/// and a still phone may produce no fix under the distance filter. It ends on
/// positive moving evidence, a clearly measured Doppler speed, or sustained
/// displacement, so one optimistic indoor fix can't end a stop.
struct StationaryPolicyV2 {
  enum Profile: Equatable { case moving, stationary }

  /// One activity reading; `type` uses the native activity names.
  struct Reading {
    let type: String
    let confidence: Int
    let recordedAtMs: Double
    let source: String
  }

  /// One provider fix.
  struct Fix {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let speed: Double?
    let speedAccuracy: Double?
    let hasVerticalAccuracy: Bool
    let mocked: Bool
    let observedAtMs: Double
  }

  private struct Evidence {
    let latitude: Double
    let longitude: Double
    let sigmaMeters: Double
    let observedAtMs: Double
  }

  static let motionPolicyVersion = 2
  static let transitionSource = "android_activity_transition"
  static let coreMotionSource = "ios_core_motion_activity"
  static let stationaryType = "stationary"
  static let automotiveType = "automotive"
  static let movingTypes: Set<String> = ["walking", "running", "cycling", automotiveType]

  static let stillEpisodeMinimumSpanMs = 30_000.0
  static let movingConfirmationReadings = 2
  static let vehicleConfidenceThreshold = 75
  static let coreMotionHighConfidence = 100
  static let coreMotionMediumPersistenceMs = 10_000.0
  static let holdRadiusFloorMeters = 25.0
  static let holdChiSquare = 9.21
  static let departureSpeedMetersPerSecond = 1.2
  static let departureSpeedAccuracyFactor = 2.0
  static let sustainedOutsideMs = 60_000.0
  static let sustainedOutsideRadiusFactor = 2.0
  static let entryConsistencyFloorMeters = 25.0
  static let entryConsistencySigmaFactor = 3.0
  static let entryWithoutFixesMs = 180_000.0

  // Coordinate-free reasons for a profile change, reported in status.
  static let reasonStillEpisode = "still_episode"
  static let reasonEntryWithoutFixes = "entry_without_fixes"
  static let reasonMovingReadings = "moving_readings"
  static let reasonMovingTransition = "moving_transition"
  static let reasonTransitionExit = "transition_exit"
  static let reasonMovingEvidence = "moving_evidence"
  static let reasonDoppler = "doppler"
  static let reasonSustainedDisplacement = "sustained_displacement"
  static let reasonActivityUnavailable = "activity_unavailable"
  static let entryMaximumAccuracyMeters = 50.0

  // Uncertainty model v1, mirrored from Dart `UncertaintyModel`.
  private static let minimumSigmaMeters = 1.5
  private static let radiusPerSigma = 1.51
  private static let maximumGnssAccuracyMeters = 25.0
  private static let earthRadiusMeters = 6_371_008.8

  let stationaryConfidenceThreshold: Int
  let movingConfidenceThreshold: Int
  let movingConfirmationCount: Int
  let confirmationMs: Double
  let maximumAcceptedAccuracyMeters: Double

  private(set) var profile: Profile = .moving

  /// Whether a still episode is current.
  var stillEpisodeActive: Bool { episodeStartedAtMs != nil }

  /// Whether a time-based rule is pending, so the owner keeps evaluating.
  var needsEvaluation: Bool {
    mediumMovingSinceMs != nil || (profile == .moving && candidateSinceMs != nil)
  }

  private var candidateSinceMs: Double?
  private var episodeStartedAtMs: Double?
  private var endedAtMs: Double?
  private var mediumMovingSinceMs: Double?
  private var movingRun = 0
  private var lastReadingAt: [String: Double] = [:]
  private var window: [Evidence] = []
  private var lastEvidence: Evidence?
  private var anchor: Evidence?

  /// Why `profile` last changed, one of the `reason` codes.
  private(set) var lastTransitionReason: String?

  // After an entry without fixes: the first fix after the silence, waiting
  // for a second one that agrees before it can anchor the stop.
  private var pendingAnchor: Evidence?
  private var outsideSinceMs: Double?
  private var outsideFarthestMeters = 0.0

  init(
    stationaryConfidenceThreshold: Int,
    movingConfidenceThreshold: Int,
    movingConfirmationCount: Int,
    confirmationMs: Double,
    maximumAcceptedAccuracyMeters: Double
  ) {
    self.stationaryConfidenceThreshold = stationaryConfidenceThreshold
    self.movingConfidenceThreshold = movingConfidenceThreshold
    self.movingConfirmationCount = movingConfirmationCount
    self.confirmationMs = confirmationMs
    self.maximumAcceptedAccuracyMeters = maximumAcceptedAccuracyMeters
  }

  mutating func onReading(_ reading: Reading, nowMs: Double) -> Profile {
    if let previous = lastReadingAt[reading.source], reading.recordedAtMs <= previous {
      return evaluate(nowMs: nowMs)
    }
    lastReadingAt[reading.source] = reading.recordedAtMs
    // Readings older than the last departure must not reopen the stop.
    if let ended = endedAtMs, reading.recordedAtMs <= ended {
      return evaluate(nowMs: nowMs)
    }

    if reading.source == Self.transitionSource {
      if reading.type == Self.stationaryType && reading.confidence <= 0 {
        return endEpisode(atMs: reading.recordedAtMs, reason: Self.reasonTransitionExit)
      }
      if Self.movingTypes.contains(reading.type) && reading.confidence >= 100 {
        return endEpisode(atMs: reading.recordedAtMs, reason: Self.reasonMovingTransition)
      }
      if reading.type == Self.stationaryType && reading.confidence >= 100 {
        movingRun = 0
        mediumMovingSinceMs = nil
        let since = candidateSinceMs ?? reading.recordedAtMs
        candidateSinceMs = since
        if episodeStartedAtMs == nil { episodeStartedAtMs = since }
      }
      // EXIT transitions of moving activities are not still evidence.
      return evaluate(nowMs: nowMs)
    }

    if isMovingReading(reading) {
      if reading.source == Self.coreMotionSource {
        // Core Motion reports changes only: high confidence ends the episode,
        // medium confidence must stay current for a short time.
        if reading.confidence >= Self.coreMotionHighConfidence {
          return endEpisode(atMs: reading.recordedAtMs, reason: Self.reasonMovingReadings)
        }
        if mediumMovingSinceMs == nil { mediumMovingSinceMs = reading.recordedAtMs }
        return evaluate(nowMs: nowMs)
      }
      movingRun += 1
      if movingRun >= max(movingConfirmationCount, Self.movingConfirmationReadings) {
        return endEpisode(atMs: reading.recordedAtMs, reason: Self.reasonMovingReadings)
      }
      return evaluate(nowMs: nowMs)
    }

    // Any other reading interrupts a run of moving readings; unknown and
    // low-confidence readings are otherwise neutral.
    movingRun = 0
    mediumMovingSinceMs = nil
    if reading.type == Self.stationaryType
      && reading.confidence >= stationaryConfidenceThreshold
      && candidateSinceMs == nil
    {
      candidateSinceMs = reading.recordedAtMs
    }
    return evaluate(nowMs: nowMs)
  }

  /// Fused sensor evidence of movement, such as a step cadence.
  mutating func onMovingEvidence(nowMs: Double) -> Profile {
    endEpisode(atMs: nowMs, reason: Self.reasonMovingEvidence)
  }

  /// The activity source or its permission failed; fail open to moving.
  mutating func onActivityUnavailable(nowMs: Double) -> Profile {
    endEpisode(atMs: nowMs, reason: Self.reasonActivityUnavailable)
  }

  mutating func onFix(_ fix: Fix) -> Profile {
    let evidence = evidenceOf(fix)
    if let evidence { lastEvidence = evidence }
    if profile == .stationary {
      guard let evidence else { return profile }
      if let reference = anchor {
        checkDeparture(reference: reference, evidence: evidence, fix: fix)
      } else if Self.dopplerConfirmsDeparture(speed: fix.speed, speedAccuracy: fix.speedAccuracy) {
        // Without an anchor only a measured speed can end the stop.
        _ = endEpisode(atMs: fix.observedAtMs, reason: Self.reasonDoppler)
      } else {
        anchorFrom(evidence)
      }
      return profile
    }
    if let evidence { window.append(evidence) }
    return evaluate(nowMs: fix.observedAtMs)
  }

  /// Advances time-based rules: medium Core Motion persistence, episode
  /// promotion and stationary entry.
  mutating func evaluate(nowMs: Double) -> Profile {
    if let mediumSince = mediumMovingSinceMs,
      nowMs - mediumSince >= Self.coreMotionMediumPersistenceMs
    {
      return endEpisode(atMs: nowMs, reason: Self.reasonMovingReadings)
    }
    window.removeAll { nowMs - $0.observedAtMs > confirmationMs }
    guard let candidate = candidateSinceMs else { return profile }
    if episodeStartedAtMs == nil && nowMs - candidate >= Self.stillEpisodeMinimumSpanMs {
      episodeStartedAtMs = candidate
    }
    guard profile == .moving, episodeStartedAtMs != nil, nowMs - candidate >= confirmationMs
    else {
      return profile
    }
    let recent = window.filter { $0.observedAtMs >= candidate }
    if recent.isEmpty {
      // A still phone under the moving distance filter may deliver no fix at
      // all; the absence of movement is the evidence.
      if nowMs - candidate >= Self.entryWithoutFixesMs {
        let reference = lastEvidence.flatMap { $0.observedAtMs >= candidate ? $0 : nil }
        enterStationary(reference, reason: Self.reasonEntryWithoutFixes)
      }
    } else {
      let centre = Self.centroid(recent)
      let consistent = recent.allSatisfy { fix in
        Self.distanceMeters(centre, fix)
          <= max(
            Self.entryConsistencyFloorMeters,
            Self.entryConsistencySigmaFactor * fix.sigmaMeters
          )
      }
      if consistent { enterStationary(centre, reason: Self.reasonStillEpisode) }
    }
    return profile
  }

  private mutating func checkDeparture(reference: Evidence, evidence: Evidence, fix: Fix) {
    let distance = Self.distanceMeters(reference, evidence)
    let radius = Self.holdRadiusMeters(
      anchorSigmaMeters: reference.sigmaMeters,
      fixSigmaMeters: evidence.sigmaMeters
    )
    if distance <= radius {
      outsideSinceMs = nil
      outsideFarthestMeters = 0
      return
    }
    if Self.dopplerConfirmsDeparture(speed: fix.speed, speedAccuracy: fix.speedAccuracy) {
      _ = endEpisode(atMs: fix.observedAtMs, reason: Self.reasonDoppler)
      return
    }
    let since = outsideSinceMs ?? fix.observedAtMs
    outsideSinceMs = since
    let sustained = fix.observedAtMs - since >= Self.sustainedOutsideMs
      && distance >= outsideFarthestMeters
      && distance >= Self.sustainedOutsideRadiusFactor * radius
    outsideFarthestMeters = max(outsideFarthestMeters, distance)
    if sustained {
      _ = endEpisode(atMs: fix.observedAtMs, reason: Self.reasonSustainedDisplacement)
    }
  }

  /// Anchors a stop entered without fixes. The first fix after a long silence
  /// is often a re-acquisition outlier tens of metres off, so two fixes must
  /// agree within the hold radius; a lone disagreeing fix is replaced.
  private mutating func anchorFrom(_ evidence: Evidence) {
    if let pending = pendingAnchor,
      Self.distanceMeters(pending, evidence)
        <= Self.holdRadiusMeters(
          anchorSigmaMeters: pending.sigmaMeters,
          fixSigmaMeters: evidence.sigmaMeters
        )
    {
      anchor = Self.centroid([pending, evidence])
      pendingAnchor = nil
    } else {
      pendingAnchor = evidence
    }
  }

  private mutating func enterStationary(_ reference: Evidence?, reason: String) {
    profile = .stationary
    lastTransitionReason = reason
    anchor = reference
    pendingAnchor = nil
    outsideSinceMs = nil
    outsideFarthestMeters = 0
  }

  private mutating func endEpisode(atMs: Double, reason: String) -> Profile {
    if profile == .stationary { lastTransitionReason = reason }
    episodeStartedAtMs = nil
    candidateSinceMs = nil
    mediumMovingSinceMs = nil
    movingRun = 0
    endedAtMs = atMs
    window.removeAll()
    anchor = nil
    pendingAnchor = nil
    outsideSinceMs = nil
    outsideFarthestMeters = 0
    profile = .moving
    return profile
  }

  private func isMovingReading(_ reading: Reading) -> Bool {
    guard Self.movingTypes.contains(reading.type) else { return false }
    let threshold =
      reading.type == Self.automotiveType
      ? max(movingConfidenceThreshold, Self.vehicleConfidenceThreshold)
      : movingConfidenceThreshold
    return reading.confidence >= threshold
  }

  private func evidenceOf(_ fix: Fix) -> Evidence? {
    guard let accuracy = fix.accuracyMeters, !fix.mocked, accuracy.isFinite, accuracy > 0,
      accuracy <= max(maximumAcceptedAccuracyMeters, Self.entryMaximumAccuracyMeters)
    else {
      return nil
    }
    return Evidence(
      latitude: fix.latitude,
      longitude: fix.longitude,
      sigmaMeters: Self.sigmaMeters(
        accuracyMeters: accuracy,
        hasSpeedAccuracy: fix.speedAccuracy != nil,
        hasVerticalAccuracy: fix.hasVerticalAccuracy
      ),
      observedAtMs: fix.observedAtMs
    )
  }

  static func sigmaMeters(
    accuracyMeters: Double,
    hasSpeedAccuracy: Bool,
    hasVerticalAccuracy: Bool
  ) -> Double {
    let originFactor: Double
    if hasSpeedAccuracy && hasVerticalAccuracy && accuracyMeters <= maximumGnssAccuracyMeters {
      originFactor = 1.0
    } else if !hasSpeedAccuracy && !hasVerticalAccuracy {
      originFactor = 1.8
    } else {
      originFactor = 1.2
    }
    return max(minimumSigmaMeters, accuracyMeters / radiusPerSigma) * originFactor
  }

  static func holdRadiusMeters(anchorSigmaMeters: Double, fixSigmaMeters: Double) -> Double {
    max(
      holdRadiusFloorMeters,
      (holdChiSquare
        * (anchorSigmaMeters * anchorSigmaMeters + fixSigmaMeters * fixSigmaMeters))
        .squareRoot()
    )
  }

  static func dopplerConfirmsDeparture(speed: Double?, speedAccuracy: Double?) -> Bool {
    guard let speed, let speedAccuracy, speed.isFinite, speedAccuracy.isFinite,
      speedAccuracy >= 0
    else {
      return false
    }
    return speed
      >= max(departureSpeedMetersPerSecond, departureSpeedAccuracyFactor * speedAccuracy)
  }

  private static func centroid(_ fixes: [Evidence]) -> Evidence {
    Evidence(
      latitude: median(fixes.map(\.latitude)),
      longitude: median(fixes.map(\.longitude)),
      sigmaMeters: median(fixes.map(\.sigmaMeters)),
      observedAtMs: fixes.map(\.observedAtMs).max() ?? 0
    )
  }

  private static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  }

  private static func distanceMeters(_ from: Evidence, _ to: Evidence) -> Double {
    let phi1 = from.latitude * .pi / 180
    let phi2 = to.latitude * .pi / 180
    let deltaPhi = phi2 - phi1
    let deltaLambda = (to.longitude - from.longitude) * .pi / 180
    let h = sin(deltaPhi / 2) * sin(deltaPhi / 2)
      + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
    return 2 * earthRadiusMeters * asin(min(1, h.squareRoot()))
  }
}
