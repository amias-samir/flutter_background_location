import XCTest

@testable import flutter_background_location_tracker

/// A pedometer the test answers by hand.
private final class FakeStepCountSource: StepCountSource {
  private(set) var calls: [String] = []
  private var live: ((StepCountReading?) -> Void)?
  /// The answer to every query; nil answers without data.
  var queryAnswer: StepCountReading?
  var answersQueries = true

  func startUpdates(from start: Date, handler: @escaping (StepCountReading?) -> Void) {
    calls.append("start")
    live = handler
  }

  func stopUpdates() {
    calls.append("stop")
    live = nil
  }

  func query(from start: Date, to end: Date, handler: @escaping (StepCountReading?) -> Void) {
    calls.append("query")
    if answersQueries { handler(queryAnswer) }
  }

  func deliver(_ steps: Int, through endDate: Date) {
    live?(StepCountReading(steps: steps, endDate: endDate))
  }

  var queryCount: Int { calls.filter { $0 == "query" }.count }
}

private final class TestClock {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

/// Steps counted per capture generation.
final class StepCounterTests: XCTestCase {
  private let coverageKeys: Set<String> = [
    "state", "countedThrough", "lastRiseAt", "uncountedMs", "sensor", "reregistrations",
  ]

  private func milliseconds(_ date: Date) -> Int64 {
    StepCounter.epochMilliseconds(date)
  }

  /// Lets the counter's main-queue hops run.
  private func drainMainQueue() {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 1)
  }

  func testCountsAreUnmeasuredUntilThePedometerReports() {
    let session = StepCountSession(generationId: "generation", startedAt: Date())
    XCTAssertNil(session.steps)
    XCTAssertEqual(session.generationId, "generation")
  }

  func testTheCountNeverGoesBack() {
    var session = StepCountSession(generationId: "generation", startedAt: Date())
    session.observe(totalSteps: 0)
    XCTAssertEqual(session.steps, 0)
    session.observe(totalSteps: 120)
    // A live update arriving after a newer query result.
    session.observe(totalSteps: 115)
    session.observe(totalSteps: -1)
    XCTAssertEqual(session.steps, 120)
    session.observe(totalSteps: 180)
    XCTAssertEqual(session.steps, 180)
  }

  func testNothingIsCountedWithoutASession() {
    let counter = StepCounter()
    XCTAssertFalse(counter.isCounting("generation"))
    XCTAssertFalse(counter.isCounting(nil))
    XCTAssertNil(counter.steps(for: "generation"))
    XCTAssertNil(counter.coverage(for: "generation"))
    let flushed = expectation(description: "flush answers at once")
    counter.flush { flushed.fulfill() }
    wait(for: [flushed], timeout: 0.1)
  }

  func testCoverageReportsThePedometerAndItsNewestReading() throws {
    let clock = TestClock()
    let source = FakeStepCountSource()
    let counter = StepCounter(source: source, permitted: { true }, clock: { clock.now })
    counter.start(generationId: "generation", startedAt: clock.now)

    let initial = try XCTUnwrap(counter.coverage(for: "generation")?.map)
    XCTAssertEqual(Set(initial.keys), coverageKeys)
    XCTAssertEqual(initial["state"] as? String, "counting")
    XCTAssertTrue(initial["countedThrough"] is NSNull)
    XCTAssertTrue(initial["lastRiseAt"] is NSNull)
    XCTAssertEqual(initial["uncountedMs"] as? Int, 0)
    XCTAssertEqual(initial["sensor"] as? String, "pedometer")
    XCTAssertEqual(initial["reregistrations"] as? Int, 0)

    let risen = clock.now.addingTimeInterval(20)
    source.deliver(30, through: risen)
    drainMainQueue()
    let quiet = clock.now.addingTimeInterval(40)
    source.deliver(30, through: quiet)
    drainMainQueue()

    let coverage = try XCTUnwrap(counter.coverage(for: "generation")?.map)
    XCTAssertEqual(counter.steps(for: "generation"), 30)
    XCTAssertEqual(coverage["countedThrough"] as? Int64, milliseconds(quiet))
    XCTAssertEqual(coverage["lastRiseAt"] as? Int64, milliseconds(risen))
    XCTAssertNil(counter.coverage(for: "another generation"))
  }

