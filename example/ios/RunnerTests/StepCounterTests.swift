import XCTest

@testable import flutter_background_location_tracker

/// Steps counted per capture generation.
final class StepCounterTests: XCTestCase {
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
    let flushed = expectation(description: "flush answers at once")
    counter.flush { flushed.fulfill() }
    wait(for: [flushed], timeout: 0.1)
  }
}
