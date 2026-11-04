import Foundation

/// The route detail the host app records (`recordingDetail`, capability
/// `recording_detail_mode`): `full` keeps native diagnostics, `clean` keeps
/// none. Capture is the same in both.
///
/// Dart sends the detail with `initialize`. It is kept in UserDefaults, so a
/// relaunch that runs before Dart uses it too. Until Dart has sent one, the
/// detail is clean.
///
/// In clean detail the step counter keeps no diagnostics, and Core Location
/// error text is left out of status messages: only a fixed sentence with the
/// error's domain and code remains.
enum DiagnosticsMode {
  static let full = "full"
  static let clean = "clean"

  private static let key = "flutter_background_location.recording_detail"
  private static let lock = NSLock()
  private static var cached: Bool?

  /// Whether diagnostics are kept.
  static var isFull: Bool {
    lock.lock()
    defer { lock.unlock() }
    if let cached { return cached }
    let value = UserDefaults.standard.string(forKey: key) == full
    cached = value
    return value
  }

  /// Applies and keeps [detail] when it is `full` or `clean`, and returns
  /// it; any other value, or none, keeps the current detail and returns nil.
  @discardableResult
  static func apply(_ detail: Any?, defaults: UserDefaults = .standard) -> String? {
    guard let value = parse(detail) else { return nil }
    lock.lock()
    cached = value == full
    lock.unlock()
    defaults.set(value, forKey: key)
    return value
  }

  /// `full` or `clean`, or nil for anything else.
  static func parse(_ detail: Any?) -> String? {
    guard let value = detail as? String, value == full || value == clean else { return nil }
    return value
  }

  /// [error]'s own description in full detail; otherwise [message] with the
  /// error's domain and code.
  static func detail(_ message: String, _ error: Error, full: Bool = isFull) -> String {
    full ? error.localizedDescription : "\(message) (\(redactedErrorSummary(error)))."
  }
}
