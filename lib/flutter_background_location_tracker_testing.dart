/// Pure-Dart fakes for host unit and widget tests.
///
/// Import this library only from tests. The production package does not depend
/// on a platform channel, database, filesystem, map, or state-management
/// library when these fakes are used.
library;

import 'dart:async';
import 'dart:io';

import 'flutter_background_location_tracker.dart';
import 'package:path/path.dart' as path_util;
import 'package:sqflite/sqflite.dart';

import 'src/storage/sqlite_track_repository.dart';

/// A wall and monotonic clock that advances only when the test asks it to.
final class DeterministicTrackingClock {
  DeterministicTrackingClock({
    DateTime? initialTime,
    int initialMonotonicNanos = 0,
  })  : _now = (initialTime ?? DateTime.utc(2026)).toUtc(),
        _monotonicNanos = initialMonotonicNanos;

  DateTime _now;
  int _monotonicNanos;

  DateTime call() => _now;
  int monotonicNanos() => _monotonicNanos;

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Cannot go backwards.');
    }
    _now = _now.add(duration);
    _monotonicNanos += duration.inMicroseconds * 1000;
  }
}

/// Temporary canonical database fixture. Pass an FFI database factory in pure
/// Dart tests or the platform factory in integration tests.
final class TemporaryTrackRepositoryFixture {
  TemporaryTrackRepositoryFixture._(this.directory, this.repository);

  final Directory directory;
  final SqliteTrackRepository repository;

  static Future<TemporaryTrackRepositoryFixture> create({
    required DatabaseFactory databaseFactory,
    DateTime Function()? clock,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'flutter_background_location_tracker_test_',
    );
    final repository = SqliteTrackRepository(
      path: path_util.join(directory.path, 'tracks.sqlite'),
      databaseFactoryOverride: databaseFactory,
      clock: clock,
      singleInstance: false,
    );
    await repository.initialize();
    return TemporaryTrackRepositoryFixture._(directory, repository);
  }

  Future<void> dispose() async {
    await repository.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Generated route samples around a synthetic origin, never a participant's
/// real trace.
final class SyntheticTrackingRoute {
  const SyntheticTrackingRoute(this.locations, this.activities);

  final List<LocationSample> locations;
  final List<ActivitySnapshot> activities;

  factory SyntheticTrackingRoute.walking({
    int pointCount = 20,
    DateTime? startedAt,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    return SyntheticTrackingRoute(
      List<LocationSample>.generate(
        pointCount,
        (index) => LocationSample(
          latitude: index * 0.00001,
          longitude: index * 0.00001,
          horizontalAccuracy: 5,
          capturedAt: start.add(Duration(seconds: index * 5)),
          provider: 'synthetic',
          eventId: 'synthetic-$index',
          mockDetectionAvailable: false,
        ),
        growable: false,
      ),
      <ActivitySnapshot>[
        ActivitySnapshot(
          type: TrackingActivityType.walking,
          confidence: 90,
          recordedAt: start,
        ),
      ],
    );
  }

  factory SyntheticTrackingRoute.stationary({
    int pointCount = 20,
    DateTime? startedAt,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    return SyntheticTrackingRoute(
      List<LocationSample>.generate(
        pointCount,
        (index) => LocationSample(
          latitude: (index.isEven ? 1 : -1) * 0.000001,
          longitude: (index % 3 - 1) * 0.000001,
          horizontalAccuracy: 8,
          capturedAt: start.add(Duration(seconds: index * 15)),
          provider: 'synthetic',
          eventId: 'stationary-$index',
          mockDetectionAvailable: false,
        ),
        growable: false,
      ),
      <ActivitySnapshot>[
        ActivitySnapshot(
          type: TrackingActivityType.stationary,
          confidence: 95,
          recordedAt: start,
        ),
      ],
    );
  }

  void emitTo(FakeTrackerAdapter adapter) {
    for (final activity in activities) {
      adapter.emitActivity(activity);
    }
    for (final location in locations) {
      adapter.emitLocation(location);
    }
  }
}

/// Common permission fixtures for readiness and settings tests.
abstract final class TrackingPermissionFixtures {
  static const ready = FakeTrackerAdapter.fullyReadyPermissionState;
  static const notDetermined = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.unknown,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: false,
    notificationGranted: true,
  );
  static const foregroundOnly = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.whileInUse,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );
  static const deniedForever = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.deniedForever,
    locationServiceEnabled: true,
    preciseLocation: false,
    activityRecognitionGranted: false,
    notificationGranted: false,
  );
  static const servicesDisabled = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.always,
    locationServiceEnabled: false,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );
}

