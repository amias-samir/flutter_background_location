import Flutter
import Foundation

// Shared by the CocoaPods and Swift Package Manager integration paths.
/// A small, independently retained stream handler is needed for each EventChannel.
final class FlutterBackgroundEventStreamHandler: NSObject, FlutterStreamHandler {
  var initialEventProvider: (() -> Any?)?

  private var eventSink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    if let initialEvent = initialEventProvider?() {
      events(initialEvent)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  func send(_ event: Any) {
    if Thread.isMainThread {
      eventSink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(event)
      }
    }
  }
}
