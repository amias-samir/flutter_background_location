import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

/// Schema 17: route details kept in the database as a route records.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 2);
  const metersPerDegree = syntheticMetersPerDegree;

  PointWriteRequest fix(
    String trackId,
    int second, {
    bool accepted = true,
    double north = 0,
    double? speed,
    double? speedAccuracy,
    String? reason,
    int flags = TrackPointQualityFlag.none,
  }) =>
      PointWriteRequest(
        trackId: trackId,
        sample: LocationSample(
          latitude: 0.5 + north / metersPerDegree,
          longitude: 0.5,
          capturedAt: t0.add(Duration(seconds: second)),
          horizontalAccuracy: 4,
          speed: speed,
          speedAccuracy: speedAccuracy,
          provider: 'fused',
          eventId: 'fix-$second',
          trackId: trackId,
        ),
        activity: const ActivitySnapshot.unknown(),
        motionState: MotionState.unknown,
        accepted: accepted,
        qualityFlags: flags,
        rejectionReason: reason,
        qualityPolicyVersion: 4,
      );

  PointWriteRequest held(String trackId, int second, {double north = 0}) => fix(
        trackId,
        second,
        accepted: false,
        north: north,
        reason: FixQualityIssue.stationaryHold,
        flags: TrackPointQualityFlag.duringStop,
      );

  TrackStopOpen open(int second, {double north = 0}) => TrackStopOpen(
        kind: TrackStopKind.dwell,
        latitude: 0.5 + north / metersPerDegree,
        longitude: 0.5,
        centreSigmaMeters: 2,
        radiusMeters: 25,
        startedAt: t0.add(Duration(seconds: second)),
        qualityPolicyVersion: 4,
      );

  group('stops, one row per visit', () {
    late RepositoryHarness harness;
    late String trackId;

    setUp(() async {
      harness = RepositoryHarness()..now = t0;
      await harness.initialize();
      trackId = await harness.createActiveTrack(trackId: 'visits');
    });

    tearDown(() => harness.repository.close());

    Future<void> stay(int from, int to, {double north = 0}) async {
      final repository = harness.repository;
      await repository.appendPointWithStop(
        held(trackId, from + 130, north: north),
        null,
        open(from, north: north),
      );
      await repository.appendPointWithStop(
        fix(trackId, to, north: north + 40),
        null,
        const TrackStopClose(departure: true),
      );
    }

    test('a stay continuing the place extends its row', () async {
      await harness.repository.appendPoint(fix(trackId, 0));
      await stay(10, 400);
      await stay(430, 900, north: 30);
      final stops = await harness.repository.listTrackStops(trackId);
      expect(stops, hasLength(1));
      expect(stops.single.startedAt, t0.add(const Duration(seconds: 10)));
      expect(stops.single.endedAt, t0.add(const Duration(seconds: 900)));
      expect(stops.single.evidenceCount, 2);
    });

    test('a later or distant stay is a new row', () async {
      await harness.repository.appendPoint(fix(trackId, 0));
      await stay(10, 400);
      await stay(400 + 200, 900, north: 10);
      await stay(930, 1300, north: 200);
      expect(await harness.repository.listTrackStops(trackId), hasLength(3));
    });
  });

  group('summary', () {
    test('kept live as a route records, equal to a full recompute', () async {
      final run = await StopReplay.start(t0, config: const TrackingConfig());
      final walk = syntheticWalk(
        trackId: run.trackId,
        from: -150,
        to: 0,
        startedAt: t0,
        eventPrefix: 'arrive',
      );
      final stopAt = walk.locations.last.capturedAt.add(
        const Duration(seconds: 5),
      );
      final stop = SyntheticTrackingRoute.pocketStop(
        duration: const Duration(minutes: 6),
        startedAt: stopAt,
        trackId: run.trackId,
      );
      final leave = syntheticWalk(
        trackId: run.trackId,
        from: 0,
        to: 150,
        startedAt: stopAt.add(const Duration(minutes: 6, seconds: 5)),
        eventPrefix: 'leave',
        enterTransition: true,
      );
      await run.replay(walk.followedBy(stop).followedBy(leave));
      final repository = run.harness.repository;

      final live = (await repository.routeSummary(run.trackId))!;
      expect(live.stopCount, 1);
      expect(live.stopped, greaterThan(const Duration(minutes: 5)));
      expect(live.moving, live.recording - live.stopped);
      expect(live.firstFixAt, walk.locations.first.capturedAt);
      expect(live.lastFixAt, leave.locations.last.capturedAt);
      expect(live.maxSpeedMetersPerSecond, isNotNull);
      expect(live.stopsSource, TrackStopSource.recorded);
      expect(live.acceptedPointCount, greaterThan(40));

      await repository.refreshRouteSummary(run.trackId);
      final recomputed = (await repository.routeSummary(run.trackId))!;
      expect(recomputed.recording, live.recording);
      expect(recomputed.stopped, live.stopped);
      expect(recomputed.moving, live.moving);
      expect(recomputed.stopCount, live.stopCount);
      expect(recomputed.maxSpeedMetersPerSecond, live.maxSpeedMetersPerSecond);
      expect(recomputed.qualityEventCount, live.qualityEventCount);
      expect(recomputed.stopEvidenceRunCount, live.stopEvidenceRunCount);
      expect(recomputed.visibleGapCount, live.visibleGapCount);
      expect(recomputed.firstFixAt, live.firstFixAt);
      expect(recomputed.lastFixAt, live.lastFixAt);

      final bundle = await repository.loadTrackBundle(run.trackId);
      expect(bundle.summary?.stopCount, 1);
    });

    test('pausing ends the recording time; Trip totals cover the legs',
        () async {
      final harness = RepositoryHarness()..now = t0;
      await harness.initialize();
      addTearDown(harness.repository.close);
      final trackId = await harness.createActiveTrack(trackId: 'paused');
      final repository = harness.repository;
      await repository.appendPoint(fix(trackId, 0, speed: 1.4));
      await repository.appendPoint(
        fix(trackId, 60, north: 80, speed: 1.6, speedAccuracy: 0.5),
      );
      // Implausibly precise but too fast: ignored for the maximum.
      await repository.appendPoint(
        fix(trackId, 65, north: 81, speed: 90, speedAccuracy: 0.5),
      );
      harness.now = t0.add(const Duration(seconds: 120));
      await repository.pauseTrack(trackId, reason: 'break');
      final paused = (await repository.routeSummary(trackId))!;
      expect(paused.recording, const Duration(seconds: 120));
      expect(paused.maxSpeedMetersPerSecond, 1.6);
      expect(paused.distanceMeters, greaterThan(70));

      final trip = (await repository.tripSummary(trackId))!;
      expect(trip.legCount, 1);
      expect(trip.recording, paused.recording);
      expect(trip.distanceMeters, paused.distanceMeters);
      expect(trip.stepCount, isNull);
    });
  });

  test('ending the day closes a current stop', () async {
    final harness = RepositoryHarness()..now = t0;
    await harness.initialize();
    final adapter = FakeTrackerAdapter();
    final controller = await TrackingClient.openWithTrips(
      owner: syntheticOwner,
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => harness.now,
    );
    addTearDown(controller.dispose);
    final started = await controller.startTrip(
      const TripStartRequest(routeId: 'end_day', operationId: 'start-end-day'),
    );
    final trackId = started.leg.trackId;
    await harness.repository.appendPoint(fix(trackId, 0));
    await harness.repository.appendPointWithStop(
      held(trackId, 130),
      null,
      open(5),
    );
    harness.now = t0.add(const Duration(minutes: 5));
    await controller.endCurrentDay(operationId: 'end-day-1');
    final stop = (await harness.repository.listTrackStops(trackId)).single;
    expect(stop.isOpen, isFalse);
    expect(stop.endedAt, t0.add(const Duration(seconds: 130)));
  });

  group('upgrading from schema 16', () {
    late Directory directory;

    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp('fbl-v17-');
    });

    tearDown(() => directory.delete(recursive: true));

    test('consolidates split stops, fills decisions and computes summaries',
        () async {
      final path = '${directory.path}/route.sqlite';
      SqliteTrackRepository open16() => SqliteTrackRepository(
            path: path,
            databaseFactoryOverride: databaseFactoryFfi,
            singleInstance: false,
          );
      final repository = open16();
      await repository.initialize();
      final trackId = await repository.createTrack(
        userId: 'user',
        organizationId: 'org',
        config: const TrackingConfig(),
        requestedTrackId: 'upgraded',
      );
      await repository.markTrackActive(trackId);
      await repository.appendPoint(fix(trackId, 0));
      await repository.appendPointWithStop(held(trackId, 130), null, open(5));
      await repository.appendPointWithStop(
        fix(trackId, 400, north: 40),
        null,
        const TrackStopClose(departure: true),
      );
      await repository.completeTrack(trackId, reason: 'done');
      await repository.close();

      // As schema 16 left it: a visit split into two rows, no stored
      // decisions and no summaries.
      final raw = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final row = (await raw.query('track_stops')).single;
      await raw.insert('track_stops', <String, Object?>{
        ...row,
        'id': 'second-stay',
        'started_at': t0.add(const Duration(seconds: 430)).toIso8601String(),
        'last_seen_at': t0.add(const Duration(seconds: 800)).toIso8601String(),
        'ended_at': t0.add(const Duration(seconds: 820)).toIso8601String(),
        'departure_point_id': null,
      });
      await raw.execute('UPDATE track_continuity_gaps SET visible = NULL');
      await raw.execute('UPDATE track_quality_runs SET stop_evidence = NULL');
      await raw.execute('DELETE FROM track_summaries');
      await raw.execute('DELETE FROM trip_summaries');
      await raw.setVersion(16);
      await raw.close();

      final upgraded = open16();
      await upgraded.initialize();
      final stops = await upgraded.listTrackStops(trackId);
      expect(stops, hasLength(1));
      expect(stops.single.endedAt, t0.add(const Duration(seconds: 820)));
      final summary = (await upgraded.routeSummary(trackId))!;
      expect(summary.stopCount, 1);
      expect(summary.stopsSource, TrackStopSource.recorded);
      expect(summary.stopEvidenceRunCount, 1);
      await upgraded.close();

      final inspected = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      expect(await inspected.getVersion(), 18);
      expect(
        await inspected.rawQuery(
          'SELECT id FROM track_quality_runs WHERE stop_evidence IS NULL',
        ),
        isEmpty,
      );
      await inspected.close();
    });
  });

  test('the visible-gap rule marks holes, not stops', () {
    bool visible(TrackingGapCause cause, {int seconds = 10, double m = 20}) =>
        TrackingContinuityGap.visibleFor(
          cause: cause,
          providerGap: Duration(seconds: seconds),
          straightLineDistanceMeters: m,
        );
    expect(visible(TrackingGapCause.explicitPause), isTrue);
    expect(visible(TrackingGapCause.acceptedFixRejectionRun), isFalse);
    expect(
        visible(TrackingGapCause.acceptedFixRejectionRun, seconds: 60), isTrue);
    expect(visible(TrackingGapCause.unknown, m: 150), isTrue);
    expect(
      visible(TrackingGapCause.expectedStationarySuppression, seconds: 900),
      isFalse,
      reason: 'a stop or pause is no hole',
    );
  });
}
