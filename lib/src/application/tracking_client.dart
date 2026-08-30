import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path_util;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/activity_snapshot.dart';
import '../domain/capability_report.dart';
import '../domain/derived_geometry.dart';
import '../domain/export_models.dart';
import '../domain/fix_quality.dart';
import '../domain/location_sample.dart';
import '../domain/native_tracking_protocol.dart';
import '../domain/permission_state.dart';
import '../domain/route_geometry.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/track_query.dart';
import '../domain/trip.dart';
import '../domain/trip_query.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_continuity.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_health.dart';
import '../domain/tracking_readiness.dart';
import '../domain/tracking_session_snapshot.dart';
import '../domain/tracking_settings.dart';
import '../domain/tracking_start.dart';
import '../export/track_export_service.dart';
import '../export/track_export_v2_service.dart';
import '../export/trip_export_service.dart';
import '../platform/native_tracker_adapter.dart';
import '../platform/tracker_adapter.dart';
import '../storage/sqlite_track_repository.dart';
import '../storage/track_repository.dart';
import '../storage/trip_repository.dart';
import '../upload/track_uploader.dart';
import '../upload/tracking_batch_uploader.dart';
import 'motion_gate.dart';
import 'derived_geometry_service.dart';
import 'route_geometry_assembler.dart';

abstract interface class Tracking {
  Stream<TrackerStatus> get statusStream;
  Stream<ActivitySnapshot> get activityStream;
  Stream<TrackPoint> get pointStream;
  Stream<Track?> watchCurrentTrack();

  Future<void> initialize();
  Future<TrackingCapabilityReport> capabilities();
  Future<TrackingPermissionState> permissions({bool request = false});
  Future<String> startTrack({
    required String userId,
    required String organizationId,
    String? routeId,
    String? requestedTrackId,
    TrackingConfig? config,
  });
  Future<void> pauseTrack({
    String? trackId,
    String reason = 'user_paused',
    String? operationId,
  });
  Future<void> resumeTrack(String trackId);
  Future<void> completeTrack({
    String? trackId,
    String reason = 'user_completed',
    String? operationId,
  });
  Future<TrackExportResult> exportTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  });
  Future<void> deleteTrack(String trackId);
  Future<TrackBundle> loadTrackBundle(String trackId);
}

enum OwnerSwitchPolicy { rejectIfResumable, pauseAndPreserveCurrent }

final class OwnerSwitchResult {
  const OwnerSwitchResult({required this.previous, required this.current});
  final TrackingOwner previous;
  final TrackingOwner current;
}

final class TrackLifecycleResult {
  const TrackLifecycleResult({required this.track, required this.status});
  final Track track;
  final TrackerStatus status;
}

enum TrackHistoryChangeKind { created, updated, deleted }

final class TrackHistoryEvent {
  const TrackHistoryEvent({required this.kind, this.trackId});
  final TrackHistoryChangeKind kind;
  final String? trackId;
}

/// Owner-bound, awaited facade for normal host integrations.
abstract interface class TrackingController implements Tracking {
  bool get isInitialized;
  TrackingOwner get currentOwner;
  TrackerStatus get currentStatus;
  ActivitySnapshot get currentActivity;
  TrackingSessionSnapshot get currentSession;
  Stream<TrackingSessionSnapshot> get sessionStream;
  Stream<TrackHistoryEvent> get trackHistoryEvents;
  bool get supportsPagedHistory;

  Future<TrackingReadiness> checkReadiness();
  Future<TrackingReadiness> requestNextPermission();
  Future<TrackingReadiness> acknowledgeReadinessEducation(String issueCode);
  Future<OwnerSwitchResult> switchOwner(
    TrackingOwner next, {
    OwnerSwitchPolicy policy = OwnerSwitchPolicy.rejectIfResumable,
  });
  Future<TrackStartResult> startNewTrack(TrackStartRequest request);
  Future<TrackStartResult> startOrRecoverTrack(TrackStartRequest request);
  Future<TrackStartResult> resumeCurrentTrack();
  Future<TrackLifecycleResult> pauseCurrentTrack({String reason});
  Future<TrackLifecycleResult> completeCurrentTrack({String reason});
  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  );
  Future<OwnerConflictResolutionResult> resolveOwnerConflict(
    OwnerConflictResolutionRequest request,
  );
  Future<Track?> getTrack(String trackId);
  Future<TrackPage> listTrackPage(TrackQuery query);
  Future<void> dispose();
}

/// Additive multi-day lifecycle API. Existing [TrackingController]
/// implementations remain source compatible because this is a separate
/// capability.
abstract interface class MultiDayTripController {
  Future<TripStartResult> startTrip(TripStartRequest request);

  Future<TripLifecycleResult> endCurrentDay({
    String reason = 'day_completed',
    String? operationId,
  });

  Future<TripContinueResult> continueTrip(
    String tripId, {
    TrackingConfig? config,
    String? operationId,
    bool confirmCompletedTripContinuation = false,
  });

  Future<TripLifecycleResult> completeTrip(
    String tripId, {
    String reason = 'trip_completed',
    String? operationId,
  });

  Future<Trip?> getTrip(String tripId);
  Future<TripPage> listTripPage(TripQuery query);
  Future<TripBundle> loadTripBundle(String tripId);
  Future<RouteGeometryReport> assembleTripRouteGeometry(
    String tripId, {
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
  });
  Future<TripExportResult> exportTrip({
    required String tripId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  });
  Future<void> deleteTrip(String tripId);
}

/// Combined controller returned by [TrackingClient.openWithTrips].
abstract interface class TrackingTripController
    implements TrackingController, MultiDayTripController {}

class TrackingClient implements Tracking {
  static Future<TrackingController> open({
    required TrackingOwner owner,
    TrackingConfiguration configuration = const TrackingConfiguration(),
    TrackerAdapter? trackerAdapter,
    TrackRepository? repository,
    ExportFileWriter? exportFileWriter,
    TrackUploader? uploader,
    DateTime Function()? clock,
  }) async {
    final client = TrackingClient(
      configuration: configuration,
      trackerAdapter: trackerAdapter,
      repository: repository,
      exportFileWriter: exportFileWriter,
      uploader: uploader,
      clock: clock,
      uploadOwner: owner,
    );
    try {
      await client.initialize();
      await client.checkReadiness();
      await client.healthSnapshot();
      await client._publishSessionSnapshot();
      return _OwnerBoundTrackingController(client, owner);
    } on Object {
      try {
        await client.dispose();
      } on Object {
        // Preserve the initialization failure; partial cleanup is best effort.
      }
      rethrow;
    }
  }

  /// Opens the same owner-bound tracking client with the additive multi-day
  /// Trip API exposed in its static type.
  static Future<TrackingTripController> openWithTrips({
    required TrackingOwner owner,
    TrackingConfiguration configuration = const TrackingConfiguration(),
    TrackerAdapter? trackerAdapter,
    TrackRepository? repository,
    ExportFileWriter? exportFileWriter,
    TrackUploader? uploader,
    DateTime Function()? clock,
  }) async =>
      (await open(
        owner: owner,
        configuration: configuration,
        trackerAdapter: trackerAdapter,
        repository: repository,
        exportFileWriter: exportFileWriter,
        uploader: uploader,
        clock: clock,
      )) as TrackingTripController;

  TrackingClient({
    this.configuration = const TrackingConfiguration(),
    TrackerAdapter? trackerAdapter,
    TrackRepository? repository,
    ExportFileWriter? exportFileWriter,
    TrackUploader? uploader,
    DateTime Function()? clock,
    TrackingOwner? uploadOwner,
  })  : _tracker = trackerAdapter ?? NativeTrackerAdapter(),
        _repository = repository,
        _exportFileWriter = exportFileWriter,
        _uploader = uploader,
        _uploadOwner = uploadOwner,
        _clock = clock ?? _utcNow;

  final TrackingConfiguration configuration;
  final TrackerAdapter _tracker;
  TrackRepository? _repository;
  ExportFileWriter? _exportFileWriter;
  final TrackUploader? _uploader;
  final TrackingOwner? _uploadOwner;
  final DateTime Function() _clock;

  final StreamController<TrackerStatus> _statusController =
      StreamController<TrackerStatus>.broadcast();
  final StreamController<ActivitySnapshot> _activityController =
      StreamController<ActivitySnapshot>.broadcast();
  final StreamController<TrackPoint> _pointController =
      StreamController<TrackPoint>.broadcast();
  final StreamController<TrackingSessionSnapshot> _sessionController =
      StreamController<TrackingSessionSnapshot>.broadcast();
  final StreamController<TrackingHealthSnapshot> _healthController =
      StreamController<TrackingHealthSnapshot>.broadcast();

  StreamSubscription<LocationSample>? _locationSubscription;
  StreamSubscription<ActivitySnapshot>? _activitySubscription;
  StreamSubscription<TrackerStatus>? _nativeStatusSubscription;
  StreamSubscription<Track?>? _currentTrackSubscription;
  TrackExportService? _exportService;
  TrackingBatchUploader? _batchUploader;
  TrackingCapabilityReport? _capabilityReport;
  ActivitySnapshot _latestActivity = const ActivitySnapshot.unknown();
  MotionGate? _motionGate;
  TrackerStatus _currentStatus = const TrackerStatus(
    lifecycle: TrackerLifecycle.idle,
  );
  Future<void> _pointTail = Future<void>.value();
  Future<void> _commandTail = Future<void>.value();
  Future<void>? _initializing;
  Future<void>? _nativeUserActionRecovery;
  Timer? _batchUploadTimer;
  Timer? _uploadRecoveryTimer;
  Timer? _firstFixTimer;
  Timer? _healthWatchdogTimer;
  String? _batchUploadTrackId;
  bool _initialized = false;
  bool _disposed = false;
  bool _acceptingLocations = false;
  int _readinessRevision = 0;
  int _sessionRevision = 0;
  final List<LocationSample> _initializationLocations = <LocationSample>[];
  final Set<String> _acknowledgedReadinessEducation = <String>{};
  TrackingReadiness? _latestReadiness;
  TrackingSessionSnapshot? _currentSession;
  TrackingHealthSnapshot? _currentHealth;
  TrackPoint? _latestPoint;
  TrackingFixState _fixState = TrackingFixState.idle;
  DateTime? _lastNativeFixAt;
  DateTime? _lastJournaledAt;
  DateTime? _lastCommittedAt;
  DateTime? _lastAcceptedAt;

  static DateTime _utcNow() => DateTime.now().toUtc();

  TrackRepository get _store {
    final value = _repository;
    if (value == null) throw StateError('Call initialize() first.');
    return value;
  }

  TrackExportService get _exports {
    final value = _exportService;
    if (value == null) throw StateError('Call initialize() first.');
    return value;
  }

  TrackerStatus get currentStatus => _currentStatus;
  ActivitySnapshot get currentActivity => _latestActivity;
  TrackingSessionSnapshot? get currentSession => _currentSession;
  TrackingHealthSnapshot? get currentHealth => _currentHealth;
  bool get isInitialized => _initialized;

