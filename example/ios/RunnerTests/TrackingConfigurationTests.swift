import CoreLocation
import XCTest

@testable import flutter_background_location_tracker

/// `samplingPolicyVersion`: parsing, persistence, and the moving stream it
/// selects.
final class TrackingConfigurationTests: XCTestCase {
  private func configuration(
    accuracy: Any = "precised",
    intervalMs: Double = 5_000,
    samplingPolicyVersion: Any? = 2
  ) -> TrackingConfiguration {
    var values: [String: Any] = ["desiredAccuracy": accuracy, "movingIntervalMs": intervalMs]
    values["samplingPolicyVersion"] = samplingPolicyVersion
    return TrackingConfiguration(dictionary: values)
  }

  func testAConfigurationWithoutTheKeyKeepsTheLegacySampling() {
    XCTAssertEqual(TrackingConfiguration.defaults.samplingPolicyVersion, 1)
    // As persisted before sampling policy 2.
    let legacy = TrackingConfiguration(dictionary: [
      "desiredAccuracy": NSNumber(value: kCLLocationAccuracyBestForNavigation),
      "movingIntervalMs": 5_000,
      "motionPolicyVersion": 2,
      "turnCaptureDegrees": 45,
    ])
    XCTAssertEqual(legacy.samplingPolicyVersion, 1)
    XCTAssertFalse(legacy.samplesUnfilteredMovingStream)
  }

  func testAValidVersionIsKeptThroughPersistenceAndJSON() throws {
    let custom = configuration()
    XCTAssertEqual(custom.samplingPolicyVersion, 2)
    XCTAssertEqual(custom.dictionary["samplingPolicyVersion"] as? Int, 2)

    // Resume and recovery rebuild the configuration from UserDefaults.
    let suiteName = "tracking-configuration-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(custom.dictionary, forKey: "configuration")
    let restored = TrackingConfiguration(
      dictionary: try XCTUnwrap(defaults.dictionary(forKey: "configuration"))
    )
    XCTAssertEqual(restored.samplingPolicyVersion, 2)
    XCTAssertTrue(restored.samplesUnfilteredMovingStream)

    let json = try JSONSerialization.data(withJSONObject: custom.dictionary)
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    XCTAssertEqual(TrackingConfiguration(dictionary: decoded).samplingPolicyVersion, 2)
  }

  func testAnInvalidVersionKeepsTheLegacySampling() {
    let invalidValues: [Any] = [0, -1, "two", NSNull(), ["version": 2]]
    for invalid in invalidValues {
      XCTAssertEqual(
        configuration(samplingPolicyVersion: invalid).samplingPolicyVersion,
        1,
        "\(invalid)"
      )
    }
    XCTAssertEqual(configuration(samplingPolicyVersion: "2").samplingPolicyVersion, 2)
    // A newer version than this side knows samples with the newest it does.
    XCTAssertEqual(configuration(samplingPolicyVersion: 9).samplingPolicyVersion, 2)
  }

  func testOnlyHighAccuracyMovingCaptureSamplesAnUnfilteredStream() {
    XCTAssertTrue(configuration(accuracy: "precised").samplesUnfilteredMovingStream)
    XCTAssertTrue(configuration(accuracy: "high").samplesUnfilteredMovingStream)
    XCTAssertTrue(
      configuration(accuracy: NSNumber(value: kCLLocationAccuracyBest))
        .samplesUnfilteredMovingStream
    )
    XCTAssertFalse(configuration(accuracy: "medium").samplesUnfilteredMovingStream)
    XCTAssertFalse(configuration(accuracy: "low").samplesUnfilteredMovingStream)
    XCTAssertFalse(configuration(accuracy: NSNumber(value: 5.0)).samplesUnfilteredMovingStream)
    XCTAssertFalse(configuration(intervalMs: 1_000).samplesUnfilteredMovingStream)
    XCTAssertFalse(configuration(samplingPolicyVersion: 1).samplesUnfilteredMovingStream)
    XCTAssertFalse(configuration(samplingPolicyVersion: nil).samplesUnfilteredMovingStream)
  }
}
