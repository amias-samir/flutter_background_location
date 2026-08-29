import 'dart:async';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

final class _MemoryWriter implements ExportFileWriter {
  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async =>
      '/exports/$fileName';
}

final class _FakeTracker
    implements
        TrackerAdapter,
        NativeUserActionAdapter,
        StagedPermissionAdapter,
        TrackScopedNativeDataAdapter {
  final StreamController<LocationSample> locations =
      StreamController<LocationSample>.broadcast();
  final StreamController<ActivitySnapshot> activities =
      StreamController<ActivitySnapshot>.broadcast();
  final StreamController<TrackerStatus> statuses =
      StreamController<TrackerStatus>.broadcast();

  final List<LocationSample> pending = <LocationSample>[];
  final List<String> acknowledged = <String>[];
  final List<String> starts = <String>[];
  final List<String> pauses = <String>[];
  final List<String> stops = <String>[];
  final List<TrackingConfig> configUpdates = <TrackingConfig>[];
  final List<String> clearedNativeTracks = <String>[];
  final List<bool> permissionRequests = <bool>[];
  bool running = false;
  String? nativeTrackId;
  bool failNextPauseAfterStopping = false;
  PendingNativeUserAction? nativeUserAction;
  final List<String> acknowledgedNativeUserActions = <String>[];
  TrackingPermissionState permissionState = const TrackingPermissionState(
    platform: 'test',
    location: LocationPermissionLevel.always,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );
  final List<TrackingReadinessAction> permissionSteps =
      <TrackingReadinessAction>[];

  @override
  Stream<LocationSample> get locationStream => locations.stream;

  @override
  Stream<ActivitySnapshot> get activityStream => activities.stream;

  @override
  Stream<TrackerStatus> get statusStream => statuses.stream;

  @override
  Future<void> acknowledgeLocations(Iterable<String> eventIds) async {
    final values = eventIds.toSet();
    acknowledged.addAll(values);
    pending.removeWhere((sample) => values.contains(sample.eventId));
  }

  @override
  Future<void> acknowledgePendingUserAction(String actionId) async {
    acknowledgedNativeUserActions.add(actionId);
    if (nativeUserAction?.actionId == actionId) nativeUserAction = null;
  }

  @override
  Future<int> clearNativeTrackData(String trackId) async {
    clearedNativeTracks.add(trackId);
    return 0;
  }

  @override
  Future<TrackingCapabilityReport> capabilities() async =>
      const TrackingCapabilityReport(
        platform: 'test',
        backgroundTracking: true,
        activityRecognition: true,
        mockDetection: true,
        pauseResume: true,
        adaptiveSampling: true,
        terminatedRecovery: true,
      );

  @override
  Future<void> dispose() async {
    await locations.close();
    await activities.close();
    await statuses.close();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<LocationSample?> lastLocation() async =>
      pending.isEmpty ? null : pending.last;

  @override
  Future<bool> openAppSettings() async => true;

  @override
  Future<PendingNativeUserAction?> pendingUserAction() async =>
      nativeUserAction;

  @override
  Future<void> pause({required String trackId}) async {
    pauses.add(trackId);
    running = false;
    if (failNextPauseAfterStopping) {
      failNextPauseAfterStopping = false;
      throw StateError('simulated process boundary');
    }
  }

  @override
  Future<List<LocationSample>> pendingLocations() async =>
      List<LocationSample>.of(pending);

  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async {
    permissionRequests.add(request);
    return permissionState;
  }

  @override
  Future<TrackingPermissionState> requestPermissionStep({
    required TrackingReadinessAction action,
    required int expectedReadinessRevision,
  }) async {
    permissionSteps.add(action);
    if (action == TrackingReadinessAction.requestBackgroundLocation) {
      permissionState = const TrackingPermissionState(
        platform: 'test',
        location: LocationPermissionLevel.always,
        locationServiceEnabled: true,
        preciseLocation: true,
        activityRecognitionGranted: true,
        notificationGranted: true,
      );
    }
    return permissionState;
  }

  @override
  Future<void> resume({
    required String trackId,
    required TrackingConfig config,
  }) async {
    starts.add(trackId);
    nativeTrackId = trackId;
    running = true;
  }

  @override
  Future<TrackerStatus> runtimeState() async => TrackerStatus(
        lifecycle:
            running ? TrackerLifecycle.tracking : TrackerLifecycle.paused,
        trackId: nativeTrackId,
      );

  @override
  Future<void> start({
    required String trackId,
    required TrackingConfig config,
  }) async {
    starts.add(trackId);
    nativeTrackId = trackId;
    running = true;
  }

  @override
  Future<void> stop({
    required String trackId,
    required String reason,
  }) async {
    stops.add(trackId);
    running = false;
    nativeTrackId = null;
  }

  @override
  Future<void> updateConfig({
    required String trackId,
    required TrackingConfig config,
  }) async {
    configUpdates.add(config);
  }
}

Future<void> _waitUntil(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached before the test timeout.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup replays pending fixes in capture order and acks after commit',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'pending-track');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId
      ..pending.addAll(<LocationSample>[
        LocationSample(
          latitude: 27.72,
          longitude: 85.32,
          capturedAt: harness.now.add(const Duration(seconds: 20)),
          eventId: 'later',
          trackId: trackId,
          capturedActivity: ActivitySnapshot(
            type: TrackingActivityType.inVehicle,
            confidence: 90,
            recordedAt: harness.now.add(const Duration(seconds: 19)),
          ),
          capturedMotionState: MotionState.moving,
        ),
        LocationSample(
          latitude: 27.71,
          longitude: 85.31,
          capturedAt: harness.now.add(const Duration(seconds: 10)),
          eventId: 'earlier',
          trackId: trackId,
          capturedActivity: ActivitySnapshot(
            type: TrackingActivityType.walking,
            confidence: 80,
            recordedAt: harness.now.add(const Duration(seconds: 9)),
          ),
          capturedMotionState: MotionState.moving,
        ),
      ]);
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now.add(const Duration(seconds: 30)),
    );

    await client.initialize();

    final bundle = await harness.repository.loadTrackBundle(trackId);
    expect(
      bundle.segments.single.points.map((point) => point.nativeEventId),
      <String>['earlier', 'later'],
    );
    expect(
      bundle.segments.single.points.map((point) => point.activityType),
      <TrackingActivityType>[
        TrackingActivityType.walking,
        TrackingActivityType.inVehicle,
      ],
    );
    expect(tracker.acknowledged, <String>['earlier', 'later']);
    expect(client.currentStatus.motionState, MotionState.moving);
    expect(client.currentStatus.samplingProfile, SamplingProfile.moving);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('mismatched native fixes are quarantined before acknowledgement',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'active-track');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId
      ..pending.add(
        LocationSample(
          latitude: 27.71,
          longitude: 85.31,
          capturedAt: harness.now.add(const Duration(seconds: 10)),
          eventId: 'foreign-event',
          trackId: 'foreign-native-track',
        ),
      );
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now.add(const Duration(seconds: 30)),
    );

    await client.initialize();

    await _waitUntil(
        () async => tracker.acknowledged.contains('foreign-event'));
    final bundle = await harness.repository.loadTrackBundle(trackId);
    final points = bundle.segments.expand((segment) => segment.points).toList();
    expect(points, hasLength(1));
    expect(points.single.accepted, isFalse);
    expect(
      points.single.qualityFlags,
      TrackPointQualityFlag.nativeTrackMismatch,
    );
    expect(points.single.rejectionReason, 'native_track_mismatch');

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('completing an older paused track never stops the active native track',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final oldTrack = await harness.createActiveTrack(trackId: 'old-track');
    await harness.repository.pauseTrack(oldTrack, reason: 'later');
    final activeTrack =
        await harness.createActiveTrack(trackId: 'active-track');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = activeTrack;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    await client.completeTrack(trackId: oldTrack);

    expect((await harness.repository.getTrack(oldTrack))!.status,
        TrackStatus.completed);
    expect((await harness.repository.getTrack(activeTrack))!.status,
        TrackStatus.active);
    expect(tracker.running, isTrue);
    expect(tracker.stops, isEmpty);
    expect(client.currentStatus.trackId, activeTrack);
    expect(client.currentStatus.lifecycle, TrackerLifecycle.tracking);

    await client.completeTrack(trackId: activeTrack);
    await client.dispose();
  });

  test('native failure is persisted as interrupted and can be resumed',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'failed-track');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    tracker.running = false;
    tracker.statuses.add(
      TrackerStatus(
        lifecycle: TrackerLifecycle.failed,
        trackId: trackId,
        message: 'native failure',
      ),
    );
    await _waitUntil(
      () async =>
          (await harness.repository.getTrack(trackId))!.status ==
          TrackStatus.interrupted,
    );

    await client.resumeTrack(trackId);
    final resumed = await harness.repository.loadTrackBundle(trackId);
    expect(resumed.track.status, TrackStatus.active);
    expect(resumed.segments, hasLength(2));
    expect(tracker.running, isTrue);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('startTrack reuses an already active track', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final firstTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );
    final secondTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );

    expect(secondTrackId, firstTrackId);
    expect(tracker.starts, <String>[firstTrackId]);
    expect((await harness.repository.findActiveTrack())!.id, firstTrackId);

    await client.completeTrack(trackId: firstTrackId);
    await client.dispose();
  });

  test('startTrack normalizes and timestamps a supplied route ID', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );
    await client.initialize();

    final trackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
      routeId: '  Morning   delivery route  ',
    );

    expect(
      (await client.getTrack(trackId))!.routeId,
      'Morning_delivery_route_20260720_080000_000000',
    );
    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('startNewTrack creates a route with read-only readiness', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );

    final result = await client.startNewTrack(
      const TrackStartRequest(
        owner: TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
        routeId: 'North Route',
      ),
    );

    expect(result.disposition, TrackStartDisposition.created);
    expect(result.created, isTrue);
    expect(result.track.userId, 'user-1');
    expect(result.track.organizationId, 'org-1');
    expect(result.track.routeId, startsWith('North_Route_'));
    expect(tracker.starts, <String>[result.trackId]);
    expect(tracker.permissionRequests, isNot(contains(true)));

    await client.completeTrack(trackId: result.trackId);
    await client.dispose();
  });

  test('startNewTrack reports same-owner conflict without native mutation',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'active-track');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );

    await expectLater(
      client.startNewTrack(
        const TrackStartRequest(
          owner: TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
        ),
      ),
      throwsA(
        isA<TrackingConflictException>()
            .having((error) => error.code, 'code', 'active_track_conflict')
            .having((error) => error.trackId, 'trackId', trackId),
      ),
    );
    expect(tracker.starts, isEmpty);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('startOrRecoverTrack hides a foreign paused route and starts own route',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'foreign-track');
    await harness.repository.pauseTrack(trackId, reason: 'owner switch');
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );

    final result = await client.startOrRecoverTrack(
      const TrackStartRequest(
        owner: TrackingOwner(userId: 'other-user', organizationId: 'org'),
      ),
    );
    expect(result.disposition, TrackStartDisposition.created);
    expect(result.track.userId, 'other-user');
    expect(result.track.id, isNot(trackId));
    expect(tracker.starts, <String>[result.track.id]);

    await client.completeTrack(trackId: result.track.id);
    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('startOrRecoverTrack resumes a same-owner paused route', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'paused-track');
    await harness.repository.pauseTrack(trackId, reason: 'rest');
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );

    final result = await client.startOrRecoverTrack(
      const TrackStartRequest(
        owner: TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
      ),
    );

    expect(result.trackId, trackId);
    expect(result.disposition, TrackStartDisposition.resumedPaused);
    expect(tracker.starts, <String>[trackId]);
    expect(tracker.permissionRequests, isNot(contains(true)));
    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.active);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('startTrack validates config before database or native mutation',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    await expectLater(
      client.startTrack(
        userId: 'user',
        organizationId: 'org',
        config: TrackingConfig.fromMap(<String, Object?>{
          'movingIntervalMs': 0,
        }),
      ),
      throwsA(
        isA<TrackingConfigurationException>()
            .having((error) => error.code, 'code', 'invalid_configuration'),
      ),
    );

    expect(tracker.starts, isEmpty);
    expect(await harness.repository.listTracks(), isEmpty);
    await client.dispose();
  });

  test('checkReadiness is read-only and separates background education',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker()
      ..permissionState = const TrackingPermissionState(
        platform: 'test',
        location: LocationPermissionLevel.whileInUse,
        locationServiceEnabled: true,
        preciseLocation: true,
        activityRecognitionGranted: true,
        notificationGranted: true,
        canRequestBackground: true,
      );
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final readiness = await client.checkReadiness();

    expect(readiness.canStart, isFalse);
    expect(
      readiness.nextAction,
      TrackingReadinessAction.explainBackgroundLocation,
    );
    expect(tracker.permissionSteps, isEmpty);
    expect(tracker.starts, isEmpty);
    await client.dispose();
  });

  test('requestNextPermission performs one staged request after education',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker()
      ..permissionState = const TrackingPermissionState(
        platform: 'test',
        location: LocationPermissionLevel.whileInUse,
        locationServiceEnabled: true,
        preciseLocation: true,
        activityRecognitionGranted: true,
        notificationGranted: true,
        canRequestBackground: true,
      );
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    await client.acknowledgeReadinessEducation(
      'background_location_explanation_required',
    );
    final readiness = await client.requestNextPermission();

    expect(readiness.canStart, isTrue);
    expect(readiness.nextAction, TrackingReadinessAction.none);
    expect(
      tracker.permissionSteps,
      <TrackingReadinessAction>[
        TrackingReadinessAction.requestBackgroundLocation,
      ],
    );
    expect(tracker.starts, isEmpty);
    await client.dispose();
  });

  test('healthSnapshot reports coordinate-free status and readiness', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );
    await client.initialize();

    final health = await client.healthSnapshot();

    expect(health.observedAt, harness.now);
    expect(health.status.lifecycle, TrackerLifecycle.paused);
    expect(health.canStart, isTrue);
    expect(health.nativeProtocol.version, 1);
    await client.dispose();
  });

  test('native capture runs only while the route is active', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final trackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );
    expect(tracker.running, isTrue);
    expect(tracker.starts, <String>[trackId]);

    await client.pauseTrack(trackId: trackId);
    expect(tracker.running, isFalse);
    expect(tracker.pauses, <String>[trackId]);

    await client.resumeTrack(trackId);
    expect(tracker.running, isTrue);
    expect(tracker.starts, <String>[trackId, trackId]);

    await client.completeTrack(trackId: trackId);
    expect(tracker.running, isFalse);
    expect(tracker.stops, <String>[trackId]);
    expect(client.currentStatus.lifecycle, TrackerLifecycle.idle);
    await client.dispose();
  });

  test('completeTrack clears matching paused native state', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final trackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );
    await client.pauseTrack(trackId: trackId);

    expect(tracker.running, isFalse);
    expect(tracker.nativeTrackId, trackId);

    await client.completeTrack(trackId: trackId);

    expect(tracker.stops, <String>[trackId]);
    expect(tracker.nativeTrackId, isNull);
    expect((await client.getTrack(trackId))!.status, TrackStatus.completed);
    await client.dispose();
  });

  test('startTrack keeps all track history by default', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final firstTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );
    await client.completeTrack(trackId: firstTrackId);
    final secondTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );

    expect(
      (await harness.repository.listTracks()).map((track) => track.id).toSet(),
      <String>{firstTrackId, secondTrackId},
    );

    await client.completeTrack(trackId: secondTrackId);
    await client.dispose();
  });

  test('startTrack can keep only the latest track when configured', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      configuration: const TrackingConfiguration(
        recordRetentionPolicy: TrackRecordRetentionPolicy.keepLatestOnly,
      ),
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final firstTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );
    await client.completeTrack(trackId: firstTrackId);
    final secondTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );

    expect(await harness.repository.getTrack(firstTrackId), isNull);
    expect(
      (await harness.repository.listTracks()).map((track) => track.id),
      <String>[secondTrackId],
    );

    await client.completeTrack(trackId: secondTrackId);
    await client.dispose();
  });

  test('keepLatestOnly never deletes another owner route', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final foreign = await harness.repository.createTrack(
      userId: 'foreign-user',
      organizationId: 'foreign-org',
      config: harness.config,
      requestedTrackId: 'foreign-completed',
    );
    await harness.repository.markTrackActive(foreign);
    await harness.repository.completeTrack(foreign, reason: 'finished');
    final tracker = _FakeTracker();
    final client = TrackingClient(
      configuration: const TrackingConfiguration(
        recordRetentionPolicy: TrackRecordRetentionPolicy.keepLatestOnly,
      ),
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );

    final own = await client.startNewTrack(
      const TrackStartRequest(
        owner: TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
      ),
    );

    expect(await harness.repository.getTrack(foreign), isNotNull);
    expect(await harness.repository.getTrack(own.trackId), isNotNull);
    await client.completeTrack(trackId: own.trackId);
    await client.dispose();
  });

  test('deleteTrack removes a selected completed route', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      configuration: const TrackingConfiguration(
        recordRetentionPolicy: TrackRecordRetentionPolicy.keepAll,
      ),
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final trackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );
    await client.completeTrack(trackId: trackId);

    await client.deleteTrack(trackId);

    expect(await client.getTrack(trackId), isNull);
    expect(await client.listTracks(), isEmpty);
    await client.dispose();
  });

  test('listTrackPage exposes bounded route summaries through the client',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    final firstTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
      requestedTrackId: 'page-first',
    );
    await client.completeTrack(trackId: firstTrackId);
    harness.now = harness.now.add(const Duration(minutes: 1));
    final secondTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
      requestedTrackId: 'page-second',
    );
    await client.completeTrack(trackId: secondTrackId);

    final page = await client.listTrackPage(TrackQuery(limit: 1));

    expect(page.items.map((track) => track.id), <String>[secondTrackId]);
    expect(page.hasMore, isTrue);
    expect(page.nextCursor, isNotNull);

    await client.dispose();
  });

  test('deleteTrack does not remove an active route', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final trackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );

    await expectLater(client.deleteTrack(trackId), throwsStateError);

    expect((await client.getTrack(trackId))!.status, TrackStatus.active);
    expect(tracker.running, isTrue);
    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('startTrack resumes an interrupted current track', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'interrupted');
    await harness.repository.interruptTrack(
      trackId,
      reason: 'native_stopped',
    );
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final resumedTrackId = await client.startTrack(
      userId: 'user',
      organizationId: 'org',
    );

    expect(resumedTrackId, trackId);
    expect(tracker.starts, <String>[trackId]);
    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.active);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('replayed pause operation cannot pause a later resumed segment',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'operations');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    await client.pauseTrack(trackId: trackId, operationId: 'pause-command');
    await client.resumeTrack(trackId);
    await client.pauseTrack(trackId: trackId, operationId: 'pause-command');

    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.active);
    expect(tracker.pauses, <String>[trackId]);
    expect(tracker.running, isTrue);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('pause intent survives failure between native stop and database update',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'pause-saga');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId
      ..failNextPauseAfterStopping = true;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    await expectLater(
      client.pauseTrack(trackId: trackId, operationId: 'durable-pause'),
      throwsStateError,
    );
    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.active);
    expect(
      (await harness.repository.findPendingLifecycleCommand())?.type,
      TrackCommandType.pause,
    );

    await client.pauseTrack(trackId: trackId, operationId: 'durable-pause');
    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.paused);
    expect(await harness.repository.findPendingLifecycleCommand(), isNull);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('initialization recovers a durable completion intent', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'complete-saga');
    await harness.repository.beginLifecycleCommand(
      trackId: trackId,
      type: TrackCommandType.complete,
      reason: 'recovered_completion',
      operationId: 'complete-command',
    );
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );

    await client.initialize();

    final track = (await harness.repository.getTrack(trackId))!;
    expect(track.status, TrackStatus.completed);
    expect(track.completionReason, 'recovered_completion');
    expect(tracker.stops, <String>[trackId]);
    expect(await harness.repository.findPendingLifecycleCommand(), isNull);
    expect(client.currentStatus.lifecycle, TrackerLifecycle.idle);
    await client.dispose();
  });

  test('initialization commits and acknowledges a native pause action',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'native-pause');
    final tracker = _FakeTracker()
      ..nativeTrackId = trackId
      ..nativeUserAction = PendingNativeUserAction(
        actionId: 'notification-pause-1',
        trackId: trackId,
        action: NativeUserActionType.pause,
        reason: 'notification_paused',
        timestamp: harness.now,
      );
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );

    await client.initialize();

    final track = (await harness.repository.getTrack(trackId))!;
    expect(track.status, TrackStatus.paused);
    expect(
      (await harness.repository.loadTrackBundle(trackId))
          .segments
          .single
          .segment
          .pauseReason,
      'notification_paused',
    );
    expect(
      tracker.acknowledgedNativeUserActions,
      <String>['notification-pause-1'],
    );

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('live native stop status durably completes before acknowledgement',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'native-stop');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    tracker
      ..running = false
      ..nativeTrackId = null
      ..nativeUserAction = PendingNativeUserAction(
        actionId: 'notification-stop-1',
        trackId: trackId,
        action: NativeUserActionType.stop,
        reason: 'notification_stopped',
        timestamp: harness.now,
      );
    tracker.statuses.add(
      const TrackerStatus(lifecycle: TrackerLifecycle.idle),
    );

    await _waitUntil(
      () async =>
          (await harness.repository.getTrack(trackId))!.status ==
              TrackStatus.completed &&
          tracker.acknowledgedNativeUserActions.isNotEmpty,
    );
    final track = (await harness.repository.getTrack(trackId))!;
    expect(track.completionReason, 'notification_stopped');
    expect(
      tracker.acknowledgedNativeUserActions,
      <String>['notification-stop-1'],
    );

    await client.dispose();
  });

  test('status stream replays the reconciled current state', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'status-track');
    await harness.repository.pauseTrack(trackId, reason: 'overnight');
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final status = await client.statusStream.first;
    expect(status.lifecycle, TrackerLifecycle.paused);
    expect(status.trackId, trackId);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('session stream replays route-aware lifecycle actions', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'session-track');
    await harness.repository.pauseTrack(trackId, reason: 'rest');
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
    );
    await client.initialize();

    final paused = await client.sessionStream.first;
    expect(paused.currentTrack?.id, trackId);
    expect(paused.allowedActions.canStartNew, isFalse);
    expect(paused.allowedActions.canPause, isFalse);
    expect(paused.allowedActions.canResume, isTrue);
    expect(paused.allowedActions.canComplete, isTrue);

    await client.completeTrack(trackId: trackId);
    await _waitUntil(
      () async => client.currentSession?.allowedActions.canStartNew == true,
    );

    final idle = client.currentSession!;
    expect(idle.status.lifecycle, TrackerLifecycle.idle);
    expect(idle.currentTrack, isNull);
    expect(idle.allowedActions.canStartNew, isTrue);
    await client.dispose();
  });

  test('Q1-03 reports first-fix timeout while capture keeps running', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );
    await client.initialize();
    final trackId = await client.startTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: const TrackingConfig(
        firstFixTimeout: Duration(milliseconds: 10),
      ),
    );

    await _waitUntil(
      () async =>
          client.currentSession?.fixState == TrackingFixState.firstFixTimedOut,
    );
    expect(tracker.running, isTrue);
    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.active);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('Q1-03 starts a new geometry segment after a large callback gap',
      () async {
    final harness = RepositoryHarness(
      config: const TrackingConfig(
        largeGapThreshold: Duration(minutes: 1),
      ),
    );
    await harness.initialize();
    final tracker = _FakeTracker();
    final client = TrackingClient(
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now.add(const Duration(minutes: 2)),
    );
    await client.initialize();
    final trackId = await client.startTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: harness.config,
    );
    tracker.locations.add(LocationSample(
      latitude: 27.7,
      longitude: 85.3,
      horizontalAccuracy: 5,
      capturedAt: harness.now,
      provider: 'test',
      trackId: trackId,
      eventId: 'gap-first',
    ));
    await _waitUntil(
      () async =>
          (await harness.repository.getTrack(trackId))!.acceptedPointCount == 1,
    );
    tracker.locations.add(LocationSample(
      latitude: 28.7,
      longitude: 86.3,
      horizontalAccuracy: 5,
      capturedAt: harness.now.add(const Duration(minutes: 2)),
      provider: 'test',
      trackId: trackId,
      eventId: 'gap-second',
    ));
    await _waitUntil(
      () async =>
          (await harness.repository.getTrack(trackId))!.acceptedPointCount == 2,
    );

    final bundle = await harness.repository.loadTrackBundle(trackId);
    expect(bundle.segments, hasLength(2));
    expect(
        bundle.segments.first.segment.status, TrackSegmentStatus.interrupted);
    expect(
        bundle.segments.last.points.single.qualityFlags &
            TrackPointQualityFlag.largeGap,
        isNot(0));
    expect(bundle.track.totalDistanceMeters, 0);

    await client.completeTrack(trackId: trackId);
    await client.dispose();
  });

  test('E1-OPEN returns an initialized owner-scoped controller', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    const firstOwner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    const secondOwner = TrackingOwner(
      userId: 'user-2',
      organizationId: 'org-1',
    );
    final controller = await TrackingClient.open(
      owner: firstOwner,
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );

    expect(controller.isInitialized, isTrue);
    expect(controller.currentOwner.userId, 'user-1');
    final first = await controller.startNewTrack(
      const TrackStartRequest(owner: firstOwner, routeId: 'owner one'),
    );
    await expectLater(
      controller.startNewTrack(
        const TrackStartRequest(owner: secondOwner, routeId: 'wrong owner'),
      ),
      throwsA(isA<TrackingOwnershipException>()),
    );
    expect(tracker.starts, hasLength(1));

    final paused = await controller.pauseCurrentTrack();
    expect(paused.track.status, TrackStatus.paused);
    await controller.switchOwner(secondOwner);
    expect(await controller.getTrack(first.trackId), isNull);
    expect(controller.currentSession.blockerCode, isNull);
    expect(controller.currentSession.allowedActions.canStartNew, isTrue);

    final second = await controller.startNewTrack(
      const TrackStartRequest(owner: secondOwner, routeId: 'owner two'),
    );
    expect(second.track.userId, 'user-2');
    await controller.completeCurrentTrack();
    await controller.dispose();
  });

  test('B1-03 runtime config update fences capture and activates an epoch',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final tracker = _FakeTracker();
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final controller = await TrackingClient.open(
      owner: owner,
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );
    final started = await controller.startNewTrack(
      const TrackStartRequest(owner: owner, routeId: 'config update'),
    );
    const updatedConfig = TrackingConfig(accuracy: TrackingAccuracy.medium);

    final update = await (controller as TrackingConfigurationController)
        .updateTrackingConfig(updatedConfig);

    expect(update.trackId, started.trackId);
    expect(update.epoch.epochNumber, 2);
    expect(update.epoch.resolvedConfig.accuracy, TrackingAccuracy.medium);
    expect(tracker.pauses, <String>[started.trackId]);
    expect(tracker.configUpdates, <TrackingConfig>[updatedConfig]);
    expect(tracker.starts, <String>[started.trackId, started.trackId]);
    expect((await controller.getTrack(started.trackId))!.config.accuracy,
        TrackingAccuracy.medium);

    await controller.completeCurrentTrack();
    await controller.dispose();
  });

  test(
      'E1-OWN resolves a redacted foreign live capture with a stale-safe token',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final foreignId = await harness.createActiveTrack(trackId: 'foreign-live');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = foreignId;
    const newOwner = TrackingOwner(
      userId: 'new-user',
      organizationId: 'org-1',
    );
    final controller = await TrackingClient.open(
      owner: newOwner,
      trackerAdapter: tracker,
      repository: harness.repository,
      exportFileWriter: _MemoryWriter(),
      clock: () => harness.now,
    );
    final blocked = controller.currentSession;
    expect(blocked.blockerCode, 'owner_scope_conflict');
    expect(blocked.currentTrack, isNull);
    expect(blocked.blockerRecoveryToken, isNotEmpty);

    await expectLater(
      controller.resolveOwnerConflict(
        const OwnerConflictResolutionRequest(
          conflictToken: 'stale',
          operationId: 'resolve-1',
          confirmed: true,
        ),
      ),
      throwsA(
        isA<TrackingConflictException>().having(
          (error) => error.code,
          'code',
          'owner_conflict_token_stale',
        ),
      ),
    );
    final result = await controller.resolveOwnerConflict(
      OwnerConflictResolutionRequest(
        conflictToken: blocked.blockerRecoveryToken!,
        operationId: 'resolve-1',
        confirmed: true,
      ),
    );
    expect(
      result.disposition,
      OwnerConflictResolutionDisposition.preservedPaused,
    );
    expect((await harness.repository.getTrack(foreignId))!.status,
        TrackStatus.paused);
    expect(controller.currentSession.blockerCode, isNull);
    expect(controller.currentSession.allowedActions.canStartNew, isTrue);

    await controller.dispose();
  });

  test('P1-01 abort retains a cancelled route and clears scoped native data',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'privacy-abort');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final privacy = TrackingPrivacyService(
      repository: harness.repository,
      tracker: tracker,
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
    );

    final report = await privacy.abortCurrentTrack(
      const AbortTrackRequest(
        reason: 'user_cancelled',
        operationId: 'privacy-abort-op',
      ),
    );
    final replay = await privacy.abortCurrentTrack(
      const AbortTrackRequest(operationId: 'privacy-abort-op'),
    );

    expect(report.status, 'completed');
    expect(replay.operationId, report.operationId);
    expect(tracker.stops, <String>[trackId]);
    expect(tracker.clearedNativeTracks, <String>[trackId]);
    final retained = await harness.repository.getTrack(trackId);
    expect(retained?.status, TrackStatus.failed);
    expect(retained?.terminalReasonCode, 'cancelled_by_host');
    await tracker.dispose();
    await harness.repository.close();
  });

  test('P1-01 confirmed deletion is owner-scoped and replayable', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'privacy-delete');
    await harness.repository.completeTrack(trackId, reason: 'finished');
    final tracker = _FakeTracker();
    final privacy = TrackingPrivacyService(
      repository: harness.repository,
      tracker: tracker,
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
    );
    const request = DeleteTrackRequest(
      trackId: 'privacy-delete',
      confirmed: true,
      operationId: 'privacy-delete-op',
    );

    final report = await privacy.deleteRecordedTrack(request);
    final replay = await privacy.deleteRecordedTrack(request);

    expect(report.status, 'completed');
    expect(replay.operationId, report.operationId);
    expect(await harness.repository.getTrack(trackId), isNull);
    expect(tracker.clearedNativeTracks, <String>[trackId]);
    final operation =
        await harness.repository.getPrivacyOperation(report.operationId);
    expect(operation?.status, 'completed');
    expect(operation?.trackId, isNull);
    await tracker.dispose();
    await harness.repository.close();
  });

  test('P1-01 erase stops active capture and removes only selected owner route',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'privacy-erase');
    final tracker = _FakeTracker()
      ..running = true
      ..nativeTrackId = trackId;
    final privacy = TrackingPrivacyService(
      repository: harness.repository,
      tracker: tracker,
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
    );

    final report = await privacy.eraseTrackEverywhere(
      const EraseTrackRequest(
        trackId: 'privacy-erase',
        confirmed: true,
        operationId: 'privacy-erase-op',
      ),
    );

    expect(report.status, 'completed');
    expect(tracker.stops, <String>[trackId]);
    expect(tracker.clearedNativeTracks, <String>[trackId]);
    expect(await harness.repository.getTrack(trackId), isNull);
    await tracker.dispose();
    await harness.repository.close();
  });
}