  func testUnavailableWithoutMotionAndFitness() {
    let source = FakeStepCountSource()
    let counter = StepCounter(source: source, permitted: { false })
    counter.start(generationId: "generation", startedAt: Date())
    XCTAssertFalse(counter.isCounting("generation"))
    XCTAssertNil(counter.coverage(for: "generation"))
    XCTAssertEqual(source.calls, [])

    var finalized = false
    counter.finalize { record in
      XCTAssertNil(record)
      finalized = true
    }
    XCTAssertTrue(finalized)
    var answered = false
    counter.querySpan(from: Date(timeIntervalSinceNow: -60), to: Date(), timeout: 1) { reading in
      XCTAssertNil(reading)
      answered = true
    }
    XCTAssertTrue(answered)
    XCTAssertEqual(source.calls, [], "never asks without permission")

    let unavailable = StepCoverage(state: StepCoverage.unavailable).map
    XCTAssertEqual(Set(unavailable.keys), coverageKeys)
    XCTAssertEqual(unavailable["state"] as? String, "unavailable")
  }

  func testFinalizeReadsThePedometerBeforeCountingStops() throws {
    let clock = TestClock()
    let source = FakeStepCountSource()
    let counter = StepCounter(source: source, permitted: { true }, clock: { clock.now })
    let start = clock.now
    counter.start(generationId: "generation", startedAt: start)
    source.deliver(40, through: start.addingTimeInterval(30))
    drainMainQueue()

    clock.now = start.addingTimeInterval(60)
    source.queryAnswer = StepCountReading(steps: 52, endDate: clock.now)
    var record: StepCountRecord?
    var callsWhenFinal: [String] = []
    let finalized = expectation(description: "finalized")
    counter.finalize { final in
      record = final
      callsWhenFinal = source.calls
      XCTAssertTrue(counter.isCounting("generation"), "counting continues until stop")
      // What a pause or stop does next.
      counter.stop()
      finalized.fulfill()
    }
    wait(for: [finalized], timeout: 1)

    XCTAssertEqual(callsWhenFinal, ["start", "query"])
    XCTAssertEqual(source.calls, ["start", "query", "stop"])
    let final = try XCTUnwrap(record)
    XCTAssertEqual(final.captureGenerationId, "generation")
    XCTAssertEqual(final.stepCount, 52)
    XCTAssertEqual(final.coverage.state, "counting")
    XCTAssertEqual(final.coverage.countedThrough, milliseconds(clock.now))
    XCTAssertEqual(final.coverage.lastRiseAt, milliseconds(clock.now))
    XCTAssertEqual(Set(final.map.keys), ["captureGenerationId", "stepCount", "stepCoverage"])
    XCTAssertEqual(final.map["stepCount"] as? Int, 52)
    XCTAssertNil(counter.steps(for: "generation"))
  }

  func testFinalizeKeepsTheLiveCountWhenThePedometerDoesNotAnswer() throws {
    let clock = TestClock()
    let source = FakeStepCountSource()
    source.answersQueries = false
    let counter = StepCounter(source: source, permitted: { true }, clock: { clock.now })
    counter.start(generationId: "generation", startedAt: clock.now)
    source.deliver(40, through: clock.now.addingTimeInterval(30))
    drainMainQueue()

    var record: StepCountRecord?
    let finalized = expectation(description: "finalized after the timeout")
    counter.finalize { final in
      record = final
      finalized.fulfill()
    }
    wait(for: [finalized], timeout: StepCounter.flushTimeout + 1)
    XCTAssertEqual(record?.stepCount, 40)
    let entry = try XCTUnwrap(counter.diagnostics.last)
    XCTAssertEqual(entry["event"] as? String, "finalize")
    XCTAssertTrue(entry["flushCompletedMs"] is NSNull)
    XCTAssertTrue(entry["replayOutcome"] is NSNull)
  }

