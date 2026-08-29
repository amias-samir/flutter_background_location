import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/activity_snapshot.dart';
import '../domain/derived_geometry.dart';
import '../domain/export_models.dart';
import '../domain/track.dart';
import '../domain/track_data_page.dart';
import '../domain/track_point.dart';
import '../domain/track_query.dart';
import '../domain/track_segment.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_privacy.dart';
import '../domain/tracking_start.dart';
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
    implements
        TrackRepository,
        UploadOutboxRepository,
        OwnerScopedUploadOutboxRepository,
        PaginatedTrackRepository,
        StreamingTrackRepository,
        ConfigurationEpochRepository,
        MutableConfigurationEpochRepository,
        GapSegmentRepository,
        OwnerScopedTrackRepository,
        PrivacyTrackRepository,
        ManagedExportRepository,
        DerivedGeometryRepository {
  SqliteTrackRepository({
    required this.path,
    DatabaseFactory? databaseFactoryOverride,
    DateTime Function()? clock,
    String Function()? idGenerator,
    String Function()? sessionControlTokenGenerator,
    bool singleInstance = true,
    this.maximumPageDecodedBytes = 1024 * 1024,
    this.maximumLegacyBundlePoints = 100000,
  })  : _databaseFactory = databaseFactoryOverride ?? databaseFactory,
        _clock = clock ?? _utcNow,
        _idGenerator = idGenerator ?? _newId,
        _sessionControlTokenGenerator = sessionControlTokenGenerator ?? _newId,
        _singleInstance = singleInstance {
    if (maximumPageDecodedBytes < 1024) {
      throw ArgumentError.value(
        maximumPageDecodedBytes,
        'maximumPageDecodedBytes',
        'Must be at least 1024 bytes.',
      );
    }
    if (maximumLegacyBundlePoints < 1) {
      throw ArgumentError.value(
        maximumLegacyBundlePoints,
        'maximumLegacyBundlePoints',
        'Must be positive.',
      );
    }
  }

  final String path;
  final DatabaseFactory _databaseFactory;
  final DateTime Function() _clock;
  final String Function() _idGenerator;
  final String Function() _sessionControlTokenGenerator;
  final bool _singleInstance;

  /// Maximum conservative decoded-object estimate returned by one data page.
  final int maximumPageDecodedBytes;

  /// Safety ceiling for the compatibility all-route materializer.
  final int maximumLegacyBundlePoints;
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
        version: 11,
        singleInstance: _singleInstance,
        onConfigure: configureTrackDatabase,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    await _repairInitialConfigurationEpochs(_db);
    await _emitCurrentTrack();
  }

  static Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        organization_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        route_id TEXT,
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
        terminal_reason_code TEXT,
        session_control_token TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE UNIQUE INDEX idx_tracks_session_control_token
      ON tracks(session_control_token)
    ''');
    await _createConfigurationEpochSchema(database);
    await _createPendingConfigurationUpdateSchema(database);
    await _createManagedExportSchema(database);
    await _createPrivacyOperationSchema(database);
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
        configuration_epoch_id TEXT,
        native_received_at TEXT,
        provider_time_delta_ms_at_receipt INTEGER,
        monotonic_fix_nanos INTEGER,
        monotonic_received_nanos INTEGER,
        monotonic_domain_id TEXT,
        quality_policy_version INTEGER,
        accepted INTEGER NOT NULL,
        quality_flags INTEGER NOT NULL,
        rejection_reason TEXT,
        sync_state TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_sync_error TEXT,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        FOREIGN KEY(segment_id) REFERENCES track_segments(id) ON DELETE CASCADE,
        FOREIGN KEY(configuration_epoch_id)
          REFERENCES tracking_configuration_epochs(id) ON DELETE CASCADE,
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
    await _createStreamingReadIndexes(database);
    await database.execute('''
      CREATE INDEX idx_track_points_configuration_epoch
      ON track_points(configuration_epoch_id, sequence)
    ''');
    await _createUploadOutboxSchema(database);
    await _createDerivedGeometrySchema(database);
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
    if (oldVersion < 3) {
      final trackColumns = await database.rawQuery(
        'PRAGMA table_info(tracks)',
      );
      final names = trackColumns.map((row) => row['name']).toSet();
      if (!names.contains('route_id')) {
        await database.execute('ALTER TABLE tracks ADD COLUMN route_id TEXT');
      }
      if (names.contains('patrol_id')) {
        await database.execute(
          'UPDATE tracks SET route_id = patrol_id WHERE route_id IS NULL',
        );
      }
    }
    if (oldVersion < 4) {
      await _createStreamingReadIndexes(database);
    }
    if (oldVersion < 5) {
      await _createConfigurationEpochSchema(database);
      final pointColumns = await database.rawQuery(
        'PRAGMA table_info(track_points)',
      );
      if (pointColumns.isNotEmpty &&
          !pointColumns.any((row) => row['name'] == 'configuration_epoch_id')) {
        await database.execute('''
          ALTER TABLE track_points
          ADD COLUMN configuration_epoch_id TEXT
            REFERENCES tracking_configuration_epochs(id) ON DELETE CASCADE
        ''');
      }
      final updatedPointColumns = await database.rawQuery(
        'PRAGMA table_info(track_points)',
      );
      final updatedPointNames =
          updatedPointColumns.map((row) => row['name']).toSet();
      if (updatedPointNames.containsAll(
        <String>{'configuration_epoch_id', 'sequence'},
      )) {
        await database.execute('''
          CREATE INDEX IF NOT EXISTS idx_track_points_configuration_epoch
          ON track_points(configuration_epoch_id, sequence)
        ''');
      }
      await _repairInitialConfigurationEpochs(database);
    }
    if (oldVersion < 6) {
      await _createManagedExportSchema(database);
    }
    if (oldVersion < 7) {
      final columns = await database.rawQuery('PRAGMA table_info(tracks)');
      if (!columns.any((row) => row['name'] == 'terminal_reason_code')) {
        await database.execute(
          'ALTER TABLE tracks ADD COLUMN terminal_reason_code TEXT',
        );
      }
      await _createPrivacyOperationSchema(database);
    }
    if (oldVersion < 8) {
      final columns = await database.rawQuery('PRAGMA table_info(tracks)');
      if (!columns.any((row) => row['name'] == 'session_control_token')) {
        await database.execute(
          'ALTER TABLE tracks ADD COLUMN session_control_token TEXT',
        );
      }
      await database.rawUpdate('''
        UPDATE tracks
        SET session_control_token = lower(hex(randomblob(16)))
        WHERE session_control_token IS NULL OR session_control_token = ''
      ''');
      await database.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_tracks_session_control_token
        ON tracks(session_control_token)
      ''');
    }
    if (oldVersion < 9) {
      final columns =
          await database.rawQuery('PRAGMA table_info(track_points)');
      if (columns.isEmpty) return;
      final names = columns.map((row) => row['name']).toSet();
      const additions = <String, String>{
        'native_received_at': 'TEXT',
        'provider_time_delta_ms_at_receipt': 'INTEGER',
        'monotonic_fix_nanos': 'INTEGER',
        'monotonic_received_nanos': 'INTEGER',
        'monotonic_domain_id': 'TEXT',
        'quality_policy_version': 'INTEGER',
      };
      for (final addition in additions.entries) {
        if (!names.contains(addition.key)) {
          await database.execute(
            'ALTER TABLE track_points ADD COLUMN ${addition.key} ${addition.value}',
          );
        }
      }
    }
    if (oldVersion < 10) {
      await _createPendingConfigurationUpdateSchema(database);
    }
    if (oldVersion < 11) {
      await _createDerivedGeometrySchema(database);
    }
  }

  static Future<void> _createDerivedGeometrySchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS derived_geometry_runs (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        name TEXT NOT NULL,
        algorithm TEXT NOT NULL,
        algorithm_version TEXT NOT NULL,
        configuration_json TEXT NOT NULL,
        map_data_source TEXT,
        map_data_version TEXT,
        source_maximum_sequence INTEGER NOT NULL,
        status TEXT NOT NULL,
        point_count INTEGER NOT NULL DEFAULT 0,
        failure_code TEXT,
        created_at TEXT NOT NULL,
        completed_at TEXT,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        CHECK(status IN ('processing', 'completed', 'failed')),
        CHECK(source_maximum_sequence >= 0),
        CHECK(point_count >= 0)
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS derived_geometry_points (
        run_id TEXT NOT NULL,
        source_point_id TEXT NOT NULL,
        segment_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        PRIMARY KEY(run_id, source_point_id),
        FOREIGN KEY(run_id) REFERENCES derived_geometry_runs(id)
          ON DELETE CASCADE,
        FOREIGN KEY(source_point_id) REFERENCES track_points(id)
          ON DELETE CASCADE,
        FOREIGN KEY(segment_id) REFERENCES track_segments(id)
          ON DELETE CASCADE,
        UNIQUE(run_id, sequence),
        CHECK(latitude >= -90 AND latitude <= 90),
        CHECK(longitude >= -180 AND longitude <= 180)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_derived_geometry_runs_track_created
      ON derived_geometry_runs(track_id, created_at DESC)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_derived_geometry_points_run_segment_seq
      ON derived_geometry_points(run_id, segment_id, sequence)
    ''');
    await database.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_derived_geometry_points_immutable
      BEFORE UPDATE ON derived_geometry_points
      BEGIN
        SELECT RAISE(ABORT, 'derived geometry points are immutable');
      END
    ''');
    await database.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_derived_geometry_run_provenance_immutable
      BEFORE UPDATE ON derived_geometry_runs
      WHEN OLD.track_id != NEW.track_id
        OR OLD.name != NEW.name
        OR OLD.algorithm != NEW.algorithm
        OR OLD.algorithm_version != NEW.algorithm_version
        OR OLD.configuration_json != NEW.configuration_json
        OR COALESCE(OLD.map_data_source, '') != COALESCE(NEW.map_data_source, '')
        OR COALESCE(OLD.map_data_version, '') != COALESCE(NEW.map_data_version, '')
        OR OLD.source_maximum_sequence != NEW.source_maximum_sequence
        OR OLD.created_at != NEW.created_at
      BEGIN
        SELECT RAISE(ABORT, 'derived geometry provenance is immutable');
      END
    ''');
  }

  static Future<void> _createPendingConfigurationUpdateSchema(
    Database database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS pending_configuration_updates (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL UNIQUE,
        epoch_number INTEGER NOT NULL,
        proposed_configuration_json TEXT NOT NULL,
        previous_configuration_json TEXT NOT NULL,
        stage TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        CHECK(epoch_number > 1),
        CHECK(stage IN ('pending', 'producerFenced', 'nativeApplied'))
      )
    ''');
  }

  static Future<void> _createPrivacyOperationSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS track_privacy_operations (
        id TEXT PRIMARY KEY,
        track_id TEXT,
        operation_type TEXT NOT NULL,
        stage TEXT NOT NULL,
        irreversible_committed INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        terminal_reason_code TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        CHECK(operation_type IN ('abort', 'delete', 'erase')),
        CHECK(irreversible_committed IN (0, 1))
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_track_privacy_operations_track_status
      ON track_privacy_operations(track_id, status, updated_at)
    ''');
  }

  static Future<void> _createManagedExportSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS managed_exports (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        format TEXT NOT NULL,
        state TEXT NOT NULL,
        destination_kind TEXT,
        content_uri TEXT,
        local_file_path TEXT,
        display_path TEXT,
        display_name TEXT,
        mime_type TEXT,
        user_visible INTEGER,
        created_at TEXT NOT NULL,
        committed_at TEXT,
        deleted_at TEXT,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        CHECK(state IN ('pending', 'committed', 'deleted')),
        CHECK(destination_kind IS NULL OR destination_kind IN ('content_uri', 'local_file')),
        CHECK(
          state = 'pending' OR
          (destination_kind = 'content_uri' AND content_uri IS NOT NULL AND local_file_path IS NULL) OR
          (destination_kind = 'local_file' AND local_file_path IS NOT NULL AND content_uri IS NULL)
        )
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_managed_exports_track_state
      ON managed_exports(track_id, state, created_at)
    ''');
  }

  static Future<void> _createConfigurationEpochSchema(
    Database database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS tracking_configuration_epochs (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        epoch_number INTEGER NOT NULL,
        resolved_configuration_json TEXT NOT NULL,
        preset_definition_version INTEGER NOT NULL,
        quality_policy_version INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        activation_sequence INTEGER NOT NULL,
        activated_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        UNIQUE(track_id, epoch_number),
        UNIQUE(track_id, activation_sequence),
        CHECK(epoch_number > 0),
        CHECK(preset_definition_version > 0),
        CHECK(quality_policy_version > 0),
        CHECK(activation_sequence > 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_tracking_config_epochs_activation
      ON tracking_configuration_epochs(track_id, activation_sequence)
    ''');
    await database.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_tracking_config_epochs_immutable
      BEFORE UPDATE ON tracking_configuration_epochs
      BEGIN
        SELECT RAISE(ABORT, 'tracking configuration epochs are immutable');
      END
    ''');
  }

  static Future<void> _repairInitialConfigurationEpochs(
    DatabaseExecutor executor,
  ) async {
    final trackColumns = await executor.rawQuery('PRAGMA table_info(tracks)');
    final trackNames = trackColumns.map((row) => row['name']).toSet();
    if (!trackNames.containsAll(
      <String>{'id', 'configuration_json', 'started_at'},
    )) {
      return;
    }
    final epochTables = await executor.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type = 'table' AND name = 'tracking_configuration_epochs'",
    );
    if (epochTables.isEmpty) return;

    final tracks = await executor.query(
      'tracks',
      columns: <String>['id', 'configuration_json', 'started_at'],
    );
    for (final row in tracks) {
      final trackId = row['id'] as String?;
      final configurationJson = row['configuration_json'] as String?;
      final startedAt = row['started_at'] as String?;
      if (trackId == null ||
          trackId.isEmpty ||
          configurationJson == null ||
          configurationJson.trim().isEmpty ||
          startedAt == null) {
        continue;
      }
      try {
        final resolved = TrackingConfig.fromJson(configurationJson);
        resolved.validate(context: 'Persisted TrackingConfig');
        await executor.insert(
          'tracking_configuration_epochs',
          <String, Object?>{
            'id': _initialConfigurationEpochId(trackId),
            'track_id': trackId,
            'epoch_number': 1,
            'resolved_configuration_json': resolved.toJson(),
            'preset_definition_version':
                TrackingPolicyVersions.presetDefinition,
            'quality_policy_version': TrackingPolicyVersions.qualityPolicy,
            'created_at': startedAt,
            'activation_sequence': 1,
            'activated_at': startedAt,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      } on Object {
        // Malformed or incomplete legacy configuration is unknown evidence.
        // Do not infer a default epoch for it.
      }
    }

    final pointColumns = await executor.rawQuery(
      'PRAGMA table_info(track_points)',
    );
    if (!pointColumns.any(
      (row) => row['name'] == 'configuration_epoch_id',
    )) {
      return;
    }
    await executor.rawUpdate('''
      UPDATE track_points
      SET configuration_epoch_id = (
        SELECT epoch.id
        FROM tracking_configuration_epochs AS epoch
        WHERE epoch.track_id = track_points.track_id
          AND epoch.epoch_number = 1
      )
      WHERE configuration_epoch_id IS NULL
        AND EXISTS (
          SELECT 1
          FROM tracking_configuration_epochs AS epoch
          WHERE epoch.track_id = track_points.track_id
            AND epoch.epoch_number = 1
        )
    ''');
  }

  static String _initialConfigurationEpochId(String trackId) =>
      'configuration_epoch:$trackId:1';

  static Future<void> _createStreamingReadIndexes(Database database) async {
    final segmentColumns = await database.rawQuery(
      'PRAGMA table_info(track_segments)',
    );
    final segmentNames = segmentColumns.map((row) => row['name']).toSet();
    if (segmentNames.containsAll(<String>{'track_id', 'segment_number'})) {
      await database.execute('''
        CREATE INDEX IF NOT EXISTS idx_track_segments_track_number
        ON track_segments(track_id, segment_number)
      ''');
    }

    final pointColumns = await database.rawQuery(
      'PRAGMA table_info(track_points)',
    );
    final pointNames = pointColumns.map((row) => row['name']).toSet();
    if (pointNames.containsAll(<String>{'track_id', 'accepted', 'sequence'})) {
      await database.execute('''
        CREATE INDEX IF NOT EXISTS idx_track_points_track_accepted_sequence
        ON track_points(track_id, accepted, sequence)
      ''');
    }
    if (pointNames.containsAll(
      <String>{'segment_id', 'accepted', 'sequence'},
    )) {
      await database.execute('''
        CREATE INDEX IF NOT EXISTS idx_track_points_segment_accepted_sequence
        ON track_points(segment_id, accepted, sequence)
      ''');
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
    String? routeId,
    required TrackingConfig config,
    String? requestedTrackId,
  }) async {
    config.validate(context: 'Track configuration');
    final now = _clock();
    final trackId = requestedTrackId ?? _idGenerator();
    final segmentId = _idGenerator();
    final sessionControlToken = _sessionControlTokenGenerator();
    if (sessionControlToken.trim().isEmpty) {
      throw StateError('The session-control token generator returned empty.');
    }
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
        'route_id': routeId,
        'status': TrackStatus.starting.name,
        'started_at': _timestamp(now),
        'next_sequence': 1,
        'current_segment_id': segmentId,
        'segment_count': 1,
        'tracker_provider': 'native',
        'configuration_json': config.toJson(),
        'session_control_token': sessionControlToken,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      await transaction.insert(
        'tracking_configuration_epochs',
        <String, Object?>{
          'id': _initialConfigurationEpochId(trackId),
          'track_id': trackId,
          'epoch_number': 1,
          'resolved_configuration_json': config.toJson(),
          'preset_definition_version': TrackingPolicyVersions.presetDefinition,
          'quality_policy_version': TrackingPolicyVersions.qualityPolicy,
          'created_at': _timestamp(now),
          'activation_sequence': 1,
          'activated_at': _timestamp(now),
        },
      );
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
  Future<String> beginGapSegment({
    required String trackId,
    required DateTime observedAt,
    required String reason,
  }) async {
    final newSegmentId = _idGenerator();
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (track.status != TrackStatus.active) {
        throw StateError('Cannot split a track in ${track.status.name}.');
      }
      final currentSegmentId = track.currentSegmentId;
      if (currentSegmentId == null) {
        throw StateError('Active track has no current segment.');
      }
      final now = _clock();
      await transaction.update(
        'track_segments',
        <String, Object?>{
          'status': TrackSegmentStatus.interrupted.name,
          'ended_at': _timestamp(observedAt),
          'pause_reason': reason,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[currentSegmentId],
      );
      final nextNumber = track.segmentCount + 1;
      await transaction.insert('track_segments', <String, Object?>{
        'id': newSegmentId,
        'track_id': trackId,
        'segment_number': nextNumber,
        'status': TrackSegmentStatus.active.name,
        'started_at': _timestamp(observedAt),
        'pause_reason': reason,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      await transaction.update(
        'tracks',
        <String, Object?>{
          'current_segment_id': newSegmentId,
          'segment_count': nextNumber,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
    });
    await _emitCurrentTrack();
    return newSegmentId;
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
      final configurationEpoch = await _configurationEpochForSequence(
        transaction,
        trackId: request.trackId,
        sequence: sequence,
      );
      if (configurationEpoch == null) {
        throw TrackingStorageException(
          code: 'configuration_epoch_missing',
          message: 'No immutable configuration epoch covers the next point.',
          trackId: request.trackId,
        );
      }
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
        'configuration_epoch_id': configurationEpoch.id,
        'native_received_at': request.sample.nativeReceivedAt == null
            ? null
            : _timestamp(request.sample.nativeReceivedAt!),
        'provider_time_delta_ms_at_receipt':
            request.sample.providerTimeDeltaMsAtReceipt,
        'monotonic_fix_nanos': request.sample.monotonicFixNanos,
        'monotonic_received_nanos': request.sample.monotonicReceivedNanos,
        'monotonic_domain_id': request.sample.monotonicDomainId,
        'quality_policy_version': configurationEpoch.qualityPolicyVersion,
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
  Stream<Track?> watchCurrentTrackForOwner(TrackingOwner owner) =>
      Stream<Track?>.multi(
        (controller) {
          var cancelled = false;
          Future<void> refresh() async {
            if (cancelled) return;
            try {
              final track = await findActiveTrackForOwner(owner) ??
                  await findLatestPausedTrackForOwner(owner);
              if (!cancelled) controller.add(track);
            } on Object catch (error, stackTrace) {
              if (!cancelled) controller.addError(error, stackTrace);
            }
          }

          var tail = Future<void>.value();
          void schedule() {
            tail = tail.then((_) => refresh());
          }

          final subscription = _currentTrackController.stream.listen(
            (_) => schedule(),
            onError: controller.addError,
            onDone: controller.close,
          );
          schedule();
          controller.onCancel = () async {
            cancelled = true;
            await subscription.cancel();
            await tail;
          };
        },
        isBroadcast: true,
      );

  @override
  Future<Track?> getTrackForOwner(
    TrackingOwner owner,
    String trackId,
  ) async {
    final rows = await _db.query(
      'tracks',
      where: 'id = ? AND user_id = ? AND organization_id = ?',
      whereArgs: <Object?>[trackId, owner.userId, owner.organizationId],
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromDatabase(rows.single);
  }

  @override
  Future<Track?> findActiveTrackForOwner(TrackingOwner owner) =>
      _findOwnerTrackByStatuses(
        owner,
        const <TrackStatus>{
          TrackStatus.starting,
          TrackStatus.active,
          TrackStatus.stopping,
        },
        orderBy: 'started_at DESC',
      );

  @override
  Future<Track?> findLatestPausedTrackForOwner(TrackingOwner owner) =>
      _findOwnerTrackByStatuses(
        owner,
        const <TrackStatus>{TrackStatus.paused, TrackStatus.interrupted},
        orderBy: 'COALESCE(paused_at, updated_at) DESC',
      );

  Future<Track?> _findOwnerTrackByStatuses(
    TrackingOwner owner,
    Set<TrackStatus> statuses, {
    required String orderBy,
  }) async {
    final placeholders = List<String>.filled(statuses.length, '?').join(',');
    final rows = await _db.query(
      'tracks',
      where:
          'user_id = ? AND organization_id = ? AND status IN ($placeholders)',
      whereArgs: <Object?>[
        owner.userId,
        owner.organizationId,
        ...statuses.map((status) => status.name),
      ],
      orderBy: orderBy,
      limit: 1,
    );
    return rows.isEmpty ? null : Track.fromDatabase(rows.single);
  }

  @override
  Future<List<Track>> listTracksForOwner(TrackingOwner owner) async {
    final rows = await _db.query(
      'tracks',
      where: 'user_id = ? AND organization_id = ?',
      whereArgs: <Object?>[owner.userId, owner.organizationId],
      orderBy: 'started_at DESC, id DESC',
    );
    return rows.map(Track.fromDatabase).toList(growable: false);
  }

  @override
  Future<TrackPage> listTrackPage(TrackQuery query) async {
    if (query.limit < 1 || query.limit > 200) {
      throw ArgumentError.value(
        query.limit,
        'limit',
        'TrackQuery.limit must be between 1 and 200.',
      );
    }
    final conditions = <String>[];
    final arguments = <Object?>[];

    if (query.statuses.isNotEmpty) {
      conditions.add(
        'status IN (${List<String>.filled(query.statuses.length, '?').join(',')})',
      );
      arguments.addAll(query.statuses.map((status) => status.name));
    }
    if (query.startedAfter != null) {
      conditions.add('started_at >= ?');
      arguments.add(_timestamp(query.startedAfter!.toUtc()));
    }
    if (query.startedBefore != null) {
      conditions.add('started_at < ?');
      arguments.add(_timestamp(query.startedBefore!.toUtc()));
    }
    if (query.routeId != null) {
      conditions.add('route_id = ?');
      arguments.add(query.routeId);
    }
    if (query.userId != null) {
      conditions.add('user_id = ?');
      arguments.add(query.userId);
    }
    if (query.organizationId != null) {
      conditions.add('organization_id = ?');
      arguments.add(query.organizationId);
    }
    final cursor = _decodeTrackCursor(query.cursor);
    if (cursor != null) {
      conditions.add('(started_at < ? OR (started_at = ? AND id < ?))');
      arguments
        ..add(cursor.startedAt)
        ..add(cursor.startedAt)
        ..add(cursor.id);
    }

    final rows = await _db.query(
      'tracks',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: arguments.isEmpty ? null : arguments,
      orderBy: 'started_at DESC, id DESC',
      limit: query.limit + 1,
    );
    final tracks = rows.map(Track.fromDatabase).toList(growable: false);
    final hasMore = tracks.length > query.limit;
    final items = hasMore ? tracks.take(query.limit).toList() : tracks;
    return TrackPage(
      items: List<Track>.unmodifiable(items),
      hasMore: hasMore,
      nextCursor:
          hasMore && items.isNotEmpty ? _encodeTrackCursor(items.last) : null,
    );
  }

  @override
  Future<TrackSegmentPage> listSegmentPage({
    required TrackingOwner owner,
    required String trackId,
    required int limit,
    String? cursor,
    TrackDataSnapshot? snapshot,
  }) async {
    _validateDataPageLimit(limit, maximum: 200, name: 'segment limit');
    _validateTrackDataSnapshot(snapshot, trackId);
    final decoded = _decodeDataCursor(cursor, kind: _DataCursorKind.segment);
    if (decoded != null &&
        (decoded.trackId != trackId ||
            decoded.segmentId != null ||
            decoded.acceptedOnly ||
            (snapshot != null &&
                decoded.upperBound != snapshot.upperSegmentNumber))) {
      throw const TrackingStorageException(
        code: 'invalid_page_cursor',
        message: 'The segment cursor does not match this page request.',
      );
    }

    return _db.transaction((transaction) async {
      await _requireOwnedTrack(transaction, owner, trackId);
      final upper = decoded?.upperBound ??
          snapshot?.upperSegmentNumber ??
          await _maximumPersistedKey(
            transaction,
            table: 'track_segments',
            key: 'segment_number',
            where: 'track_id = ?',
            whereArgs: <Object?>[trackId],
          );
      final after = decoded?.afterKey ?? 0;
      _validateDataCursorBounds(after: after, upper: upper);
      final rows = await transaction.query(
        'track_segments',
        where: 'track_id = ? AND segment_number > ? AND segment_number <= ?',
        whereArgs: <Object?>[trackId, after, upper],
        orderBy: 'segment_number ASC',
        limit: limit + 1,
      );
      final page = _buildBoundedSegmentPage(
        rows,
        trackId: trackId,
        limit: limit,
        upper: upper,
      );
      return page;
    });
  }

  @override
  Future<TrackPointPage> listPointPage({
    required TrackingOwner owner,
    required String trackId,
    String? segmentId,
    required int limit,
    String? cursor,
    bool acceptedOnly = false,
    TrackDataSnapshot? snapshot,
  }) async {
    _validateDataPageLimit(limit, maximum: 1000, name: 'point limit');
    _validateTrackDataSnapshot(snapshot, trackId);
    final decoded = _decodeDataCursor(cursor, kind: _DataCursorKind.point);
    if (decoded != null &&
        (decoded.trackId != trackId ||
            decoded.segmentId != segmentId ||
            decoded.acceptedOnly != acceptedOnly ||
            (snapshot != null &&
                decoded.upperBound != snapshot.upperSequence))) {
      throw const TrackingStorageException(
        code: 'invalid_page_cursor',
        message: 'The point cursor does not match this page request.',
      );
    }

    return _db.transaction((transaction) async {
      await _requireOwnedTrack(transaction, owner, trackId);
      if (segmentId != null) {
        final segments = await transaction.query(
          'track_segments',
          columns: <String>['id'],
          where: 'id = ? AND track_id = ?',
          whereArgs: <Object?>[segmentId, trackId],
          limit: 1,
        );
        if (segments.isEmpty) {
          throw const TrackingStorageException(
            code: 'segment_not_found',
            message: 'The segment is not available in this route scope.',
          );
        }
      }

      final snapshotWhere = segmentId == null
          ? 'track_id = ?'
          : 'track_id = ? AND segment_id = ?';
      final snapshotArgs = segmentId == null
          ? <Object?>[trackId]
          : <Object?>[trackId, segmentId];
      final upper = decoded?.upperBound ??
          snapshot?.upperSequence ??
          await _maximumPersistedKey(
            transaction,
            table: 'track_points',
            key: 'sequence',
            where: snapshotWhere,
            whereArgs: snapshotArgs,
          );
      final after = decoded?.afterKey ?? 0;
      _validateDataCursorBounds(after: after, upper: upper);

      final conditions = <String>[
        'track_id = ?',
        'sequence > ?',
        'sequence <= ?',
      ];
      final arguments = <Object?>[trackId, after, upper];
      if (segmentId != null) {
        conditions.add('segment_id = ?');
        arguments.add(segmentId);
      }
      if (acceptedOnly) {
        conditions.add('accepted = 1');
      }
      final rows = await transaction.query(
        'track_points',
        where: conditions.join(' AND '),
        whereArgs: arguments,
        orderBy: 'sequence ASC',
        limit: limit + 1,
      );
      return _buildBoundedPointPage(
        rows,
        trackId: trackId,
        segmentId: segmentId,
        acceptedOnly: acceptedOnly,
        limit: limit,
        upper: upper,
      );
    });
  }

  @override
  Future<TrackDataSnapshot> createTrackDataSnapshot({
    required TrackingOwner owner,
    required String trackId,
  }) async {
    return _db.transaction((transaction) async {
      await _requireOwnedTrack(transaction, owner, trackId);
      final upperSegmentNumber = await _maximumPersistedKey(
        transaction,
        table: 'track_segments',
        key: 'segment_number',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
      final upperSequence = await _maximumPersistedKey(
        transaction,
        table: 'track_points',
        key: 'sequence',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
      return TrackDataSnapshot(
        trackId: trackId,
        upperSegmentNumber: upperSegmentNumber,
        upperSequence: upperSequence,
      );
    });
  }

  @override
  Future<TrackingConfigurationEpoch?> getConfigurationEpoch({
    required TrackingOwner owner,
    required String trackId,
    required String epochId,
  }) async {
    return _db.transaction((transaction) async {
      await _requireOwnedTrack(transaction, owner, trackId);
      final rows = await transaction.query(
        'tracking_configuration_epochs',
        where: 'id = ? AND track_id = ?',
        whereArgs: <Object?>[epochId, trackId],
        limit: 1,
      );
      return rows.isEmpty
          ? null
          : TrackingConfigurationEpoch.fromDatabase(rows.single);
    });
  }

  @override
  Future<TrackingConfigurationUpdateOperation> beginConfigurationUpdate({
    required TrackingOwner owner,
    required String trackId,
    required TrackingConfig config,
  }) async {
    config.validate(context: 'Runtime tracking configuration');
    final now = _clock();
    final operationId = _idGenerator();
    late final TrackingConfigurationUpdateOperation operation;
    await _db.transaction((transaction) async {
      final track = await _requireOwnedTrack(transaction, owner, trackId);
      if (track.status != TrackStatus.active) {
        throw StateError('Runtime configuration requires an active track.');
      }
      final existing = await transaction.query(
        'pending_configuration_updates',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        operation = TrackingConfigurationUpdateOperation.fromDatabase(
          existing.single,
        );
        return;
      }
      final epochRows = await transaction.rawQuery(
        'SELECT COALESCE(MAX(epoch_number), 0) AS maximum_epoch '
        'FROM tracking_configuration_epochs WHERE track_id = ?',
        <Object?>[trackId],
      );
      final epochNumber =
          ((epochRows.single['maximum_epoch'] as num?)?.toInt() ?? 0) + 1;
      final row = <String, Object?>{
        'id': operationId,
        'track_id': trackId,
        'epoch_number': epochNumber,
        'proposed_configuration_json': config.toJson(),
        'previous_configuration_json': track.config.toJson(),
        'stage': TrackingConfigurationUpdateStage.pending.name,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      };
      await transaction.insert('pending_configuration_updates', row);
      operation = TrackingConfigurationUpdateOperation.fromDatabase(row);
    });
    return operation;
  }

  @override
  Future<void> markConfigurationUpdateStage({
    required String operationId,
    required TrackingConfigurationUpdateStage stage,
  }) async {
    await _db.transaction((transaction) async {
      final rows = await transaction.query(
        'pending_configuration_updates',
        where: 'id = ?',
        whereArgs: <Object?>[operationId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final current = TrackingConfigurationUpdateOperation.fromDatabase(
        rows.single,
      );
      if (stage.index < current.stage.index) {
        throw StateError('Configuration update stage cannot move backwards.');
      }
      await transaction.update(
        'pending_configuration_updates',
        <String, Object?>{
          'stage': stage.name,
          'updated_at': _timestamp(_clock()),
        },
        where: 'id = ?',
        whereArgs: <Object?>[operationId],
      );
    });
  }

  @override
  Future<TrackingConfigurationEpoch> activateConfigurationUpdate({
    required String operationId,
  }) async {
    late final TrackingConfigurationEpoch epoch;
    await _db.transaction((transaction) async {
      final operations = await transaction.query(
        'pending_configuration_updates',
        where: 'id = ?',
        whereArgs: <Object?>[operationId],
        limit: 1,
      );
      if (operations.isEmpty) {
        throw StateError('Unknown configuration update operation.');
      }
      final operation = TrackingConfigurationUpdateOperation.fromDatabase(
        operations.single,
      );
      if (operation.stage != TrackingConfigurationUpdateStage.nativeApplied) {
        throw StateError('Native policy must be applied before activation.');
      }
      final trackRows = await transaction.query(
        'tracks',
        columns: <String>['next_sequence'],
        where: 'id = ?',
        whereArgs: <Object?>[operation.trackId],
        limit: 1,
      );
      if (trackRows.isEmpty) throw StateError('Unknown configuration track.');
      final nextSequence = (trackRows.single['next_sequence']! as num).toInt();
      final priorEpochRows = await transaction.rawQuery(
        'SELECT COALESCE(MAX(activation_sequence), 0) AS maximum_activation '
        'FROM tracking_configuration_epochs WHERE track_id = ?',
        <Object?>[operation.trackId],
      );
      final maximumActivation =
          (priorEpochRows.single['maximum_activation']! as num).toInt();
      final activationSequence = nextSequence > maximumActivation
          ? nextSequence
          : maximumActivation + 1;
      final now = _clock();
      final epochId = _idGenerator();
      final row = <String, Object?>{
        'id': epochId,
        'track_id': operation.trackId,
        'epoch_number': operation.epochNumber,
        'resolved_configuration_json': operation.proposedConfig.toJson(),
        'preset_definition_version': TrackingPolicyVersions.presetDefinition,
        'quality_policy_version': TrackingPolicyVersions.qualityPolicy,
        'created_at': _timestamp(operation.createdAt),
        'activation_sequence': activationSequence,
        'activated_at': _timestamp(now),
      };
      await transaction.insert('tracking_configuration_epochs', row);
      await transaction.update(
        'tracks',
        <String, Object?>{
          'configuration_json': operation.proposedConfig.toJson(),
          if (activationSequence != nextSequence)
            'next_sequence': activationSequence,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[operation.trackId],
      );
      await transaction.delete(
        'pending_configuration_updates',
        where: 'id = ?',
        whereArgs: <Object?>[operationId],
      );
      epoch = TrackingConfigurationEpoch.fromDatabase(row);
    });
    await _emitCurrentTrack();
    return epoch;
  }

  @override
  Future<void> cancelConfigurationUpdate(String operationId) => _db.delete(
        'pending_configuration_updates',
        where: 'id = ? AND stage != ?',
        whereArgs: <Object?>[
          operationId,
          TrackingConfigurationUpdateStage.nativeApplied.name,
        ],
      );

  @override
  Future<List<TrackingConfigurationUpdateOperation>>
      pendingConfigurationUpdates() async {
    final rows = await _db.query(
      'pending_configuration_updates',
      orderBy: 'created_at ASC, id ASC',
    );
    return rows
        .map(TrackingConfigurationUpdateOperation.fromDatabase)
        .toList(growable: false);
  }

  @override
  Future<String> beginManagedExport({
    required TrackingOwner owner,
    required String trackId,
    required TrackExportFormat format,
  }) async {
    final exportId = _idGenerator();
    final now = _clock();
    await _db.transaction((transaction) async {
      await _requireOwnedTrack(transaction, owner, trackId);
      await transaction.insert('managed_exports', <String, Object?>{
        'id': exportId,
        'track_id': trackId,
        'format': format.name,
        'state': ManagedExportState.pending.name,
        'created_at': _timestamp(now),
      });
    });
    return exportId;
  }

  @override
  Future<void> commitManagedExport({
    required TrackingOwner owner,
    required String exportId,
    required TrackExportDestination destination,
  }) async {
    final contentUri = destination.contentUri?.toString();
    final localFilePath = destination.localFilePath;
    if ((contentUri == null) == (localFilePath == null)) {
      throw const TrackingStorageException(
        code: 'invalid_export_destination',
        message: 'A managed export requires exactly one durable access handle.',
      );
    }
    await _db.transaction((transaction) async {
      final rows = await transaction.rawQuery('''
        SELECT managed.id
        FROM managed_exports AS managed
        INNER JOIN tracks AS track ON track.id = managed.track_id
        WHERE managed.id = ? AND managed.state = ?
          AND track.user_id = ? AND track.organization_id = ?
        LIMIT 1
        ''', <Object?>[
        exportId,
        ManagedExportState.pending.name,
        owner.userId,
        owner.organizationId,
      ]);
      if (rows.isEmpty) {
        throw const TrackingOwnershipException(
          code: 'managed_export_not_found_in_owner_scope',
          message: 'The pending export is not available in this owner scope.',
        );
      }
      await transaction.update(
        'managed_exports',
        <String, Object?>{
          'state': ManagedExportState.committed.name,
          'destination_kind': contentUri != null ? 'content_uri' : 'local_file',
          'content_uri': contentUri,
          'local_file_path': localFilePath,
          'display_path': destination.displayPath,
          'display_name': destination.displayName,
          'mime_type': destination.mimeType,
          'user_visible': destination.userVisible ? 1 : 0,
          'committed_at': _timestamp(_clock()),
        },
        where: 'id = ?',
        whereArgs: <Object?>[exportId],
      );
    });
  }

  @override
  Future<void> abortManagedExport({
    required TrackingOwner owner,
    required String exportId,
  }) async {
    await _db.rawDelete('''
      DELETE FROM managed_exports
      WHERE id = ? AND state = ? AND track_id IN (
        SELECT id FROM tracks WHERE user_id = ? AND organization_id = ?
      )
      ''', <Object?>[
      exportId,
      ManagedExportState.pending.name,
      owner.userId,
      owner.organizationId,
    ]);
  }

  @override
  Future<ManagedExportRecord?> getManagedExport({
    required TrackingOwner owner,
    required String exportId,
  }) async {
    final rows = await _db.rawQuery('''
      SELECT managed.*
      FROM managed_exports AS managed
      INNER JOIN tracks AS track ON track.id = managed.track_id
      WHERE managed.id = ?
        AND track.user_id = ? AND track.organization_id = ?
      LIMIT 1
      ''', <Object?>[exportId, owner.userId, owner.organizationId]);
    if (rows.isEmpty) return null;
    return _managedExportFromRow(rows.single);
  }

  @override
  Future<List<ManagedExportRecord>> listManagedExports({
    required TrackingOwner owner,
    required String trackId,
  }) async {
    await _requireOwnedTrack(_db, owner, trackId);
    final rows = await _db.query(
      'managed_exports',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(_managedExportFromRow).toList(growable: false);
  }

  @override
  Future<void> markManagedExportDeleted({
    required TrackingOwner owner,
    required String exportId,
  }) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final rows = await transaction.rawQuery('''
        SELECT managed.state
        FROM managed_exports AS managed
        INNER JOIN tracks AS track ON track.id = managed.track_id
        WHERE managed.id = ?
          AND track.user_id = ? AND track.organization_id = ?
        LIMIT 1
        ''', <Object?>[exportId, owner.userId, owner.organizationId]);
      if (rows.isEmpty) {
        throw const TrackingOwnershipException(
          code: 'managed_export_not_found_in_owner_scope',
          message: 'The export is not available in this owner scope.',
        );
      }
      if (rows.single['state'] == ManagedExportState.deleted.name) return;
      await transaction.update(
        'managed_exports',
        <String, Object?>{
          'state': ManagedExportState.deleted.name,
          'deleted_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[exportId],
      );
    });
  }

  static ManagedExportRecord _managedExportFromRow(
    Map<String, Object?> row,
  ) {
    final contentUri = row['content_uri'] as String?;
    final localFilePath = row['local_file_path'] as String?;
    final destination = contentUri == null && localFilePath == null
        ? null
        : TrackExportDestination(
            displayName: row['display_name']! as String,
            mimeType: row['mime_type']! as String,
            contentUri: contentUri == null ? null : Uri.parse(contentUri),
            localFilePath: localFilePath,
            displayPath: row['display_path'] as String?,
            userVisible: row['user_visible'] == 1,
          );
    DateTime? date(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return ManagedExportRecord(
      id: row['id']! as String,
      trackId: row['track_id']! as String,
      format: TrackExportFormat.values.byName(row['format']! as String),
      state: ManagedExportState.values.byName(row['state']! as String),
      destination: destination,
      createdAt: date('created_at')!,
      committedAt: date('committed_at'),
      deletedAt: date('deleted_at'),
    );
  }

  @override
  Future<TrackPrivacyOperationRecord> beginPrivacyOperation({
    required TrackingOwner owner,
    required String trackId,
    required String operationType,
    String? operationId,
  }) async {
    if (!const <String>{
      TrackPrivacyOperationTypes.abort,
      TrackPrivacyOperationTypes.delete,
      TrackPrivacyOperationTypes.erase,
    }.contains(operationType)) {
      throw ArgumentError.value(operationType, 'operationType');
    }
    final id = operationId?.trim().isNotEmpty == true
        ? operationId!.trim()
        : _idGenerator();
    final now = _clock();
    return _db.transaction((transaction) async {
      await _requireOwnedTrack(transaction, owner, trackId);
      final existing = await transaction.query(
        'track_privacy_operations',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final operation = _privacyOperationFromRow(existing.single);
        if (operation.trackId != trackId ||
            operation.operationType != operationType) {
          throw const TrackingConflictException(
            code: 'privacy_operation_conflict',
            message: 'The operation ID is already bound to another request.',
          );
        }
        return operation;
      }
      await transaction.insert(
        'track_privacy_operations',
        <String, Object?>{
          'id': id,
          'track_id': trackId,
          'operation_type': operationType,
          'stage': TrackPrivacyOperationStages.preflight,
          'irreversible_committed': 0,
          'status': 'pending',
          'created_at': _timestamp(now),
          'updated_at': _timestamp(now),
        },
      );
      return TrackPrivacyOperationRecord(
        id: id,
        trackId: trackId,
        operationType: operationType,
        stage: TrackPrivacyOperationStages.preflight,
        irreversibleCommitted: false,
        status: 'pending',
        createdAt: now,
        updatedAt: now,
      );
    });
  }

  @override
  Future<TrackPrivacyOperationRecord?> getPrivacyOperation(
    String operationId,
  ) async {
    final rows = await _db.query(
      'track_privacy_operations',
      where: 'id = ?',
      whereArgs: <Object?>[operationId],
      limit: 1,
    );
    return rows.isEmpty ? null : _privacyOperationFromRow(rows.single);
  }

  @override
  Future<void> updatePrivacyOperation({
    required String operationId,
    required String stage,
    bool irreversibleCommitted = false,
    String status = 'pending',
    String? terminalReasonCode,
    bool completed = false,
    bool redactTrackIdentity = false,
  }) async {
    final now = _clock();
    final updated = await _db.update(
      'track_privacy_operations',
      <String, Object?>{
        'stage': stage,
        'irreversible_committed': irreversibleCommitted ? 1 : 0,
        'status': status,
        if (terminalReasonCode != null)
          'terminal_reason_code': terminalReasonCode,
        'updated_at': _timestamp(now),
        if (completed) 'completed_at': _timestamp(now),
        if (redactTrackIdentity) 'track_id': null,
      },
      where: 'id = ?',
      whereArgs: <Object?>[operationId],
    );
    if (updated != 1) {
      throw const TrackingStorageException(
        code: 'privacy_operation_not_found',
        message: 'The privacy operation does not exist.',
      );
    }
  }

  @override
  Future<void> abortTrackForOwner({
    required TrackingOwner owner,
    required String trackId,
    required String reason,
    required String operationId,
  }) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final track = await _requireOwnedTrack(transaction, owner, trackId);
      final operationRows = await transaction.query(
        'track_privacy_operations',
        where: 'id = ? AND track_id = ? AND operation_type = ?',
        whereArgs: <Object?>[
          operationId,
          trackId,
          TrackPrivacyOperationTypes.abort,
        ],
        limit: 1,
      );
      if (operationRows.isEmpty) {
        throw const TrackingStorageException(
          code: 'privacy_operation_not_found',
          message: 'The abort operation does not exist.',
        );
      }
      if (track.status == TrackStatus.failed &&
          track.terminalReasonCode == 'cancelled_by_host') {
        return;
      }
      if (track.status == TrackStatus.completed) {
        throw TrackingConflictException(
          code: 'track_not_abortable',
          message: 'A completed route cannot be aborted.',
          trackId: track.id,
        );
      }
      if (track.currentSegmentId != null) {
        await transaction.update(
          'track_segments',
          <String, Object?>{
            'status': TrackSegmentStatus.interrupted.name,
            'ended_at': _timestamp(now),
            'pause_reason': reason,
            'updated_at': _timestamp(now),
          },
          where: 'id = ?',
          whereArgs: <Object?>[track.currentSegmentId],
        );
      }
      await transaction.update(
        'tracks',
        <String, Object?>{
          'status': TrackStatus.failed.name,
          'ended_at': _timestamp(now),
          'current_segment_id': null,
          'completion_reason': reason,
          'terminal_reason_code': 'cancelled_by_host',
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
      await transaction.delete(
        'upload_outbox',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
      await transaction.update(
        'track_privacy_operations',
        <String, Object?>{
          'stage': TrackPrivacyOperationStages.completed,
          'status': 'completed',
          'terminal_reason_code': 'cancelled_by_host',
          'updated_at': _timestamp(now),
          'completed_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[operationId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> eraseTrackForOwner({
    required TrackingOwner owner,
    required String trackId,
    required String operationId,
  }) =>
      _deleteTrackForPrivacy(
        owner: owner,
        trackId: trackId,
        operationId: operationId,
        operationType: TrackPrivacyOperationTypes.erase,
        requireTerminal: false,
      );

  @override
  Future<void> deleteRecordedTrackForOwner({
    required TrackingOwner owner,
    required String trackId,
    required String operationId,
  }) =>
      _deleteTrackForPrivacy(
        owner: owner,
        trackId: trackId,
        operationId: operationId,
        operationType: TrackPrivacyOperationTypes.delete,
        requireTerminal: true,
      );

  Future<void> _deleteTrackForPrivacy({
    required TrackingOwner owner,
    required String trackId,
    required String operationId,
    required String operationType,
    required bool requireTerminal,
  }) async {
    final now = _clock();
    await _db.transaction((transaction) async {
      final operationRows = await transaction.query(
        'track_privacy_operations',
        where: 'id = ? AND operation_type = ?',
        whereArgs: <Object?>[operationId, operationType],
        limit: 1,
      );
      if (operationRows.isEmpty) {
        throw const TrackingStorageException(
          code: 'privacy_operation_not_found',
          message: 'The privacy operation does not exist.',
        );
      }
      final operation = _privacyOperationFromRow(operationRows.single);
      if (operation.status == 'completed' && operation.trackId == null) return;
      if (operation.trackId != trackId || !operation.irreversibleCommitted) {
        throw const TrackingConflictException(
          code: 'privacy_operation_not_committed',
          message: 'The privacy operation is not committed for deletion.',
        );
      }
      final track = await _requireOwnedTrack(transaction, owner, trackId);
      if (requireTerminal && !track.isTerminal) {
        throw TrackingConflictException(
          code: 'track_not_deletable',
          message: 'Only a terminal route can be deleted.',
          trackId: track.id,
        );
      }
      await transaction.delete(
        'tracks',
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
      await transaction.update(
        'track_privacy_operations',
        <String, Object?>{
          'track_id': null,
          'stage': TrackPrivacyOperationStages.completed,
          'status': 'completed',
          'irreversible_committed': 1,
          'updated_at': _timestamp(now),
          'completed_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[operationId],
      );
    });
    await _emitCurrentTrack();
  }

  static TrackPrivacyOperationRecord _privacyOperationFromRow(
    Map<String, Object?> row,
  ) {
    DateTime? date(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return TrackPrivacyOperationRecord(
      id: row['id']! as String,
      trackId: row['track_id'] as String?,
      operationType: row['operation_type']! as String,
      stage: row['stage']! as String,
      irreversibleCommitted: row['irreversible_committed'] == 1,
      status: row['status']! as String,
      terminalReasonCode: row['terminal_reason_code'] as String?,
      createdAt: date('created_at')!,
      updatedAt: date('updated_at')!,
      completedAt: date('completed_at'),
    );
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    await _db.transaction((transaction) async {
      final track = await _requiredTrack(transaction, trackId);
      if (!track.isTerminal) {
        throw StateError(
          'Only completed or failed tracks can be deleted. '
          'Track $trackId is ${track.status.name}.',
        );
      }
      await _requireNoCommittedManagedExports(transaction, trackId);
      await transaction.delete(
        'tracks',
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> deleteTrackForOwner(
    TrackingOwner owner,
    String trackId,
  ) async {
    await _db.transaction((transaction) async {
      final track = await _requireOwnedTrack(transaction, owner, trackId);
      if (!track.isTerminal) {
        throw TrackingStorageException(
          code: 'track_not_deletable',
          message: 'Only a terminal route can be deleted.',
          trackId: track.id,
        );
      }
      await _requireNoCommittedManagedExports(transaction, trackId);
      await transaction.delete(
        'tracks',
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> deleteTracksExcept(Set<String> retainedTrackIds) async {
    await _db.transaction((transaction) async {
      if (retainedTrackIds.isEmpty) {
        await transaction.delete(
          'tracks',
          where:
              "id NOT IN (SELECT track_id FROM managed_exports WHERE state = ?)",
          whereArgs: <Object?>[ManagedExportState.committed.name],
        );
        return;
      }
      final placeholders =
          List<String>.filled(retainedTrackIds.length, '?').join(',');
      await transaction.delete(
        'tracks',
        where: 'id NOT IN ($placeholders) AND '
            'id NOT IN (SELECT track_id FROM managed_exports WHERE state = ?)',
        whereArgs: <Object?>[
          ...retainedTrackIds,
          ManagedExportState.committed.name,
        ],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> deleteTracksExceptForOwner(
    TrackingOwner owner,
    Set<String> retainedTrackIds,
  ) async {
    await _db.transaction((transaction) async {
      final conditions = <String>[
        'user_id = ?',
        'organization_id = ?',
        'status IN (?, ?)',
        'id NOT IN (SELECT track_id FROM managed_exports WHERE state = ?)',
      ];
      final arguments = <Object?>[
        owner.userId,
        owner.organizationId,
        TrackStatus.completed.name,
        TrackStatus.failed.name,
        ManagedExportState.committed.name,
      ];
      if (retainedTrackIds.isNotEmpty) {
        conditions.add(
          'id NOT IN (${List<String>.filled(retainedTrackIds.length, '?').join(',')})',
        );
        arguments.addAll(retainedTrackIds);
      }
      await transaction.delete(
        'tracks',
        where: conditions.join(' AND '),
        whereArgs: arguments,
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
      final pointCountRows = await transaction.rawQuery(
        'SELECT COUNT(*) AS point_count FROM track_points WHERE track_id = ?',
        <Object?>[trackId],
      );
      final pointCount =
          (pointCountRows.single['point_count'] as num?)?.toInt() ?? 0;
      if (pointCount > maximumLegacyBundlePoints) {
        throw TrackingStorageException(
          code: 'legacy_bundle_limit_exceeded',
          message: 'This route contains $pointCount points, which exceeds the '
              'configured all-route materialization limit. Use the bounded '
              'segment and point page APIs.',
          trackId: trackId,
        );
      }
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
  Future<List<String>> pendingUploadTrackIdsForOwner(
    TrackingOwner owner,
  ) async {
    final rows = await _db.rawQuery('''
      SELECT track_id FROM upload_outbox
        WHERE track_id IN (
          SELECT id FROM tracks WHERE user_id = ? AND organization_id = ?
        )
      UNION
      SELECT track_id FROM track_points
        WHERE accepted = 1 AND sync_state = 'pending'
          AND track_id IN (
            SELECT id FROM tracks WHERE user_id = ? AND organization_id = ?
          )
      UNION
      SELECT id AS track_id FROM tracks
        WHERE status = 'completed' AND sync_state != 'synced'
          AND user_id = ? AND organization_id = ?
      ORDER BY track_id
    ''', <Object?>[
      owner.userId,
      owner.organizationId,
      owner.userId,
      owner.organizationId,
      owner.userId,
      owner.organizationId,
    ]);
    return rows.map((row) => row['track_id'] as String).toList(growable: false);
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

  static String _encodeTrackCursor(Track track) {
    final payload = jsonEncode(<String, Object?>{
      'startedAt': _timestamp(track.startedAt),
      'id': track.id,
    });
    return base64Url.encode(utf8.encode(payload));
  }

  static _TrackCursor? _decodeTrackCursor(String? cursor) {
    if (cursor == null || cursor.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(cursor)));
      if (decoded is! Map) return null;
      final startedAt = decoded['startedAt'];
      final id = decoded['id'];
      if (startedAt is! String || id is! String || id.isEmpty) return null;
      return _TrackCursor(startedAt: startedAt, id: id);
    } on Object {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid track-page cursor.');
    }
  }

  static String _timestamp(DateTime value) => value.toUtc().toIso8601String();

  static void _validateDataPageLimit(
    int limit, {
    required int maximum,
    required String name,
  }) {
    if (limit < 1 || limit > maximum) {
      throw ArgumentError.value(
        limit,
        'limit',
        '$name must be between 1 and $maximum.',
      );
    }
  }

  static void _validateTrackDataSnapshot(
    TrackDataSnapshot? snapshot,
    String trackId,
  ) {
    if (snapshot == null) return;
    if (snapshot.trackId != trackId ||
        snapshot.upperSegmentNumber < 0 ||
        snapshot.upperSequence < 0) {
      throw const TrackingStorageException(
        code: 'invalid_page_snapshot',
        message: 'The route-data snapshot does not match this page request.',
      );
    }
  }

  static void _validateDataCursorBounds({
    required int after,
    required int upper,
  }) {
    if (after < 0 || upper < 0 || after > upper) {
      throw const TrackingStorageException(
        code: 'invalid_page_cursor',
        message: 'The page cursor contains invalid snapshot boundaries.',
      );
    }
  }

  static Future<int> _maximumPersistedKey(
    DatabaseExecutor executor, {
    required String table,
    required String key,
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final rows = await executor.rawQuery(
      'SELECT MAX($key) AS maximum_key FROM $table WHERE $where',
      whereArgs,
    );
    return (rows.single['maximum_key'] as num?)?.toInt() ?? 0;
  }

  static Future<TrackingConfigurationEpoch?> _configurationEpochForSequence(
    DatabaseExecutor executor, {
    required String trackId,
    required int sequence,
  }) async {
    final rows = await executor.query(
      'tracking_configuration_epochs',
      where: 'track_id = ? AND activation_sequence <= ?',
      whereArgs: <Object?>[trackId, sequence],
      orderBy: 'activation_sequence DESC',
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : TrackingConfigurationEpoch.fromDatabase(rows.single);
  }

  static Future<Track> _requireOwnedTrack(
    DatabaseExecutor executor,
    TrackingOwner owner,
    String trackId,
  ) async {
    final rows = await executor.query(
      'tracks',
      where: 'id = ? AND user_id = ? AND organization_id = ?',
      whereArgs: <Object?>[
        trackId,
        owner.userId,
        owner.organizationId,
      ],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    return Track.fromDatabase(rows.single);
  }

  static Future<void> _requireNoCommittedManagedExports(
    DatabaseExecutor executor,
    String trackId,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT COUNT(*) AS export_count
      FROM managed_exports
      WHERE track_id = ? AND state = ?
      ''',
      <Object?>[trackId, ManagedExportState.committed.name],
    );
    final count = (rows.single['export_count'] as num?)?.toInt() ?? 0;
    if (count > 0) {
      throw const TrackingConflictException(
        code: 'managed_exports_require_explicit_cleanup',
        message:
            'This route has managed exports that require an explicit choice.',
      );
    }
  }

  TrackSegmentPage _buildBoundedSegmentPage(
    List<Map<String, Object?>> rows, {
    required String trackId,
    required int limit,
    required int upper,
  }) {
    final items = <TrackSegment>[];
    var estimatedBytes = 0;
    var hasMore = false;
    for (final row in rows) {
      if (items.length == limit) {
        hasMore = true;
        break;
      }
      final segment = TrackSegment.fromDatabase(row);
      final itemBytes = _estimateSegmentBytes(segment);
      if (itemBytes > maximumPageDecodedBytes && items.isEmpty) {
        throw const TrackingStorageException(
          code: 'page_item_too_large',
          message: 'A segment cannot fit within the configured page budget.',
        );
      }
      if (estimatedBytes + itemBytes > maximumPageDecodedBytes) {
        hasMore = true;
        break;
      }
      items.add(segment);
      estimatedBytes += itemBytes;
    }
    hasMore = hasMore || rows.length > items.length;
    return TrackSegmentPage(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore && items.isNotEmpty
          ? _encodeDataCursor(
              _DataCursor(
                kind: _DataCursorKind.segment,
                trackId: trackId,
                upperBound: upper,
                afterKey: items.last.segmentNumber,
              ),
            )
          : null,
      snapshotUpperSegmentNumber: upper,
      estimatedDecodedBytes: estimatedBytes,
    );
  }

  TrackPointPage _buildBoundedPointPage(
    List<Map<String, Object?>> rows, {
    required String trackId,
    required String? segmentId,
    required bool acceptedOnly,
    required int limit,
    required int upper,
  }) {
    final items = <TrackPoint>[];
    var estimatedBytes = 0;
    var hasMore = false;
    for (final row in rows) {
      if (items.length == limit) {
        hasMore = true;
        break;
      }
      final point = TrackPoint.fromDatabase(row);
      final itemBytes = _estimatePointBytes(point);
      if (itemBytes > maximumPageDecodedBytes && items.isEmpty) {
        throw const TrackingStorageException(
          code: 'page_item_too_large',
          message: 'A point cannot fit within the configured page budget.',
        );
      }
      if (estimatedBytes + itemBytes > maximumPageDecodedBytes) {
        hasMore = true;
        break;
      }
      items.add(point);
      estimatedBytes += itemBytes;
    }
    hasMore = hasMore || rows.length > items.length;
    return TrackPointPage(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore && items.isNotEmpty
          ? _encodeDataCursor(
              _DataCursor(
                kind: _DataCursorKind.point,
                trackId: trackId,
                segmentId: segmentId,
                acceptedOnly: acceptedOnly,
                upperBound: upper,
                afterKey: items.last.sequence,
              ),
            )
          : null,
      snapshotUpperSequence: upper,
      estimatedDecodedBytes: estimatedBytes,
    );
  }

  static int _estimateSegmentBytes(TrackSegment segment) =>
      256 +
      _stringBytes(segment.id) +
      _stringBytes(segment.trackId) +
      _stringBytes(segment.startPointId) +
      _stringBytes(segment.endPointId) +
      _stringBytes(segment.resumedFromPointId) +
      _stringBytes(segment.pauseReason);

  static int _estimatePointBytes(TrackPoint point) =>
      384 +
      _stringBytes(point.id) +
      _stringBytes(point.trackId) +
      _stringBytes(point.segmentId) +
      _stringBytes(point.provider) +
      _stringBytes(point.mockEvidence) +
      _stringBytes(point.nativeEventId) +
      _stringBytes(point.rejectionReason);

  static int _stringBytes(String? value) =>
      value == null ? 0 : utf8.encode(value).length;

  static String _encodeDataCursor(_DataCursor cursor) {
    final payload = jsonEncode(<String, Object?>{
      'v': 1,
      'kind': cursor.kind.name,
      'trackId': cursor.trackId,
      'segmentId': cursor.segmentId,
      'acceptedOnly': cursor.acceptedOnly,
      'upper': cursor.upperBound,
      'after': cursor.afterKey,
    });
    return base64Url.encode(utf8.encode(payload));
  }

  static _DataCursor? _decodeDataCursor(
    String? cursor, {
    required _DataCursorKind kind,
  }) {
    if (cursor == null || cursor.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(cursor)));
      if (decoded is! Map<String, dynamic> ||
          decoded['v'] != 1 ||
          decoded['kind'] != kind.name ||
          decoded['trackId'] is! String ||
          (decoded['trackId'] as String).isEmpty ||
          decoded['upper'] is! int ||
          decoded['after'] is! int ||
          decoded['acceptedOnly'] is! bool ||
          (decoded['segmentId'] != null && decoded['segmentId'] is! String)) {
        throw const FormatException('Invalid cursor payload.');
      }
      return _DataCursor(
        kind: kind,
        trackId: decoded['trackId'] as String,
        segmentId: decoded['segmentId'] as String?,
        acceptedOnly: decoded['acceptedOnly'] as bool,
        upperBound: decoded['upper'] as int,
        afterKey: decoded['after'] as int,
      );
    } on TrackingStorageException {
      rethrow;
    } on Object {
      throw const TrackingStorageException(
        code: 'invalid_page_cursor',
        message: 'The page cursor is invalid or unsupported.',
      );
    }
  }

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
  Future<DerivedGeometryRun> beginDerivedGeometryRun({
    required TrackingOwner owner,
    required String trackId,
    required DerivedGeometryRequest request,
    required int sourceMaximumSequence,
  }) async {
    if (request.name.trim().isEmpty ||
        request.algorithm.trim().isEmpty ||
        request.algorithmVersion.trim().isEmpty) {
      throw const TrackingConfigurationException(
        code: 'invalid_derived_geometry_request',
        message: 'Derived geometry name, algorithm, and version are required.',
      );
    }
    final track = await getTrackForOwner(owner, trackId);
    if (track == null) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    if (sourceMaximumSequence < 0 ||
        sourceMaximumSequence >= track.nextSequence) {
      throw ArgumentError.value(
        sourceMaximumSequence,
        'sourceMaximumSequence',
        'Must be a valid persisted route snapshot boundary.',
      );
    }
    final id = _idGenerator();
    final now = _clock().toUtc();
    await _db.insert('derived_geometry_runs', <String, Object?>{
      'id': id,
      'track_id': trackId,
      'name': request.name.trim(),
      'algorithm': request.algorithm.trim(),
      'algorithm_version': request.algorithmVersion.trim(),
      'configuration_json': jsonEncode(request.configuration),
      'map_data_source': request.mapDataSource,
      'map_data_version': request.mapDataVersion,
      'source_maximum_sequence': sourceMaximumSequence,
      'status': DerivedGeometryRunStatus.processing.name,
      'point_count': 0,
      'created_at': _timestamp(now),
    });
    return (await getDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      runId: id,
    ))!;
  }

  @override
  Future<void> appendDerivedGeometryPoints({
    required String runId,
    required Iterable<DerivedGeometryPoint> points,
  }) async {
    final values = points.toList(growable: false);
    if (values.isEmpty) return;
    await _db.transaction((transaction) async {
      final runs = await transaction.query(
        'derived_geometry_runs',
        where: 'id = ? AND status = ?',
        whereArgs: <Object?>[
          runId,
          DerivedGeometryRunStatus.processing.name,
        ],
        limit: 1,
      );
      if (runs.isEmpty) {
        throw const TrackingStorageException(
          code: 'derived_geometry_run_not_writable',
          message: 'The derived geometry run is not processing.',
        );
      }
      final trackId = runs.single['track_id']! as String;
      final upper = (runs.single['source_maximum_sequence']! as num).toInt();
      for (final point in values) {
        if (point.runId != runId ||
            !point.latitude.isFinite ||
            !point.longitude.isFinite ||
            point.latitude < -90 ||
            point.latitude > 90 ||
            point.longitude < -180 ||
            point.longitude > 180) {
          throw const TrackingStorageException(
            code: 'invalid_derived_geometry_point',
            message: 'A derived coordinate is invalid for this run.',
          );
        }
        final sources = await transaction.query(
          'track_points',
          columns: <String>['track_id', 'segment_id', 'sequence', 'accepted'],
          where: 'id = ?',
          whereArgs: <Object?>[point.sourcePointId],
          limit: 1,
        );
        if (sources.isEmpty ||
            sources.single['track_id'] != trackId ||
            sources.single['segment_id'] != point.segmentId ||
            sources.single['sequence'] != point.sequence ||
            sources.single['accepted'] != 1 ||
            point.sequence > upper) {
          throw const TrackingStorageException(
            code: 'derived_geometry_source_mismatch',
            message: 'A derived coordinate does not match its raw point.',
          );
        }
        await transaction.insert(
          'derived_geometry_points',
          <String, Object?>{
            'run_id': runId,
            'source_point_id': point.sourcePointId,
            'segment_id': point.segmentId,
            'sequence': point.sequence,
            'latitude': point.latitude,
            'longitude': point.longitude,
          },
        );
      }
    });
  }

  @override
  Future<DerivedGeometryRun> completeDerivedGeometryRun(String runId) async {
    await _db.transaction((transaction) async {
      final runs = await transaction.query(
        'derived_geometry_runs',
        where: 'id = ? AND status = ?',
        whereArgs: <Object?>[
          runId,
          DerivedGeometryRunStatus.processing.name,
        ],
        limit: 1,
      );
      if (runs.isEmpty) {
        throw const TrackingStorageException(
          code: 'derived_geometry_run_not_writable',
          message: 'The derived geometry run is not processing.',
        );
      }
      final row = runs.single;
      final trackId = row['track_id']! as String;
      final upper = (row['source_maximum_sequence']! as num).toInt();
      final expectedRows = await transaction.rawQuery(
        'SELECT COUNT(*) AS count FROM track_points '
        'WHERE track_id = ? AND accepted = 1 AND sequence <= ?',
        <Object?>[trackId, upper],
      );
      final actualRows = await transaction.rawQuery(
        'SELECT COUNT(*) AS count FROM derived_geometry_points WHERE run_id = ?',
        <Object?>[runId],
      );
      final expected = Sqflite.firstIntValue(expectedRows) ?? 0;
      final actual = Sqflite.firstIntValue(actualRows) ?? 0;
      if (actual != expected) {
        throw TrackingStorageException(
          code: 'derived_geometry_incomplete',
          message: 'Derived geometry has $actual of $expected source points.',
          trackId: trackId,
        );
      }
      await transaction.update(
        'derived_geometry_runs',
        <String, Object?>{
          'status': DerivedGeometryRunStatus.completed.name,
          'point_count': actual,
          'completed_at': _timestamp(_clock()),
        },
        where: 'id = ? AND status = ?',
        whereArgs: <Object?>[
          runId,
          DerivedGeometryRunStatus.processing.name,
        ],
      );
    });
    final rows = await _db.query(
      'derived_geometry_runs',
      where: 'id = ?',
      whereArgs: <Object?>[runId],
      limit: 1,
    );
    return _derivedGeometryRun(rows.single);
  }

  @override
  Future<void> failDerivedGeometryRun(
    String runId, {
    required String code,
  }) async {
    await _db.update(
      'derived_geometry_runs',
      <String, Object?>{
        'status': DerivedGeometryRunStatus.failed.name,
        'failure_code': code,
        'completed_at': _timestamp(_clock()),
      },
      where: 'id = ? AND status = ?',
      whereArgs: <Object?>[
        runId,
        DerivedGeometryRunStatus.processing.name,
      ],
    );
  }

  @override
  Future<List<DerivedGeometryRun>> listDerivedGeometryRuns({
    required TrackingOwner owner,
    required String trackId,
  }) async {
    final rows = await _db.rawQuery('''
      SELECT derived_geometry_runs.*
      FROM derived_geometry_runs
      INNER JOIN tracks ON tracks.id = derived_geometry_runs.track_id
      WHERE derived_geometry_runs.track_id = ?
        AND tracks.user_id = ? AND tracks.organization_id = ?
      ORDER BY derived_geometry_runs.created_at DESC,
               derived_geometry_runs.id DESC
    ''', <Object?>[trackId, owner.userId, owner.organizationId]);
    return rows.map(_derivedGeometryRun).toList(growable: false);
  }

  @override
  Future<DerivedGeometryRun?> getDerivedGeometryRun({
    required TrackingOwner owner,
    required String trackId,
    required String runId,
  }) async {
    final rows = await _db.rawQuery('''
      SELECT derived_geometry_runs.*
      FROM derived_geometry_runs
      INNER JOIN tracks ON tracks.id = derived_geometry_runs.track_id
      WHERE derived_geometry_runs.id = ? AND derived_geometry_runs.track_id = ?
        AND tracks.user_id = ? AND tracks.organization_id = ?
      LIMIT 1
    ''', <Object?>[runId, trackId, owner.userId, owner.organizationId]);
    return rows.isEmpty ? null : _derivedGeometryRun(rows.single);
  }

  @override
  Future<Map<String, DerivedGeometryPoint>> derivedCoordinatesForSourcePoints({
    required TrackingOwner owner,
    required String trackId,
    required String runId,
    required Iterable<String> sourcePointIds,
  }) async {
    final ids = sourcePointIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const <String, DerivedGeometryPoint>{};
    final run = await getDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      runId: runId,
    );
    if (run == null || run.status != DerivedGeometryRunStatus.completed) {
      throw const TrackingStorageException(
        code: 'derived_geometry_unavailable',
        message: 'The selected derived geometry is not complete.',
      );
    }
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final rows = await _db.query(
      'derived_geometry_points',
      where: 'run_id = ? AND source_point_id IN ($placeholders)',
      whereArgs: <Object?>[runId, ...ids],
    );
    final result = <String, DerivedGeometryPoint>{};
    for (final row in rows) {
      final point = DerivedGeometryPoint(
        runId: row['run_id']! as String,
        sourcePointId: row['source_point_id']! as String,
        segmentId: row['segment_id']! as String,
        sequence: (row['sequence']! as num).toInt(),
        latitude: (row['latitude']! as num).toDouble(),
        longitude: (row['longitude']! as num).toDouble(),
      );
      result[point.sourcePointId] = point;
    }
    if (result.length != ids.length) {
      throw const TrackingStorageException(
        code: 'derived_geometry_incomplete',
        message: 'The selected derivation is missing source coordinates.',
      );
    }
    return Map<String, DerivedGeometryPoint>.unmodifiable(result);
  }

  @override
  Future<void> deleteDerivedGeometryRun({
    required TrackingOwner owner,
    required String trackId,
    required String runId,
  }) async {
    final count = await _db.rawDelete('''
      DELETE FROM derived_geometry_runs
      WHERE id = ? AND track_id = ? AND EXISTS (
        SELECT 1 FROM tracks
        WHERE tracks.id = derived_geometry_runs.track_id
          AND tracks.user_id = ? AND tracks.organization_id = ?
      )
    ''', <Object?>[runId, trackId, owner.userId, owner.organizationId]);
    if (count != 1) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The derived route is not available in this owner scope.',
      );
    }
  }

  static DerivedGeometryRun _derivedGeometryRun(Map<String, Object?> row) {
    final decoded = jsonDecode(row['configuration_json']! as String);
    return DerivedGeometryRun(
      id: row['id']! as String,
      trackId: row['track_id']! as String,
      name: row['name']! as String,
      algorithm: row['algorithm']! as String,
      algorithmVersion: row['algorithm_version']! as String,
      configuration: (decoded as Map).cast<String, Object?>(),
      mapDataSource: row['map_data_source'] as String?,
      mapDataVersion: row['map_data_version'] as String?,
      sourceMaximumSequence: (row['source_maximum_sequence']! as num).toInt(),
      status: DerivedGeometryRunStatus.values.firstWhere(
        (status) => status.name == row['status'],
      ),
      pointCount: (row['point_count']! as num).toInt(),
      failureCode: row['failure_code'] as String?,
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      completedAt: row['completed_at'] == null
          ? null
          : DateTime.parse(row['completed_at']! as String).toUtc(),
    );
  }

  @override
  Future<void> close() async {
    await _database?.close();
    _database = null;
    await _currentTrackController.close();
  }
}

final class _TrackCursor {
  const _TrackCursor({
    required this.startedAt,
    required this.id,
  });

  final String startedAt;
  final String id;
}

enum _DataCursorKind { segment, point }

final class _DataCursor {
  const _DataCursor({
    required this.kind,
    required this.trackId,
    required this.upperBound,
    required this.afterKey,
    this.segmentId,
    this.acceptedOnly = false,
  });

  final _DataCursorKind kind;
  final String trackId;
  final String? segmentId;
  final bool acceptedOnly;
  final int upperBound;
  final int afterKey;
}
