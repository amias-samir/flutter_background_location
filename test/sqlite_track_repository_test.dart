import 'dart:io';

import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/export_models.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/track.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/track_query.dart';
import 'package:flutter_background_location_tracker/src/domain/track_segment.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/trip.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_error.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_configuration_epoch.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_privacy.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_start.dart';
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

  test('schema 10 upgrades to current tables without changing route data',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fbl-v10-v11-');
    final databasePath = '${directory.path}/route.sqlite';
    final original = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await original.initialize();
    final trackId = await original.createTrack(
      userId: 'user',
      organizationId: 'org',
      routeId: 'preserved',
      config: const TrackingConfig(),
      requestedTrackId: 'preserved-track',
    );
    await original.markTrackActive(trackId);
    await original.completeTrack(trackId, reason: 'done');
    await original.close();

    final downgraded = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await downgraded.execute('DROP TABLE derived_geometry_points');
    await downgraded.execute('DROP TABLE derived_geometry_runs');
    await downgraded.setVersion(10);
    await downgraded.close();

    final migrated = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await migrated.initialize();
    expect((await migrated.getTrack(trackId))?.routeId, 'preserved');
    await migrated.close();
    final inspected = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(await inspected.getVersion(), 14);
    final tables = await inspected.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    expect(
      tables.map((row) => row['name']),
      containsAll(<String>[
        'derived_geometry_runs',
        'derived_geometry_points',
      ]),
    );
    await inspected.close();
    await directory.delete(recursive: true);
  });

  test('schema 14 repairs route distance from accepted segment geometry',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fbl-v13-v14-');
    final databasePath = '${directory.path}/route.sqlite';
    final original = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await original.initialize();
    final trackId = await original.createTrack(
      userId: 'distance-user',
      organizationId: 'distance-org',
      routeId: 'distance-repair',
      config: const TrackingConfig(),
      requestedTrackId: 'distance-track',
    );
    await original.markTrackActive(trackId);
    for (final (sequence, longitude) in <(int, double)>[
      (1, 0),
      (2, 0.005),
      (3, 0.01),
    ]) {
      final capturedAt = DateTime.utc(2026, 9, 4, 8, 0, sequence);
      await original.appendPoint(
        PointWriteRequest(
          trackId: trackId,
          sample: LocationSample(
            latitude: 0,
            longitude: longitude,
            horizontalAccuracy: 5,
            capturedAt: capturedAt,
            provider: 'migration-test',
          ),
          activity: ActivitySnapshot(
            type: TrackingActivityType.inVehicle,
            confidence: 90,
            recordedAt: capturedAt,
          ),
          motionState: MotionState.moving,
          accepted: true,
          qualityFlags: TrackPointQualityFlag.none,
        ),
      );
    }
    await original.completeTrack(trackId, reason: 'done');
    await original.close();

    final version13 = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await version13.update(
      'track_segments',
      <String, Object?>{'distance_m': 7.0},
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
    await version13.update(
      'tracks',
      <String, Object?>{'total_distance_m': 7.0},
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
    );
    await version13.update(
      'trips',
      <String, Object?>{'measured_distance_m': 7.0},
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
    );
    await version13.setVersion(13);
    await version13.close();

    final migrated = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await migrated.initialize();
    final repaired = (await migrated.getTrack(trackId))!;
    expect(repaired.totalDistanceMeters, moreOrLessEquals(1112, epsilon: 2));
    await migrated.close();

    final inspected = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    expect(await inspected.getVersion(), 14);
    final tripRows = await inspected.query(
      'trips',
      columns: const <String>['measured_distance_m'],
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
    );
    expect(
      (tripRows.single['measured_distance_m']! as num).toDouble(),
      moreOrLessEquals(1112, epsilon: 2),
    );
    await inspected.close();
    await directory.delete(recursive: true);
  });

  test('schema 11 migration backfills one retry-safe implicit Trip per Track',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fbl-v11-v12-');
    final databasePath = '${directory.path}/route.sqlite';
    final original = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await original.initialize();
    final trackId = await original.createTrack(
      userId: 'migration-user',
      organizationId: 'migration-org',
      routeId: 'preserved-route-id',
      config: const TrackingConfig(),
      requestedTrackId: 'preserved-track-id',
    );
    await original.markTrackActive(trackId);
    await original.completeTrack(trackId, reason: 'finished');
    final sourceTrack = (await original.getTrack(trackId))!;
    await original.close();

    final version11 = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    for (final table in <String>[
      'trip_upload_outbox',
      'trip_operations',
      'trip_legs',
      'trips',
      'track_continuity_gaps',
    ]) {
      await version11.execute('DROP TABLE $table');
    }
    await version11.setVersion(11);
    await version11.close();

    Future<void> verifyMigration() async {
      final migrated = SqliteTrackRepository(
        path: databasePath,
        databaseFactoryOverride: databaseFactoryFfi,
        singleInstance: false,
      );
      await migrated.initialize();
      const owner = TrackingOwner(
        userId: 'migration-user',
        organizationId: 'migration-org',
      );
      final bundle = await migrated.loadTripBundleForOwner(owner, trackId);
      expect(bundle.trip.id, trackId);
      expect(bundle.trip.routeId, sourceTrack.routeId);
      expect(bundle.trip.status, TripStatus.completed);
      expect(bundle.trip.acceptedPointCount, sourceTrack.acceptedPointCount);
      expect(bundle.trip.rejectedPointCount, sourceTrack.rejectedPointCount);
      expect(
          bundle.trip.measuredDistanceMeters, sourceTrack.totalDistanceMeters);
      expect(bundle.legs, hasLength(1));
      expect(bundle.legs.single.trackId, trackId);
      expect((await migrated.getTrack(trackId))?.routeId, sourceTrack.routeId);
      await migrated.close();
    }

    await verifyMigration();
    await verifyMigration();
    await directory.delete(recursive: true);
  });

  test('persists a distinct opaque native session-control token per track',
      () async {
    final first = await harness.createActiveTrack(trackId: 'control-one');
    final firstTrack = (await harness.repository.getTrack(first))!;
    expect(firstTrack.sessionControlToken, isNotNull);
    expect(firstTrack.sessionControlToken, isNotEmpty);
    expect(firstTrack.sessionControlToken, isNot(firstTrack.id));

    await harness.repository.completeTrack(first, reason: 'finished');
    final second = await harness.createActiveTrack(trackId: 'control-two');
    final secondTrack = (await harness.repository.getTrack(second))!;
    expect(secondTrack.sessionControlToken, isNotEmpty);
    expect(
        secondTrack.sessionControlToken, isNot(firstTrack.sessionControlToken));
  });

  test('Q1-01 preserves native receipt and monotonic policy evidence',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'timing-evidence');
    final capturedAt = DateTime.utc(2026, 7, 20, 8);
    final receivedAt = capturedAt.add(const Duration(milliseconds: 240));
    final point = await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
      capturedAt: capturedAt,
      nativeReceivedAt: receivedAt,
      providerTimeDeltaMsAtReceipt: 240,
      monotonicFixNanos: 1000000,
      monotonicReceivedNanos: 1240000,
      monotonicDomainId: 'test-process-clock',
    );

    expect(point.nativeReceivedAt, receivedAt);
    expect(point.providerTimeDeltaMsAtReceipt, 240);
    expect(point.monotonicFixNanos, 1000000);
    expect(point.monotonicReceivedNanos, 1240000);
    expect(point.monotonicDomainId, 'test-process-clock');
    expect(point.qualityPolicyVersion, greaterThan(0));
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

  test('S1-02 managed export inventory is owner-scoped and two-phase',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'managed-export');
    await harness.repository.completeTrack(trackId, reason: 'finished');
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    const foreignOwner = TrackingOwner(
      userId: 'user-2',
      organizationId: 'org-1',
    );

    final abortedId = await harness.repository.beginManagedExport(
      owner: owner,
      trackId: trackId,
      format: TrackExportFormat.gpx,
    );
    expect(
      (await harness.repository.getManagedExport(
        owner: owner,
        exportId: abortedId,
      ))
          ?.state,
      ManagedExportState.pending,
    );
    expect(
      await harness.repository.getManagedExport(
        owner: foreignOwner,
        exportId: abortedId,
      ),
      isNull,
    );
    await harness.repository.abortManagedExport(
      owner: owner,
      exportId: abortedId,
    );
    expect(
      await harness.repository.getManagedExport(
        owner: owner,
        exportId: abortedId,
      ),
      isNull,
    );

    final committedId = await harness.repository.beginManagedExport(
      owner: owner,
      trackId: trackId,
      format: TrackExportFormat.geoJson,
    );
    final destination = TrackExportDestination(
      displayName: 'route.geojson',
      mimeType: 'application/geo+json',
      contentUri: Uri.parse('content://media/external/downloads/42'),
      displayPath: 'Download/flutter_background_location/route.geojson',
      userVisible: true,
    );
    await expectLater(
      harness.repository.commitManagedExport(
        owner: foreignOwner,
        exportId: committedId,
        destination: destination,
      ),
      throwsA(isA<TrackingOwnershipException>()),
    );
    await harness.repository.commitManagedExport(
      owner: owner,
      exportId: committedId,
      destination: destination,
    );
    final committed = await harness.repository.getManagedExport(
      owner: owner,
      exportId: committedId,
    );
    expect(committed?.state, ManagedExportState.committed);
    expect(committed?.destination?.contentUri, destination.contentUri);
    expect(committed?.destination?.localFilePath, isNull);
  });

  test('P1-01 abort retains a cancelled audit route and durable operation',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'abort-route');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.repository.enqueueTrackCompletion(trackId);
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    final operation = await harness.repository.beginPrivacyOperation(
      owner: owner,
      trackId: trackId,
      operationType: TrackPrivacyOperationTypes.abort,
      operationId: 'abort-operation',
    );
    await harness.repository.abortTrackForOwner(
      owner: owner,
      trackId: trackId,
      reason: 'user_cancelled',
      operationId: operation.id,
    );
    await harness.repository.abortTrackForOwner(
      owner: owner,
      trackId: trackId,
      reason: 'duplicate_retry',
      operationId: operation.id,
    );

    final track = await harness.repository.getTrack(trackId);
    expect(track?.status, TrackStatus.failed);
    expect(track?.terminalReasonCode, 'cancelled_by_host');
    expect(track?.completionReason, 'user_cancelled');
    expect(
      await harness.repository.getUploadOutboxEntry(
        trackId,
        UploadOutboxKind.completion,
      ),
      isNull,
    );
    final persisted =
        await harness.repository.getPrivacyOperation(operation.id);
    expect(persisted?.stage, TrackPrivacyOperationStages.completed);
    expect(persisted?.status, 'completed');
    expect(persisted?.terminalReasonCode, 'cancelled_by_host');
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

  test('E1-OWN scoped lookup, stream, and retention never cross owners',
      () async {
    const firstOwner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    const secondOwner = TrackingOwner(
      userId: 'user-2',
      organizationId: 'org-2',
    );
    final first = await harness.createActiveTrack(trackId: 'owner-one');
    await harness.repository.pauseTrack(first, reason: 'later');
    final second = await harness.repository.createTrack(
      userId: secondOwner.userId,
      organizationId: secondOwner.organizationId,
      config: harness.config,
      requestedTrackId: 'owner-two',
    );
    await harness.repository.markTrackActive(second);

    expect(
      (await harness.repository.findLatestPausedTrackForOwner(firstOwner))?.id,
      first,
    );
    expect(
      await harness.repository.findLatestPausedTrackForOwner(secondOwner),
      isNull,
    );
    expect(
      (await harness.repository.findActiveTrackForOwner(secondOwner))?.id,
      second,
    );
    expect(
      await harness.repository.getTrackForOwner(secondOwner, first),
      isNull,
    );
    expect(
      (await harness.repository.watchCurrentTrackForOwner(firstOwner).first)
          ?.id,
      first,
    );

    await harness.repository.completeTrack(second, reason: 'finished');
    await harness.repository.deleteTracksExceptForOwner(
      secondOwner,
      const <String>{},
    );
    expect(await harness.repository.getTrack(second), isNull);
    expect(await harness.repository.getTrack(first), isNotNull);
  });

  test('listTrackPage returns deterministic bounded summary pages', () async {
    Future<String> completedTrack(String id, int minute) async {
      harness.now = DateTime.utc(2026, 7, 20, 8, minute);
      final trackId = await harness.repository.createTrack(
        userId: minute.isEven ? 'user-1' : 'user-2',
        organizationId: 'org-1',
        routeId: minute.isEven ? 'north' : 'south',
        config: harness.config,
        requestedTrackId: id,
      );
      await harness.repository.markTrackActive(trackId);
      await harness.repository.completeTrack(trackId, reason: 'finished');
      return trackId;
    }

    final first = await completedTrack('first', 0);
    final second = await completedTrack('second', 1);
    final third = await completedTrack('third', 2);

    final page = await harness.repository.listTrackPage(
      TrackQuery(statuses: <TrackStatus>[TrackStatus.completed], limit: 2),
    );
    expect(page.items.map((track) => track.id), <String>[third, second]);
    expect(page.hasMore, isTrue);
    expect(page.nextCursor, isNotNull);
    expect(() => page.items.add((page.items.first)), throwsUnsupportedError);

    final nextPage = await harness.repository.listTrackPage(
      TrackQuery(
        statuses: <TrackStatus>[TrackStatus.completed],
        limit: 2,
        cursor: page.nextCursor,
      ),
    );
    expect(nextPage.items.map((track) => track.id), <String>[first]);
    expect(nextPage.hasMore, isFalse);
    expect(nextPage.nextCursor, isNull);

    final filtered = await harness.repository.listTrackPage(
      TrackQuery(routeId: 'north', userId: 'user-1', limit: 10),
    );
    expect(filtered.items.map((track) => track.id), <String>[third, first]);

    await expectLater(
      harness.repository.listTrackPage(TrackQuery(limit: 0)),
      throwsArgumentError,
    );
  });

  test('D1-01 pages segments and points in stable owner-scoped order',
      () async {
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    final trackId = await harness.createActiveTrack(trackId: 'paged-route');
    final first = await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    final rejected = await harness.append(
      trackId: trackId,
      latitude: 27.71,
      longitude: 85.31,
      accepted: false,
      qualityFlags: TrackPointQualityFlag.poorAccuracy,
      rejectionReason: 'poor_accuracy',
    );
    await harness.repository.pauseTrack(trackId, reason: 'break');
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    final third = await harness.append(
      trackId: trackId,
      latitude: 27.72,
      longitude: 85.32,
    );

    final firstSegments = await harness.repository.listSegmentPage(
      owner: owner,
      trackId: trackId,
      limit: 1,
    );
    expect(firstSegments.items.single.segmentNumber, 1);
    expect(firstSegments.snapshotUpperSegmentNumber, 2);
    expect(firstSegments.hasMore, isTrue);
    expect(firstSegments.estimatedDecodedBytes, lessThanOrEqualTo(1024 * 1024));
    expect(() => firstSegments.items.clear(), throwsUnsupportedError);

    final secondSegments = await harness.repository.listSegmentPage(
      owner: owner,
      trackId: trackId,
      limit: 1,
      cursor: firstSegments.nextCursor,
    );
    expect(secondSegments.items.single.segmentNumber, 2);
    expect(secondSegments.hasMore, isFalse);

    final firstPoints = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 2,
    );
    expect(
      firstPoints.items.map((point) => point.sequence),
      <int>[first.sequence, rejected.sequence],
    );
    expect(firstPoints.items.last.accepted, isFalse);
    expect(firstPoints.items.last.qualityFlags,
        TrackPointQualityFlag.poorAccuracy);
    expect(firstPoints.snapshotUpperSequence, third.sequence);
    expect(firstPoints.hasMore, isTrue);

    final secondPoints = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 2,
      cursor: firstPoints.nextCursor,
    );
    expect(
      secondPoints.items.map((point) => point.sequence),
      <int>[third.sequence],
    );
    expect(secondPoints.hasMore, isFalse);

    final accepted = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 10,
      acceptedOnly: true,
    );
    expect(
      accepted.items.map((point) => point.sequence),
      <int>[first.sequence, third.sequence],
    );
  });

  test('D1-01 snapshot cursor excludes concurrent appends', () async {
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    final trackId = await harness.createActiveTrack(trackId: 'snapshot-route');
    for (var index = 0; index < 3; index += 1) {
      await harness.append(
        trackId: trackId,
        latitude: 27.7 + index / 1000,
        longitude: 85.3,
      );
    }

    final firstPage = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 2,
    );
    final fixedSnapshot = await harness.repository.createTrackDataSnapshot(
      owner: owner,
      trackId: trackId,
    );
    final appended = await harness.append(
      trackId: trackId,
      latitude: 27.8,
      longitude: 85.4,
    );
    final snapshotTail = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 2,
      cursor: firstPage.nextCursor,
    );
    expect(snapshotTail.items.map((point) => point.sequence), <int>[3]);
    expect(snapshotTail.snapshotUpperSequence, 3);

    final independentSnapshotRead = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 10,
      snapshot: fixedSnapshot,
    );
    expect(
      independentSnapshotRead.items.map((point) => point.sequence),
      <int>[1, 2, 3],
    );

    final fresh = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 10,
    );
    expect(fresh.items.last.sequence, appended.sequence);
    expect(fresh.snapshotUpperSequence, appended.sequence);
  });

  test('D1-01 rejects cross-owner and mismatched cursor reads', () async {
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    final trackId = await harness.createActiveTrack(trackId: 'scoped-route');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.append(
      trackId: trackId,
      latitude: 27.71,
      longitude: 85.31,
    );
    await expectLater(
      harness.repository.listPointPage(
        owner: const TrackingOwner(
          userId: 'different-user',
          organizationId: 'org-1',
        ),
        trackId: trackId,
        limit: 10,
      ),
      throwsA(
        isA<TrackingOwnershipException>().having(
          (error) => error.code,
          'code',
          'track_not_found_in_owner_scope',
        ),
      ),
    );

    final page = await harness.repository.listPointPage(
      owner: owner,
      trackId: trackId,
      limit: 1,
      acceptedOnly: false,
    );
    await expectLater(
      harness.repository.listPointPage(
        owner: owner,
        trackId: trackId,
        limit: 1,
        cursor: page.nextCursor,
        acceptedOnly: true,
      ),
      throwsA(
        isA<TrackingStorageException>().having(
          (error) => error.code,
          'code',
          'invalid_page_cursor',
        ),
      ),
    );
  });

  test('D1-01 legacy bundle materialization has a typed safety ceiling',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-bundle-cap-');
    final repository = SqliteTrackRepository(
      path: '${directory.path}/tracks.sqlite',
      databaseFactoryOverride: databaseFactoryFfi,
      maximumPageDecodedBytes: 1024,
      maximumLegacyBundlePoints: 1,
      singleInstance: false,
    );
    await repository.initialize();
    addTearDown(() async {
      await repository.close();
      await directory.delete(recursive: true);
    });
    final trackId = await repository.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: harness.config,
      requestedTrackId: 'bundle-cap-route',
    );
    await repository.markTrackActive(trackId);
    for (var index = 0; index < 3; index += 1) {
      await repository.appendPoint(
        PointWriteRequest(
          trackId: trackId,
          sample: LocationSample(
            latitude: 27.7 + index / 1000,
            longitude: 85.3,
            capturedAt: harness.now.add(Duration(seconds: index)),
          ),
          activity: const ActivitySnapshot.unknown(),
          motionState: MotionState.unknown,
          accepted: true,
          qualityFlags: TrackPointQualityFlag.none,
        ),
      );
    }

    await expectLater(
      repository.loadTrackBundle(trackId),
      throwsA(
        isA<TrackingStorageException>().having(
          (error) => error.code,
          'code',
          'legacy_bundle_limit_exceeded',
        ),
      ),
    );

    final boundedPage = await repository.listPointPage(
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      trackId: trackId,
      limit: 3,
    );
    expect(boundedPage.items, isNotEmpty);
    expect(boundedPage.items.length, lessThan(3));
    expect(boundedPage.estimatedDecodedBytes, lessThanOrEqualTo(1024));
    expect(boundedPage.hasMore, isTrue);
    expect(boundedPage.nextCursor, isNotNull);
  });

  test('D1-02 assigns every new point to a resolvable immutable epoch',
      () async {
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    final trackId = await harness.createActiveTrack(trackId: 'epoch-route');
    final point = await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );

    expect(point.configurationEpochId, isNotNull);
    final epoch = await harness.repository.getConfigurationEpoch(
      owner: owner,
      trackId: trackId,
      epochId: point.configurationEpochId!,
    );
    expect(epoch, isNotNull);
    expect(epoch!.trackId, trackId);
    expect(epoch.epochNumber, 1);
    expect(epoch.activationSequence, 1);
    expect(epoch.resolvedConfig.toMap(), harness.config.toMap());
    expect(epoch.presetDefinitionVersion, 4);
    expect(epoch.qualityPolicyVersion, 1);

    await expectLater(
      harness.repository.getConfigurationEpoch(
        owner: const TrackingOwner(
          userId: 'foreign-user',
          organizationId: 'org-1',
        ),
        trackId: trackId,
        epochId: point.configurationEpochId!,
      ),
      throwsA(isA<TrackingOwnershipException>()),
    );
  });

  test('B1-03 activates a new immutable epoch at the next point sequence',
      () async {
    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    final trackId = await harness.createActiveTrack(trackId: 'epoch-update');
    final first = await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    const updatedConfig = TrackingConfig(accuracy: TrackingAccuracy.medium);
    final operation = await harness.repository.beginConfigurationUpdate(
      owner: owner,
      trackId: trackId,
      config: updatedConfig,
    );
    await harness.repository.markConfigurationUpdateStage(
      operationId: operation.id,
      stage: TrackingConfigurationUpdateStage.producerFenced,
    );
    await harness.repository.markConfigurationUpdateStage(
      operationId: operation.id,
      stage: TrackingConfigurationUpdateStage.nativeApplied,
    );
    final epoch = await harness.repository.activateConfigurationUpdate(
      operationId: operation.id,
    );
    harness.now = harness.now.add(const Duration(seconds: 10));
    final second = await harness.append(
      trackId: trackId,
      latitude: 27.701,
      longitude: 85.301,
    );

    expect(first.configurationEpochId, isNot(epoch.id));
    expect(epoch.activationSequence, 2);
    expect(second.configurationEpochId, epoch.id);
    expect((await harness.repository.getTrack(trackId))!.config.accuracy,
        TrackingAccuracy.medium);
    expect(await harness.repository.pendingConfigurationUpdates(), isEmpty);
  });

  test('D1-02 database trigger rejects mutation of an activated epoch',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-epoch-lock-');
    final databasePath = '${directory.path}/tracks.sqlite';
    final repository = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
    );
    await repository.initialize();
    final trackId = await repository.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: harness.config,
      requestedTrackId: 'immutable-epoch-route',
    );
    await repository.close();

    final database = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await expectLater(
      database.rawUpdate(
        '''
        UPDATE tracking_configuration_epochs
        SET quality_policy_version = 99
        WHERE track_id = ?
        ''',
        <Object?>[trackId],
      ),
      throwsA(isA<DatabaseException>()),
    );
    final rows = await database.query(
      'tracking_configuration_epochs',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
    await database.close();
    await directory.delete(recursive: true);

    expect(rows, hasLength(1));
    expect(rows.single['quality_policy_version'], 1);
  });

  test('deleteTrack removes the selected terminal track and child rows',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'delete-me');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    await harness.repository.deleteTrack(trackId);

    expect(await harness.repository.getTrack(trackId), isNull);
    expect(await harness.repository.listTracks(), isEmpty);
    await expectLater(
      harness.repository.loadTrackBundle(trackId),
      throwsStateError,
    );
  });

  test('deleteTrack rejects a route that can still be resumed', () async {
    final trackId = await harness.createActiveTrack(trackId: 'keep-paused');
    await harness.repository.pauseTrack(trackId, reason: 'later');

    await expectLater(
      harness.repository.deleteTrack(trackId),
      throwsStateError,
    );

    expect((await harness.repository.getTrack(trackId))!.status,
        TrackStatus.paused);
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

  test('migrates a legacy version 1 database to the current schema', () async {
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
              paused_at TEXT,
              configuration_json TEXT
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
    final trackColumns = await inspected.rawQuery('PRAGMA table_info(tracks)');
    await inspected.close();
    await directory.delete(recursive: true);

    expect(version, 14);
    expect(
      tables.map((row) => row['name']),
      containsAll(<String>[
        'pending_tracking_commands',
        'upload_outbox',
        'tracking_configuration_epochs',
        'managed_exports',
        'track_privacy_operations',
        'derived_geometry_runs',
        'derived_geometry_points',
      ]),
    );
    expect(columns.map((row) => row['name']), contains('native_event_id'));
    expect(
      columns.map((row) => row['name']),
      contains('configuration_epoch_id'),
    );
    expect(trackColumns.map((row) => row['name']), contains('route_id'));
    expect(
      trackColumns.map((row) => row['name']),
      contains('terminal_reason_code'),
    );
    expect(
      trackColumns.map((row) => row['name']),
      contains('session_control_token'),
    );
    expect(
      columns.map((row) => row['name']),
      containsAll(<String>[
        'native_received_at',
        'provider_time_delta_ms_at_receipt',
        'monotonic_fix_nanos',
        'monotonic_received_nanos',
        'monotonic_domain_id',
        'quality_policy_version',
      ]),
    );
  });

  test('D1-01 migrates version 3 data and installs streaming indexes',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-d1-migrate-');
    final databasePath = '${directory.path}/legacy.sqlite';
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE tracks (
              id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              started_at TEXT NOT NULL,
              paused_at TEXT,
              configuration_json TEXT
            )
          ''');
          await database.execute('''
            CREATE TABLE track_segments (
              id TEXT PRIMARY KEY,
              track_id TEXT NOT NULL,
              segment_number INTEGER NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE track_points (
              id TEXT PRIMARY KEY,
              track_id TEXT NOT NULL,
              segment_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              accepted INTEGER NOT NULL
            )
          ''');
          await database.insert('tracks', <String, Object?>{
            'id': 'preserved-track',
            'status': TrackStatus.completed.name,
            'started_at': DateTime.utc(2026, 7, 20).toIso8601String(),
            'configuration_json': harness.config.toJson(),
          });
          await database.insert('track_segments', <String, Object?>{
            'id': 'preserved-segment',
            'track_id': 'preserved-track',
            'segment_number': 1,
          });
          await database.insert('track_points', <String, Object?>{
            'id': 'preserved-point',
            'track_id': 'preserved-track',
            'segment_id': 'preserved-segment',
            'sequence': 7,
            'accepted': 0,
          });
          await database.insert('tracks', <String, Object?>{
            'id': 'unknown-policy-track',
            'status': TrackStatus.completed.name,
            'started_at': DateTime.utc(2026, 7, 21).toIso8601String(),
            'configuration_json': '{malformed',
          });
          await database.insert('track_segments', <String, Object?>{
            'id': 'unknown-policy-segment',
            'track_id': 'unknown-policy-track',
            'segment_number': 1,
          });
          await database.insert('track_points', <String, Object?>{
            'id': 'unknown-policy-point',
            'track_id': 'unknown-policy-track',
            'segment_id': 'unknown-policy-segment',
            'sequence': 1,
            'accepted': 1,
          });
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
    final rows = await inspected.query('track_points');
    final epochRows = await inspected.query(
      'tracking_configuration_epochs',
      where: 'track_id = ?',
      whereArgs: <Object?>['preserved-track'],
    );
    final pointIndexes = await inspected.rawQuery(
      'PRAGMA index_list(track_points)',
    );
    final segmentIndexes = await inspected.rawQuery(
      'PRAGMA index_list(track_segments)',
    );
    final acceptedPointPlan = await inspected.rawQuery('''
      EXPLAIN QUERY PLAN
      SELECT * FROM track_points
      WHERE track_id = ? AND accepted = 1 AND sequence > ? AND sequence <= ?
      ORDER BY sequence ASC LIMIT 101
      ''', <Object?>['preserved-track', 0, 100]);
    final segmentPlan = await inspected.rawQuery('''
      EXPLAIN QUERY PLAN
      SELECT * FROM track_segments
      WHERE track_id = ? AND segment_number > ? AND segment_number <= ?
      ORDER BY segment_number ASC LIMIT 101
      ''', <Object?>['preserved-track', 0, 100]);
    await inspected.close();
    await directory.delete(recursive: true);

    expect(version, 14);
    final preservedPoint = rows.singleWhere(
      (row) => row['id'] == 'preserved-point',
    );
    final unknownPolicyPoint = rows.singleWhere(
      (row) => row['id'] == 'unknown-policy-point',
    );
    expect(preservedPoint['sequence'], 7);
    expect(preservedPoint['accepted'], 0);
    expect(preservedPoint['configuration_epoch_id'], epochRows.single['id']);
    expect(unknownPolicyPoint['configuration_epoch_id'], isNull);
    expect(epochRows.single['epoch_number'], 1);
    expect(epochRows.single['activation_sequence'], 1);
    expect(
      epochRows.single['resolved_configuration_json'],
      harness.config.toJson(),
    );
    expect(
      pointIndexes.map((row) => row['name']),
      containsAll(<String>[
        'idx_track_points_track_accepted_sequence',
        'idx_track_points_segment_accepted_sequence',
      ]),
    );
    expect(
      segmentIndexes.map((row) => row['name']),
      contains('idx_track_segments_track_number'),
    );
    expect(
      acceptedPointPlan.map((row) => row['detail']).join(' '),
      contains('idx_track_points_track_accepted_sequence'),
    );
    expect(
      segmentPlan.map((row) => row['detail']).join(' '),
      contains('idx_track_segments_track_number'),
    );
  });

  test('D1-02 migrates an interim version 4 route to an initial epoch',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-d1-v4-');
    final databasePath = '${directory.path}/legacy.sqlite';
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE tracks (
              id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              started_at TEXT NOT NULL,
              paused_at TEXT,
              configuration_json TEXT
            )
          ''');
          await database.execute('''
            CREATE TABLE track_points (
              id TEXT PRIMARY KEY,
              track_id TEXT NOT NULL,
              sequence INTEGER NOT NULL,
              accepted INTEGER NOT NULL
            )
          ''');
          await database.insert('tracks', <String, Object?>{
            'id': 'v4-track',
            'status': TrackStatus.completed.name,
            'started_at': DateTime.utc(2026, 7, 22).toIso8601String(),
            'configuration_json': harness.config.toJson(),
          });
          await database.insert('track_points', <String, Object?>{
            'id': 'v4-point',
            'track_id': 'v4-track',
            'sequence': 1,
            'accepted': 1,
          });
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
    final epoch = (await inspected.query(
      'tracking_configuration_epochs',
    ))
        .single;
    final point = (await inspected.query('track_points')).single;
    await inspected.close();
    await directory.delete(recursive: true);

    expect(version, 14);
    expect(epoch['track_id'], 'v4-track');
    expect(point['id'], 'v4-point');
    expect(point['configuration_epoch_id'], epoch['id']);
  });

  test('migrates legacy patrol metadata to route ID', () async {
    final directory = await Directory.systemTemp.createTemp('fbl-route-id-');
    final databasePath = '${directory.path}/legacy.sqlite';
    final legacy = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (database, version) async {
          await database.execute('''
            CREATE TABLE tracks (
              id TEXT PRIMARY KEY,
              status TEXT NOT NULL,
              started_at TEXT NOT NULL,
              paused_at TEXT,
              patrol_id TEXT
            )
          ''');
          await database.insert('tracks', <String, Object?>{
            'id': 'legacy-track',
            'status': TrackStatus.completed.name,
            'started_at': DateTime.utc(2026, 7, 20).toIso8601String(),
            'patrol_id': 'legacy-patrol',
          });
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
    final rows = await inspected.query(
      'tracks',
      columns: <String>['route_id'],
      where: 'id = ?',
      whereArgs: <Object?>['legacy-track'],
    );
    await inspected.close();
    await directory.delete(recursive: true);

    expect(rows.single['route_id'], 'legacy-patrol');
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
