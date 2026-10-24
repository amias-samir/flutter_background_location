import XCTest

@testable import flutter_background_location_tracker

/// Replays the turn-capture and sampling fixtures shared with Kotlin.
final class TurnCaptureSamplerTests: XCTestCase {
  private func loadFixture(_ name: String) throws -> [String: Any] {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(
      bundle.url(forResource: name, withExtension: "json"),
      "\(name).json is missing from the RunnerTests bundle"
    )
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
  }

  private func fix(_ values: [String: Any]) -> TurnCaptureSampler.Fix {
    TurnCaptureSampler.Fix(
      elapsedMs: (values["t"] as? Double ?? 0) * 1_000,
      latitude: values["latitude"] as? Double ?? 0,
      longitude: values["longitude"] as? Double ?? 0,
      speedMetersPerSecond: values["speed"] as? Double,
      bearingDegrees: values["bearing"] as? Double,
      bearingAccuracyDegrees: values["bearingAccuracy"] as? Double
    )
  }

  /// The shared configuration, overridden by the scenario's own.
  private func sampler(
    _ shared: [String: Any],
    _ scenario: [String: Any]
  ) -> TurnCaptureSampler {
    let config = shared.merging(scenario["config"] as? [String: Any] ?? [:]) { _, own in own }
    return TurnCaptureSampler(
      intervalMs: config["intervalMs"] as? Double ?? 5_000,
      turnDegrees: config["turnDegrees"] as? Double ?? 45,
      minimumDistanceMeters: config["minimumDistanceMeters"] as? Double ?? 5
    )
  }

  private func replay(_ name: String, minimumScenarios: Int) throws {
    let fixture = try loadFixture(name)
    let config = try XCTUnwrap(fixture["config"] as? [String: Any])
    let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(scenarios.count, minimumScenarios)
    for scenario in scenarios {
      var sampler = sampler(config, scenario)
      var recorded: [Int] = []
      for (index, values) in (scenario["fixes"] as? [[String: Any]] ?? []).enumerated() {
        if sampler.accept(fix(values)) { recorded.append(index) }
      }
      XCTAssertEqual(
        recorded,
        scenario["recorded"] as? [Int] ?? [],
        "\(name): \(scenario["name"] as? String ?? "?")"
      )
    }
  }

  func testReplaysEveryScenario() throws {
    try replay("turn_capture_v1", minimumScenarios: 8)
  }

  func testReplaysEverySamplingPolicy2Scenario() throws {
    try replay("turn_capture_v2", minimumScenarios: 11)
  }

  /// Sampling policy 2's moving profile emits exactly what the sampler
  /// records, from an unfiltered stream.
  func testTheMovingProfileEmitsExactlyWhatTheSamplerRecords() throws {
    let fixture = try loadFixture("turn_capture_v2")
    let config = try XCTUnwrap(fixture["config"] as? [String: Any])
    for scenario in try XCTUnwrap(fixture["scenarios"] as? [[String: Any]]) {
      var sampler = sampler(config, scenario)
      var previous: TurnCaptureSampler.Fix?
      var emitted: [Int] = []
      for (index, values) in (scenario["fixes"] as? [[String: Any]] ?? []).enumerated() {
        let candidate = fix(values)
        let emit =
          previous.map { last in
            FixEmissionRule.shouldEmit(
              candidate,
              elapsedMs: candidate.elapsedMs - last.elapsedMs,
              distanceMeters: TurnCaptureSampler.distanceMeters(last, candidate),
              intervalMs: sampler.intervalMs,
              distanceFilterMeters: sampler.minimumDistanceMeters,
              sampler: sampler,
              samplerOnly: true
            )
          } ?? true
        guard emit else { continue }
        sampler.record(candidate)
        previous = candidate
        emitted.append(index)
      }
      XCTAssertEqual(
        emitted,
        scenario["recorded"] as? [Int] ?? [],
        scenario["name"] as? String ?? "?"
      )
    }
  }

  func testOnlyTheLegacyRuleEmitsOnDistance() {
    let first = TurnCaptureSampler.Fix(
      elapsedMs: 0, latitude: 0.5, longitude: 0.5,
      speedMetersPerSecond: 1.3, bearingDegrees: nil, bearingAccuracyDegrees: nil
    )
    // Six metres east, one second later.
    let next = TurnCaptureSampler.Fix(
      elapsedMs: 1_000, latitude: 0.5, longitude: 0.5 + 6 / 111_195.08 / cos(0.5 * .pi / 180),
      speedMetersPerSecond: 1.3, bearingDegrees: nil, bearingAccuracyDegrees: nil
    )
    var sampler = TurnCaptureSampler(intervalMs: 5_000, turnDegrees: 45, minimumDistanceMeters: 5)
    sampler.record(first)
    let distance = TurnCaptureSampler.distanceMeters(first, next)
    XCTAssertGreaterThan(distance, 5)

    XCTAssertTrue(
      FixEmissionRule.shouldEmit(
        next, elapsedMs: 1_000, distanceMeters: distance, intervalMs: 5_000,
        distanceFilterMeters: 5, sampler: nil, samplerOnly: false
      ))
    XCTAssertFalse(
      FixEmissionRule.shouldEmit(
        next, elapsedMs: 1_000, distanceMeters: distance, intervalMs: 5_000,
        distanceFilterMeters: 5, sampler: sampler, samplerOnly: true
      ))
  }

  func testZeroDegreesRecordsNoTurns() {
    func driving(_ seconds: Double, east: Double, north: Double, bearing: Double)
      -> TurnCaptureSampler.Fix
    {
      TurnCaptureSampler.Fix(
        elapsedMs: seconds * 1_000,
        latitude: 0.5 + north / 111_195.08,
        longitude: 0.5 + east / 111_195.08 / cos(0.5 * .pi / 180),
        speedMetersPerSecond: 12,
        bearingDegrees: bearing,
        bearingAccuracyDegrees: 5
      )
    }
    var off = TurnCaptureSampler(intervalMs: 5_000, turnDegrees: 0, minimumDistanceMeters: 5)
    var on = TurnCaptureSampler(intervalMs: 5_000, turnDegrees: 45, minimumDistanceMeters: 5)
    let start = driving(0, east: 0, north: 0, bearing: 90)
    let turned = driving(1, east: 12, north: 0, bearing: 180)
    XCTAssertTrue(off.accept(start))
    XCTAssertTrue(on.accept(start))
    XCTAssertFalse(off.accept(turned))
    XCTAssertTrue(on.accept(turned))
  }

  func testAnglesWrapAroundNorth() {
    XCTAssertEqual(TurnCaptureSampler.angleBetween(10, 350), 20, accuracy: 0.001)
    XCTAssertEqual(TurnCaptureSampler.angleBetween(350, 10), 20, accuracy: 0.001)
    XCTAssertEqual(TurnCaptureSampler.angleBetween(0, 180), 180, accuracy: 0.001)
  }
}
