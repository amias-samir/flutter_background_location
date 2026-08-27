import Flutter
import Foundation
import UIKit

// Keep this public registration entry point available to both native package managers.
public final class FlutterBackgroundLocationPlugin: NSObject, FlutterPlugin {
  static let methodChannelName = "flutter_background_location/methods"
  static let locationChannelName = "flutter_background_location/location"
  static let activityChannelName = "flutter_background_location/activity"
  static let statusChannelName = "flutter_background_location/status"

  // Core Location capture must outlive any Flutter engine or scene instance.
  // Recreating this object while a route is active stops CLLocationManager and
  // incorrectly turns a normal background transition into an interruption.
  private let service = BackgroundLocationService.shared
  private let methodChannel: FlutterMethodChannel
  private let locationStreamHandler = FlutterBackgroundEventStreamHandler()
  private let activityStreamHandler = FlutterBackgroundEventStreamHandler()
  private let statusStreamHandler = FlutterBackgroundEventStreamHandler()
  private let engineInstanceId = UUID().uuidString

  public static func register(with registrar: FlutterPluginRegistrar) {
    prepareTerminationRecovery()
    let instance = FlutterBackgroundLocationPlugin(messenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
  }

  /// Host AppDelegates that create Flutter engines lazily may call this from a
  /// Core Location launch path before attaching Flutter UI.
  public static func prepareTerminationRecovery() {
    let prepare = {
      BackgroundLocationService.shared.initialize { _ in }
    }
    if Thread.isMainThread {
      prepare()
    } else {
      DispatchQueue.main.async(execute: prepare)
    }
  }

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: Self.methodChannelName,
      binaryMessenger: messenger
    )
    super.init()

    service.addObserver(self)
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

