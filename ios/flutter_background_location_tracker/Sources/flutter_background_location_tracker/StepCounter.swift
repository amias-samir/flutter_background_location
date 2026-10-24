import CoreMotion
import Foundation

/// One pedometer answer: the steps since the start date, through `endDate`.
struct StepCountReading {
  let steps: Int
  let endDate: Date
}

/// The pedometer calls `StepCounter` makes, so tests can supply their own.
/// Handlers may run on any queue.
protocol StepCountSource: AnyObject {
  func startUpdates(from start: Date, handler: @escaping (StepCountReading?) -> Void)
  func stopUpdates()
  func query(from start: Date, to end: Date, handler: @escaping (StepCountReading?) -> Void)
}

/// `CMPedometer` as a step-count source.
final class PedometerStepCountSource: StepCountSource {
  private let pedometer = CMPedometer()

  func startUpdates(from start: Date, handler: @escaping (StepCountReading?) -> Void) {
    pedometer.startUpdates(from: start) { data, _ in handler(data.map(Self.reading)) }
  }

  func stopUpdates() {
    pedometer.stopUpdates()
  }

  func query(from start: Date, to end: Date, handler: @escaping (StepCountReading?) -> Void) {
    pedometer.queryPedometerData(from: start, to: end) { data, _ in
      handler(data.map(Self.reading))
    }
  }

  private static func reading(_ data: CMPedometerData) -> StepCountReading {
    StepCountReading(steps: data.numberOfSteps.intValue, endDate: data.endDate)
  }
}

/// How completely a generation's steps are counted (`stepCoverage`).
///
/// `state` is `counting`; `suspect` while the fixes show walking and the
/// count does not rise; `unavailable` without the pedometer or Motion &
/// Fitness; or `ended_unflushed` for a checkpoint left by process death. The
/// pedometer counts from the generation's start, so no time is left
/// uncounted and nothing is re-registered: both stay 0.
struct StepCoverage: Equatable {
  static let counting = "counting"
  static let suspect = "suspect"
  static let unavailable = "unavailable"
  static let endedUnflushed = "ended_unflushed"
  static let pedometerSensor = "pedometer"

  var state: String
  /// Epoch ms of the newest reading accounted for.
  var countedThrough: Int64?
  /// Epoch ms of the newest reading that raised the count.
  var lastRiseAt: Int64?
  var sensor: String?

  init(
    state: String,
    countedThrough: Int64? = nil,
    lastRiseAt: Int64? = nil,
    sensor: String? = StepCoverage.pedometerSensor
  ) {
    self.state = state
    self.countedThrough = countedThrough
    self.lastRiseAt = lastRiseAt
    self.sensor = sensor
  }

  init?(propertyList: [String: Any]) {
    guard let state = propertyList["state"] as? String else { return nil }
    self.state = state
    countedThrough = (propertyList["countedThrough"] as? NSNumber)?.int64Value
    lastRiseAt = (propertyList["lastRiseAt"] as? NSNumber)?.int64Value
    sensor = propertyList["sensor"] as? String
  }

  /// The channel and journal map; unknown values are null.
  var map: [String: Any] {
    [
      "state": state,
      "countedThrough": countedThrough.map { $0 as Any } ?? NSNull(),
      "lastRiseAt": lastRiseAt.map { $0 as Any } ?? NSNull(),
      "uncountedMs": 0,
      "sensor": sensor.map { $0 as Any } ?? NSNull(),
      "reregistrations": 0,
    ]
  }

  /// UserDefaults holds no null, so unknown values are left out.
  var propertyList: [String: Any] {
    var values: [String: Any] = ["state": state]
    if let countedThrough { values["countedThrough"] = countedThrough }
    if let lastRiseAt { values["lastRiseAt"] = lastRiseAt }
    if let sensor { values["sensor"] = sensor }
    return values
  }
}

/// A generation's step count and coverage: a checkpoint while it captures,
/// its final count once it has ended (`stepFinal`).
struct StepCountRecord: Equatable {
  let captureGenerationId: String
  let stepCount: Int
  let coverage: StepCoverage

  init(captureGenerationId: String, stepCount: Int, coverage: StepCoverage) {
    self.captureGenerationId = captureGenerationId
    self.stepCount = stepCount
    self.coverage = coverage
  }

  init?(propertyList: [String: Any]?) {
    guard let propertyList,
      let generationId = propertyList["captureGenerationId"] as? String, !generationId.isEmpty,
      let steps = (propertyList["stepCount"] as? NSNumber)?.intValue, steps >= 0,
      let coverageValues = propertyList["stepCoverage"] as? [String: Any],
      let coverage = StepCoverage(propertyList: coverageValues)
    else {
      return nil
    }
    self.init(captureGenerationId: generationId, stepCount: steps, coverage: coverage)
  }

