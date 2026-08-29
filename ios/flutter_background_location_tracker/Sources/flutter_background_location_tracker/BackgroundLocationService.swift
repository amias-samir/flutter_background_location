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
  case preciseLocationRequired
  case missingUsageDescription(String)
  case backgroundModeMissing
  case permissionRequestInProgress
  case invalidArguments(String)
  case locationJournalCapacity(current: Int, maximum: Int)
  case locationJournalFailure(String)
  case nativeJournalCursorInvalid

  var code: String {
    switch self {
    case .alreadyTracking: return "already_tracking"
    case .invalidTrackId: return "invalid_track_id"
    case .invalidState: return "invalid_state"
    case .locationServicesDisabled: return "location_services_disabled"
    case .locationPermissionDenied: return "location_permission_denied"
    case .backgroundPermissionRequired: return "background_permission_required"
    case .preciseLocationRequired: return "precise_location_required"
    case .missingUsageDescription: return "missing_usage_description"
    case .backgroundModeMissing: return "background_mode_missing"
    case .permissionRequestInProgress: return "permission_request_in_progress"
    case .invalidArguments: return "invalid_arguments"
    case .locationJournalCapacity: return "location_journal_capacity"
    case .locationJournalFailure: return "location_journal_failure"
    case .nativeJournalCursorInvalid: return "native_journal_cursor_invalid"
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
    case .preciseLocationRequired:
      return "Precise Location is required for route tracking."
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
    case .nativeJournalCursorInvalid:
      return "The native journal cursor is invalid; restart paging from the first page."
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

  private let observers = NSHashTable<AnyObject>.weakObjects()

  func addObserver(_ observer: BackgroundLocationServiceDelegate) {
    observers.add(observer)
  }

  func removeObserver(_ observer: BackgroundLocationServiceDelegate) {
    observers.remove(observer)
  }

  private func notifyObservers(
    _ notification: (BackgroundLocationServiceDelegate) -> Void
  ) {
    for case let observer as BackgroundLocationServiceDelegate in observers.allObjects {
      notification(observer)
    }
  }

  private enum PersistenceKey {
    static let lifecycle = "flutter_background_location.lifecycle"
    static let trackId = "flutter_background_location.track_id"
    static let configuration = "flutter_background_location.configuration"
    static let sessionControlToken = "flutter_background_location.session_control_token"
    static let commandRevision = "flutter_background_location.command_revision"
    static let lastCommandId = "flutter_background_location.last_command_id"
  }

  private let locationManager = CLLocationManager()
  private let userDefaults: UserDefaults
  private let locationJournalQueue: NativeLocationJournalQueue

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
  private var sessionGeneration: Int64 = 0
  private var pendingTerminationRecovery = false
  private var recoveredFromTermination = false
  private var terminationRecoveryGapStartedAt: Date?
  // Stored as AnyObject so this package can keep its iOS 13 deployment target
  // while using CLBackgroundActivitySession on iOS 17 and later.
  private var backgroundActivitySession: AnyObject?
  private let monotonicDomainId = "ios_process_\(UUID().uuidString)"

  var nativeCommandTrackId: String? { trackId }
  var nativeCommandLifecycleIsIdle: Bool { lifecycle == .idle }
  var nativeSessionControlToken: String? {
    userDefaults.string(forKey: PersistenceKey.sessionControlToken)
  }
  var nativeCommandRevision: Int64 {
    max(0, Int64(userDefaults.integer(forKey: PersistenceKey.commandRevision)))
  }
  var nativeLastCommandId: String? {
    userDefaults.string(forKey: PersistenceKey.lastCommandId)
  }

  func claimNativeSessionControl(_ token: String) throws {
    guard !token.isEmpty else {
      throw BackgroundLocationServiceError.invalidArguments(
        "Session-control token must not be empty."
      )
    }
    if nativeSessionControlToken != token {
      userDefaults.set(0, forKey: PersistenceKey.commandRevision)
      userDefaults.removeObject(forKey: PersistenceKey.lastCommandId)
    }
    userDefaults.set(token, forKey: PersistenceKey.sessionControlToken)
    guard userDefaults.synchronize() else {
      throw BackgroundLocationServiceError.invalidState(
        "Could not persist native session control."
      )
    }
  }

  func recordNativeCommandResult(token: String, commandId: String, revision: Int64) throws {
    userDefaults.set(token, forKey: PersistenceKey.sessionControlToken)
    userDefaults.set(commandId, forKey: PersistenceKey.lastCommandId)
    userDefaults.set(revision, forKey: PersistenceKey.commandRevision)
    guard userDefaults.synchronize() else {
      throw BackgroundLocationServiceError.invalidState(
        "Could not persist the native command result."
      )
    }
  }

  init(
    userDefaults: UserDefaults = .standard,
    locationJournal: NativeLocationJournal = NativeLocationJournal()
  ) {
    self.userDefaults = userDefaults
    locationJournalQueue = NativeLocationJournalQueue(journal: locationJournal)
    super.init()
    locationManager.delegate = self
    restorePersistedState()
  }

  func initialize(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    locationJournalQueue.prepare { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let pendingCount):
        DispatchQueue.main.async {
          self.journalPendingCount = pendingCount
          self.journalFailureMessage = nil
          self.attemptTerminationRecoveryIfNeeded()
          self.emitStatus(message: self.recoveryStatusMessage)
          completion(.success(self.stateMap()))
        }
      case .failure(let error):
        completion(.failure(self.failLocationJournal(error)))
      }
    }
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
      "terminatedRecovery": true,
      "terminationRecoveryModes": [
        IOSTerminationRecoveryMode.interrupted.rawValue,
        IOSTerminationRecoveryMode.significantChange.rawValue,
      ],
      "motorizedTwoWheelerDetection": false,
    ]
  }

  func start(
    trackId: String,
    configuration: TrackingConfiguration,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard lifecycle != .tracking && lifecycle != .starting else {
      completion(.failure(BackgroundLocationServiceError.alreadyTracking))
      return
    }
    guard !trackId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      completion(.failure(BackgroundLocationServiceError.invalidTrackId))
      return
    }

    do {
      try validateTrackingPreconditions(configuration)
    } catch {
      completion(.failure(error))
      return
    }

    locationJournalQueue.ensureCapacityForCapture { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let pendingCount):
        self.journalPendingCount = pendingCount
        self.journalFailureMessage = nil
        completion(.success(self.startAfterJournalPrepared(trackId: trackId, configuration: configuration)))
      case .failure(let error):
        completion(.failure(self.failLocationJournal(error)))
      }
    }
  }

  private func startAfterJournalPrepared(
    trackId: String,
    configuration: TrackingConfiguration
  ) -> [String: Any] {
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
    sessionGeneration += 1
    lifecycle = .starting
    profile = .moving
    persistState()
    emitStatus()

    configureLocationManager(for: .moving)
    startBackgroundActivitySessionIfNeeded()
    startMotionUpdatesIfPossible()
    startConfiguredLocationUpdates()

    lifecycle = .tracking
    persistState()
    emitStatus()
    return stateMap()
  }

  func pause(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    if lifecycle == .paused {
      completion(.success(stateMap()))
      return
    }
    guard lifecycle == .tracking || lifecycle == .starting else {
      completion(
        .failure(
          BackgroundLocationServiceError.invalidState(
            "pauseTracking can only be called while tracking is active."
          )))
      return
    }

    lifecycle = .stopping
    emitStatus(message: "user_paused")
    stopNativeUpdates()
    locationJournalQueue.fence { [weak self] in
      guard let self else { return }
      self.lifecycle = .paused
      self.profile = .paused
      self.persistState()
      self.emitStatus()
      completion(.success(self.stateMap()))
    }
  }

  func resume(
    trackId suppliedTrackId: String?,
    configuration suppliedConfiguration: TrackingConfiguration?,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard lifecycle == .paused || lifecycle == .interrupted else {
      completion(
        .failure(
          BackgroundLocationServiceError.invalidState(
            "resumeTracking requires a paused or interrupted track."
          )))
      return
    }
    guard let resumedTrackId = suppliedTrackId ?? trackId else {
      completion(.failure(BackgroundLocationServiceError.invalidTrackId))
      return
    }
    start(
      trackId: resumedTrackId,
      configuration: suppliedConfiguration ?? configuration,
      completion: completion
    )
  }

  func stop(
    expectedTrackId: String? = nil,
    reason: String?,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    guard lifecycle != .idle else {
      completion(.success(stateMap()))
      return
    }
    if let expectedTrackId,
      let trackId,
      expectedTrackId != trackId
    {
      completion(
        .failure(
          BackgroundLocationServiceError.invalidState(
            "The requested track does not match the native session."
          )))
      return
    }

    lifecycle = .stopping
    emitStatus(message: reason)
    stopNativeUpdates()
    locationJournalQueue.fence { [weak self] in
      guard let self else { return }
      self.lifecycle = .idle
      self.profile = .idle
      self.trackId = nil
      self.clearPersistedSession()
      self.emitStatus(message: reason)
      completion(.success(self.stateMap()))
    }
  }

  func update(configuration: TrackingConfiguration) -> [String: Any] {
    self.configuration = configuration
    if lifecycle == .tracking {
      locationManager.stopUpdatingLocation()
      locationManager.stopMonitoringSignificantLocationChanges()
      configureLocationManager(for: profile)
      if configuration.allowBackgroundLocationUpdates {
        startBackgroundActivitySessionIfNeeded()
      } else {
        stopBackgroundActivitySession()
      }
      startConfiguredLocationUpdates()
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
      "commandRevision": nativeCommandRevision,
      "iosTerminationRecoveryMode": configuration.terminationRecoveryMode.rawValue,
      "recoveredFromTermination": recoveredFromTermination,
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
    if let terminationRecoveryGapStartedAt {
      state["terminationRecoveryGapStartedAt"] = epochMilliseconds(
        terminationRecoveryGapStartedAt
      )
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

  func pendingLocations(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    locationJournalQueue.pendingLocations { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let events):
        self.journalPendingCount = events.count
        self.journalFailureMessage = nil
        completion(.success(events))
      case .failure(let error):
        completion(.failure(self.failLocationJournal(error)))
      }
    }
  }

  func pendingLocationPage(
    cursor: String?,
    maxRecords: Int,
    maxEncodedBytes: Int,
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    locationJournalQueue.pendingLocationPage(
      cursor: cursor,
      maxRecords: maxRecords,
      maxEncodedBytes: maxEncodedBytes
    ) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let page):
        if cursor == nil {
          self.journalPendingCount = page.events.count + page.remainingCount
        }
        self.journalFailureMessage = nil
        completion(.success(page.map))
      case .failure(let error):
        if case NativeLocationJournalError.invalidCursor = error {
          completion(.failure(BackgroundLocationServiceError.nativeJournalCursorInvalid))
        } else {
          completion(.failure(self.failLocationJournal(error)))
        }
      }
    }
  }

  func nativeJournalDiagnostic(
    performMaintenance: Bool,
    completion: @escaping ([String: Any]) -> Void
  ) {
    locationJournalQueue.diagnostic(
      performMaintenance: performMaintenance,
      completion: completion
    )
  }

  func acknowledgeLocations(
    eventIds: [String],
    completion: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    locationJournalQueue.acknowledge(eventIds: eventIds) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let acknowledgement):
        self.journalPendingCount = acknowledgement.remaining
        self.journalFailureMessage = nil
        completion(
          .success([
            "acknowledged": acknowledgement.deleted,
            "remaining": acknowledgement.remaining,
          ]))
      case .failure(let error):
        completion(.failure(self.failLocationJournal(error)))
      }
    }
  }

  func deletePendingLocations(
    trackId: String,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    locationJournalQueue.deleteTrack(trackId: trackId) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let deleted):
        if let pendingCount = self.journalPendingCount {
          self.journalPendingCount = max(0, pendingCount - deleted)
        }
        self.journalFailureMessage = nil
        completion(.success(deleted))
      case .failure(let error):
        completion(.failure(self.failLocationJournal(error)))
      }
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
    guard hasPreciseLocationAuthorization() else {
      throw BackgroundLocationServiceError.preciseLocationRequired
    }
  }

  private func enforceActiveTrackingPreconditions(reason: String) {
    guard lifecycle == .tracking || lifecycle == .starting else {
      emitStatus(message: reason)
      return
    }
    do {
      try validateTrackingPreconditions(configuration)
      emitStatus(message: reason)
    } catch let error as BackgroundLocationServiceError {
      stopNativeUpdates()
      lifecycle = .interrupted
      profile = .paused
      persistState()
      emitStatus(message: "tracking_interrupted_\(error.code)")
    } catch {
      stopNativeUpdates()
      lifecycle = .interrupted
      profile = .paused
      persistState()
      emitStatus(message: "tracking_interrupted_prerequisite_lost")
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
    sessionGeneration += 1
    locationManager.stopUpdatingLocation()
    locationManager.stopMonitoringSignificantLocationChanges()
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

  private func startConfiguredLocationUpdates() {
    if configuration.terminationRecoveryMode == .significantChange {
      locationManager.startMonitoringSignificantLocationChanges()
    } else {
      locationManager.startUpdatingLocation()
    }
  }

  private var recoveryStatusMessage: String? {
    if recoveredFromTermination {
      return "termination_recovery_started_gap_possible"
    }
    return lifecycle == .interrupted ? "previous_session_interrupted" : nil
  }

  private func attemptTerminationRecoveryIfNeeded() {
    guard pendingTerminationRecovery else { return }
    pendingTerminationRecovery = false
    guard configuration.terminationRecoveryMode == .significantChange,
      trackId != nil,
      currentAuthorizationStatus() == .authorizedAlways,
      CLLocationManager.locationServicesEnabled()
    else {
      lifecycle = .interrupted
      profile = .paused
      persistState()
      return
    }
    do {
      try validateTrackingPreconditions(configuration)
      sessionGeneration += 1
      profile = .moving
      lifecycle = .starting
      configureLocationManager(for: .moving)
      startBackgroundActivitySessionIfNeeded()
      startMotionUpdatesIfPossible()
      startConfiguredLocationUpdates()
      lifecycle = .tracking
      recoveredFromTermination = true
      persistState()
    } catch {
      lifecycle = .interrupted
      profile = .paused
      persistState()
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
    notifyObservers { $0.backgroundLocationService(self, didReceiveActivity: event) }

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
      isMotionEvidenceEligible(location),
      let reference = stationaryReferenceLocation,
      isMotionEvidenceEligible(reference),
      location.timestamp >= reference.timestamp
    else {
      return false
    }
    let certainDisplacement = location.distance(from: reference)
      - location.horizontalAccuracy - reference.horizontalAccuracy
    return certainDisplacement
      >= configuration.stationaryProbeDisplacementMeters
  }

  private func recordStationaryCandidateEvidence(_ location: CLLocation) {
    guard isMotionEvidenceEligible(location) else { return }
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
        + location.horizontalAccuracy + candidate.horizontalAccuracy
    )
  }

  private func isMotionEvidenceEligible(_ location: CLLocation) -> Bool {
    guard location.horizontalAccuracy > 0,
      location.horizontalAccuracy <= configuration.maximumAcceptedAccuracyMeters
    else { return false }
    if #available(iOS 15.0, *), location.sourceInformation?.isSimulatedBySoftware == true {
      return false
    }
    return true
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
    let nativeReceivedAt = Date()
    let nativeReceivedAtMs = epochMilliseconds(nativeReceivedAt)
    let providerTimestampMs = epochMilliseconds(location.timestamp)
    var event: [String: Any] = [
      "eventId": UUID().uuidString,
      "lat": location.coordinate.latitude,
      "lon": location.coordinate.longitude,
      "altitude": location.altitude,
      "accuracy": location.horizontalAccuracy,
      "verticalAccuracy": location.verticalAccuracy,
      "heading": location.course,
      "speed": location.speed,
      "timestamp": providerTimestampMs,
      "nativeReceivedAt": nativeReceivedAtMs,
      "providerTimeDeltaMsAtReceipt": nativeReceivedAtMs - providerTimestampMs,
      "monotonicReceivedNanos": Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000),
      "monotonicDomainId": monotonicDomainId,
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
    let status = stateMap(message: message)
    notifyObservers { $0.backgroundLocationService(self, didChangeStatus: status) }
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
    case .starting, .tracking:
      terminationRecoveryGapStartedAt = Date()
      if configuration.terminationRecoveryMode == .significantChange {
        lifecycle = .starting
        profile = .moving
        pendingTerminationRecovery = true
      } else {
        lifecycle = .interrupted
        profile = .paused
        userDefaults.set(
          TrackingLifecycle.interrupted.rawValue,
          forKey: PersistenceKey.lifecycle
        )
      }
    case .stopping, .interrupted, .failed:
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
    pendingTerminationRecovery = false
    recoveredFromTermination = false
    terminationRecoveryGapStartedAt = nil
  }

  private func epochMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  // MARK: - CLLocationManagerDelegate

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard lifecycle == .tracking else { return }
    for location in locations {
      let generation = sessionGeneration
      recordStationaryCandidateEvidence(location)
      if shouldExitStationary(for: location) {
        transition(to: .moving)
      }
      guard shouldEmit(location) else { continue }
      lastEmittedLocation = location
      let event = locationMap(location)
      locationJournalQueue.append(event) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let pendingCount):
          self.journalPendingCount = pendingCount
          self.journalFailureMessage = nil
          guard generation == self.sessionGeneration,
            self.lifecycle == .tracking || self.lifecycle == .starting
          else {
            return
          }
          self.lastLocationEvent = event
          self.notifyObservers {
            $0.backgroundLocationService(self, didReceiveLocation: event)
          }
        case .failure(let error):
          guard generation == self.sessionGeneration else { return }
          self.failLocationJournal(error)
        }
      }
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
    enforceActiveTrackingPreconditions(reason: "authorization_changed")
  }

  func locationManager(
    _ manager: CLLocationManager,
    didChangeAuthorization status: CLAuthorizationStatus
  ) {
    if #available(iOS 14.0, *) {
      return
    }
    finishPermissionRequestIfNeeded()
    enforceActiveTrackingPreconditions(reason: "authorization_changed")
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
