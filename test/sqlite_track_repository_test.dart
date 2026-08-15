import 'dart:io';

import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/track.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/track_segment.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_background_location_tracker/src/storage/track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_support.dart';

void main() {
  late RepositoryHarness harness;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
  });

  tearDown(() => harness.repository.close());

  test('uses query APIs for result-returning connection PRAGMAs', () async {
    final database = _AndroidCompatiblePragmaDatabase();

    await configureTrackDatabase(database);

    expect(database.executedSql, <String>['PRAGMA foreign_keys = ON']);
    expect(
      database.queriedSql,
      <String>[
        'PRAGMA busy_timeout = 5000',
        'PRAGMA journal_mode = WAL',
      ],
    );
  });

  test('persists lifecycle state and makes lifecycle operations idempotent',
      () async {
    final trackId = await harness.repository.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: harness.config,
      requestedTrackId: 'track-lifecycle',
    );

    var bundle = await harness.repository.loadTrackBundle(trackId);
    expect(bundle.track.status, TrackStatus.starting);
    expect(bundle.track.segmentCount, 1);
    expect(bundle.segments.single.segment.status, TrackSegmentStatus.starting);

    await harness.repository.markTrackActive(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.repository.pauseTrack(
      trackId,
      reason: 'overnight',
      operationId: 'pause-1',
    );
    final firstPause = (await harness.repository.getTrack(trackId))!.pausedAt;

    harness.now = harness.now.add(const Duration(hours: 1));
    await harness.repository.pauseTrack(
      trackId,
      reason: 'duplicate',
      operationId: 'pause-1',
    );
    expect((await harness.repository.getTrack(trackId))!.pausedAt, firstPause);

    await harness.repository.prepareResume(trackId);
    await harness.repository.prepareResume(trackId);
    bundle = await harness.repository.loadTrackBundle(trackId);
    expect(bundle.track.status, TrackStatus.starting);
    expect(bundle.segments, hasLength(2));
    expect(bundle.segments.last.segment.status, TrackSegmentStatus.starting);

    await harness.repository.markTrackActive(trackId);
    await harness.repository.completeTrack(
      trackId,
      reason: 'finished',
      operationId: 'complete-1',
    );
    final firstEnd = (await harness.repository.getTrack(trackId))!.endedAt;

    harness.now = harness.now.add(const Duration(hours: 1));
    await harness.repository.completeTrack(
      trackId,
      reason: 'duplicate',
      operationId: 'complete-1',
    );
    bundle = await harness.repository.loadTrackBundle(trackId);
    expect(bundle.track.status, TrackStatus.completed);
    expect(bundle.track.completionReason, 'finished');
    expect(bundle.track.endedAt, firstEnd);
    expect(bundle.segments.last.segment.status, TrackSegmentStatus.completed);
  });

  test('resume cannot create a second active track', () async {
    final paused = await harness.createActiveTrack(trackId: 'paused-track');
    await harness.repository.pauseTrack(paused, reason: 'later');
    final active = await harness.createActiveTrack(trackId: 'active-track');

    await expectLater(
      harness.repository.prepareResume(paused),
      throwsStateError,
    );
    expect((await harness.repository.getTrack(paused))!.status,
        TrackStatus.paused);
    expect((await harness.repository.getTrack(active))!.status,
        TrackStatus.active);
    expect(
      (await harness.repository.loadTrackBundle(paused)).segments,
      hasLength(1),
    );
  });

  test('deleteTracksExcept removes older tracks and cascades child rows',
      () async {
    final removed = await harness.createActiveTrack(trackId: 'removed-track');
    await harness.append(trackId: removed, latitude: 27.7, longitude: 85.3);
    await harness.repository.completeTrack(removed, reason: 'finished');
    final retained = await harness.createActiveTrack(trackId: 'retained-track');
    await harness.append(trackId: retained, latitude: 27.8, longitude: 85.4);

    await harness.repository.deleteTracksExcept(<String>{retained});

    expect(await harness.repository.getTrack(removed), isNull);
    await expectLater(
      harness.repository.loadTrackBundle(removed),
      throwsStateError,
    );
    final retainedBundle = await harness.repository.loadTrackBundle(retained);
    expect(retainedBundle.segments.single.points, hasLength(1));
  });

  test('current track stream replays its latest state to new listeners',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'stream-track');
    expect((await harness.repository.currentTrackStream.first)?.id, trackId);

    await harness.repository.pauseTrack(trackId, reason: 'overnight');
    final replayed = await harness.repository.currentTrackStream.first;
    expect(replayed?.id, trackId);
    expect(replayed?.status, TrackStatus.paused);
  });

  test('allocates unique monotonic sequences for concurrent writes', () async {
    final trackId = await harness.createActiveTrack(trackId: 'track-sequence');

    final points = await Future.wait(
      List<Future<TrackPoint>>.generate(
        25,
        (index) => harness.append(
          trackId: trackId,
          latitude: 27.7 + index / 100000,
          longitude: 85.3 + index / 100000,
          capturedAt: harness.now.add(Duration(seconds: index)),
          accepted: true,
        ),
      ),
    );

    final sequences = points.map((point) => point.sequence).toList()..sort();
    expect(sequences, List<int>.generate(25, (index) => index + 1));
    expect(sequences.toSet(), hasLength(25));

    final track = (await harness.repository.getTrack(trackId))!;
    expect(track.nextSequence, 26);
    expect(track.acceptedPointCount, 25);
  });

  test('preserves sequence allocation across independent SQLite connections',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-connections-');
    final databasePath = '${directory.path}/tracks.sqlite';
    var firstId = 0;
    var secondId = 0;
    final first = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      clock: () => harness.now,
      idGenerator: () => 'first-${firstId++}',
      singleInstance: false,
    );
    final second = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      clock: () => harness.now,
      idGenerator: () => 'second-${secondId++}',
      singleInstance: false,
    );
    await first.initialize();
    await second.initialize();
    addTearDown(() async {
      await first.close();
      await second.close();
      await directory.delete(recursive: true);
    });
    final trackId = await first.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: harness.config,
      requestedTrackId: 'cross-connection',
    );
    await first.markTrackActive(trackId);

    Future<TrackPoint> append(
      SqliteTrackRepository repository,
      int index,
    ) =>
        repository.appendPoint(
          PointWriteRequest(
            trackId: trackId,
            sample: LocationSample(
              latitude: 27.7 + index / 100000,
              longitude: 85.3 + index / 100000,
              capturedAt: harness.now.add(Duration(seconds: index)),
            ),
            activity: const ActivitySnapshot.unknown(),
            motionState: MotionState.unknown,
            accepted: true,
            qualityFlags: TrackPointQualityFlag.none,
          ),
        );

    final points = <TrackPoint>[];
    for (var index = 0; index < 20; index += 1) {
      points.add(await append(index.isEven ? first : second, index));
    }
    final sequences = points.map((point) => point.sequence).toList()..sort();
    expect(sequences, List<int>.generate(20, (index) => index + 1));
    expect((await first.getTrack(trackId))!.nextSequence, 21);
  });

  test('replaying a native event does not duplicate its point', () async {
    final trackId = await harness.createActiveTrack(trackId: 'track-replay');
    final first = await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
      eventId: 'native-event-1',
      sourceTrackId: trackId,
    );
    final replay = await harness.append(
      trackId: trackId,
      latitude: 99,
      longitude: 99,
      eventId: 'native-event-1',
      sourceTrackId: trackId,
    );

    final bundle = await harness.repository.loadTrackBundle(trackId);
    expect(replay.id, first.id);
    expect(replay.sequence, first.sequence);
    expect(bundle.segments.single.points, hasLength(1));
    expect(bundle.track.acceptedPointCount, 1);
    expect(bundle.track.nextSequence, 2);
  });

  test('counts rejected points without using them for route distance',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'track-rejected');
    final first = await harness.append(
      trackId: trackId,
      latitude: 0,
      longitude: 0,
      capturedAt: harness.now,
    );
    await harness.append(
      trackId: trackId,
      latitude: 50,
      longitude: 50,
      capturedAt: harness.now.add(const Duration(seconds: 1)),
      accepted: false,
      qualityFlags: TrackPointQualityFlag.poorAccuracy,
      rejectionReason: 'poor_accuracy',
    );
    final third = await harness.append(
      trackId: trackId,
      latitude: 0,
      longitude: 0.001,
      capturedAt: harness.now.add(const Duration(seconds: 2)),
    );

    final track = (await harness.repository.getTrack(trackId))!;
    expect(<int>[first.sequence, third.sequence], <int>[1, 3]);
    expect(track.acceptedPointCount, 2);
    expect(track.rejectedPointCount, 1);
    expect(track.totalDistanceMeters, moreOrLessEquals(111.2, epsilon: 0.5));

    final pending = await harness.repository.pendingAcceptedPoints(
      trackId,
      limit: 10,
    );
    expect(pending.map((point) => point.sequence), <int>[1, 3]);
  });

  test('resume creates a new segment and never bridges pause-gap distance',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'track-segments');
    await harness.append(
      trackId: trackId,
      latitude: 0,
      longitude: 0,
      capturedAt: harness.now,
    );
    final previousEndpoint = await harness.append(
      trackId: trackId,
      latitude: 0,
      longitude: 0.001,
      capturedAt: harness.now.add(const Duration(seconds: 10)),
    );

    harness.now = harness.now.add(const Duration(hours: 12));
    await harness.repository.pauseTrack(
      trackId,
      reason: 'overnight',
      operationId: 'pause-overnight',
    );
    await expectLater(
      harness.append(
        trackId: trackId,
        latitude: 5,
        longitude: 5,
      ),
      throwsStateError,
    );

    harness.now = harness.now.add(const Duration(hours: 12));
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    final firstResumed = await harness.append(
      trackId: trackId,
      latitude: 10,
      longitude: 10,
      capturedAt: harness.now,
    );
    final secondResumed = await harness.append(
      trackId: trackId,
      latitude: 10,
      longitude: 10.001,
      capturedAt: harness.now.add(const Duration(seconds: 10)),
    );

    final bundle = await harness.repository.loadTrackBundle(trackId);
    expect(bundle.segments, hasLength(2));
    expect(
      bundle.segments.last.segment.resumedFromPointId,
      previousEndpoint.id,
    );
    expect(firstResumed.sequence, 3);
    expect(secondResumed.sequence, 4);
    expect(bundle.segments.first.segment.distanceMeters,
        moreOrLessEquals(111.2, epsilon: 0.5));
    expect(bundle.segments.last.segment.distanceMeters,
        moreOrLessEquals(109.5, epsilon: 0.5));
    expect(
      bundle.track.totalDistanceMeters,
      moreOrLessEquals(
        bundle.segments.fold<double>(
          0,
          (sum, segment) => sum + segment.segment.distanceMeters,
        ),
        epsilon: 0.001,
      ),
    );
    expect(bundle.track.totalDistanceMeters, lessThan(300));
  });

  test('migrates a legacy version 1 database to the durable outbox schema',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-migration-');
    final databasePath = '${directory.path}/legacy.sqlite';
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE tracks (
              id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              started_at TEXT NOT NULL,
              paused_at TEXT
            )
          ''');
          await database.execute('''
            CREATE TABLE track_points (
              id TEXT PRIMARY KEY,
              track_id TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacy.close();

    final migrated = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await migrated.initialize();
    await migrated.close();

    final inspected = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final version = await inspected.getVersion();
    final tables = await inspected.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final columns = await inspected.rawQuery('PRAGMA table_info(track_points)');
    await inspected.close();
    await directory.delete(recursive: true);

    expect(version, 2);
    expect(
      tables.map((row) => row['name']),
      containsAll(<String>['pending_tracking_commands', 'upload_outbox']),
    );
    expect(columns.map((row) => row['name']), contains('native_event_id'));
  });
}

final class _AndroidCompatiblePragmaDatabase implements Database {
  final List<String> executedSql = <String>[];
  final List<String> queriedSql = <String>[];

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    if (sql.contains('busy_timeout') || sql.contains('journal_mode')) {
      throw StateError('Result-returning PRAGMAs require rawQuery on Android.');
    }
    executedSql.add(sql);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    queriedSql.add(sql);
    return const <Map<String, Object?>>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