  var map: [String: Any] {
    [
      "captureGenerationId": captureGenerationId,
      "stepCount": stepCount,
      "stepCoverage": coverage.map,
    ]
  }

  var propertyList: [String: Any] {
    [
      "captureGenerationId": captureGenerationId,
      "stepCount": stepCount,
      "stepCoverage": coverage.propertyList,
    ]
  }

  /// The final record of a generation that ended without a flush, from the
  /// pedometer's answer for its whole span and the newest count known before
  /// it. A rise recovers a suspect count. Without an answer the known count
  /// stands; a checkpoint left by process death is marked `ended_unflushed`.
  static func closing(
    generationId: String,
    answer: StepCountReading?,
    known: StepCountRecord?,
    knownFromCheckpoint: Bool
  ) -> StepCountRecord? {
    guard let answer, answer.steps >= 0 else {
      guard let known, knownFromCheckpoint else { return known }
      var coverage = known.coverage
      coverage.state = StepCoverage.endedUnflushed
      return StepCountRecord(
        captureGenerationId: generationId,
        stepCount: known.stepCount,
        coverage: coverage
      )
    }
    let previous = known?.stepCount ?? 0
    let rose = answer.steps > previous
    let answeredThrough = StepCounter.epochMilliseconds(answer.endDate)
    return StepCountRecord(
      captureGenerationId: generationId,
      stepCount: max(answer.steps, previous),
      coverage: StepCoverage(
        state: !rose && known?.coverage.state == StepCoverage.suspect
          ? StepCoverage.suspect : StepCoverage.counting,
        countedThrough: max(answeredThrough, known?.coverage.countedThrough ?? answeredThrough),
        lastRiseAt: rose ? answeredThrough : known?.coverage.lastRiseAt
      )
    )
  }
}

/// Notices a pedometer that stops counting while the fixes show walking:
/// walking-pace Doppler for a minute and no rise for two (90 s plus the 30 s
/// report latency Android allows). The count turns suspect and the pedometer
/// is asked directly, at most once a minute; any rise recovers it. Steps
/// never decide motion, and a stalled span is never estimated.
struct StepStallWatch {
  static let walkingSpeedMetersPerSecond = 0.7...2.5
  static let maximumSpeedAccuracyMetersPerSecond = 0.5
  static let evidenceSpanMs = 60_000.0
  static let silenceMs = 120_000.0
  static let queryIntervalMs = 60_000.0
  /// Walking evidence further apart than this does not join one span.
  static let evidenceGapMs = 60_000.0

  private(set) var suspect = false
  private var lastRiseAtMs: Double
  private var walkingSinceMs: Double?
  private var lastWalkingAtMs: Double?
  private var lastQueryAtMs: Double?

  init(startedAtMs: Double) {
    lastRiseAtMs = startedAtMs
  }

  /// A precisely measured walking pace, unless a vehicle or bicycle explains it.
  static func isWalkingEvidence(speed: Double?, speedAccuracy: Double?, inVehicle: Bool) -> Bool {
    guard !inVehicle, let speed, let speedAccuracy, speed.isFinite, speedAccuracy.isFinite,
      speedAccuracy >= 0
    else {
      return false
    }
    return walkingSpeedMetersPerSecond.contains(speed)
      && speedAccuracy <= maximumSpeedAccuracyMetersPerSecond
  }

  /// Notes a provider fix; true when the pedometer should be asked now.
  mutating func observeFix(walking: Bool, atMs: Double) -> Bool {
    if let last = lastWalkingAtMs, atMs - last > Self.evidenceGapMs {
      walkingSinceMs = nil
    }
    guard walking else { return false }
    if walkingSinceMs == nil { walkingSinceMs = atMs }
    lastWalkingAtMs = atMs
    guard let since = walkingSinceMs,
      atMs - since >= Self.evidenceSpanMs,
      atMs - lastRiseAtMs >= Self.silenceMs
    else {
      return false
    }
    suspect = true
    if let lastQuery = lastQueryAtMs, atMs - lastQuery < Self.queryIntervalMs { return false }
    lastQueryAtMs = atMs
    return true
  }

  /// The count rose: whatever was suspect is recovered.
  mutating func observeRise(atMs: Double) {
    lastRiseAtMs = max(lastRiseAtMs, atMs)
    suspect = false
    walkingSinceMs = nil
  }
}

/// Steps of one capture generation: the pedometer's count since the
/// generation started. The count never goes back.
struct StepCountSession {
  let generationId: String
  let startedAt: Date
  /// Steps since [startedAt]; nil until the pedometer first reports.
  private(set) var steps: Int?
  /// End of the newest reading accounted for.
  private(set) var countedThrough: Date?
  /// End of the newest reading that raised the count.
  private(set) var lastRiseAt: Date?