/// In-memory export writer with optional deterministic failure injection.
final class FakeExportFileWriter implements ExportFileWriter {
  final Map<String, String> files = <String, String>{};
  Object? nextWriteError;
  Object? nextDeleteError;

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async {
    final failure = nextWriteError;
    nextWriteError = null;
    if (failure != null) throw failure;
    final path = '/fake/$fileName';
    files[path] = contents;
    return path;
  }

  @override
  Future<void> delete(String path) async {
    final failure = nextDeleteError;
    nextDeleteError = null;
    if (failure != null) throw failure;
    files.remove(path);
  }
}

/// One recorded fake call with sanitized arguments.
final class FakeTrackingCall {
  const FakeTrackingCall(this.method, [this.arguments = const {}]);

  final String method;
  final Map<String, Object?> arguments;
}

/// Deterministic platform adapter for testing a real [TrackingClient].
final class FakeTrackerAdapter
    implements TrackerAdapter, StagedPermissionAdapter, NativeProtocolAdapter {
  FakeTrackerAdapter({
    this.permissionState = fullyReadyPermissionState,
    this.capabilityReport = fullySupportedCapabilityReport,
    NativeTrackingProtocol? protocol,
  }) : protocol = protocol ?? NativeTrackingProtocol.legacy();

  static const fullyReadyPermissionState = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.always,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );

  static const fullySupportedCapabilityReport = TrackingCapabilityReport(
    platform: 'fake',
    backgroundTracking: true,
    activityRecognition: true,
    mockDetection: true,
    pauseResume: true,
    adaptiveSampling: true,
    terminatedRecovery: false,
  );

  TrackingPermissionState permissionState;
  TrackingCapabilityReport capabilityReport;
  NativeTrackingProtocol protocol;
  final List<FakeTrackingCall> calls = <FakeTrackingCall>[];
  final Map<String, Object> failures = <String, Object>{};
  final List<LocationSample> pending = <LocationSample>[];
  final StreamController<LocationSample> _locations =
      StreamController<LocationSample>.broadcast();
  final StreamController<ActivitySnapshot> _activities =
      StreamController<ActivitySnapshot>.broadcast();
  final StreamController<TrackerStatus> _statuses =
      StreamController<TrackerStatus>.broadcast();
  bool _running = false;
  String? _trackId;
  LocationSample? _lastLocation;

  @override
  Stream<LocationSample> get locationStream => _locations.stream;
  @override
  Stream<ActivitySnapshot> get activityStream => _activities.stream;
  @override
  Stream<TrackerStatus> get statusStream => _statuses.stream;

  void emitLocation(LocationSample sample, {bool durablePending = false}) {
    _lastLocation = sample;
    if (durablePending) pending.add(sample);
    _locations.add(sample);
  }

  void emitActivity(ActivitySnapshot activity) => _activities.add(activity);
  void emitStatus(TrackerStatus status) => _statuses.add(status);

  @override
  Future<void> initialize() async {
    _throwIfScheduled('initialize');
    calls.add(const FakeTrackingCall('initialize'));
  }

  @override
  Future<TrackingCapabilityReport> capabilities() async {
    calls.add(const FakeTrackingCall('capabilities'));
    return capabilityReport;
  }

  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async {
    calls.add(FakeTrackingCall('permissions', <String, Object?>{
      'request': request,
    }));
    return permissionState;
  }

  @override
  Future<TrackingPermissionState> requestPermissionStep({
    required TrackingReadinessAction action,
    required int expectedReadinessRevision,
  }) async {
    calls.add(FakeTrackingCall('requestPermissionStep', <String, Object?>{
      'action': action.name,
      'expectedReadinessRevision': expectedReadinessRevision,
    }));
    return permissionState;
  }

  @override
  Future<void> start({
    required String trackId,
    required TrackingConfig config,
  }) async {
    _throwIfScheduled('start');
    calls.add(FakeTrackingCall('start', <String, Object?>{'trackId': trackId}));
    _trackId = trackId;
    _running = true;
  }

  @override
  Future<void> pause({required String trackId}) async {
    _throwIfScheduled('pause');
    calls.add(FakeTrackingCall('pause', <String, Object?>{'trackId': trackId}));
    _running = false;
  }

  @override
  Future<void> resume({
    required String trackId,
    required TrackingConfig config,
  }) async {
    _throwIfScheduled('resume');
    calls
        .add(FakeTrackingCall('resume', <String, Object?>{'trackId': trackId}));
    _trackId = trackId;
    _running = true;
  }

  @override
  Future<void> stop({required String trackId, required String reason}) async {
    _throwIfScheduled('stop');
    calls.add(FakeTrackingCall('stop', <String, Object?>{
      'trackId': trackId,
      'reason': reason,
    }));
    _trackId = null;
    _running = false;
  }

  @override
  Future<void> updateConfig({
    required String trackId,
    required TrackingConfig config,
  }) async {
    _throwIfScheduled('updateConfig');
    calls.add(
      FakeTrackingCall('updateConfig', <String, Object?>{'trackId': trackId}),
    );
  }

  @override
  Future<bool> isRunning() async => _running;

  @override
  Future<TrackerStatus> runtimeState() async => TrackerStatus(
        lifecycle: _running ? TrackerLifecycle.tracking : TrackerLifecycle.idle,
        trackId: _trackId,
      );

  @override
  Future<LocationSample?> lastLocation() async => _lastLocation;

  @override
  Future<List<LocationSample>> pendingLocations() async =>
      List<LocationSample>.unmodifiable(pending);

  @override
  Future<void> acknowledgeLocations(Iterable<String> eventIds) async {
    _throwIfScheduled('acknowledgeLocations');
    final ids = eventIds.toSet();
    calls.add(FakeTrackingCall('acknowledgeLocations', <String, Object?>{
      'count': ids.length,
    }));
    pending.removeWhere((sample) => ids.contains(sample.eventId));
  }

  @override
  Future<bool> openAppSettings() async {
    calls.add(const FakeTrackingCall('openAppSettings'));
    return true;
  }

  @override
  Future<NativeTrackingProtocol> protocolInfo() async => protocol;

  @override
  Future<void> dispose() async {
    calls.add(const FakeTrackingCall('dispose'));
    await _locations.close();
    await _activities.close();
    await _statuses.close();
  }

  void _throwIfScheduled(String method) {
    final failure = failures.remove(method);
    if (failure != null) throw failure;
  }
}

