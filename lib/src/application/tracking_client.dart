import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path_util;
import 'package:sqflite/sqflite.dart';

import '../domain/activity_snapshot.dart';
import '../domain/capability_report.dart';
import '../domain/export_models.dart';
import '../domain/location_sample.dart';
import '../domain/permission_state.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../export/track_export_service.dart';
import '../platform/native_tracker_adapter.dart';
import '../platform/tracker_adapter.dart';
import '../storage/sqlite_track_repository.dart';
import '../storage/track_repository.dart';
import '../upload/track_uploader.dart';
import '../upload/tracking_batch_uploader.dart';
import 'motion_gate.dart';
import 'position_validator.dart';

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

class TrackingClient implements Tracking {
  TrackingClient({
    this.configuration = const TrackingConfiguration(),
    TrackerAdapter? trackerAdapter,
    TrackRepository? repository,
    ExportFileWriter? exportFileWriter,
    TrackUploader? uploader,
    DateTime Function()? clock,
  })  : _tracker = trackerAdapter ?? NativeTrackerAdapter(),
        _repository = repository,
        _exportFileWriter = exportFileWriter,
        _uploader = uploader,
        _clock = clock ?? _utcNow;

  final TrackingConfiguration configuration;
  final TrackerAdapter _tracker;
  TrackRepository? _repository;
  ExportFileWriter? _exportFileWriter;
  final TrackUploader? _uploader;
  final DateTime Function() _clock;

  final StreamController<TrackerStatus> _statusController =
      StreamController<TrackerStatus>.broadcast();
  final StreamController<ActivitySnapshot> _activityController =
      StreamController<ActivitySnapshot>.broadcast();
  final StreamController<TrackPoint> _pointController =
      StreamController<TrackPoint>.broadcast();

  StreamSubscription<LocationSample>? _locationSubscription;
  StreamSubscription<ActivitySnapshot>? _activitySubscription;
  StreamSubscription<TrackerStatus>? _nativeStatusSubscription;
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
  String? _batchUploadTrackId;
  bool _initialized = false;
  bool _disposed = false;
  bool _acceptingLocations = false;
  final List<LocationSample> _initializationLocations = <LocationSample>[];

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

  @override
  Stream<Track?> watchCurrentTrack() => _store.currentTrackStream;

  @override
  Future<void> initialize() {
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
    await _reconcile();
    await _drainPendingNativeLocations();
    await _drainPendingNativeLocations();
    _initialized = true;
    _acceptingLocations = _currentStatus.lifecycle == TrackerLifecycle.tracking;
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
            await _tracker.start(trackId: active.id, config: active.config);
          }
          _motionGate = MotionGate(active.config);
          _acceptingLocations = true;
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
      final trackId = await _store.createTrack(
        userId: userId,
        organizationId: organizationId,
        routeId: routeId == null ? null : createRouteId(routeId, _clock()),
        config: selectedConfig,
        requestedTrackId: requestedTrackId,
      );
      await _applyRecordRetention(retainedTrackId: trackId);
      _motionGate = MotionGate(selectedConfig);
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
        await _tracker.start(trackId: trackId, config: selectedConfig);
        _emitStatus(
          TrackerStatus(
            lifecycle: TrackerLifecycle.tracking,
            trackId: trackId,
          ),
        );
        _scheduleBatchUploads(trackId, selectedConfig);
        return trackId;
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
    });
  }

  Future<void> _applyRecordRetention({required String retainedTrackId}) async {
    if (configuration.recordRetentionPolicy !=
        TrackRecordRetentionPolicy.keepLatestOnly) {
      return;
    }
    await _store.deleteTracksExcept(<String>{retainedTrackId});
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

  Future<void> _resumeTrack(String trackId) async {
    final existing = await _store.getTrack(trackId);
    if (existing == null) throw StateError('Unknown track: $trackId');
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
    final permission = await _tracker.permissions(request: true);
    if (!permission.canTrackInBackground) {
      throw TrackingPermissionException(permission);
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
      final nativeTrackId =
          nativeRunning ? (await _tracker.runtimeState()).trackId : null;
      final nativeBelongsToTarget = nativeTrackId == track.id ||
          (nativeTrackId == null && _currentStatus.trackId == track.id);
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
      if (nativeRunning) {
        try {
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
  }

  Future<void> _recoverPendingNativeUserAction() async {
    final existing = _nativeUserActionRecovery;
    if (existing != null) return existing;
    final tracker = _tracker;
    if (tracker is! NativeUserActionAdapter) return;
    final adapter = tracker as NativeUserActionAdapter;

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
      await _safeHealthEvent(
        trackId: track.id,
        type: 'location_track_mismatch',
        details: <String, Object?>{
          'sourceTrackId': sourceTrackId,
          'activeTrackId': track.id,
          'eventId': sample.eventId,
        },
      );
      final eventId = sample.eventId;
      if (eventId != null) {
        await _tracker.acknowledgeLocations(<String>[eventId]);
      }
      return;
    }
    final segmentId = track.currentSegmentId;
    if (segmentId == null) {
      throw StateError('Active track has no current segment.');
    }
    final previous = await _store.findLastAcceptedPoint(
      track.id,
      segmentId: segmentId,
    );
    final validation = PositionValidator(track.config).validate(
      sample: sample,
      previous: previous,
      now: _clock(),
    );
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
        accepted: validation.accepted,
        qualityFlags: validation.qualityFlags,
        rejectionReason: validation.rejectionReason,
      ),
    );
    final eventId = sample.eventId;
    if (eventId != null) {
      await _tracker.acknowledgeLocations(<String>[eventId]);
    }
    if (!_pointController.isClosed) _pointController.add(point);
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

  void _handleActivity(ActivitySnapshot activity) {
    _latestActivity = activity;
    _motionGate?.add(activity, activity.recordedAt ?? _clock());
    if (!_activityController.isClosed) _activityController.add(activity);
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
    final pending = <LocationSample>[
      ...await _tracker.pendingLocations(),
      ..._initializationLocations,
    ];
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
    await _locationSubscription?.cancel();
    await _activitySubscription?.cancel();
    await _nativeStatusSubscription?.cancel();
    await _pointTail;
    await _batchUploader?.dispose();
    await _tracker.dispose();
    await _repository?.close();
    await _statusController.close();
    await _activityController.close();
    await _pointController.close();
  }
}

typedef FlutterBackgroundLocation = TrackingClient;