  init(generationId: String, startedAt: Date) {
    self.generationId = generationId
    self.startedAt = startedAt
  }

  /// Accounts for a reading of [totalSteps] through [endDate]; true when it
  /// raised the count.
  @discardableResult
  mutating func observe(totalSteps: Int, through endDate: Date? = nil) -> Bool {
    guard totalSteps >= 0 else { return false }
    let rose = totalSteps > (steps ?? 0)
    steps = max(steps ?? 0, totalSteps)
    if let endDate {
      countedThrough = max(countedThrough ?? endDate, endDate)
      if rose { lastRiseAt = max(lastRiseAt ?? endDate, endDate) }
    }
    return rose
  }
}

/// Counts steps while capture is active, in every motion fusion mode.
///
/// `CMPedometer` reports the steps taken since a start date, so a count
/// started late in a generation, or again after a configuration update,
/// still counts from the generation's start, and a query answers for any
/// span of the last seven days. It needs a step-counting device and Motion &
/// Fitness authorized; it never asks for that permission, and without it
/// steps stay unmeasured. Called on the main thread.
final class StepCounter {
  static let flushTimeout: TimeInterval = 0.5
  static let maximumDiagnostics = 64

  private let source: StepCountSource
  private let permitted: () -> Bool
  private let clock: () -> Date
  private var session: StepCountSession?
  private var watch: StepStallWatch?
  /// Rotates with every session so a late reading of an earlier one is
  /// ignored.
  private var token = 0
  private var lastDeliveryAt: Date?
  private var lastRiseObservedAt: Date?
  /// Count-free health entries, newest last.
  private(set) var diagnostics: [[String: Any]] = []

  static var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

  static var isAuthorized: Bool {
    CMPedometer.authorizationStatus() == .authorized
      && Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil
  }

  init(
    source: StepCountSource = PedometerStepCountSource(),
    permitted: @escaping () -> Bool = { StepCounter.isAvailable && StepCounter.isAuthorized },
    clock: @escaping () -> Date = Date.init
  ) {
    self.source = source
    self.permitted = permitted
    self.clock = clock
  }

  /// Whether [generationId]'s steps are being counted.
  func isCounting(_ generationId: String?) -> Bool {
    generationId != nil && session?.generationId == generationId
  }

  /// Starts counting [generationId]'s steps from [startedAt]; its running
  /// count continues.
  func start(generationId: String, startedAt: Date) {
    guard !isCounting(generationId), permitted() else { return }
    stop()
    session = StepCountSession(generationId: generationId, startedAt: startedAt)
    watch = StepStallWatch(startedAtMs: Self.watchTime(clock()))
    lastDeliveryAt = nil
    lastRiseObservedAt = nil
    let current = token
    source.startUpdates(from: startedAt) { [weak self] reading in
      guard let reading else { return }
      DispatchQueue.main.async { self?.observeLive(reading, token: current) }
    }
    recordDiagnostic("start")
  }

  func stop() {
    guard session != nil else { return }
    recordDiagnostic("stop")
    token += 1
    session = nil
    watch = nil
    source.stopUpdates()
  }

  /// [generationId]'s steps; nil when they are not counted.
  func steps(for generationId: String?) -> Int? {
    isCounting(generationId) ? session?.steps : nil
  }

  /// [generationId]'s coverage; nil when its steps are not counted.
  func coverage(for generationId: String?) -> StepCoverage? {
    guard isCounting(generationId), let session else { return nil }
    return StepCoverage(
      state: watch?.suspect == true ? StepCoverage.suspect : StepCoverage.counting,
      countedThrough: session.countedThrough.map(Self.epochMilliseconds),
      lastRiseAt: session.lastRiseAt.map(Self.epochMilliseconds)
    )
  }

  /// [generationId]'s count with its coverage; nil when it is not counted
  /// or the pedometer has not answered yet.
  func record(for generationId: String?) -> StepCountRecord? {
    guard let generationId, let steps = steps(for: generationId),
      let coverage = coverage(for: generationId)
    else {
      return nil
    }
    return StepCountRecord(captureGenerationId: generationId, stepCount: steps, coverage: coverage)
  }

  /// Reads the count up to now, then calls [then] on the main thread: at
  /// once when nothing is counted, and after [flushTimeout] at the latest.
  func flush(then: @escaping () -> Void) {
    query(diagnostic: nil, then: then)
  }

  /// Reads the counted generation's final count before anything stops it,
  /// then calls [then] on the main thread with its record, nil when nothing
  /// is counted. Counting continues until [stop].
  func finalize(then: @escaping (StepCountRecord?) -> Void) {
    guard let generationId = session?.generationId else {
      then(nil)
      return
    }
    query(diagnostic: "finalize") { [weak self] in
      then(self?.record(for: generationId))
    }
  }