  Stream<TrackingHealthSnapshot> get healthStream =>
      Stream<TrackingHealthSnapshot>.multi(
        (controller) {
          final subscription = _healthController.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          final current = _currentHealth;
          if (current != null) controller.add(current);
          controller.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<TrackerStatus> get statusStream => Stream<TrackerStatus>.multi(
        (controller) {
          final subscription = _statusController.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.add(_currentStatus);
          controller.onCancel = () {
            unawaited(subscription.cancel());
          };
        },
        isBroadcast: true,
      );

  @override
  Stream<ActivitySnapshot> get activityStream => _activityController.stream;

  @override
  Stream<TrackPoint> get pointStream => _pointController.stream;

  Stream<TrackingSessionSnapshot> get sessionStream =>
      Stream<TrackingSessionSnapshot>.multi(
        (controller) {
          final subscription = _sessionController.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          final snapshot = _currentSession;
          if (snapshot != null) controller.add(snapshot);
          controller.onCancel = () {
            unawaited(subscription.cancel());
          };
        },
        isBroadcast: true,
      );

  @override
  Stream<Track?> watchCurrentTrack() => _store.currentTrackStream;

  @override
  Future<void> initialize() {
    configuration.validate();
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    _ensureNotDisposed();
    WidgetsFlutterBinding.ensureInitialized();
    if (_repository == null) {
      final databasesPath = await getDatabasesPath();
      _repository = SqliteTrackRepository(
        path: path_util.join(databasesPath, configuration.databaseName),
      );
    }
    await _store.initialize();
    _currentTrackSubscription = _store.currentTrackStream.listen((_) {
      unawaited(_publishSessionSnapshot());
    });
    _exportFileWriter ??= PublicDownloadsExportWriter(
      directoryName: configuration.exportDirectoryName,
    );
    _exportService = TrackExportService(
      repository: _store,
      fileWriter: _exportFileWriter!,
    );
    if (_uploader != null) {
      _batchUploader = TrackingBatchUploader(
        repository: _store,
        uploader: _uploader,
        maximumPointCount: configuration.maximumUploadBatchPointCount,
        maximumEncodedBytes: configuration.maximumUploadBatchBytes,
        leaseDuration: configuration.uploadLeaseDuration,
        initialBackoff: configuration.uploadInitialBackoff,
        maximumBackoff: configuration.uploadMaximumBackoff,
        clock: _clock,
        owner: _uploadOwner,
      );
    }

    _locationSubscription = _tracker.locationStream.listen(
      _enqueueLocation,
      onError: (Object error, StackTrace stackTrace) {
        _emitStatus(
          TrackerStatus(
            lifecycle: TrackerLifecycle.failed,
            trackId: _currentStatus.trackId,
            message: 'Location stream failed: $error',
          ),
        );
      },
    );
    _activitySubscription = _tracker.activityStream.listen(
      _handleActivity,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(
          _safeHealthEvent(
            trackId: _currentStatus.trackId,
            type: 'activity_stream_failed',
            details: <String, Object?>{'error': error.toString()},
          ),
        );
      },
    );
    _nativeStatusSubscription = _tracker.statusStream.listen(
      _handleNativeStatus,
      onError: (Object error, StackTrace stackTrace) {
        _emitStatus(
          TrackerStatus(
            lifecycle: TrackerLifecycle.failed,
            trackId: _currentStatus.trackId,
            message: 'Native tracker failed: $error',
          ),
        );
      },
    );

    await _tracker.initialize();
    _capabilityReport = await _tracker.capabilities();
    await _recoverPendingNativeUserAction();
    await _recoverPendingLifecycleCommand();
    await _recoverPendingConfigurationUpdates();
    await _recoverPendingTripOperations();
    await _reconcile();
    await _drainPendingNativeLocations();
    await _drainPendingNativeLocations();
    _initialized = true;
    _acceptingLocations = _currentStatus.lifecycle == TrackerLifecycle.tracking;
    await _publishSessionSnapshot();
    _startUploadRecoveryLoop();
    unawaited(_triggerAllUploads());
  }

  Future<void> _reconcile() async {
    final active = await _store.findActiveTrack();
    final paused = await _store.findLatestPausedTrack();
    final nativeRunning = await _tracker.isRunning();
    if (active == null && nativeRunning) {
      final state = await _tracker.runtimeState();
      final orphanId = state.trackId;
      if (orphanId != null) {
        await _tracker.stop(trackId: orphanId, reason: 'orphan_native_session');
      }
      _emitStatus(
        const TrackerStatus(
          lifecycle: TrackerLifecycle.interrupted,
          message: 'Stopped an orphan native tracking session.',
        ),
      );
      return;
    }
    if (active != null && nativeRunning) {
      final nativeState = await _tracker.runtimeState();
      final nativeTrackId = nativeState.trackId;
      if (nativeTrackId != null && nativeTrackId != active.id) {
        await _tracker.stop(
          trackId: nativeTrackId,
          reason: 'native_database_track_mismatch',
        );
        await _waitUntilNativeStopped();
        await _store.interruptTrack(
          active.id,
          reason: 'native_database_track_mismatch',
        );
        _emitStatus(
          TrackerStatus(
            lifecycle: TrackerLifecycle.interrupted,
            trackId: active.id,
            message: 'Native and stored track identifiers did not match.',
          ),
        );
        return;
      }
      if (active.status == TrackStatus.starting) {
        await _store.markTrackActive(active.id);
      }
      _motionGate = MotionGate(active.config);
      _scheduleBatchUploads(active.id, active.config);
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: active.id,
          lastPointAt: active.lastPointAt,
        ),
      );
      return;
    }
    if (active != null && !nativeRunning) {
      // Persist fixes captured before the native runner stopped while the old
      // segment is still active. Closing it first would either lose those
      // durable events or incorrectly attach them to a later resumed segment.
      if (active.status == TrackStatus.starting) {
        await _store.markTrackActive(active.id);
      }
      await _drainPendingNativeLocations(trackId: active.id);
      await _store.interruptTrack(
        active.id,
        reason: 'active_track_without_native_runner',
      );
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.interrupted,
          trackId: active.id,
          lastPointAt: active.lastPointAt,
          message: 'Tracking was interrupted and requires an explicit resume.',
        ),
      );
      return;
    }
    if (paused != null) {
      _emitStatus(
        TrackerStatus(
          lifecycle: paused.status == TrackStatus.paused
              ? TrackerLifecycle.paused
              : TrackerLifecycle.interrupted,
          trackId: paused.id,
          lastPointAt: paused.lastPointAt,
        ),
      );
    } else {
      _emitStatus(const TrackerStatus(lifecycle: TrackerLifecycle.idle));
    }
  }

  @override
  Future<TrackingCapabilityReport> capabilities() async {
    await initialize();
    return _capabilityReport ?? await _tracker.capabilities();
  }

  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async {
    await initialize();
    return _tracker.permissions(request: request);
  }

  Future<TrackingReadiness> checkReadiness() async {
    await initialize();
    final permission = await _tracker.permissions();
    final capability = _capabilityReport ?? await _tracker.capabilities();
    final readiness = _readinessFrom(permission, capability);
    unawaited(_publishSessionSnapshot());
    return readiness;
  }

  Future<TrackingReadiness> acknowledgeReadinessEducation(
    String issueCode,
  ) async {
    final readiness = await checkReadiness();
    final issueMatches = readiness.issues.any(
      (issue) =>
          issue.code == issueCode &&
          issue.action == TrackingReadinessAction.explainBackgroundLocation,
    );
    if (!issueMatches) {
      throw TrackingNotReadyException(
        code: 'education_issue_stale',
        message: 'The readiness education issue is no longer current.',
      );
    }
    _acknowledgedReadinessEducation.add(issueCode);
    return checkReadiness();
  }

  Future<TrackingReadiness> requestNextPermission() async {
    final readiness = await checkReadiness();
    final action = readiness.nextAction;
    if (!_isPermissionRequestAction(action)) return readiness;
    if (_tracker is! StagedPermissionAdapter) {
      throw const TrackingNativeException(
        code: 'capability_unsupported',
        message: 'This tracker adapter does not support staged permissions.',
      );
    }
    try {
      final stagedAdapter = _tracker as StagedPermissionAdapter;
      final permission = await stagedAdapter.requestPermissionStep(
        action: action,
        expectedReadinessRevision: readiness.revision,
      );
      final capability = _capabilityReport ?? await _tracker.capabilities();
      return _readinessFrom(permission, capability);
    } on TrackingPermissionStepException {
      rethrow;
    } on TrackingException {
      rethrow;
    } catch (error) {
      throw TrackingPermissionStepException(
        code: 'permission_request_failed',
        message: 'The native permission request failed.',
        permissionMayHaveChanged: true,
        cause: error,
      );
    }
  }

  TrackingReadiness _readinessFrom(
    TrackingPermissionState permission,
    TrackingCapabilityReport capability,
  ) {
    final issues = <TrackingReadinessIssue>[];
    void add(
      String code,
      TrackingReadinessAction action, {
      required bool blocking,
      String? message,
    }) {
      issues.add(
        TrackingReadinessIssue(
          code: code,
          action: action,
          blocking: blocking,
          message: message,
        ),
      );
    }

    if (!capability.backgroundTracking) {
      add(
        'background_tracking_unsupported',
        TrackingReadinessAction.unsupported,
        blocking: true,
      );
    } else if (!permission.locationServiceEnabled) {
      add(
        'location_services_disabled',
        TrackingReadinessAction.enableLocationServices,
        blocking: true,
        message: permission.message,
      );
    } else if (permission.location == LocationPermissionLevel.deniedForever ||
        (permission.requiresSettings &&
            permission.location == LocationPermissionLevel.denied)) {
      add(
        'location_permission_requires_settings',
        TrackingReadinessAction.openAppSettings,
        blocking: true,
        message: permission.message,
      );
    } else if (permission.location == LocationPermissionLevel.denied ||
        permission.location == LocationPermissionLevel.unknown) {
      add(
        'foreground_location_required',
        TrackingReadinessAction.requestForegroundLocation,
        blocking: true,
        message: permission.message,
      );
    } else if (permission.location == LocationPermissionLevel.whileInUse) {
      const educationCode = 'background_location_explanation_required';
      if (!_acknowledgedReadinessEducation.contains(educationCode)) {
        add(
          educationCode,
          TrackingReadinessAction.explainBackgroundLocation,
          blocking: true,
          message: permission.message,
        );
      } else if (permission.canRequestBackground) {
        add(
          'background_location_required',
          TrackingReadinessAction.requestBackgroundLocation,
          blocking: true,
          message: permission.message,
        );
      } else {
        add(
          'background_location_requires_settings',
          TrackingReadinessAction.openAppSettings,
          blocking: true,
          message: permission.message,
        );
      }
    } else if (!permission.preciseLocation) {
      add(
        'precise_location_required',
        TrackingReadinessAction.enablePreciseLocation,
        blocking: true,
        message: permission.message,
      );
    } else if (!permission.notificationGranted) {
      add(
        'notification_permission_required',
        TrackingReadinessAction.requestNotification,
        blocking: true,
        message: permission.message,
      );
    }

    if (capability.activityRecognition &&
        !permission.activityRecognitionGranted) {
      add(
        'activity_recognition_recommended',
        TrackingReadinessAction.requestActivityRecognition,
        blocking: false,
      );
    }

    TrackingReadinessAction nextAction = TrackingReadinessAction.none;
    for (final issue in issues) {
      if (issue.blocking) {
        nextAction = issue.action;
        break;
      }
    }
    if (nextAction == TrackingReadinessAction.none && issues.isNotEmpty) {
      nextAction = issues.first.action;
    }

    final readiness = TrackingReadiness(
      revision: ++_readinessRevision,
      permissions: permission,
      capabilities: capability,
      issues: issues,
      nextAction: nextAction,
    );
    _latestReadiness = readiness;
    return readiness;
  }

  static bool _isPermissionRequestAction(TrackingReadinessAction action) =>
      action == TrackingReadinessAction.requestForegroundLocation ||
      action == TrackingReadinessAction.requestBackgroundLocation ||
      action == TrackingReadinessAction.requestNotification ||
      action == TrackingReadinessAction.requestActivityRecognition;

  Future<TrackStartResult> startNewTrack(TrackStartRequest request) async {
    await initialize();
    final selectedConfig =
        request.config ?? configuration.defaultTrackingConfig;
    selectedConfig.validate(context: 'TrackingConfig');
    return _serializeCommand(() async {
      final readiness = await _requireReadinessForNativeStart();
      final active = await _store.findActiveTrack();
      if (active != null) {
        _throwStartConflict(active, request.owner);
      }
      final paused = await _ownerStore.findLatestPausedTrackForOwner(
        request.owner,
      );
      if (paused != null) {
        _throwStartConflict(paused, request.owner);
      }
      return _createAndStartTrack(
        request: request,
        config: selectedConfig,
        readiness: readiness,
      );
    });
  }

  Future<TrackStartResult> startOrRecoverTrack(
      TrackStartRequest request) async {
    await initialize();
    final selectedConfig =
        request.config ?? configuration.defaultTrackingConfig;
    selectedConfig.validate(context: 'TrackingConfig');
    return _serializeCommand(() async {
      final readiness = await _requireReadinessForNativeStart();
      final active = await _store.findActiveTrack();
      if (active != null) {
        _ensureOwner(active, request.owner);
        await _activateExistingActiveTrack(active);
        return TrackStartResult(
          track: (await _store.getTrack(active.id)) ?? active,
          disposition: TrackStartDisposition.reusedActive,
          readiness: readiness,
        );
      }

      final paused = await _ownerStore.findLatestPausedTrackForOwner(
        request.owner,
      );
      if (paused != null) {
        _ensureOwner(paused, request.owner);
        final disposition = paused.status == TrackStatus.interrupted
            ? TrackStartDisposition.resumedInterrupted
            : TrackStartDisposition.resumedPaused;
        await _resumeTrack(
          paused.id,
          requestPermission: false,
          precheckedReadiness: readiness,
        );
        return TrackStartResult(
          track: (await _store.getTrack(paused.id)) ?? paused,
          disposition: disposition,
          readiness: readiness,
        );
      }

      return _createAndStartTrack(
        request: request,
        config: selectedConfig,
        readiness: readiness,
      );
    });
  }

  Future<TrackStartResult> resumeCurrentTrack({
    required TrackingOwner owner,
  }) async {
    await initialize();
    return _serializeCommand(() async {
      final readiness = await _requireReadinessForNativeStart();
      final active = await _store.findActiveTrack();
      if (active != null) {
        _ensureOwner(active, owner);
        await _activateExistingActiveTrack(active);
        return TrackStartResult(
          track: (await _store.getTrack(active.id)) ?? active,
          disposition: TrackStartDisposition.reusedActive,
          readiness: readiness,
        );
      }
      final paused = await _ownerStore.findLatestPausedTrackForOwner(owner);
      if (paused == null) {
        throw const TrackingConflictException(
          code: 'no_resumable_track',
          message: 'There is no paused or interrupted track to resume.',
        );
      }
      _ensureOwner(paused, owner);
      final disposition = paused.status == TrackStatus.interrupted
          ? TrackStartDisposition.resumedInterrupted
          : TrackStartDisposition.resumedPaused;
      await _resumeTrack(
        paused.id,
        requestPermission: false,
        precheckedReadiness: readiness,
      );
      return TrackStartResult(
        track: (await _store.getTrack(paused.id)) ?? paused,
        disposition: disposition,
        readiness: readiness,
      );
    });
  }

  @override
  Future<String> startTrack({
    required String userId,
    required String organizationId,
    String? routeId,
    String? requestedTrackId,
    TrackingConfig? config,
  }) async {
    await initialize();
    final selectedConfig = config ?? configuration.defaultTrackingConfig;
    selectedConfig.validate(context: 'TrackingConfig');
    return _serializeCommand(() async {
      final permission = await _tracker.permissions(request: true);
      if (!permission.canTrackInBackground) {
        throw TrackingPermissionException(permission);
      }
      final active = await _store.findActiveTrack();
      if (active != null) {
        final nativeRunning = await _tracker.isRunning();
        final nativeTrackId =
            nativeRunning ? (await _tracker.runtimeState()).trackId : null;
        if (!nativeRunning ||
            nativeTrackId == null ||
            nativeTrackId == active.id) {
          if (active.status == TrackStatus.starting) {
            await _store.markTrackActive(active.id);
          }
          if (!nativeRunning) {
            await _bindNativeCommandLease(active.id);
            await _tracker.start(trackId: active.id, config: active.config);
          }
          _motionGate = MotionGate(active.config);
          _acceptingLocations = true;
          _beginFixAcquisition(active);
          _scheduleBatchUploads(active.id, active.config);
          _emitStatus(
            TrackerStatus(
              lifecycle: TrackerLifecycle.tracking,
              trackId: active.id,
              lastPointAt: active.lastPointAt,
            ),
          );
          return active.id;
        }
        throw StateError(
          'Native tracking belongs to $nativeTrackId, not ${active.id}.',
        );
      }
      final paused = await _store.findLatestPausedTrack();
      if (paused != null) {
        await _resumeTrack(paused.id);
        return paused.id;
      }
      final result = await _createAndStartTrack(
        request: TrackStartRequest(
          owner: TrackingOwner(
            userId: userId,
            organizationId: organizationId,
          ),
          routeId: routeId,
          requestedTrackId: requestedTrackId,
          config: selectedConfig,
        ),
        config: selectedConfig,
        readiness: _readinessFrom(
          permission,
          _capabilityReport ?? await _tracker.capabilities(),
        ),
      );
      return result.trackId;
    });
  }

  Future<void> _applyRecordRetention({
    required TrackingOwner owner,
    required String retainedTrackId,
  }) async {
    if (configuration.recordRetentionPolicy !=
        TrackRecordRetentionPolicy.keepLatestOnly) {
      return;
    }
    await _ownerStore.deleteTracksExceptForOwner(
      owner,
      <String>{retainedTrackId},
    );
  }

  @override
  Future<void> pauseTrack({
    String? trackId,
    String reason = 'user_paused',
    String? operationId,
  }) async {
    await initialize();
    await _serializeCommand(() async {
      final track = await _resolveTrack(trackId);
      if (track.status == TrackStatus.paused) return;
      if (operationId != null &&
          await _store.wasOperationApplied(
            track.id,
            operationId: operationId,
            type: TrackOperationType.pause,
          )) {
        return;
      }
      if (track.status != TrackStatus.active) {
        throw StateError('Cannot pause track in ${track.status.name}.');
      }
      if (await _tracker.isRunning()) {
        final nativeTrackId = (await _tracker.runtimeState()).trackId;
        if (nativeTrackId != null && nativeTrackId != track.id) {
          throw StateError(
            'Native tracking belongs to $nativeTrackId, not ${track.id}.',
          );
        }
      }
      final command = await _store.beginLifecycleCommand(
        trackId: track.id,
        type: TrackCommandType.pause,
        reason: reason,
        operationId: operationId,
      );
      _acceptingLocations = false;
      try {
        await _bindNativeCommandLease(track.id);
        await _tracker.pause(trackId: track.id);
        await _waitUntilNativeStopped();
      } catch (_) {
        _acceptingLocations = true;
        rethrow;
      }
      await _pointTail;
      await _drainPendingNativeLocations(trackId: track.id);
      await _store.pauseTrack(
        track.id,
        reason: command.reason,
        operationId: command.operationId,
      );
      await _store.clearPendingLifecycleCommand(command.id);
      _clearFixAcquisition();
      _cancelBatchUploads(track.id);
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.paused,
          trackId: track.id,
          lastPointAt: (await _store.getTrack(track.id))?.lastPointAt,
        ),
      );
      unawaited(_triggerUpload(track.id));
    });
  }

  @override
  Future<void> resumeTrack(String trackId) async {
    await initialize();
    await _serializeCommand(() => _resumeTrack(trackId));
  }

  Future<void> _resumeTrack(
    String trackId, {
    bool requestPermission = true,
    TrackingReadiness? precheckedReadiness,
  }) async {
    final existing = await _store.getTrack(trackId);
    if (existing == null) throw StateError('Unknown track: $trackId');
    existing.config.validate(context: 'Track.config');
    if (existing.status == TrackStatus.active ||
        existing.status == TrackStatus.starting) {
      final nativeRunning = await _tracker.isRunning();
      final nativeTrackId =
          nativeRunning ? (await _tracker.runtimeState()).trackId : null;
      if (nativeRunning &&
          (nativeTrackId == null || nativeTrackId == trackId)) {
        return;
      }
      if (nativeRunning && nativeTrackId != trackId) {
        throw StateError(
          'Native tracking belongs to $nativeTrackId, not $trackId.',
        );
      }
      await _drainPendingNativeLocations(trackId: trackId);
      await _store.interruptTrack(
        trackId,
        reason: 'resume_found_inactive_native_runner',
      );
    }
    if (requestPermission) {
      final permission = await _tracker.permissions(request: true);
      if (!permission.canTrackInBackground) {
        throw TrackingPermissionException(permission);
      }
    } else {
      final readiness =
          precheckedReadiness ?? await _requireReadinessForNativeStart();
      if (!readiness.canStart) {
        throw TrackingNotReadyException(
          code: 'not_ready',
          message: 'Tracking readiness requirements are not satisfied.',
        );
      }
    }
    final prepared = await _store.prepareResume(trackId);
    if (prepared.status == TrackStatus.active) return;
    _motionGate = MotionGate(prepared.config);
    _emitStatus(
      TrackerStatus(
        lifecycle: TrackerLifecycle.starting,
        trackId: trackId,
      ),
    );
    try {
      await _store.markTrackActive(trackId);
      _acceptingLocations = true;
      await _bindNativeCommandLease(trackId);
      if (await _tracker.isRunning()) {
        await _tracker.resume(trackId: trackId, config: prepared.config);
      } else {
        await _tracker.start(trackId: trackId, config: prepared.config);
      }
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: trackId,
        ),
      );
      _beginFixAcquisition(prepared);
      _scheduleBatchUploads(trackId, prepared.config);
    } catch (error) {
      _acceptingLocations = false;
      await _store.interruptTrack(
        trackId,
        reason: 'tracker_resume_failed',
      );
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.failed,
          trackId: trackId,
          message: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<TrackingReadiness> _requireReadinessForNativeStart() async {
    final readiness = await checkReadiness();
    if (readiness.canStart) return readiness;
    throw TrackingNotReadyException(
      code: 'not_ready',
      message: 'Tracking readiness requirements are not satisfied.',
      recoveryAction:
          readiness.nextAction == TrackingReadinessAction.openAppSettings ||
                  readiness.nextAction ==
                      TrackingReadinessAction.enableLocationServices ||
                  readiness.nextAction ==
                      TrackingReadinessAction.enablePreciseLocation
              ? TrackingRecoveryActions.openSettings
              : TrackingRecoveryActions.refresh,
    );
  }

  Future<TrackStartResult> _createAndStartTrack({
    required TrackStartRequest request,
    required TrackingConfig config,
    required TrackingReadiness readiness,
  }) async {
    final trackId = await _store.createTrack(
      userId: request.owner.userId,
      organizationId: request.owner.organizationId,
      routeId: request.routeId == null
          ? null
          : createRouteId(request.routeId!, _clock()),
      config: config,
      requestedTrackId: request.requestedTrackId,
    );
    await _applyRecordRetention(
      owner: request.owner,
      retainedTrackId: trackId,
    );
    _motionGate = MotionGate(config);
    _emitStatus(
      TrackerStatus(
        lifecycle: TrackerLifecycle.starting,
        trackId: trackId,
      ),
    );
    try {
      // Mark active before native capture starts so an immediate first fix is
      // never rejected merely because the database is still "starting".
      await _store.markTrackActive(trackId);
      _acceptingLocations = true;
      await _bindNativeCommandLease(trackId);
      await _tracker.start(trackId: trackId, config: config);
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: trackId,
        ),
      );
      _beginFixAcquisition((await _store.getTrack(trackId))!);
      _scheduleBatchUploads(trackId, config);
      return TrackStartResult(
        track: (await _store.getTrack(trackId))!,
        disposition: TrackStartDisposition.created,
        readiness: readiness,
      );
    } catch (error) {
      _acceptingLocations = false;
      await _store.interruptTrack(
        trackId,
        reason: 'tracker_start_failed',
      );
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.failed,
          trackId: trackId,
          message: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<void> _activateExistingActiveTrack(Track active) async {
    final nativeRunning = await _tracker.isRunning();
    final nativeTrackId =
        nativeRunning ? (await _tracker.runtimeState()).trackId : null;
    if (nativeRunning && nativeTrackId != null && nativeTrackId != active.id) {
      throw TrackingConflictException(
        code: 'active_track_conflict',
        message: 'Native tracking is already active for another route.',
        trackId: active.id,
      );
    }
    if (active.status == TrackStatus.starting) {
      await _store.markTrackActive(active.id);
    }
    if (!nativeRunning) {
      await _bindNativeCommandLease(active.id);
      await _tracker.start(trackId: active.id, config: active.config);
    }
    _motionGate = MotionGate(active.config);
    _acceptingLocations = true;
    _beginFixAcquisition(active);
    _scheduleBatchUploads(active.id, active.config);
    _emitStatus(
      TrackerStatus(
        lifecycle: TrackerLifecycle.tracking,
        trackId: active.id,
        lastPointAt: active.lastPointAt,
      ),
    );
  }

  OwnerScopedTrackRepository get _ownerStore {
    final store = _store;
    if (store is OwnerScopedTrackRepository) {
      return store as OwnerScopedTrackRepository;
    }
    throw const TrackingStorageException(
      code: 'capability_unsupported',
      message: 'This repository does not support owner-scoped route access.',
    );
  }

  void _ensureOwner(Track track, TrackingOwner owner) {
    if (owner.owns(track)) return;
    throw const TrackingOwnershipException(
      code: 'owner_scope_conflict',
      message: 'A route from another owner must be resolved before continuing.',
    );
  }

  Future<void> _bindNativeCommandLease(String trackId) async {
    final adapter = _tracker;
    if (adapter is! CommandLeaseTrackerAdapter) return;
    final leaseAdapter = adapter as CommandLeaseTrackerAdapter;
    final track = await _store.getTrack(trackId);
    final token = track?.sessionControlToken;
    if (token == null || token.isEmpty) {
      // Custom/legacy repositories may not persist the additive token yet.
      // Preserve their legacy behavior instead of inventing a non-durable one.
      return;
    }
    await leaseAdapter.acquireCommandLease(
      trackId: trackId,
      sessionControlToken: token,
    );
  }

  Future<void> _releaseNativeCommandLease(String trackId) async {
    final adapter = _tracker;
    if (adapter is CommandLeaseTrackerAdapter) {
      await (adapter as CommandLeaseTrackerAdapter)
          .releaseCommandLease(trackId: trackId);
    }
  }

  Future<void> _recoverPendingConfigurationUpdates() async {
    final store = _store;
    if (store is! MutableConfigurationEpochRepository) return;
    final epochStore = store as MutableConfigurationEpochRepository;
    for (var operation in await epochStore.pendingConfigurationUpdates()) {
      final track = await _store.getTrack(operation.trackId);
      if (track == null || track.isTerminal) {
        await epochStore.cancelConfigurationUpdate(operation.id);
        continue;
      }
      if (operation.stage == TrackingConfigurationUpdateStage.pending) {
        await epochStore.cancelConfigurationUpdate(operation.id);
        continue;
      }
      await _bindNativeCommandLease(track.id);
      if (operation.stage == TrackingConfigurationUpdateStage.producerFenced) {
        await _tracker.updateConfig(
          trackId: track.id,
          config: operation.proposedConfig,
        );
        await epochStore.markConfigurationUpdateStage(
          operationId: operation.id,
          stage: TrackingConfigurationUpdateStage.nativeApplied,
        );
        operation = TrackingConfigurationUpdateOperation(
          id: operation.id,
          trackId: operation.trackId,
          epochNumber: operation.epochNumber,
          proposedConfig: operation.proposedConfig,
          previousConfig: operation.previousConfig,
          stage: TrackingConfigurationUpdateStage.nativeApplied,
          createdAt: operation.createdAt,
        );
      }
      if (operation.stage == TrackingConfigurationUpdateStage.nativeApplied) {
        await epochStore.activateConfigurationUpdate(
          operationId: operation.id,
        );
        if (track.status == TrackStatus.active) {
          await _tracker.resume(
            trackId: track.id,
            config: operation.proposedConfig,
          );
        }
      }
    }
  }

  Future<TrackingConfigurationUpdateResult> updateTrackingConfig({
    required TrackingOwner owner,
    required TrackingConfig config,
  }) async {
    await initialize();
    config.validate(context: 'Runtime TrackingConfig');
    return _serializeCommand(() async {
      final store = _store;
      if (store is! MutableConfigurationEpochRepository) {
        throw const TrackingStorageException(
          code: 'capability_unsupported',
          message: 'This repository cannot persist configuration epochs.',
        );
      }
      final track = await _ownerStore.findActiveTrackForOwner(owner);
      if (track == null) {
        throw const TrackingConflictException(
          code: 'no_active_track',
          message: 'Runtime configuration requires an active route.',
        );
      }
      final epochStore = store as MutableConfigurationEpochRepository;
      final operation = await epochStore.beginConfigurationUpdate(
        owner: owner,
        trackId: track.id,
        config: config,
      );
      var stage = operation.stage;
      _acceptingLocations = false;
      try {
        await _pointTail;
        await _drainPendingNativeLocations(trackId: track.id);
        await _bindNativeCommandLease(track.id);
        if (stage == TrackingConfigurationUpdateStage.pending) {
          await _tracker.pause(trackId: track.id);
          await epochStore.markConfigurationUpdateStage(
            operationId: operation.id,
            stage: TrackingConfigurationUpdateStage.producerFenced,
          );
          stage = TrackingConfigurationUpdateStage.producerFenced;
        }
        await _drainPendingNativeLocations(trackId: track.id);
        if (stage == TrackingConfigurationUpdateStage.producerFenced) {
          await _tracker.updateConfig(trackId: track.id, config: config);
          await epochStore.markConfigurationUpdateStage(
            operationId: operation.id,
            stage: TrackingConfigurationUpdateStage.nativeApplied,
          );
          stage = TrackingConfigurationUpdateStage.nativeApplied;
        }
        final epoch = await epochStore.activateConfigurationUpdate(
          operationId: operation.id,
        );
        await _tracker.resume(trackId: track.id, config: config);
        _motionGate = MotionGate(config);
        _acceptingLocations = true;
        _beginFixAcquisition((await _store.getTrack(track.id))!);
        _scheduleBatchUploads(track.id, config);
        _emitStatus(TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: track.id,
          lastPointAt: track.lastPointAt,
          message: 'configuration_updated',
        ));
        return TrackingConfigurationUpdateResult(
          trackId: track.id,
          epoch: epoch,
          resumedCapture: true,
        );
      } on Object {
        if (stage != TrackingConfigurationUpdateStage.nativeApplied) {
          await epochStore.cancelConfigurationUpdate(operation.id);
          try {
            await _tracker.resume(trackId: track.id, config: track.config);
            _acceptingLocations = true;
          } on Object {
            await _store.interruptTrack(
              track.id,
              reason: 'configuration_update_recovery_failed',
            );
          }
        }
        rethrow;
      }
    });
  }

  Never _throwStartConflict(Track track, TrackingOwner owner) {
    if (!owner.owns(track)) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_conflict',
        message:
            'A route from another owner must be resolved before starting a new route.',
      );
    }
    throw TrackingConflictException(
      code: 'active_track_conflict',
      message: 'A same-owner active or resumable route already exists.',
      trackId: track.id,
    );
  }

  @override
  Future<void> completeTrack({
    String? trackId,
    String reason = 'user_completed',
    String? operationId,
  }) async {
    await initialize();
    await _serializeCommand(() async {
      final track = await _resolveTrack(trackId);
      if (track.status == TrackStatus.completed) return;
      if (operationId != null &&
          await _store.wasOperationApplied(
            track.id,
            operationId: operationId,
            type: TrackOperationType.complete,
          )) {
        return;
      }
      final nativeRunning = await _tracker.isRunning();
      final nativeState = await _tracker.runtimeState();
      final nativeTrackId = nativeState.trackId;
      final nativeBelongsToTarget = nativeTrackId == track.id ||
          (nativeRunning &&
              nativeTrackId == null &&
              _currentStatus.trackId == track.id);
      if (nativeRunning && !nativeBelongsToTarget) {
        if (track.status == TrackStatus.active ||
            track.status == TrackStatus.starting ||
            track.status == TrackStatus.stopping) {
          throw StateError(
            'Native tracking belongs to $nativeTrackId, not ${track.id}.',
          );
        }
        final command = await _store.beginLifecycleCommand(
          trackId: track.id,
          type: TrackCommandType.complete,
          reason: reason,
          operationId: operationId,
        );
        // Completing an older paused track must not stop or silence the active
        // native session for a different track.
        await _store.completeTrack(
          track.id,
          reason: command.reason,
          operationId: command.operationId,
        );
        await _store.clearPendingLifecycleCommand(command.id);
        final batchUploader = _batchUploader;
        if (batchUploader != null) {
          await batchUploader.enqueueCompletion(track.id);
          unawaited(_finishUpload(track.id, batchUploader));
        }
        return;
      }
      final command = await _store.beginLifecycleCommand(
        trackId: track.id,
        type: TrackCommandType.complete,
        reason: reason,
        operationId: operationId,
      );
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.stopping,
          trackId: track.id,
        ),
      );
      _acceptingLocations = false;
      if (nativeRunning || nativeTrackId == track.id) {
        try {
          await _bindNativeCommandLease(track.id);
          await _tracker.stop(trackId: track.id, reason: command.reason);
          await _waitUntilNativeStopped();
        } catch (_) {
          _acceptingLocations = true;
          rethrow;
        }
      }
      await _pointTail;
      await _drainPendingNativeLocations(trackId: track.id);
      await _store.completeTrack(
        track.id,
        reason: command.reason,
        operationId: command.operationId,
      );
      await _store.clearPendingLifecycleCommand(command.id);
      await _releaseNativeCommandLease(track.id);
      _clearFixAcquisition();
      _cancelBatchUploads(track.id);
      final remainingActive = await _store.findActiveTrack();
      if (remainingActive == null) {
        _emitStatus(const TrackerStatus(lifecycle: TrackerLifecycle.idle));
      }
      final batchUploader = _batchUploader;
      if (batchUploader != null) {
        await batchUploader.enqueueCompletion(track.id);
        unawaited(_finishUpload(track.id, batchUploader));
      }
    });
  }

  Future<void> _finishUpload(
    String trackId,
    TrackingBatchUploader batchUploader,
  ) async {
    try {
      await batchUploader.tryDrain(trackId);
    } catch (error) {
      await _safeHealthEvent(
        trackId: trackId,
        type: 'upload_failed',
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _recoverPendingLifecycleCommand() async {
    final command = await _store.findPendingLifecycleCommand();
    if (command == null) return;
    var track = await _store.getTrack(command.trackId);
    if (track == null ||
        track.status == TrackStatus.completed ||
        (command.type == TrackCommandType.pause &&
            track.status == TrackStatus.paused)) {
      await _store.clearPendingLifecycleCommand(command.id);
      return;
    }

    final nativeRunning = await _tracker.isRunning();
    final nativeTrackId =
        nativeRunning ? (await _tracker.runtimeState()).trackId : null;
    if (nativeRunning &&
        nativeTrackId != null &&
        nativeTrackId != command.trackId) {
      await _safeHealthEvent(
        trackId: command.trackId,
        type: 'pending_command_track_mismatch',
        details: <String, Object?>{
          'command': command.type.name,
          'nativeTrackId': nativeTrackId,
        },
      );
      return;
    }

    if (track.status == TrackStatus.starting) {
      await _store.markTrackActive(track.id);
      track = (await _store.getTrack(track.id))!;
    }
    if (track.status == TrackStatus.interrupted &&
        command.type == TrackCommandType.pause) {
      await _store.clearPendingLifecycleCommand(command.id);
      return;
    }

    _acceptingLocations = false;
    if (nativeRunning) {
      await _bindNativeCommandLease(command.trackId);
      if (command.type == TrackCommandType.pause) {
        await _tracker.pause(trackId: command.trackId);
      } else {
        await _tracker.stop(
          trackId: command.trackId,
          reason: command.reason,
        );
      }
      await _waitUntilNativeStopped();
    }
    await _pointTail;
    await _drainPendingNativeLocations(trackId: command.trackId);
    if (command.type == TrackCommandType.pause) {
      await _store.pauseTrack(
        command.trackId,
        reason: command.reason,
        operationId: command.operationId,
      );
    } else {
      await _store.completeTrack(
        command.trackId,
        reason: command.reason,
        operationId: command.operationId,
      );
    }
    await _store.clearPendingLifecycleCommand(command.id);
    if (command.type == TrackCommandType.complete) {
      await _releaseNativeCommandLease(command.trackId);
    }
  }

  Future<void> _recoverPendingTripOperations() async {
    final repository = _store;
    if (repository is! TripRepository) return;
    final tripStore = repository as TripRepository;
    for (final operation in await tripStore.pendingTripOperations()) {
      try {
        final trackId = operation.legTrackId;
        if (trackId == null) {
          await tripStore.markTripOperationStage(
            operationRecordId: operation.id,
            stage: TripOperationStage.failed,
          );
          continue;
        }
        final track = await _store.getTrack(trackId);
        if (track == null) {
          await tripStore.markTripOperationStage(
            operationRecordId: operation.id,
            stage: TripOperationStage.failed,
          );
          continue;
        }
        final owner = TrackingOwner(
          userId: track.userId,
          organizationId: track.organizationId,
        );
        switch (operation.type) {
          case TripOperationType.start:
          case TripOperationType.continueTrip:
            await _recoverTripNativeStart(
              tripStore: tripStore,
              operation: operation,
              track: track,
            );
          case TripOperationType.endDay:
          case TripOperationType.complete:
            await _recoverTripFinalization(
              tripStore: tripStore,
              operation: operation,
              track: track,
              owner: owner,
            );
        }
      } on Object catch (error) {
        await _safeHealthEvent(
          trackId: operation.legTrackId,
          type: 'trip_operation_recovery_deferred',
          details: <String, Object?>{
            'tripId': operation.tripId,
            'operationType': operation.type.name,
            'operationStage': operation.stage.name,
            'errorType': error.runtimeType.toString(),
          },
        );
      }
    }
  }

  Future<void> _recoverTripNativeStart({
    required TripRepository tripStore,
    required TripOperationRecord operation,
    required Track track,
  }) async {
    if (track.status == TrackStatus.completed ||
        track.status == TrackStatus.failed) {
      await tripStore.markTripOperationStage(
        operationRecordId: operation.id,
        stage: TripOperationStage.failed,
      );
      return;
    }
    final nativeRunning = await _tracker.isRunning();
    final nativeState = await _tracker.runtimeState();
    if (nativeRunning &&
        nativeState.trackId != null &&
        nativeState.trackId != track.id) {
      throw TrackingTripException(
        code: 'active_trip_conflict',
        message: 'Native capture belongs to a different Trip.',
        tripId: operation.tripId,
      );
    }

    var refreshed = track;
    if (!nativeRunning) {
      final resume = refreshed.status == TrackStatus.paused ||
          refreshed.status == TrackStatus.interrupted;
      if (resume) {
        refreshed = await _store.prepareResume(refreshed.id);
      }
      if (refreshed.status == TrackStatus.starting || resume) {
        await _store.markTrackActive(refreshed.id);
        refreshed = (await _store.getTrack(refreshed.id))!;
      }
      await _bindNativeCommandLease(refreshed.id);
      if (resume) {
        await _tracker.resume(
          trackId: refreshed.id,
          config: refreshed.config,
        );
      } else {
        await _tracker.start(
          trackId: refreshed.id,
          config: refreshed.config,
        );
      }
    } else if (refreshed.status == TrackStatus.starting) {
      await _store.markTrackActive(refreshed.id);
      refreshed = (await _store.getTrack(refreshed.id))!;
    }

    _motionGate = MotionGate(refreshed.config);
    _acceptingLocations = true;
    _beginFixAcquisition(refreshed);
    _scheduleBatchUploads(refreshed.id, refreshed.config);
    await tripStore.markTripOperationStage(
      operationRecordId: operation.id,
      stage: TripOperationStage.completed,
    );
    _emitStatus(
      TrackerStatus(
        lifecycle: TrackerLifecycle.tracking,
        trackId: refreshed.id,
        lastPointAt: refreshed.lastPointAt,
      ),
    );
  }

  Future<void> _recoverTripFinalization({
    required TripRepository tripStore,
    required TripOperationRecord operation,
    required Track track,
    required TrackingOwner owner,
  }) async {
    final nativeRunning = await _tracker.isRunning();
    final nativeState = await _tracker.runtimeState();
    if (nativeRunning &&
        nativeState.trackId != null &&
        nativeState.trackId != track.id) {
      throw TrackingTripException(
        code: 'active_trip_conflict',
        message: 'Native capture belongs to a different Trip.',
        tripId: operation.tripId,
      );
    }
    _acceptingLocations = false;
    if (nativeRunning || nativeState.trackId == track.id) {
      await _bindNativeCommandLease(track.id);
      await _tracker.stop(
        trackId: track.id,
        reason: operation.reason ?? 'trip_operation_recovery',
      );
      await _waitUntilNativeStopped();
    }
    await tripStore.markTripOperationStage(
      operationRecordId: operation.id,
      stage: TripOperationStage.nativeStopped,
    );
    await _pointTail;
    await _drainPendingNativeLocations(trackId: track.id);
    final reason = operation.reason ??
        (operation.type == TripOperationType.complete
            ? 'trip_completed_recovered'
            : 'day_completed_recovered');
    if (operation.type == TripOperationType.complete) {
      await tripStore.completeTripAfterLegCompletion(
        owner: owner,
        tripId: operation.tripId,
        trackId: track.id,
        reason: reason,
        operationId: operation.operationId,
      );
      final outbox = _store;
      if (outbox is TripUploadOutboxRepository) {
        await (outbox as TripUploadOutboxRepository).enqueueTripCompletion(
          owner: owner,
          tripId: operation.tripId,
        );
      }
    } else {
      await tripStore.suspendTripAfterLegCompletion(
        owner: owner,
        tripId: operation.tripId,
        trackId: track.id,
        reason: reason,
        operationId: operation.operationId,
      );
    }
    await _releaseNativeCommandLease(track.id);
    _clearFixAcquisition();
    _cancelBatchUploads(track.id);
    final batchUploader = _batchUploader;
    if (batchUploader != null) {
      await batchUploader.enqueueCompletion(track.id);
      unawaited(_finishUpload(track.id, batchUploader));
    }
  }

  Future<void> _recoverPendingNativeUserAction() async {
    final existing = _nativeUserActionRecovery;
    if (existing != null) return existing;
    final tracker = _tracker as Object;
    if (tracker is! NativeUserActionAdapter) return;
    final adapter = tracker;

    late final Future<void> recovery;
    recovery = _serializeCommand(() async {
      final action = await adapter.pendingUserAction();
      if (action == null) return;
      var track = await _store.getTrack(action.trackId);
      if (track == null) {
        throw StateError(
          'Native ${action.action.name} action references unknown track '
          '${action.trackId}.',
        );
      }
      if (track.status == TrackStatus.starting) {
        await _store.markTrackActive(track.id);
        track = (await _store.getTrack(track.id))!;
      }

      if (action.action == NativeUserActionType.pause) {
        if (track.status != TrackStatus.paused) {
          if (track.status != TrackStatus.active) {
            throw StateError(
              'Cannot apply native pause in ${track.status.name}.',
            );
          }
          _acceptingLocations = false;
          await _pointTail;
          await _drainPendingNativeLocations(trackId: track.id);
          await _store.pauseTrack(
            track.id,
            reason: action.reason,
            operationId: 'native:${action.actionId}',
          );
        }
        _cancelBatchUploads(track.id);
        _emitStatus(
          TrackerStatus(
            lifecycle: TrackerLifecycle.paused,
            trackId: track.id,
            lastPointAt: (await _store.getTrack(track.id))?.lastPointAt,
          ),
        );
        unawaited(_triggerUpload(track.id));
      } else {
        if (track.status != TrackStatus.completed) {
          _acceptingLocations = false;
          await _pointTail;
          if (track.status == TrackStatus.active) {
            await _drainPendingNativeLocations(trackId: track.id);
          }
          await _store.completeTrack(
            track.id,
            reason: action.reason,
            operationId: 'native:${action.actionId}',
          );
        }
        _cancelBatchUploads(track.id);
        final batchUploader = _batchUploader;
        if (batchUploader != null) {
          await batchUploader.enqueueCompletion(track.id);
          unawaited(_finishUpload(track.id, batchUploader));
        }
        final remainingActive = await _store.findActiveTrack();
        if (remainingActive == null) {
          _emitStatus(const TrackerStatus(lifecycle: TrackerLifecycle.idle));
        }
      }
      await adapter.acknowledgePendingUserAction(action.actionId);
    });
    _nativeUserActionRecovery = recovery;
    try {
      await recovery;
    } finally {
      if (identical(_nativeUserActionRecovery, recovery)) {
        _nativeUserActionRecovery = null;
      }
    }
  }

  void _schedulePendingNativeUserActionRecovery() {
    unawaited(
      _recoverPendingNativeUserAction().catchError((Object error) async {
        await _safeHealthEvent(
          trackId: _currentStatus.trackId,
          type: 'native_user_action_recovery_failed',
          details: <String, Object?>{'error': error.toString()},
        );
      }),
    );
  }

  Future<Track> _resolveTrack(String? trackId) async {
    if (trackId != null) {
      final track = await _store.getTrack(trackId);
      if (track == null) throw StateError('Unknown track: $trackId');
      return track;
    }
    final track =
        await _store.findActiveTrack() ?? await _store.findLatestPausedTrack();
    if (track == null) throw StateError('There is no current track.');
    return track;
  }

  void _enqueueLocation(LocationSample sample) {
    _lastNativeFixAt = sample.nativeReceivedAt ?? _clock();
    _lastJournaledAt = sample.nativeReceivedAt;
    if (!_acceptingLocations) {
      if (!_initialized) _initializationLocations.add(sample);
      return;
    }
    _queueLocation(sample);
  }

  void _queueLocation(LocationSample sample) {
    _pointTail = _pointTail.then((_) => _processLocation(sample)).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.failed,
          trackId: _currentStatus.trackId,
          message: 'Could not persist a location fix: $error',
        ),
      );
    });
  }

  Future<void> _processLocation(LocationSample sample) async {
    final track = await _store.findActiveTrack();
    if (track == null || track.status != TrackStatus.active) {
      await _safeHealthEvent(
        type: 'location_without_active_track',
        details: const <String, Object?>{},
      );
      return;
    }
    final sourceTrackId = sample.trackId;
    if (sourceTrackId != null && sourceTrackId != track.id) {
      final point = await _quarantineMismatchedLocation(
        track: track,
        sample: sample,
      );
      await _safeHealthEvent(
        trackId: track.id,
        type: 'location_track_mismatch',
        details: <String, Object?>{
          'sourceTrackId': sourceTrackId,
          'activeTrackId': track.id,
          'eventId': sample.eventId,
          'quarantined': point != null,
        },
      );
      final eventId = sample.eventId;
      if (eventId != null && point != null) {
        await _tracker.acknowledgeLocations(<String>[eventId]);
      }
      return;
    }
    final segmentId = track.currentSegmentId;
    if (segmentId == null) {
      throw StateError('Active track has no current segment.');
    }
    final previousInSegment = await _store.findLastAcceptedPoint(
      track.id,
      segmentId: segmentId,
    );
    final previousAccepted =
        previousInSegment ?? await _store.findLastAcceptedPoint(track.id);
    final continuityStore = _store is ContinuityTrackRepository
        ? _store as ContinuityTrackRepository
        : null;
    final previousRaw = await continuityStore?.findLastRawPoint(track.id);
    final decision = FixQualityPolicy(track.config).evaluate(
      sample: sample,
      previous: previousInSegment,
      now: _clock(),
    );
    final continuityDecision = _classifyContinuity(
      track: track,
      sample: sample,
      quality: decision,
      previousAccepted: previousAccepted,
      previousRaw: previousRaw,
      currentSegmentId: segmentId,
    );
    final capturedActivity = sample.capturedActivity ??
        _recentActivityFor(sample.capturedAt) ??
        const ActivitySnapshot.unknown();
    final capturedMotionState =
        sample.capturedMotionState ?? _motionGate?.state ?? MotionState.unknown;
    final request = PointWriteRequest(
      trackId: track.id,
      sample: sample,
      activity: capturedActivity,
      motionState: capturedMotionState,
      accepted: decision.acceptedForGeometry,
      qualityFlags: decision.qualityFlags,
      rejectionReason: decision.rejectionReason,
    );
    final appendResult = continuityStore == null
        ? PointAppendResult(
            point: await _store.appendPoint(request),
            segmentId: segmentId,
            duplicate: false,
          )
        : await continuityStore.appendPointWithContinuity(
            request,
            continuityDecision,
          );
    final point = appendResult.point;
    final gap = appendResult.gap;
    if (gap != null) {
      await _safeHealthEvent(
        trackId: track.id,
        type: 'continuity_gap_recorded',
        details: <String, Object?>{
          'cause': gap.cause.name,
          'treatment': gap.treatment.name,
          'providerGapMs': gap.providerGap?.inMilliseconds,
          'rawReceiptGapMs': gap.rawReceiptGap?.inMilliseconds,
          'continuityPolicyVersion': gap.continuityPolicyVersion,
        },
      );
    }
    _lastCommittedAt = _clock();
    final eventId = sample.eventId;
    if (eventId != null) {
      await _tracker.acknowledgeLocations(<String>[eventId]);
    }
    if (!_pointController.isClosed) _pointController.add(point);
    _latestPoint = point;
    if (point.accepted) {
      _firstFixTimer?.cancel();
      _firstFixTimer = null;
      _fixState = TrackingFixState.healthy;
      _lastAcceptedAt = point.capturedAt;
    }
    final samplingProfile = switch (capturedMotionState) {
      MotionState.stationary => SamplingProfile.stationary,
      MotionState.moving => SamplingProfile.moving,
      MotionState.unknown =>
        _motionGate?.samplingProfile ?? SamplingProfile.moving,
    };
    _emitStatus(
      TrackerStatus(
        lifecycle: TrackerLifecycle.tracking,
        trackId: track.id,
        lastPointAt: point.capturedAt,
        motionState: capturedMotionState,
        samplingProfile: samplingProfile,
      ),
    );
    if (point.accepted && _batchUploader != null) {
      final updated = await _store.getTrack(track.id);
      if (updated != null &&
          updated.acceptedPointCount % track.config.batchPointCount == 0) {
        unawaited(_triggerUpload(track.id));
      }
    }
  }

  TrackingContinuityDecision? _classifyContinuity({
    required Track track,
    required LocationSample sample,
    required FixQualityDecision quality,
    required TrackPoint? previousAccepted,
    required TrackPoint? previousRaw,
    required String currentSegmentId,
  }) {
    if (previousAccepted == null) return null;

    final acceptedGap = sample.capturedAt.difference(
      previousAccepted.capturedAt,
    );
    final rawReceiptGap = previousRaw?.nativeReceivedAt == null ||
            sample.nativeReceivedAt == null
        ? null
        : sample.nativeReceivedAt!.difference(previousRaw!.nativeReceivedAt!);
    final generationChanged = previousRaw?.captureGenerationId != null &&
        sample.captureGenerationId != null &&
        previousRaw!.captureGenerationId != sample.captureGenerationId;
    final monotonicDomainChanged = previousRaw?.monotonicDomainId != null &&
        sample.monotonicDomainId != null &&
        previousRaw!.monotonicDomainId != sample.monotonicDomainId;
    final alreadyAcrossLifecycleBoundary =
        previousAccepted.segmentId != currentSegmentId;
    final hasInterveningRejectedFixes = previousRaw != null &&
        previousRaw.sequence > previousAccepted.sequence &&
        !previousRaw.accepted;
    final acceptedGapDiagnostic =
        acceptedGap > track.config.acceptedGeometryGapThreshold;
    final rawGapDiagnostic = rawReceiptGap != null &&
        rawReceiptGap > track.config.callbackHealthWarningThreshold;

    if (!acceptedGapDiagnostic &&
        !rawGapDiagnostic &&
        !quality.issues.contains(FixQualityIssue.largeGap) &&
        !generationChanged &&
        !monotonicDomainChanged &&
        !alreadyAcrossLifecycleBoundary &&
        !hasInterveningRejectedFixes) {
      return null;
    }

    final lifecycle = sample.nativeLifecycle ?? _currentStatus.lifecycle;
    final sampling = sample.samplingProfile ?? _currentStatus.samplingProfile;
    final callbackHealthy = rawReceiptGap == null ||
        rawReceiptGap <= track.config.callbackHealthWarningThreshold;
    final batchingObserved = acceptedGapDiagnostic && callbackHealthy;
    return TrackingContinuityClassifier(
      policy: track.config.continuityPolicy,
      policyVersion: TrackingPolicyVersions.continuityPolicy,
    ).classify(
      TrackingContinuityEvidence(
        currentAcceptedForGeometry: quality.acceptedForGeometry,
        expectedTrackId: track.id,
        currentTrackId: sample.trackId ?? track.id,
        previousCaptureGenerationId: previousRaw?.captureGenerationId,
        currentCaptureGenerationId: sample.captureGenerationId,
        previousMonotonicDomainId: previousRaw?.monotonicDomainId,
        currentMonotonicDomainId: sample.monotonicDomainId,
        nativeLifecycle: lifecycle,
        samplingProfile: sampling,
        serviceHealthy: lifecycle == TrackerLifecycle.tracking ||
            lifecycle == TrackerLifecycle.starting,
        permissionAndServiceAvailable: lifecycle != TrackerLifecycle.failed,
        hasInterveningRejectedFixes: hasInterveningRejectedFixes,
        providerBatchingObserved: batchingObserved,
        providerAvailable:
            sample.provider != null && sample.provider!.trim().isNotEmpty,
        explicitBoundaryCause: alreadyAcrossLifecycleBoundary
            ? TrackingGapCause.explicitPause
            : null,
        acceptedGeometryGap: acceptedGap,
        rawReceiptGap: rawReceiptGap,
      ),
    );
  }

  Future<TrackPoint?> _quarantineMismatchedLocation({
    required Track track,
    required LocationSample sample,
  }) async {
    final segmentId = track.currentSegmentId;
    if (segmentId == null) return null;
    final capturedActivity = sample.capturedActivity ??
        _recentActivityFor(sample.capturedAt) ??
        const ActivitySnapshot.unknown();
    final capturedMotionState =
        sample.capturedMotionState ?? _motionGate?.state ?? MotionState.unknown;
    final point = await _store.appendPoint(
      PointWriteRequest(
        trackId: track.id,
        sample: sample,
        activity: capturedActivity,
        motionState: capturedMotionState,
        accepted: false,
        qualityFlags: TrackPointQualityFlag.nativeTrackMismatch,
        rejectionReason: 'native_track_mismatch',
      ),
    );
    if (!_pointController.isClosed) _pointController.add(point);
    _latestPoint = point;
    unawaited(_publishSessionSnapshot());
    return point;
  }

  void _handleActivity(ActivitySnapshot activity) {
    _latestActivity = activity;
    _motionGate?.add(activity, activity.recordedAt ?? _clock());
    if (!_activityController.isClosed) _activityController.add(activity);
    unawaited(_publishSessionSnapshot());
  }

  ActivitySnapshot? _recentActivityFor(DateTime capturedAt) {
    final recordedAt = _latestActivity.recordedAt;
    if (recordedAt == null) return null;
    final age = capturedAt.difference(recordedAt).abs();
    return age <= const Duration(minutes: 5) ? _latestActivity : null;
  }

  void _handleNativeStatus(TrackerStatus status) {
    if (status.lifecycle == TrackerLifecycle.paused ||
        status.lifecycle == TrackerLifecycle.idle) {
      _schedulePendingNativeUserActionRecovery();
    }
    if (status.trackId == null &&
        _currentStatus.lifecycle == TrackerLifecycle.tracking &&
        (status.lifecycle == TrackerLifecycle.idle ||
            status.lifecycle == TrackerLifecycle.paused)) {
      return;
    }
    final explicitlyCurrent =
        status.trackId != null && status.trackId == _currentStatus.trackId;
    final unscopedTransitionIsCurrent = status.trackId == null &&
        _currentStatus.lifecycle != TrackerLifecycle.tracking;
    if (status.lifecycle == TrackerLifecycle.failed ||
        status.lifecycle == TrackerLifecycle.interrupted ||
        ((status.lifecycle == TrackerLifecycle.paused ||
                status.lifecycle == TrackerLifecycle.idle) &&
            (explicitlyCurrent || unscopedTransitionIsCurrent))) {
      _acceptingLocations = false;
    }
    final trackId = status.trackId ?? _currentStatus.trackId;
    _emitStatus(
      TrackerStatus(
        lifecycle: status.lifecycle,
        trackId: trackId,
        lastPointAt: status.lastPointAt ?? _currentStatus.lastPointAt,
        message: status.message,
        motionState: status.motionState,
        samplingProfile: status.samplingProfile,
      ),
    );
    final nativeTrackId = status.trackId;
    if (nativeTrackId != null &&
        (status.lifecycle == TrackerLifecycle.failed ||
            status.lifecycle == TrackerLifecycle.interrupted ||
            status.lifecycle == TrackerLifecycle.idle)) {
      unawaited(_persistNativeTerminalState(nativeTrackId, status));
    }
  }

  Future<void> _persistNativeTerminalState(
    String trackId,
    TrackerStatus nativeStatus,
  ) =>
      _serializeCommand(() async {
        final track = await _store.getTrack(trackId);
        if (track == null ||
            track.status == TrackStatus.completed ||
            track.status == TrackStatus.paused ||
            track.status == TrackStatus.interrupted) {
          return;
        }
        await _pointTail;
        await _drainPendingNativeLocations(trackId: trackId);
        await _store.interruptTrack(
          trackId,
          reason: 'native_${nativeStatus.lifecycle.name}',
        );
        _cancelBatchUploads(trackId);
        final persisted = await _store.getTrack(trackId);
        _emitStatus(
          TrackerStatus(
            lifecycle: nativeStatus.lifecycle == TrackerLifecycle.failed
                ? TrackerLifecycle.failed
                : TrackerLifecycle.interrupted,
            trackId: trackId,
            lastPointAt: persisted?.lastPointAt,
            message: nativeStatus.message,
            motionState: nativeStatus.motionState,
            samplingProfile: nativeStatus.samplingProfile,
          ),
        );
      });

  void _emitStatus(TrackerStatus status) {
    _currentStatus = status;
    if (!_statusController.isClosed) _statusController.add(status);
    unawaited(_publishSessionSnapshot());
  }

  Future<void> _publishSessionSnapshot() async {
    if (!_initialized || _disposed || _sessionController.isClosed) return;
    try {
      final readiness = _latestReadiness ??
          _readinessFrom(
            await _tracker.permissions(),
            _capabilityReport ?? await _tracker.capabilities(),
          );
      final currentTrack = await _store.findActiveTrack() ??
          await _store.findLatestPausedTrack();
      final snapshot = TrackingSessionSnapshot(
        revision: ++_sessionRevision,
        observedAt: _clock(),
        status: _currentStatus,
        currentTrack: currentTrack,
        activity: _latestActivity,
        lastPoint: _latestPoint,
        fixState: _fixState,
        readiness: readiness,
        allowedActions: TrackingLifecycleActions.fromState(
          status: _currentStatus,
          currentTrack: currentTrack,
          readiness: readiness,
        ),
      );
      _currentSession = snapshot;
      _sessionController.add(snapshot);
    } on Object {
      // Snapshot publication is diagnostic/UI support and must not break an
      // in-flight lifecycle or location command.
    }
  }

  void _beginFixAcquisition(Track track) {
    _firstFixTimer?.cancel();
    if (track.acceptedPointCount > 0) {
      _fixState = TrackingFixState.healthy;
      _firstFixTimer = null;
      return;
    }
    _fixState = TrackingFixState.acquiringFix;
    _firstFixTimer = Timer(track.config.firstFixTimeout, () {
      if (_disposed || _currentStatus.trackId != track.id) return;
      if (_currentStatus.lifecycle != TrackerLifecycle.tracking &&
          _currentStatus.lifecycle != TrackerLifecycle.starting) {
        return;
      }
      _fixState = TrackingFixState.firstFixTimedOut;
      unawaited(
        _safeHealthEvent(
          trackId: track.id,
          type: 'first_fix_timeout',
          details: <String, Object?>{
            'timeoutMs': track.config.firstFixTimeout.inMilliseconds,
          },
        ),
      );
      unawaited(_publishSessionSnapshot());
    });
    _startHealthWatchdog(track.config);
    unawaited(_publishSessionSnapshot());
  }

  void _clearFixAcquisition() {
    _firstFixTimer?.cancel();
    _firstFixTimer = null;
    _fixState = TrackingFixState.idle;
    _healthWatchdogTimer?.cancel();
    _healthWatchdogTimer = null;
  }

  void _startHealthWatchdog(TrackingConfig config) {
    _healthWatchdogTimer?.cancel();
    final expected = config.movingInterval > config.stationaryInterval
        ? config.movingInterval
        : config.stationaryInterval;
    final interval = Duration(
      seconds: (expected.inSeconds * 2).clamp(30, 60),
    );
    _healthWatchdogTimer = Timer.periodic(interval, (_) {
      unawaited(_observeHealth());
    });
  }

  Future<void> _observeHealth() async {
    try {
      await healthSnapshot();
    } on Object {
      // Observe-only watchdog failures never alter lifecycle state.
    }
  }

  void _scheduleBatchUploads(String trackId, TrackingConfig config) {
    final uploader = _batchUploader;
    if (uploader == null || config.batchMaxAge <= Duration.zero) return;
    _batchUploadTimer?.cancel();
    _batchUploadTrackId = trackId;
    _batchUploadTimer = Timer.periodic(
      config.batchMaxAge,
      (_) => unawaited(_triggerUpload(trackId)),
    );
  }

  void _startUploadRecoveryLoop() {
    if (_batchUploader == null) return;
    _uploadRecoveryTimer?.cancel();
    _uploadRecoveryTimer = Timer.periodic(
      configuration.uploadRecoveryInterval,
      (_) => unawaited(_triggerAllUploads()),
    );
  }

  Future<void> _triggerUpload(String trackId) async {
    final uploader = _batchUploader;
    if (uploader == null) return;
    try {
      await uploader.tryDrain(trackId);
    } catch (error) {
      await _safeHealthEvent(
        trackId: trackId,
        type: 'upload_failed',
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  Future<void> _triggerAllUploads() async {
    final uploader = _batchUploader;
    if (uploader == null) return;
    try {
      await uploader.tryDrainAll();
    } catch (error) {
      await _safeHealthEvent(
        type: 'upload_recovery_failed',
        details: <String, Object?>{'error': error.toString()},
      );
    }
  }

  void _cancelBatchUploads(String trackId) {
    if (_batchUploadTrackId != trackId) return;
    _batchUploadTimer?.cancel();
    _batchUploadTimer = null;
    _batchUploadTrackId = null;
  }

  Future<void> _safeHealthEvent({
    String? trackId,
    required String type,
    Map<String, Object?>? details,
  }) async {
    try {
      await _store.recordHealthEvent(
        trackId: trackId,
        type: type,
        details: details,
      );
    } on Object {
      // Health logging must never break location capture.
    }
  }

  Future<void> _drainPendingNativeLocations({String? trackId}) async {
    final active = await _store.findActiveTrack();
    if (active == null || (trackId != null && active.id != trackId)) return;
    final tracker = _tracker as Object;
    if (tracker is PagedNativeLocationAdapter) {
      try {
        await _drainPagedNativeLocations(tracker);
        await _drainInitializationLocations();
        return;
      } on TrackingNativeException catch (error) {
        if (error.code != 'capability_unsupported') rethrow;
      }
    }

    final pending = <LocationSample>[...await _tracker.pendingLocations()];
    pending.addAll(_initializationLocations);
    _initializationLocations.clear();
    pending.sort((left, right) {
      final byTime = left.capturedAt.compareTo(right.capturedAt);
      if (byTime != 0) return byTime;
      return (left.eventId ?? '').compareTo(right.eventId ?? '');
    });
    final seenEventIds = <String>{};
    for (final sample in pending) {
      final eventId = sample.eventId;
      if (eventId != null && !seenEventIds.add(eventId)) continue;
      _queueLocation(sample);
    }
    await _pointTail;
  }

  Future<void> _drainPagedNativeLocations(
    PagedNativeLocationAdapter pagedTracker,
  ) async {
    final seenEventIds = <String>{};
    String? cursor;
    for (var pageIndex = 0; pageIndex < 1000; pageIndex += 1) {
      final page = await pagedTracker.pendingLocationPage(cursor: cursor);
      for (final sample in page.events) {
        final eventId = sample.eventId;
        if (eventId != null && !seenEventIds.add(eventId)) continue;
        _queueLocation(sample);
      }
      await _pointTail;
      if (!page.hasMore) return;
      final nextCursor = page.nextCursor;
      if (nextCursor == null || nextCursor == cursor) {
        throw const TrackingNativeException(
          code: 'native_journal_cursor_stalled',
          message: 'The native pending-location page cursor did not advance.',
        );
      }
      cursor = nextCursor;
    }
    throw const TrackingNativeException(
      code: 'native_journal_page_limit_exceeded',
      message: 'The native pending-location journal did not finish draining.',
    );
  }

  Future<void> _drainInitializationLocations() async {
    final pending = <LocationSample>[..._initializationLocations];
    _initializationLocations.clear();
    pending.sort((left, right) {
      final byTime = left.capturedAt.compareTo(right.capturedAt);
      if (byTime != 0) return byTime;
      return (left.eventId ?? '').compareTo(right.eventId ?? '');
    });
    for (final sample in pending) {
      _queueLocation(sample);
    }
    await _pointTail;
  }

  Future<void> _waitUntilNativeStopped() async {
    for (var attempt = 0; attempt < 100; attempt += 1) {
      if (!await _tracker.isRunning()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException(
      'The native tracker did not stop within 5 seconds.',
      const Duration(seconds: 5),
    );
  }

  Future<T> _serializeCommand<T>(Future<T> Function() action) async {
    final previous = _commandTail;
    final completer = Completer<void>();
    _commandTail = completer.future;
    await previous.catchError((Object _) {});
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  @override
  Future<TrackExportResult> exportTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  }) async {
    await initialize();
    await _pointTail;
    return _exports.exportTrack(
      trackId: trackId,
      format: format,
      options: options,
      fileName: fileName,
    );
  }

  Future<Track?> getTrack(String trackId) async {
    await initialize();
    return _store.getTrack(trackId);
  }

  Future<TrackPage> listTrackPage(TrackQuery query) async {
    await initialize();
    final store = _store;
    if (store is PaginatedTrackRepository) {
      return (store as PaginatedTrackRepository).listTrackPage(query);
    }
    throw const TrackingNativeException(
      code: 'capability_unsupported',
      message: 'This track repository does not support paginated history.',
    );
  }

  Future<List<Track>> listTracks() async {
    await initialize();
    return _store.listTracks();
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    await initialize();
    await _serializeCommand(() async {
      await _pointTail;
      await _store.deleteTrack(trackId);
    });
  }

  @override
  Future<TrackBundle> loadTrackBundle(String trackId) async {
    await initialize();
    return _store.loadTrackBundle(trackId);
  }

  Future<LocationSample?> getLastNativeLocation() async {
    await initialize();
    return _tracker.lastLocation();
  }

  Future<bool> openAppSettings() async {
    await initialize();
    return _tracker.openAppSettings();
  }

  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  ) async {
    await initialize();
    if (_tracker is TrackerSettingsAdapter) {
      final settingsAdapter = _tracker as TrackerSettingsAdapter;
      return settingsAdapter.openSettings(destination);
    }
    if (destination == TrackingSettingsDestination.application) {
      return TrackingSettingsResult(
        destination: destination,
        supported: true,
        opened: await _tracker.openAppSettings(),
      );
    }
    return TrackingSettingsResult(
      destination: destination,
      supported: false,
      opened: false,
      message: 'This tracker adapter does not expose settings actions.',
    );
  }

  Future<BatteryOptimizationState> batteryOptimizationState() async {
    await initialize();
    if (_tracker is TrackerSettingsAdapter) {
      final settingsAdapter = _tracker as TrackerSettingsAdapter;
      return settingsAdapter.batteryOptimizationState();
    }
    return const BatteryOptimizationState.unsupported();
  }

  Future<TrackingHealthSnapshot> healthSnapshot() async {
    await initialize();
    final protocol = _tracker is NativeProtocolAdapter
        ? await (_tracker as NativeProtocolAdapter).protocolInfo()
        : NativeTrackingProtocol.legacy();
    final observedAt = _clock();
    final status = await _tracker.runtimeState();
    final readiness = await checkReadiness();
    Map<String, Object?> nativeState = const <String, Object?>{};
    if (_tracker is NativeTrackingHealthAdapter) {
      nativeState =
          await (_tracker as NativeTrackingHealthAdapter).nativeHealthState();
    }
    Map<String, Object?> journal = const <String, Object?>{};
    if (_tracker is NativeJournalDiagnosticsAdapter) {
      journal = await (_tracker as NativeJournalDiagnosticsAdapter)
          .nativeJournalDiagnostic();
    }
    final rawStats = journal['stats'];
    final stats = rawStats is Map
        ? rawStats.map((key, value) => MapEntry(key.toString(), value))
        : const <String, Object?>{};
    final pendingEvents = (stats['pendingRows'] as num?)?.toInt() ??
        (nativeState['pendingLocationCount'] as num?)?.toInt();
    final pendingBytes = (stats['pendingPayloadBytes'] as num?)?.toInt();
    final providerState = providerStateForPermission(readiness.permissions);
    final issues = <TrackingHealthIssue>[
      for (final issue in readiness.issues)
        TrackingHealthIssue(
          code: issue.code,
          blocking: issue.blocking,
          message: issue.message,
        ),
      if (status.lifecycle == TrackerLifecycle.tracking &&
          _fixState == TrackingFixState.firstFixTimedOut)
        const TrackingHealthIssue(
          code: 'first_fix_timeout',
          blocking: false,
        ),
      if (status.lifecycle == TrackerLifecycle.tracking &&
          _lastNativeFixAt != null &&
          observedAt.difference(_lastNativeFixAt!) > const Duration(minutes: 3))
        const TrackingHealthIssue(code: 'native_fix_stale', blocking: false),
      if (journal['healthy'] == false &&
          journal['errorType'] != 'capability_unsupported')
        const TrackingHealthIssue(
          code: 'native_journal_unhealthy',
          blocking: true,
        ),
      if (pendingEvents != null && pendingEvents >= 8000)
        const TrackingHealthIssue(
          code: 'native_queue_pressure',
          blocking: false,
        ),
    ];
    if (issues.any((issue) => issue.code == 'native_fix_stale')) {
      _fixState = TrackingFixState.stale;
    }
    final snapshot = TrackingHealthSnapshot(
      observedAt: observedAt,
      status: status,
      readiness: readiness,
      nativeProtocol: protocol,
      nativeServiceState:
          nativeState['actualState']?.toString() ?? status.lifecycle.name,
      providerState: providerState,
      fixState: _fixState,
      lastNativeFixAt:
          trackingHealthDate(nativeState['lastPointAt']) ?? _lastNativeFixAt,
      lastJournaledAt: _lastJournaledAt,
      lastCommittedAt: _lastCommittedAt,
      lastAcceptedAt: _lastAcceptedAt,
      pendingNativeEvents: pendingEvents,
      pendingNativeBytes: pendingBytes,
      issues: issues,
    );
    _currentHealth = snapshot;
    if (!_healthController.isClosed) _healthController.add(snapshot);
    return snapshot;
  }

  Future<TrackingDoctorReport> runSetupDoctor() async {
    final health = await healthSnapshot();
    final battery = await batteryOptimizationState();
    final findings = <TrackingDoctorFinding>[
      TrackingDoctorFinding(
        code: 'background_tracking_capability',
        severity: TrackingDoctorFindingSeverity.error,
        applicable: true,
        passed: health.readiness.capabilities.backgroundTracking,
        troubleshootingAnchor: '#troubleshooting',
      ),
      TrackingDoctorFinding(
        code: 'location_services',
        severity: TrackingDoctorFindingSeverity.error,
        applicable: true,
        passed: health.providerState != 'disabled',
        troubleshootingAnchor: '#location-permissions',
      ),
      TrackingDoctorFinding(
        code: 'always_location_permission',
        severity: TrackingDoctorFindingSeverity.error,
        applicable: true,
        passed: health.readiness.permissions.canTrackInBackground,
        troubleshootingAnchor: '#location-permissions',
      ),
      TrackingDoctorFinding(
        code: 'precise_location',
        severity: TrackingDoctorFindingSeverity.error,
        applicable: true,
        passed: health.readiness.permissions.preciseLocation,
        troubleshootingAnchor: '#location-permissions',
      ),
      TrackingDoctorFinding(
        code: 'native_journal',
        severity: TrackingDoctorFindingSeverity.error,
        applicable: health.nativeProtocol.supports(
          NativeTrackingCapabilities.nativeJournalDiagnostics,
        ),
        passed: !health.issues
            .any((issue) => issue.code == 'native_journal_unhealthy'),
        troubleshootingAnchor: '#troubleshooting',
      ),
      TrackingDoctorFinding(
        code: 'battery_optimization',
        severity: TrackingDoctorFindingSeverity.warning,
        applicable: battery.supported,
        passed: battery.isIgnoringBatteryOptimizations,
        troubleshootingAnchor: '#battery-optimization',
      ),
    ];
    return TrackingDoctorReport(observedAt: _clock(), findings: findings);
  }

  Future<TrackingSupportReport> createSupportReport() async {
    final health = await healthSnapshot();
    return TrackingSupportReport(
      createdAt: _clock(),
      protocolVersion: health.nativeProtocol.version,
      capabilities: health.nativeProtocol.capabilityCodes,
      health: health,
      batteryOptimization: await batteryOptimizationState(),
    );
  }

  Future<void> deleteExport(TrackExportResult result) async {
    await initialize();
    await _exports.deleteExport(result);
  }

  void _ensureNotDisposed() {
    if (_disposed) throw StateError('TrackingClient is disposed.');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (_initialized && await _tracker.isRunning()) {
      throw StateError('Pause or complete the active track before dispose().');
    }
    _disposed = true;
    _batchUploadTimer?.cancel();
    _uploadRecoveryTimer?.cancel();
    _firstFixTimer?.cancel();
    _healthWatchdogTimer?.cancel();
    await _locationSubscription?.cancel();
    await _activitySubscription?.cancel();
    await _nativeStatusSubscription?.cancel();
    await _currentTrackSubscription?.cancel();
    await _pointTail;
    await _batchUploader?.dispose();
    await _tracker.dispose();
    await _repository?.close();
    await _statusController.close();
    await _activityController.close();
    await _pointController.close();
    await _sessionController.close();
    await _healthController.close();
  }
}

final class _OwnerBoundTrackingController
    implements
        TrackingTripController,
        TrackingDiagnosticsController,
        TrackingConfigurationController,
        TrackingGeometryController {
  _OwnerBoundTrackingController(this._client, this._owner) {
    _sessionSubscription = _client.sessionStream.listen(
      (snapshot) {
        if (!_sessions.isClosed) _sessions.add(_sanitize(snapshot));
      },
      onError: _sessions.addError,
      onDone: _sessions.close,
    );
    final initial = _client.currentSession;
    if (initial != null) _sessions.add(_sanitize(initial));
  }

  final TrackingClient _client;
  TrackingOwner _owner;
  late final StreamSubscription<TrackingSessionSnapshot> _sessionSubscription;
  final StreamController<TrackingSessionSnapshot> _sessions =
      StreamController<TrackingSessionSnapshot>.broadcast();
  final StreamController<TrackHistoryEvent> _history =
      StreamController<TrackHistoryEvent>.broadcast();
  TrackingSessionSnapshot? _snapshot;
  String? _foreignConflictTrackId;
  String? _foreignConflictToken;

  @override
  TrackingHealthSnapshot get currentHealth {
    final health = _client.currentHealth;
    if (health == null) {
      throw StateError('Health is unavailable before initialization.');
    }
    return health;
  }

  @override
  Stream<TrackingHealthSnapshot> get healthStream => _client.healthStream;

  @override
  bool get isInitialized => _client.isInitialized;

  @override
  TrackingOwner get currentOwner => _owner;

  @override
  TrackerStatus get currentStatus => currentSession.status;

  @override
  ActivitySnapshot get currentActivity => currentSession.activity;

  @override
  TrackingSessionSnapshot get currentSession {
    final current = _snapshot;
    if (current != null) return current;
    final source = _client.currentSession;
    if (source == null) {
      throw StateError('The owner-bound controller is not initialized.');
    }
    return _sanitize(source);
  }

  TrackingSessionSnapshot _sanitize(TrackingSessionSnapshot source) {
    final track = source.currentTrack;
    if (track == null || _owner.owns(track)) {
      _foreignConflictTrackId = null;
      _foreignConflictToken = null;
      return _snapshot = source;
    }
    final liveForeign = track.status == TrackStatus.active ||
        track.status == TrackStatus.starting ||
        track.status == TrackStatus.stopping;
    final status = const TrackerStatus(lifecycle: TrackerLifecycle.idle);
    if (liveForeign && _foreignConflictTrackId != track.id) {
      _foreignConflictTrackId = track.id;
      _foreignConflictToken = const Uuid().v4();
    } else if (!liveForeign) {
      _foreignConflictTrackId = null;
      _foreignConflictToken = null;
    }
    final sanitized = TrackingSessionSnapshot(
      revision: source.revision,
      observedAt: source.observedAt,
      status: status,
      currentTrack: null,
      activity: const ActivitySnapshot.unknown(),
      lastPoint: null,
      fixState: TrackingFixState.idle,
      readiness: source.readiness,
      allowedActions: liveForeign
          ? const TrackingLifecycleActions(
              canStartNew: false,
              canPause: false,
              canResume: false,
              canComplete: false,
              commandInProgress: false,
            )
          : TrackingLifecycleActions.fromState(
              status: status,
              currentTrack: null,
              readiness: source.readiness,
            ),
      blockerCode: liveForeign ? 'owner_scope_conflict' : null,
      blockerRecoveryToken: liveForeign ? _foreignConflictToken : null,
    );
    return _snapshot = sanitized;
  }

  @override
  Stream<TrackingSessionSnapshot> get sessionStream =>
      Stream<TrackingSessionSnapshot>.multi(
        (controller) {
          final subscription = _sessions.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          final current = _snapshot;
          if (current != null) controller.add(current);
          controller.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<TrackHistoryEvent> get trackHistoryEvents => _history.stream;

  @override
  bool get supportsPagedHistory =>
      _client._repository is PaginatedTrackRepository;

  @override
  Stream<TrackerStatus> get statusStream =>
      sessionStream.map((snapshot) => snapshot.status);

  @override
  Stream<ActivitySnapshot> get activityStream =>
      sessionStream.map((snapshot) => snapshot.activity);

  @override
  Stream<TrackPoint> get pointStream => _client.pointStream
      .asyncMap((point) async =>
          await _ownedTrack(point.trackId) == null ? null : point)
      .where((point) => point != null)
      .cast<TrackPoint>();

  @override
  Stream<Track?> watchCurrentTrack() =>
      sessionStream.map((snapshot) => snapshot.currentTrack);

  @override
  Future<void> initialize() => _client.initialize();

  @override
  Future<TrackingCapabilityReport> capabilities() => _client.capabilities();

  @override
  Future<TrackingPermissionState> permissions({bool request = false}) =>
      _client.permissions(request: request);

  @override
  Future<TrackingReadiness> checkReadiness() => _client.checkReadiness();

  @override
  Future<TrackingReadiness> requestNextPermission() =>
      _client.requestNextPermission();

  @override
  Future<TrackingReadiness> acknowledgeReadinessEducation(String issueCode) =>
      _client.acknowledgeReadinessEducation(issueCode);

  @override
  Future<OwnerSwitchResult> switchOwner(
    TrackingOwner next, {
    OwnerSwitchPolicy policy = OwnerSwitchPolicy.rejectIfResumable,
  }) async {
    final previous = _owner;
    if (_sameOwner(previous, next)) {
      return OwnerSwitchResult(previous: previous, current: next);
    }
    final active = await _client._store.findActiveTrack();
    if (active != null) {
      if (!previous.owns(active)) {
        throw const TrackingOwnershipException(
          code: 'owner_scope_conflict',
          message:
              'A foreign active capture must be resolved before switching.',
        );
      }
      if (policy != OwnerSwitchPolicy.pauseAndPreserveCurrent) {
        throw TrackingConflictException(
          code: 'active_track_conflict',
          message: 'Pause the active route before switching owner scope.',
          trackId: active.id,
        );
      }
      await _client.pauseTrack(trackId: active.id, reason: 'owner_switched');
    }
    _owner = next;
    final source = _client.currentSession;
    if (source != null && !_sessions.isClosed) _sessions.add(_sanitize(source));
    return OwnerSwitchResult(previous: previous, current: next);
  }

  @override
  Future<OwnerConflictResolutionResult> resolveOwnerConflict(
    OwnerConflictResolutionRequest request,
  ) async {
    if (!request.confirmed) {
      throw const TrackingOwnershipException(
        code: 'owner_conflict_resolution_not_confirmed',
        message: 'Owner-conflict resolution requires explicit confirmation.',
      );
    }
    final trackId = _foreignConflictTrackId;
    if (trackId == null) {
      return const OwnerConflictResolutionResult(
        disposition: OwnerConflictResolutionDisposition.alreadyResolved,
      );
    }
    if (request.conflictToken != _foreignConflictToken) {
      throw const TrackingConflictException(
        code: 'owner_conflict_token_stale',
        message: 'The owner-conflict confirmation is stale; refresh state.',
      );
    }
    final track = await _client._store.getTrack(trackId);
    if (track == null ||
        (track.status != TrackStatus.starting &&
            track.status != TrackStatus.active &&
            track.status != TrackStatus.stopping)) {
      _foreignConflictTrackId = null;
      _foreignConflictToken = null;
      final source = _client.currentSession;
      if (source != null) _sessions.add(_sanitize(source));
      return const OwnerConflictResolutionResult(
        disposition: OwnerConflictResolutionDisposition.alreadyResolved,
      );
    }
    await _client.pauseTrack(
      trackId: trackId,
      reason: 'owner_scope_resolved',
      operationId: request.operationId,
    );
    _foreignConflictTrackId = null;
    _foreignConflictToken = null;
    final source = _client.currentSession;
    if (source != null) _sessions.add(_sanitize(source));
    return const OwnerConflictResolutionResult(
      disposition: OwnerConflictResolutionDisposition.preservedPaused,
    );
  }

  TripRepository get _tripStore {
    final repository = _client._repository;
    if (repository is TripRepository) return repository as TripRepository;
    throw const TrackingStorageException(
      code: 'capability_unsupported',
      message: 'This repository does not support multi-day Trips.',
    );
  }

  @override
  Future<TripStartResult> startTrip(TripStartRequest request) async {
    final operationId = request.operationId ?? const Uuid().v4();
    final existing = await _tripStore.findTripOperationForOwner(
      owner: _owner,
      operationId: operationId,
      type: TripOperationType.start,
    );
    if (existing != null) {
      final bundle =
          await _tripStore.loadTripBundleForOwner(_owner, existing.tripId);
      return TripStartResult(
        trip: bundle.trip,
        leg: bundle.legs.firstWhere(
          (leg) => leg.trackId == existing.legTrackId,
          orElse: () => bundle.legs.first,
        ),
      );
    }
    final trackResult = await startNewTrack(
      TrackStartRequest(
        owner: _owner,
        routeId: request.routeId,
        requestedTrackId: request.requestedTripId,
        config: request.config,
      ),
    );
    final prepared = await _tripStore.registerImplicitTripStart(
      owner: _owner,
      tripId: trackResult.trackId,
      operationId: operationId,
      reason: 'trip_started',
    );
    await _tripStore.markTripOperationStage(
      operationRecordId: prepared.operation.id,
      stage: TripOperationStage.completed,
    );
    return TripStartResult(
      trip: (await _tripStore.getTripForOwner(_owner, prepared.trip.id))!,
      leg: prepared.leg,
    );
  }

  @override
  Future<TripLifecycleResult> endCurrentDay({
    String reason = 'day_completed',
    String? operationId,
  }) async {
    final page = await _tripStore.listTripPage(
      TripQuery(owner: _owner, limit: 1, statuses: const {TripStatus.active}),
    );
    if (page.items.isEmpty) {
      if (operationId != null) {
        final existing = await _tripStore.findTripOperationForOwner(
          owner: _owner,
          operationId: operationId,
          type: TripOperationType.endDay,
        );
        if (existing?.stage == TripOperationStage.completed &&
            existing?.legTrackId != null) {
          final bundle =
              await _tripStore.loadTripBundleForOwner(_owner, existing!.tripId);
          return TripLifecycleResult(
            trip: bundle.trip,
            leg: bundle.legs.firstWhere(
              (leg) => leg.trackId == existing.legTrackId,
            ),
            status: _client.currentStatus,
          );
        }
      }
      throw const TrackingTripException(
        code: 'trip_not_active',
        message: 'There is no active Trip to end for the day.',
      );
    }
    return _finishTrip(
      page.items.single,
      reason: reason,
      operationId: operationId ?? const Uuid().v4(),
      completeTrip: false,
    );
  }

  @override
  Future<TripContinueResult> continueTrip(
    String tripId, {
    TrackingConfig? config,
    String? operationId,
    bool confirmCompletedTripContinuation = false,
  }) async {
    await _client.initialize();
    return _client._serializeCommand(() async {
      final trip = await _tripStore.getTripForOwner(_owner, tripId);
      if (trip == null) {
        throw const TrackingOwnershipException(
          code: 'owner_scope_conflict',
          message: 'The Trip is not available in this owner scope.',
        );
      }
      final readiness = await _client._requireReadinessForNativeStart();
      final selectedConfig = config ??
          (trip.currentLegTrackId == null
              ? _client.configuration.defaultTrackingConfig
              : (await _client._store.getTrack(trip.currentLegTrackId!))
                      ?.config ??
                  _client.configuration.defaultTrackingConfig);
      final prepared = await _tripStore.prepareNextTripLeg(
        owner: _owner,
        tripId: trip.id,
        config: selectedConfig,
        operationId: operationId ?? const Uuid().v4(),
        confirmCompletedTripContinuation: confirmCompletedTripContinuation,
      );
      final initialStatus = prepared.track.status;
      final disposition = prepared.created
          ? TripContinueDisposition.createdLeg
          : initialStatus == TrackStatus.interrupted ||
                  initialStatus == TrackStatus.paused
              ? TripContinueDisposition.resumedInterruptedLeg
              : TripContinueDisposition.reusedActiveLeg;
      try {
        if (prepared.created) {
          await _client._store.markTrackActive(prepared.track.id);
          _client._motionGate = MotionGate(selectedConfig);
          _client._acceptingLocations = true;
          await _client._bindNativeCommandLease(prepared.track.id);
          await _client._tracker.start(
            trackId: prepared.track.id,
            config: selectedConfig,
          );
          _client._beginFixAcquisition(
            (await _client._store.getTrack(prepared.track.id))!,
          );
          _client._scheduleBatchUploads(prepared.track.id, selectedConfig);
        } else if (initialStatus == TrackStatus.interrupted ||
            initialStatus == TrackStatus.paused) {
          await _client._resumeTrack(
            prepared.track.id,
            requestPermission: false,
            precheckedReadiness: readiness,
          );
        } else {
          await _client._activateExistingActiveTrack(prepared.track);
        }
        await _tripStore.markTripOperationStage(
          operationRecordId: prepared.operation.id,
          stage: TripOperationStage.completed,
        );
      } on Object {
        final current = await _client._store.getTrack(prepared.track.id);
        if (current != null &&
            (current.status == TrackStatus.starting ||
                current.status == TrackStatus.active)) {
          await _client._store.interruptTrack(
            current.id,
            reason: 'trip_continue_native_start_failed',
          );
        }
        await _tripStore.markTripOperationStage(
          operationRecordId: prepared.operation.id,
          stage: TripOperationStage.failed,
        );
        rethrow;
      }
      _client._emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: prepared.track.id,
        ),
      );
      _history.add(TrackHistoryEvent(
        kind: prepared.created
            ? TrackHistoryChangeKind.created
            : TrackHistoryChangeKind.updated,
        trackId: prepared.track.id,
      ));
      final bundle = await _tripStore.loadTripBundleForOwner(_owner, trip.id);
      return TripContinueResult(
        trip: bundle.trip,
        leg: bundle.legs.firstWhere(
          (leg) => leg.trackId == prepared.track.id,
        ),
        disposition: disposition,
      );
    });
  }

  @override
  Future<TripLifecycleResult> completeTrip(
    String tripId, {
    String reason = 'trip_completed',
    String? operationId,
  }) async {
    final trip = await _tripStore.getTripForOwner(_owner, tripId);
    if (trip == null) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_conflict',
        message: 'The Trip is not available in this owner scope.',
      );
    }
    if (trip.status == TripStatus.completed) {
      final outbox = _client._store;
      if (outbox is TripUploadOutboxRepository) {
        await (outbox as TripUploadOutboxRepository).enqueueTripCompletion(
          owner: _owner,
          tripId: trip.id,
        );
      }
      final bundle = await _tripStore.loadTripBundleForOwner(_owner, trip.id);
      return TripLifecycleResult(
        trip: bundle.trip,
        leg: bundle.legs.last,
        status: _client.currentStatus,
      );
    }
    return _finishTrip(
      trip,
      reason: reason,
      operationId: operationId ?? const Uuid().v4(),
      completeTrip: true,
    );
  }

  Future<TripLifecycleResult> _finishTrip(
    Trip trip, {
    required String reason,
    required String operationId,
    required bool completeTrip,
  }) async {
    await _client.initialize();
    return _client._serializeCommand(() async {
      final refreshed = await _tripStore.getTripForOwner(_owner, trip.id);
      if (refreshed == null || refreshed.currentLegTrackId == null) {
        throw const TrackingTripException(
          code: 'trip_operation_conflict',
          message: 'The Trip has no current leg.',
        );
      }
      final trackId = refreshed.currentLegTrackId!;
      final track = await _requireOwnedTrack(trackId);
      final operation = await _tripStore.beginTripOperation(
        owner: _owner,
        tripId: refreshed.id,
        trackId: track.id,
        type: completeTrip
            ? TripOperationType.complete
            : TripOperationType.endDay,
        operationId: operationId,
        reason: reason,
      );
      final nativeRunning = await _client._tracker.isRunning();
      final nativeState = await _client._tracker.runtimeState();
      if (nativeRunning &&
          nativeState.trackId != null &&
          nativeState.trackId != track.id) {
        throw TrackingTripException(
          code: 'active_trip_conflict',
          message: 'Native capture belongs to a different Trip.',
          tripId: refreshed.id,
        );
      }
      _client._acceptingLocations = false;
      try {
        if (nativeRunning || nativeState.trackId == track.id) {
          await _client._bindNativeCommandLease(track.id);
          await _client._tracker.stop(trackId: track.id, reason: reason);
          await _client._waitUntilNativeStopped();
        }
      } on Object {
        _client._acceptingLocations = true;
        rethrow;
      }
      await _tripStore.markTripOperationStage(
        operationRecordId: operation.id,
        stage: TripOperationStage.nativeStopped,
      );
      await _client._pointTail;
      await _client._drainPendingNativeLocations(trackId: track.id);
      if (completeTrip) {
        await _tripStore.completeTripAfterLegCompletion(
          owner: _owner,
          tripId: refreshed.id,
          trackId: track.id,
          reason: reason,
          operationId: operationId,
        );
        final outbox = _client._store;
        if (outbox is TripUploadOutboxRepository) {
          await (outbox as TripUploadOutboxRepository).enqueueTripCompletion(
            owner: _owner,
            tripId: refreshed.id,
          );
        }
      } else {
        await _tripStore.suspendTripAfterLegCompletion(
          owner: _owner,
          tripId: refreshed.id,
          trackId: track.id,
          reason: reason,
          operationId: operationId,
        );
      }
      await _client._releaseNativeCommandLease(track.id);
      _client._clearFixAcquisition();
      _client._cancelBatchUploads(track.id);
      _client
          ._emitStatus(const TrackerStatus(lifecycle: TrackerLifecycle.idle));
      final batchUploader = _client._batchUploader;
      if (batchUploader != null) {
        await batchUploader.enqueueCompletion(track.id);
        unawaited(_client._finishUpload(track.id, batchUploader));
      }
      _history.add(TrackHistoryEvent(
        kind: TrackHistoryChangeKind.updated,
        trackId: track.id,
      ));
      final bundle =
          await _tripStore.loadTripBundleForOwner(_owner, refreshed.id);
      return TripLifecycleResult(
        trip: bundle.trip,
        leg: bundle.legs.firstWhere((leg) => leg.trackId == track.id),
        status: _client.currentStatus,
      );
    });
  }

  @override
  Future<Trip?> getTrip(String tripId) =>
      _tripStore.getTripForOwner(_owner, tripId);

  @override
  Future<TripPage> listTripPage(TripQuery query) {
    _requireOwner(query.owner);
    return _tripStore.listTripPage(query);
  }

  @override
  Future<TripBundle> loadTripBundle(String tripId) =>
      _tripStore.loadTripBundleForOwner(_owner, tripId);

  @override
  Future<RouteGeometryReport> assembleTripRouteGeometry(
    String tripId, {
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
  }) async {
    final tripBundle = await _tripStore.loadTripBundleForOwner(_owner, tripId);
    final sourceParts = <RouteGeometrySourcePart>[];
    for (final leg in tripBundle.legs) {
      final trackBundle = await _client._store.loadTrackBundle(leg.trackId);
      final safeLegacyAfterIds = _client._store is LegacyGapEvidenceRepository
          ? await (_client._store as LegacyGapEvidenceRepository)
              .safeLegacyAutomaticAfterSegmentIds(leg.trackId)
          : const <String>{};
      sourceParts.addAll(
        trackBundle.segments.map(
          (source) => RouteGeometrySourcePart(
            legNumber: leg.legNumber,
            segment: source.segment,
            points: source.points,
            legacyAutomaticGapEligible:
                safeLegacyAfterIds.contains(source.segment.id),
          ),
        ),
      );
    }
    return const RouteGeometryAssembler().assemble(
      sourceParts: sourceParts,
      gaps: tripBundle.gaps,
      continuity: continuity,
    );
  }

  @override
  Future<TripExportResult> exportTrip({
    required String tripId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  }) async {
    await _client.initialize();
    return TripExportService(
      repository: _client._store,
      fileWriter: _client._exportFileWriter!,
    ).exportTrip(
      owner: _owner,
      tripId: tripId,
      format: format,
      options: options,
      fileName: fileName,
    );
  }

  @override
  Future<void> deleteTrip(String tripId) async {
    await _client.initialize();
    final bundle = await _tripStore.loadTripBundleForOwner(_owner, tripId);
    if (bundle.trip.status == TripStatus.active ||
        bundle.trip.status == TripStatus.suspended) {
      throw TrackingTripException(
        code: 'trip_not_terminal',
        message: 'Only a terminal Trip can be deleted.',
        tripId: tripId,
      );
    }

    // Managed snapshots and native journal entries live outside the Trip
    // relational cascade, so remove them before the irreversible DB delete.
    final managedExports = TrackExportServiceV2(
      repository: _client._store,
      owner: _owner,
      directoryName: _client.configuration.exportDirectoryName,
    );
    for (final leg in bundle.legs) {
      if (_client._store is ManagedExportRepository) {
        final exports = await managedExports.listManagedExports(leg.trackId);
        for (final export in exports.where(
          (item) => item.state == ManagedExportState.committed.name,
        )) {
          await managedExports.deleteManagedExport(export.id);
        }
      }
      final tracker = _client._tracker;
      if (tracker is TrackScopedNativeDataAdapter) {
        await (tracker as TrackScopedNativeDataAdapter)
            .clearNativeTrackData(leg.trackId);
      }
    }
    await _tripStore.deleteTripForOwner(_owner, tripId);
    _history.add(
      TrackHistoryEvent(kind: TrackHistoryChangeKind.deleted),
    );
  }

  @override
  Future<TrackStartResult> startNewTrack(TrackStartRequest request) async {
    _requireOwner(request.owner);
    final result = await _client.startNewTrack(request);
    _history.add(TrackHistoryEvent(
      kind: TrackHistoryChangeKind.created,
      trackId: result.trackId,
    ));
    return result;
  }

  @override
  Future<TrackStartResult> startOrRecoverTrack(
      TrackStartRequest request) async {
    _requireOwner(request.owner);
    final result = await _client.startOrRecoverTrack(request);
    _history.add(TrackHistoryEvent(
      kind: result.created
          ? TrackHistoryChangeKind.created
          : TrackHistoryChangeKind.updated,
      trackId: result.trackId,
    ));
    return result;
  }

  @override
  Future<TrackStartResult> resumeCurrentTrack() async {
    final result = await _client.resumeCurrentTrack(owner: _owner);
    _history.add(TrackHistoryEvent(
      kind: TrackHistoryChangeKind.updated,
      trackId: result.trackId,
    ));
    return result;
  }

  @override
  Future<TrackLifecycleResult> pauseCurrentTrack({
    String reason = 'user_paused',
  }) async {
    final track = await _currentOwnedTrack();
    await _client.pauseTrack(trackId: track.id, reason: reason);
    final updated = (await _client.getTrack(track.id))!;
    _history.add(TrackHistoryEvent(
      kind: TrackHistoryChangeKind.updated,
      trackId: track.id,
    ));
    return TrackLifecycleResult(track: updated, status: _client.currentStatus);
  }

  @override
  Future<TrackLifecycleResult> completeCurrentTrack({
    String reason = 'user_completed',
  }) async {
    final track = await _currentOwnedTrack();
    await _client.completeTrack(trackId: track.id, reason: reason);
    final updated = (await _client.getTrack(track.id))!;
    _history.add(TrackHistoryEvent(
      kind: TrackHistoryChangeKind.updated,
      trackId: track.id,
    ));
    return TrackLifecycleResult(track: updated, status: _client.currentStatus);
  }

  @override
  Future<String> startTrack({
    required String userId,
    required String organizationId,
    String? routeId,
    String? requestedTrackId,
    TrackingConfig? config,
  }) async {
    final requestedOwner =
        TrackingOwner(userId: userId, organizationId: organizationId);
    _requireOwner(requestedOwner);
    return (await startOrRecoverTrack(TrackStartRequest(
      owner: requestedOwner,
      routeId: routeId,
      requestedTrackId: requestedTrackId,
      config: config,
    )))
        .trackId;
  }

  @override
  Future<void> pauseTrack({
    String? trackId,
    String reason = 'user_paused',
    String? operationId,
  }) async {
    final track = trackId == null
        ? await _currentOwnedTrack()
        : await _requireOwnedTrack(trackId);
    await _client.pauseTrack(
      trackId: track.id,
      reason: reason,
      operationId: operationId,
    );
  }

  @override
  Future<void> resumeTrack(String trackId) async {
    await _requireOwnedTrack(trackId);
    await _client.resumeTrack(trackId);
  }

  @override
  Future<void> completeTrack({
    String? trackId,
    String reason = 'user_completed',
    String? operationId,
  }) async {
    final track = trackId == null
        ? await _currentOwnedTrack()
        : await _requireOwnedTrack(trackId);
    await _client.completeTrack(
      trackId: track.id,
      reason: reason,
      operationId: operationId,
    );
  }

  @override
  Future<TrackExportResult> exportTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  }) async {
    await _requireOwnedTrack(trackId);
    return _client.exportTrack(
      trackId: trackId,
      format: format,
      options: options,
      fileName: fileName,
    );
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    await _requireOwnedTrack(trackId);
    await _client.deleteTrack(trackId);
    _history.add(TrackHistoryEvent(
      kind: TrackHistoryChangeKind.deleted,
      trackId: trackId,
    ));
  }

  @override
  Future<TrackBundle> loadTrackBundle(String trackId) async {
    await _requireOwnedTrack(trackId);
    return _client.loadTrackBundle(trackId);
  }

  @override
  Future<Track?> getTrack(String trackId) => _ownedTrack(trackId);

  @override
  Future<TrackPage> listTrackPage(TrackQuery query) => _client.listTrackPage(
        TrackQuery(
          statuses: query.statuses,
          startedAfter: query.startedAfter,
          startedBefore: query.startedBefore,
          routeId: query.routeId,
          userId: _owner.userId,
          organizationId: _owner.organizationId,
          limit: query.limit,
          cursor: query.cursor,
        ),
      );

  @override
  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  ) =>
      _client.openSettings(destination);

  @override
  Future<BatteryOptimizationState> batteryOptimizationState() =>
      _client.batteryOptimizationState();

  @override
  Future<TrackingDoctorReport> runSetupDoctor() => _client.runSetupDoctor();

  @override
  Future<TrackingSupportReport> createSupportReport() =>
      _client.createSupportReport();

  @override
  Future<TrackingConfigurationUpdateResult> updateTrackingConfig(
    TrackingConfig config,
  ) =>
      _client.updateTrackingConfig(owner: _owner, config: config);

  @override
  Future<DerivedGeometryRun> deriveGeometry(
    String trackId, {
    DerivedGeometryRequest request = const DerivedGeometryRequest(),
  }) async {
    await _requireOwnedTrack(trackId);
    return DerivedGeometryService(_client._store).derive(
      owner: _owner,
      trackId: trackId,
      request: request,
    );
  }

  @override
  Future<List<DerivedGeometryRun>> listDerivedGeometry(String trackId) async {
    await _requireOwnedTrack(trackId);
    final store = _client._store;
    if (store is! DerivedGeometryRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support derived geometry.',
      );
    }
    return (store as DerivedGeometryRepository).listDerivedGeometryRuns(
      owner: _owner,
      trackId: trackId,
    );
  }

  @override
  Future<TrackBundle> loadTrackGeometry(
    String trackId, {
    TrackGeometrySelection geometry = const TrackGeometrySelection.raw(),
  }) async {
    await _requireOwnedTrack(trackId);
    return DerivedGeometryService(_client._store).loadForMap(
      owner: _owner,
      trackId: trackId,
      geometry: geometry,
    );
  }

  @override
  Future<RouteGeometryReport> assembleTrackRouteGeometry(
    String trackId, {
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
  }) async {
    await _requireOwnedTrack(trackId);
    final bundle = await _client._store.loadTrackBundle(trackId);
    final continuityStore = _client._store is ContinuityTrackRepository
        ? _client._store as ContinuityTrackRepository
        : null;
    final legacyStore = _client._store is LegacyGapEvidenceRepository
        ? _client._store as LegacyGapEvidenceRepository
        : null;
    final gaps = await continuityStore?.listContinuityGaps(trackId) ??
        const <TrackingContinuityGap>[];
    final safeLegacyAfterIds =
        await legacyStore?.safeLegacyAutomaticAfterSegmentIds(trackId) ??
            const <String>{};
    return const RouteGeometryAssembler().assemble(
      sourceParts: bundle.segments.map(
        (source) => RouteGeometrySourcePart(
          legNumber: 1,
          segment: source.segment,
          points: source.points,
          legacyAutomaticGapEligible:
              safeLegacyAfterIds.contains(source.segment.id),
        ),
      ),
      gaps: gaps,
      continuity: continuity,
    );
  }

  @override
  Future<void> deleteDerivedGeometry(String trackId, String runId) async {
    await _requireOwnedTrack(trackId);
    final store = _client._store;
    if (store is! DerivedGeometryRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support derived geometry.',
      );
    }
    await (store as DerivedGeometryRepository).deleteDerivedGeometryRun(
      owner: _owner,
      trackId: trackId,
      runId: runId,
    );
  }

  Future<Track?> _ownedTrack(String trackId) async {
    final track = await _client.getTrack(trackId);
    return track != null && _owner.owns(track) ? track : null;
  }

  Future<Track> _requireOwnedTrack(String trackId) async {
    final track = await _ownedTrack(trackId);
    if (track != null) return track;
    throw const TrackingOwnershipException(
      code: 'owner_scope_conflict',
      message: 'The requested route is outside the bound owner scope.',
    );
  }

  Future<Track> _currentOwnedTrack() async {
    final active = await _client._ownerStore.findActiveTrackForOwner(_owner);
    if (active != null) return active;
    final paused =
        await _client._ownerStore.findLatestPausedTrackForOwner(_owner);
    if (paused != null) return paused;
    throw const TrackingConflictException(
      code: 'no_current_track',
      message: 'There is no current route in this owner scope.',
    );
  }

  void _requireOwner(TrackingOwner candidate) {
    if (_sameOwner(candidate, _owner)) return;
    throw const TrackingOwnershipException(
      code: 'owner_scope_conflict',
      message: 'The request owner does not match the controller owner scope.',
    );
  }

  static bool _sameOwner(TrackingOwner first, TrackingOwner second) =>
      first.userId == second.userId &&
      first.organizationId == second.organizationId;

  @override
  Future<void> dispose() async {
    await _sessionSubscription.cancel();
    await _history.close();
    if (!_sessions.isClosed) await _sessions.close();
    await _client.dispose();
  }
}

typedef FlutterBackgroundLocation = TrackingClient;
