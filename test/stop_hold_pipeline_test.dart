import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/domain/track_geodesy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

// End-to-end replays of the 2026-10-18 field test's failure modes through the
// real TrackingClient, validator and SQLite repository. Every coordinate is
// generated around a synthetic origin.

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 13);

  test('quality policy 2 holds a café-style stop and keeps the walk away',
      () async {
    // Routes recorded under quality policy 2 keep its rules: ENTER WALKING
    // ends the stop at once.
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 2,
    );
    final arrival = syntheticWalk(
      trackId: run.trackId,
      from: -150,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final stopStart = arrival.locations.last.capturedAt.add(
      const Duration(seconds: 5),
    );
    const stopLength = Duration(minutes: 60);
    final stop = SyntheticTrackingRoute.indoorStop(
      duration: stopLength,
      startedAt: stopStart,
      trackId: run.trackId,
    );
    final departure = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 150,
      startedAt: stopStart.add(stopLength).add(const Duration(seconds: 5)),
      eventPrefix: 'depart',
      enterTransition: true,
    );
    final points =
        await run.replay(arrival.followedBy(stop).followedBy(departure));

    final inStop = points.where(
      (point) =>
          !point.capturedAt.isBefore(stopStart) &&
          point.capturedAt.isBefore(stopStart.add(stopLength)),
    );
    final acceptedInStop = inStop.where((point) => point.accepted).toList();
    expect(
      acceptedInStop.length,
      lessThanOrEqualTo(6),
      reason: 'about one accepted fix per ten minutes at most',
    );
    expect(
      inStop
          .where((point) => !point.accepted)
          .map((point) => point.rejectionReason)
          .toSet(),
      everyElement(
        anyOf(
          FixQualityIssue.stationaryHold,
          FixQualityIssue.stationaryOutlier,
          'poor_accuracy',
        ),
      ),
    );
    final track = (await run.harness.repository.getTrack(run.trackId))!;
    expect(track.segmentCount, 1);
    // Two 150 m legs; the stop itself may add at most 25 m per hour.
    expect(track.totalDistanceMeters, inInclusiveRange(290, 300 + 25));
    final departureAccepted = points
        .where((point) => point.nativeEventId!.startsWith('depart-'))
        .where((point) => point.accepted)
        .length;
    expect(departureAccepted, departure.locations.length);

    final gaps = await run.harness.repository.listContinuityGaps(run.trackId);
    expect(
      gaps.map((gap) => gap.cause),
      isNot(contains(TrackingGapCause.acceptedFixRejectionRun)),
    );
    final quality = await run.harness.repository.trackQualitySummary(
      owner: syntheticOwner,
      trackId: run.trackId,
    );
    expect(quality.visibleQualityRunCount, 0);
  });

  test('the same stop under motion policy 1 still accumulates jitter',
      () async {
    // Routes recorded before motion policy 2 resume with it, so their
    // capture and acceptance stay exactly as recorded.
    final legacy = TrackingConfig.fromMap(
      const <String, Object?>{'motionPolicyVersion': 1},
    );
    final run = await StopReplay.start(t0, config: legacy);
    final stop = SyntheticTrackingRoute.indoorStop(
      duration: const Duration(minutes: 60),
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(stop);
    expect(
      points.map((point) => point.rejectionReason),
      everyElement(anyOf(isNull, 'poor_accuracy')),
    );
    final track = (await run.harness.repository.getTrack(run.trackId))!;
    expect(track.totalDistanceMeters, greaterThan(100));
  });

  test('a re-acquisition burst after a long stop is not a departure', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    const stopLength = Duration(minutes: 20);
    final stop = SyntheticTrackingRoute.indoorStop(
      duration: stopLength,
      startedAt: t0,
      trackId: run.trackId,
      seed: 7,
    );
    final burst = SyntheticTrackingRoute.reacquisitionBurst(
      startedAt: t0.add(stopLength),
      trackId: run.trackId,
    );
    final points = await run.replay(stop.followedBy(burst));

    final firstDeparture = points.firstWhere(
      (point) =>
          point.accepted &&
          point.nativeEventId!.startsWith('reacquisition-') &&
          metersFromSyntheticOrigin(point) > 50,
    );
    // Only the motorbike departure with a measured Doppler speed leaves the
    // stop; nothing from the burst is accepted 50 m out.
    expect(firstDeparture.speed, greaterThanOrEqualTo(3.4));
    final beforeDeparture = points.where(
      (point) =>
          point.accepted &&
          point.capturedAt.isBefore(firstDeparture.capturedAt),
    );
    expect(
      beforeDeparture.map(metersFromSyntheticOrigin),
      everyElement(lessThanOrEqualTo(50)),
    );
    final after = points.where(
      (point) => point.capturedAt.isAfter(firstDeparture.capturedAt),
    );
    expect(after, isNotEmpty);
    expect(after.every((point) => point.accepted), isTrue);
  });

  test('quality policy 2 does not hold a slow lane ride', () async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 2,
    );
    final lane = SyntheticTrackingRoute.slowLaneRide(
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(lane);
    expect(points.every((point) => point.accepted), isTrue);
  });

  test('a slow lane ride keeps moving fixes and holds stuck positions',
      () async {
    // Quality policy 3: positions that stop following the vehicle are quiet
    // fixes, held as a pause; fixes near a walking or vehicle transition
    // move and stay in the route. No stay lasts long enough to be a stop.
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final lane = SyntheticTrackingRoute.slowLaneRide(
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(lane);
    String id(int step) => 'lane-$step';
    bool accepted(int step) =>
        points.singleWhere((point) => point.nativeEventId == id(step)).accepted;
    expect(accepted(6), isTrue, reason: 'ENTER WALKING');
    expect(accepted(12), isTrue, reason: 'ENTER IN_VEHICLE');
    final held = points.where((point) => !point.accepted).toList();
    expect(held.length, greaterThanOrEqualTo(6));
    for (final point in held) {
      expect(
        point.qualityFlags & TrackPointQualityFlag.duringStop,
        TrackPointQualityFlag.duringStop,
      );
    }
    expect(await run.harness.repository.listTrackStops(run.trackId), isEmpty);
  });

  test('a Dart restart in the middle of a stop restores the hold', () async {
    final harness = RepositoryHarness()..now = t0;
    await harness.initialize();
    final first = FakeTrackerAdapter();
    final client = await TrackingClient.openWithTrips(
      owner: syntheticOwner,
      repository: harness.repository,
      trackerAdapter: first,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => t0.add(const Duration(hours: 6)),
    );
    final started = await client.startTrip(
      const TripStartRequest(
        requestedTripId: 'synthetic_restart',
        routeId: 'synthetic_restart',
        config: TrackingConfig(),
      ),
    );
    final trackId = started.leg.trackId;
    final before = SyntheticTrackingRoute.indoorStop(
      duration: const Duration(minutes: 20),
      startedAt: t0,
      trackId: trackId,
    );
    await emitAndWait(harness, first, trackId, before);
    final last = await harness.repository.findLastRawPoint(trackId);
    expect(
      last?.rejectionReason,
      FixQualityIssue.stationaryHold,
      reason: 'the stop was being held when the engine went away',
    );

    // A new Dart engine attaches while the native service keeps capturing.
    final second = FakeTrackerAdapter();
    await second.start(trackId: trackId, config: const TrackingConfig());
    final restarted = await TrackingClient.openWithTrips(
      owner: syntheticOwner,
      repository: harness.repository,
      trackerAdapter: second,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => t0.add(const Duration(hours: 6)),
    );
    addTearDown(() async {
      await restarted.completeTrip(
        started.trip.id,
        reason: 'synthetic_test_cleanup',
      );
      await first.stop(trackId: trackId, reason: 'synthetic_test_cleanup');
      await client.dispose();
      await restarted.dispose();
    });

    // Only neutral readings arrive after the restart: without the stored
    // evidence these jittery fixes would all be accepted.
    final resumeAt = t0.add(const Duration(minutes: 21));
    final jitter = <LocationSample>[
      for (var step = 0; step < 12; step += 1)
        syntheticJitterFix(
          trackId: trackId,
          at: resumeAt.add(Duration(seconds: step * 10)),
          eastMeters: step.isEven ? 6 : -6,
          northMeters: step % 3 == 0 ? 5 : -4,
          eventId: 'after-restart-$step',
        ),
    ];
    final after = SyntheticTrackingRoute(jitter, const <ActivitySnapshot>[]);
    final points = await emitAndWait(harness, second, trackId, after);
    final accepted = points
        .where((point) => point.nativeEventId!.startsWith('after-restart-'))
        .where((point) => point.accepted);
    expect(accepted, isEmpty);
  });

  test('the cleaned view collapses a recorded stop to one point', () async {
    // Recorded under motion policy 1, like the 2026-10-18 field test: every
    // jittery stop fix is an accepted point.
    final legacy = TrackingConfig.fromMap(
      const <String, Object?>{'motionPolicyVersion': 1},
    );
    final run = await StopReplay.start(t0, config: legacy);
    final arrival = syntheticWalk(
      trackId: run.trackId,
      from: -150,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final stopStart = arrival.locations.last.capturedAt.add(
      const Duration(seconds: 5),
    );
    const stopLength = Duration(minutes: 30);
    final stop = SyntheticTrackingRoute.indoorStop(
      duration: stopLength,
      startedAt: stopStart,
      trackId: run.trackId,
    );
    final departure = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 150,
      startedAt: stopStart.add(stopLength).add(const Duration(seconds: 5)),
      eventPrefix: 'depart',
      enterTransition: true,
    );
    final points =
        await run.replay(arrival.followedBy(stop).followedBy(departure));
    final accepted = points.where((point) => point.accepted).toList();
    expect(
      accepted.where((point) => point.nativeEventId!.startsWith('indoor-')),
      hasLength(greaterThan(20)),
      reason: 'the recorded stop is full of accepted jitter',
    );

    final service = DerivedGeometryService(run.harness.repository);
    Future<Map<String, DerivedGeometryPoint>> clean() async {
      final derivedRun = await service.derive(
        owner: syntheticOwner,
        trackId: run.trackId,
        request: const DerivedGeometryRequest(
          name: 'cleaned',
          algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
        ),
      );
      return run.harness.repository.derivedCoordinatesForSourcePoints(
        owner: syntheticOwner,
        trackId: run.trackId,
        runId: derivedRun.id,
        sourcePointIds: accepted.map((point) => point.id),
      );
    }

    final cleaned = await clean();
    expect(cleaned, hasLength(accepted.length), reason: 'one per source');
    final stopPositions = <(double, double)>{
      for (final point in accepted)
        if (point.nativeEventId!.startsWith('indoor-'))
          (cleaned[point.id]!.latitude, cleaned[point.id]!.longitude),
    };
    expect(stopPositions, hasLength(1), reason: 'one point per stop');
    final (latitude, longitude) = stopPositions.single;
    expect(
      TrackGeodesy.sphericalHaversineMeters(
        syntheticOrigin.latitude,
        syntheticOrigin.longitude,
        latitude,
        longitude,
      ),
      lessThan(6),
      reason: 'the centre sits on the true stop',
    );
    for (final point in accepted) {
      final id = point.nativeEventId!;
      final index = int.parse(id.substring(id.lastIndexOf('-') + 1));
      // Walking inside the hold radius is part of the stop; the walk away is
      // raw from the second fix outside the radius, about 36 m out.
      if (id.startsWith('depart-') && index >= 6 ||
          id.startsWith('arrive-') && index <= 20) {
        expect(cleaned[point.id]!.latitude, point.latitude, reason: id);
        expect(cleaned[point.id]!.longitude, point.longitude, reason: id);
      }
    }
    final again = await clean();
    for (final point in accepted) {
      expect(again[point.id]!.latitude, cleaned[point.id]!.latitude);
      expect(again[point.id]!.longitude, cleaned[point.id]!.longitude);
    }
  });

  test('explicit capture intents are never held', () async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(captureIntent: RouteCaptureIntent.walking),
    );
    final stop = SyntheticTrackingRoute.indoorStop(
      duration: const Duration(minutes: 20),
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(stop);
    expect(
      points.map((point) => point.rejectionReason),
      everyElement(anyOf(isNull, 'poor_accuracy')),
    );
  });
}
