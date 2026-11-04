import XCTest

@testable import flutter_background_location_tracker

/// The journal lives in the host app's container, so each test scopes its rows
/// to a unique track and deletes them afterwards.
final class NativeLocationJournalTests: XCTestCase {
  private var journal: NativeLocationJournal!
  private var trackId = ""

  override func setUpWithError() throws {
    journal = NativeLocationJournal()
    _ = try journal.prepare()
    trackId = "journal-test-\(UUID().uuidString)"
  }

  override func tearDownWithError() throws {
    _ = try journal.deleteTrack(trackId: trackId)
  }

  private func event(_ index: Int) -> [String: Any] {
    [
      "eventId": "\(trackId)-\(index)",
      "trackId": trackId,
      "timestamp": NSNumber(value: Int64(1_784_534_400_000 + index * 1_000)),
      "lat": 0.001,
      "lon": 0.001 + Double(index) / 100_000,
      "motionEvidence": ["state": "moving", "confidence": 70],
    ]
  }

  func testAppendAllStoresACallbackInOrderAndReportsEachEvent() throws {
    let before = try journal.prepare()

    let results = try journal.appendAll([event(1), event(2), event(3)])

    XCTAssertEqual(results.count, 3)
    XCTAssertEqual(try results.map { try $0.get() }, [before + 1, before + 2, before + 3])
    let stored = try journal.pendingLocations()
      .filter { $0["trackId"] as? String == trackId }
    XCTAssertEqual(stored.compactMap { $0["eventId"] as? String }, [
      "\(trackId)-1", "\(trackId)-2", "\(trackId)-3",
    ])
    XCTAssertEqual(
      (stored.first?["motionEvidence"] as? [String: Any])?["state"] as? String,
      "moving"
    )
  }

  func testDuplicatesAndInvalidEventsFailOnlyThemselves() throws {
    _ = try journal.appendAll([event(1)])
    let before = try journal.prepare()
    var invalid = event(9)
    invalid["eventId"] = ""

    let results = try journal.appendAll([event(1), invalid, event(2)])

    // A duplicate identity is already durable: success without a new row.
    XCTAssertEqual(try results[0].get(), before)
    XCTAssertThrowsError(try results[1].get())
    XCTAssertEqual(try results[2].get(), before + 1)
  }

  func testSingleAppendMatchesTheBatchPath() throws {
    let before = try journal.prepare()

    XCTAssertEqual(try journal.append(event(1)), before + 1)
    XCTAssertEqual(try journal.append(event(1)), before + 1)
  }
}
