import CoreLocation
import XCTest

@testable import flutter_background_location_tracker

/// Lifecycle edges of the process-scoped service, driven through its
/// Core Location delegate with an isolated UserDefaults suite.
final class BackgroundLocationServiceTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "fbl-service-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  private func service(persistedLifecycle: String) -> BackgroundLocationService {
    defaults.set(persistedLifecycle, forKey: "flutter_background_location.lifecycle")
    defaults.set("route-1", forKey: "flutter_background_location.track_id")
    return BackgroundLocationService(userDefaults: defaults)
  }

  private func deny(_ service: BackgroundLocationService) {
    service.locationManager(CLLocationManager(), didFailWithError: CLError(.denied))
  }

  // REL-07: a late denial must not turn a paused route into a failure.
  func testLateDenialLeavesPausedRouteUnchanged() {
    let service = service(persistedLifecycle: "paused")
    deny(service)
    XCTAssertEqual(service.stateMap()["state"] as? String, "paused")
    XCTAssertEqual(defaults.string(forKey: "flutter_background_location.lifecycle"), "paused")
  }

  // REL-07: an interrupted route stays resumable after a late denial.
  func testLateDenialLeavesInterruptedRouteResumable() {
    let service = service(persistedLifecycle: "interrupted")
    deny(service)
    XCTAssertEqual(service.stateMap()["state"] as? String, "interrupted")
    XCTAssertEqual(
      defaults.string(forKey: "flutter_background_location.lifecycle"),
      "interrupted"
    )
  }

  // A temporarily unknown location changes nothing.
  func testLocationUnknownKeepsState() {
    let service = service(persistedLifecycle: "paused")
    service.locationManager(CLLocationManager(), didFailWithError: CLError(.locationUnknown))
    XCTAssertEqual(service.stateMap()["state"] as? String, "paused")
  }
}