  func testWalkingWithoutARisingCountIsSuspectUntilTheCountRises() throws {
    let clock = TestClock()
    let source = FakeStepCountSource()
    let counter = StepCounter(source: source, permitted: { true }, clock: { clock.now })
    let start = clock.now
    counter.start(generationId: "generation", startedAt: start)
    source.deliver(10, through: start)
    drainMainQueue()
    source.queryAnswer = StepCountReading(steps: 10, endDate: start)

    func walk(at seconds: Double) {
      clock.now = start.addingTimeInterval(seconds)
      counter.noteFix(speed: 1.4, speedAccuracy: 0.3, inVehicle: false)
    }
    for seconds in stride(from: 5.0, through: 115, by: 5) { walk(at: seconds) }
    XCTAssertEqual(counter.coverage(for: "generation")?.state, "counting")
    XCTAssertEqual(source.queryCount, 0)

    // Two minutes of walking pace without a rise: the pedometer is asked.
    walk(at: 120)
    drainMainQueue()
    XCTAssertEqual(counter.coverage(for: "generation")?.state, "suspect")
    XCTAssertEqual(source.queryCount, 1)
    // At most once a minute.
    walk(at: 150)
    XCTAssertEqual(source.queryCount, 1)
    walk(at: 181)
    drainMainQueue()
    XCTAssertEqual(source.queryCount, 2)
    XCTAssertEqual(counter.coverage(for: "generation")?.state, "suspect")

    // Any rise recovers the count.
    source.deliver(25, through: clock.now)
    drainMainQueue()
    XCTAssertEqual(counter.coverage(for: "generation")?.state, "counting")
    XCTAssertEqual(counter.steps(for: "generation"), 25)

    let events = counter.diagnostics.compactMap { $0["event"] as? String }
    XCTAssertEqual(events, ["start", "transition", "flush", "flush", "transition"])
    let entries = counter.diagnostics
    let suspected = try XCTUnwrap(entries.first { $0["event"] as? String == "transition" })
    XCTAssertEqual(suspected["evidenceSource"] as? String, "doppler")
    XCTAssertEqual(suspected["watchdogState"] as? String, "suspect")
    let flushed = try XCTUnwrap(entries.first { $0["event"] as? String == "flush" })
    XCTAssertEqual(flushed["replayOutcome"] as? String, "same")
  }

  func testOnlyAPreciseWalkingPaceIsWalkingEvidence() {
    func walking(_ speed: Double?, _ accuracy: Double?, inVehicle: Bool = false) -> Bool {
      StepStallWatch.isWalkingEvidence(speed: speed, speedAccuracy: accuracy, inVehicle: inVehicle)
    }
    XCTAssertTrue(walking(1.3, 0.4))
    XCTAssertFalse(walking(1.3, 0.8))
    XCTAssertFalse(walking(0.5, 0.2))
    XCTAssertFalse(walking(3.0, 0.2))
    XCTAssertFalse(walking(1.3, 0.2, inVehicle: true))
    XCTAssertFalse(walking(nil, 0.2))
    XCTAssertFalse(walking(1.3, nil))
  }

  func testNoEvidenceNeverSuspectsAndAnInterruptedWalkStartsOver() {
    var still = StepStallWatch(startedAtMs: 0)
    for second in stride(from: 0, through: 600, by: 5) {
      XCTAssertFalse(still.observeFix(walking: false, atMs: Double(second) * 1_000))
    }
    XCTAssertFalse(still.suspect)

    var watch = StepStallWatch(startedAtMs: 0)
    XCTAssertFalse(watch.observeFix(walking: true, atMs: 100_000))
    // More than a minute without walking evidence: the span starts again.
    XCTAssertFalse(watch.observeFix(walking: true, atMs: 200_000))
    XCTAssertFalse(watch.observeFix(walking: true, atMs: 250_000))
    XCTAssertTrue(watch.observeFix(walking: true, atMs: 260_000))
    XCTAssertTrue(watch.suspect)
    watch.observeRise(atMs: 261_000)
    XCTAssertFalse(watch.suspect)
  }

