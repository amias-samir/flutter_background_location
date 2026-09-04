import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

const _owner = TrackingOwner(
  userId: 'trip-user',
  organizationId: 'trip-organization',
);

final class _RecordingTripUploader implements TripCompletionUploader {
  final List<String> keys = <String>[];
  final List<int> revisions = <int>[];

  @override
  Future<void> uploadTripCompletion({
    required Trip trip,
    required int lifecycleRevision,
    required String idempotencyKey,
  }) async {
    keys.add(idempotencyKey);
    revisions.add(lifecycleRevision);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Start, End day, Continue, and Complete create ordered daily legs',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final oldTrack = await harness.repository.createTrack(
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      routeId: 'old_terminal_trip',
      config: const TrackingConfig(),
      requestedTrackId: 'old-terminal-trip',
    );
    await harness.repository.markTrackActive(oldTrack);
    await harness.repository.completeTrack(oldTrack, reason: 'old_completed');
    final adapter = FakeTrackerAdapter();
    final controller = await TrackingClient.openWithTrips(
      owner: _owner,
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => harness.now,
    );
    addTearDown(controller.dispose);

    final started = await controller.startTrip(
      const TripStartRequest(
        routeId: 'three_day_route',
        operationId: 'start-operation',
        routePresentation: MultiDayRoutePresentation.connectDailyLegs,
        config: TrackingConfig(captureIntent: RouteCaptureIntent.walking),
      ),
    );
    final replayedStart = await controller.startTrip(
      const TripStartRequest(
        routeId: 'ignored_on_idempotent_replay',
        operationId: 'start-operation',
      ),
    );
    expect(replayedStart.trip.id, started.trip.id);
    expect(replayedStart.leg.trackId, started.leg.trackId);

    final ended = await controller.endCurrentDay(
      reason: 'overnight',
      operationId: 'end-day-1',
    );
    expect(ended.trip.status, TripStatus.suspended);
    expect(ended.leg.trackStatus, TrackStatus.completed);
    expect(adapter.calls.where((call) => call.method == 'stop'), hasLength(1));

    final replayedEnd = await controller.endCurrentDay(
      reason: 'overnight',
      operationId: 'end-day-1',
    );
    expect(replayedEnd.trip.id, ended.trip.id);
    expect(replayedEnd.leg.trackId, ended.leg.trackId);

    harness.now = harness.now.add(const Duration(days: 1));
    final continued = await controller.continueTrip(
      started.trip.id,
      operationId: 'continue-day-2',
    );
    final replayedContinue = await controller.continueTrip(
      started.trip.id,
      operationId: 'continue-day-2',
    );
    expect(continued.disposition, TripContinueDisposition.createdLeg);
    expect(replayedContinue.leg.trackId, continued.leg.trackId);
    expect(continued.leg.trackId, isNot(started.leg.trackId));

    final completed = await controller.completeTrip(
      started.trip.id,
      operationId: 'complete-trip',
    );
    final bundle = await controller.loadTripBundle(started.trip.id);
    expect(completed.trip.status, TripStatus.completed);
    expect(bundle.legs.map((leg) => leg.legNumber), <int>[1, 2]);
    expect(
      bundle.legs.map((leg) => leg.trackStatus),
      everyElement(TrackStatus.completed),
    );
    expect(bundle.trip.routeId, started.trip.routeId);
    expect(
      bundle.trip.routePresentation,
      MultiDayRoutePresentation.connectDailyLegs,
    );
    expect(bundle.trip.captureIntent, RouteCaptureIntent.walking);

    await harness.repository.deleteTracksExceptForOwner(
      _owner,
      <String>{bundle.legs.last.trackId},
    );
    expect(await harness.repository.getTrack(oldTrack), isNull);
    for (final leg in bundle.legs) {
      expect(
        await harness.repository.getTrack(leg.trackId),
        isNotNull,
        reason: 'Retention must preserve every leg in the retained Trip.',
      );
    }

    await expectLater(
      controller.continueTrip(started.trip.id),
      throwsA(
        isA<TrackingTripException>().having(
          (error) => error.code,
          'code',
          'completed_trip_confirmation_required',
        ),
      ),
    );

