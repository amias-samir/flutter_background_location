import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_support.dart';

/// Schema 16: stop records written atomically with the fixes that open,
/// extend and close them.
void main() {
  final t0 = DateTime.utc(2026, 10, 19, 5);

  PointWriteRequest request(
    String trackId,
    int second, {
    required bool accepted,
    double north = 0,
  }) =>
      PointWriteRequest(
        trackId: trackId,
        sample: LocationSample(
          latitude: 0.5 + north / 111195,
          longitude: 0.5,
          capturedAt: t0.add(Duration(seconds: second)),
          horizontalAccuracy: 4,
          provider: 'fused',
          eventId: 'event-$second',
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

  TrackStopOpen open(String? arrivalPointId) => TrackStopOpen(
        kind: TrackStopKind.dwell,
        latitude: 0.5,
        longitude: 0.5,
        centreSigmaMeters: 2.5,
        radiusMeters: 25,
        startedAt: t0.add(const Duration(seconds: 5)),
        qualityPolicyVersion: 3,
        arrivalPointId: arrivalPointId,
        priorEvidenceCount: 3,
      );

  group('stop records', () {
    late RepositoryHarness harness;
    late String trackId;

    setUp(() async {
      harness = RepositoryHarness()..now = t0;
      await harness.initialize();
      trackId = await harness.createActiveTrack(trackId: 'stop-route');
    });

    tearDown(() => harness.repository.close());

    test('open, extend and close travel with their fixes', () async {
      final repository = harness.repository;
      final arrival = await repository.appendPoint(
        request(trackId, 0, accepted: true),
      );
      final opened = await repository.appendPointWithStop(
        request(trackId, 130, accepted: false, north: 3),
        null,
        open(arrival.id),
      );
      expect(opened.stop?.isOpen, isTrue);
      expect(opened.stop?.evidenceCount, 4);
      expect(opened.stop?.arrivalPointId, arrival.id);

      final extended = await repository.appendPointWithStop(
        request(trackId, 400, accepted: false, north: -2),
        null,
        const TrackStopExtend(),
      );
      expect(extended.stop?.evidenceCount, 5);
      expect(extended.stop?.lastSeenAt, t0.add(const Duration(seconds: 400)));

      final departed = await repository.appendPointWithStop(
        request(trackId, 430, accepted: true, north: 60),
        null,
        const TrackStopClose(departure: true),
      );
      final stop = departed.stop!;
      expect(stop.isOpen, isFalse);
      expect(stop.endedAt, t0.add(const Duration(seconds: 430)));
      expect(stop.departurePointId, departed.point.id);
      expect(stop.duration, const Duration(seconds: 425));
      expect(await repository.findOpenTrackStop(trackId), isNull);

      final bundle = await repository.loadTrackBundle(trackId);
      expect(bundle.stops.map((item) => item.id), <String>[stop.id]);
    });

    test('a whole stop is written closed with its departure', () async {
      final repository = harness.repository;
      final arrival = await repository.appendPoint(
        request(trackId, 0, accepted: true),
      );
      final held = await repository.appendPoint(
        request(trackId, 40, accepted: false, north: 2),
      );
      final departed = await repository.appendPointWithStop(
        request(trackId, 400, accepted: true, north: 4),
        null,
        TrackStopRecord(
          kind: TrackStopKind.dwell,
          latitude: 0.5,
          longitude: 0.5,
          centreSigmaMeters: 3,
          radiusMeters: 25,
          startedAt: t0.add(const Duration(seconds: 5)),
          lastSeenAt: held.capturedAt,
          evidenceCount: 1,
          qualityPolicyVersion: 3,
          firstSequence: held.sequence,
          lastSequence: held.sequence,
          arrivalPointId: arrival.id,
        ),
      );
      final stop = departed.stop!;
      expect(stop.isOpen, isFalse);
      expect(stop.endedAt, t0.add(const Duration(seconds: 400)));
      expect(stop.lastSeenAt, held.capturedAt);
      expect(stop.departurePointId, departed.point.id);
      expect(stop.arrivalPointId, arrival.id);
      expect(stop.evidenceCount, 1);
      expect(await repository.findOpenTrackStop(trackId), isNull);
    });

    test('a replayed fix applies its stop change once', () async {
      final repository = harness.repository;
      await repository.appendPoint(request(trackId, 0, accepted: true));
      await repository.appendPointWithStop(
        request(trackId, 130, accepted: false),
        null,
        open(null),
      );
      final replay = await repository.appendPointWithStop(
        request(trackId, 130, accepted: false),
        null,
        open(null),
      );
      expect(replay.duplicate, isTrue);
      final stops = await repository.listTrackStops(trackId);
      expect(stops, hasLength(1));
      expect(stops.single.evidenceCount, 4);
    });

    test('completing the route ends a current stop at its last fix', () async {
      final repository = harness.repository;
      await repository.appendPoint(request(trackId, 0, accepted: true));
      await repository.appendPointWithStop(
        request(trackId, 130, accepted: false),
        null,
        open(null),
      );
      await repository.appendPointWithStop(
        request(trackId, 300, accepted: false),
        null,
        const TrackStopExtend(),
      );
      await repository.completeTrack(trackId, reason: 'done');
      final stop = (await repository.listTrackStops(trackId)).single;
      expect(stop.isOpen, isFalse);
      expect(stop.endedAt, t0.add(const Duration(seconds: 300)));
    });

    test('deleting the route deletes its stops', () async {
      final repository = harness.repository;
      await repository.appendPoint(request(trackId, 0, accepted: true));
      await repository.appendPointWithStop(
        request(trackId, 130, accepted: false),
        null,
        open(null),
      );
      await repository.completeTrack(trackId, reason: 'done');
      await repository.deleteTrack(trackId);
      expect(await repository.listTrackStops(trackId), isEmpty);
    });
  });

  group('schema 16', () {
    late Directory directory;

    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp('fbl-v16-');
    });

    tearDown(() => directory.delete(recursive: true));

    SqliteTrackRepository open(String name) => SqliteTrackRepository(
          path: '${directory.path}/$name.sqlite',
          databaseFactoryOverride: databaseFactoryFfi,
          singleInstance: false,
        );

    Future<Database> openRaw(String name) => databaseFactoryFfi.openDatabase(
          '${directory.path}/$name.sqlite',
          options: OpenDatabaseOptions(singleInstance: false),
        );

    Future<List<String>> stopSchema(String name) async {
      final raw = await openRaw(name);
      final rows = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE tbl_name = 'track_stops' "
        "AND name NOT LIKE 'sqlite_autoindex_%' ORDER BY name",
      );
      await raw.close();
      return rows.map((row) => row['name']! as String).toList();
    }

    test('fresh databases create the stop table and its indexes', () async {
      final repository = open('fresh');
      await repository.initialize();
      await repository.close();
      expect(await stopSchema('fresh'), <String>[
        'idx_track_stops_open',
        'idx_track_stops_track_started',
        'track_stops',
      ]);
      final raw = await openRaw('fresh');
      expect(await raw.getVersion(), 17);
      await raw.close();
    });

    test('upgrading from schema 15 adds the table and keeps routes', () async {
      final original = open('upgraded');
      await original.initialize();
      final trackId = await original.createTrack(
        userId: 'user',
        organizationId: 'org',
        config: const TrackingConfig(),
        requestedTrackId: 'kept-route',
      );
      await original.close();

      final raw = await openRaw('upgraded');
      await raw.execute('DROP TABLE track_stops');
      await raw.setVersion(15);
      await raw.close();

      final upgraded = open('upgraded');
      await upgraded.initialize();
      expect(await upgraded.getTrack(trackId), isNotNull);
      expect(await upgraded.listTrackStops(trackId), isEmpty);
      await upgraded.close();
      expect(await stopSchema('upgraded'), contains('track_stops'));

      // Reopening is idempotent.
      final reopened = open('upgraded');
      await reopened.initialize();
      await reopened.close();
      expect(await stopSchema('upgraded'), contains('idx_track_stops_open'));
    });

    test('a downgraded database regains the table on the next open', () async {
      final repository = open('downgraded');
      await repository.initialize();
      await repository.close();
      final raw = await openRaw('downgraded');
      // An older build keeps the version it knows and never drops the table;
      // a missing table must still come back.
      await raw.execute('DROP TABLE track_stops');
      await raw.setVersion(16);
      await raw.close();
      final reopened = open('downgraded');
      await reopened.initialize();
      await reopened.close();
      expect(await stopSchema('downgraded'), contains('track_stops'));
    });
  });
}
