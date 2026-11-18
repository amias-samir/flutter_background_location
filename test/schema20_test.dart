import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// FLT-16 / REL-14: schema 20 changes indexes and adds the quarantine table;
// no row is rewritten. A fresh database and one upgraded from schema 19 must
// end with the same schema.

Future<Database> _raw(String path) => databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );

Future<SqliteTrackRepository> _open(String path) async {
  final repository = SqliteTrackRepository(
    path: path,
    databaseFactoryOverride: databaseFactoryFfi,
    singleInstance: false,
  );
  await repository.initialize();
  return repository;
}

/// Named schema objects, without SQLite's own autoindexes.
Future<Map<String, String>> _schema(String path) async {
  final raw = await _raw(path);
  final rows = await raw.rawQuery(
    "SELECT type, name, sql FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
  );
  await raw.close();
  return <String, String>{
    for (final row in rows)
      '${row['type']}:${row['name']}':
          (row['sql'] as String? ?? '').replaceAll(RegExp(r'\s+'), ' ').trim(),
  };
}

Future<String> _plan(Database raw, String sql, List<Object?> args) async =>
    (await raw.rawQuery('EXPLAIN QUERY PLAN $sql', args))
        .map((row) => row['detail'])
        .join(' ');

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fbl-schema20-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('a fresh database has the schema 20 indexes and quarantine', () async {
    final path = '${directory.path}/fresh.sqlite';
    await (await _open(path)).close();
    final schema = await _schema(path);
    expect(
        schema.keys,
        containsAll(<String>[
          'index:idx_track_points_upload_pending',
          'index:idx_derived_points_source',
          'index:idx_gaps_before_point',
          'index:idx_gaps_after_point',
          'index:idx_quality_runs_before_point',
          'index:idx_quality_runs_after_point',
          'index:idx_track_stops_arrival_point',
          'index:idx_track_stops_departure_point',
          'index:idx_health_events_track',
          'table:quarantined_native_events',
        ]));
    expect(
        schema.keys, isNot(contains('index:idx_track_points_track_sequence')),
        reason: 'UNIQUE(track_id, sequence) already indexes it');
    expect(schema.keys, isNot(contains('index:idx_track_points_pending')));
    final raw = await _raw(path);
    expect(await raw.getVersion(), 20);
    await raw.close();
  });

  test('a schema 19 database upgrades to the fresh schema, keeping its rows',
      () async {
    final fresh = '${directory.path}/fresh.sqlite';
    await (await _open(fresh)).close();

    final upgraded = '${directory.path}/upgraded.sqlite';
    final repository = await _open(upgraded);
    final trackId = await repository.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: const TrackingConfig(),
      requestedTrackId: 'route',
    );
    await repository.close();
    // As schema 19 left it.
    final raw = await _raw(upgraded);
    for (final index in <String>[
      'idx_track_points_upload_pending',
      'idx_derived_points_source',
      'idx_gaps_before_point',
      'idx_gaps_after_point',
      'idx_quality_runs_before_point',
      'idx_quality_runs_after_point',
      'idx_track_stops_arrival_point',
      'idx_track_stops_departure_point',
      'idx_health_events_track',
    ]) {
      await raw.execute('DROP INDEX $index');
    }
    await raw.execute('DROP TABLE quarantined_native_events');
    await raw.execute(
      'CREATE INDEX idx_track_points_track_sequence '
      'ON track_points(track_id, sequence)',
    );
    await raw.execute(
      'CREATE INDEX idx_track_points_pending '
      'ON track_points(sync_state, captured_at)',
    );
    await raw.setVersion(19);
    await raw.close();

    final reopened = await _open(upgraded);
    expect(await reopened.getTrack(trackId), isNotNull);
    await reopened.close();
    expect(await _schema(upgraded), await _schema(fresh));
    final inspected = await _raw(upgraded);
    expect(await inspected.getVersion(), 20);
    await inspected.close();

    // Reopening changes nothing.
    await (await _open(upgraded)).close();
    expect(await _schema(upgraded), await _schema(fresh));
  });

  test('uploads and cascading deletes use the schema 20 indexes', () async {
    final path = '${directory.path}/plans.sqlite';
    await (await _open(path)).close();
    final raw = await _raw(path);
    // Which routes still have points to upload: only the accepted pending
    // points are indexed, never the rejected ones that stay pending.
    expect(
      await _plan(
        raw,
        "SELECT track_id FROM track_points "
        "WHERE accepted = 1 AND sync_state = 'pending'",
        const <Object?>[],
      ),
      contains('idx_track_points_upload_pending'),
    );
    expect(
      await _plan(
        raw,
        "SELECT * FROM track_points WHERE track_id = ? AND accepted = 1 "
        "AND sync_state = 'pending' ORDER BY sequence ASC LIMIT 100",
        <Object?>['route'],
      ),
      startsWith('SEARCH'),
    );
    for (final (table, column, index) in <(String, String, String)>[
      ('track_continuity_gaps', 'after_point_id', 'idx_gaps_after_point'),
      ('track_continuity_gaps', 'before_point_id', 'idx_gaps_before_point'),
      (
        'track_quality_runs',
        'before_point_id',
        'idx_quality_runs_before_point'
      ),
      ('track_stops', 'departure_point_id', 'idx_track_stops_departure_point'),
      (
        'derived_geometry_points',
        'source_point_id',
        'idx_derived_points_source'
      ),
    ]) {
      expect(
        await _plan(
            raw, 'SELECT 1 FROM $table WHERE $column = ?', <Object?>['p']),
        contains(index),
        reason: '$table.$column is looked up for every deleted point',
      );
    }
    await raw.close();
  });
}
