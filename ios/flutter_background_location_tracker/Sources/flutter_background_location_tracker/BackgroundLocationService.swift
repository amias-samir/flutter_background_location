import CoreLocation
import CoreMotion
import Foundation

protocol BackgroundLocationServiceDelegate: AnyObject {
  func backgroundLocationService(
    _ service: BackgroundLocationService,
    didReceiveLocation event: [String: Any]
  )
  func backgroundLocationService(
    _ service: BackgroundLocationService,
    didReceiveActivity event: [String: Any]
  )
  func backgroundLocationService(
    _ service: BackgroundLocationService,
    didChangeStatus status: [String: Any]
  )
}

enum BackgroundLocationServiceError: LocalizedError {
  case alreadyTracking
  case invalidTrackId
  case invalidState(String)
  case locationServicesDisabled
  case locationPermissionDenied
  case backgroundPermissionRequired
  case missingUsageDescription(String)
  case backgroundModeMissing
  case permissionRequestInProgress
  case invalidArguments(String)
  case locationJournalCapacity(current: Int, maximum: Int)
  case locationJournalFailure(String)

  var code: String {
    switch self {
    case .alreadyTracking: return "already_tracking"
    case .invalidTrackId: return "invalid_track_id"
    case .invalidState: return "invalid_state"
    case .locationServicesDisabled: return "location_services_disabled"
    case .locationPermissionDenied: return "location_permission_denied"
    case .backgroundPermissionRequired: return "background_permission_required"
    case .missingUsageDescription: return "missing_usage_description"
    case .backgroundModeMissing: return "background_mode_missing"
    case .permissionRequestInProgress: return "permission_request_in_progress"
    case .invalidArguments: return "invalid_arguments"
    case .locationJournalCapacity: return "location_journal_capacity"
    case .locationJournalFailure: return "location_journal_failure"
    }
  }

  var errorDescription: String? {
    switch self {
    case .alreadyTracking:
      return "Location tracking is already active."
    case .invalidTrackId:
      return "startTracking requires a non-empty trackId."
    case .invalidState(let message):
      return message
    case .locationServicesDisabled:
      return "Location Services are disabled."
    case .locationPermissionDenied:
      return "Location permission is denied or restricted."
    case .backgroundPermissionRequired:
      return "Always location permission is required for background tracking."
    case .missingUsageDescription(let key):
      return "The host app Info.plist must define \(key)."
    case .backgroundModeMissing:
      return "The host app must enable the Location updates background mode."
    case .permissionRequestInProgress:
      return "A location permission request is already in progress."
    case .invalidArguments(let message):
      return message
    case .locationJournalCapacity(let current, let maximum):
      return "The durable location journal is full (\(current)/\(maximum) pending fixes)."
    case .locationJournalFailure(let message):
      return message
    }
  }
}

private enum TrackingLifecycle: String {
  case idle
  case starting
  case tracking
  case paused
  case stopping
  case interrupted
  case failed
}

private enum TrackingProfile: String {
  case idle
  case moving
  case stationary
  case paused
}

final class BackgroundLocationService: NSObject, CLLocationManagerDelegate {
  static let shared = BackgroundLocationService()

  weak var delegate: BackgroundLocationServiceDelegate?

  private enum PersistenceKey {
    static let lifecycle = "flutter_background_location.lifecycle"
    static let trackId = "flutter_background_location.track_id"
    static let configuration = "flutter_background_location.configuration"
  }

  private let locationManager = CLLocationManager()
  private let userDefaults: UserDefaults
  private let locationJournal: NativeLocationJournal

  private var motionManager: CMMotionActivityManager?
  private var motionPermissionProbe: CMMotionActivityManager?
  private var pendingPermissionResult: (([String: Any]) -> Void)?
  private var pendingPermissionWantsMotion = false
  private var stationaryTransitionWorkItem: DispatchWorkItem?

