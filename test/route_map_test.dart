import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/application/route_map_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

/// Records every statement a repository runs, so a test can prove a read
/// writes nothing and binds a bounded number of arguments.
final class StatementLog {
  final statements = <(String, int)>[];
  var batches = 0;

  DatabaseFactory factory() {
    sqfliteFfiInit();
    // Test-only statement recorder; the API is marked experimental.
    // ignore: experimental_member_use
    return SqfliteDatabaseFactoryLogger(
      databaseFactoryFfi,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: (event) {
          switch (event) {
            case SqfliteLoggerSqlEvent(:final sql, :final arguments):
              statements.add(
                (sql, arguments is List ? arguments.length : 0),
              );
            case SqfliteLoggerBatchEvent():
              batches += 1;
            default:
          }
        },
      ),
    );
  }

  void clear() {
    statements.clear();
    batches = 0;
  }

  static final _write = RegExp(
    r'^\s*(INSERT|UPDATE|DELETE|REPLACE|BEGIN|COMMIT|CREATE|DROP|ALTER)\b',
    caseSensitive: false,
  );

  List<String> get writes => <String>[
        for (final (sql, _) in statements)
          if (_write.hasMatch(sql)) sql,
      ];

  int get maxArguments => statements.fold(
        0,
        (max, statement) => statement.$2 > max ? statement.$2 : max,
      );
}

