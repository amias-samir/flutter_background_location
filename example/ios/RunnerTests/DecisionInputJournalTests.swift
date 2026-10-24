import XCTest

@testable import flutter_background_location_tracker

/// Replays the activity-reading compaction fixture shared with Kotlin and
/// pins what each journaled fix carries.
final class DecisionInputJournalTests: XCTestCase {
  private func loadFixture() throws -> [String: Any] {
    let bundle = Bundle(for: Self.self)
    let url = try XCTUnwrap(
      bundle.url(forResource: "activity_reading_compaction_v1", withExtension: "json"),
      "activity_reading_compaction_v1.json is missing from the RunnerTests bundle"
    )
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
  }

  private func reading(
    _ type: String,
    _ confidence: Int,
    source: String = "ios_core_motion_activity"
  ) -> [String: Any] {
    ["type": type, "confidence": confidence, "timestamp": 1_800_000_000_000, "source": source]
  }

  private func readings(_ inputs: [String: Any]) -> [[String: Any]] {
    inputs["activityReadings"] as? [[String: Any]] ?? []
  }

  private func transitions(_ inputs: [String: Any]) -> [[String: Any]] {
    inputs["profileTransitions"] as? [[String: Any]] ?? []
  }

  func testReplaysTheCompactionFixture() throws {
    let fixture = try loadFixture()
    let config = try XCTUnwrap(fixture["config"] as? [String: Any])
    XCTAssertEqual(config["maxReadings"] as? Int, DecisionInputJournal.maximumReadings)
    let scenarios = try XCTUnwrap(fixture["scenarios"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(scenarios.count, 7)
    for scenario in scenarios {
      let name = scenario["name"] as? String ?? "?"
      var journal = DecisionInputJournal()
      for reading in scenario["readings"] as? [[String: Any]] ?? [] {
        journal.recordReading(reading)
      }
      let inputs = journal.take(journal.mark(trackingProfile: "moving"))
      // `kept` lists input indices; arrival numbers count from 1.
      XCTAssertEqual(
        readings(inputs).compactMap { ($0["seq"] as? Int).map { $0 - 1 } },
        scenario["kept"] as? [Int] ?? [],
        name
      )
      XCTAssertEqual(
        inputs["activityReadingsDropped"] as? Int ?? 0,
        scenario["dropped"] as? Int ?? 0,
        name
      )
    }
  }

  func testReadingsKeepTheirChannelKeysAndGainAnArrivalNumber() throws {
    var journal = DecisionInputJournal()
    let event: [String: Any] = [
      "type": "walking",
      "rawType": "walking",
      "confidence": 100,
      "timestamp": Int64(1_800_000_000_000),
      "episodeStartedAt": Int64(1_799_999_990_000),
      "source": "ios_core_motion_activity",
      "evidenceState": "fresh",
      "ageMs": Int64(0),
      "probabilities": ["walking": 100],
      "walking": true,
      "trackId": "track",
    ]
    journal.recordReading(event)

    let taken = readings(journal.take(journal.mark(trackingProfile: "moving")))
    XCTAssertEqual(taken.count, 1)
    let kept = try XCTUnwrap(taken.first)
    XCTAssertEqual(Set(kept.keys), Set(event.keys).union(["seq"]))
    XCTAssertEqual(kept["seq"] as? Int, 1)
    XCTAssertEqual(kept["episodeStartedAt"] as? Int64, 1_799_999_990_000)

    // A fix with nothing new still carries both lists, empty.
    let next = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual((next["activityReadings"] as? [Any])?.count, 0)
    XCTAssertEqual((next["profileTransitions"] as? [Any])?.count, 0)
    XCTAssertNil(next["activityReadingsDropped"])
  }

  func testAFixIsStampedBeforeItsEvaluationSwitchesTheProfile() throws {
    var journal = DecisionInputJournal()
    journal.recordReading(reading("walking", 100))
    // Fix N is captured in the stationary profile; evaluating it ends the stop.
    let fixN = journal.mark(trackingProfile: "stationary")
    journal.recordTransition(
      atMs: 1_800_000_005_000,
      from: "stationary",
      to: "moving",
      reason: "doppler"
    )

    let inputsN = journal.take(fixN)
    XCTAssertEqual(inputsN["trackingProfile"] as? String, "stationary")
    XCTAssertEqual(inputsN["samplingProfile"] as? String, "stationary")
    XCTAssertEqual(inputsN["batteryMode"] as? String, "stationary")
    XCTAssertEqual(inputsN["motionState"] as? String, "stationary")
    XCTAssertEqual(readings(inputsN).count, 1)
    XCTAssertEqual(transitions(inputsN).count, 0)

    // Fix N+1 reports the switch fix N caused.
    let inputsNext = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual(inputsNext["samplingProfile"] as? String, "moving")
    XCTAssertEqual(readings(inputsNext).count, 0)
    let switched = try XCTUnwrap(transitions(inputsNext).first)
    XCTAssertEqual(transitions(inputsNext).count, 1)
    XCTAssertEqual(switched["seq"] as? Int, 2)
    XCTAssertEqual(switched["at"] as? Int64, 1_800_000_005_000)
    XCTAssertEqual(switched["from"] as? String, "stationary")
    XCTAssertEqual(switched["to"] as? String, "moving")
    XCTAssertEqual(switched["reason"] as? String, "doppler")
  }

  func testAFixThatIsNotJournaledLeavesItsInputsForTheNextOne() {
    var journal = DecisionInputJournal()
    journal.recordReading(reading("stationary", 100))
    // The sampler skips this fix: nothing is taken for it.
    _ = journal.mark(trackingProfile: "moving")
    journal.recordTransition(atMs: 1, from: "moving", to: "stationary", reason: "still_episode")

    let inputs = journal.take(journal.mark(trackingProfile: "stationary"))
    XCTAssertEqual(readings(inputs).compactMap { $0["seq"] as? Int }, [1])
    XCTAssertEqual(transitions(inputs).compactMap { $0["seq"] as? Int }, [2])
    XCTAssertEqual(inputs["samplingProfile"] as? String, "stationary")
  }

  func testOnlyTheNewestEightSwitchesAreKept() {
    var journal = DecisionInputJournal()
    for index in 0..<10 {
      journal.recordTransition(
        atMs: Int64(index),
        from: index % 2 == 0 ? "moving" : "stationary",
        to: index % 2 == 0 ? "stationary" : "moving",
        reason: nil
      )
    }
    let kept = transitions(journal.take(journal.mark(trackingProfile: "moving")))
    XCTAssertEqual(kept.compactMap { $0["seq"] as? Int }, Array(3...10))
    XCTAssertNil(kept.first?["reason"], "an unknown reason is left out")
  }

  func testArrivalNumbersAreSharedAndRestartWithEachGeneration() {
    var journal = DecisionInputJournal()
    journal.recordReading(reading("walking", 100))
    journal.recordTransition(atMs: 1, from: "stationary", to: "moving", reason: "moving_readings")
    journal.recordReading(reading("stationary", 100))
    let inputs = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual(readings(inputs).compactMap { $0["seq"] as? Int }, [1, 3])
    XCTAssertEqual(transitions(inputs).compactMap { $0["seq"] as? Int }, [2])

    journal.reset()
    journal.recordReading(reading("walking", 100))
    let restarted = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual(readings(restarted).compactMap { $0["seq"] as? Int }, [1])
  }

  func testARunNeverSpansTwoFixes() {
    var journal = DecisionInputJournal()
    let periodic = "android_activity_recognition"
    for _ in 0..<3 { journal.recordReading(reading("stationary", 100, source: periodic)) }
    let first = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual(readings(first).compactMap { $0["seq"] as? Int }, [1, 3])

    for _ in 0..<3 { journal.recordReading(reading("stationary", 100, source: periodic)) }
    let second = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual(readings(second).compactMap { $0["seq"] as? Int }, [4, 6])
  }

  func testTheByteBudgetDropsTheOldestReadings() throws {
    var journal = DecisionInputJournal()
    let padding = String(repeating: "x", count: 400)
    for index in 0..<DecisionInputJournal.maximumReadings {
      var event = reading("unknown", 0)
      event["timestamp"] = index
      event["rawType"] = padding
      journal.recordReading(event)
    }

    let inputs = journal.take(journal.mark(trackingProfile: "moving"))
    let taken = readings(inputs)
    let bytes = try JSONSerialization.data(withJSONObject: taken).count
    XCTAssertLessThanOrEqual(bytes, DecisionInputJournal.maximumReadingBytes)
    XCTAssertGreaterThan(bytes, DecisionInputJournal.maximumReadingBytes - 600, "as many as fit")
    let dropped = try XCTUnwrap(inputs["activityReadingsDropped"] as? Int)
    XCTAssertEqual(dropped + taken.count, DecisionInputJournal.maximumReadings)
    XCTAssertEqual(taken.first?["seq"] as? Int, dropped + 1)
    XCTAssertEqual(taken.last?["seq"] as? Int, DecisionInputJournal.maximumReadings)
  }

  func testAReadingThatCannotBeJournaledIsDroppedAndCounted() {
    var journal = DecisionInputJournal()
    var invalid = reading("walking", 100)
    invalid["unencodable"] = Date()
    journal.recordReading(invalid)
    journal.recordReading(reading("stationary", 100))

    let inputs = journal.take(journal.mark(trackingProfile: "moving"))
    XCTAssertEqual(readings(inputs).compactMap { $0["seq"] as? Int }, [2])
    XCTAssertEqual(inputs["activityReadingsDropped"] as? Int, 1)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(inputs))
  }
}
