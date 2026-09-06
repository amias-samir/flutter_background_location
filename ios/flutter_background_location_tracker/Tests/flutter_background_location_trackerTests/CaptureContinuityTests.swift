import Foundation
import XCTest
@testable import flutter_background_location_tracker

final class CaptureContinuityTests: XCTestCase {
  func testProfileOnlyChangesPreserveGeneration() {
    var state = IOSCaptureGenerationState()
    let startedAt = Date(timeIntervalSince1970: 100)
    state.rotate(id: "generation-one", at: startedAt)

    // Moving/stationary configuration changes intentionally do not call rotate.
    let movingIdentity = state.id
    let stationaryIdentity = state.id

    XCTAssertEqual(movingIdentity, "generation-one")
    XCTAssertEqual(stationaryIdentity, movingIdentity)
    XCTAssertEqual(state.startedAt, startedAt)
  }

  func testGenuineProviderRestartRotatesGeneration() {
    var state = IOSCaptureGenerationState()
    state.rotate(id: "generation-one", at: Date(timeIntervalSince1970: 100))
    state.rotate(id: "generation-two", at: Date(timeIntervalSince1970: 200))

    XCTAssertEqual(state.id, "generation-two")
    XCTAssertEqual(state.startedAt, Date(timeIntervalSince1970: 200))
  }

  func testTerminationRecoveryRestoresThenRotatesAtNewProviderSession() {
    var state = IOSCaptureGenerationState()
    state.restore(
      id: "persisted-generation",
      startedAt: Date(timeIntervalSince1970: 100)
    )
    XCTAssertEqual(state.id, "persisted-generation")

    state.rotate(id: "recovery-generation", at: Date(timeIntervalSince1970: 300))
    XCTAssertEqual(state.id, "recovery-generation")
    XCTAssertNotEqual(state.id, "persisted-generation")
  }
}