    final transport = _RecordingTripUploader();
    final completionUploader = TripCompletionUploadService(
      repository: harness.repository,
      owner: _owner,
      uploader: transport,
      leaseOwner: 'test-trip-uploader',
      clock: () => harness.now,
    );
    expect(await completionUploader.tryDrain(), 1);
    expect(transport.keys, <String>[
      'trip:${started.trip.id}:completion:v${completed.trip.lifecycleRevision}',
    ]);
    expect(
      await harness.repository.hasAcknowledgedTripCompletion(
        tripId: started.trip.id,
      ),
      isTrue,
    );
    await expectLater(
      controller.continueTrip(
        started.trip.id,
        operationId: 'continue-after-upload',
        confirmCompletedTripContinuation: true,
      ),
      throwsA(
        isA<TrackingTripException>().having(
          (error) => error.code,
          'code',
          'trip_already_finalized',
        ),
      ),
    );
  });

  test('startup recovers a prepared Continue operation exactly once', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final firstTrack = await harness.repository.createTrack(
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      routeId: 'recovery_trip',
      config: const TrackingConfig(),
      requestedTrackId: 'recovery-trip',
    );
    await harness.repository.markTrackActive(firstTrack);
    await harness.repository.completeTrack(
      firstTrack,
      reason: 'first_day_completed',
      operationId: 'complete-first-day',
    );
    final prepared = await harness.repository.prepareNextTripLeg(
      owner: _owner,
      tripId: firstTrack,
      config: const TrackingConfig(),
      operationId: 'prepared-continue',
      confirmCompletedTripContinuation: true,
    );
    expect(prepared.created, isTrue);
    expect(prepared.track.status, TrackStatus.starting);

    final adapter = FakeTrackerAdapter();
    final controller = await TrackingClient.openWithTrips(
      owner: _owner,
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => harness.now,
    );
    addTearDown(() async {
      final trip = await controller.getTrip(firstTrack);
      if (trip != null && trip.status != TripStatus.completed) {
        await controller.completeTrip(
          trip.id,
          operationId: 'recovery-cleanup',
        );
      }
      await controller.dispose();
    });

    final recoveredTrack = await controller.getTrack(prepared.track.id);
    expect(recoveredTrack?.status, TrackStatus.active);
    expect(controller.currentStatus.trackId, prepared.track.id);
    expect(controller.currentStatus.lifecycle, TrackerLifecycle.tracking);
    expect(
      adapter.calls
          .where((call) => call.method == 'start')
          .map((call) => call.arguments['trackId']),
      <Object?>[prepared.track.id],
    );
    expect(await harness.repository.pendingTripOperations(), isEmpty);

    final replay = await controller.continueTrip(
      firstTrack,
      operationId: 'prepared-continue',
      confirmCompletedTripContinuation: true,
    );
    expect(replay.leg.trackId, prepared.track.id);
    expect((await controller.loadTripBundle(firstTrack)).legs, hasLength(2));
  });

  test('deleting a terminal Trip cascades every daily leg and outbox row',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final controller = await TrackingClient.openWithTrips(
      owner: _owner,
      repository: harness.repository,
      trackerAdapter: FakeTrackerAdapter(),
      exportFileWriter: FakeExportFileWriter(),
      clock: () => harness.now,
    );
    addTearDown(controller.dispose);

    final started = await controller.startTrip(
      const TripStartRequest(operationId: 'delete-start'),
    );
    await controller.endCurrentDay(operationId: 'delete-end-day');
    final next = await controller.continueTrip(
      started.trip.id,
      operationId: 'delete-continue',
    );
    await controller.completeTrip(
      started.trip.id,
      operationId: 'delete-complete',
    );
    final trackIds = <String>[started.leg.trackId, next.leg.trackId];

    await controller.deleteTrip(started.trip.id);

    expect(await controller.getTrip(started.trip.id), isNull);
    for (final trackId in trackIds) {
      expect(await controller.getTrack(trackId), isNull);
    }
    expect(
      await harness.repository.listTripUploadEntriesForOwner(_owner),
      isEmpty,
    );
  });

  test('startup finishes a prepared End-day after stopping matching native',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.repository.createTrack(
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      config: const TrackingConfig(),
      requestedTrackId: 'recover-end-day',
    );
    await harness.repository.markTrackActive(trackId);
    await harness.repository.beginTripOperation(
      owner: _owner,
      tripId: trackId,
      trackId: trackId,
      type: TripOperationType.endDay,
      operationId: 'prepared-end-day',
      reason: 'overnight',
    );
    final adapter = FakeTrackerAdapter();
    await adapter.start(trackId: trackId, config: const TrackingConfig());

    final controller = await TrackingClient.openWithTrips(
      owner: _owner,
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => harness.now,
    );
    addTearDown(controller.dispose);

    final trip = await controller.getTrip(trackId);
    final track = await controller.getTrack(trackId);
    expect(trip?.status, TripStatus.suspended);
    expect(track?.status, TrackStatus.completed);
    expect(await harness.repository.pendingTripOperations(), isEmpty);
    expect(await adapter.isRunning(), isFalse);
    expect(
      adapter.calls
          .where((call) => call.method == 'stop')
          .map((call) => call.arguments['trackId']),
      <Object?>[trackId],
    );
  });
}
