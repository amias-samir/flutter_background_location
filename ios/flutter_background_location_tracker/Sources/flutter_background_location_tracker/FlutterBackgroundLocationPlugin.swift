import Flutter
import Foundation
import UIKit

// Keep this public registration entry point available to both native package managers.
public final class FlutterBackgroundLocationPlugin: NSObject, FlutterPlugin {
  static let methodChannelName = "flutter_background_location/methods"
  static let locationChannelName = "flutter_background_location/location"
  static let activityChannelName = "flutter_background_location/activity"
  static let statusChannelName = "flutter_background_location/status"

  private let service = BackgroundLocationService()
  private let methodChannel: FlutterMethodChannel
  private let locationStreamHandler = FlutterBackgroundEventStreamHandler()
  private let activityStreamHandler = FlutterBackgroundEventStreamHandler()
  private let statusStreamHandler = FlutterBackgroundEventStreamHandler()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterBackgroundLocationPlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
  }

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: Self.methodChannelName,
      binaryMessenger: messenger
    )
    super.init()

    service.delegate = self
    statusStreamHandler.initialEventProvider = { [weak service] in
      service?.stateMap()
    }
    FlutterEventChannel(
      name: Self.locationChannelName,
      binaryMessenger: messenger
    ).setStreamHandler(locationStreamHandler)
    FlutterEventChannel(
      name: Self.activityChannelName,
      binaryMessenger: messenger
    ).setStreamHandler(activityStreamHandler)
    FlutterEventChannel(
      name: Self.statusChannelName,
      binaryMessenger: messenger
    ).setStreamHandler(statusStreamHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          result(
            FlutterError(
              code: "plugin_unavailable",
              message: "The iOS tracking plugin is no longer available.",
              details: nil
            ))
          return
        }
        self.handle(call, result: result)
      }
      return
    }

    let arguments = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "initialize":
        result(try service.initialize())
      case "requestPermissions":
        let background = (arguments["background"] as? Bool) ?? true
        let motion = (arguments["motion"] as? Bool) ?? true
        try service.requestPermissions(background: background, motion: motion) { permission in
          result(permission)
        }
      case "getPermissionStatus":
        result(service.permissionMap())
      case "getCapabilities":
        result(service.capabilitiesMap())
      case "startTracking":
        guard let trackId = arguments["trackId"] as? String else {
          throw BackgroundLocationServiceError.invalidTrackId
        }
        result(
          try service.start(
            trackId: trackId,
            configuration: trackingConfiguration(from: arguments)
          ))
      case "pauseTracking":
        result(try service.pause())
      case "resumeTracking":
        let suppliedTrackId = arguments["trackId"] as? String
        let suppliedConfiguration =
          hasConfiguration(in: arguments)
          ? trackingConfiguration(from: arguments)
          : nil
        result(
          try service.resume(
            trackId: suppliedTrackId,
            configuration: suppliedConfiguration
          ))
      case "stopTracking":
        result(service.stop(reason: arguments["reason"] as? String))
      case "isTracking":
        let state = service.stateMap()
        result(state["isTracking"] as? Bool ?? false)
      case "getState":
        result(service.stateMap())
      case "getLastLocation":
        result(service.lastLocationMap())
      case "getPendingLocations":
        result(try service.pendingLocations())
      case "acknowledgeLocations":
        guard let eventIds = arguments["eventIds"] as? [String] else {
          throw BackgroundLocationServiceError.invalidArguments(
            "acknowledgeLocations requires an eventIds string list."
          )
        }
        result(try service.acknowledgeLocations(eventIds: eventIds))
      case "updateConfig":
        result(service.update(configuration: trackingConfiguration(from: arguments)))
      case "openAppSettings":
        openAppSettings(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch let error as BackgroundLocationServiceError {
      result(
        FlutterError(
          code: error.code,
          message: error.localizedDescription,
          details: service.stateMap()
        ))
    } catch {
      result(
        FlutterError(
          code: "ios_error",
          message: error.localizedDescription,
          details: nil
        ))
    }
  }

  private func trackingConfiguration(from arguments: [String: Any]) -> TrackingConfiguration {
    if let nested = arguments["config"] as? [String: Any] {
      return TrackingConfiguration(dictionary: nested)
    }
    // Accept flattened configuration maps for compatibility with early clients.
    return TrackingConfiguration(dictionary: arguments)
  }

  private func hasConfiguration(in arguments: [String: Any]) -> Bool {
    if arguments["config"] is [String: Any] {
      return true
    }
    return arguments.keys.contains { key in
      key.hasSuffix("Ms") || key.hasSuffix("Meters") || key == "desiredAccuracy"
        || key == "activityType"
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString),
      UIApplication.shared.canOpenURL(url)
    else {
      result(false)
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      result(opened)
    }
  }
}

extension FlutterBackgroundLocationPlugin: BackgroundLocationServiceDelegate {
  func backgroundLocationService(
    _ service: BackgroundLocationService,
    didReceiveLocation event: [String: Any]
  ) {
    locationStreamHandler.send(event)
  }

  func backgroundLocationService(
    _ service: BackgroundLocationService,
    didReceiveActivity event: [String: Any]
  ) {
    activityStreamHandler.send(event)
  }

  func backgroundLocationService(
    _ service: BackgroundLocationService,
    didChangeStatus status: [String: Any]
  ) {
    statusStreamHandler.send(status)
  }
}
