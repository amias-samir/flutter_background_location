import 'dart:math' as math;

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'stop_replay_support.dart';

/// D55–D58: a route recorded under older rules is decided again under the
/// current ones and stored beside what it recorded. Nothing recorded changes,
/// and deleting the review restores every recorded row.
void main() {
  final t0 = DateTime.utc(2026, 10, 24, 3);

  LocationSample fix(
    String trackId,
    int second, {
    required double east,
    double north = 0,
    double accuracy = 5,
    double? speed,
    double? speedAccuracy,
    ActivitySnapshot? activity,
  }) {
    final at = t0.add(Duration(seconds: second));
    return LocationSample(
      latitude: syntheticOrigin.latitude + north / syntheticMetersPerDegree,
      longitude: syntheticOrigin.longitude +
          east /
              (syntheticMetersPerDegree *
                  math.cos(syntheticOrigin.latitude * math.pi / 180)),
      capturedAt: at,
      horizontalAccuracy: accuracy,
      verticalAccuracy: 3,
      speed: speed,
      speedAccuracy: speedAccuracy,
      provider: 'fused',
      eventId: 'review-$second',
      trackId: trackId,
      capturedActivity: activity ??
          ActivitySnapshot(
            type: TrackingActivityType.unknown,
            confidence: 40,
            recordedAt: at,
            source: 'android_activity_recognition',
          ),
      nativeReceivedAt: at.add(const Duration(milliseconds: 200)),
      providerTimeDeltaMsAtReceipt: 200,
      captureGenerationId: 'synthetic-generation',
      nativeLifecycle: TrackerLifecycle.tracking,
      mockDetectionAvailable: true,
    );
  }

  /// The walk 09:08 failure of the two-phone field test, with generated
  /// coordinates: a walk, a silence, three wrong fixes 100–140 m away, the
  /// true place, and the walk on.
  SyntheticTrackingRoute excursion(String trackId) {
    final walkIn = syntheticWalk(
      trackId: trackId,
      from: -60,
      to: 0,
      startedAt: t0,
      eventPrefix: 'in',
    );
    final arrivedAt = 50;
    final place = <LocationSample>[
      fix(trackId, arrivedAt + 29,
          east: -93,
          north: 32,
          accuracy: 5.8,
          speed: 0.51,
          speedAccuracy: 11.1),
      fix(trackId, arrivedAt + 35,
          east: -125,
          north: 35,
          accuracy: 6.8,
          speed: 3.58,
          speedAccuracy: 7.1),
      fix(trackId, arrivedAt + 41,
          east: -133,
          north: 24,
          accuracy: 10.9,
          speed: 2.81,
          speedAccuracy: 5.8),
      for (var i = 0; i < 19; i += 1)
        fix(trackId, arrivedAt + 48 + i * 18,
            east: (i.isEven ? -6.0 : 8.0) + i * 0.3,
            north: i.isEven ? 4.0 : -3.0,
            accuracy: 4.5,
            speed: 0.15,
            speedAccuracy: i.isEven ? 2.9 : 1.8),
    ];
    final walkOut = syntheticWalk(
      trackId: trackId,
      from: 0,
      to: 70,
      startedAt: t0.add(Duration(seconds: arrivedAt + 48 + 19 * 18)),
      eventPrefix: 'out',
    );
    return SyntheticTrackingRoute(
      <LocationSample>[...walkIn.locations, ...place, ...walkOut.locations],
      <ActivitySnapshot>[...walkIn.activities, ...walkOut.activities],
    );
  }

  String describe(TrackPoint point) =>
      '${point.id}/${point.sequence}/${point.accepted}/${point.rejectionReason}/'
      '${point.latitude}/${point.longitude}';

  test(
      'a route recorded under quality policy 4 is reviewed once it has '
      'completed, without changing what it recorded', () async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 4,
    );
    final recorded = await run.replay(excursion(run.trackId));
    final repository = run.harness.repository;
    expect(
      await repository.tracksAwaitingReview(),
      isEmpty,
      reason: 'a route is reviewed only once it has completed',
    );
    await (run.client as TrackingTripController)
        .endCurrentDay(operationId: 'review-end-day');
    final track = (await repository.getTrack(run.trackId))!;
    final liveStops = await repository.listTrackStops(run.trackId);
    final liveSummary = (await repository.routeSummary(run.trackId))!;
    expect(liveSummary.correctedDistanceMeters, isNull);
    expect(await repository.tracksAwaitingReview(), <String>[run.trackId]);
    expect(
      await repository.tracksAwaitingReview(
        owner: const TrackingOwner(
          userId: 'another-user',
          organizationId: 'synthetic-organization',
        ),
      ),
      isEmpty,
      reason: 'owner-scoped',
    );

    // A read reviews the route first.
    final reviewed = await (run.client as TrackingSummaryController)
        .routeSummary(run.trackId);
    final corrected = reviewed.correctedDistanceMeters!;
    expect(
      reviewed.distanceMeters,
      liveSummary.distanceMeters,
      reason: 'the measured distance stays as recorded',
    );
    expect(
      corrected,
      lessThan(reviewed.distanceMeters - 150),
      reason: 'the excursion is not in the reviewed route',
    );
    expect(corrected, inInclusiveRange(125, 175));
    expect(reviewed.displayDistanceMeters, corrected);
    expect(await repository.tracksAwaitingReview(), isEmpty);

    // Nothing recorded changed.
    final after = (await repository.loadTrackBundle(run.trackId))
        .segments
        .expand((segment) => segment.points)
        .toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    expect(after.map(describe), recorded.map(describe));
    final unchanged = (await repository.getTrack(run.trackId))!;
    expect(unchanged.totalDistanceMeters, track.totalDistanceMeters);
    expect(unchanged.acceptedPointCount, track.acceptedPointCount);

    // The reviewed route is a derived run with exactly the kept fixes.
    final geometry = run.client as TrackingGeometryController;
    final runs = (await geometry.listDerivedGeometry(run.trackId))
        .where((run) =>
            run.algorithm == DerivedGeometryAlgorithm.routeQualityReview)
        .toList();
    expect(runs, hasLength(1));
    final view = await geometry.loadTrackGeometry(
      run.trackId,
      geometry: TrackGeometrySelection.derived(runs.single.id),
    );
    final kept = view.segments
        .expand((segment) => segment.points)
        .where((point) => point.accepted)
        .toList();
    expect(
      kept.map(metersFromSyntheticOrigin).reduce(math.max),
      lessThan(80),
      reason: 'no kept fix is out on the excursion',
    );
    expect(view.stops, hasLength(1), reason: 'the stay at the true place');

    // A second read reviews nothing again.
    await (run.client as TrackingSummaryController).routeSummary(run.trackId);
    expect(
      (await geometry.listDerivedGeometry(run.trackId))
          .where((run) =>
              run.algorithm == DerivedGeometryAlgorithm.routeQualityReview)
          .map((run) => run.id),
      <String>[runs.single.id],
    );

    // Deleting the review restores every recorded row.
    await repository.deleteRouteReview(run.trackId);
    final restored = (await repository.routeSummary(run.trackId))!;
    expect(restored.correctedDistanceMeters, isNull);
    expect(restored.stopCount, liveSummary.stopCount);
    expect(restored.qualityEventCount, liveSummary.qualityEventCount);
    expect(restored.visibleGapCount, liveSummary.visibleGapCount);
    expect(
      (await repository.listTrackStops(run.trackId)).map((stop) => stop.id),
      liveStops.map((stop) => stop.id),
    );
  });

  test('a route recorded under the current rules needs no review', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    await run.replay(
      syntheticWalk(
        trackId: run.trackId,
        from: 0,
        to: 120,
        startedAt: t0,
        eventPrefix: 'current',
      ),
    );
    await (run.client as TrackingTripController)
        .endCurrentDay(operationId: 'current-end-day');
    final repository = run.harness.repository;
    expect(await repository.awaitsReview(run.trackId), isFalse);
    final summary = await (run.client as TrackingSummaryController)
        .routeSummary(run.trackId);
    expect(summary.correctedDistanceMeters, isNull);
    expect(summary.displayDistanceMeters, summary.distanceMeters);
  });
  test(
      'FLT-22 a review a crash left half-stored is removed on open and the '
      'previous review stays current', () async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 4,
    );
    await run.replay(excursion(run.trackId));
    await (run.client as TrackingTripController)
        .endCurrentDay(operationId: 'crash-end-day');
    final reviewed = await (run.client as TrackingSummaryController)
        .routeSummary(run.trackId);
    final geometry = run.client as TrackingGeometryController;
    Future<List<String>> reviewRuns() async => <String>[
          for (final derived in await geometry.listDerivedGeometry(run.trackId))
            if (derived.algorithm ==
                DerivedGeometryAlgorithm.routeQualityReview)
              derived.id,
        ];
    final current = await reviewRuns();
    expect(current, hasLength(1));

    // A newer review whose kept fixes were partly written when the app died.
    final path = run.databasePath!;
    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    // The client's connection may be busy with its background passes.
    await raw.rawQuery('PRAGMA busy_timeout = 5000');
    final point = (await raw.query(
      'track_points',
      where: 'track_id = ? AND accepted = 1',
      whereArgs: <Object?>[run.trackId],
      limit: 1,
    ))
        .single;
    // A second connection's write can meet the client's commits; retry.
    Future<void> retried(Future<void> Function() write) async {
      for (var attempt = 0;; attempt += 1) {
        try {
          return await write();
        } on DatabaseException catch (error) {
          if (attempt >= 100 || error.getResultCode() != 5) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }

    await retried(() => raw.insert('derived_geometry_runs', <String, Object?>{
          'id': 'abandoned-review',
          'track_id': run.trackId,
          'name': 'reviewed',
          'algorithm': 'route_quality_review',
          'algorithm_version': '1',
          'configuration_json': '{}',
          'source_maximum_sequence': 1,
          'status': 'processing',
          'point_count': 1,
          'created_at': DateTime.utc(2030).toIso8601String(),
        }));
    await retried(() => raw.insert('derived_geometry_points', <String, Object?>{
          'run_id': 'abandoned-review',
          'source_point_id': point['id'],
          'segment_id': point['segment_id'],
          'sequence': point['sequence'],
          'latitude': point['latitude'],
          'longitude': point['longitude'],
          'matched': 1,
        }));
    await raw.close();
    expect(await reviewRuns(), current,
        reason: 'a processing review is never listed');

    final reopened = SqliteTrackRepository(
      path: path,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await reopened.initialize();
    final summary = (await reopened.routeSummary(run.trackId))!;
    expect(summary.correctedDistanceMeters, reviewed.correctedDistanceMeters);
    await reopened.close();
    final inspected = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await inspected.rawQuery('PRAGMA busy_timeout = 5000');
    expect(
      await inspected.query(
        'derived_geometry_runs',
        where: 'id = ?',
        whereArgs: <Object?>['abandoned-review'],
      ),
      isEmpty,
    );
    expect(
      await inspected.query(
        'derived_geometry_points',
        where: 'run_id = ?',
        whereArgs: <Object?>['abandoned-review'],
      ),
      isEmpty,
    );
    await inspected.close();
  });
}