  deinit {
    service.removeObserver(self)
    let engineId = engineInstanceId
    if Thread.isMainThread {
      NativeCommandCoordinator.shared.release(engineId: engineId, engineLeaseToken: nil)
    } else {
      DispatchQueue.main.async {
        NativeCommandCoordinator.shared.release(engineId: engineId, engineLeaseToken: nil)
      }
    }
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
        service.initialize { [weak self] outcome in
          self?.finish(result, outcome)
        }
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
      case "getProtocolInfo":
        result(protocolInfo())
      case "acquireCommandLease":
        acquireCommandLease(arguments: arguments, result: result)
      case "releaseCommandLease":
        NativeCommandCoordinator.shared.release(
          engineId: engineInstanceId,
          engineLeaseToken: arguments["engineLeaseToken"] as? String
        )
        result(true)
      case "startTrackingV2":
        executeLeasedCommand(arguments: arguments, result: result) { leasedResult in
          guard let trackId = arguments["trackId"] as? String else {
            leasedResult(FlutterError(code: "invalid_track_id", message: nil, details: nil))
            return
          }
          self.service.start(
            trackId: trackId,
            configuration: self.trackingConfiguration(from: arguments)
          ) { [weak self] outcome in self?.finish(leasedResult, outcome) }
        }
      case "pauseTrackingV2":
        executeLeasedCommand(arguments: arguments, result: result) { leasedResult in
          self.service.pause { [weak self] outcome in self?.finish(leasedResult, outcome) }
        }
      case "resumeTrackingV2":
        executeLeasedCommand(arguments: arguments, result: result) { leasedResult in
          let suppliedConfiguration = self.hasConfiguration(in: arguments)
            ? self.trackingConfiguration(from: arguments) : nil
          self.service.resume(
            trackId: arguments["trackId"] as? String,
            configuration: suppliedConfiguration
          ) { [weak self] outcome in self?.finish(leasedResult, outcome) }
        }
      case "stopTrackingV2":
        executeLeasedCommand(arguments: arguments, result: result) { leasedResult in
          self.service.stop(
            expectedTrackId: arguments["trackId"] as? String,
            reason: arguments["reason"] as? String
          ) { [weak self] outcome in self?.finish(leasedResult, outcome) }
        }
      case "updateConfigV2":
        executeLeasedCommand(arguments: arguments, result: result) { leasedResult in
          leasedResult(self.service.update(configuration: self.trackingConfiguration(from: arguments)))
        }
      case "startTracking":
        try guardLegacyCommand(result: result) {
          guard let trackId = arguments["trackId"] as? String else {
            throw BackgroundLocationServiceError.invalidTrackId
          }
          service.start(
            trackId: trackId,
            configuration: trackingConfiguration(from: arguments)
          ) { [weak self] outcome in
            self?.finish(result, outcome)
          }
        }
      case "pauseTracking":
        guardLegacyCommand(result: result) {
        service.pause { [weak self] outcome in
          self?.finish(result, outcome)
        }
        }
      case "resumeTracking":
        guardLegacyCommand(result: result) {
        let suppliedTrackId = arguments["trackId"] as? String
        let suppliedConfiguration =
          hasConfiguration(in: arguments)
          ? trackingConfiguration(from: arguments)
          : nil
        service.resume(
            trackId: suppliedTrackId,
            configuration: suppliedConfiguration
        ) { [weak self] outcome in
          self?.finish(result, outcome)
        }
        }
      case "stopTracking":
        guardLegacyCommand(result: result) {
        service.stop(
            expectedTrackId: arguments["trackId"] as? String,
            reason: arguments["reason"] as? String
        ) { [weak self] outcome in
          self?.finish(result, outcome)
        }
        }
      case "isTracking":
        let state = service.stateMap()
        result(state["isTracking"] as? Bool ?? false)
      case "getState":
        result(service.stateMap())
      case "getLastLocation":
        result(service.lastLocationMap())
      case "getPendingLocations":
        service.pendingLocations { [weak self] outcome in
          self?.finish(result, outcome)
        }
      case "getPendingLocationsPage":
        service.pendingLocationPage(
          cursor: arguments["cursor"] as? String,
          maxRecords: arguments["maxRecords"] as? Int ?? 100,
          maxEncodedBytes: arguments["maxEncodedBytes"] as? Int ?? 256 * 1_024
        ) { [weak self] outcome in
          self?.finish(result, outcome)
        }
      case "getNativeJournalDiagnostic":
        service.nativeJournalDiagnostic(
          performMaintenance: arguments["performMaintenance"] as? Bool ?? false
        ) { diagnostic in
          result(diagnostic)
        }
      case "acknowledgeLocations":
        guard let eventIds = arguments["eventIds"] as? [String] else {
          throw BackgroundLocationServiceError.invalidArguments(
            "acknowledgeLocations requires an eventIds string list."
          )
        }
        service.acknowledgeLocations(eventIds: eventIds) { [weak self] outcome in
          self?.finish(result, outcome)
        }
      case "clearNativeTrackData":
        guard let trackId = arguments["trackId"] as? String, !trackId.isEmpty else {
          throw BackgroundLocationServiceError.invalidTrackId
        }
        service.deletePendingLocations(trackId: trackId) { [weak self] outcome in
          self?.finish(result, outcome)
        }
      case "updateConfig":
        guardLegacyCommand(result: result) {
          result(service.update(configuration: trackingConfiguration(from: arguments)))
        }
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

  private func acquireCommandLease(arguments: [String: Any], result: @escaping FlutterResult) {
    guard let trackId = arguments["trackId"] as? String, !trackId.isEmpty,
      let sessionToken = arguments["sessionControlToken"] as? String, !sessionToken.isEmpty
    else {
      result(FlutterError(
        code: "native_command_lease_invalid",
        message: "A track ID and session-control token are required.",
        details: nil
      ))
      return
    }
    do {
      let lease = try NativeCommandCoordinator.shared.acquire(
        service: service,
        engineId: engineInstanceId,
        trackId: trackId,
        sessionControlToken: sessionToken
      )
      result([
        "engineLeaseToken": lease.engineLeaseToken,
        "commandRevision": service.nativeCommandRevision,
      ])
    } catch let rejection as NativeCommandCoordinator.Rejection {
      result(commandError(rejection))
    } catch {
      result(FlutterError(
        code: "native_state_persistence_failed",
        message: error.localizedDescription,
        details: redactedCommandState()
      ))
    }
  }

  private func guardLegacyCommand(result: @escaping FlutterResult, operation: () throws -> Void) rethrows {
    if NativeCommandCoordinator.shared.hasLease {
      result(FlutterError(
        code: "native_command_lease_conflict",
        message: "A negotiated command lease owns native lifecycle changes.",
        details: redactedCommandState()
      ))
      return
    }
    try operation()
  }

  private func executeLeasedCommand(
    arguments: [String: Any],
    result: @escaping FlutterResult,
    operation: (@escaping FlutterResult) -> Void
  ) {
    let permit: NativeCommandCoordinator.Permit
    do {
      permit = try NativeCommandCoordinator.shared.begin(
        service: service,
        engineId: engineInstanceId,
        arguments: arguments
      )
    } catch let rejection as NativeCommandCoordinator.Rejection {
      result(commandError(rejection))
      return
    } catch {
      result(FlutterError(code: "ios_error", message: error.localizedDescription, details: nil))
      return
    }
    if permit.replayed {
      var state = service.stateMap()
      state["commandRevision"] = permit.revision
      result(state)
      return
    }
    operation { [weak self] value in
      guard let self else { return }
      if value is FlutterError {
        NativeCommandCoordinator.shared.fail(permit)
        result(value)
        return
      }
      do {
        let revision = try NativeCommandCoordinator.shared.complete(service: self.service, permit: permit)
        var response = value as? [String: Any] ?? ["value": value as Any]
        response["commandRevision"] = revision
        result(response)
      } catch let rejection as NativeCommandCoordinator.Rejection {
        result(self.commandError(rejection))
      } catch {
        result(FlutterError(
          code: "native_state_persistence_failed",
          message: error.localizedDescription,
          details: self.redactedCommandState()
        ))
      }
    }
  }

  private func commandError(_ rejection: NativeCommandCoordinator.Rejection) -> FlutterError {
    FlutterError(code: rejection.code, message: rejection.message, details: redactedCommandState())
  }

  private func redactedCommandState() -> [String: Any] {
    let state = service.stateMap()
    return [
      "state": state["state"] as Any,
      "isTracking": state["isTracking"] as Any,
      "isPaused": state["isPaused"] as Any,
      "commandRevision": service.nativeCommandRevision,
    ]
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
        || key == "activityType" || key == "iosTerminationRecoveryMode"
    }
  }

  private func finish<T>(_ result: @escaping FlutterResult, _ outcome: Result<T, Error>) {
    switch outcome {
    case .success(let value):
      result(value)
    case .failure(let error as BackgroundLocationServiceError):
      result(
        FlutterError(
          code: error.code,
          message: error.localizedDescription,
          details: service.stateMap()
        ))
    case .failure(let error):
      result(
        FlutterError(
          code: "ios_error",
          message: error.localizedDescription,
          details: nil
        ))
    }
  }

  private func protocolInfo() -> [String: Any] {
    [
      "version": 2,
      "capabilityCodes": [
        "paused_stop_expected_track",
        "staged_permission_requests",
        "active_prerequisite_monitor",
        "ios_serial_journal_queue",
        "paged_journal",
        "byte_bounded_journal",
        "native_journal_diagnostics",
        "track_scoped_native_clear"
        ,"command_lease",
        "ios_significant_change_recovery"
      ],
    ]
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
