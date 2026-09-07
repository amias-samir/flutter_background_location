import Foundation

/// Pure capture-generation state kept separate from Core Location so profile
/// changes cannot accidentally rotate the native continuity identity.
struct IOSCaptureGenerationState {
  private(set) var id: String?
  private(set) var startedAt: Date?

  mutating func rotate(id newID: String = UUID().uuidString, at date: Date = Date()) {
    id = newID
    startedAt = date
  }

  mutating func restore(id restoredID: String?, startedAt restoredDate: Date?) {
    id = restoredID
    startedAt = restoredDate
  }

  mutating func clear() {
    id = nil
    startedAt = nil
  }
}
