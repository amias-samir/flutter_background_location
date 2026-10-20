import XCTest

@testable import flutter_background_location_tracker

/// Replays the turn-capture fixture shared with Kotlin.
final class TurnCaptureSamplerTests: XCTestCase {
  func testReplaysEveryScenario() throws {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(
      bundle.url(forResource: "turn_capture_v1", withExtension: "json"),
      "turn_capture_v1.json is missing from the RunnerTests bundle"
    )
    let fixture = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    let config = try XCTUnwrap(fixture["config"] as? [String: Any])
    let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(scenarios.count, 8)
    for scenario in scenarios {
      var sampler = TurnCaptureSampler(
        intervalMs: config["intervalMs"] as? Double ?? 5_000,
        turnDegrees: config["turnDegrees"] as? Double ?? 45,
        minimumDistanceMeters: config["minimumDistanceMeters"] as? Double ?? 5
      )
      var recorded: [Int] = []
      for (index, fix) in (scenario["fixes"] as? [[String: Any]] ?? []).enumerated() {
        let accepted = sampler.accept(
          TurnCaptureSampler.Fix(
            elapsedMs: (fix["t"] as? Double ?? 0) * 1_000,
            latitude: fix["latitude"] as? Double ?? 0,
            longitude: fix["longitude"] as? Double ?? 0,
            speedMetersPerSecond: fix["speed"] as? Double,
            bearingDegrees: fix["bearing"] as? Double,
            bearingAccuracyDegrees: fix["bearingAccuracy"] as? Double
          )
        )
        if accepted { recorded.append(index) }
      }
      XCTAssertEqual(
        recorded,
        scenario["recorded"] as? [Int] ?? [],
        scenario["name"] as? String ?? "?"
      )
    }
  }

  func testAnglesWrapAroundNorth() {
    XCTAssertEqual(TurnCaptureSampler.angleBetween(10, 350), 20, accuracy: 0.001)
    XCTAssertEqual(TurnCaptureSampler.angleBetween(350, 10), 20, accuracy: 0.001)
    XCTAssertEqual(TurnCaptureSampler.angleBetween(0, 180), 180, accuracy: 0.001)
  }
}
