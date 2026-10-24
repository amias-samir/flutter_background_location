import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/domain/track_geodesy.dart';
import 'package:flutter_background_location_tracker/src/domain/track_stop_places.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

/// A visit to one place is one stop, however many stays it took.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 1);
  const metersPerDegree = syntheticMetersPerDegree;

  TrackStop stop(
    String id, {
    required int fromSecond,
    required int toSecond,
    double eastMeters = 0,
    String kind = TrackStopKind.dwell,
    int evidence = 10,
    double radius = 25,
    String segmentId = 'segment-1',
    bool open = false,
    int policy = 3,
    String? arrival,
  }) =>
      TrackStop(
        id: id,
        trackId: 'track',
        segmentId: segmentId,
        kind: kind,
        latitude: 0.5,
        longitude: 0.5 + eastMeters / (metersPerDegree * 0.99996192),
        centreSigmaMeters: 2,
        radiusMeters: radius,
        startedAt: t0.add(Duration(seconds: fromSecond)),
        lastSeenAt: t0.add(Duration(seconds: toSecond - 5)),
        endedAt: open ? null : t0.add(Duration(seconds: toSecond)),
        evidenceCount: evidence,
        qualityPolicyVersion: policy,
        firstSequence: fromSecond,
        lastSequence: toSecond,
        arrivalPointId: arrival ?? 'arrival-$id',
        departurePointId: open ? null : 'departure-$id',
      );

  double metersBetween(TrackStop a, TrackStop b) =>
      TrackGeodesy.sphericalHaversineMeters(
        a.latitude,
        a.longitude,
        b.latitude,
        b.longitude,
      );

  group('merge', () {
    test('stays a short walk apart are one stop', () {
      final first = stop('a', fromSecond: 0, toSecond: 600, evidence: 30);
      final second = stop(
        'b',
        fromSecond: 660,
        toSecond: 1200,
        eastMeters: 30,
        kind: TrackStopKind.still,
      );
      final merged = TrackStopPlaces.merge(<TrackStop>[second, first]).single;
      expect(merged.id, 'a');
      expect(merged.startedAt, first.startedAt);
      expect(merged.endedAt, second.endedAt);
      expect(merged.lastSeenAt, second.lastSeenAt);
      expect(merged.duration, const Duration(minutes: 20));
      expect(merged.kind, TrackStopKind.still);
      expect(merged.evidenceCount, 40);
      expect(merged.arrivalPointId, 'arrival-a');
      expect(merged.departurePointId, 'departure-b');
      expect(merged.firstSequence, 0);
      expect(merged.lastSequence, 1200);
      // Weighted towards the stay with more evidence.
      expect(metersBetween(merged, first), closeTo(7.5, 0.5));
      // Both hold discs fit inside the place's.
      expect(
        merged.radiusMeters,
        greaterThanOrEqualTo(metersBetween(merged, second) + 25),
      );
    });

    test('a long walk or a distant stay starts another stop', () {
      final first = stop('a', fromSecond: 0, toSecond: 600);
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          first,
          stop('b', fromSecond: 600 + 181, toSecond: 1200, eastMeters: 10),
        ]),
        hasLength(2),
        reason: 'more than three minutes later',
      );
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          first,
          stop('b', fromSecond: 660, toSecond: 1200, eastMeters: 80),
        ]),
        hasLength(2),
        reason: 'more than 75 m away',
      );
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          first,
          stop(
            'b',
            fromSecond: 660,
            toSecond: 1200,
            eastMeters: 10,
            segmentId: 'segment-2',
          ),
        ]),
        hasLength(2),
        reason: 'a pause and resume separates the stays',
      );
    });

    test(
        'from quality policy 5, a stay anchored on the fix that left the '
        'place continues it at any distance', () {
      // A visit drifted 77 m across its radius and stopped again at the
      // departure fix (bhotechaur 14:02).
      final first = stop('a', fromSecond: 0, toSecond: 600, policy: 5);
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          first,
          stop('b',
              fromSecond: 600,
              toSecond: 1200,
              eastMeters: 77,
              policy: 5,
              arrival: 'departure-a'),
        ]),
        hasLength(1),
      );
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          first,
          stop('b', fromSecond: 600, toSecond: 1200, eastMeters: 77, policy: 5),
        ]),
        hasLength(2),
        reason: 'anchored on a later fix, 77 m away',
      );
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          stop('a', fromSecond: 0, toSecond: 600, policy: 4),
          stop('b',
              fromSecond: 600,
              toSecond: 1200,
              eastMeters: 77,
              policy: 4,
              arrival: 'departure-a'),
        ]),
        hasLength(2),
        reason: 'older policies keep the 75 m rule alone',
      );
      expect(
        TrackStopPlaces.merge(<TrackStop>[
          first,
          stop('b',
              fromSecond: 600 + 181,
              toSecond: 1200,
              eastMeters: 77,
              policy: 5,
              arrival: 'departure-a'),
        ]),
        hasLength(2),
        reason: 'more than three minutes later',
      );
    });

    test('a place does not drift along a chain of stays', () {
      final merged = TrackStopPlaces.merge(<TrackStop>[
        stop('a', fromSecond: 0, toSecond: 300),
        stop('b', fromSecond: 330, toSecond: 600, eastMeters: 60),
        stop('c', fromSecond: 630, toSecond: 900, eastMeters: 120),
      ]);
      expect(merged.map((item) => item.id), <String>['a', 'c']);
    });

    test('a current stay keeps the place open', () {
      final merged = TrackStopPlaces.merge(<TrackStop>[
        stop('a', fromSecond: 0, toSecond: 600),
        stop('b', fromSecond: 640, toSecond: 900, eastMeters: 20, open: true),
      ]).single;
      expect(merged.isOpen, isTrue);
      expect(merged.departurePointId, isNull);
      expect(merged.duration, const Duration(seconds: 895));
    });
  });

  test('the repository lists and exports a visit as one stop', () async {
    final harness = RepositoryHarness()..now = t0;
    await harness.initialize();
    addTearDown(harness.repository.close);
    final trackId = await harness.createActiveTrack(trackId: 'places');
    final repository = harness.repository;

    PointWriteRequest fix(int second,
            {required bool accepted, double east = 0}) =>
        PointWriteRequest(
          trackId: trackId,
          sample: LocationSample(
            latitude: 0.5,
            longitude: 0.5 + east / (metersPerDegree * 0.99996192),
            capturedAt: t0.add(Duration(seconds: second)),
            horizontalAccuracy: 4,
            provider: 'fused',
            eventId: 'fix-$second',
            trackId: trackId,
          ),
          activity: const ActivitySnapshot.unknown(),
          motionState: MotionState.unknown,
          accepted: accepted,
          qualityFlags: accepted
              ? TrackPointQualityFlag.none
              : TrackPointQualityFlag.duringStop,
          rejectionReason: accepted ? null : FixQualityIssue.stationaryHold,
          qualityPolicyVersion: 3,
        );
    TrackStopOpen open(int second, double east) => TrackStopOpen(
          kind: TrackStopKind.dwell,
          latitude: 0.5,
          longitude: 0.5 + east / (metersPerDegree * 0.99996192),
          centreSigmaMeters: 2,
          radiusMeters: 25,
          startedAt: t0.add(Duration(seconds: second)),
          qualityPolicyVersion: 3,
        );

    await repository.appendPoint(fix(0, accepted: true));
    await repository.appendPointWithStop(
      fix(130, accepted: false),
      null,
      open(5, 0),
    );
    await repository.appendPointWithStop(
      fix(300, accepted: true, east: 30),
      null,
      const TrackStopClose(departure: true),
    );
    await repository.appendPointWithStop(
      fix(440, accepted: false, east: 32),
      null,
      open(330, 32),
    );
    await repository.appendPointWithStop(
      fix(700, accepted: true, east: 160),
      null,
      const TrackStopClose(departure: true),
    );
    await repository.completeTrack(trackId, reason: 'done');

    final stops = await repository.listTrackStops(trackId);
    expect(stops, hasLength(1));
    expect(stops.single.startedAt, t0.add(const Duration(seconds: 5)));
    expect(stops.single.endedAt, t0.add(const Duration(seconds: 700)));
    expect(stops.single.evidenceCount, 2);
    expect((await repository.loadTrackBundle(trackId)).stops, hasLength(1));
  });

  test('walking between two parts of a place leaves one stop', () async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: TrackingPolicyVersions.qualityPolicy,
    );
    final first = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 4),
      startedAt: t0,
      seed: 3,
      eventPrefix: 'shrine-1',
      trackId: run.trackId,
    );
    final walkAt = t0.add(const Duration(minutes: 4, seconds: 5));
    final walk = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 35,
      startedAt: walkAt,
      eventPrefix: 'between',
      enterTransition: true,
    );
    final secondAt = walkAt.add(const Duration(seconds: 35));
    final second = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 4),
      startedAt: secondAt,
      origin: (
        latitude: syntheticOrigin.latitude,
        longitude: syntheticOrigin.longitude +
            35 /
                (syntheticMetersPerDegree *
                    0.99996192), // cos(0.5°) at the synthetic origin
      ),
      seed: 5,
      eventPrefix: 'shrine-2',
      trackId: run.trackId,
    );
    final leave = syntheticWalk(
      trackId: run.trackId,
      from: 35,
      to: 200,
      startedAt: secondAt.add(const Duration(minutes: 4, seconds: 5)),
      eventPrefix: 'leave',
      enterTransition: true,
    );
    await run.replay(
      first.followedBy(walk).followedBy(second).followedBy(leave),
    );

    final raw = await databaseFactoryFfi.openDatabase(
      run.databasePath!,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final records = await raw.rawQuery('SELECT COUNT(*) AS n FROM track_stops');
    await raw.close();
    expect(records.single['n'], 1, reason: 'one stored row per visit');
    final stops = await run.harness.repository.listTrackStops(run.trackId);
    expect(stops, hasLength(1), reason: 'one visit, one stop');
    final visit = stops.single;
    expect(visit.isOpen, isFalse);
    expect(
      visit.startedAt.difference(t0).inSeconds,
      lessThan(30),
    );
    expect(
      visit.endedAt!.isAfter(secondAt.add(const Duration(minutes: 3))),
      isTrue,
    );
  });
}