  func testAClosedGenerationTakesThePedometersAnswerForItsSpan() {
    let end = Date(timeIntervalSince1970: 1_800_000_600)
    let earlier = milliseconds(end.addingTimeInterval(-60))
    let checkpoint = StepCountRecord(
      captureGenerationId: "generation",
      stepCount: 300,
      coverage: StepCoverage(state: "counting", countedThrough: earlier, lastRiseAt: earlier)
    )

    let answered = StepCountRecord.closing(
      generationId: "generation",
      answer: StepCountReading(steps: 340, endDate: end),
      known: checkpoint,
      knownFromCheckpoint: true
    )
    XCTAssertEqual(answered?.stepCount, 340)
    XCTAssertEqual(answered?.coverage.state, "counting")
    XCTAssertEqual(answered?.coverage.countedThrough, milliseconds(end))
    XCTAssertEqual(answered?.coverage.lastRiseAt, milliseconds(end))

    // Without an answer a checkpoint stands in, marked as never flushed.
    let unanswered = StepCountRecord.closing(
      generationId: "generation",
      answer: nil,
      known: checkpoint,
      knownFromCheckpoint: true
    )
    XCTAssertEqual(unanswered?.stepCount, 300)
    XCTAssertEqual(unanswered?.coverage.state, "ended_unflushed")
    XCTAssertEqual(unanswered?.coverage.countedThrough, earlier)

    // A live count kept at the stop stands as it is.
    XCTAssertEqual(
      StepCountRecord.closing(
        generationId: "generation",
        answer: nil,
        known: checkpoint,
        knownFromCheckpoint: false
      ),
      checkpoint
    )

    // The count never goes back, and a suspect count without a rise stays so.
    let suspect = StepCountRecord(
      captureGenerationId: "generation",
      stepCount: 300,
      coverage: StepCoverage(state: "suspect", countedThrough: earlier, lastRiseAt: earlier)
    )
    let lower = StepCountRecord.closing(
      generationId: "generation",
      answer: StepCountReading(steps: 250, endDate: end),
      known: suspect,
      knownFromCheckpoint: false
    )
    XCTAssertEqual(lower?.stepCount, 300)
    XCTAssertEqual(lower?.coverage.state, "suspect")
    XCTAssertEqual(lower?.coverage.lastRiseAt, earlier)
    XCTAssertNil(
      StepCountRecord.closing(
        generationId: "generation",
        answer: nil,
        known: nil,
        knownFromCheckpoint: false
      ))
  }

  func testRecordsSurviveUserDefaults() throws {
    let suiteName = "step-counter-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let record = StepCountRecord(
      captureGenerationId: "generation",
      stepCount: 12,
      coverage: StepCoverage(state: "counting", countedThrough: 1_800_000_000_000, lastRiseAt: nil)
    )

    defaults.set(record.propertyList, forKey: "record")

    XCTAssertEqual(StepCountRecord(propertyList: defaults.dictionary(forKey: "record")), record)
    let coverage = record.map["stepCoverage"] as? [String: Any]
    XCTAssertTrue(coverage?["lastRiseAt"] is NSNull)
    XCTAssertNil(StepCountRecord(propertyList: ["captureGenerationId": "generation"]))
    XCTAssertNil(StepCountRecord(propertyList: nil))
  }

  func testDiagnosticsNeverCarryCounts() throws {
    let clock = TestClock()
    let source = FakeStepCountSource()
    source.queryAnswer = StepCountReading(steps: 999, endDate: clock.now)
    let counter = StepCounter(source: source, permitted: { true }, clock: { clock.now })
    counter.start(generationId: "generation", startedAt: clock.now)
    let finalized = expectation(description: "finalized")
    counter.finalize { _ in finalized.fulfill() }
    wait(for: [finalized], timeout: 1)
    counter.stop()

    XCTAssertEqual(
      counter.diagnostics.compactMap { $0["event"] as? String },
      ["start", "finalize", "stop"]
    )
    for entry in counter.diagnostics {
      XCTAssertEqual(
        Set(entry.keys),
        [
          "at", "event", "sensor", "registered", "watchdogState", "sinceDeliveryMs", "sinceRiseMs",
          "flushCompletedMs", "replayOutcome", "evidenceSource", "reregistrations",
        ]
      )
      XCTAssertFalse(entry.values.contains { ($0 as? Int) == 999 })
    }
  }
}
