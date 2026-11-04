import XCTest

@testable import flutter_background_location_tracker

final class MotionEvidenceWindowsTests: XCTestCase {
  func testCumulativeStepsNeedACadenceNotJustAPositiveTotal() {
    var window = StepCadenceWindow(startedAt: 0)

    // Three steps, then nothing for a minute, then three more.
    XCTAssertFalse(window.observe(totalSteps: 3, at: 5))
    XCTAssertFalse(window.observe(totalSteps: 6, at: 70))
    // Six steps within 30 s is movement.
    XCTAssertTrue(window.observe(totalSteps: 12, at: 80))
  }

  func testSustainedWalkingIsReportedAtMostEveryInterval() {
    var window = StepCadenceWindow(startedAt: 0)

    let reported = stride(from: 2.0, through: 40, by: 2).filter { time in
      window.observe(totalSteps: Int(time) * 2, at: time)
    }

    XCTAssertEqual(reported, [4, 14, 24, 34])
  }

  func testTheProbeBudgetSlidesInsteadOfResettingHourly() {
    var budget = RollingProbeBudget(window: 3_600)
    budget.record(start: 3_420, end: 3_600)

    XCTAssertFalse(budget.allows(at: 3_610, duration: 4, maximum: 180))
    XCTAssertEqual(budget.used(at: 7_024), 176, accuracy: 0.001)
    XCTAssertTrue(budget.allows(at: 7_030, duration: 4, maximum: 180))
    XCTAssertEqual(budget.used(at: 7_300), 0, accuracy: 0.001)
  }
}
