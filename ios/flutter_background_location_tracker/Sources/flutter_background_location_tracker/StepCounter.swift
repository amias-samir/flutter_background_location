import CoreMotion
import Foundation

/// Steps of one capture generation: the pedometer's count since the
/// generation started. The count never goes back.
struct StepCountSession {
  let generationId: String
  let startedAt: Date
  /// Steps since [startedAt]; nil until the pedometer first reports.
  private(set) var steps: Int?

  init(generationId: String, startedAt: Date) {
    self.generationId = generationId
    self.startedAt = startedAt
  }

  mutating func observe(totalSteps: Int) {
    guard totalSteps >= 0 else { return }
    steps = max(steps ?? 0, totalSteps)
  }
}

/// Counts steps while capture is active, in every motion fusion mode.
///
/// `CMPedometer` reports the steps taken since a start date, so a count
/// started late in a generation, or again after a configuration update,
/// still counts from the generation's start. It needs a step-counting device
/// and Motion & Fitness authorized; it never asks for that permission, and
/// without it steps stay unmeasured. Called on the main thread.
final class StepCounter {
  static let flushTimeout: TimeInterval = 0.5

  private let pedometer = CMPedometer()
  private var session: StepCountSession?
  /// Rotates with every session so a late reading of an earlier one is
  /// ignored.
  private var token = 0

  static var isAvailable: Bool { CMPedometer.isStepCountingAvailable() }

  static var isAuthorized: Bool {
    CMPedometer.authorizationStatus() == .authorized
      && Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil
  }

  /// Whether [generationId]'s steps are being counted.
  func isCounting(_ generationId: String?) -> Bool {
    generationId != nil && session?.generationId == generationId
  }

  /// Starts counting [generationId]'s steps from [startedAt]; its running
  /// count continues.
  func start(generationId: String, startedAt: Date) {
    guard !isCounting(generationId), Self.isAvailable, Self.isAuthorized else { return }
    stop()
    session = StepCountSession(generationId: generationId, startedAt: startedAt)
    let current = token
    pedometer.startUpdates(from: startedAt) { [weak self] data, _ in
      guard let total = data?.numberOfSteps.intValue else { return }
      DispatchQueue.main.async { self?.observe(total, token: current) }
    }
  }

  func stop() {
    guard session != nil else { return }
    token += 1
    session = nil
    pedometer.stopUpdates()
  }

  /// [generationId]'s steps; nil when they are not counted.
  func steps(for generationId: String?) -> Int? {
    isCounting(generationId) ? session?.steps : nil
  }

  /// Reads the count up to now, then calls [then] on the main thread: at
  /// once when nothing is counted, and after [flushTimeout] at the latest.
  func flush(then: @escaping () -> Void) {
    guard let startedAt = session?.startedAt else {
      then()
      return
    }
    let current = token
    var done = false
    let finish = {
      guard !done else { return }
      done = true
      then()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushTimeout, execute: finish)
    pedometer.queryPedometerData(from: startedAt, to: Date()) { [weak self] data, _ in
      DispatchQueue.main.async {
        if let total = data?.numberOfSteps.intValue {
          self?.observe(total, token: current)
        }
        finish()
      }
    }
  }

  private func observe(_ total: Int, token: Int) {
    guard token == self.token else { return }
    session?.observe(totalSteps: total)
  }
}
