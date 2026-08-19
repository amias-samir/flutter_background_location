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

final class _FakeTracker implements TrackerAdapter, NativeUserActionAdapter {
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
  bool running = false;
  String? nativeTrackId;
  bool failNextPauseAfterStopping = false;
  PendingNativeUserAction? nativeUserAction;
  final List<String> acknowledgedNativeUserActions = <String>[];

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
  Future<TrackingPermissionState> permissions({bool request = false}) async =>
      const TrackingPermissionState(
        platform: 'test',
        location: LocationPermissionLevel.always,
        locationServiceEnabled: true,
        preciseLocation: true,
        activityRecognitionGranted: true,
        notificationGranted: true,
      );

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
  }) async {}
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
}