/// In-memory implementation of the normal host facade.
///
/// It is intentionally deterministic and supports the complete lifecycle used
/// by widget tests. Export data is represented by a fake path and route maps
/// contain the points injected through [emitPoint].
final class FakeTrackingController
    implements TrackingController, TrackingConfigurationController {
  FakeTrackingController({
    required TrackingOwner owner,
    DateTime Function()? clock,
    TrackingReadiness? readiness,
  })  : _owner = owner,
        _clock = clock ?? DateTime.now,
        _readiness = readiness ?? _ready();

  TrackingOwner _owner;
  final DateTime Function() _clock;
  TrackingReadiness _readiness;
  final Map<String, Track> _tracks = <String, Track>{};
  final Map<String, List<TrackPoint>> _points = <String, List<TrackPoint>>{};
  final List<FakeTrackingCall> calls = <FakeTrackingCall>[];
  final StreamController<TrackingSessionSnapshot> _sessions =
      StreamController<TrackingSessionSnapshot>.broadcast();
  final StreamController<TrackHistoryEvent> _history =
      StreamController<TrackHistoryEvent>.broadcast();
  ActivitySnapshot _activity = const ActivitySnapshot.unknown();
  TrackingSessionSnapshot? _snapshot;
  int _revision = 0;
  int _nextTrack = 1;
  bool _disposed = false;

  static TrackingReadiness _ready() => TrackingReadiness(
        revision: 1,
        permissions: FakeTrackerAdapter.fullyReadyPermissionState,
        capabilities: FakeTrackerAdapter.fullySupportedCapabilityReport,
        issues: const <TrackingReadinessIssue>[],
        nextAction: TrackingReadinessAction.none,
      );

  @override
  bool get isInitialized => !_disposed;
  @override
  TrackingOwner get currentOwner => _owner;
  @override
  TrackerStatus get currentStatus => currentSession.status;
  @override
  ActivitySnapshot get currentActivity => _activity;
  @override
  TrackingSessionSnapshot get currentSession => _snapshot ??= _buildSnapshot();
  @override
  bool get supportsPagedHistory => true;
  @override
  Stream<TrackHistoryEvent> get trackHistoryEvents => _history.stream;

  @override
  Stream<TrackingSessionSnapshot> get sessionStream =>
      Stream<TrackingSessionSnapshot>.multi(
        (controller) {
          controller.add(currentSession);
          final subscription = _sessions.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<TrackerStatus> get statusStream =>
      sessionStream.map((snapshot) => snapshot.status);
  @override
  Stream<ActivitySnapshot> get activityStream =>
      sessionStream.map((snapshot) => snapshot.activity);
  @override
  Stream<TrackPoint> get pointStream => _pointStream.stream;
  final StreamController<TrackPoint> _pointStream =
      StreamController<TrackPoint>.broadcast();

  @override
  Stream<Track?> watchCurrentTrack() =>
      sessionStream.map((snapshot) => snapshot.currentTrack);

  @override
  Future<void> initialize() async {}
  @override
  Future<TrackingCapabilityReport> capabilities() async =>
      _readiness.capabilities;
  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async =>
      _readiness.permissions;
  @override
  Future<TrackingReadiness> checkReadiness() async {
    calls.add(const FakeTrackingCall('checkReadiness'));
    return _readiness;
  }

  @override
  Future<TrackingReadiness> requestNextPermission() async {
    calls.add(const FakeTrackingCall('requestNextPermission'));
    return _readiness;
  }

  @override
  Future<TrackingReadiness> acknowledgeReadinessEducation(
      String issueCode) async {
    calls.add(FakeTrackingCall(
      'acknowledgeReadinessEducation',
      <String, Object?>{'issueCode': issueCode},
    ));
    return _readiness;
  }

  void setReadiness(TrackingReadiness readiness) {
    _readiness = readiness;
    _publish();
  }

  void emitActivity(ActivitySnapshot activity) {
    _activity = activity;
    _publish();
  }

  TrackPoint emitPoint({
    required double latitude,
    required double longitude,
    bool accepted = true,
  }) {
    final track = _currentTrack;
    if (track == null || track.status != TrackStatus.active) {
      throw StateError('Start or resume a fake route before emitting points.');
    }
    final values = _points.putIfAbsent(track.id, () => <TrackPoint>[]);
    final now = _clock().toUtc();
    final point = TrackPoint(
      id: 'fake-point-${values.length + 1}',
      trackId: track.id,
      segmentId: track.currentSegmentId!,
      sequence: values.length + 1,
      latitude: latitude,
      longitude: longitude,
      capturedAt: now,
      persistedAt: now,
      activityType: _activity.type,
      activityConfidence: _activity.confidence,
      motionState: MotionState.moving,
      isMocked: false,
      mockDetectionAvailable: true,
      accepted: accepted,
      qualityFlags: TrackPointQualityFlag.none,
    );
    values.add(point);
    _tracks[track.id] = _copyTrack(
      track,
      acceptedPointCount: track.acceptedPointCount + (accepted ? 1 : 0),
      rejectedPointCount: track.rejectedPointCount + (accepted ? 0 : 1),
      nextSequence: point.sequence + 1,
      lastPointAt: now,
    );
    _pointStream.add(point);
    _publish();
    return point;
  }

  /// Seeds a resumable interrupted route to simulate process restoration.
  Track seedInterruptedTrack({
    String trackId = 'fake-interrupted-track',
    String? routeId,
    TrackingConfig config = const TrackingConfig(),
  }) {
    final now = _clock().toUtc();
    final track = Track(
      id: trackId,
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      routeId: routeId,
      status: TrackStatus.interrupted,
      startedAt: now.subtract(const Duration(minutes: 5)),
      pausedAt: now,
      totalDistanceMeters: 0,
      acceptedPointCount: 0,
      rejectedPointCount: 0,
      segmentCount: 1,
      nextSequence: 1,
      currentSegmentId: null,
      completionReason: 'process_terminated',
      config: config,
    );
    _tracks[trackId] = track;
    _points[trackId] = <TrackPoint>[];
    calls.add(FakeTrackingCall(
      'seedInterruptedTrack',
      <String, Object?>{'trackId': trackId},
    ));
    _publish();
    return track;
  }

  @override
  Future<TrackStartResult> startNewTrack(TrackStartRequest request) async {
    _requireOwner(request.owner);
    if (_currentTrack?.isResumable == true ||
        _currentTrack?.status == TrackStatus.active) {
      throw const TrackingConflictException(
        code: 'active_track_conflict',
        message: 'A fake route is already active or resumable.',
      );
    }
    if (!_readiness.canStart) {
      throw const TrackingNotReadyException(
        code: 'tracking_not_ready',
        message: 'Fake readiness blocks Start.',
      );
    }
    final now = _clock().toUtc();
    final id = request.requestedTrackId ?? 'fake-track-${_nextTrack++}';
    final track = Track(
      id: id,
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      routeId:
          request.routeId == null ? null : createRouteId(request.routeId!, now),
      status: TrackStatus.active,
      startedAt: now,
      totalDistanceMeters: 0,
      acceptedPointCount: 0,
      rejectedPointCount: 0,
      segmentCount: 1,
      nextSequence: 1,
      currentSegmentId: '$id-segment-1',
      config: request.config ?? const TrackingConfig(),
    );
    _tracks[id] = track;
    _points[id] = <TrackPoint>[];
    calls.add(
        FakeTrackingCall('startNewTrack', <String, Object?>{'trackId': id}));
    _history.add(
        TrackHistoryEvent(kind: TrackHistoryChangeKind.created, trackId: id));
    _publish();
    return TrackStartResult(
      track: track,
      disposition: TrackStartDisposition.created,
      readiness: _readiness,
    );
  }

  @override
  Future<TrackStartResult> startOrRecoverTrack(
      TrackStartRequest request) async {
    _requireOwner(request.owner);
    final current = _currentTrack;
    if (current == null || current.isTerminal) return startNewTrack(request);
    if (current.status == TrackStatus.active) {
      return TrackStartResult(
        track: current,
        disposition: TrackStartDisposition.reusedActive,
        readiness: _readiness,
      );
    }
    return _resume(current);
  }

  @override
  Future<TrackStartResult> resumeCurrentTrack() async {
    final track = _currentTrack;
    if (track == null || !track.isResumable) {
      throw const TrackingConflictException(
        code: 'no_resumable_track',
        message: 'There is no resumable fake route.',
      );
    }
    return _resume(track);
  }

  Future<TrackStartResult> _resume(Track track) async {
    final updated = _copyTrack(
      track,
      status: TrackStatus.active,
      resumedAt: _clock().toUtc(),
      currentSegmentId: '${track.id}-segment-${track.segmentCount + 1}',
      segmentCount: track.segmentCount + 1,
    );
    _tracks[track.id] = updated;
    calls.add(
        FakeTrackingCall('resume', <String, Object?>{'trackId': track.id}));
    _publish();
    return TrackStartResult(
      track: updated,
      disposition: track.status == TrackStatus.interrupted
          ? TrackStartDisposition.resumedInterrupted
          : TrackStartDisposition.resumedPaused,
      readiness: _readiness,
    );
  }

  @override
  Future<TrackLifecycleResult> pauseCurrentTrack({
    String reason = 'user_paused',
  }) async {
    final track = _requireCurrent();
    final updated = _copyTrack(
      track,
      status: TrackStatus.paused,
      pausedAt: _clock().toUtc(),
      currentSegmentId: null,
      clearCurrentSegment: true,
    );
    _tracks[track.id] = updated;
    calls
        .add(FakeTrackingCall('pause', <String, Object?>{'trackId': track.id}));
    _publish();
    return TrackLifecycleResult(track: updated, status: currentStatus);
  }

  @override
  Future<TrackLifecycleResult> completeCurrentTrack({
    String reason = 'user_completed',
  }) async {
    final track = _requireCurrent();
    final updated = _copyTrack(
      track,
      status: TrackStatus.completed,
      endedAt: _clock().toUtc(),
      completionReason: reason,
      currentSegmentId: null,
      clearCurrentSegment: true,
    );
    _tracks[track.id] = updated;
    calls.add(
        FakeTrackingCall('complete', <String, Object?>{'trackId': track.id}));
    _publish();
    return TrackLifecycleResult(track: updated, status: currentStatus);
  }

  @override
  Future<OwnerSwitchResult> switchOwner(
    TrackingOwner next, {
    OwnerSwitchPolicy policy = OwnerSwitchPolicy.rejectIfResumable,
  }) async {
    final previous = _owner;
    if (_currentTrack?.status == TrackStatus.active) {
      if (policy != OwnerSwitchPolicy.pauseAndPreserveCurrent) {
        throw const TrackingConflictException(
          code: 'active_track_conflict',
          message: 'Pause the fake route before switching owner.',
        );
      }
      await pauseCurrentTrack(reason: 'owner_switched');
    }
    _owner = next;
    _publish();
    return OwnerSwitchResult(previous: previous, current: next);
  }

  @override
  Future<OwnerConflictResolutionResult> resolveOwnerConflict(
    OwnerConflictResolutionRequest request,
  ) async {
    if (!request.confirmed) {
      throw const TrackingOwnershipException(
        code: 'owner_conflict_resolution_not_confirmed',
        message: 'Fake owner-conflict resolution requires confirmation.',
      );
    }
    return const OwnerConflictResolutionResult(
      disposition: OwnerConflictResolutionDisposition.alreadyResolved,
    );
  }

  @override
  Future<String> startTrack({
    required String userId,
    required String organizationId,
    String? routeId,
    String? requestedTrackId,
    TrackingConfig? config,
  }) async =>
      (await startOrRecoverTrack(TrackStartRequest(
        owner: TrackingOwner(userId: userId, organizationId: organizationId),
        routeId: routeId,
        requestedTrackId: requestedTrackId,
        config: config,
      )))
          .trackId;

  @override
  Future<void> pauseTrack(
      {String? trackId,
      String reason = 'user_paused',
      String? operationId}) async {
    _requireTrack(trackId);
    await pauseCurrentTrack(reason: reason);
  }

  @override
  Future<void> resumeTrack(String trackId) async {
    _requireTrack(trackId);
    await resumeCurrentTrack();
  }

  @override
  Future<void> completeTrack(
      {String? trackId,
      String reason = 'user_completed',
      String? operationId}) async {
    _requireTrack(trackId);
    await completeCurrentTrack(reason: reason);
  }

  @override
  Future<Track?> getTrack(String trackId) async {
    final track = _tracks[trackId];
    return track != null && _owner.owns(track) ? track : null;
  }

  @override
  Future<TrackPage> listTrackPage(TrackQuery query) async {
    final values = _tracks.values.where(_owner.owns).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return TrackPage(
      items: List<Track>.unmodifiable(values.take(query.limit)),
      hasMore: values.length > query.limit,
    );
  }

  @override
  Future<TrackBundle> loadTrackBundle(String trackId) async {
    final track = await getTrack(trackId);
    if (track == null) throw StateError('Unknown fake route.');
    final points = List<TrackPoint>.unmodifiable(_points[trackId] ?? const []);
    final segments = <TrackSegmentWithPoints>[];
    for (var number = 1; number <= track.segmentCount; number += 1) {
      final id = '${track.id}-segment-$number';
      final segmentPoints = points
          .where((point) => point.segmentId == id)
          .toList(growable: false);
      segments.add(TrackSegmentWithPoints(
        segment: TrackSegment(
          id: id,
          trackId: track.id,
          segmentNumber: number,
          status: track.status == TrackStatus.completed
              ? TrackSegmentStatus.completed
              : number == track.segmentCount &&
                      track.status == TrackStatus.active
                  ? TrackSegmentStatus.active
                  : TrackSegmentStatus.paused,
          startedAt: segmentPoints.isEmpty
              ? track.startedAt
              : segmentPoints.first.capturedAt,
          endedAt: track.status == TrackStatus.completed ? track.endedAt : null,
          distanceMeters: 0,
          acceptedPointCount:
              segmentPoints.where((point) => point.accepted).length,
        ),
        points: List<TrackPoint>.unmodifiable(segmentPoints),
      ));
    }
    return TrackBundle(
      track: track,
      segments: segments,
    );
  }

  @override
  Future<TrackExportResult> exportTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  }) async {
    final track = await getTrack(trackId);
    if (track == null) throw StateError('Unknown fake route.');
    final extension = switch (format) {
      TrackExportFormat.geoJson => 'geojson',
      TrackExportFormat.kml => 'kml',
      TrackExportFormat.gpx => 'gpx',
    };
    final name = fileName ?? '${track.routeId ?? track.id}.$extension';
    calls.add(
        FakeTrackingCall('exportTrack', <String, Object?>{'trackId': trackId}));
    return TrackExportResult(
      trackId: trackId,
      format: format,
      fileName: name,
      mimeType: 'application/octet-stream',
      path: '/fake/$name',
      pointCount: _points[trackId]?.length ?? 0,
      segmentCount: track.segmentCount,
    );
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    final track = await getTrack(trackId);
    if (track == null) throw StateError('Unknown fake route.');
    if (!track.isTerminal) throw StateError('Complete the fake route first.');
    _tracks.remove(trackId);
    _points.remove(trackId);
    _history.add(TrackHistoryEvent(
        kind: TrackHistoryChangeKind.deleted, trackId: trackId));
    _publish();
  }

  @override
  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  ) async {
    calls.add(
      FakeTrackingCall(
        'openSettings',
        <String, Object?>{'destination': destination.name},
      ),
    );
    return TrackingSettingsResult(
      destination: destination,
      supported: true,
      opened: true,
    );
  }

  @override
  Future<TrackingConfigurationUpdateResult> updateTrackingConfig(
    TrackingConfig config,
  ) async {
    config.validate(context: 'Fake runtime TrackingConfig');
    final track = _requireCurrent();
    if (track.status != TrackStatus.active) {
      throw StateError('A fake route must be active to update configuration.');
    }
    final updated = Track(
      id: track.id,
      userId: track.userId,
      organizationId: track.organizationId,
      routeId: track.routeId,
      status: track.status,
      startedAt: track.startedAt,
      pausedAt: track.pausedAt,
      resumedAt: track.resumedAt,
      endedAt: track.endedAt,
      totalDistanceMeters: track.totalDistanceMeters,
      acceptedPointCount: track.acceptedPointCount,
      rejectedPointCount: track.rejectedPointCount,
      segmentCount: track.segmentCount,
      nextSequence: track.nextSequence,
      currentSegmentId: track.currentSegmentId,
      lastPointAt: track.lastPointAt,
      completionReason: track.completionReason,
      config: config,
    );
    _tracks[track.id] = updated;
    final now = _clock().toUtc();
    final epoch = TrackingConfigurationEpoch(
      id: 'fake-epoch-${track.id}-${track.nextSequence}',
      trackId: track.id,
      epochNumber: track.segmentCount + 1,
      resolvedConfig: config,
      presetDefinitionVersion: TrackingPolicyVersions.presetDefinition,
      qualityPolicyVersion: TrackingPolicyVersions.qualityPolicy,
      createdAt: now,
      activationSequence: track.nextSequence,
      activatedAt: now,
    );
    calls.add(FakeTrackingCall(
      'updateTrackingConfig',
      <String, Object?>{'trackId': track.id},
    ));
    _publish();
    return TrackingConfigurationUpdateResult(
      trackId: track.id,
      epoch: epoch,
      resumedCapture: true,
    );
  }

  Track? get _currentTrack {
    final candidates = _tracks.values.where(
      (track) =>
          _owner.owns(track) &&
          (track.status == TrackStatus.active || track.isResumable),
    );
    return candidates.isEmpty ? null : candidates.last;
  }

  Track _requireCurrent() {
    final track = _currentTrack;
    if (track == null) throw StateError('There is no current fake route.');
    return track;
  }

  void _requireTrack(String? trackId) {
    if (trackId != null && _currentTrack?.id != trackId) {
      throw StateError('The fake route is not current.');
    }
    _requireCurrent();
  }

  void _requireOwner(TrackingOwner owner) {
    if (owner.userId != _owner.userId ||
        owner.organizationId != _owner.organizationId) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_conflict',
        message: 'The fake request owner does not match the bound owner.',
      );
    }
  }

  TrackingSessionSnapshot _buildSnapshot() {
    final track = _currentTrack;
    final lifecycle = switch (track?.status) {
      TrackStatus.active => TrackerLifecycle.tracking,
      TrackStatus.paused => TrackerLifecycle.paused,
      TrackStatus.interrupted => TrackerLifecycle.interrupted,
      _ => TrackerLifecycle.idle,
    };
    final status = TrackerStatus(lifecycle: lifecycle, trackId: track?.id);
    return TrackingSessionSnapshot(
      revision: ++_revision,
      observedAt: _clock().toUtc(),
      status: status,
      currentTrack: track,
      activity: _activity,
      lastPoint: track == null || (_points[track.id]?.isEmpty ?? true)
          ? null
          : _points[track.id]!.last,
      readiness: _readiness,
      allowedActions: TrackingLifecycleActions.fromState(
        status: status,
        currentTrack: track,
        readiness: _readiness,
      ),
    );
  }

  void _publish() {
    _snapshot = _buildSnapshot();
    if (!_sessions.isClosed) _sessions.add(_snapshot!);
  }

  static Track _copyTrack(
    Track source, {
    TrackStatus? status,
    DateTime? pausedAt,
    DateTime? resumedAt,
    DateTime? endedAt,
    int? acceptedPointCount,
    int? rejectedPointCount,
    int? segmentCount,
    int? nextSequence,
    String? currentSegmentId,
    bool clearCurrentSegment = false,
    DateTime? lastPointAt,
    String? completionReason,
  }) =>
      Track(
        id: source.id,
        userId: source.userId,
        organizationId: source.organizationId,
        routeId: source.routeId,
        status: status ?? source.status,
        startedAt: source.startedAt,
        pausedAt: pausedAt ?? source.pausedAt,
        resumedAt: resumedAt ?? source.resumedAt,
        endedAt: endedAt ?? source.endedAt,
        totalDistanceMeters: source.totalDistanceMeters,
        acceptedPointCount: acceptedPointCount ?? source.acceptedPointCount,
        rejectedPointCount: rejectedPointCount ?? source.rejectedPointCount,
        segmentCount: segmentCount ?? source.segmentCount,
        nextSequence: nextSequence ?? source.nextSequence,
        currentSegmentId: clearCurrentSegment
            ? null
            : (currentSegmentId ?? source.currentSegmentId),
        lastPointAt: lastPointAt ?? source.lastPointAt,
        completionReason: completionReason ?? source.completionReason,
        terminalReasonCode: source.terminalReasonCode,
        sessionControlToken: source.sessionControlToken,
        config: source.config,
      );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sessions.close();
    await _history.close();
    await _pointStream.close();
  }
}
