import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/activity_snapshot.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/track_segment.dart';
import '../domain/tracking_config.dart';
import 'track_repository.dart';

/// Configures connection-scoped SQLite behavior used by the track repository.
///
/// This is kept outside [SqliteTrackRepository] so the Android-compatible
/// query path for result-returning PRAGMAs can be regression tested.
Future<void> configureTrackDatabase(Database database) async {
  await database.execute('PRAGMA foreign_keys = ON');
  await database.rawQuery('PRAGMA busy_timeout = 5000');
  await database.rawQuery('PRAGMA journal_mode = WAL');
}

final class SqliteTrackRepository
    implements TrackRepository, UploadOutboxRepository {
  SqliteTrackRepository({
    required this.path,
    DatabaseFactory? databaseFactoryOverride,
    DateTime Function()? clock,
    String Function()? idGenerator,
    bool singleInstance = true,
  })  : _databaseFactory = databaseFactoryOverride ?? databaseFactory,
        _clock = clock ?? _utcNow,
        _idGenerator = idGenerator ?? _newId,
        _singleInstance = singleInstance;

  final String path;
  final DatabaseFactory _databaseFactory;
  final DateTime Function() _clock;
  final String Function() _idGenerator;
  final bool _singleInstance;
  final StreamController<Track?> _currentTrackController =
      StreamController<Track?>.broadcast();
  Track? _currentTrackSnapshot;

  Database? _database;

  static DateTime _utcNow() => DateTime.now().toUtc();
  static String _newId() => const Uuid().v4();

  Database get _db {
    final value = _database;
    if (value == null || !value.isOpen) {
      throw StateError('Track repository is not initialized.');
    }
    return value;
  }

  @override
  Stream<Track?> get currentTrackStream => Stream<Track?>.multi(
        (controller) {
          final subscription = _currentTrackController.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.add(_currentTrackSnapshot);
          controller.onCancel = () {
            unawaited(subscription.cancel());
          };
        },
        isBroadcast: true,
      );

  @override
  Future<void> initialize() async {
    if (_database?.isOpen ?? false) return;
    _database = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        singleInstance: _singleInstance,
        onConfigure: configureTrackDatabase,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    await _emitCurrentTrack();
  }

  static Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        organization_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        patrol_id TEXT,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        paused_at TEXT,
        resumed_at TEXT,
        ended_at TEXT,
        start_lat REAL,
        start_lon REAL,
        end_lat REAL,
        end_lon REAL,
        total_distance_m REAL NOT NULL DEFAULT 0,
        accepted_point_count INTEGER NOT NULL DEFAULT 0,
        rejected_point_count INTEGER NOT NULL DEFAULT 0,
        next_sequence INTEGER NOT NULL DEFAULT 1,
        current_segment_id TEXT,
        segment_count INTEGER NOT NULL DEFAULT 0,
        last_point_at TEXT,
        tracker_provider TEXT NOT NULL,
        configuration_json TEXT NOT NULL,
        completion_reason TEXT,
        sync_state TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE track_segments (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        segment_number INTEGER NOT NULL,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        start_sequence INTEGER,
        end_sequence INTEGER,
        start_point_id TEXT,
        end_point_id TEXT,
        resumed_from_point_id TEXT,
        pause_reason TEXT,
        distance_m REAL NOT NULL DEFAULT 0,
        accepted_point_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        UNIQUE(track_id, segment_number)
      )
    ''');
    await database.execute('''
      CREATE TABLE track_points (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        segment_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        altitude REAL,
        horizontal_accuracy REAL,
        vertical_accuracy REAL,
        speed REAL,
        speed_accuracy REAL,
        heading REAL,
        heading_accuracy REAL,
        captured_at TEXT NOT NULL,
        persisted_at TEXT NOT NULL,
        activity_type TEXT NOT NULL,
        activity_confidence INTEGER NOT NULL,
        motion_state TEXT NOT NULL,
        provider TEXT,
        is_mocked INTEGER NOT NULL,
        mock_detection_available INTEGER NOT NULL,
        mock_assessment TEXT NOT NULL,
        mock_evidence TEXT,
        native_event_id TEXT,
        accepted INTEGER NOT NULL,
        quality_flags INTEGER NOT NULL,
        rejection_reason TEXT,
        sync_state TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_sync_error TEXT,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        FOREIGN KEY(segment_id) REFERENCES track_segments(id) ON DELETE CASCADE,
        UNIQUE(track_id, sequence)
      )
    ''');
    await database.execute('''
      CREATE TABLE tracking_health_events (
        id TEXT PRIMARY KEY,
        track_id TEXT,
        type TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        details_json TEXT,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE tracking_operations (
        track_id TEXT NOT NULL,
        operation_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        completed_at TEXT NOT NULL,
        PRIMARY KEY(track_id, operation_id, operation_type),
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE pending_tracking_commands (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL UNIQUE,
        command_type TEXT NOT NULL,
        reason TEXT NOT NULL,
        operation_id TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX idx_tracks_status ON tracks(status)',
    );
    await database.execute('''
      CREATE INDEX idx_track_segments_track_number
      ON track_segments(track_id, segment_number)
    ''');
    await database.execute('''
      CREATE INDEX idx_track_points_track_sequence
      ON track_points(track_id, sequence)
    ''');
    await database.execute('''
      CREATE INDEX idx_track_points_segment_sequence
      ON track_points(segment_id, sequence)
    ''');
    await database.execute('''
      CREATE INDEX idx_track_points_pending
      ON track_points(sync_state, captured_at)
    ''');
    await database.execute('''
      CREATE UNIQUE INDEX idx_track_points_native_event
      ON track_points(track_id, native_event_id)
      WHERE native_event_id IS NOT NULL
    ''');
    await _createUploadOutboxSchema(database);
  }

  static Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await database.execute('''
        CREATE TABLE IF NOT EXISTS pending_tracking_commands (
          id TEXT PRIMARY KEY,
          track_id TEXT NOT NULL UNIQUE,
          command_type TEXT NOT NULL,
          reason TEXT NOT NULL,
          operation_id TEXT,
          created_at TEXT NOT NULL,
          FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
        )
      ''');
      final pointColumns = await database.rawQuery(
        'PRAGMA table_info(track_points)',
      );
      if (!pointColumns.any((row) => row['name'] == 'native_event_id')) {
        await database.execute(
          'ALTER TABLE track_points ADD COLUMN native_event_id TEXT',
        );
      }
      await database.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_track_points_native_event
        ON track_points(track_id, native_event_id)
        WHERE native_event_id IS NOT NULL
      ''');
      await _createUploadOutboxSchema(database);
    }
  }

  static Future<void> _createUploadOutboxSchema(
    Database database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS upload_outbox (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        first_sequence INTEGER,
        last_sequence INTEGER,
        idempotency_key TEXT NOT NULL UNIQUE,
        state TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at TEXT NOT NULL,
        lease_owner TEXT,
        lease_expires_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        UNIQUE(track_id, kind),
        CHECK(kind IN ('points', 'completion')),
        CHECK(state IN ('pending', 'leased'))
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_upload_outbox_due
      ON upload_outbox(state, next_attempt_at, lease_expires_at)
    ''');
  }

  @override
  Future<String> createTrack({
    required String userId,
    required String organizationId,
    String? patrolId,
    required TrackingConfig config,
    String? requestedTrackId,
  }) async {
    final now = _clock();
    final trackId = requestedTrackId ?? _idGenerator();
    final segmentId = _idGenerator();
    await _db.transaction((transaction) async {
      final existing = await transaction.query(
        'tracks',
        columns: <String>['id'],
        where: 'status IN (?, ?, ?)',
        whereArgs: <Object?>[
          TrackStatus.starting.name,
          TrackStatus.active.name,
          TrackStatus.stopping.name,
        ],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw StateError('Only one track may be active at a time.');
      }
      await transaction.insert('tracks', <String, Object?>{
        'id': trackId,
        'organization_id': organizationId,
        'user_id': userId,
        'patrol_id': patrolId,
        'status': TrackStatus.starting.name,
        'started_at': _timestamp(now),
        'next_sequence': 1,
        'current_segment_id': segmentId,
        'segment_count': 1,
        'tracker_provider': 'native',
        'configuration_json': config.toJson(),
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      await transaction.insert('track_segments', <String, Object?>{
        'id': segmentId,
        'track_id': trackId,
        'segment_number': 1,
        'status': TrackSegmentStatus.starting.name,
        'started_at': _timestamp(now),
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
    });
    await _emitCurrentTrack();
    return trackId;
  }

  @override
  Future<void> markTrackActive(String trackId) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (track.status == TrackStatus.active) return;
      if (track.status != TrackStatus.starting) {
        throw StateError('Cannot activate track in ${track.status.name}.');
      }
      final segmentId = track.currentSegmentId;
      if (segmentId == null) {
        throw StateError('Track has no segment to activate.');
      }
      await transaction.update(
        'track_segments',
        <String, Object?>{
          'status': TrackSegmentStatus.active.name,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[segmentId],
      );
      await transaction.update(
        'tracks',
        <String, Object?>{
          'status': TrackStatus.active.name,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> pauseTrack(
    String trackId, {
    required String reason,
    String? operationId,
  }) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (track.status == TrackStatus.paused) return;
      if (track.status != TrackStatus.active) {
        throw StateError('Cannot pause track in ${track.status.name}.');
      }
      if (await _operationWasApplied(
        transaction,
        trackId,
        operationId,
        TrackOperationType.pause,
      )) {
        return;
      }
      final segmentId = track.currentSegmentId;
      if (segmentId == null) throw StateError('Active track has no segment.');
      await transaction.update(
        'track_segments',
        <String, Object?>{
          'status': TrackSegmentStatus.paused.name,
          'ended_at': _timestamp(now),
          'pause_reason': reason,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[segmentId],
      );
      await transaction.update(
        'tracks',
        <String, Object?>{
          'status': TrackStatus.paused.name,
          'paused_at': _timestamp(now),
          'current_segment_id': null,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
      await _recordOperation(
        transaction,
        trackId,
        operationId,
        TrackOperationType.pause,
        now,
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<Track> prepareResume(String trackId) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (track.status == TrackStatus.active ||
          track.status == TrackStatus.starting) {
        return;
      }
      if (!track.isResumable) {
        throw StateError('Cannot resume track in ${track.status.name}.');
      }
      final otherActive = await transaction.query(
        'tracks',
        columns: <String>['id'],
        where: 'id != ? AND status IN (?, ?, ?)',
        whereArgs: <Object?>[
          trackId,
          TrackStatus.starting.name,
          TrackStatus.active.name,
          TrackStatus.stopping.name,
        ],
        limit: 1,
      );
      if (otherActive.isNotEmpty) {
        throw StateError(
          'Another track is active: ${otherActive.single['id']}.',
        );
      }
      final lastPoint = await _lastAcceptedPoint(transaction, trackId);
      final segmentId = _idGenerator();
      final nextNumber = track.segmentCount + 1;
      await transaction.insert('track_segments', <String, Object?>{
        'id': segmentId,
        'track_id': trackId,
        'segment_number': nextNumber,
        'status': TrackSegmentStatus.starting.name,
        'started_at': _timestamp(now),
        'resumed_from_point_id': lastPoint?.id,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      await transaction.update(
        'tracks',
        <String, Object?>{
          'status': TrackStatus.starting.name,
          'paused_at': null,
          'resumed_at': _timestamp(now),
          'current_segment_id': segmentId,
          'segment_count': nextNumber,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
    });
    await _emitCurrentTrack();
    return (await getTrack(trackId))!;
  }

  @override
  Future<void> completeTrack(
    String trackId, {
    required String reason,
    String? operationId,
  }) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (track.status == TrackStatus.completed) return;
      if (track.status == TrackStatus.failed) {
        throw StateError('A failed track cannot be completed.');
      }
      if (await _operationWasApplied(
        transaction,
        trackId,
        operationId,
        TrackOperationType.complete,
      )) {
        return;
      }
      final segmentId = track.currentSegmentId;
      if (segmentId != null) {
        await transaction.update(
          'track_segments',
          <String, Object?>{
            'status': TrackSegmentStatus.completed.name,
            'ended_at': _timestamp(now),
            'updated_at': _timestamp(now),
          },
          where: 'id = ?',
          whereArgs: <Object?>[segmentId],
        );
      }
      await transaction.update(
        'tracks',
        <String, Object?>{
          'status': TrackStatus.completed.name,
          'ended_at': _timestamp(now),
          'current_segment_id': null,
          'completion_reason': reason,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
      await _recordOperation(
        transaction,
        trackId,
        operationId,
        TrackOperationType.complete,
        now,
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> interruptTrack(String trackId, {required String reason}) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (track.status == TrackStatus.completed ||
          track.status == TrackStatus.paused ||
          track.status == TrackStatus.interrupted) {
        return;
      }
      final segmentId = track.currentSegmentId;
      if (segmentId != null) {
        await transaction.update(
          'track_segments',
          <String, Object?>{
            'status': TrackSegmentStatus.interrupted.name,
            'ended_at': _timestamp(now),
            'pause_reason': reason,
            'updated_at': _timestamp(now),
          },
          where: 'id = ?',
          whereArgs: <Object?>[segmentId],
        );
      }
      await transaction.update(
        'tracks',
        <String, Object?>{
          'status': TrackStatus.interrupted.name,
          'paused_at': _timestamp(now),
          'current_segment_id': null,
          'completion_reason': reason,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<TrackPoint> appendPoint(PointWriteRequest request) async {
    final point = await _db.transaction((transaction) async {
      final nativeEventId = request.sample.eventId;
      if (nativeEventId != null) {
        final existing = await transaction.query(
          'track_points',
          where: 'track_id = ? AND native_event_id = ?',
          whereArgs: <Object?>[request.trackId, nativeEventId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          return TrackPoint.fromDatabase(existing.single);
        }
      }
      // Acquire the SQLite write lock before reading the allocated sequence.
      // This stays safe across multiple database connections without relying on
      // SELECT ... FOR UPDATE, which SQLite does not support.
      final allocated = await transaction.rawUpdate(
        '''
        UPDATE tracks
        SET next_sequence = next_sequence + 1, updated_at = ?
        WHERE id = ? AND status = ? AND current_segment_id IS NOT NULL
        ''',
        <Object?>[
          _timestamp(_clock()),
          request.trackId,
          TrackStatus.active.name,
        ],
      );
      if (allocated != 1) {
        throw StateError('Track is not active: ${request.trackId}');
      }
      final track = await _requiredTrack(transaction, request.trackId);
      final sequence = track.nextSequence - 1;
      final segmentId = track.currentSegmentId!;
      final previous = request.accepted
          ? await _lastAcceptedPoint(
              transaction,
              request.trackId,
              segmentId: segmentId,
            )
          : null;
      final distanceDelta = previous == null
          ? 0.0
          : _distanceMeters(
              previous.latitude,
              previous.longitude,
              request.sample.latitude,
              request.sample.longitude,
            );
      final now = _clock();
      final id = _idGenerator();
      await transaction.insert('track_points', <String, Object?>{
        'id': id,
        'track_id': request.trackId,
        'segment_id': segmentId,
        'sequence': sequence,
        'latitude': request.sample.latitude,
        'longitude': request.sample.longitude,
        'altitude': request.sample.altitude,
        'horizontal_accuracy': request.sample.horizontalAccuracy,
        'vertical_accuracy': request.sample.verticalAccuracy,
        'speed': request.sample.speed,
        'speed_accuracy': request.sample.speedAccuracy,
        'heading': request.sample.heading,
        'heading_accuracy': request.sample.headingAccuracy,
        'captured_at': _timestamp(request.sample.capturedAt),
        'persisted_at': _timestamp(now),
        'activity_type': request.activity.type.value,
        'activity_confidence': request.activity.confidence,
        'motion_state': request.motionState.name,
        'provider': request.sample.provider,
        'is_mocked': request.sample.isMocked ? 1 : 0,
        'mock_detection_available':
            request.sample.mockDetectionAvailable ? 1 : 0,
        'mock_assessment': request.sample.mockAssessment.name,
        'mock_evidence': request.sample.mockEvidence,
        'native_event_id': nativeEventId,
        'accepted': request.accepted ? 1 : 0,
        'quality_flags': request.qualityFlags,
        'rejection_reason': request.rejectionReason,
      });
      if (request.accepted) {
        await transaction.rawUpdate(
          '''
          UPDATE track_segments
          SET start_sequence = COALESCE(start_sequence, ?),
              end_sequence = ?,
              start_point_id = COALESCE(start_point_id, ?),
              end_point_id = ?,
              distance_m = distance_m + ?,
              accepted_point_count = accepted_point_count + 1,
              updated_at = ?
          WHERE id = ?
          ''',
          <Object?>[
            sequence,
            sequence,
            id,
            id,
            distanceDelta,
            _timestamp(now),
            segmentId,
          ],
        );
        await transaction.rawUpdate(
          '''
          UPDATE tracks
          SET start_lat = COALESCE(start_lat, ?),
              start_lon = COALESCE(start_lon, ?),
              end_lat = ?,
              end_lon = ?,
              total_distance_m = total_distance_m + ?,
              accepted_point_count = accepted_point_count + 1,
              last_point_at = ?,
              updated_at = ?
          WHERE id = ?
          ''',
          <Object?>[
            request.sample.latitude,
            request.sample.longitude,
            request.sample.latitude,
            request.sample.longitude,
            distanceDelta,
            _timestamp(request.sample.capturedAt),
            _timestamp(now),
            request.trackId,
          ],
        );
      } else {
        await transaction.rawUpdate(
          '''
          UPDATE tracks
          SET rejected_point_count = rejected_point_count + 1,
              last_point_at = ?,
              updated_at = ?
          WHERE id = ?
          ''',
          <Object?>[
            _timestamp(request.sample.capturedAt),
            _timestamp(now),
            request.trackId,
          ],
        );
      }
      final rows = await transaction.query(
        'track_points',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return TrackPoint.fromDatabase(rows.single);
    });
    await _emitCurrentTrack();
    return point;
  }

  @override
  Future<Track?> getTrack(String trackId) async {
    final rows = await _db.query(
      'tracks',
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromDatabase(rows.single);
  }

  @override
  Future<List<Track>> listTracks() async {
    final rows = await _db.query('tracks', orderBy: 'started_at DESC');
    return rows.map(Track.fromDatabase).toList(growable: false);
  }

  @override
  Future<void> deleteTracksExcept(Set<String> retainedTrackIds) async {
    await _db.transaction((transaction) async {
      if (retainedTrackIds.isEmpty) {
        await transaction.delete('tracks');
        return;
      }
      final placeholders =
          List<String>.filled(retainedTrackIds.length, '?').join(',');
      await transaction.delete(
        'tracks',
        where: 'id NOT IN ($placeholders)',
        whereArgs: retainedTrackIds.toList(growable: false),
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<Track?> findActiveTrack() async {
    final rows = await _db.query(
      'tracks',
      where: 'status IN (?, ?, ?)',
      whereArgs: <Object?>[
        TrackStatus.starting.name,
        TrackStatus.active.name,
        TrackStatus.stopping.name,
      ],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromDatabase(rows.single);
  }

  @override
  Future<Track?> findLatestPausedTrack() async {
    final rows = await _db.query(
      'tracks',
      where: 'status IN (?, ?)',
      whereArgs: <Object?>[
        TrackStatus.paused.name,
        TrackStatus.interrupted.name,
      ],
      orderBy: 'paused_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromDatabase(rows.single);
  }

  @override
  Future<TrackPoint?> findLastAcceptedPoint(
    String trackId, {
    String? segmentId,
  }) =>
      _lastAcceptedPoint(_db, trackId, segmentId: segmentId);

  static Future<TrackPoint?> _lastAcceptedPoint(
    DatabaseExecutor executor,
    String trackId, {
    String? segmentId,
  }) async {
    final rows = await executor.query(
      'track_points',
      where: segmentId == null
          ? 'track_id = ? AND accepted = 1'
          : 'track_id = ? AND segment_id = ? AND accepted = 1',
      whereArgs: segmentId == null
          ? <Object?>[trackId]
          : <Object?>[trackId, segmentId],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : TrackPoint.fromDatabase(rows.single);
  }

  @override
  Future<TrackBundle> loadTrackBundle(String trackId) async {
    return _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      final segmentRows = await transaction.query(
        'track_segments',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
        orderBy: 'segment_number ASC',
      );
      final segments = <TrackSegmentWithPoints>[];
      for (final row in segmentRows) {
        final segment = TrackSegment.fromDatabase(row);
        final pointRows = await transaction.query(
          'track_points',
          where: 'segment_id = ?',
          whereArgs: <Object?>[segment.id],
          orderBy: 'sequence ASC',
        );
        segments.add(
          TrackSegmentWithPoints(
            segment: segment,
            points:
                pointRows.map(TrackPoint.fromDatabase).toList(growable: false),
          ),
        );
      }
      return TrackBundle(track: track, segments: segments);
    });
  }

  @override
  Future<List<TrackPoint>> pendingAcceptedPoints(
    String trackId, {
    required int limit,
  }) async {
    final rows = await _db.query(
      'track_points',
      where: 'track_id = ? AND accepted = 1 AND sync_state = ?',
      whereArgs: <Object?>[trackId, 'pending'],
      orderBy: 'sequence ASC',
      limit: limit,
    );
    return rows.map(TrackPoint.fromDatabase).toList(growable: false);
  }

  @override
  Future<void> markPointsSynced(
    String trackId,
    Iterable<int> sequences,
  ) async {
    final values = sequences.toList(growable: false);
    if (values.isEmpty) return;
    final placeholders = List<String>.filled(values.length, '?').join(',');
    await _db.rawUpdate(
      '''
      UPDATE track_points SET sync_state = 'synced', last_sync_error = NULL
      WHERE track_id = ? AND sequence IN ($placeholders)
      ''',
      <Object?>[trackId, ...values],
    );
  }

  @override
  Future<UploadOutboxLease?> leaseNextUpload({
    required String trackId,
    required String leaseOwner,
    required Duration leaseDuration,
    required int maximumPointCount,
    required int maximumEncodedBytes,
    required UploadBatchEncodedSize encodedSize,
  }) async {
    if (leaseOwner.trim().isEmpty) {
      throw ArgumentError.value(leaseOwner, 'leaseOwner', 'Must not be empty.');
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'Must be positive.',
      );
    }
    if (maximumPointCount <= 0 || maximumEncodedBytes <= 0) {
      throw ArgumentError('Upload batch limits must be positive.');
    }

    final now = _clock().toUtc();
    final leaseExpiresAt = now.add(leaseDuration);
    return _db.transaction((transaction) async {
      await _requiredTrack(transaction, trackId);
      var pointRows = await transaction.query(
        'upload_outbox',
        where: 'track_id = ? AND kind = ?',
        whereArgs: <Object?>[trackId, UploadOutboxKind.points.name],
        limit: 1,
      );
      if (pointRows.isEmpty) {
        final candidateRows = await transaction.query(
          'track_points',
          where: 'track_id = ? AND accepted = 1 AND sync_state = ?',
          whereArgs: <Object?>[trackId, 'pending'],
          orderBy: 'sequence ASC',
          limit: maximumPointCount,
        );
        final candidates =
            candidateRows.map(TrackPoint.fromDatabase).toList(growable: false);
        if (candidates.isNotEmpty) {
          final selected = <TrackPoint>[];
          for (final point in candidates) {
            final candidate = <TrackPoint>[...selected, point];
            if (encodedSize(candidate) > maximumEncodedBytes) {
              if (selected.isEmpty) {
                throw StateError(
                  'A single encoded track point exceeds the '
                  '$maximumEncodedBytes-byte upload limit.',
                );
              }
              break;
            }
            selected.add(point);
          }
          final first = selected.first.sequence;
          final last = selected.last.sequence;
          final timestamp = _timestamp(now);
          await transaction.insert('upload_outbox', <String, Object?>{
            'id': _idGenerator(),
            'track_id': trackId,
            'kind': UploadOutboxKind.points.name,
            'first_sequence': first,
            'last_sequence': last,
            'idempotency_key': '$trackId:$first:$last',
            'state': UploadOutboxState.pending.name,
            'attempt_count': 0,
            'next_attempt_at': timestamp,
            'created_at': timestamp,
            'updated_at': timestamp,
          });
          pointRows = await transaction.query(
            'upload_outbox',
            where: 'track_id = ? AND kind = ?',
            whereArgs: <Object?>[trackId, UploadOutboxKind.points.name],
            limit: 1,
          );
        }
      }

      if (pointRows.isNotEmpty) {
        final entry = _uploadOutboxEntryFromRow(pointRows.single);
        final points = await _pointsForOutbox(transaction, entry);
        if (points.isEmpty) {
          await transaction.delete(
            'upload_outbox',
            where: 'id = ?',
            whereArgs: <Object?>[entry.id],
          );
        } else {
          return _claimUpload(
            transaction,
            entry: entry,
            leaseOwner: leaseOwner,
            now: now,
            leaseExpiresAt: leaseExpiresAt,
            points: points,
          );
        }
      }

      await _enqueueTrackCompletion(transaction, trackId, now);
      final completionRows = await transaction.query(
        'upload_outbox',
        where: 'track_id = ? AND kind = ?',
        whereArgs: <Object?>[trackId, UploadOutboxKind.completion.name],
        limit: 1,
      );
      if (completionRows.isEmpty) return null;
      return _claimUpload(
        transaction,
        entry: _uploadOutboxEntryFromRow(completionRows.single),
        leaseOwner: leaseOwner,
        now: now,
        leaseExpiresAt: leaseExpiresAt,
        points: const <TrackPoint>[],
      );
    });
  }

  static Future<UploadOutboxLease?> _claimUpload(
    DatabaseExecutor executor, {
    required UploadOutboxEntry entry,
    required String leaseOwner,
    required DateTime now,
    required DateTime leaseExpiresAt,
    required List<TrackPoint> points,
  }) async {
    final expired = entry.state == UploadOutboxState.leased &&
        (entry.leaseExpiresAt == null || !entry.leaseExpiresAt!.isAfter(now));
    final due = !entry.nextAttemptAt.isAfter(now);
    if ((!expired && entry.state == UploadOutboxState.leased) || !due) {
      return null;
    }
    final updated = await executor.update(
      'upload_outbox',
      <String, Object?>{
        'state': UploadOutboxState.leased.name,
        'lease_owner': leaseOwner,
        'lease_expires_at': _timestamp(leaseExpiresAt),
        'updated_at': _timestamp(now),
      },
      where: 'id = ?',
      whereArgs: <Object?>[entry.id],
    );
    if (updated != 1) return null;
    final rows = await executor.query(
      'upload_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[entry.id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return UploadOutboxLease(
      entry: _uploadOutboxEntryFromRow(rows.single),
      leaseOwner: leaseOwner,
      points: List<TrackPoint>.unmodifiable(points),
    );
  }

  static Future<List<TrackPoint>> _pointsForOutbox(
    DatabaseExecutor executor,
    UploadOutboxEntry entry,
  ) async {
    final first = entry.firstSequence;
    final last = entry.lastSequence;
    if (first == null || last == null) return const <TrackPoint>[];
    final rows = await executor.query(
      'track_points',
      where: '''
        track_id = ? AND accepted = 1 AND sync_state = 'pending'
        AND sequence >= ? AND sequence <= ?
      ''',
      whereArgs: <Object?>[entry.trackId, first, last],
      orderBy: 'sequence ASC',
    );
    return rows.map(TrackPoint.fromDatabase).toList(growable: false);
  }

  @override
  Future<void> acknowledgePointUpload({
    required String outboxId,
    required String leaseOwner,
    required int acceptedThroughSequence,
    Iterable<int> rejectedSequences = const <int>[],
  }) async {
    await _db.transaction((transaction) async {
      final entry = await _requiredUploadLease(
        transaction,
        outboxId,
        leaseOwner,
        UploadOutboxKind.points,
      );
      final first = entry.firstSequence!;
      final last = entry.lastSequence!;
      final acceptedThrough = math.min(acceptedThroughSequence, last);
      final rejected = rejectedSequences
          .where((sequence) => sequence >= first && sequence <= last)
          .toSet()
          .toList(growable: false);
      if (acceptedThrough < first && rejected.isEmpty) {
        throw StateError('The upload acknowledgement made no progress.');
      }
      if (acceptedThrough >= first) {
        await transaction.rawUpdate(
          '''
          UPDATE track_points
          SET sync_state = 'synced', last_sync_error = NULL
          WHERE track_id = ? AND accepted = 1 AND sync_state = 'pending'
            AND sequence >= ? AND sequence <= ?
          ''',
          <Object?>[entry.trackId, first, acceptedThrough],
        );
      }
      if (rejected.isNotEmpty) {
        final placeholders =
            List<String>.filled(rejected.length, '?').join(',');
        await transaction.rawUpdate(
          '''
          UPDATE track_points
          SET sync_state = 'rejected', last_sync_error = 'server_rejected'
          WHERE track_id = ? AND sequence IN ($placeholders)
          ''',
          <Object?>[entry.trackId, ...rejected],
        );
      }
      await transaction.delete(
        'upload_outbox',
        where: 'id = ? AND lease_owner = ?',
        whereArgs: <Object?>[outboxId, leaseOwner],
      );
    });
  }

  @override
  Future<void> acknowledgeCompletionUpload({
    required String outboxId,
    required String leaseOwner,
  }) async {
    await _db.transaction((transaction) async {
      final entry = await _requiredUploadLease(
        transaction,
        outboxId,
        leaseOwner,
        UploadOutboxKind.completion,
      );
      await transaction.update(
        'tracks',
        <String, Object?>{
          'sync_state': 'synced',
          'updated_at': _timestamp(_clock()),
        },
        where: 'id = ?',
        whereArgs: <Object?>[entry.trackId],
      );
      await transaction.delete(
        'upload_outbox',
        where: 'id = ? AND lease_owner = ?',
        whereArgs: <Object?>[outboxId, leaseOwner],
      );
    });
  }

  @override
  Future<void> failUpload({
    required String outboxId,
    required String leaseOwner,
    required String error,
    required DateTime nextAttemptAt,
  }) async {
    await _db.transaction((transaction) async {
      final entry = await _requiredUploadLease(
        transaction,
        outboxId,
        leaseOwner,
        null,
      );
      final boundedError =
          error.length <= 2048 ? error : error.substring(0, 2048);
      await transaction.update(
        'upload_outbox',
        <String, Object?>{
          'state': UploadOutboxState.pending.name,
          'attempt_count': entry.attemptCount + 1,
          'last_error': boundedError,
          'next_attempt_at': _timestamp(nextAttemptAt),
          'lease_owner': null,
          'lease_expires_at': null,
          'updated_at': _timestamp(_clock()),
        },
        where: 'id = ? AND lease_owner = ?',
        whereArgs: <Object?>[outboxId, leaseOwner],
      );
      if (entry.kind == UploadOutboxKind.points) {
        await transaction.rawUpdate(
          '''
          UPDATE track_points
          SET retry_count = retry_count + 1, last_sync_error = ?
          WHERE track_id = ? AND accepted = 1 AND sync_state = 'pending'
            AND sequence >= ? AND sequence <= ?
          ''',
          <Object?>[
            boundedError,
            entry.trackId,
            entry.firstSequence,
            entry.lastSequence,
          ],
        );
      }
    });
  }

  static Future<UploadOutboxEntry> _requiredUploadLease(
    DatabaseExecutor executor,
    String outboxId,
    String leaseOwner,
    UploadOutboxKind? expectedKind,
  ) async {
    final rows = await executor.query(
      'upload_outbox',
      where: 'id = ? AND state = ? AND lease_owner = ?',
      whereArgs: <Object?>[
        outboxId,
        UploadOutboxState.leased.name,
        leaseOwner,
      ],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('The upload lease is no longer valid.');
    final entry = _uploadOutboxEntryFromRow(rows.single);
    if (expectedKind != null && entry.kind != expectedKind) {
      throw StateError('Unexpected upload outbox task kind.');
    }
    return entry;
  }

  @override
  Future<void> enqueueTrackCompletion(String trackId) async {
    final now = _clock().toUtc();
    await _db.transaction(
      (transaction) => _enqueueTrackCompletion(transaction, trackId, now),
    );
  }

  Future<void> _enqueueTrackCompletion(
    DatabaseExecutor executor,
    String trackId,
    DateTime now,
  ) async {
    final rows = await executor.query(
      'tracks',
      columns: <String>['status', 'sync_state'],
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Unknown track: $trackId');
    final row = rows.single;
    if (row['status'] != TrackStatus.completed.name ||
        row['sync_state'] == 'synced') {
      return;
    }
    final timestamp = _timestamp(now);
    await executor.insert(
      'upload_outbox',
      <String, Object?>{
        'id': _idGenerator(),
        'track_id': trackId,
        'kind': UploadOutboxKind.completion.name,
        'idempotency_key': '$trackId:completion',
        'state': UploadOutboxState.pending.name,
        'attempt_count': 0,
        'next_attempt_at': timestamp,
        'created_at': timestamp,
        'updated_at': timestamp,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  @override
  Future<List<String>> pendingUploadTrackIds() async {
    final rows = await _db.rawQuery('''
      SELECT track_id FROM upload_outbox
      UNION
      SELECT track_id FROM track_points
        WHERE accepted = 1 AND sync_state = 'pending'
      UNION
      SELECT id AS track_id FROM tracks
        WHERE status = 'completed' AND sync_state != 'synced'
      ORDER BY track_id
    ''');
    return rows
        .map((row) => row['track_id']! as String)
        .toList(growable: false);
  }

  @override
  Future<UploadOutboxEntry?> getUploadOutboxEntry(
    String trackId,
    UploadOutboxKind kind,
  ) async {
    final rows = await _db.query(
      'upload_outbox',
      where: 'track_id = ? AND kind = ?',
      whereArgs: <Object?>[trackId, kind.name],
      limit: 1,
    );
    return rows.isEmpty ? null : _uploadOutboxEntryFromRow(rows.single);
  }

  static UploadOutboxEntry _uploadOutboxEntryFromRow(
    Map<String, Object?> row,
  ) {
    DateTime? optionalDate(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return UploadOutboxEntry(
      id: row['id']! as String,
      trackId: row['track_id']! as String,
      kind: UploadOutboxKind.values.byName(row['kind']! as String),
      firstSequence: (row['first_sequence'] as num?)?.toInt(),
      lastSequence: (row['last_sequence'] as num?)?.toInt(),
      idempotencyKey: row['idempotency_key']! as String,
      state: UploadOutboxState.values.byName(row['state']! as String),
      attemptCount: (row['attempt_count']! as num).toInt(),
      lastError: row['last_error'] as String?,
      nextAttemptAt: optionalDate('next_attempt_at')!,
      leaseOwner: row['lease_owner'] as String?,
      leaseExpiresAt: optionalDate('lease_expires_at'),
      createdAt: optionalDate('created_at')!,
      updatedAt: optionalDate('updated_at')!,
    );
  }

  @override
  Future<PendingTrackCommand> beginLifecycleCommand({
    required String trackId,
    required TrackCommandType type,
    required String reason,
    String? operationId,
  }) async {
    final command = await _db.transaction((transaction) async {
      await _requiredTrack(transaction, trackId);
      final existing = await transaction.query(
        'pending_tracking_commands',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final command = _pendingCommandFromRow(existing.single);
        if (command.type != type) {
          throw StateError(
            'Track $trackId already has a pending ${command.type.name} command.',
          );
        }
        return command;
      }
      final now = _clock();
      final id = _idGenerator();
      await transaction.insert(
        'pending_tracking_commands',
        <String, Object?>{
          'id': id,
          'track_id': trackId,
          'command_type': type.name,
          'reason': reason,
          'operation_id': operationId,
          'created_at': _timestamp(now),
        },
      );
      return PendingTrackCommand(
        id: id,
        trackId: trackId,
        type: type,
        reason: reason,
        operationId: operationId,
        createdAt: now,
      );
    });
    return command;
  }

  @override
  Future<PendingTrackCommand?> findPendingLifecycleCommand() async {
    final rows = await _db.query(
      'pending_tracking_commands',
      orderBy: 'created_at ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : _pendingCommandFromRow(rows.single);
  }

  @override
  Future<void> clearPendingLifecycleCommand(String commandId) => _db.delete(
        'pending_tracking_commands',
        where: 'id = ?',
        whereArgs: <Object?>[commandId],
      );

  static PendingTrackCommand _pendingCommandFromRow(
    Map<String, Object?> row,
  ) =>
      PendingTrackCommand(
        id: row['id']! as String,
        trackId: row['track_id']! as String,
        type: TrackCommandType.values.firstWhere(
          (type) => type.name == row['command_type'],
        ),
        reason: row['reason']! as String,
        operationId: row['operation_id'] as String?,
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      );

  @override
  Future<void> recordHealthEvent({
    String? trackId,
    required String type,
    Map<String, Object?>? details,
  }) =>
      _db.insert('tracking_health_events', <String, Object?>{
        'id': _idGenerator(),
        'track_id': trackId,
        'type': type,
        'occurred_at': _timestamp(_clock()),
        'details_json': details == null ? null : jsonEncode(details),
      });

  static Future<Track> _requiredTrack(
    DatabaseExecutor executor,
    String trackId,
  ) async {
    final rows = await executor.query(
      'tracks',
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Unknown track: $trackId');
    return Track.fromDatabase(rows.single);
  }

  @override
  Future<bool> wasOperationApplied(
    String trackId, {
    required String operationId,
    required TrackOperationType type,
  }) =>
      _operationWasApplied(_db, trackId, operationId, type);

  static Future<bool> _operationWasApplied(
    DatabaseExecutor executor,
    String trackId,
    String? operationId,
    TrackOperationType type,
  ) async {
    if (operationId == null) return false;
    final rows = await executor.query(
      'tracking_operations',
      columns: <String>['operation_id'],
      where: 'track_id = ? AND operation_id = ? AND operation_type = ?',
      whereArgs: <Object?>[trackId, operationId, type.name],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<void> _recordOperation(
    DatabaseExecutor executor,
    String trackId,
    String? operationId,
    TrackOperationType operationType,
    DateTime now,
  ) async {
    if (operationId == null) return;
    await executor.insert(
      'tracking_operations',
      <String, Object?>{
        'track_id': trackId,
        'operation_id': operationId,
        'operation_type': operationType.name,
        'completed_at': _timestamp(now),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> _emitCurrentTrack() async {
    if (_currentTrackController.isClosed) return;
    _currentTrackSnapshot =
        await findActiveTrack() ?? await findLatestPausedTrack();
    _currentTrackController.add(_currentTrackSnapshot);
  }

  static String _timestamp(DateTime value) => value.toUtc().toIso8601String();

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const radius = 6371008.8;
    final lat1 = latitude1 * math.pi / 180;
    final lat2 = latitude2 * math.pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * math.pi / 180;
    final deltaLongitude = (longitude2 - longitude1) * math.pi / 180;
    final a = math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLongitude / 2) *
            math.sin(deltaLongitude / 2);
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
    await _currentTrackController.close();
  }
}