void main() {
  final t0 = DateTime.utc(2026, 10, 20, 6);

  Future<StopReplay> walkStopWalk({DatabaseFactory? databaseFactory}) async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      databaseFactory: databaseFactory,
    );
    final arrive = syntheticWalk(
      trackId: run.trackId,
      from: -150,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final stopAt = arrive.locations.last.capturedAt.add(
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
    await run.replay(arrive.followedBy(stop).followedBy(leave));
    return run;
  }

  Future<String> completeTrip(StopReplay run) async {
    final trips = run.client as MultiDayTripController;
    final trip = (await trips.listTripPage(
      const TripQuery(owner: syntheticOwner, limit: 1),
    ))
        .items
        .single;
    await trips.completeTrip(trip.id, reason: 'synthetic_done');
    return trip.id;
  }

  /// Waits for the details a map asked for, by joining the cleaning the
  /// background preparation runs (or running it), so a later read meets no
  /// background write.
  Future<DerivedGeometryRun> settle(StopReplay run) async {
    final summaries = run.client as TrackingSummaryController;
    await summaries.routeSummary(run.trackId);
    return summaries.currentCleanedGeometry(run.trackId);
  }

  List<(String, double, double)> coordinates(RouteGeometryReport report) =>
      <(String, double, double)>[
        for (final part in report.parts)
          for (final point in part.points)
            (point.id, point.latitude, point.longitude),
      ];

  group('TrackingMapController', () {
    test('the client offers maps', () async {
      final run = await walkStopWalk();
      expect(run.client, isA<TrackingMapController>());
    });

    test('a completed route opens in its cleaned view without writing',
        () async {
      final log = StatementLog();
      final run = await walkStopWalk(databaseFactory: log.factory());
      final tripId = await completeTrip(run);
      final cleanedRun = await settle(run);
      final maps = run.client as TrackingMapController;

      log.clear();
      final track = await maps.loadTrackMap(run.trackId);
      final trip = await maps.loadTripMap(tripId);
      final raw = await maps.loadTrackMap(
        run.trackId,
        view: RouteGeometryView.raw,
      );
      expect(log.writes, isEmpty, reason: 'opening a map never writes');
      expect(log.batches, 0);
      expect(log.maxArguments, lessThanOrEqualTo(999));

      expect(track.view, RouteGeometryView.cleaned);
      expect(track.views, <RouteGeometryView>[
        RouteGeometryView.cleaned,
        RouteGeometryView.raw,
      ]);
      expect(track.preparing, isFalse);
      expect(track.routeSummary, isNotNull);
      expect(track.stops, isNotEmpty);
      expect(trip.tripSummary?.legCount, 1);
      expect(trip.stops.map((stop) => stop.id), track.stops.map((s) => s.id));

      // Raw: exactly what the facade assembles today.
      final geometry = run.client as TrackingGeometryController;
      final assembled = await geometry.assembleTrackRouteGeometry(run.trackId);
      expect(coordinates(raw.geometry), coordinates(assembled));
      expect(raw.geometry.gapCount, assembled.gapCount);
      expect(
        raw.geometry.inferredConnectors.map((c) => c.afterPointId),
        assembled.inferredConnectors.map((c) => c.afterPointId),
      );

      // Cleaned: the same topology, at the stored cleaned coordinates.
      final derived = await geometry.loadTrackGeometry(
        run.trackId,
        geometry: TrackGeometrySelection.derived(cleanedRun.id),
      );
      final cleanedById = <String, (double, double)>{
        for (final segment in derived.segments)
          for (final point in segment.points)
            point.id: (point.latitude, point.longitude),
      };
      expect(
        coordinates(track.geometry),
        <(String, double, double)>[
          for (final (id, latitude, longitude) in coordinates(assembled))
            (
              id,
              cleanedById[id]?.$1 ?? latitude,
              cleanedById[id]?.$2 ?? longitude,
            ),
        ],
      );
      expect(coordinates(trip.geometry), coordinates(track.geometry));
    });

    test('a missing cleaned view is prepared after the map, not by it',
        () async {
      final run = await walkStopWalk();
      await completeTrip(run);
      final cleanedRun = await settle(run);
      final geometry = run.client as TrackingGeometryController;
      await geometry.deleteDerivedGeometry(run.trackId, cleanedRun.id);
      final maps = run.client as TrackingMapController;

      final updated = run.client.trackHistoryEvents.firstWhere(
        (event) =>
            event.kind == TrackHistoryChangeKind.updated &&
            event.trackId == run.trackId,
      );
      final pending = await maps.loadTrackMap(run.trackId);
      expect(pending.view, RouteGeometryView.cleaned);
      expect(pending.preparing, isTrue);
      final assembled = await geometry.assembleTrackRouteGeometry(run.trackId);
      expect(
        coordinates(pending.geometry),
        coordinates(assembled),
        reason: 'drawn as recorded until the cleaned view is stored',
      );

      await updated;
      final ready = await maps.loadTrackMap(run.trackId);
      expect(ready.preparing, isFalse);
      expect(
        await geometry.listDerivedGeometry(run.trackId),
        hasLength(1),
        reason: 'the background prepared exactly one cleaned view',
      );
    });

    test('a cancelled load stops with route_map_cancelled', () async {
      final run = await walkStopWalk();
      final maps = run.client as TrackingMapController;
      var checks = 0;
      await expectLater(
        maps.loadTrackMap(run.trackId, isCancelled: () => ++checks > 2),
        throwsA(
          isA<TrackingException>().having(
            (error) => error.code,
            'code',
            'route_map_cancelled',
          ),
        ),
      );
    });

    test('a route outside the owner scope is refused', () async {
      final run = await walkStopWalk();
      final maps = run.client as TrackingMapController;
      await expectLater(
        maps.loadTrackMap('someone-elses-route'),
        throwsA(
          isA<TrackingOwnershipException>().having(
            (error) => error.code,
            'code',
            'owner_scope_conflict',
          ),
        ),
      );
    });
  });

  group('RouteMapReader', () {
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    late StatementLog log;
    late RepositoryHarness harness;

    setUp(() async {
      log = StatementLog();
      harness = RepositoryHarness(databaseFactory: log.factory());
      await harness.initialize();
    });

    tearDown(() => harness.repository.close());

    Future<String> record(String trackId, int count, {int from = 0}) async {
      for (var i = from; i < from + count; i++) {
        await harness.append(
          trackId: trackId,
          latitude: 27 + i * 0.0001,
          longitude: 85 + (i.isEven ? 0.00002 : -0.00002),
          capturedAt: harness.now.add(Duration(seconds: 5 * i)),
        );
      }
      return trackId;
    }

    Future<RouteMapRead> read(
      String trackId, {
      RouteGeometryView? view,
    }) =>
        RouteMapReader(harness.repository, now: () => harness.now).loadTrack(
          owner: owner,
          trackId: trackId,
          view: view,
          continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
          checkpoint: () {},
        );

    test('a long route reads in bounded statements and writes nothing',
        () async {
      final trackId = await harness.createActiveTrack(trackId: 'long');
      await record(trackId, 2500);
      await harness.repository.completeTrack(trackId, reason: 'done');
      await DerivedGeometryService(harness.repository).derive(
        owner: owner,
        trackId: trackId,
        request: const DerivedGeometryRequest(
          algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
        ),
      );

      log.clear();
      final map = (await read(trackId)).map;
      expect(log.writes, isEmpty);
      expect(log.maxArguments, lessThanOrEqualTo(10));
      expect(
        log.statements.length,
        lessThan(20),
        reason: 'pages of 1,000 points, not a statement per point',
      );
      expect(map.view, RouteGeometryView.cleaned);
      expect(map.preparing, isFalse);
      expect(
        map.geometry.parts.expand((part) => part.points),
        hasLength(2500),
      );
    });

    test('a recording route draws its uncleaned tail as recorded', () async {
      final trackId = await harness.createActiveTrack(trackId: 'live');
      await record(trackId, 120);
      final run = await DerivedGeometryService(harness.repository).derive(
        owner: owner,
        trackId: trackId,
        request: const DerivedGeometryRequest(
          algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
        ),
      );
      await record(trackId, 40, from: 120);

      final read1 = await read(trackId, view: RouteGeometryView.cleaned);
      final points = read1.map.geometry.parts.expand((part) => part.points);
      expect(points, hasLength(160));
      final derived =
          await harness.repository.derivedCoordinatesForSourcePoints(
        owner: owner,
        trackId: trackId,
        runId: run.id,
        sourcePointIds: points
            .where((point) => point.sequence <= run.sourceMaximumSequence)
            .map((point) => point.id),
      );
      for (final point in points) {
        final cleaned = derived[point.id];
        if (cleaned != null) {
          expect((point.latitude, point.longitude),
              (cleaned.latitude, cleaned.longitude));
        } else {
          expect(point.sequence, greaterThan(run.sourceMaximumSequence));
          expect(point.latitude, 27 + (point.sequence - 1) * 0.0001);
        }
      }
      expect(read1.map.preparing, isFalse,
          reason: 'a recording route is not waiting for anything');
      expect(read1.prepare, isEmpty,
          reason: 'fewer than 300 new points: no live refresh yet');
    });
  });

  test('compacting a long clean route clears its readings in chunks', () async {
    final directory = await Directory.systemTemp.createTemp('fbl-compact-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/route.sqlite';
    final log = StatementLog();
    final harness =
        RepositoryHarness(path: path, databaseFactory: log.factory());
    await harness.initialize();
    addTearDown(() => harness.repository.close());
    harness.repository.newRouteRecordingDetail = RouteRecordingDetail.clean;
    final trackId = await harness.createActiveTrack(trackId: 'clean-long');
    for (var i = 0; i < 2500; i++) {
      await harness.append(
        trackId: trackId,
        latitude: 27 + i * 0.0001,
        longitude: 85,
        capturedAt: harness.now.add(Duration(seconds: 5 * i)),
      );
    }
    await harness.repository.completeTrack(trackId, reason: 'done');
    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await raw.rawUpdate(
      "UPDATE track_points SET activity_readings_json = '[]' WHERE track_id = ?",
      <Object?>[trackId],
    );

    log.clear();
    expect(
      await harness.repository.compactCleanRoutes(
        owner: const TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
      ),
      1,
    );
    final clearing = log.statements
        .where((statement) =>
            statement.$1.contains('SET activity_readings_json = NULL'))
        .length;
    expect(clearing, greaterThanOrEqualTo(3),
        reason: 'three 1,000-fix chunks, then the claiming transaction');
    expect(
      await raw.rawQuery(
        'SELECT id FROM track_points WHERE activity_readings_json IS NOT NULL',
      ),
      isEmpty,
    );
    expect(
      (await raw.rawQuery('SELECT COUNT(*) AS n FROM track_points'))
          .single['n'],
      2500,
      reason: 'compaction never deletes points',
    );
    await raw.close();
  });
}