  private var lifecycle: TrackingLifecycle = .idle
  private var profile: TrackingProfile = .idle
  private var trackId: String?
  private var configuration = TrackingConfiguration.defaults
  private var lastLocationEvent: [String: Any]?
  private var lastActivityEvent: [String: Any]?
  private var lastEmittedLocation: CLLocation?
  private var lastReliableLocation: CLLocation?
  private var stationaryReferenceLocation: CLLocation?
  private var stationaryCandidateLocation: CLLocation?
  private var stationaryCandidateMaximumDisplacement = 0.0
  private var stationaryCandidateHasFollowUpFix = false
  private var movingEvidence = 0
  private var journalPendingCount: Int?
  private var journalFailureMessage: String?
  // Stored as AnyObject so this package can keep its iOS 13 deployment target
  // while using CLBackgroundActivitySession on iOS 17 and later.
  private var backgroundActivitySession: AnyObject?

  init(
    userDefaults: UserDefaults = .standard,
    locationJournal: NativeLocationJournal = NativeLocationJournal()
  ) {
    self.userDefaults = userDefaults
    self.locationJournal = locationJournal
    super.init()
    locationManager.delegate = self
    restorePersistedState()
  }

  func initialize() throws -> [String: Any] {
    do {
      journalPendingCount = try locationJournal.prepare()
      journalFailureMessage = nil
    } catch {
      throw failLocationJournal(error)
    }
    emitStatus(message: lifecycle == .interrupted ? "previous_session_interrupted" : nil)
    return stateMap()
  }

  func requestPermissions(
    background: Bool,
    motion: Bool,
    completion: @escaping ([String: Any]) -> Void
  ) throws {
    if pendingPermissionResult != nil {
      throw BackgroundLocationServiceError.permissionRequestInProgress
    }

    switch currentAuthorizationStatus() {
    case .notDetermined:
      try requireUsageDescription("NSLocationWhenInUseUsageDescription")
      pendingPermissionResult = completion
      pendingPermissionWantsMotion = motion
      locationManager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse where background:
      try requireUsageDescription("NSLocationAlwaysAndWhenInUseUsageDescription")
      pendingPermissionResult = completion
      pendingPermissionWantsMotion = motion
      locationManager.requestAlwaysAuthorization()
    case .denied, .restricted:
      completion(permissionMap())
    default:
      if motion {
        requestMotionAuthorizationIfPossible()
      }
      completion(permissionMap())
    }
  }

  func permissionMap() -> [String: Any] {
    let authorization = currentAuthorizationStatus()
    let authorized = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
    let motionStatus = CMMotionActivityManager.authorizationStatus()

    let activityGranted = motionStatus == .authorized
    let notificationsGranted = true
    let serviceEnabled = CLLocationManager.locationServicesEnabled()
    let preciseLocation = authorized && hasPreciseLocationAuthorization()
    let requiresSettings =
      !serviceEnabled || authorization == .denied
      || authorization == .restricted || (authorized && !preciseLocation)
    let canRequestBackground =
      (authorization == .notDetermined || authorization == .authorizedWhenInUse)
      && hasUsageDescription("NSLocationAlwaysAndWhenInUseUsageDescription")

    var permissions: [String: Any] = [
      "platform": "ios",
      "location": publicLocationPermission(authorization),
      "locationAuthorizationStatus": locationAuthorizationStatus(authorization),
      "locationServicesEnabled": serviceEnabled,
      "locationServiceEnabled": serviceEnabled,
      "preciseLocation": preciseLocation,
      "backgroundLocation": authorization == .authorizedAlways,
      "backgroundModeConfigured": hasLocationBackgroundMode(),
      "activityRecognition": activityGranted,
      "activityRecognitionGranted": activityGranted,
      "motionAuthorization": motionAuthorizationStatus(motionStatus),
      "notifications": notificationsGranted,
      "notificationGranted": notificationsGranted,
      "canRequestBackground": canRequestBackground,
      "requiresSettings": requiresSettings,
    ]
    if let message = permissionMessage(
      authorization: authorization,
      serviceEnabled: serviceEnabled,
      preciseLocation: preciseLocation,
      canRequestBackground: canRequestBackground
    ) {
      permissions["message"] = message
    }
    return permissions
  }

  func capabilitiesMap() -> [String: Any] {
    let mockDetectionAvailable: Bool
    if #available(iOS 15.0, *) {
      mockDetectionAvailable = true
    } else {
      mockDetectionAvailable = false
    }

