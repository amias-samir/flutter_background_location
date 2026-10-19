import XCTest

@testable import flutter_background_location_tracker

/// Replays the motion-policy-2 fixture shared with Dart and Kotlin.
final class StationaryPolicyV2Tests: XCTestCase {
  private func loadFixture() throws -> [String: Any] {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(
      bundle.url(forResource: "motion_policy_v2", withExtension: "json"),
      "motion_policy_v2.json is missing from the RunnerTests bundle"
    )
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testReplaysEveryIOSScenario() throws {
    let fixture = try loadFixture()
    let config = try XCTUnwrap(fixture["config"] as? [String: Any])
    let origin = try XCTUnwrap(fixture["origin"] as? [String: Any])
    let originLatitude = try XCTUnwrap(origin["latitude"] as? Double)
    let originLongitude = try XCTUnwrap(origin["longitude"] as? Double)
    let metersPerDegree = 111_195.07973436875
    let start = 1_792_000_000_000.0
    var replayed = 0
    for case let scenario as [String: Any] in try XCTUnwrap(fixture["scenarios"] as? [Any]) {
      let platforms = scenario["platforms"] as? [String] ?? []
      guard platforms.contains("ios") else { continue }
      let name = scenario["name"] as? String ?? "?"
      var policy = StationaryPolicyV2(
        stationaryConfidenceThreshold: config["stationaryConfidenceThreshold"] as? Int ?? 75,
        movingConfidenceThreshold: config["movingConfidenceThreshold"] as? Int ?? 60,
        movingConfirmationCount: config["movingConfirmationCount"] as? Int ?? 1,
        confirmationMs: (config["confirmationSeconds"] as? Double ?? 90) * 1_000,
        maximumAcceptedAccuracyMeters: config["maximumAcceptedAccuracyMeters"] as? Double ?? 20
      )
      for case let step as [String: Any] in scenario["steps"] as? [Any] ?? [] {
        let seconds = step["t"] as? Double ?? 0
        let atMs = start + seconds * 1_000
        if let reading = step["reading"] as? [String: Any] {
          _ = policy.onReading(
            .init(
              type: Self.nativeType(reading["type"] as? String ?? "unknown"),
              confidence: reading["confidence"] as? Int ?? 0,
              recordedAtMs: atMs,
              source: reading["source"] as? String ?? ""
            ),
            nowMs: atMs
          )
        } else if let fix = step["fix"] as? [String: Any] {
          let east = fix["east"] as? Double ?? 0
          let north = fix["north"] as? Double ?? 0
          _ = policy.onFix(
            .init(
              latitude: originLatitude + north / metersPerDegree,
              longitude: originLongitude
                + east / (metersPerDegree * cos(originLatitude * .pi / 180)),
              accuracyMeters: fix["accuracy"] as? Double,
              speed: fix["speed"] as? Double,
              speedAccuracy: fix["speedAccuracy"] as? Double,
              hasVerticalAccuracy: fix["vertical"] as? Bool ?? false,
              mocked: false,
              observedAtMs: atMs
            )
          )
        } else {
          _ = policy.evaluate(nowMs: atMs)
        }
        guard let expectation = step["expect"] as? [String: Any] else { continue }
        let place = "\(name) at t=\(Int(seconds))"
        if let episode = expectation["episode"] as? Bool {
          XCTAssertEqual(policy.stillEpisodeActive, episode, place)
        }
        if let profile = expectation["profile"] as? String {
          XCTAssertEqual(policy.profile, profile == "stationary" ? .stationary : .moving, place)
        }
      }
      replayed += 1
    }
    XCTAssertGreaterThanOrEqual(replayed, 4)
  }

  func testConfigurationWithoutTheKeyKeepsTheLegacyPolicy() {
    let legacy = TrackingConfiguration(dictionary: ["captureIntent": "adaptive"])
    XCTAssertEqual(legacy.motionPolicyVersion, 1)
    XCTAssertFalse(legacy.usesStationaryPolicyV2)

    let current = TrackingConfiguration(
      dictionary: ["captureIntent": "adaptive", "motionPolicyVersion": 2]
    )
    XCTAssertTrue(current.usesStationaryPolicyV2)
    XCTAssertEqual(TrackingConfiguration(dictionary: current.dictionary).motionPolicyVersion, 2)

    XCTAssertEqual(TrackingConfiguration(dictionary: ["motionPolicyVersion": 9]).motionPolicyVersion, 2)
    XCTAssertFalse(
      TrackingConfiguration(dictionary: ["captureIntent": "walking", "motionPolicyVersion": 2])
        .usesStationaryPolicyV2
    )
  }

  func testDopplerConfirmsOnlyClearlyMeasuredSpeeds() {
    XCTAssertTrue(StationaryPolicyV2.dopplerConfirmsDeparture(speed: 3.4, speedAccuracy: 1.2))
    XCTAssertFalse(StationaryPolicyV2.dopplerConfirmsDeparture(speed: 1.7, speedAccuracy: 5.9))
    XCTAssertFalse(StationaryPolicyV2.dopplerConfirmsDeparture(speed: 1.1, speedAccuracy: 0.2))
    XCTAssertEqual(
      StationaryPolicyV2.holdRadiusMeters(anchorSigmaMeters: 2, fixSigmaMeters: 2), 25)
  }

  func testReportsWhyTheProfileChanged() {
    var policy = StationaryPolicyV2(
      stationaryConfidenceThreshold: 75,
      movingConfidenceThreshold: 60,
      movingConfirmationCount: 1,
      confirmationMs: 90_000,
      maximumAcceptedAccuracyMeters: 20
    )
    let start = 1_792_000_000_000.0
    let source = "android_activity_recognition"
    _ = policy.onReading(
      .init(type: "stationary", confidence: 100, recordedAtMs: start, source: source),
      nowMs: start
    )
    _ = policy.onReading(
      .init(type: "stationary", confidence: 99, recordedAtMs: start + 30_000, source: source),
      nowMs: start + 30_000
    )
    XCTAssertEqual(policy.evaluate(nowMs: start + 180_000), .stationary)
    XCTAssertEqual(policy.lastTransitionReason, StationaryPolicyV2.reasonEntryWithoutFixes)

    _ = policy.onFix(
      .init(
        latitude: 0.5,
        longitude: 0.5,
        accuracyMeters: 2,
        speed: 3.4,
        speedAccuracy: 1.2,
        hasVerticalAccuracy: true,
        mocked: false,
        observedAtMs: start + 600_000
      )
    )
    XCTAssertEqual(policy.profile, .moving)
    XCTAssertEqual(policy.lastTransitionReason, StationaryPolicyV2.reasonDoppler)
  }

  private static func nativeType(_ value: String) -> String {
    switch value {
    case "in_vehicle": return "automotive"
    case "on_bicycle": return "cycling"
    default: return value
    }
  }
}