  /// Notes a provider fix: a walking pace while the count does not rise
  /// makes it suspect, and the pedometer is asked directly.
  func noteFix(speed: Double?, speedAccuracy: Double?, inVehicle: Bool) {
    guard session != nil, var watch = self.watch else { return }
    let wasSuspect = watch.suspect
    let shouldQuery = watch.observeFix(
      walking: StepStallWatch.isWalkingEvidence(
        speed: speed,
        speedAccuracy: speedAccuracy,
        inVehicle: inVehicle
      ),
      atMs: Self.watchTime(clock())
    )
    self.watch = watch
    if watch.suspect, !wasSuspect {
      recordDiagnostic("transition", evidenceSource: "doppler")
    }
    if shouldQuery { query(diagnostic: "flush") {} }
  }

  /// Asks the pedometer for the steps of a span that has ended, such as a
  /// generation closed without a final count. Calls [then] on the main
  /// thread with the answer: nil without permission, for an empty span, or
  /// after [timeout].
  func querySpan(
    from start: Date,
    to end: Date,
    timeout: TimeInterval,
    then: @escaping (StepCountReading?) -> Void
  ) {
    guard end > start, permitted() else {
      then(nil)
      return
    }
    var done = false
    let finish = { [weak self] (reading: StepCountReading?) in
      guard !done else { return }
      done = true
      self?.recordDiagnostic("closed_span", replayOutcome: reading == nil ? "none" : "answered")
      then(reading)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    source.query(from: start, to: end) { reading in
      DispatchQueue.main.async { finish(reading) }
    }
  }

  private func query(diagnostic: String?, then: @escaping () -> Void) {
    guard let startedAt = session?.startedAt else {
      then()
      return
    }
    let current = token
    let requestedAt = clock()
    var done = false
    let finish = { [weak self] (outcome: String?) in
      guard !done else { return }
      done = true
      if let self, let diagnostic {
        let elapsedMs =
          Self.epochMilliseconds(self.clock()) - Self.epochMilliseconds(requestedAt)
        // A query that timed out has neither a completion time nor an outcome.
        self.recordDiagnostic(
          diagnostic,
          flushCompletedMs: outcome == nil ? nil : elapsedMs,
          replayOutcome: outcome
        )
      }
      then()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushTimeout) { finish(nil) }
    source.query(from: startedAt, to: requestedAt) { [weak self] reading in
      DispatchQueue.main.async {
        // No answer, or one for a session that has stopped since.
        guard let reading, let self, current == self.token else {
          finish("none")
          return
        }
        finish(self.observe(reading, token: current) ? "rose" : "same")
      }
    }
  }

  private func observeLive(_ reading: StepCountReading, token: Int) {
    guard token == self.token else { return }
    lastDeliveryAt = clock()
    observe(reading, token: token)
  }

  /// Accounts for [reading]; a rise recovers a suspect count.
  @discardableResult
  private func observe(_ reading: StepCountReading, token: Int) -> Bool {
    guard token == self.token, session != nil else { return false }
    guard session?.observe(totalSteps: reading.steps, through: reading.endDate) == true else {
      return false
    }
    let now = clock()
    lastRiseObservedAt = now
    let wasSuspect = watch?.suspect == true
    watch?.observeRise(atMs: Self.watchTime(now))
    if wasSuspect { recordDiagnostic("transition") }
    return true
  }

  private func recordDiagnostic(
    _ event: String,
    flushCompletedMs: Int64? = nil,
    replayOutcome: String? = nil,
    evidenceSource: String? = nil
  ) {
    let now = Self.epochMilliseconds(clock())
    let state: String
    if session == nil {
      state = StepCoverage.unavailable
    } else {
      state = watch?.suspect == true ? StepCoverage.suspect : StepCoverage.counting
    }
    diagnostics.append([
      "at": now,
      "event": event,
      "sensor": StepCoverage.pedometerSensor,
      "registered": session != nil,
      "watchdogState": state,
      "sinceDeliveryMs": Self.nullable(lastDeliveryAt.map { now - Self.epochMilliseconds($0) }),
      "sinceRiseMs": Self.nullable(lastRiseObservedAt.map { now - Self.epochMilliseconds($0) }),
      "flushCompletedMs": Self.nullable(flushCompletedMs),
      "replayOutcome": Self.nullable(replayOutcome),
      "evidenceSource": Self.nullable(evidenceSource),
      "reregistrations": 0,
    ])
    if diagnostics.count > Self.maximumDiagnostics {
      diagnostics.removeFirst(diagnostics.count - Self.maximumDiagnostics)
    }
  }

  private static func nullable(_ value: Any?) -> Any {
    value ?? NSNull()
  }

  static func epochMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  private static func watchTime(_ date: Date) -> Double {
    (date.timeIntervalSince1970 * 1_000).rounded()
  }
}