    return [
      "platform": "ios",
      "backgroundTracking": true,
      "backgroundModeConfigured": hasLocationBackgroundMode(),
      "activityRecognition": CMMotionActivityManager.isActivityAvailable(),
      "mockDetection": mockDetectionAvailable,
      "mockDetectionAvailable": mockDetectionAvailable,
      "pauseResume": true,
      "adaptiveSampling": true,
      "durableNativeHandoff": true,
      "nativeJournalCapacity": NativeLocationJournal.maximumPendingEvents,
      "terminatedRecovery": false,
      "motorizedTwoWheelerDetection": false,
    ]
  }

  func start(trackId: String, configuration: TrackingConfiguration) throws -> [String: Any] {
    guard lifecycle != .tracking && lifecycle != .starting else {
      throw BackgroundLocationServiceError.alreadyTracking
    }
    guard !trackId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw BackgroundLocationServiceError.invalidTrackId
    }

    try validateTrackingPreconditions(configuration)
    try prepareJournalForCapture()

    stationaryTransitionWorkItem?.cancel()
    stationaryTransitionWorkItem = nil
    movingEvidence = 0
    lastEmittedLocation = nil
    lastReliableLocation = nil
    stationaryReferenceLocation = nil
    resetStationaryCandidate()
    if self.trackId != trackId {
      lastLocationEvent = nil
      lastActivityEvent = nil
    }
    self.trackId = trackId
    self.configuration = configuration
    lifecycle = .starting
    profile = .moving
    persistState()
    emitStatus()

    configureLocationManager(for: .moving)
    startBackgroundActivitySessionIfNeeded()
    startMotionUpdatesIfPossible()
    locationManager.startUpdatingLocation()

    lifecycle = .tracking
    persistState()
    emitStatus()
    return stateMap()
  }

  func pause() throws -> [String: Any] {
    if lifecycle == .paused {
      return stateMap()
    }
    guard lifecycle == .tracking || lifecycle == .starting else {
      throw BackgroundLocationServiceError.invalidState(
        "pauseTracking can only be called while tracking is active."
      )
    }

    stopNativeUpdates()
    lifecycle = .paused
    profile = .paused
    persistState()
    emitStatus()
    return stateMap()
  }

  func resume(
    trackId suppliedTrackId: String?,
    configuration suppliedConfiguration: TrackingConfiguration?
  ) throws -> [String: Any] {
    guard lifecycle == .paused || lifecycle == .interrupted else {
      throw BackgroundLocationServiceError.invalidState(
        "resumeTracking requires a paused or interrupted track."
      )
    }
    guard let resumedTrackId = suppliedTrackId ?? trackId else {
      throw BackgroundLocationServiceError.invalidTrackId
    }
    return try start(
      trackId: resumedTrackId,
      configuration: suppliedConfiguration ?? configuration
    )
  }

  func stop(reason: String?) -> [String: Any] {
    guard lifecycle != .idle else {
      return stateMap()
    }

    lifecycle = .stopping
    emitStatus(message: reason)
    stopNativeUpdates()
    lifecycle = .idle
    profile = .idle
    trackId = nil
    clearPersistedSession()
    emitStatus(message: reason)
    return stateMap()
  }

  func update(configuration: TrackingConfiguration) -> [String: Any] {
    self.configuration = configuration
    if lifecycle == .tracking {
      configureLocationManager(for: profile)
      if configuration.allowBackgroundLocationUpdates {
        startBackgroundActivitySessionIfNeeded()
      } else {
        stopBackgroundActivitySession()
      }
    }
    persistState()
    emitStatus(message: "configuration_updated")
    return stateMap()
  }

  func stateMap(message: String? = nil) -> [String: Any] {
    let motionState: String
    switch profile {
    case .stationary:
      motionState = "stationary"
    case .moving where lifecycle == .tracking || lifecycle == .starting:
      motionState = "moving"
    default:
      motionState = "unknown"
    }
    let locationServicesEnabled = CLLocationManager.locationServicesEnabled()
    var state: [String: Any] = [
      "platform": "ios",
      "state": lifecycle.rawValue,
      "lifecycle": lifecycle.rawValue,
      "isTracking": lifecycle == .tracking || lifecycle == .starting,
      "isPaused": lifecycle == .paused,
      "nativeServiceActive": lifecycle == .tracking || lifecycle == .starting,
      "backgroundActivitySessionActive": backgroundActivitySession != nil,
      "trackingProfile": profile.rawValue,
      "samplingProfile": profile == .stationary ? "stationary" : "moving",
      "batteryMode": profile == .stationary ? "stationary" : "moving",
      "motionState": motionState,
      "mockDetectionAvailable": isMockDetectionAvailable,
      "locationServicesEnabled": locationServicesEnabled,
      "locationServiceEnabled": locationServicesEnabled,
      "locationJournalHealthy": journalPendingCount != nil && journalFailureMessage == nil,
      "locationJournalCapacity": NativeLocationJournal.maximumPendingEvents,
      "timestamp": epochMilliseconds(Date()),
    ]
    if let journalPendingCount {
      state["pendingLocationCount"] = journalPendingCount
    }
    if let journalFailureMessage {
      state["locationJournalError"] = journalFailureMessage
    }
    if let trackId {
      state["trackId"] = trackId
    }
    if let lastLocationEvent {
      state["lastLocation"] = lastLocationEvent
      state["lastPointAt"] = lastLocationEvent["timestamp"]
    }
    if let lastActivityEvent {
      state["lastActivity"] = lastActivityEvent
    }
    if let message {
      state["message"] = message
    }
    return state
  }

  func lastLocationMap() -> [String: Any]? {
    lastLocationEvent
  }

  func pendingLocations() throws -> [[String: Any]] {
    do {
      let events = try locationJournal.pendingLocations()
      journalPendingCount = events.count
      journalFailureMessage = nil
      return events
    } catch {
      throw failLocationJournal(error)
    }
  }

  func acknowledgeLocations(eventIds: [String]) throws -> [String: Any] {
    do {
      let acknowledgement = try locationJournal.acknowledge(eventIds: eventIds)
      journalPendingCount = acknowledgement.remaining
      journalFailureMessage = nil
      return [
        "acknowledged": acknowledgement.deleted,
        "remaining": acknowledgement.remaining,
      ]
    } catch {
      throw failLocationJournal(error)
    }
  }

  private func validateTrackingPreconditions(_ configuration: TrackingConfiguration) throws {
    guard CLLocationManager.locationServicesEnabled() else {
      throw BackgroundLocationServiceError.locationServicesDisabled
    }
    let authorization = currentAuthorizationStatus()
    guard
      authorization != .denied && authorization != .restricted && authorization != .notDetermined
    else {
      throw BackgroundLocationServiceError.locationPermissionDenied
    }
    if configuration.requireAlwaysAuthorization && authorization != .authorizedAlways {
      throw BackgroundLocationServiceError.backgroundPermissionRequired
    }
    if configuration.allowBackgroundLocationUpdates {
      try requireUsageDescription("NSLocationAlwaysAndWhenInUseUsageDescription")
      guard hasLocationBackgroundMode() else {
        throw BackgroundLocationServiceError.backgroundModeMissing
      }
    }
  }

  private func prepareJournalForCapture() throws {
    do {
      journalPendingCount = try locationJournal.ensureCapacityForCapture()
      journalFailureMessage = nil
    } catch {
      throw failLocationJournal(error)
    }
  }

  @discardableResult
  private func failLocationJournal(_ error: Error) -> BackgroundLocationServiceError {
    let serviceError: BackgroundLocationServiceError
    if let journalError = error as? NativeLocationJournalError,
      case .capacity(let current, let maximum) = journalError
    {
      serviceError = .locationJournalCapacity(current: current, maximum: maximum)
    } else {
      serviceError = .locationJournalFailure(
        error.localizedDescription.isEmpty
          ? "The durable location journal failed."
          : error.localizedDescription
      )
    }

    journalFailureMessage = serviceError.localizedDescription
    if lifecycle == .tracking || lifecycle == .starting {
      stopNativeUpdates()
    }
    lifecycle = .failed
    profile = .paused
    if trackId != nil {
      persistState()
    }
    emitStatus(message: serviceError.localizedDescription)
    return serviceError
  }

  private func configureLocationManager(for profile: TrackingProfile) {
    let useStationaryProfile = profile == .stationary
    locationManager.desiredAccuracy =
      useStationaryProfile
      ? configuration.stationaryDesiredAccuracy
      : configuration.movingDesiredAccuracy
    locationManager.distanceFilter =
      useStationaryProfile
      ? configuration.stationaryDistanceFilterMeters
      : configuration.movingDistanceFilterMeters
    locationManager.activityType = configuration.activityType
    // Core Location's automatic pause can suspend the app before Core Motion
    // has a chance to restore the moving profile. Keep the stream alive and
    // obtain stationary savings from accuracy, distance, and event throttling.
    locationManager.pausesLocationUpdatesAutomatically = false
    locationManager.allowsBackgroundLocationUpdates = configuration.allowBackgroundLocationUpdates
    if #available(iOS 11.0, *) {
      locationManager.showsBackgroundLocationIndicator =
        configuration.allowBackgroundLocationUpdates
        && configuration.showBackgroundLocationIndicator
    }
  }

  private func startMotionUpdatesIfPossible() {
    guard CMMotionActivityManager.isActivityAvailable() else {
      emitStatus(message: "motion_activity_unavailable")
      return
    }
    guard CMMotionActivityManager.authorizationStatus() != .denied,
      CMMotionActivityManager.authorizationStatus() != .restricted
    else {
      emitStatus(message: "motion_permission_unavailable")
      return
    }
    guard Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil else {
      emitStatus(message: "motion_usage_description_missing")
      return
    }

    let manager = CMMotionActivityManager()
    motionManager = manager
    manager.startActivityUpdates(to: .main) { [weak self] activity in
      guard let self, let activity else { return }
      self.handle(activity)
    }
  }

  private func requestMotionAuthorizationIfPossible() {
    guard CMMotionActivityManager.isActivityAvailable(),
      CMMotionActivityManager.authorizationStatus() == .notDetermined,
      Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil
    else {
      return
    }

    let probe = CMMotionActivityManager()
    motionPermissionProbe = probe
    probe.queryActivityStarting(
      from: Date(timeIntervalSinceNow: -60),
      to: Date(),
      to: .main
    ) { [weak self] _, _ in
      self?.motionPermissionProbe = nil
    }
  }

  private func stopNativeUpdates() {
    locationManager.stopUpdatingLocation()
    locationManager.allowsBackgroundLocationUpdates = false
    if #available(iOS 11.0, *) {
      locationManager.showsBackgroundLocationIndicator = false
    }
    stopBackgroundActivitySession()
    motionManager?.stopActivityUpdates()
    motionManager = nil
    stationaryTransitionWorkItem?.cancel()
    stationaryTransitionWorkItem = nil
    movingEvidence = 0
    lastEmittedLocation = nil
    lastReliableLocation = nil
    stationaryReferenceLocation = nil
    resetStationaryCandidate()
  }

  private func startBackgroundActivitySessionIfNeeded() {
    guard configuration.allowBackgroundLocationUpdates,
      backgroundActivitySession == nil
    else {
      return
    }
    if #available(iOS 17.0, *) {
      backgroundActivitySession = CLBackgroundActivitySession()
    }
  }

  private func stopBackgroundActivitySession() {
    if #available(iOS 17.0, *),
      let session = backgroundActivitySession as? CLBackgroundActivitySession
    {
      session.invalidate()
    }
    backgroundActivitySession = nil
  }

  private func handle(_ activity: CMMotionActivity) {
    let event = activityMap(activity)
    lastActivityEvent = event
    delegate?.backgroundLocationService(self, didReceiveActivity: event)

    let type = event["type"] as? String ?? "unknown"
    let confidence = event["confidence"] as? Int ?? 0

    if type == "stationary" && confidence >= configuration.stationaryConfidenceThreshold {
      movingEvidence = 0
      scheduleStationaryTransition()
      return
    }

    stationaryTransitionWorkItem?.cancel()
    stationaryTransitionWorkItem = nil
    resetStationaryCandidate()
    guard type != "stationary", type != "unknown",
      confidence >= configuration.movingConfidenceThreshold
    else {
      movingEvidence = 0
      return
    }

    movingEvidence += 1
    if movingEvidence >= configuration.movingConfirmationCount {
      movingEvidence = 0
      transition(to: .moving)
    }
  }

  private func scheduleStationaryTransition() {
    guard profile != .stationary, stationaryTransitionWorkItem == nil else { return }

    stationaryCandidateLocation = lastReliableLocation
    stationaryCandidateMaximumDisplacement = 0
    stationaryCandidateHasFollowUpFix = false

    let workItem = DispatchWorkItem { [weak self] in
      guard let self,
        self.lifecycle == .tracking,
        self.lastActivityEvent?["type"] as? String == "stationary"
      else {
        return
      }
      self.stationaryTransitionWorkItem = nil
      guard self.hasLowStationaryDisplacementEvidence() else {
        self.resetStationaryCandidate()
        self.emitStatus(message: "stationary_entry_rejected_gps_evidence")
        return
      }
      self.transition(to: .stationary)
    }
    stationaryTransitionWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + configuration.stationaryTimeoutMs / 1_000,
      execute: workItem
    )
  }

  private func transition(to newProfile: TrackingProfile) {
    guard lifecycle == .tracking, profile != newProfile else { return }
    stationaryReferenceLocation = newProfile == .stationary ? lastEmittedLocation : nil
    resetStationaryCandidate()
    profile = newProfile
    lastEmittedLocation = nil
    configureLocationManager(for: newProfile)
    persistState()
    emitStatus(message: "tracking_profile_changed")
  }

  private func shouldEmit(_ location: CLLocation) -> Bool {
    guard location.horizontalAccuracy >= 0 else { return false }
    guard let previous = lastEmittedLocation else { return true }
    guard location.timestamp >= previous.timestamp else { return false }

    let interval =
      profile == .stationary
      ? configuration.stationaryIntervalMs
      : configuration.movingIntervalMs
    let distance =
      profile == .stationary
      ? configuration.stationaryDistanceFilterMeters
      : configuration.movingDistanceFilterMeters
    let elapsedMs = location.timestamp.timeIntervalSince(previous.timestamp) * 1_000
    return elapsedMs >= interval || location.distance(from: previous) >= distance
  }

  private func shouldExitStationary(for location: CLLocation) -> Bool {
    guard profile == .stationary,
      location.horizontalAccuracy >= 0,
      let reference = stationaryReferenceLocation,
      reference.horizontalAccuracy >= 0,
      location.timestamp >= reference.timestamp
    else {
      return false
    }
    return location.distance(from: reference)
      >= configuration.stationaryProbeDisplacementMeters
  }

  private func recordStationaryCandidateEvidence(_ location: CLLocation) {
    guard location.horizontalAccuracy >= 0,
      location.horizontalAccuracy <= configuration.maximumAcceptedAccuracyMeters
    else {
      return
    }
    lastReliableLocation = location
    guard stationaryTransitionWorkItem != nil else { return }
    guard let candidate = stationaryCandidateLocation else {
      stationaryCandidateLocation = location
      return
    }
    guard location.timestamp > candidate.timestamp else { return }
    stationaryCandidateHasFollowUpFix = true
    stationaryCandidateMaximumDisplacement = max(
      stationaryCandidateMaximumDisplacement,
      location.distance(from: candidate)
    )
  }

  private func hasLowStationaryDisplacementEvidence() -> Bool {
    stationaryCandidateLocation != nil
      && stationaryCandidateHasFollowUpFix
      && stationaryCandidateMaximumDisplacement
        < configuration.stationaryProbeDisplacementMeters
  }

  private func resetStationaryCandidate() {
    stationaryCandidateLocation = nil
    stationaryCandidateMaximumDisplacement = 0
    stationaryCandidateHasFollowUpFix = false
  }

  private func locationMap(_ location: CLLocation) -> [String: Any] {
    var event: [String: Any] = [
      "eventId": UUID().uuidString,
      "lat": location.coordinate.latitude,
      "lon": location.coordinate.longitude,
      "altitude": location.altitude,
      "accuracy": location.horizontalAccuracy,
      "verticalAccuracy": location.verticalAccuracy,
      "heading": location.course,
      "speed": location.speed,
      "timestamp": epochMilliseconds(location.timestamp),
      "trackingProfile": profile.rawValue,
      "samplingProfile": profile == .stationary ? "stationary" : "moving",
      "batteryMode": profile == .stationary ? "stationary" : "moving",
      "motionState": profile == .stationary ? "stationary" : "moving",
      "provider": "core_location",
    ]
    if #available(iOS 13.4, *) {
      event["headingAccuracy"] = location.courseAccuracy
      event["speedAccuracy"] = location.speedAccuracy
    } else {
      event["headingAccuracy"] = -1.0
      event["speedAccuracy"] = -1.0
    }
    if let trackId {
      event["trackId"] = trackId
    }
    if let activity = lastActivityEvent {
      event["activityType"] = activity["type"]
      event["activityConfidence"] = activity["confidence"]
      event["activityTimestamp"] = activity["timestamp"]
    } else {
      event["activityType"] = "unknown"
      event["activityConfidence"] = 0
    }

    if #available(iOS 15.0, *) {
      let source = location.sourceInformation
      let mocked = source?.isSimulatedBySoftware ?? false
      event["isMocked"] = mocked
      event["mockDetectionAvailable"] = source != nil
      event["mockStatus"] =
        source == nil
        ? "unavailable"
        : (mocked ? "detected" : "not_detected")
      if mocked {
        event["mockEvidence"] = "ios_simulated_by_software"
      }
      if let source {
        event["isProducedByAccessory"] = source.isProducedByAccessory
      }
    } else {
      event["isMocked"] = false
      event["mockDetectionAvailable"] = false
      event["mockStatus"] = "unavailable"
    }
    return event
  }

  private func activityMap(_ activity: CMMotionActivity) -> [String: Any] {
    let type: String
    if activity.automotive {
      type = "automotive"
    } else if activity.cycling {
      type = "cycling"
    } else if activity.running {
      type = "running"
    } else if activity.walking {
      type = "walking"
    } else if activity.stationary {
      type = "stationary"
    } else {
      type = "unknown"
    }

    var event: [String: Any] = [
      "type": type,
      "rawType": type,
      "confidence": motionConfidence(activity.confidence),
      "timestamp": epochMilliseconds(activity.startDate),
      "stationary": activity.stationary,
      "walking": activity.walking,
      "running": activity.running,
      "cycling": activity.cycling,
      "automotive": activity.automotive,
      "unknown": activity.unknown,
    ]
    if let trackId {
      event["trackId"] = trackId
    }
    return event
  }

  private func motionConfidence(_ confidence: CMMotionActivityConfidence) -> Int {
    switch confidence {
    case .low: return 33
    case .medium: return 67
    case .high: return 100
    @unknown default: return 0
    }
  }

  private func emitStatus(message: String? = nil) {
    delegate?.backgroundLocationService(self, didChangeStatus: stateMap(message: message))
  }

  private func currentAuthorizationStatus() -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return locationManager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  private func hasPreciseLocationAuthorization() -> Bool {
    if #available(iOS 14.0, *) {
      return locationManager.accuracyAuthorization == .fullAccuracy
    }
    return true
  }

  private var isMockDetectionAvailable: Bool {
    if #available(iOS 15.0, *) {
      return true
    }
    return false
  }

  private func publicLocationPermission(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whileInUse"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .notDetermined: return "unknown"
    @unknown default: return "unknown"
    }
  }

  private func locationAuthorizationStatus(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorizedAlways: return "always"
    case .authorizedWhenInUse: return "whileInUse"
    @unknown default: return "unknown"
    }
  }

  private func motionAuthorizationStatus(_ status: CMAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "notDetermined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
  }

  private func requireUsageDescription(_ key: String) throws {
    guard hasUsageDescription(key) else {
      throw BackgroundLocationServiceError.missingUsageDescription(key)
    }
  }

  private func hasUsageDescription(_ key: String) -> Bool {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
      return false
    }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func permissionMessage(
    authorization: CLAuthorizationStatus,
    serviceEnabled: Bool,
    preciseLocation: Bool,
    canRequestBackground: Bool
  ) -> String? {
    if !serviceEnabled {
      return "Location Services are disabled. Enable them in Settings."
    }
    if authorization == .denied || authorization == .restricted {
      return "Location access is unavailable. Review the app's location permission in Settings."
    }
    if authorization == .notDetermined {
      return "Location permission has not been requested."
    }
    if authorization == .authorizedWhenInUse {
      return canRequestBackground
        ? "Always location access is required. Explain background tracking, then request permission again."
        : "Add NSLocationAlwaysAndWhenInUseUsageDescription before requesting Always access."
    }
    if !preciseLocation {
      return "Precise Location must be enabled for route tracking."
    }
    return nil
  }

  private func hasLocationBackgroundMode() -> Bool {
    guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
    else {
      return false
    }
    return modes.contains("location")
  }

  private func persistState() {
    userDefaults.set(lifecycle.rawValue, forKey: PersistenceKey.lifecycle)
    userDefaults.set(trackId, forKey: PersistenceKey.trackId)
    userDefaults.set(configuration.dictionary, forKey: PersistenceKey.configuration)
  }

  private func restorePersistedState() {
    if let savedConfiguration = userDefaults.dictionary(forKey: PersistenceKey.configuration) {
      configuration = TrackingConfiguration(dictionary: savedConfiguration)
    }
    trackId = userDefaults.string(forKey: PersistenceKey.trackId)

    guard let savedValue = userDefaults.string(forKey: PersistenceKey.lifecycle),
      let savedLifecycle = TrackingLifecycle(rawValue: savedValue)
    else {
      return
    }
    switch savedLifecycle {
    case .paused:
      lifecycle = .paused
      profile = .paused
    case .starting, .tracking, .stopping, .interrupted, .failed:
      // iOS cannot promise automatic continuous recovery after termination.
      // Keep enough state for Dart to surface an explicit resume action.
      lifecycle = .interrupted
      profile = .paused
      userDefaults.set(TrackingLifecycle.interrupted.rawValue, forKey: PersistenceKey.lifecycle)
    case .idle:
      lifecycle = .idle
      profile = .idle
    }
  }

  private func clearPersistedSession() {
    userDefaults.removeObject(forKey: PersistenceKey.lifecycle)
    userDefaults.removeObject(forKey: PersistenceKey.trackId)
    userDefaults.removeObject(forKey: PersistenceKey.configuration)
  }

  private func epochMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard lifecycle == .tracking else { return }
    for location in locations {
      recordStationaryCandidateEvidence(location)
      if shouldExitStationary(for: location) {
        transition(to: .moving)
      }
      guard shouldEmit(location) else { continue }
      lastEmittedLocation = location
      let event = locationMap(location)
      do {
        journalPendingCount = try locationJournal.append(event)
        journalFailureMessage = nil
      } catch {
        failLocationJournal(error)
        return
      }
      lastLocationEvent = event
      delegate?.backgroundLocationService(self, didReceiveLocation: event)
    }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    let coreLocationError = error as? CLError
    if coreLocationError?.code == .locationUnknown {
      emitStatus(message: "location_temporarily_unavailable")
      return
    }

    if coreLocationError?.code == .denied {
      stopNativeUpdates()
      lifecycle = .failed
      profile = .paused
      persistState()
    }
    emitStatus(message: error.localizedDescription)
  }

  func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
    emitStatus(message: "location_updates_paused_by_ios")
  }

  func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
    emitStatus(message: "location_updates_resumed_by_ios")
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    finishPermissionRequestIfNeeded()
    emitStatus(message: "authorization_changed")
  }

  func locationManager(
    _ manager: CLLocationManager,
    didChangeAuthorization status: CLAuthorizationStatus
  ) {
    if #available(iOS 14.0, *) {
      return
    }
    finishPermissionRequestIfNeeded()
    emitStatus(message: "authorization_changed")
  }

  private func finishPermissionRequestIfNeeded() {
    guard currentAuthorizationStatus() != .notDetermined,
      let result = pendingPermissionResult
    else {
      return
    }
    pendingPermissionResult = nil
    let authorization = currentAuthorizationStatus()
    if pendingPermissionWantsMotion
      && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse)
    {
      requestMotionAuthorizationIfPossible()
    }
    pendingPermissionWantsMotion = false
    result(permissionMap())
  }
}
