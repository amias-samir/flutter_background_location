import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../domain/activity_snapshot.dart';
import '../domain/derived_geometry.dart';
import '../domain/export_models.dart';
import '../domain/motion_evidence.dart';
import '../domain/track.dart';
import '../domain/track_data_page.dart';
import '../domain/track_point.dart';
import '../domain/track_query.dart';
import '../domain/track_segment.dart';
import '../domain/tracker_status.dart';
import '../domain/trip.dart';
import '../domain/trip_query.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_continuity.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_privacy.dart';
import '../domain/tracking_quality.dart';
import '../domain/tracking_start.dart';
import 'track_repository.dart';
import 'trip_repository.dart';

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
        ContinuityTrackRepository,
        GapSegmentRepository,
        LegacyGapEvidenceRepository,
        OwnerScopedTrackRepository,
        PrivacyTrackRepository,
        ManagedExportRepository,
        TripRepository,
        TripUploadOutboxRepository,
        TripPrivacyRepository,
        QualityDiagnosticsRepository,
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
  static int? _sqliteBool(bool? value) =>
      value == null ? null : (value ? 1 : 0);

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
        version: 13,
        singleInstance: _singleInstance,
        onConfigure: configureTrackDatabase,
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    // Schema 12 is still under development. Keep this idempotent ensure so a
    // local database opened by an earlier schema-12 build gains the additive
    // Trip completion outbox without a destructive version bump.
    await _createTripUploadOutboxSchema(_db);
    await _createSchema13EvidenceTables(_db);
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
        activity_source TEXT,
        activity_raw_type TEXT,
        activity_evidence_state TEXT,
        activity_age_ms INTEGER,
        activity_probabilities_json TEXT,
        native_foreground_state TEXT,
        screen_interactive INTEGER,
        battery_saver_active INTEGER,
        motion_evidence_id TEXT,
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
        capture_generation_id TEXT,
        native_session_started_at TEXT,
        native_lifecycle TEXT,
        sampling_profile TEXT,
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
    await _createContinuityAndTripSchema(database);
    await _createSchema13EvidenceTables(database);
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
    if (oldVersion < 12) {
      final pointColumns = await database.rawQuery(
        'PRAGMA table_info(track_points)',
      );
      final pointNames = pointColumns.map((row) => row['name']).toSet();
      const additions = <String, String>{
        'capture_generation_id': 'TEXT',
        'native_session_started_at': 'TEXT',
        'native_lifecycle': 'TEXT',
        'sampling_profile': 'TEXT',
      };
      for (final addition in additions.entries) {
        if (pointColumns.isNotEmpty && !pointNames.contains(addition.key)) {
          await database.execute(
            'ALTER TABLE track_points ADD COLUMN ${addition.key} ${addition.value}',
          );
        }
      }
      await _createContinuityAndTripSchema(database);
      await _backfillImplicitTrips(database);
    }
    if (oldVersion < 13) {
      final tripColumns = await database.rawQuery('PRAGMA table_info(trips)');
      final tripNames = tripColumns.map((row) => row['name']).toSet();
      const tripAdditions = <String, String>{
        'route_presentation': "TEXT NOT NULL DEFAULT 'separateRecordedParts'",
        'capture_intent': "TEXT NOT NULL DEFAULT 'adaptive'",
        'quality_policy_version': 'INTEGER NOT NULL DEFAULT 1',
      };
      for (final addition in tripAdditions.entries) {
        if (tripColumns.isNotEmpty && !tripNames.contains(addition.key)) {
          await database.execute(
            'ALTER TABLE trips ADD COLUMN ${addition.key} ${addition.value}',
          );
        }
      }
      final pointColumns =
          await database.rawQuery('PRAGMA table_info(track_points)');
      final pointNames = pointColumns.map((row) => row['name']).toSet();
      const pointAdditions = <String, String>{
        'activity_source': 'TEXT',
        'activity_raw_type': 'TEXT',
        'activity_evidence_state': 'TEXT',
        'activity_age_ms': 'INTEGER',
        'activity_probabilities_json': 'TEXT',
        'native_foreground_state': 'TEXT',
        'screen_interactive': 'INTEGER',
        'battery_saver_active': 'INTEGER',
        'motion_evidence_id': 'TEXT',
      };
      for (final addition in pointAdditions.entries) {
        if (pointColumns.isNotEmpty && !pointNames.contains(addition.key)) {
          await database.execute(
            'ALTER TABLE track_points ADD COLUMN ${addition.key} ${addition.value}',
          );
        }
      }
      final derivedColumns =
          await database.rawQuery('PRAGMA table_info(derived_geometry_points)');
      final derivedNames = derivedColumns.map((row) => row['name']).toSet();
      const derivedAdditions = <String, String>{
        'processor_confidence': 'REAL',
        'matched': 'INTEGER NOT NULL DEFAULT 1',
      };
      for (final addition in derivedAdditions.entries) {
        if (derivedColumns.isNotEmpty && !derivedNames.contains(addition.key)) {
          await database.execute(
            'ALTER TABLE derived_geometry_points ADD COLUMN '
            '${addition.key} ${addition.value}',
          );
        }
      }
      await _createSchema13EvidenceTables(database);
    }
  }

  static Future<void> _createContinuityAndTripSchema(
    Database database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS track_continuity_gaps (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        before_point_id TEXT,
        after_point_id TEXT NOT NULL,
        before_segment_id TEXT NOT NULL,
        after_segment_id TEXT NOT NULL,
        provider_gap_ms INTEGER,
        raw_receipt_gap_ms INTEGER,
        straight_line_distance_m REAL,
        cause TEXT NOT NULL,
        treatment TEXT NOT NULL,
        distance_treatment TEXT NOT NULL,
        native_capture_generation TEXT,
        configuration_epoch_id TEXT,
        continuity_policy_version INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        FOREIGN KEY(before_point_id) REFERENCES track_points(id) ON DELETE CASCADE,
        FOREIGN KEY(after_point_id) REFERENCES track_points(id) ON DELETE CASCADE,
        FOREIGN KEY(before_segment_id) REFERENCES track_segments(id) ON DELETE CASCADE,
        FOREIGN KEY(after_segment_id) REFERENCES track_segments(id) ON DELETE CASCADE,
        FOREIGN KEY(configuration_epoch_id)
          REFERENCES tracking_configuration_epochs(id) ON DELETE CASCADE,
        UNIQUE(track_id, after_point_id, continuity_policy_version),
        CHECK(provider_gap_ms IS NULL OR provider_gap_ms >= 0),
        CHECK(raw_receipt_gap_ms IS NULL OR raw_receipt_gap_ms >= 0),
        CHECK(straight_line_distance_m IS NULL OR straight_line_distance_m >= 0),
        CHECK(continuity_policy_version > 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_track_continuity_gaps_track_created
      ON track_continuity_gaps(track_id, created_at)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_track_continuity_gaps_track_cause
      ON track_continuity_gaps(track_id, cause)
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS trips (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        organization_id TEXT NOT NULL,
        route_id TEXT,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        suspended_at TEXT,
        ended_at TEXT,
        current_leg_track_id TEXT,
        leg_count INTEGER NOT NULL DEFAULT 0,
        accepted_point_count INTEGER NOT NULL DEFAULT 0,
        rejected_point_count INTEGER NOT NULL DEFAULT 0,
        measured_distance_m REAL NOT NULL DEFAULT 0,
        lifecycle_revision INTEGER NOT NULL DEFAULT 1,
        route_presentation TEXT NOT NULL DEFAULT 'separateRecordedParts',
        capture_intent TEXT NOT NULL DEFAULT 'adaptive',
        quality_policy_version INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(current_leg_track_id) REFERENCES tracks(id) ON DELETE SET NULL,
        CHECK(status IN ('active', 'suspended', 'completed', 'failed')),
        CHECK(leg_count >= 0),
        CHECK(accepted_point_count >= 0),
        CHECK(rejected_point_count >= 0),
        CHECK(measured_distance_m >= 0),
        CHECK(lifecycle_revision > 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_trips_owner_started
      ON trips(organization_id, user_id, started_at DESC, id DESC)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_trips_status
      ON trips(status)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS trip_legs (
        trip_id TEXT NOT NULL,
        track_id TEXT NOT NULL UNIQUE,
        leg_number INTEGER NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        day_label TEXT,
        PRIMARY KEY(trip_id, leg_number),
        FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        CHECK(leg_number > 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_trip_legs_track
      ON trip_legs(track_id)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS trip_operations (
        id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        operation_id TEXT NOT NULL,
        stage TEXT NOT NULL,
        reason TEXT,
        leg_track_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT,
        FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE,
        FOREIGN KEY(leg_track_id) REFERENCES tracks(id) ON DELETE SET NULL,
        UNIQUE(trip_id, operation_type, operation_id)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_trip_operations_pending
      ON trip_operations(stage, created_at)
    ''');
    await _createTripUploadOutboxSchema(database);
  }

  static Future<void> _createSchema13EvidenceTables(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS track_motion_evidence (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        configuration_epoch_id TEXT,
        fused_state TEXT NOT NULL,
        confidence INTEGER NOT NULL,
        policy_version INTEGER NOT NULL,
        observed_at TEXT NOT NULL,
        window_started_at TEXT,
        window_ended_at TEXT,
        supporting_sources_json TEXT NOT NULL,
        conflicting_sources_json TEXT NOT NULL,
        step_delta INTEGER NOT NULL DEFAULT 0,
        significant_motion INTEGER NOT NULL DEFAULT 0,
        accelerometer_sample_count INTEGER NOT NULL DEFAULT 0,
        acceleration_motion_energy REAL,
        gyroscope_sample_count INTEGER NOT NULL DEFAULT 0,
        rotation_energy REAL,
        compass_available INTEGER NOT NULL DEFAULT 0,
        gps_displacement_evidence TEXT,
        native_foreground_state TEXT,
        screen_interactive INTEGER,
        battery_saver_active INTEGER,
        transition_reason TEXT NOT NULL,
        selected_sampling_profile TEXT,
        generation INTEGER,
        created_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        FOREIGN KEY(configuration_epoch_id)
          REFERENCES tracking_configuration_epochs(id) ON DELETE CASCADE,
        CHECK(confidence >= 0 AND confidence <= 100),
        CHECK(policy_version > 0),
        CHECK(accelerometer_sample_count >= 0),
        CHECK(gyroscope_sample_count >= 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_track_motion_evidence_track_observed
      ON track_motion_evidence(track_id, observed_at DESC)
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS track_quality_runs (
        id TEXT PRIMARY KEY,
        track_id TEXT NOT NULL,
        first_raw_sequence INTEGER NOT NULL,
        last_raw_sequence INTEGER NOT NULL,
        rejected_count INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        maximum_uncertainty_m REAL,
        median_uncertainty_m REAL,
        before_point_id TEXT,
        after_point_id TEXT,
        severity TEXT NOT NULL,
        threshold_reason TEXT NOT NULL,
        policy_version INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        FOREIGN KEY(before_point_id) REFERENCES track_points(id) ON DELETE SET NULL,
        FOREIGN KEY(after_point_id) REFERENCES track_points(id) ON DELETE SET NULL,
        CHECK(first_raw_sequence > 0),
        CHECK(last_raw_sequence >= first_raw_sequence),
        CHECK(rejected_count > 0),
        CHECK(duration_ms >= 0),
        CHECK(policy_version > 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_track_quality_runs_track_sequence
      ON track_quality_runs(track_id, first_raw_sequence)
    ''');
  }

  static Future<void> _createTripUploadOutboxSchema(
    Database database,
  ) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS trip_upload_outbox (
        id TEXT PRIMARY KEY,
        trip_id TEXT NOT NULL,
        lifecycle_revision INTEGER NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        state TEXT NOT NULL DEFAULT 'pending',
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at TEXT NOT NULL,
        lease_owner TEXT,
        lease_expires_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        acknowledged_at TEXT,
        FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE,
        UNIQUE(trip_id, lifecycle_revision),
        CHECK(lifecycle_revision > 0),
        CHECK(state IN ('pending', 'leased', 'acknowledged')),
        CHECK(attempt_count >= 0)
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_trip_upload_outbox_due
      ON trip_upload_outbox(state, next_attempt_at, lease_expires_at)
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS idx_trip_upload_outbox_trip_state
      ON trip_upload_outbox(trip_id, state, lifecycle_revision)
    ''');
  }

  static Future<void> _backfillImplicitTrips(Database database) async {
    final trackColumns = await database.rawQuery('PRAGMA table_info(tracks)');
    if (trackColumns.isEmpty) return;
    final names = trackColumns.map((row) => row['name']).toSet();
    final required = <String>{
      'id',
      'user_id',
      'organization_id',
      'status',
      'started_at',
      'accepted_point_count',
      'rejected_point_count',
      'total_distance_m',
      'created_at',
      'updated_at',
    };
    if (!names.containsAll(required)) return;
    final routeExpression = names.contains('route_id') ? 'route_id' : 'NULL';
    final endedExpression = names.contains('ended_at') ? 'ended_at' : 'NULL';
    final pausedExpression = names.contains('paused_at') ? 'paused_at' : 'NULL';
    await database.rawInsert('''
      INSERT OR IGNORE INTO trips (
        id, user_id, organization_id, route_id, status, started_at,
        suspended_at, ended_at, current_leg_track_id, leg_count,
        accepted_point_count, rejected_point_count, measured_distance_m,
        lifecycle_revision, created_at, updated_at
      )
      SELECT id, user_id, organization_id, $routeExpression,
        CASE
          WHEN status IN ('starting', 'active', 'stopping') THEN 'active'
          WHEN status IN ('paused', 'interrupted') THEN 'suspended'
          WHEN status = 'failed' THEN 'failed'
          ELSE 'completed'
        END,
        started_at,
        CASE WHEN status IN ('paused', 'interrupted')
          THEN COALESCE($pausedExpression, updated_at) ELSE NULL END,
        CASE WHEN status IN ('completed', 'failed')
          THEN COALESCE($endedExpression, updated_at) ELSE NULL END,
        id, 1, accepted_point_count, rejected_point_count, total_distance_m,
        1, created_at, updated_at
      FROM tracks
    ''');
    await database.rawInsert('''
      INSERT OR IGNORE INTO trip_legs (
        trip_id, track_id, leg_number, started_at, ended_at
      )
      SELECT id, id, 1, started_at, $endedExpression FROM tracks
    ''');
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
        processor_confidence REAL,
        matched INTEGER NOT NULL DEFAULT 1,
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
      // Every legacy Track is also a one-leg implicit Trip. Full multi-day
      // lifecycle APIs add later legs without changing Track semantics.
      await transaction.insert('trips', <String, Object?>{
        'id': trackId,
        'user_id': userId,
        'organization_id': organizationId,
        'route_id': routeId,
        'status': 'active',
        'started_at': _timestamp(now),
        'current_leg_track_id': trackId,
        'leg_count': 1,
        'lifecycle_revision': 1,
        'capture_intent': config.captureIntent.name,
        'quality_policy_version': TrackingPolicyVersions.qualityPolicy,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      await transaction.insert('trip_legs', <String, Object?>{
        'trip_id': trackId,
        'track_id': trackId,
        'leg_number': 1,
        'started_at': _timestamp(now),
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
      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET status = 'active', suspended_at = NULL,
            current_leg_track_id = ?, updated_at = ?
        WHERE id = (SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1)
        ''',
        <Object?>[trackId, _timestamp(now), trackId],
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
      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET status = 'suspended', suspended_at = ?,
            current_leg_track_id = ?, updated_at = ?
        WHERE id = (SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1)
        ''',
        <Object?>[
          _timestamp(now),
          trackId,
          _timestamp(now),
          trackId,
        ],
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
      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET status = 'active', suspended_at = NULL,
            current_leg_track_id = ?, updated_at = ?
        WHERE id = (SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1)
        ''',
        <Object?>[trackId, _timestamp(now), trackId],
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
      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET status = 'active', suspended_at = NULL,
            current_leg_track_id = ?, updated_at = ?
        WHERE id = (SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1)
        ''',
        <Object?>[trackId, _timestamp(now), trackId],
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
      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET status = 'completed', ended_at = ?, suspended_at = NULL,
            current_leg_track_id = ?, lifecycle_revision = lifecycle_revision + 1,
            updated_at = ?
        WHERE id = (SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1)
        ''',
        <Object?>[
          _timestamp(now),
          trackId,
          _timestamp(now),
          trackId,
        ],
      );
      await transaction.update(
        'trip_legs',
        <String, Object?>{'ended_at': _timestamp(now)},
        where: 'track_id = ?',
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
      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET status = 'suspended', suspended_at = ?,
            current_leg_track_id = ?, updated_at = ?
        WHERE id = (SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1)
        ''',
        <Object?>[
          _timestamp(now),
          trackId,
          _timestamp(now),
          trackId,
        ],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<TrackPoint> appendPoint(PointWriteRequest request) async =>
      (await appendPointWithContinuity(request, null)).point;

  @override
  Future<PointAppendResult> appendPointWithContinuity(
    PointWriteRequest request,
    TrackingContinuityDecision? continuity,
  ) async {
    final result = await _db.transaction((transaction) async {
      final nativeEventId = request.sample.eventId;
      if (nativeEventId != null) {
        final existing = await transaction.query(
          'track_points',
          where: 'track_id = ? AND native_event_id = ?',
          whereArgs: <Object?>[request.trackId, nativeEventId],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          final point = TrackPoint.fromDatabase(existing.single);
          final gapRows = await transaction.query(
            'track_continuity_gaps',
            where: 'track_id = ? AND after_point_id = ?',
            whereArgs: <Object?>[request.trackId, point.id],
            orderBy: 'continuity_policy_version DESC',
            limit: 1,
          );
          return PointAppendResult(
            point: point,
            segmentId: point.segmentId,
            duplicate: true,
            gap: gapRows.isEmpty
                ? null
                : TrackingContinuityGap.fromDatabase(gapRows.single),
          );
        }
      }

      final trackBefore = await _requiredTrack(transaction, request.trackId);
      if (trackBefore.status != TrackStatus.active ||
          trackBefore.currentSegmentId == null) {
        throw StateError('Track is not active: ${request.trackId}');
      }
      final previousRaw = await _lastRawPoint(transaction, request.trackId);
      final previousAccepted =
          await _lastAcceptedPoint(transaction, request.trackId);
      final beforeSegmentId = trackBefore.currentSegmentId!;

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

      final now = _clock();
      var segmentId = beforeSegmentId;
      final shouldSplit = request.accepted &&
          continuity?.treatment == TrackingGapTreatment.startNewSegment &&
          previousAccepted?.segmentId == beforeSegmentId;
      if (shouldSplit) {
        segmentId = _idGenerator();
        final nextSegmentNumber = track.segmentCount + 1;
        await transaction.update(
          'track_segments',
          <String, Object?>{
            'status': TrackSegmentStatus.interrupted.name,
            'ended_at': _timestamp(request.sample.capturedAt),
            'pause_reason': 'continuity_${continuity!.cause.name}',
            'updated_at': _timestamp(now),
          },
          where: 'id = ?',
          whereArgs: <Object?>[beforeSegmentId],
        );
        await transaction.insert('track_segments', <String, Object?>{
          'id': segmentId,
          'track_id': request.trackId,
          'segment_number': nextSegmentNumber,
          'status': TrackSegmentStatus.active.name,
          'started_at': _timestamp(request.sample.capturedAt),
          'resumed_from_point_id': previousAccepted?.id,
          'pause_reason': 'continuity_${continuity.cause.name}',
          'created_at': _timestamp(now),
          'updated_at': _timestamp(now),
        });
        await transaction.update(
          'tracks',
          <String, Object?>{
            'current_segment_id': segmentId,
            'segment_count': nextSegmentNumber,
            'updated_at': _timestamp(now),
          },
          where: 'id = ?',
          whereArgs: <Object?>[request.trackId],
        );
      }

      final connectorDistance = previousAccepted == null
          ? 0.0
          : _distanceMeters(
              previousAccepted.latitude,
              previousAccepted.longitude,
              request.sample.latitude,
              request.sample.longitude,
            );
      final distanceDelta = request.accepted &&
              previousAccepted != null &&
              previousAccepted.segmentId == segmentId &&
              !shouldSplit &&
              !(continuity?.excludeConnectorFromMeasuredDistance ?? false)
          ? connectorDistance
          : 0.0;
      final activity = request.activity.evaluatedAt(
        request.sample.capturedAt,
        configurationEpoch.resolvedConfig.activityFreshnessThreshold,
      );
      final motionEvidenceId = await _persistMotionEvidence(
        transaction,
        trackId: request.trackId,
        configurationEpochId: configurationEpoch.id,
        evidence: request.sample.capturedMotionEvidence,
        samplingProfile: request.sample.samplingProfile,
        now: now,
      );
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
        'activity_type': activity.type.value,
        'activity_confidence': activity.confidence,
        'activity_source': activity.source,
        'activity_raw_type': activity.rawType,
        'activity_evidence_state': activity.evidenceState.name,
        'activity_age_ms': activity.age?.inMilliseconds,
        'activity_probabilities_json': jsonEncode(<String, int>{
          for (final entry in activity.probabilities.entries)
            entry.key.value: entry.value,
        }),
        'native_foreground_state':
            request.sample.capturedMotionEvidence?.nativeForegroundState,
        'screen_interactive': _sqliteBool(
          request.sample.capturedMotionEvidence?.screenInteractive,
        ),
        'battery_saver_active': _sqliteBool(
          request.sample.capturedMotionEvidence?.batterySaverActive,
        ),
        'motion_evidence_id': motionEvidenceId,
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
        'capture_generation_id': request.sample.captureGenerationId,
        'native_session_started_at':
            request.sample.nativeSessionStartedAt == null
                ? null
                : _timestamp(request.sample.nativeSessionStartedAt!),
        'native_lifecycle': request.sample.nativeLifecycle?.name,
        'sampling_profile': request.sample.samplingProfile?.name,
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

      TrackingContinuityGap? committedGap;
      if (continuity != null && previousAccepted != null) {
        final providerGap =
            request.sample.capturedAt.difference(previousAccepted.capturedAt);
        final rawReceiptGap = previousRaw?.nativeReceivedAt == null ||
                request.sample.nativeReceivedAt == null
            ? null
            : request.sample.nativeReceivedAt!
                .difference(previousRaw!.nativeReceivedAt!);
        final gapId = _idGenerator();
        await transaction.insert(
          'track_continuity_gaps',
          <String, Object?>{
            'id': gapId,
            'track_id': request.trackId,
            'before_point_id': previousAccepted.id,
            'after_point_id': id,
            'before_segment_id': beforeSegmentId,
            'after_segment_id': segmentId,
            'provider_gap_ms':
                providerGap.isNegative ? null : providerGap.inMilliseconds,
            'raw_receipt_gap_ms':
                rawReceiptGap == null || rawReceiptGap.isNegative
                    ? null
                    : rawReceiptGap.inMilliseconds,
            'straight_line_distance_m': connectorDistance,
            'cause': continuity.cause.name,
            'treatment': continuity.treatment.name,
            'distance_treatment':
                (continuity.excludeConnectorFromMeasuredDistance
                        ? TrackingGapDistanceTreatment.excluded
                        : TrackingGapDistanceTreatment.measured)
                    .name,
            'native_capture_generation': request.sample.captureGenerationId,
            'configuration_epoch_id': configurationEpoch.id,
            'continuity_policy_version': continuity.policyVersion,
            'created_at': _timestamp(now),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        final gapRows = await transaction.query(
          'track_continuity_gaps',
          where: 'track_id = ? AND after_point_id = ? '
              'AND continuity_policy_version = ?',
          whereArgs: <Object?>[
            request.trackId,
            id,
            continuity.policyVersion,
          ],
          limit: 1,
        );
        if (gapRows.isNotEmpty) {
          committedGap = TrackingContinuityGap.fromDatabase(gapRows.single);
        }
      }

      if (request.accepted && previousAccepted != null) {
        await _persistQualityRun(
          transaction,
          trackId: request.trackId,
          beforePoint: previousAccepted,
          afterPointId: id,
          afterSequence: sequence,
          maximumAcceptedAccuracyMeters:
              configurationEpoch.resolvedConfig.maximumAcceptedAccuracyMeters,
          policyVersion: configurationEpoch.qualityPolicyVersion,
          now: now,
        );
      }

      await transaction.rawUpdate(
        '''
        UPDATE trips
        SET accepted_point_count = accepted_point_count + ?,
            rejected_point_count = rejected_point_count + ?,
            measured_distance_m = measured_distance_m + ?,
            updated_at = ?
        WHERE id = (
          SELECT trip_id FROM trip_legs WHERE track_id = ? LIMIT 1
        )
        ''',
        <Object?>[
          request.accepted ? 1 : 0,
          request.accepted ? 0 : 1,
          distanceDelta,
          _timestamp(now),
          request.trackId,
        ],
      );
      final rows = await transaction.query(
        'track_points',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      final point = TrackPoint.fromDatabase(rows.single);
      return PointAppendResult(
        point: point,
        segmentId: segmentId,
        duplicate: false,
        gap: committedGap,
      );
    });
    await _emitCurrentTrack();
    return result;
  }

  Future<String?> _persistMotionEvidence(
    Transaction transaction, {
    required String trackId,
    required String configurationEpochId,
    required MotionEvidenceSnapshot? evidence,
    required SamplingProfile? samplingProfile,
    required DateTime now,
  }) async {
    if (evidence == null) return null;
    final observedAt = _timestamp(evidence.observedAt);
    final recent = await transaction.query(
      'track_motion_evidence',
      columns: <String>['id', 'generation', 'fused_state', 'policy_version'],
      where: 'track_id = ? AND observed_at = ?',
      whereArgs: <Object?>[trackId, observedAt],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (recent.isNotEmpty &&
        recent.single['generation'] == evidence.generation &&
        recent.single['fused_state'] == evidence.state.name &&
        recent.single['policy_version'] == evidence.policyVersion) {
      return recent.single['id']! as String;
    }

    final id = _idGenerator();
    final duration = evidence.probeDuration;
    await transaction.insert('track_motion_evidence', <String, Object?>{
      'id': id,
      'track_id': trackId,
      'configuration_epoch_id': configurationEpochId,
      'fused_state': evidence.state.name,
      'confidence': evidence.confidence,
      'policy_version': evidence.policyVersion,
      'observed_at': observedAt,
      'window_started_at': duration == null
          ? null
          : _timestamp(evidence.observedAt.subtract(duration)),
      'window_ended_at': duration == null ? null : observedAt,
      'supporting_sources_json': jsonEncode(
        evidence.supportingSources.map((source) => source.name).toList(),
      ),
      'conflicting_sources_json': jsonEncode(
        evidence.conflictingSources.map((source) => source.name).toList(),
      ),
      'step_delta': evidence.stepDetected ? 1 : 0,
      'significant_motion': evidence.significantMotionDetected ? 1 : 0,
      'accelerometer_sample_count': evidence.accelerometerSampleCount,
      'acceleration_motion_energy': evidence.accelerationMotionEnergy,
      'gyroscope_sample_count': evidence.gyroscopeSampleCount,
      'rotation_energy': evidence.rotationEnergy,
      'compass_available': evidence.compassAvailable ? 1 : 0,
      'gps_displacement_evidence': evidence.gpsDisplacementEvidence,
      'native_foreground_state': evidence.nativeForegroundState,
      'screen_interactive': _sqliteBool(evidence.screenInteractive),
      'battery_saver_active': _sqliteBool(evidence.batterySaverActive),
      'transition_reason': evidence.reason,
      'selected_sampling_profile': samplingProfile?.name,
      'generation': evidence.generation,
      'created_at': _timestamp(now),
    });
    // Retain only the newest coordinate-free summaries. Raw sensor samples are
    // never stored, and long Trips cannot grow this table without a bound.
    await transaction.rawDelete(
      '''
      DELETE FROM track_motion_evidence
      WHERE track_id = ? AND id NOT IN (
        SELECT id FROM track_motion_evidence
        WHERE track_id = ?
        ORDER BY observed_at DESC, created_at DESC
        LIMIT 512
      )
      ''',
      <Object?>[trackId, trackId],
    );
    return id;
  }

  Future<void> _persistQualityRun(
    Transaction transaction, {
    required String trackId,
    required TrackPoint beforePoint,
    required String afterPointId,
    required int afterSequence,
    required double maximumAcceptedAccuracyMeters,
    required int policyVersion,
    required DateTime now,
  }) async {
    final rows = await transaction.query(
      'track_points',
      columns: <String>[
        'sequence',
        'captured_at',
        'horizontal_accuracy',
        'rejection_reason',
      ],
      where: 'track_id = ? AND sequence > ? AND sequence < ? '
          'AND accepted = 0',
      whereArgs: <Object?>[trackId, beforePoint.sequence, afterSequence],
      orderBy: 'sequence ASC',
    );
    if (rows.isEmpty) return;
    final accuracy = rows
        .map((row) => (row['horizontal_accuracy'] as num?)?.toDouble())
        .whereType<double>()
        .where((value) => value.isFinite && value >= 0)
        .toList()
      ..sort();
    final firstAt =
        DateTime.parse(rows.first['captured_at']! as String).toUtc();
    final lastAt = DateTime.parse(rows.last['captured_at']! as String).toUtc();
    final duration = lastAt.difference(firstAt);
    final maximum = accuracy.isEmpty ? null : accuracy.last;
    final median = accuracy.isEmpty
        ? null
        : accuracy.length.isOdd
            ? accuracy[accuracy.length ~/ 2]
            : (accuracy[accuracy.length ~/ 2 - 1] +
                    accuracy[accuracy.length ~/ 2]) /
                2;
    final visible = rows.length >= 3 ||
        duration >= const Duration(seconds: 30) ||
        (maximum != null && maximum > maximumAcceptedAccuracyMeters * 1.5);
    final reasons = rows
        .map((row) => row['rejection_reason']?.toString())
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    await transaction.insert('track_quality_runs', <String, Object?>{
      'id': _idGenerator(),
      'track_id': trackId,
      'first_raw_sequence': (rows.first['sequence']! as num).toInt(),
      'last_raw_sequence': (rows.last['sequence']! as num).toInt(),
      'rejected_count': rows.length,
      'duration_ms': duration.isNegative ? 0 : duration.inMilliseconds,
      'maximum_uncertainty_m': maximum,
      'median_uncertainty_m': median,
      'before_point_id': beforePoint.id,
      'after_point_id': afterPointId,
      'severity': visible ? 'visibleGap' : 'informational',
      'threshold_reason':
          reasons.isEmpty ? 'rejected_fix_run' : reasons.join(','),
      'policy_version': policyVersion,
      'created_at': _timestamp(now),
    });
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
  Future<Trip?> getTripForOwner(TrackingOwner owner, String tripId) async {
    final rows = await _db.query(
      'trips',
      where: 'id = ? AND user_id = ? AND organization_id = ?',
      whereArgs: <Object?>[
        tripId,
        owner.userId,
        owner.organizationId,
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : Trip.fromDatabase(rows.single);
  }

  @override
  Future<TripPage> listTripPage(TripQuery query) async {
    if (query.limit < 1 || query.limit > 100) {
      throw ArgumentError.value(query.limit, 'limit', 'Must be 1 through 100.');
    }
    final cursor = _decodeTripCursor(query.cursor);
    final where = <String>['user_id = ?', 'organization_id = ?'];
    final args = <Object?>[query.owner.userId, query.owner.organizationId];
    if (query.statuses.isNotEmpty) {
      where.add(
          'status IN (${List.filled(query.statuses.length, '?').join(',')})');
      args.addAll(query.statuses.map((status) => status.name));
    }
    if (cursor != null) {
      where.add('(started_at < ? OR (started_at = ? AND id < ?))');
      args.addAll(<Object?>[cursor.startedAt, cursor.startedAt, cursor.id]);
    }
    final rows = await _db.query(
      'trips',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'started_at DESC, id DESC',
      limit: query.limit + 1,
    );
    final hasMore = rows.length > query.limit;
    final visible = rows.take(query.limit).map(Trip.fromDatabase).toList();
    return TripPage(
      items: visible,
      nextCursor: hasMore && visible.isNotEmpty
          ? _encodeTripCursor(visible.last)
          : null,
    );
  }

  @override
  Future<TripLegPage> listTripLegPage({
    required TrackingOwner owner,
    required String tripId,
    required int limit,
    String? cursor,
  }) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be 1 through 100.');
    }
    await _requiredOwnedTrip(_db, owner, tripId);
    final after = _decodeLegCursor(cursor);
    final rows = await _db.rawQuery(
      '''
      SELECT l.*, t.status AS track_status
      FROM trip_legs l
      JOIN tracks t ON t.id = l.track_id
      WHERE l.trip_id = ? AND l.leg_number > ?
      ORDER BY l.leg_number ASC
      LIMIT ?
      ''',
      <Object?>[tripId, after, limit + 1],
    );
    final hasMore = rows.length > limit;
    final visible = rows.take(limit).map(TripLeg.fromDatabase).toList();
    return TripLegPage(
      items: visible,
      nextCursor: hasMore && visible.isNotEmpty
          ? _encodeLegCursor(visible.last.legNumber)
          : null,
    );
  }

  @override
  Future<TripBundle> loadTripBundleForOwner(
    TrackingOwner owner,
    String tripId,
  ) async {
    final trip = await _requiredOwnedTrip(_db, owner, tripId);
    final legRows = await _db.rawQuery(
      '''
      SELECT l.*, t.status AS track_status
      FROM trip_legs l
      JOIN tracks t ON t.id = l.track_id
      WHERE l.trip_id = ?
      ORDER BY l.leg_number ASC
      ''',
      <Object?>[tripId],
    );
    final gapRows = await _db.rawQuery(
      '''
      SELECT g.*
      FROM track_continuity_gaps g
      JOIN trip_legs l ON l.track_id = g.track_id
      WHERE l.trip_id = ?
      ORDER BY l.leg_number ASC, g.created_at ASC, g.id ASC
      ''',
      <Object?>[tripId],
    );
    return TripBundle(
      trip: trip,
      legs: legRows.map(TripLeg.fromDatabase),
      gaps: gapRows.map(TrackingContinuityGap.fromDatabase),
    );
  }

  @override
  Future<PreparedTripLeg> registerImplicitTripStart({
    required TrackingOwner owner,
    required String tripId,
    required String operationId,
    MultiDayRoutePresentation routePresentation =
        MultiDayRoutePresentation.separateRecordedParts,
    RouteCaptureIntent captureIntent = RouteCaptureIntent.adaptive,
    String? reason,
  }) async {
    final operationRecordId = await _db.transaction((transaction) async {
      final trip = await _requiredOwnedTrip(transaction, owner, tripId);
      final leg = await _requiredTripLeg(transaction, tripId, 1);
      final existing = await _findTripOperation(
        transaction,
        tripId: trip.id,
        type: TripOperationType.start,
        operationId: operationId,
      );
      if (existing != null) return existing.id;
      final now = _clock();
      await transaction.update(
        'trips',
        <String, Object?>{
          'route_presentation': routePresentation.name,
          'capture_intent': captureIntent.name,
          'quality_policy_version': TrackingPolicyVersions.qualityPolicy,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[trip.id],
      );
      final id = _idGenerator();
      await transaction.insert('trip_operations', <String, Object?>{
        'id': id,
        'trip_id': trip.id,
        'operation_type': TripOperationType.start.name,
        'operation_id': operationId,
        'stage': TripOperationStage.prepared.name,
        'reason': reason,
        'leg_track_id': leg.trackId,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      return id;
    });
    return _preparedTripLeg(operationRecordId, created: false);
  }

  @override
  Future<PreparedTripLeg> prepareNextTripLeg({
    required TrackingOwner owner,
    required String tripId,
    required TrackingConfig config,
    required String operationId,
    bool confirmCompletedTripContinuation = false,
    bool allowRevisionAfterAcknowledgedCompletion = false,
    String? dayLabel,
  }) async {
    config.validate(context: 'Trip continuation configuration');
    final prepared = await _db.transaction((transaction) async {
      final trip = await _requiredOwnedTrip(transaction, owner, tripId);
      final existingOperation = await _findTripOperation(
        transaction,
        tripId: tripId,
        type: TripOperationType.continueTrip,
        operationId: operationId,
      );
      if (existingOperation != null) {
        return (id: existingOperation.id, created: false);
      }
      if (trip.status == TripStatus.failed) {
        throw TrackingTripException(
          code: 'trip_not_continuable',
          message: 'A failed Trip cannot be continued.',
          tripId: trip.id,
        );
      }
      if (trip.status == TripStatus.completed &&
          !confirmCompletedTripContinuation) {
        throw TrackingTripException(
          code: 'completed_trip_confirmation_required',
          message:
              'Explicit confirmation is required to continue a completed Trip.',
          tripId: trip.id,
        );
      }
      if (trip.status == TripStatus.completed &&
          !allowRevisionAfterAcknowledgedCompletion) {
        final acknowledged = await transaction.query(
          'trip_upload_outbox',
          columns: <String>['id'],
          where: 'trip_id = ? AND state = ?',
          whereArgs: <Object?>[
            trip.id,
            TripUploadOutboxState.acknowledged.name,
          ],
          limit: 1,
        );
        if (acknowledged.isNotEmpty) {
          throw TrackingTripException(
            code: 'trip_already_finalized',
            message: 'The acknowledged Trip completion cannot be revised by '
                'the configured uploader.',
            tripId: trip.id,
          );
        }
      }

      final now = _clock();
      final currentTrackId = trip.currentLegTrackId;
      Track? currentTrack;
      if (currentTrackId != null) {
        final rows = await transaction.query(
          'tracks',
          where: 'id = ?',
          whereArgs: <Object?>[currentTrackId],
          limit: 1,
        );
        if (rows.isNotEmpty) currentTrack = Track.fromDatabase(rows.single);
      }

      var created = false;
      late String targetTrackId;
      if (currentTrack != null &&
          (currentTrack.status == TrackStatus.starting ||
              currentTrack.status == TrackStatus.active ||
              currentTrack.status == TrackStatus.interrupted ||
              currentTrack.status == TrackStatus.paused)) {
        targetTrackId = currentTrack.id;
      } else {
        final activeRows = await transaction.query(
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
        if (activeRows.isNotEmpty) {
          throw TrackingTripException(
            code: 'active_trip_conflict',
            message: 'Another Trip already owns active native capture.',
            tripId: trip.id,
          );
        }
        created = true;
        targetTrackId = _idGenerator();
        final segmentId = _idGenerator();
        final sessionControlToken = _sessionControlTokenGenerator();
        final nextLegNumber = trip.legCount + 1;
        await transaction.insert('tracks', <String, Object?>{
          'id': targetTrackId,
          'organization_id': owner.organizationId,
          'user_id': owner.userId,
          'route_id': trip.routeId,
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
            'id': _initialConfigurationEpochId(targetTrackId),
            'track_id': targetTrackId,
            'epoch_number': 1,
            'resolved_configuration_json': config.toJson(),
            'preset_definition_version':
                TrackingPolicyVersions.presetDefinition,
            'quality_policy_version': TrackingPolicyVersions.qualityPolicy,
            'created_at': _timestamp(now),
            'activation_sequence': 1,
            'activated_at': _timestamp(now),
          },
        );
        await transaction.insert('track_segments', <String, Object?>{
          'id': segmentId,
          'track_id': targetTrackId,
          'segment_number': 1,
          'status': TrackSegmentStatus.starting.name,
          'started_at': _timestamp(now),
          'created_at': _timestamp(now),
          'updated_at': _timestamp(now),
        });
        await transaction.insert('trip_legs', <String, Object?>{
          'trip_id': trip.id,
          'track_id': targetTrackId,
          'leg_number': nextLegNumber,
          'started_at': _timestamp(now),
          'day_label': dayLabel,
        });
        await transaction.update(
          'trips',
          <String, Object?>{
            'status': TripStatus.active.name,
            'suspended_at': null,
            'ended_at': null,
            'current_leg_track_id': targetTrackId,
            'leg_count': nextLegNumber,
            'lifecycle_revision': trip.lifecycleRevision + 1,
            'updated_at': _timestamp(now),
          },
          where: 'id = ?',
          whereArgs: <Object?>[trip.id],
        );
      }

      final operationRecordId = _idGenerator();
      await transaction.insert('trip_operations', <String, Object?>{
        'id': operationRecordId,
        'trip_id': trip.id,
        'operation_type': TripOperationType.continueTrip.name,
        'operation_id': operationId,
        'stage': TripOperationStage.prepared.name,
        'leg_track_id': targetTrackId,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      return (id: operationRecordId, created: created);
    });
    await _emitCurrentTrack();
    return _preparedTripLeg(prepared.id, created: prepared.created);
  }

  @override
  Future<void> markTripOperationStage({
    required String operationRecordId,
    required TripOperationStage stage,
  }) async {
    final now = _clock();
    final updated = await _db.update(
      'trip_operations',
      <String, Object?>{
        'stage': stage.name,
        'updated_at': _timestamp(now),
        if (stage == TripOperationStage.completed ||
            stage == TripOperationStage.failed)
          'completed_at': _timestamp(now),
      },
      where: 'id = ?',
      whereArgs: <Object?>[operationRecordId],
    );
    if (updated != 1) {
      throw const TrackingStorageException(
        code: 'trip_operation_missing',
        message: 'The durable Trip operation no longer exists.',
      );
    }
  }

  @override
  Future<TripOperationRecord> beginTripOperation({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required TripOperationType type,
    required String operationId,
    String? reason,
  }) async {
    final recordId = await _db.transaction((transaction) async {
      final trip = await _requiredOwnedTrip(transaction, owner, tripId);
      final membership = await transaction.query(
        'trip_legs',
        columns: <String>['track_id'],
        where: 'trip_id = ? AND track_id = ?',
        whereArgs: <Object?>[tripId, trackId],
        limit: 1,
      );
      if (membership.isEmpty || trip.currentLegTrackId != trackId) {
        throw TrackingTripException(
          code: 'trip_operation_conflict',
          message: 'The requested Track is not the current Trip leg.',
          tripId: trip.id,
        );
      }
      final existing = await _findTripOperation(
        transaction,
        tripId: tripId,
        type: type,
        operationId: operationId,
      );
      if (existing != null) return existing.id;
      final now = _clock();
      final id = _idGenerator();
      await transaction.insert('trip_operations', <String, Object?>{
        'id': id,
        'trip_id': tripId,
        'operation_type': type.name,
        'operation_id': operationId,
        'stage': TripOperationStage.prepared.name,
        'reason': reason,
        'leg_track_id': trackId,
        'created_at': _timestamp(now),
        'updated_at': _timestamp(now),
      });
      return id;
    });
    final rows = await _db.query(
      'trip_operations',
      where: 'id = ?',
      whereArgs: <Object?>[recordId],
      limit: 1,
    );
    return TripOperationRecord.fromDatabase(rows.single);
  }

  @override
  Future<void> suspendTripAfterLegCompletion({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required String reason,
    required String operationId,
  }) =>
      _finishTripLeg(
        owner: owner,
        tripId: tripId,
        trackId: trackId,
        reason: reason,
        operationId: operationId,
        operationType: TripOperationType.endDay,
        finalStatus: TripStatus.suspended,
      );

  @override
  Future<void> completeTripAfterLegCompletion({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required String reason,
    required String operationId,
  }) =>
      _finishTripLeg(
        owner: owner,
        tripId: tripId,
        trackId: trackId,
        reason: reason,
        operationId: operationId,
        operationType: TripOperationType.complete,
        finalStatus: TripStatus.completed,
      );

  Future<void> _finishTripLeg({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required String reason,
    required String operationId,
    required TripOperationType operationType,
    required TripStatus finalStatus,
  }) async {
    await _db.transaction((transaction) async {
      final trip = await _requiredOwnedTrip(transaction, owner, tripId);
      final membership = await transaction.query(
        'trip_legs',
        where: 'trip_id = ? AND track_id = ?',
        whereArgs: <Object?>[tripId, trackId],
        limit: 1,
      );
      if (membership.isEmpty || trip.currentLegTrackId != trackId) {
        throw TrackingTripException(
          code: 'trip_operation_conflict',
          message: 'The requested Track is not the current Trip leg.',
          tripId: trip.id,
        );
      }
      final existing = await _findTripOperation(
        transaction,
        tripId: tripId,
        type: operationType,
        operationId: operationId,
      );
      if (existing?.stage == TripOperationStage.completed) return;
      final now = _clock();
      final operationRecordId = existing?.id ?? _idGenerator();
      if (existing == null) {
        await transaction.insert('trip_operations', <String, Object?>{
          'id': operationRecordId,
          'trip_id': tripId,
          'operation_type': operationType.name,
          'operation_id': operationId,
          'stage': TripOperationStage.nativeStopped.name,
          'reason': reason,
          'leg_track_id': trackId,
          'created_at': _timestamp(now),
          'updated_at': _timestamp(now),
        });
      }
      final track = await _requiredTrack(transaction, trackId);
      if (track.status != TrackStatus.completed) {
        if (track.status == TrackStatus.failed) {
          throw TrackingTripException(
            code: 'trip_not_completable',
            message: 'A failed Trip leg cannot be completed.',
            tripId: trip.id,
          );
        }
        if (track.currentSegmentId != null) {
          await transaction.update(
            'track_segments',
            <String, Object?>{
              'status': TrackSegmentStatus.completed.name,
              'ended_at': _timestamp(now),
              'updated_at': _timestamp(now),
            },
            where: 'id = ?',
            whereArgs: <Object?>[track.currentSegmentId],
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
      }
      await transaction.update(
        'trip_legs',
        <String, Object?>{'ended_at': _timestamp(now)},
        where: 'trip_id = ? AND track_id = ?',
        whereArgs: <Object?>[tripId, trackId],
      );
      await transaction.update(
        'trips',
        <String, Object?>{
          'status': finalStatus.name,
          'suspended_at':
              finalStatus == TripStatus.suspended ? _timestamp(now) : null,
          'ended_at':
              finalStatus == TripStatus.completed ? _timestamp(now) : null,
          'current_leg_track_id': trackId,
          'lifecycle_revision': trip.lifecycleRevision + 1,
          'updated_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
      await transaction.update(
        'trip_operations',
        <String, Object?>{
          'stage': TripOperationStage.completed.name,
          'updated_at': _timestamp(now),
          'completed_at': _timestamp(now),
        },
        where: 'id = ?',
        whereArgs: <Object?>[operationRecordId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<List<TripOperationRecord>> pendingTripOperations() async {
    final rows = await _db.query(
      'trip_operations',
      where: 'stage NOT IN (?, ?)',
      whereArgs: <Object?>[
        TripOperationStage.completed.name,
        TripOperationStage.failed.name,
      ],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(TripOperationRecord.fromDatabase).toList(growable: false);
  }

  @override
  Future<TripOperationRecord?> findTripOperationForOwner({
    required TrackingOwner owner,
    required String operationId,
    TripOperationType? type,
  }) async {
    final rows = await _db.rawQuery(
      '''
      SELECT o.*
      FROM trip_operations o
      JOIN trips t ON t.id = o.trip_id
      WHERE t.user_id = ? AND t.organization_id = ?
        AND o.operation_id = ?
        ${type == null ? '' : 'AND o.operation_type = ?'}
      ORDER BY o.created_at DESC, o.id DESC
      LIMIT 1
      ''',
      <Object?>[
        owner.userId,
        owner.organizationId,
        operationId,
        if (type != null) type.name,
      ],
    );
    return rows.isEmpty ? null : TripOperationRecord.fromDatabase(rows.single);
  }

  @override
  Future<Trip> verifyAndRepairTripAggregates({
    required TrackingOwner owner,
    required String tripId,
  }) async {
    await _db.transaction((transaction) async {
      await _requiredOwnedTrip(transaction, owner, tripId);
      final totals = await transaction.rawQuery(
        '''
        SELECT COUNT(*) AS leg_count,
          COALESCE(SUM(t.accepted_point_count), 0) AS accepted_count,
          COALESCE(SUM(t.rejected_point_count), 0) AS rejected_count,
          COALESCE(SUM(t.total_distance_m), 0) AS measured_distance
        FROM trip_legs l
        JOIN tracks t ON t.id = l.track_id
        WHERE l.trip_id = ?
        ''',
        <Object?>[tripId],
      );
      final row = totals.single;
      await transaction.update(
        'trips',
        <String, Object?>{
          'leg_count': (row['leg_count'] as num).toInt(),
          'accepted_point_count': (row['accepted_count'] as num).toInt(),
          'rejected_point_count': (row['rejected_count'] as num).toInt(),
          'measured_distance_m': (row['measured_distance'] as num).toDouble(),
          'updated_at': _timestamp(_clock()),
        },
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
    });
    return (await getTripForOwner(owner, tripId))!;
  }

  @override
  Future<void> deleteTripForOwner(TrackingOwner owner, String tripId) async {
    await _db.transaction((transaction) async {
      final trip = await _requiredOwnedTrip(transaction, owner, tripId);
      if (trip.status == TripStatus.active ||
          trip.status == TripStatus.suspended) {
        throw TrackingTripException(
          code: 'trip_not_terminal',
          message: 'Only a terminal Trip can be deleted.',
          tripId: trip.id,
        );
      }
      final legRows = await transaction.query(
        'trip_legs',
        columns: <String>['track_id'],
        where: 'trip_id = ?',
        whereArgs: <Object?>[tripId],
      );
      // Clear the cyclic current-leg reference before Track cascades run.
      await transaction.update(
        'trips',
        <String, Object?>{'current_leg_track_id': null},
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
      for (final row in legRows) {
        await transaction.delete(
          'tracks',
          where: 'id = ?',
          whereArgs: <Object?>[row['track_id']],
        );
      }
      await transaction.delete(
        'trips',
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
    });
    await _emitCurrentTrack();
  }

  @override
  Future<void> enqueueTripCompletion({
    required TrackingOwner owner,
    required String tripId,
  }) async {
    await _db.transaction((transaction) async {
      final trip = await _requiredOwnedTrip(transaction, owner, tripId);
      if (trip.status != TripStatus.completed) {
        throw TrackingTripException(
          code: 'trip_not_completed',
          message: 'Only a completed Trip can enqueue final completion.',
          tripId: trip.id,
        );
      }
      final now = _clock();
      await transaction.insert(
        'trip_upload_outbox',
        <String, Object?>{
          'id': _idGenerator(),
          'trip_id': trip.id,
          'lifecycle_revision': trip.lifecycleRevision,
          'idempotency_key':
              'trip:${trip.id}:completion:v${trip.lifecycleRevision}',
          'state': TripUploadOutboxState.pending.name,
          'attempt_count': 0,
          'next_attempt_at': _timestamp(now),
          'created_at': _timestamp(now),
          'updated_at': _timestamp(now),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  @override
  Future<TripUploadOutboxLease?> leaseNextTripCompletion({
    required TrackingOwner owner,
    required String leaseOwner,
    required Duration leaseDuration,
  }) async {
    if (leaseOwner.trim().isEmpty) {
      throw ArgumentError.value(leaseOwner, 'leaseOwner');
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(leaseDuration, 'leaseDuration');
    }
    return _db.transaction((transaction) async {
      final now = _clock();
      final rows = await transaction.rawQuery(
        '''
        SELECT o.*
        FROM trip_upload_outbox o
        JOIN trips t ON t.id = o.trip_id
        WHERE t.user_id = ? AND t.organization_id = ?
          AND (
            (o.state = ? AND o.next_attempt_at <= ?)
            OR (o.state = ? AND o.lease_expires_at <= ?)
          )
        ORDER BY o.next_attempt_at ASC, o.created_at ASC, o.id ASC
        LIMIT 1
        ''',
        <Object?>[
          owner.userId,
          owner.organizationId,
          TripUploadOutboxState.pending.name,
          _timestamp(now),
          TripUploadOutboxState.leased.name,
          _timestamp(now),
        ],
      );
      if (rows.isEmpty) return null;
      final candidate = TripUploadOutboxEntry.fromDatabase(rows.single);
      final leaseExpiresAt = now.add(leaseDuration);
      final updated = await transaction.update(
        'trip_upload_outbox',
        <String, Object?>{
          'state': TripUploadOutboxState.leased.name,
          'lease_owner': leaseOwner,
          'lease_expires_at': _timestamp(leaseExpiresAt),
          'attempt_count': candidate.attemptCount + 1,
          'updated_at': _timestamp(now),
        },
        where: 'id = ? AND (state = ? OR '
            '(state = ? AND lease_expires_at <= ?))',
        whereArgs: <Object?>[
          candidate.id,
          TripUploadOutboxState.pending.name,
          TripUploadOutboxState.leased.name,
          _timestamp(now),
        ],
      );
      if (updated != 1) return null;
      final leasedRows = await transaction.query(
        'trip_upload_outbox',
        where: 'id = ?',
        whereArgs: <Object?>[candidate.id],
        limit: 1,
      );
      final trip = await _requiredOwnedTrip(
        transaction,
        owner,
        candidate.tripId,
      );
      return TripUploadOutboxLease(
        entry: TripUploadOutboxEntry.fromDatabase(leasedRows.single),
        trip: trip,
        leaseOwner: leaseOwner,
      );
    });
  }

  @override
  Future<void> acknowledgeTripCompletionUpload({
    required String outboxId,
    required String leaseOwner,
  }) async {
    final now = _clock();
    final updated = await _db.update(
      'trip_upload_outbox',
      <String, Object?>{
        'state': TripUploadOutboxState.acknowledged.name,
        'lease_owner': null,
        'lease_expires_at': null,
        'last_error': null,
        'acknowledged_at': _timestamp(now),
        'updated_at': _timestamp(now),
      },
      where: 'id = ? AND state = ? AND lease_owner = ?',
      whereArgs: <Object?>[
        outboxId,
        TripUploadOutboxState.leased.name,
        leaseOwner,
      ],
    );
    if (updated != 1) {
      throw const TrackingConflictException(
        code: 'trip_upload_lease_conflict',
        message: 'The Trip completion lease is no longer owned by this worker.',
      );
    }
  }

  @override
  Future<void> failTripCompletionUpload({
    required String outboxId,
    required String leaseOwner,
    required String error,
    required DateTime nextAttemptAt,
  }) async {
    final updated = await _db.update(
      'trip_upload_outbox',
      <String, Object?>{
        'state': TripUploadOutboxState.pending.name,
        'lease_owner': null,
        'lease_expires_at': null,
        'last_error': error,
        'next_attempt_at': _timestamp(nextAttemptAt.toUtc()),
        'updated_at': _timestamp(_clock()),
      },
      where: 'id = ? AND state = ? AND lease_owner = ?',
      whereArgs: <Object?>[
        outboxId,
        TripUploadOutboxState.leased.name,
        leaseOwner,
      ],
    );
    if (updated != 1) {
      throw const TrackingConflictException(
        code: 'trip_upload_lease_conflict',
        message: 'The Trip completion lease is no longer owned by this worker.',
      );
    }
  }

  @override
  Future<bool> hasAcknowledgedTripCompletion({
    required String tripId,
  }) async {
    final rows = await _db.query(
      'trip_upload_outbox',
      columns: <String>['id'],
      where: 'trip_id = ? AND state = ?',
      whereArgs: <Object?>[
        tripId,
        TripUploadOutboxState.acknowledged.name,
      ],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<TripUploadOutboxEntry>> listTripUploadEntriesForOwner(
    TrackingOwner owner,
  ) async {
    final rows = await _db.rawQuery(
      '''
      SELECT o.*
      FROM trip_upload_outbox o
      JOIN trips t ON t.id = o.trip_id
      WHERE t.user_id = ? AND t.organization_id = ?
      ORDER BY o.created_at ASC, o.id ASC
      ''',
      <Object?>[owner.userId, owner.organizationId],
    );
    return rows.map(TripUploadOutboxEntry.fromDatabase).toList(growable: false);
  }

  @override
  Future<void> eraseTripForOwner(TrackingOwner owner, String tripId) async {
    await _db.transaction((transaction) async {
      await _requiredOwnedTrip(transaction, owner, tripId);
      final legRows = await transaction.query(
        'trip_legs',
        columns: <String>['track_id'],
        where: 'trip_id = ?',
        whereArgs: <Object?>[tripId],
      );
      await transaction.update(
        'trips',
        <String, Object?>{'current_leg_track_id': null},
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
      for (final row in legRows) {
        await transaction.delete(
          'tracks',
          where: 'id = ?',
          whereArgs: <Object?>[row['track_id']],
        );
      }
      await transaction.delete(
        'trips',
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
    });
    await _emitCurrentTrack();
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
      await _prepareLegacyTrackDeletion(transaction, trackId);
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
      await _prepareLegacyTrackDeletion(transaction, trackId);
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
      await _prepareLegacyTrackDeletion(transaction, trackId);
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
      await _deleteTripsExcept(
        transaction,
        retainedTrackIds: retainedTrackIds,
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
      await _deleteTripsExcept(
        transaction,
        retainedTrackIds: retainedTrackIds,
        owner: owner,
        terminalOnly: true,
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

  @override
  Future<TrackPoint?> findLastRawPoint(String trackId) =>
      _lastRawPoint(_db, trackId);

  @override
  Future<List<TrackingContinuityGap>> listContinuityGaps(
    String trackId,
  ) async {
    final rows = await _db.query(
      'track_continuity_gaps',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(TrackingContinuityGap.fromDatabase).toList(growable: false);
  }

  @override
  Future<Set<String>> safeLegacyAutomaticAfterSegmentIds(
    String trackId,
  ) async {
    final rows = await _db.rawQuery(
      '''
      SELECT after_segment.id AS after_segment_id
      FROM track_segments after_segment
      JOIN track_segments before_segment
        ON before_segment.track_id = after_segment.track_id
       AND before_segment.segment_number = after_segment.segment_number - 1
      WHERE after_segment.track_id = ?
        AND after_segment.pause_reason = 'large_callback_gap'
        AND before_segment.pause_reason = 'large_callback_gap'
        AND after_segment.resumed_from_point_id IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM tracking_operations operation
          WHERE operation.track_id = after_segment.track_id
            AND operation.operation_type = 'pause'
            AND operation.completed_at >= before_segment.started_at
            AND operation.completed_at <= after_segment.started_at
        )
        AND NOT EXISTS (
          SELECT 1 FROM tracking_health_events health
          WHERE health.track_id = after_segment.track_id
            AND health.occurred_at >= before_segment.started_at
            AND health.occurred_at <= after_segment.started_at
            AND health.type IN (
              'native_tracker_interrupted',
              'native_tracker_failed',
              'previous_session_interrupted',
              'termination_recovery_started_gap_possible',
              'authorization_changed'
            )
        )
      ''',
      <Object?>[trackId],
    );
    return rows.map((row) => row['after_segment_id']! as String).toSet();
  }

  static Future<TrackPoint?> _lastRawPoint(
    DatabaseExecutor executor,
    String trackId,
  ) async {
    final rows = await executor.query(
      'track_points',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : TrackPoint.fromDatabase(rows.single);
  }

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

  static Future<Trip> _requiredOwnedTrip(
    DatabaseExecutor executor,
    TrackingOwner owner,
    String tripId,
  ) async {
    final rows = await executor.query(
      'trips',
      where: 'id = ? AND user_id = ? AND organization_id = ?',
      whereArgs: <Object?>[
        tripId,
        owner.userId,
        owner.organizationId,
      ],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_conflict',
        message: 'The Trip does not exist in the active owner scope.',
      );
    }
    return Trip.fromDatabase(rows.single);
  }

  static Future<void> _prepareLegacyTrackDeletion(
    DatabaseExecutor executor,
    String trackId,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT l.trip_id, t.leg_count
      FROM trip_legs l
      JOIN trips t ON t.id = l.trip_id
      WHERE l.track_id = ?
      LIMIT 1
      ''',
      <Object?>[trackId],
    );
    if (rows.isEmpty) return;
    final legCount = (rows.single['leg_count'] as num).toInt();
    if (legCount > 1) {
      throw TrackingStorageException(
        code: 'track_is_trip_leg',
        message: 'Delete the containing Trip instead of one internal leg.',
        trackId: trackId,
      );
    }
    final tripId = rows.single['trip_id']! as String;
    await executor.update(
      'trips',
      <String, Object?>{'current_leg_track_id': null},
      where: 'id = ?',
      whereArgs: <Object?>[tripId],
    );
    await executor.delete(
      'trips',
      where: 'id = ?',
      whereArgs: <Object?>[tripId],
    );
  }

  static Future<void> _deleteTripsExcept(
    DatabaseExecutor executor, {
    required Set<String> retainedTrackIds,
    TrackingOwner? owner,
    bool terminalOnly = false,
  }) async {
    final conditions = <String>[
      '''NOT EXISTS (
        SELECT 1 FROM trip_legs protected_legs
        JOIN managed_exports exports ON exports.track_id = protected_legs.track_id
        WHERE protected_legs.trip_id = trips.id AND exports.state = ?
      )''',
    ];
    final args = <Object?>[ManagedExportState.committed.name];
    if (owner != null) {
      conditions.add('user_id = ? AND organization_id = ?');
      args.addAll(<Object?>[owner.userId, owner.organizationId]);
    }
    if (terminalOnly) {
      conditions.add('status IN (?, ?)');
      args.addAll(<Object?>[TripStatus.completed.name, TripStatus.failed.name]);
    }
    if (retainedTrackIds.isNotEmpty) {
      final placeholders = List.filled(retainedTrackIds.length, '?').join(',');
      conditions.add('''NOT EXISTS (
        SELECT 1 FROM trip_legs retained
        WHERE retained.trip_id = trips.id
          AND retained.track_id IN ($placeholders)
      )''');
      args.addAll(retainedTrackIds);
    }
    final tripRows = await executor.query(
      'trips',
      columns: <String>['id'],
      where: conditions.join(' AND '),
      whereArgs: args,
    );
    for (final tripRow in tripRows) {
      final tripId = tripRow['id']! as String;
      final legRows = await executor.query(
        'trip_legs',
        columns: <String>['track_id'],
        where: 'trip_id = ?',
        whereArgs: <Object?>[tripId],
      );
      await executor.update(
        'trips',
        <String, Object?>{'current_leg_track_id': null},
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
      for (final legRow in legRows) {
        await executor.delete(
          'tracks',
          where: 'id = ?',
          whereArgs: <Object?>[legRow['track_id']],
        );
      }
      await executor.delete(
        'trips',
        where: 'id = ?',
        whereArgs: <Object?>[tripId],
      );
    }
  }

  static Future<TripLeg> _requiredTripLeg(
    DatabaseExecutor executor,
    String tripId,
    int legNumber,
  ) async {
    final rows = await executor.rawQuery(
      '''
      SELECT l.*, t.status AS track_status
      FROM trip_legs l
      JOIN tracks t ON t.id = l.track_id
      WHERE l.trip_id = ? AND l.leg_number = ?
      LIMIT 1
      ''',
      <Object?>[tripId, legNumber],
    );
    if (rows.isEmpty) {
      throw const TrackingStorageException(
        code: 'trip_leg_missing',
        message: 'The Trip leg does not exist.',
      );
    }
    return TripLeg.fromDatabase(rows.single);
  }

  static Future<TripOperationRecord?> _findTripOperation(
    DatabaseExecutor executor, {
    required String tripId,
    required TripOperationType type,
    required String operationId,
  }) async {
    final rows = await executor.query(
      'trip_operations',
      where: 'trip_id = ? AND operation_type = ? AND operation_id = ?',
      whereArgs: <Object?>[tripId, type.name, operationId],
      limit: 1,
    );
    return rows.isEmpty ? null : TripOperationRecord.fromDatabase(rows.single);
  }

  Future<PreparedTripLeg> _preparedTripLeg(
    String operationRecordId, {
    required bool created,
  }) async {
    final operationRows = await _db.query(
      'trip_operations',
      where: 'id = ?',
      whereArgs: <Object?>[operationRecordId],
      limit: 1,
    );
    if (operationRows.isEmpty) {
      throw const TrackingStorageException(
        code: 'trip_operation_missing',
        message: 'The durable Trip operation does not exist.',
      );
    }
    final operation = TripOperationRecord.fromDatabase(operationRows.single);
    final tripRows = await _db.query(
      'trips',
      where: 'id = ?',
      whereArgs: <Object?>[operation.tripId],
      limit: 1,
    );
    final legRows = await _db.rawQuery(
      '''
      SELECT l.*, t.status AS track_status
      FROM trip_legs l
      JOIN tracks t ON t.id = l.track_id
      WHERE l.trip_id = ? AND l.track_id = ?
      LIMIT 1
      ''',
      <Object?>[operation.tripId, operation.legTrackId],
    );
    final track = await getTrack(operation.legTrackId!);
    if (tripRows.isEmpty || legRows.isEmpty || track == null) {
      throw const TrackingStorageException(
        code: 'trip_operation_inconsistent',
        message: 'The Trip operation references missing local state.',
      );
    }
    return PreparedTripLeg(
      trip: Trip.fromDatabase(tripRows.single),
      leg: TripLeg.fromDatabase(legRows.single),
      track: track,
      operation: operation,
      created: created,
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

  static String _encodeTripCursor(Trip trip) {
    final payload = jsonEncode(<String, Object?>{
      'startedAt': _timestamp(trip.startedAt),
      'id': trip.id,
    });
    return base64Url.encode(utf8.encode(payload));
  }

  static _TripCursor? _decodeTripCursor(String? cursor) {
    if (cursor == null || cursor.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(cursor)));
      if (decoded is! Map) return null;
      final startedAt = decoded['startedAt'];
      final id = decoded['id'];
      if (startedAt is! String || id is! String || id.isEmpty) return null;
      return _TripCursor(startedAt: startedAt, id: id);
    } on Object {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid Trip-page cursor.');
    }
  }

  static String _encodeLegCursor(int legNumber) => base64Url
      .encode(utf8.encode(jsonEncode(<String, int>{'leg': legNumber})));

  static int _decodeLegCursor(String? cursor) {
    if (cursor == null || cursor.trim().isEmpty) return 0;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(cursor)));
      if (decoded is! Map || decoded['leg'] is! num) {
        throw const FormatException();
      }
      final value = (decoded['leg'] as num).toInt();
      if (value < 0) throw const FormatException();
      return value;
    } on Object {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid Trip-leg cursor.');
    }
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
            point.longitude > 180 ||
            (point.confidence != null &&
                (!point.confidence!.isFinite ||
                    point.confidence! < 0 ||
                    point.confidence! > 1))) {
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
            'processor_confidence': point.confidence,
            'matched': point.matched ? 1 : 0,
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
        confidence: (row['processor_confidence'] as num?)?.toDouble(),
        matched: row['matched'] != 0,
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
  Future<TrackingQualitySummary> trackQualitySummary({
    required TrackingOwner owner,
    required String trackId,
  }) async {
    final track = await getTrackForOwner(owner, trackId);
    if (track == null) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    return _qualitySummaryForTrackIds(<String>[trackId]);
  }

  @override
  Future<TrackingQualitySummary> tripQualitySummary({
    required TrackingOwner owner,
    required String tripId,
  }) async {
    final trip = await getTripForOwner(owner, tripId);
    if (trip == null) {
      throw const TrackingOwnershipException(
        code: 'trip_not_found_in_owner_scope',
        message: 'The Trip is not available in the current owner scope.',
      );
    }
    final rows = await _db.query(
      'trip_legs',
      columns: <String>['track_id'],
      where: 'trip_id = ?',
      whereArgs: <Object?>[tripId],
      orderBy: 'leg_number ASC',
    );
    return _qualitySummaryForTrackIds(
      rows.map((row) => row['track_id']! as String).toList(growable: false),
    );
  }

  Future<TrackingQualitySummary> _qualitySummaryForTrackIds(
    List<String> trackIds,
  ) async {
    if (trackIds.isEmpty) {
      return const TrackingQualitySummary(
        rawCallbackCount: 0,
        acceptedPointCount: 0,
        rejectedPointCount: 0,
        qualityRunCount: 0,
        visibleQualityRunCount: 0,
        continuityGapCount: 0,
        lifecycleBoundaryCount: 0,
        staleActivityCount: 0,
      );
    }
    final placeholders = List<String>.filled(trackIds.length, '?').join(',');
    final pointRows = await _db.rawQuery('''
      SELECT accepted, horizontal_accuracy, activity_evidence_state
      FROM track_points WHERE track_id IN ($placeholders)
      ''', trackIds);
    final qualityRows = await _db.rawQuery('''
      SELECT severity FROM track_quality_runs
      WHERE track_id IN ($placeholders)
      ''', trackIds);
    final gapRows = await _db.rawQuery('''
      SELECT cause FROM track_continuity_gaps
      WHERE track_id IN ($placeholders)
      ''', trackIds);
    final acceptedAccuracy = <double>[];
    final rejectedAccuracy = <double>[];
    var accepted = 0;
    var rejected = 0;
    var stale = 0;
    for (final row in pointRows) {
      final isAccepted = row['accepted'] == 1;
      if (isAccepted) {
        accepted += 1;
      } else {
        rejected += 1;
      }
      if (row['activity_evidence_state'] == ActivityEvidenceState.stale.name) {
        stale += 1;
      }
      final accuracy = (row['horizontal_accuracy'] as num?)?.toDouble();
      if (accuracy != null && accuracy.isFinite && accuracy >= 0) {
        (isAccepted ? acceptedAccuracy : rejectedAccuracy).add(accuracy);
      }
    }
    const lifecycleCauses = <String>{
      'explicitPause',
      'nativeInterruption',
      'processRestart',
      'permissionOrServiceLoss',
      'overnightBoundary',
    };
    return TrackingQualitySummary(
      rawCallbackCount: pointRows.length,
      acceptedPointCount: accepted,
      rejectedPointCount: rejected,
      qualityRunCount: qualityRows.length,
      visibleQualityRunCount:
          qualityRows.where((row) => row['severity'] != 'informational').length,
      continuityGapCount: gapRows.length,
      lifecycleBoundaryCount:
          gapRows.where((row) => lifecycleCauses.contains(row['cause'])).length,
      staleActivityCount: stale,
      acceptedAccuracyP50Meters: _percentile(acceptedAccuracy, 0.50),
      acceptedAccuracyP95Meters: _percentile(acceptedAccuracy, 0.95),
      rejectedAccuracyP50Meters: _percentile(rejectedAccuracy, 0.50),
      rejectedAccuracyP95Meters: _percentile(rejectedAccuracy, 0.95),
    );
  }

  static double? _percentile(List<double> values, double percentile) {
    if (values.isEmpty) return null;
    values.sort();
    final index = ((values.length - 1) * percentile).round();
    return values[index];
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

final class _TripCursor {
  const _TripCursor({required this.startedAt, required this.id});

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
