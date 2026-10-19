import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/domain/stop_site.dart';
import 'package:flutter_background_location_tracker/src/domain/track_geodesy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

// End-to-end replays of the 2026-10-19 field test (temple, home rooms,
// roadside bike stop) through the real TrackingClient, validator and SQLite
// repository under quality policy 3, where a stop is a stay at a place. Every
// coordinate is generated around a synthetic origin.

const _stopReasons = <String>{
  FixQualityIssue.stationaryHold,
  FixQualityIssue.stationaryOutlier,
};

void main() {
  final t0 = DateTime.utc(2026, 10, 19, 3);

  test('a pocket stop is held from its first quiet fix and recorded', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final arrival = syntheticWalk(
      trackId: run.trackId,
      from: -150,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final stopStart =
        arrival.locations.last.capturedAt.add(const Duration(seconds: 5));
    const stopLength = Duration(minutes: 10);
    final stop = SyntheticTrackingRoute.pocketStop(
      duration: stopLength,
      startedAt: stopStart,
      trackId: run.trackId,
    );
    final leftAt = stopStart.add(stopLength).add(const Duration(seconds: 5));
    final departure = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 150,
      startedAt: leftAt,
      eventPrefix: 'depart',
    );
    final points =
        await run.replay(arrival.followedBy(stop).followedBy(departure));

    final inStop = points
        .where((point) => point.nativeEventId!.startsWith('pocket-stop-'))
        .toList();
    // Within the quiet window of the last walking reading a fix can still
    // count as the arrival; after it, no stop jitter enters the route.
    final quietFrom = arrival.activities.last.recordedAt!.add(
      StopSitePolicy.quietWindow,
    );
    expect(
      inStop
          .where((point) => point.capturedAt.isAfter(quietFrom))
          .where((point) => point.accepted),
      isEmpty,
      reason: 'no stop jitter enters the route',
    );
    expect(
        inStop.where((point) => point.accepted).length, lessThanOrEqualTo(1));
    expect(
      inStop
          .where((point) => !point.accepted)
          .map((point) => point.rejectionReason),
      everyElement(isIn(_stopReasons)),
    );

    final departing = points
        .where((point) => point.nativeEventId!.startsWith('depart-'))
        .toList();
    final firstAccepted = departing.indexWhere((point) => point.accepted);
    expect(firstAccepted, isNonNegative);
    expect(
      departing[firstAccepted].capturedAt.difference(leftAt),
      lessThanOrEqualTo(const Duration(seconds: 45)),
      reason: 'the walk away is picked up within 45 s',
    );
    expect(
      departing.skip(firstAccepted).every((point) => point.accepted),
      isTrue,
    );

    final track = (await run.harness.repository.getTrack(run.trackId))!;
    expect(track.segmentCount, 1);
    // Two 150 m walks and the chord between where they end and start.
    expect(track.totalDistanceMeters, inInclusiveRange(285, 325));

    final stops = await run.harness.repository.listTrackStops(run.trackId);
    expect(stops, hasLength(1));
    final record = stops.single;
    expect(record.kind, TrackStopKind.dwell);
    expect(record.isOpen, isFalse);
    expect(
      record.startedAt.difference(stopStart).abs(),
      lessThanOrEqualTo(const Duration(seconds: 10)),
      reason: 'the stay starts where the walk in ended',
    );
    expect(record.endedAt, departing[firstAccepted].capturedAt);
    expect(record.departurePointId, departing[firstAccepted].id);
    // The arrival is the last route point before the first held fix.
    final firstHeld = points.firstWhere((point) => !point.accepted);
    final arrivalPoint = points.lastWhere(
      (point) => point.accepted && point.sequence < firstHeld.sequence,
    );
    expect(record.arrivalPointId, arrivalPoint.id);
    expect(
      (record.duration - stopLength).inSeconds,
      inInclusiveRange(0, 60),
      reason: 'the stay lasts until the walk away leaves the radius',
    );
    expect(
      TrackGeodesy.sphericalHaversineMeters(
        syntheticOrigin.latitude,
        syntheticOrigin.longitude,
        record.latitude,
        record.longitude,
      ),
      lessThan(10),
      reason: 'the record sits on the place',
    );
    expect(
      record.evidenceCount,
      points
          .where((point) => !point.accepted)
          .where((point) => !point.capturedAt.isBefore(record.startedAt))
          .length,
    );
    final quality = await run.harness.repository.trackQualitySummary(
      owner: syntheticOwner,
      trackId: run.trackId,
    );
    expect(quality.visibleQualityRunCount, 0);
    final gaps = await run.harness.repository.listContinuityGaps(run.trackId);
    expect(
      gaps.map((gap) => gap.cause),
      isNot(contains(TrackingGapCause.acceptedFixRejectionRun)),
    );
  });

  test('quality policy 2 records the same pocket stop as before', () async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 2,
    );
    final stop = SyntheticTrackingRoute.pocketStop(
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(stop);
    expect(
      points.map((point) => point.rejectionReason),
      everyElement(isNull),
      reason: 'without still evidence version 2 holds nothing',
    );
    expect(
      points.map((point) => point.qualityPolicyVersion).toSet(),
      <int>{2},
    );
  });

  test('walking about inside the place stays part of the stop', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final first = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 5),
      startedAt: t0,
      trackId: run.trackId,
    );
    final wanderAt = t0.add(const Duration(minutes: 5, seconds: 5));
    final wander = SyntheticTrackingRoute.placeWander(
      startedAt: wanderAt,
      trackId: run.trackId,
    );
    final second = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 3),
      startedAt: wanderAt.add(const Duration(minutes: 3, seconds: 5)),
      seed: 8,
      eventPrefix: 'pocket-again',
      trackId: run.trackId,
    );
    final leftAt = wanderAt.add(const Duration(minutes: 6, seconds: 10));
    final departure = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 120,
      startedAt: leftAt,
      eventPrefix: 'depart',
    );
    final points = await run.replay(
      first.followedBy(wander).followedBy(second).followedBy(departure),
    );

    final wandering = points
        .where((point) => point.nativeEventId!.startsWith('place-wander-'))
        .toList();
    expect(wandering, isNotEmpty);
    expect(
      wandering.where((point) => point.accepted),
      isEmpty,
      reason: 'rooms and courtyards are part of the stop',
    );
    expect(
      points
          .where((point) => point.nativeEventId!.startsWith('pocket-again-'))
          .where((point) => point.accepted),
      isEmpty,
    );
    final departing = points
        .where((point) => point.nativeEventId!.startsWith('depart-'))
        .toList();
    final firstAccepted = departing.indexWhere((point) => point.accepted);
    expect(
      departing[firstAccepted].capturedAt.difference(leftAt),
      lessThanOrEqualTo(const Duration(seconds: 45)),
    );
  });

  test('a slow stroll with short pauses keeps its distance', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final stroll = SyntheticTrackingRoute.slowStrollWithPauses(
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(stroll);
    // Walking moves; only quiet fixes during a pause are held, and pauses
    // shorter than two minutes are not stops.
    for (final point in points.where((point) => !point.accepted)) {
      expect(point.rejectionReason, FixQualityIssue.stationaryHold);
      expect(point.activityRawType, 'unknown');
    }
    expect(await run.harness.repository.listTrackStops(run.trackId), isEmpty);
    final pathLength = metersFromSyntheticOrigin(points.last);
    final track = (await run.harness.repository.getTrack(run.trackId))!;
    expect(
      track.totalDistanceMeters,
      inInclusiveRange(pathLength * 0.97, pathLength * 1.03 + 8),
    );
  });

  test('a roadside bike stop is held once it lasts two minutes', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    const stopLength = Duration(minutes: 6);
    final roadside = SyntheticTrackingRoute.roadsideStop(
      stop: stopLength,
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(roadside);
    final stopAt = t0.add(const Duration(seconds: 40));
    final leftAt = stopAt.add(stopLength);

    final inStop = points
        .where((point) =>
            !point.capturedAt.isBefore(stopAt) &&
            point.capturedAt.isBefore(leftAt))
        .toList();
    expect(
      inStop
          .where((point) => point.capturedAt
              .isAfter(stopAt.add(const Duration(seconds: 150))))
          .where((point) => point.accepted),
      isEmpty,
      reason: 'the jacket-pocket stop is a stop after two minutes',
    );
    final departing =
        points.where((point) => !point.capturedAt.isBefore(leftAt)).toList();
    final firstAccepted = departing.indexWhere((point) => point.accepted);
    expect(
      departing[firstAccepted].capturedAt.difference(leftAt),
      lessThanOrEqualTo(const Duration(seconds: 30)),
      reason: 'the ride away is picked up within 30 s',
    );
    expect(
      points
          .where((point) => point.capturedAt.isBefore(stopAt))
          .every((point) => point.accepted),
      isTrue,
      reason: 'the arrival is kept',
    );
  });

  test('poor fixes during a stop leave no quality marker', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final stop = SyntheticTrackingRoute.pocketStop(
      startedAt: t0,
      trackId: run.trackId,
    );
    final poor = <LocationSample>[
      for (var index = 0; index < 4; index += 1)
        LocationSample(
          latitude: syntheticOrigin.latitude + 60 / syntheticMetersPerDegree,
          longitude: syntheticOrigin.longitude,
          capturedAt: t0.add(Duration(minutes: 5, seconds: 2 + index * 20)),
          horizontalAccuracy: 120,
          provider: 'fused',
          eventId: 'indoor-network-$index',
          trackId: run.trackId,
          nativeReceivedAt:
              t0.add(Duration(minutes: 5, seconds: 2 + index * 20)),
          providerTimeDeltaMsAtReceipt: 100,
          captureGenerationId: 'synthetic-generation',
          nativeLifecycle: TrackerLifecycle.tracking,
          mockDetectionAvailable: true,
        ),
    ];
    final locations = <LocationSample>[...stop.locations, ...poor]
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final departure = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 120,
      startedAt: t0.add(const Duration(minutes: 10, seconds: 5)),
      eventPrefix: 'depart',
    );
    final points = await run.replay(
      SyntheticTrackingRoute(locations, stop.activities).followedBy(departure),
    );

    final network = points
        .where((point) => point.nativeEventId!.startsWith('indoor-network-'))
        .toList();
    expect(network, hasLength(4));
    for (final point in network) {
      expect(point.rejectionReason, 'poor_accuracy');
      expect(
        point.qualityFlags & TrackPointQualityFlag.duringStop,
        TrackPointQualityFlag.duringStop,
      );
    }
    final quality = await run.harness.repository.trackQualitySummary(
      owner: syntheticOwner,
      trackId: run.trackId,
    );
    expect(quality.visibleQualityRunCount, 0);
    final gaps = await run.harness.repository.listContinuityGaps(run.trackId);
    expect(
      gaps.map((gap) => gap.cause),
      isNot(contains(TrackingGapCause.acceptedFixRejectionRun)),
    );
  });

  test('a Dart restart during a pocket stop restores it', () async {
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
        requestedTripId: 'synthetic_pocket_restart',
        routeId: 'synthetic_pocket_restart',
        config: TrackingConfig(),
      ),
    );
    final trackId = started.leg.trackId;
    final before = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 8),
      startedAt: t0,
      trackId: trackId,
    );
    await emitAndWait(harness, first, trackId, before);
    final last = await harness.repository.findLastRawPoint(trackId);
    expect(last?.rejectionReason, isIn(_stopReasons));
    final openBefore = await harness.repository.findOpenTrackStop(trackId);
    expect(openBefore, isNotNull);

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

    final resumeAt = t0.add(const Duration(minutes: 9));
    final jitter = SyntheticTrackingRoute(
      <LocationSample>[
        for (var step = 0; step < 12; step += 1)
          syntheticJitterFix(
            trackId: trackId,
            at: resumeAt.add(Duration(seconds: step * 10)),
            eastMeters: step.isEven ? 6 : -6,
            northMeters: step % 3 == 0 ? 5 : -4,
            eventId: 'after-restart-$step',
          ),
      ],
      const <ActivitySnapshot>[],
    );
    final points = await emitAndWait(harness, second, trackId, jitter);
    expect(
      points
          .where((point) => point.nativeEventId!.startsWith('after-restart-'))
          .where((point) => point.accepted),
      isEmpty,
    );
    // The stored stop carries on: same record, same centre, longer stay.
    final openAfter = await harness.repository.findOpenTrackStop(trackId);
    expect(openAfter?.id, openBefore!.id);
    expect(openAfter!.latitude, openBefore.latitude);
    expect(openAfter.longitude, openBefore.longitude);
    expect(openAfter.startedAt, openBefore.startedAt);
    expect(openAfter.evidenceCount, openBefore.evidenceCount + 12);
    expect(openAfter.lastSeenAt, jitter.locations.last.capturedAt);
    expect(await harness.repository.listTrackStops(trackId), hasLength(1));
  });

  test('a pause shorter than two minutes holds its jitter and is no stop',
      () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final arrival = syntheticWalk(
      trackId: run.trackId,
      from: -60,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final pauseStart =
        arrival.locations.last.capturedAt.add(const Duration(seconds: 5));
    final pause = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(seconds: 70),
      startedAt: pauseStart,
      seed: 9,
      eventPrefix: 'pause',
      trackId: run.trackId,
    );
    final walkOn = pauseStart.add(const Duration(seconds: 75));
    final onward = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 60,
      startedAt: walkOn,
      eventPrefix: 'onward',
    );
    final points =
        await run.replay(arrival.followedBy(pause).followedBy(onward));

    expect(
      points
          .where((point) => point.nativeEventId!.startsWith('pause-'))
          .where((point) => point.accepted),
      isEmpty,
    );
    final onwardPoints = points
        .where((point) => point.nativeEventId!.startsWith('onward-'))
        .toList();
    expect(
      onwardPoints.every((point) => point.accepted),
      isTrue,
      reason: 'the walk on continues at its first moving fix',
    );
    expect(await run.harness.repository.listTrackStops(run.trackId), isEmpty);
  });

  group('a stay the provider fell silent in', () {
    Future<(StopReplay, List<TrackPoint>)> replay({
      required double resumeFrom,
    }) async {
      final run = await StopReplay.start(t0, config: const TrackingConfig());
      final arrival = syntheticWalk(
        trackId: run.trackId,
        from: -60,
        to: 0,
        startedAt: t0,
        eventPrefix: 'arrive',
      );
      final pauseStart =
          arrival.locations.last.capturedAt.add(const Duration(seconds: 5));
      final pause = SyntheticTrackingRoute.pocketStop(
        duration: const Duration(seconds: 70),
        startedAt: pauseStart,
        seed: 9,
        eventPrefix: 'pause',
        trackId: run.trackId,
      );
      // No fixes for six minutes, then walking on.
      final onward = syntheticWalk(
        trackId: run.trackId,
        from: resumeFrom,
        to: resumeFrom + 60,
        startedAt: pauseStart.add(const Duration(minutes: 7)),
        eventPrefix: 'onward',
      );
      final points =
          await run.replay(arrival.followedBy(pause).followedBy(onward));
      return (run, points);
    }

    test('is recorded when the walk resumes at the place', () async {
      final (run, points) = await replay(resumeFrom: 0);
      final held = points
          .where((point) => point.nativeEventId!.startsWith('pause-'))
          .toList();
      expect(held.where((point) => point.accepted), isEmpty);
      final departure = points.firstWhere(
        (point) => point.nativeEventId!.startsWith('onward-'),
      );
      expect(departure.accepted, isTrue);

      final stop =
          (await run.harness.repository.listTrackStops(run.trackId)).single;
      expect(stop.isOpen, isFalse);
      expect(stop.kind, TrackStopKind.dwell);
      expect(stop.endedAt, departure.capturedAt);
      expect(stop.departurePointId, departure.id);
      expect(stop.lastSeenAt, held.last.capturedAt);
      expect(stop.evidenceCount, held.length);
      expect(stop.firstSequence, held.first.sequence);
      expect(stop.lastSequence, held.last.sequence);
      expect(stop.duration, greaterThan(const Duration(minutes: 7)));
      expect(stop.duration, lessThan(const Duration(minutes: 8)));
    });

    test('is no stop when the walk resumes elsewhere', () async {
      // Where the device was during the silence is unknown.
      final (run, _) = await replay(resumeFrom: 200);
      expect(await run.harness.repository.listTrackStops(run.trackId), isEmpty);
    });
  });

  test('pausing the route ends a current stop at its last fix', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final stop = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 5),
      startedAt: t0,
      trackId: run.trackId,
    );
    final points = await run.replay(stop);
    final open = await run.harness.repository.findOpenTrackStop(run.trackId);
    expect(open, isNotNull, reason: 'five minutes in, the stay is a stop');

    await run.client.pauseCurrentTrack(reason: 'synthetic_pause');
    expect(await run.harness.repository.findOpenTrackStop(run.trackId), isNull);
    final closed =
        (await run.harness.repository.listTrackStops(run.trackId)).single;
    expect(closed.endedAt, points.last.capturedAt);
    expect(closed.departurePointId, isNull);
  });

  test('stops are listed per route and per Trip through the controller',
      () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final stop = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 4),
      startedAt: t0,
      trackId: run.trackId,
    );
    await run.replay(stop);
    final controller = run.client as TrackingStopController;
    final trackStops = await controller.listTrackStops(run.trackId);
    expect(trackStops, hasLength(1));
    final tripId = (await (run.client as MultiDayTripController)
            .listTripPage(const TripQuery(owner: syntheticOwner, limit: 5)))
        .items
        .single
        .id;
    final tripStops = await controller.listTripStops(tripId);
    expect(tripStops.map((stop) => stop.id), <String>[trackStops.single.id]);
  });

  group('cleaned view, stop-aware cleaning version 2', () {
    Future<Map<String, DerivedGeometryPoint>> clean(
      StopReplay run,
      List<TrackPoint> accepted,
    ) async {
      final derived =
          await DerivedGeometryService(run.harness.repository).derive(
        owner: syntheticOwner,
        trackId: run.trackId,
        request: const DerivedGeometryRequest(
          name: 'cleaned',
          algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
        ),
      );
      expect(
        derived.algorithmVersion,
        DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion,
      );
      return run.harness.repository.derivedCoordinatesForSourcePoints(
        owner: syntheticOwner,
        trackId: run.trackId,
        runId: derived.id,
        sourcePointIds: accepted.map((point) => point.id),
      );
    }

    test('a pocket stop recorded by an older build collapses to one point',
        () async {
      final run = await StopReplay.start(
        t0,
        config: const TrackingConfig(),
        qualityPolicy: 2,
      );
      final stop = SyntheticTrackingRoute.pocketStop(
        startedAt: t0,
        trackId: run.trackId,
      );
      final departure = syntheticWalk(
        trackId: run.trackId,
        from: 0,
        to: 150,
        startedAt: t0.add(const Duration(minutes: 10, seconds: 5)),
        eventPrefix: 'depart',
      );
      final points = await run.replay(stop.followedBy(departure));
      final accepted = points.where((point) => point.accepted).toList();
      final cleaned = await clean(run, accepted);

      final stopPositions = <(double, double)>{
        for (final point in accepted)
          if (point.nativeEventId!.startsWith('pocket-stop-'))
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
        lessThan(8),
      );
      for (final point in accepted) {
        final id = point.nativeEventId!;
        if (!id.startsWith('depart-')) continue;
        final index = int.parse(id.substring(id.lastIndexOf('-') + 1));
        if (index < 8) continue;
        expect(cleaned[point.id]!.latitude, point.latitude, reason: id);
        expect(cleaned[point.id]!.longitude, point.longitude, reason: id);
      }
    });

    test('a slow stroll with short pauses is not collapsed', () async {
      final run = await StopReplay.start(
        t0,
        config: const TrackingConfig(),
        qualityPolicy: 2,
      );
      final stroll = SyntheticTrackingRoute.slowStrollWithPauses(
        startedAt: t0,
        trackId: run.trackId,
      );
      final points = await run.replay(stroll);
      final accepted = points.where((point) => point.accepted).toList();
      final cleaned = await clean(run, accepted);
      double length(List<(double, double)> path) {
        var total = 0.0;
        for (var index = 1; index < path.length; index += 1) {
          total += TrackGeodesy.sphericalHaversineMeters(
            path[index - 1].$1,
            path[index - 1].$2,
            path[index].$1,
            path[index].$2,
          );
        }
        return total;
      }

      final raw = length([
        for (final point in accepted) (point.latitude, point.longitude),
      ]);
      final smoothed = length([
        for (final point in accepted)
          (cleaned[point.id]!.latitude, cleaned[point.id]!.longitude),
      ]);
      expect(smoothed, inInclusiveRange(raw * 0.97, raw * 1.0001));
    });
  });
}
